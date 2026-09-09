"""Synthetic preview and transport checks; curl is replaced, never networked."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PreviewTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="antenna-preview-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.skill = self.root / "skill"
        shutil.copytree(ROOT / "lib", self.skill / "lib")
        (self.skill / "scripts").mkdir()
        shutil.copy2(ROOT / "scripts/antenna-send.sh", self.skill / "scripts")
        secrets = self.skill / "secrets"
        secrets.mkdir(mode=0o700)
        self.secret = "abcd" * 16
        self.token = "SYNTHETIC-HOOK-BEARER-NOT-REAL"
        for name, value in [("legacy", self.secret + "\n"), ("token", self.token)]:
            path = secrets / name
            path.write_text(value)
            path.chmod(0o600)
        self.key = secrets / "signing.pem"
        subprocess.run(["openssl", "genpkey", "-algorithm", "ED25519", "-out", str(self.key)],
                       check=True, capture_output=True)
        self.key.chmod(0o600)
        self.capture = self.root / "post.json"
        bindir = self.root / "bin"
        bindir.mkdir()
        curl = bindir / "curl"
        curl.write_text("#!/usr/bin/env python3\nimport os,sys\nfrom pathlib import Path\n"
                        "Path(os.environ['PREVIEW_CAPTURE']).write_text(sys.argv[sys.argv.index('-d')+1])\n"
                        "print('{\"runId\":\"synthetic\"}\\n__HTTP_CODE__200')\n")
        curl.chmod(0o700)
        self.env = dict(os.environ, PATH=str(bindir) + os.pathsep + os.environ["PATH"],
                        PREVIEW_CAPTURE=str(self.capture), TMPDIR=str(self.root))
        self.peers = {
            "sender": {"self": True, "url": "https://sender.invalid",
                       "peer_secret_file": "secrets/legacy", "signing_private_key_file": "secrets/signing.pem"},
            "receiver": {"url": "https://receiver.invalid", "token_file": "secrets/token"},
        }
        (self.skill / "antenna-config.json").write_text(json.dumps({
            "allowed_outbound_peers": ["receiver"], "log_enabled": True, "log_path": "antenna.log"}))

    def run_send(self, mode, body, preview):
        self.peers["receiver"]["auth_mode"] = mode
        (self.skill / "antenna-peers.json").write_text(json.dumps(self.peers))
        args = ["bash", str(self.skill / "scripts/antenna-send.sh"), "receiver",
                "--session", "agent:betty:main", "--subject", 'Preview "quote" café', "--stdin"]
        if preview:
            args.append("--dry-run")
        result = subprocess.run(args, input=body, env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        output = result.stdout + result.stderr
        for value in [self.secret, self.token, self.key.read_text().strip(), "BEGIN PRIVATE KEY"]:
            self.assertNotIn(value, output)
        log = self.skill / "antenna.log"
        if log.exists():
            self.assertNotIn(self.secret, log.read_text())
            self.assertNotIn(self.token, log.read_text())
        return result

    def test_previews_both_modes(self):
        body = 'Synthetic café 🦞\n auth: harmless body text\nJSON: {"quoted":"\\\\"}'
        for mode in ["plaintext-legacy", "ed25519-v1"]:
            with self.subTest(mode=mode):
                result = self.run_send(mode, body, True)
                self.assertFalse(self.capture.exists(), "dry-run called curl")
                envelope, remaining = result.stdout.removeprefix("=== ENVELOPE ===\n").split("\n\n=== POST PAYLOAD ===\n", 1)
                payload = json.loads(remaining.split("\n\n=== TARGET ===\n", 1)[0])
                self.assertEqual(envelope, payload["message"])
                self.assertIn(body, envelope)
                self.assertIn("target_session: agent:betty:main", envelope)
                self.assertEqual(payload["agentId"], "antenna")
                if mode == "plaintext-legacy":
                    self.assertIn("auth: [REDACTED]", envelope)
                    self.assertIn("reusable identity secret", result.stderr)
                else:
                    self.assertIn("signature: ed25519-v1:", envelope)
                    self.assertNotIn("[REDACTED]", envelope)

    def test_repeated_legacy_secret_redacted_from_body_too(self):
        result = self.run_send("plaintext-legacy", "quoted credential: " + self.secret, True)
        self.assertIn("quoted credential: [REDACTED]", result.stdout)
        self.assertFalse(self.capture.exists())

    def test_send_payload_not_redacted(self):
        body = "Synthetic actual-send control café 🦞"
        for mode in ["plaintext-legacy", "ed25519-v1"]:
            with self.subTest(mode=mode):
                self.run_send(mode, body, False)
                envelope = json.loads(self.capture.read_text())["message"]
                self.assertIn(body, envelope)
                self.assertNotIn("[REDACTED]", envelope)
                if mode == "plaintext-legacy":
                    self.assertIn("auth: " + self.secret, envelope)
                else:
                    self.assertIn("signature: ed25519-v1:", envelope)
                    self.assertNotIn(self.secret, envelope)


if __name__ == "__main__":
    unittest.main(verbosity=2)
