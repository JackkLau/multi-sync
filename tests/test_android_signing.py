"""Release validation guardrails; SDK tools are stubbed, not cryptography tests."""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile


@unittest.skipIf(os.name == "nt", "Android shell helpers target macOS/Linux; Windows uses Android Studio")
class AndroidReleaseValidationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.apk = self.root / "release.apk"
        self.script = Path(__file__).resolve().parents[1] / "scripts/verify-android-apk.sh"
        self.fingerprint = "A1" * 32
        tools = self.root / "sdk/build-tools/35.0.0"
        tools.mkdir(parents=True)
        fixtures = {
            "apksigner": """#!/usr/bin/env python3
import os, sys
print(os.environ['TEST_APK_SIGNATURE'])
sys.exit(int(os.environ.get('TEST_APK_SIGNATURE_EXIT', '0')))
""",
            "aapt": """#!/usr/bin/env python3
import os
print(os.environ['TEST_APK_MANIFEST'])
""",
            "zipalign": """#!/usr/bin/env python3
import os, sys
assert sys.argv[1:5] == ['-c', '-P', '16', '4']
sys.exit(int(os.environ.get('TEST_APK_ALIGNMENT_EXIT', '0')))
""",
        }
        for name, content in fixtures.items():
            path = tools / name
            path.write_text(content)
            path.chmod(0o755)
        self.env = os.environ.copy()
        for key in ["ANDROID_SDK_ROOT", "ANDROID_BUILD_TOOLS_VERSION", "MULTISYNC_ANDROID_CERT_SHA256"]:
            self.env.pop(key, None)
        self.env.update({
            "ANDROID_HOME": str(self.root / "sdk"),
            "TEST_APK_SIGNATURE": (
                "Verified using v2 scheme (APK Signature Scheme v2): true\n"
                "Signer #1 certificate DN: CN=MultiSync Release\n"
                f"Signer #1 certificate SHA-256 digest: {self.fingerprint}\n"
            ),
            "TEST_APK_MANIFEST": "package: name='local.multisync' versionCode='2'\nsdkVersion:'26'\n",
        })
        self.write_apk()

    def write_apk(self, missing_abi=None):
        with zipfile.ZipFile(self.apk, "w") as archive:
            archive.writestr("AndroidManifest.xml", b"binary manifest fixture")
            archive.writestr("classes.dex", b"dex fixture")
            for abi in ["arm64-v8a", "x86_64"]:
                if abi != missing_abi:
                    archive.writestr(f"lib/{abi}/libmulti_sync_bridge.so", b"\x7fELFfixture")

    def verify(self, fingerprint=None):
        command = ["sh", str(self.script), str(self.apk)]
        if fingerprint is not None:
            command.append(fingerprint)
        return subprocess.run(command, env=self.env, capture_output=True, text=True)

    def test_matching_identity_passes_without_modifying_apk(self):
        before = hashlib.sha256(self.apk.read_bytes()).digest()
        result = self.verify(":".join(["a1"] * 32))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(self.fingerprint, result.stdout)
        self.assertEqual(hashlib.sha256(self.apk.read_bytes()).digest(), before)

    def test_wrong_signing_identity_rejected(self):
        result = self.verify("B2" * 32)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("证书不一致", result.stderr)

    def test_invalid_signature_rejected_before_success(self):
        self.env["TEST_APK_SIGNATURE_EXIT"] = "1"
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("验证通过", result.stdout)

    def test_debuggable_release_rejected(self):
        self.env["TEST_APK_MANIFEST"] += "application-debuggable\n"
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("可调试", result.stderr)

    def test_android_debug_certificate_rejected(self):
        self.env["TEST_APK_SIGNATURE"] = self.env["TEST_APK_SIGNATURE"].replace(
            "CN=MultiSync Release", "CN=Android Debug, O=Android, C=US"
        )
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Android Debug", result.stderr)

    def test_missing_native_engine_rejected(self):
        self.write_apk(missing_abi="arm64-v8a")
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("验证通过", result.stdout)

    def test_bad_alignment_rejected(self):
        self.env["TEST_APK_ALIGNMENT_EXIT"] = "1"
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("验证通过", result.stdout)


if __name__ == "__main__":
    unittest.main()
