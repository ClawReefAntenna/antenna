#!/usr/bin/env python3
"""PUB-001 fixture-only Public Group encrypted fan-out proof."""

from __future__ import annotations

import base64
import calendar
import hashlib
import json
import re
import shutil
import subprocess
import tempfile
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any


INNER_PROTOCOL = "antenna-public-group-ed25519-v1"
SUBMIT_PROTOCOL = "antenna-public-group-submit-v1"
BINDING_PROTOCOL = "antenna-age-key-binding-v1"
SEND_SCOPE = "public-groups:send"
MAX_RECIPIENTS = 256
MAX_BODY = 64 * 1024
MAX_CIPHERTEXT = 2 * 1024 * 1024
UUID4_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")


class Rejected(Exception):
    pass


def run(*args: str, input_bytes: bytes | None = None, check: bool = True) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(args, input=input_bytes, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=check)


def field(name: str, value: str) -> bytes:
    raw = value.encode("utf-8")
    return name.encode() + b":" + str(len(raw)).encode() + b":" + raw + b"\n"


def canonical(fields: list[tuple[str, str]]) -> bytes:
    return b"".join(field(name, value) for name, value in fields)


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical_b64(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


def decode_b64(value: str) -> bytes:
    try:
        raw = base64.b64decode(value, validate=True)
    except Exception as exc:
        raise Rejected("invalid base64") from exc
    if canonical_b64(raw) != value:
        raise Rejected("non-canonical base64")
    return raw


def json_bytes(value: dict[str, Any]) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def strict_json(raw: bytes) -> dict[str, Any]:
    def pairs(items: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in items:
            if key in result:
                raise Rejected("duplicate JSON key")
            result[key] = value
        return result

    try:
        value = json.loads(raw.decode("utf-8"), object_pairs_hook=pairs)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise Rejected("invalid JSON") from exc
    if not isinstance(value, dict):
        raise Rejected("JSON object required")
    return value


@dataclass
class SigningIdentity:
    private: Path
    public: Path

    @classmethod
    def create(cls, root: Path, name: str) -> "SigningIdentity":
        directory = root / name
        directory.mkdir(mode=0o700)
        private = directory / "identity-private.pem"
        public = directory / "identity-public.pem"
        run("openssl", "genpkey", "-algorithm", "ED25519", "-out", str(private))
        private.chmod(0o600)
        run("openssl", "pkey", "-in", str(private), "-pubout", "-out", str(public))
        public.chmod(0o644)
        return cls(private, public)

    def sign(self, data: bytes, work: Path) -> str:
        source = work / f"sign-{uuid.uuid4()}.bin"
        signature = work / f"sig-{uuid.uuid4()}.bin"
        source.write_bytes(data)
        source.chmod(0o600)
        run("openssl", "pkeyutl", "-sign", "-rawin", "-inkey", str(self.private), "-in", str(source), "-out", str(signature))
        raw = signature.read_bytes()
        source.unlink()
        signature.unlink()
        if len(raw) != 64:
            raise Rejected("unexpected Ed25519 signature length")
        return "ed25519-v1:" + canonical_b64(raw)

    def fingerprint(self) -> str:
        der = run("openssl", "pkey", "-pubin", "-in", str(self.public), "-outform", "DER").stdout
        return sha(der)


def verify(public: Path, data: bytes, encoded: str, work: Path) -> None:
    if not encoded.startswith("ed25519-v1:"):
        raise Rejected("unsupported signature")
    raw = decode_b64(encoded.removeprefix("ed25519-v1:"))
    if len(raw) != 64:
        raise Rejected("invalid Ed25519 signature length")
    source = work / f"verify-{uuid.uuid4()}.bin"
    signature = work / f"verify-sig-{uuid.uuid4()}.bin"
    source.write_bytes(data)
    signature.write_bytes(raw)
    result = run("openssl", "pkeyutl", "-verify", "-rawin", "-pubin", "-inkey", str(public), "-in", str(source), "-sigfile", str(signature), check=False)
    source.unlink()
    signature.unlink()
    if result.returncode != 0:
        raise Rejected("invalid Ed25519 signature")


@dataclass
class AgeIdentity:
    private: Path
    recipient: str

    @classmethod
    def create(cls, root: Path, name: str) -> "AgeIdentity":
        directory = root / name
        directory.mkdir(mode=0o700, exist_ok=True)
        private = directory / "age-identity.txt"
        run("age-keygen", "-o", str(private))
        private.chmod(0o600)
        recipient = run("age-keygen", "-y", str(private)).stdout.decode().strip()
        if not recipient.startswith("age1"):
            raise Rejected("invalid age recipient")
        return cls(private, recipient)


@dataclass
class Host:
    host_id: str
    owner: str
    signing: SigningIdentity
    age: AgeIdentity
    hook_token: str
    active: bool = True

    def identity_fingerprint(self) -> str:
        return self.signing.fingerprint()

    def age_fingerprint(self) -> str:
        return sha(self.age.recipient.encode())

    def binding_bytes(self) -> bytes:
        return canonical([
            ("protocol", BINDING_PROTOCOL),
            ("host_id", self.host_id),
            ("age_recipient", self.age.recipient),
        ])

    def public_record(self, work: Path) -> dict[str, Any]:
        return {
            "host_id": self.host_id,
            "identity_public_key": self.signing.public.read_text(),
            "identity_fingerprint": self.identity_fingerprint(),
            "age_recipient": self.age.recipient,
            "age_fingerprint": self.age_fingerprint(),
            "age_binding_signature": self.signing.sign(self.binding_bytes(), work),
        }


def keyset_digest(records: list[dict[str, Any]]) -> str:
    parts: list[bytes] = []
    for record in sorted(records, key=lambda item: item["host_id"]):
        parts.append(canonical([
            ("host_id", record["host_id"]),
            ("identity_fingerprint", record["identity_fingerprint"]),
            ("age_recipient", record["age_recipient"]),
            ("age_fingerprint", record["age_fingerprint"]),
        ]))
    return sha(b"".join(parts))


class FixtureRegistry:
    def __init__(self, work: Path, group_id: str, revision: int, hosts: list[Host], members: dict[str, bool]) -> None:
        self.work = work
        self.group_id = group_id
        self.revision = revision
        self.hosts = {host.host_id: host for host in hosts}
        self.members = members
        self.tokens: dict[str, dict[str, Any]] = {}
        self.attempts: dict[str, int] = {}
        self.seen_submissions: set[tuple[str, str]] = set()

    def add_token(self, token: str, owner: str, scopes: list[str], active: bool = True) -> None:
        self.tokens[sha(token.encode())] = {"owner": owner, "scopes": scopes, "active": active}

    def recipients(self, sender_id: str) -> list[Host]:
        result = [self.hosts[host_id] for host_id, active in self.members.items() if active and host_id != sender_id and self.hosts[host_id].active]
        if not result or len(result) > MAX_RECIPIENTS:
            raise Rejected("invalid recipient count")
        return sorted(result, key=lambda host: host.host_id)

    def snapshot(self, sender_id: str) -> dict[str, Any]:
        if not self.members.get(sender_id) or sender_id not in self.hosts:
            raise Rejected("sender is not an active member")
        records = [host.public_record(self.work) for host in self.recipients(sender_id)]
        for record in records:
            if not record["age_recipient"] or not record["identity_public_key"]:
                raise Rejected("incomplete member key record")
            key_file = self.work / f"snapshot-{record['host_id']}.pem"
            key_file.write_text(record["identity_public_key"])
            verify(key_file, canonical([
                ("protocol", BINDING_PROTOCOL),
                ("host_id", record["host_id"]),
                ("age_recipient", record["age_recipient"]),
            ]), record["age_binding_signature"], self.work)
        return {"group_id": self.group_id, "group_revision": self.revision, "members": records, "keyset_digest": keyset_digest(records)}

    def authenticate(self, token: str, sender_id: str) -> None:
        auth = self.tokens.get(sha(token.encode()))
        sender = self.hosts.get(sender_id)
        if not auth or not auth["active"] or SEND_SCOPE not in auth["scopes"]:
            raise Rejected("unauthorized API token")
        if not sender or sender.owner != auth["owner"]:
            raise Rejected("token does not own sender host")

    def submit(self, token: str, request: dict[str, Any], fail: set[str] | None = None) -> tuple[dict[str, Any], dict[str, bytes]]:
        expected = {"protocol", "group_id", "group_revision", "keyset_digest", "sender_host_id", "message_id", "created_at", "ciphertext_format", "ciphertext_size", "ciphertext_sha256", "ciphertext_base64", "submission_signature"}
        if set(request) != expected or request["protocol"] != SUBMIT_PROTOCOL or request["ciphertext_format"] != "age-v1":
            raise Rejected("invalid submission schema")
        sender_id = request["sender_host_id"]
        self.authenticate(token, sender_id)
        if request["group_id"] != self.group_id or not self.members.get(sender_id):
            raise Rejected("sender is not authorized for group")
        if not isinstance(request["group_revision"], int) or request["group_revision"] < 0:
            raise Rejected("invalid group revision")
        if not UUID4_RE.fullmatch(request["message_id"]):
            raise Rejected("invalid message ID")
        try:
            created = calendar.timegm(time.strptime(request["created_at"], "%Y-%m-%dT%H:%M:%SZ"))
        except (TypeError, ValueError) as exc:
            raise Rejected("invalid submission timestamp") from exc
        now = int(time.time())
        if created < now - 300 or created > now + 60:
            raise Rejected("stale or future submission")
        ciphertext = decode_b64(request["ciphertext_base64"])
        if len(ciphertext) != request["ciphertext_size"] or len(ciphertext) > MAX_CIPHERTEXT or sha(ciphertext) != request["ciphertext_sha256"]:
            raise Rejected("ciphertext size or hash mismatch")
        current = self.snapshot(sender_id)
        if request["group_revision"] != current["group_revision"] or request["keyset_digest"] != current["keyset_digest"]:
            raise Rejected("stale group revision or key set")
        verify(self.hosts[sender_id].signing.public, submission_canonical(request), request["submission_signature"], self.work)
        replay_key = (sender_id, request["message_id"])
        if replay_key in self.seen_submissions:
            raise Rejected("duplicate submission")
        self.seen_submissions.add(replay_key)
        deliveries: dict[str, bytes] = {}
        results: list[dict[str, str]] = []
        for host in self.recipients(sender_id):
            self.attempts[host.host_id] = self.attempts.get(host.host_id, 0) + 1
            if fail and host.host_id in fail:
                results.append({"member_id": host.host_id, "status": "failed"})
                continue
            wrapper = {
                "group_id": self.group_id,
                "group_revision": self.revision,
                "sender_host_id": sender_id,
                "message_id": request["message_id"],
                "ciphertext_format": "age-v1",
                "ciphertext_size": len(ciphertext),
                "ciphertext_sha256": sha(ciphertext),
                "ciphertext": ciphertext,
            }
            assert "hook_token" not in wrapper and host.hook_token not in repr(wrapper)
            deliveries[host.host_id] = wrapper["ciphertext"]
            results.append({"member_id": host.host_id, "status": "accepted"})
        response = {"accepted": sum(item["status"] == "accepted" for item in results), "failed": sum(item["status"] != "accepted" for item in results), "results": results}
        assert "token" not in json.dumps(response).lower()
        return response, deliveries


def inner_canonical(value: dict[str, Any]) -> bytes:
    return canonical([
        ("protocol", value["protocol"]),
        ("sender_host_id", value["sender_host_id"]),
        ("timestamp", value["timestamp"]),
        ("message_id", value["message_id"]),
        ("group_id", value["group_id"]),
        ("group_revision", str(value["group_revision"])),
        ("subject", value["subject"]),
        ("body_base64", value["body_base64"]),
    ])


def submission_canonical(value: dict[str, Any]) -> bytes:
    return canonical([
        ("protocol", value["protocol"]),
        ("group_id", value["group_id"]),
        ("group_revision", str(value["group_revision"])),
        ("keyset_digest", value["keyset_digest"]),
        ("sender_host_id", value["sender_host_id"]),
        ("message_id", value["message_id"]),
        ("created_at", value["created_at"]),
        ("ciphertext_format", value["ciphertext_format"]),
        ("ciphertext_size", str(value["ciphertext_size"])),
        ("ciphertext_sha256", value["ciphertext_sha256"]),
    ])


def verify_snapshot(snapshot: dict[str, Any], pins: dict[str, tuple[str, str]], work: Path) -> list[str]:
    if snapshot["keyset_digest"] != keyset_digest(snapshot["members"]):
        raise Rejected("invalid key-set digest")
    recipients: list[str] = []
    for member in snapshot["members"]:
        identity_fp = sha(run("openssl", "pkey", "-pubin", "-inform", "PEM", "-outform", "DER", input_bytes=member["identity_public_key"].encode()).stdout)
        if identity_fp != member["identity_fingerprint"] or sha(member["age_recipient"].encode()) != member["age_fingerprint"]:
            raise Rejected("member fingerprint mismatch")
        key = work / f"sender-view-{member['host_id']}.pem"
        key.write_text(member["identity_public_key"])
        verify(key, canonical([("protocol", BINDING_PROTOCOL), ("host_id", member["host_id"]), ("age_recipient", member["age_recipient"])]), member["age_binding_signature"], work)
        prior = pins.get(member["host_id"])
        observed = (member["identity_fingerprint"], member["age_fingerprint"])
        if prior and prior != observed:
            raise Rejected("unexpected member key change")
        pins.setdefault(member["host_id"], observed)
        recipients.append(member["age_recipient"])
    return recipients


def encrypt_age(cleartext: bytes, recipients: list[str], work: Path) -> bytes:
    source = work / "inner-message.json"
    encrypted = work / "group-message.age"
    source.write_bytes(cleartext)
    args = ["age"]
    for recipient in recipients:
        args.extend(["-r", recipient])
    args.extend(["-o", str(encrypted), str(source)])
    run(*args)
    ciphertext = encrypted.read_bytes()
    source.unlink()
    encrypted.unlink()
    return ciphertext


def decrypt_age(ciphertext: bytes, identity: AgeIdentity, work: Path) -> bytes:
    source = work / f"cipher-{uuid.uuid4()}.age"
    output = work / f"clear-{uuid.uuid4()}.json"
    source.write_bytes(ciphertext)
    result = run("age", "-d", "-i", str(identity.private), "-o", str(output), str(source), check=False)
    source.unlink()
    if result.returncode != 0:
        if output.exists():
            output.unlink()
        raise Rejected("age decryption failed")
    clear = output.read_bytes()
    output.unlink()
    return clear


def verify_inner(cleartext: bytes, sender_public: Path, work: Path) -> dict[str, Any]:
    value = strict_json(cleartext)
    expected = {"protocol", "sender_host_id", "timestamp", "message_id", "group_id", "group_revision", "subject", "body_base64", "signature"}
    if set(value) != expected or value["protocol"] != INNER_PROTOCOL or not UUID4_RE.fullmatch(value["message_id"]):
        raise Rejected("invalid inner schema")
    body = decode_b64(value["body_base64"])
    if len(body) > MAX_BODY:
        raise Rejected("body too large")
    verify(sender_public, inner_canonical(value), value["signature"], work)
    value["body"] = body
    return value


def expect_rejected(label: str, operation: Any, passed: list[str]) -> None:
    try:
        operation()
    except Rejected:
        passed.append(label)
        print(f"PASS: {label}")
        return
    raise AssertionError(f"expected rejection: {label}")


def main() -> None:
    for command in ("openssl", "age", "age-keygen"):
        if not shutil.which(command):
            raise SystemExit(f"missing dependency: {command}")
    passed: list[str] = []
    retained_cipher_path: Path | None = None
    with tempfile.TemporaryDirectory(prefix="pub001-") as temp:
        work = Path(temp)
        group_id = str(uuid.uuid4())
        sender = Host(str(uuid.uuid4()), "account-a", SigningIdentity.create(work, "sender-sign"), AgeIdentity.create(work, "sender-age"), "fixture-hook-sender")
        alice = Host(str(uuid.uuid4()), "account-b", SigningIdentity.create(work, "alice-sign"), AgeIdentity.create(work, "alice-age"), "fixture-hook-alice")
        bob = Host(str(uuid.uuid4()), "account-c", SigningIdentity.create(work, "bob-sign"), AgeIdentity.create(work, "bob-age"), "fixture-hook-bob")
        outsider = Host(str(uuid.uuid4()), "account-z", SigningIdentity.create(work, "outsider-sign"), AgeIdentity.create(work, "outsider-age"), "fixture-hook-outsider")
        clawreef = AgeIdentity.create(work, "clawreef-nonrecipient")
        registry = FixtureRegistry(work, group_id, 7, [sender, alice, bob, outsider], {sender.host_id: True, alice.host_id: True, bob.host_id: True, outsider.host_id: False})
        token = "fixture-account-token-a"
        registry.add_token(token, "account-a", [SEND_SCOPE])
        registry.add_token("fixture-outsider-token", "account-z", [SEND_SCOPE])
        registry.add_token("fixture-wrong-scope", "account-a", ["groups:read"])

        pins: dict[str, tuple[str, str]] = {}
        snapshot = registry.snapshot(sender.host_id)
        recipients = verify_snapshot(snapshot, pins, work)
        body = "One signed ciphertext for the whole reef. 🦞\n".encode()
        inner: dict[str, Any] = {
            "protocol": INNER_PROTOCOL,
            "sender_host_id": sender.host_id,
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "message_id": str(uuid.uuid4()),
            "group_id": group_id,
            "group_revision": snapshot["group_revision"],
            "subject": "PUB-001 fixture",
            "body_base64": canonical_b64(body),
        }
        inner["signature"] = sender.signing.sign(inner_canonical(inner), work)
        cleartext = json_bytes(inner)
        ciphertext = encrypt_age(cleartext, recipients, work)
        retained_cipher_path = work / "group-message.age"
        assert len(ciphertext) <= MAX_CIPHERTEXT
        request: dict[str, Any] = {
            "protocol": SUBMIT_PROTOCOL,
            "group_id": group_id,
            "group_revision": snapshot["group_revision"],
            "keyset_digest": snapshot["keyset_digest"],
            "sender_host_id": sender.host_id,
            "message_id": inner["message_id"],
            "created_at": inner["timestamp"],
            "ciphertext_format": "age-v1",
            "ciphertext_size": len(ciphertext),
            "ciphertext_sha256": sha(ciphertext),
            "ciphertext_base64": canonical_b64(ciphertext),
        }
        request["submission_signature"] = sender.signing.sign(submission_canonical(request), work)
        response, deliveries = registry.submit(token, request)
        assert response["accepted"] == 2 and response["failed"] == 0
        assert deliveries[alice.host_id] == ciphertext == deliveries[bob.host_id]
        passed.append("one byte-identical ciphertext fanned to all recipients")
        print("PASS: one byte-identical ciphertext fanned to all recipients")

        for member in (alice, bob):
            verified = verify_inner(decrypt_age(deliveries[member.host_id], member.age, work), sender.signing.public, work)
            assert verified["body"] == body
            assert verified["group_id"] == request["group_id"]
            assert verified["group_revision"] == request["group_revision"]
            assert verified["sender_host_id"] == request["sender_host_id"]
            assert verified["message_id"] == request["message_id"]
        passed.append("all intended recipients decrypt and verify original sender")
        print("PASS: all intended recipients decrypt and verify original sender")

        expect_rejected("non-member cannot decrypt", lambda: decrypt_age(ciphertext, outsider.age, work), passed)
        expect_rejected("ClawReef cannot decrypt", lambda: decrypt_age(ciphertext, clawreef, work), passed)
        expect_rejected("duplicate submission is rejected", lambda: registry.submit(token, request), passed)
        expect_rejected("wrong account token cannot submit as sender", lambda: registry.submit("fixture-outsider-token", request), passed)
        expect_rejected("token without send scope is rejected", lambda: registry.submit("fixture-wrong-scope", request), passed)
        registry.members[sender.host_id] = False
        expect_rejected("removed sender cannot submit", lambda: registry.submit(token, request), passed)
        registry.members[sender.host_id] = True

        altered = dict(request)
        altered["ciphertext_base64"] = canonical_b64(ciphertext + b"X")
        expect_rejected("altered ciphertext fails closed", lambda: registry.submit(token, altered), passed)

        old_bob_age = bob.age
        bob.age = AgeIdentity.create(work, "bob-rotated-age")
        registry.revision += 1
        changed_snapshot = registry.snapshot(sender.host_id)
        expect_rejected("unexpected member key change fails sender pins", lambda: verify_snapshot(changed_snapshot, pins, work), passed)
        expect_rejected("stale group revision and key set fail relay", lambda: registry.submit(token, request), passed)
        bob.age = old_bob_age
        registry.revision = 7

        original_public_record = bob.public_record
        bob.public_record = lambda _work: {**original_public_record(_work), "age_recipient": ""}  # type: ignore[method-assign]
        expect_rejected("missing member encryption key fails snapshot", lambda: registry.snapshot(sender.host_id), passed)
        bob.public_record = original_public_record  # type: ignore[method-assign]

        tampered = dict(request)
        tampered["ciphertext_sha256"] = "0" * 64
        expect_rejected("ciphertext hash tamper fails closed", lambda: registry.submit(token, tampered), passed)
        bad_signature = dict(request)
        bad_signature["submission_signature"] = outsider.signing.sign(submission_canonical(bad_signature), work)
        expect_rejected("wrong outer signing key fails closed", lambda: registry.submit(token, bad_signature), passed)

        stale = dict(request)
        stale["message_id"] = str(uuid.uuid4())
        stale["created_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 301))
        stale["submission_signature"] = sender.signing.sign(submission_canonical(stale), work)
        expect_rejected("stale signed submission fails closed", lambda: registry.submit(token, stale), passed)

        partial_registry = FixtureRegistry(work, group_id, 7, [sender, alice, bob, outsider], {sender.host_id: True, alice.host_id: True, bob.host_id: True, outsider.host_id: False})
        partial_registry.add_token(token, "account-a", [SEND_SCOPE])
        partial_response, partial_deliveries = partial_registry.submit(token, request, fail={bob.host_id})
        assert partial_response["accepted"] == 1 and partial_response["failed"] == 1
        assert partial_registry.attempts == {alice.host_id: 1, bob.host_id: 1}
        assert set(partial_deliveries) == {alice.host_id}
        passed.append("partial delivery reports once without retry or transaction state")
        print("PASS: partial delivery reports once without retry or transaction state")
        assert all(host.hook_token not in json.dumps(partial_response) for host in (sender, alice, bob, outsider))
        passed.append("responses and wrappers expose no hook token")
        print("PASS: responses and wrappers expose no hook token")

        stress_identities = [AgeIdentity.create(work, f"stress-age-{index:03d}") for index in range(MAX_RECIPIENTS)]
        started = time.monotonic()
        stress_ciphertext = encrypt_age(cleartext, [identity.recipient for identity in stress_identities], work)
        elapsed = time.monotonic() - started
        assert len(stress_ciphertext) <= MAX_CIPHERTEXT
        assert decrypt_age(stress_ciphertext, stress_identities[0], work) == cleartext
        assert decrypt_age(stress_ciphertext, stress_identities[-1], work) == cleartext
        passed.append("age fan-out supports the proposed 256-recipient ceiling")
        print(f"PASS: age fan-out supports the proposed 256-recipient ceiling ({len(stress_ciphertext)} bytes, {elapsed:.3f}s encrypt)")

        # No ciphertext path survives even within the fixture before temp cleanup.
        assert not retained_cipher_path.exists()
        passed.append("fixture retains no ciphertext artifact")
        print("PASS: fixture retains no ciphertext artifact")

    assert retained_cipher_path is not None and not retained_cipher_path.exists()
    print(f"RESULT: {len(passed)}/{len(passed)} checks passed")


if __name__ == "__main__":
    main()
