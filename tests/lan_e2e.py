"""Independent HTTPS contract tests. Requires the actual Rust binary; never substitutes a mock server."""
import base64
import hashlib
import http.client
import json
import os
from pathlib import Path
import select
import socket
import ssl
import subprocess
import tempfile
import time
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ.get("MULTISYNC_BIN", ROOT / "target/debug/multi-sync"))


def decode_ticket(value):
    raw = value.removeprefix("msync1:")
    return json.loads(base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4)))


class PinnedConnection(http.client.HTTPSConnection):
    def connect(self):
        raw = socket.create_connection((self.host, self.port), timeout=10)
        self.sock = self._context.wrap_socket(raw, server_hostname="multi-sync.local")


def event_from(process, timeout=15):
    if not select.select([process.stdout], [], [], timeout)[0]:
        raise AssertionError("engine did not emit an event before timeout")
    line = process.stdout.readline()
    if not line:
        raise AssertionError(f"engine exited without event: {process.poll()}")
    return json.loads(line)


class Receiver:
    def __init__(self, inbox):
        self.inbox = inbox
        self.process = subprocess.Popen(
            [str(BINARY), "receive", "--inbox", str(inbox), "--bind", "127.0.0.1:0", "--advertise", "127.0.0.1"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
        ready = event_from(self.process)
        if ready.get("event") != "ready":
            self.close()
            raise AssertionError(f"receiver startup failed: {ready.get('message', 'unexpected event')}")
        self.invitation = ready["ticket"]
        self.ticket = decode_ticket(self.invitation)

    def close(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=5)
        self.process.stdout.close()
        self.process.stderr.close()

    def request(self, method, path, body=b"", headers=None, token=None, certificate=None):
        cert = certificate or self.ticket["certificate"]
        der = base64.urlsafe_b64decode(cert + "=" * (-len(cert) % 4))
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.load_verify_locations(cadata=ssl.DER_cert_to_PEM_cert(der))
        connection = PinnedConnection(self.ticket["host"], self.ticket["port"], context=context, timeout=10)
        merged = {"Authorization": "Bearer " + (self.ticket["token"] if token is None else token)}
        merged.update(headers or {})
        try:
            connection.request(method, path, body, merged)
            response = connection.getresponse()
            data = response.read()
            return response.status, json.loads(data) if data else {}
        finally:
            connection.close()

    def decision(self, operation, job_id):
        result = subprocess.run([str(BINARY), operation, "--inbox", str(self.inbox), "--id", job_id],
                                capture_output=True, text=True, timeout=15)
        assert result.returncode == 0, result.stdout
        return json.loads(result.stdout)["job"]


class LanIntegration(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="multi-sync-e2e-")
        self.inbox = Path(self.temp.name) / "inbox"
        self.receiver = Receiver(self.inbox)

    def tearDown(self):
        self.receiver.close()
        self.temp.cleanup()

    def offer(self, data, name="sample.bin"):
        manifest = {"id": str(uuid.uuid4()), "name": name, "size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
        status, result = self.receiver.request("POST", "/v1/transfers", json.dumps(manifest).encode(), {"Content-Type": "application/json"})
        self.assertEqual(status, 200, result)
        return manifest

    def chunk(self, manifest, offset, data):
        return self.receiver.request("PUT", f"/v1/transfers/{manifest['id']}/chunks?offset={offset}", data,
                                     {"x-chunk-sha256": hashlib.sha256(data).hexdigest()})

    def test_accept_resume_restart_and_keep_both(self):
        data = os.urandom(2 * 1024 * 1024 + 123)
        source = Path(self.temp.name) / "source.bin"
        source.write_bytes(data)
        existing = self.inbox / "sample.bin"
        existing.write_bytes(b"preserve existing")
        manifest = self.offer(data)
        first = data[:1024 * 1024]
        self.assertEqual(self.chunk(manifest, 0, first)[0], 409)
        self.receiver.decision("approve", manifest["id"])
        self.assertEqual(self.chunk(manifest, 0, first)[1]["offset"], len(first))
        self.receiver.close()
        self.receiver = Receiver(self.inbox)
        status, job = self.receiver.request("GET", f"/v1/transfers/{manifest['id']}")
        self.assertEqual((status, job["offset"]), (200, len(first)))
        self.assertEqual(self.chunk(manifest, 0, first)[1]["offset"], len(first))
        for offset in range(len(first), len(data), 1024 * 1024):
            self.assertEqual(self.chunk(manifest, offset, data[offset:offset + 1024 * 1024])[0], 200)
        status, completed = self.receiver.request("POST", f"/v1/transfers/{manifest['id']}/complete")
        self.assertEqual((status, completed["state"]), (200, "completed"))
        self.assertEqual((self.inbox / completed["final_name"]).read_bytes(), data)
        self.assertEqual(existing.read_bytes(), b"preserve existing")
        self.assertEqual(source.read_bytes(), data)

    def test_authentication_certificate_mismatch_and_traversal(self):
        status, _ = self.receiver.request("GET", f"/v1/transfers/{uuid.uuid4()}", token="incorrect")
        self.assertEqual(status, 401)
        for name in ["../escape", "C:\\escape", "CON.txt"]:
            manifest = {"id": str(uuid.uuid4()), "name": name, "size": 0, "sha256": hashlib.sha256(b"").hexdigest()}
            status, _ = self.receiver.request("POST", "/v1/transfers", json.dumps(manifest).encode(), {"Content-Type": "application/json"})
            self.assertEqual(status, 409)
        other = Receiver(Path(self.temp.name) / "other")
        try:
            with self.assertRaises(ssl.SSLCertVerificationError):
                self.receiver.request("GET", "/v1/transfers/unused", certificate=other.ticket["certificate"])
        finally:
            other.close()

    def test_real_sender_keeps_source_and_journal_is_idempotent(self):
        source = Path(self.temp.name) / "original.bin"
        data = os.urandom(1024 * 1024 + 71)
        source.write_bytes(data)
        journal = Path(self.temp.name) / "outgoing/job.json"
        sender = subprocess.Popen([str(BINARY), "send", "--source", str(source), "--journal", str(journal)],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
        try:
            sender.stdin.write(self.receiver.invitation)
            sender.stdin.close()
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                event = event_from(sender)
                if event["event"] == "waiting":
                    self.receiver.decision("approve", event["id"])
                if event["event"] == "error":
                    self.fail(event.get("message"))
                if event["event"] == "completed":
                    break
            else:
                self.fail("sender did not complete")
            self.assertEqual(sender.wait(timeout=10), 0)
            self.assertEqual(source.read_bytes(), data)
            resumed = subprocess.run([str(BINARY), "send", "--journal", str(journal)], capture_output=True, text=True, timeout=30)
            self.assertEqual(resumed.returncode, 0, resumed.stdout)
            files = [path for path in self.inbox.iterdir() if path.is_file()]
            self.assertEqual(len(files), 1)
            self.assertEqual(files[0].read_bytes(), data)
        finally:
            if sender.poll() is None:
                sender.terminate()
                sender.wait(timeout=10)
            sender.stdout.close()
            sender.stderr.close()


if __name__ == "__main__":
    if not BINARY.is_file():
        raise SystemExit("Rust 引擎未构建；请先运行 cargo build -p multi-sync。未执行集成测试。")
    unittest.main(verbosity=2)
