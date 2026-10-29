"""Exercise the exact C ABI used by the native apps against a real HTTPS receiver."""
import ctypes
import json
import os
from pathlib import Path
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
LIBRARY = os.environ.get("MULTISYNC_LIBRARY")


class NativeBridge(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not LIBRARY:
            raise RuntimeError("Set MULTISYNC_LIBRARY to the built native shared library")
        cls.library = ctypes.CDLL(str(Path(LIBRARY).resolve()))
        cls.library.multisync_call.argtypes = [ctypes.c_char_p]
        cls.library.multisync_call.restype = ctypes.c_void_p
        cls.library.multisync_free.argtypes = [ctypes.c_void_p]

    def call(self, **request):
        pointer = self.library.multisync_call(json.dumps(request).encode())
        self.assertTrue(pointer)
        try:
            result = json.loads(ctypes.string_at(pointer))
        finally:
            self.library.multisync_free(pointer)
        return result

    def ok(self, **request):
        result = self.call(**request)
        self.assertTrue(result.get("ok"), result.get("error"))
        return result

    def until(self, handle, event, on_event=None):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            state = self.ok(op="poll", handle=handle)
            for item in state["events"]:
                self.assertNotEqual(item["event"], "error", item.get("message"))
                if on_event:
                    on_event(item)
                if item["event"] == event:
                    return item
            time.sleep(0.025)
        self.fail(f"native task did not emit {event}")

    def finish(self, handle):
        self.ok(op="stop", handle=handle)
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if self.ok(op="poll", handle=handle)["finished"]:
                self.ok(op="release", handle=handle)
                return
            time.sleep(0.025)
        self.fail("native task did not stop")

    def test_native_send_pause_resume_receiver_restart_and_no_overwrite(self):
        with tempfile.TemporaryDirectory(prefix="multisync-bridge-") as directory:
            root = Path(directory)
            inbox = root / "Inbox"
            inbox.mkdir()
            source = root / "素材.bin"
            data = os.urandom(2 * 1024 * 1024 + 193)
            source.write_bytes(data)
            (inbox / source.name).write_bytes(b"existing")
            receiver = self.ok(op="start_receive", inbox=str(inbox), host="127.0.0.1", port=0)["handle"]
            sender = None
            try:
                ready = self.until(receiver, "ready")
                ticket = ready["ticket"]
                port = self.ok(op="validate_ticket", ticket=ticket)["port"]
                journal = str(root / "outgoing" / "job.json")
                sender = self.ok(op="send", source=str(source), journal=journal, ticket=ticket)["handle"]
                waiting = self.until(sender, "waiting")
                jobs = self.ok(op="jobs", inbox=str(inbox))["jobs"]
                self.assertEqual(jobs[0]["state"], "pending")
                self.assertEqual(jobs[0]["offset"], 0)
                self.finish(sender)
                sender = None
                self.finish(receiver)
                receiver = self.ok(op="start_receive", inbox=str(inbox), host="127.0.0.1", port=port)["handle"]
                self.until(receiver, "ready")
                self.ok(op="approve", inbox=str(inbox), id=waiting["id"])
                sender = self.ok(op="send", journal=journal)["handle"]
                completed = self.until(sender, "completed")
                self.finish(sender)
                sender = None
                self.assertEqual((inbox / completed["final_name"]).read_bytes(), data)
                self.assertEqual((inbox / source.name).read_bytes(), b"existing")
                self.assertEqual(source.read_bytes(), data)
                # A repeated sender resumes the stable journal and does not create another copy.
                sender = self.ok(op="send", journal=journal)["handle"]
                self.until(sender, "completed")
                self.finish(sender)
                sender = None
                self.assertEqual(len([p for p in inbox.iterdir() if p.is_file()]), 2)
            finally:
                if sender:
                    self.finish(sender)
                self.finish(receiver)

    def test_invalid_requests_never_start_tasks(self):
        self.assertFalse(self.call(op="validate_ticket", ticket="https://example.com")["ok"])
        self.assertFalse(self.call(op="start_receive", inbox="relative", host="127.0.0.1")["ok"])
        self.assertFalse(self.call(op="start_receive", inbox=str(ROOT), host="8.8.8.8")["ok"])
        self.assertFalse(self.call(op="poll", handle="missing")["ok"])
        self.assertFalse(self.call(op="unknown")["ok"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
