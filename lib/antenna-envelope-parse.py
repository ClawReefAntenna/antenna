#!/usr/bin/env python3
"""Strict, byte-preserving parser for one Antenna Ed25519 envelope."""
import json
import pathlib
import sys
import unicodedata

raw = pathlib.Path(sys.argv[1]).read_bytes()
body_path = pathlib.Path(sys.argv[2])
opening = b"[ANTENNA_RELAY]\n"
closing = b"[/ANTENNA_RELAY]"
allowed = {
    "protocol": 32, "from": 64, "timestamp": 32, "message_id": 36,
    "signature": 128, "auth": 96, "target_session": 128, "user": 64,
    "reply_to": 256, "subject": 200,
}

if raw.count(b"[ANTENNA_RELAY]") != 1 or raw.count(closing) != 1:
    raise SystemExit("envelope markers must occur exactly once")
try:
    start = raw.index(opening)
    end = raw.index(closing, start + len(opening))
except ValueError:
    raise SystemExit("envelope must contain one complete LF-framed marker pair")
inner = raw[start + len(opening):end]
if b"\r" in inner or not inner.endswith(b"\n"):
    raise SystemExit("closing marker must begin on its own LF-delimited line")

try:
    header_bytes, framed_body = inner.split(b"\n\n", 1)
    headers = {}
    for line in header_bytes.split(b"\n"):
        name, separator, value = line.partition(b": ")
        key = name.decode("ascii")
        text = value.decode("utf-8")
        malformed = (
            not separator or key not in allowed or key in headers or not text
            or text != text.strip() or len(value) > allowed.get(key, 0)
            or any(unicodedata.category(char).startswith("C") for char in text)
        )
        if malformed:
            raise ValueError("duplicate, unknown, oversized, or malformed header")
        headers[key] = text
    body = framed_body[:-1]
    if b"\0" in body:
        raise ValueError("NUL bytes are not supported in body")
    body.decode("utf-8")
except (UnicodeDecodeError, ValueError) as exc:
    raise SystemExit(str(exc))

body_path.write_bytes(body)
print(json.dumps(headers, ensure_ascii=False))
