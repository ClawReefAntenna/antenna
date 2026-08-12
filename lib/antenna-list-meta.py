#!/usr/bin/env python3
"""Strict local Distribution List metadata and snapshot codec."""
import json
import pathlib
import re
import sys

ID = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")
OPEN = b"[ANTENNA_META v=1]\n"
CLOSE = b"[/ANTENNA_META]\n\n"
MAX_META = 8192


def fail(message: str) -> None:
    raise SystemExit(f"Error: {message}")


def display_ok(value: object) -> bool:
    return (
        isinstance(value, str)
        and 1 <= len(value) <= 100
        and not any(ord(char) < 32 or ord(char) == 127 for char in value)
    )


def peers_ok(value: object) -> bool:
    return (
        isinstance(value, list)
        and 1 <= len(value) <= 100
        and all(isinstance(peer, str) and ID.fullmatch(peer) for peer in value)
    )


def canonical_peers(value: list[str]) -> list[str]:
    return sorted(set(value))


def prefix(display: str, peers_csv: str, source: str, destination: str) -> None:
    peers = peers_csv.split(",") if peers_csv else []
    if not display_ok(display) or not peers_ok(peers) or peers != canonical_peers(peers):
        fail("invalid or noncanonical list metadata")
    block = (
        OPEN
        + f"list: {display}\n".encode()
        + f"recipients: {','.join(peers)}\n".encode()
        + CLOSE
    )
    if len(block) > MAX_META:
        fail("list metadata exceeds 8192 bytes")
    body = pathlib.Path(source).read_bytes()
    if not body:
        fail("visible-recipient messages require a non-empty user body")
    if OPEN.rstrip(b"\n") in body or b"[/ANTENNA_META]" in body:
        fail("message body contains a reserved Antenna metadata delimiter")
    try:
        body.decode("utf-8")
    except UnicodeDecodeError:
        fail("message body must be valid UTF-8")
    if b"\0" in body:
        fail("message body contains NUL")
    pathlib.Path(destination).write_bytes(block + body)


def parse(source: str) -> None:
    data = pathlib.Path(source).read_bytes()
    if len(data) > 1_000_000:
        fail("source body is oversized")
    if data.count(OPEN) != 1 or data.count(b"[/ANTENNA_META]") != 1 or not data.startswith(OPEN):
        fail("metadata block is missing, duplicated, or embedded")
    end = data.find(CLOSE)
    if end < 0 or end + len(CLOSE) > MAX_META:
        fail("metadata block is malformed or oversized")
    block = data[len(OPEN):end]
    if not block.endswith(b"\n"):
        fail("metadata block is missing its final line ending")
    block = block[:-1]
    try:
        lines = block.decode("utf-8").split("\n")
    except UnicodeDecodeError:
        fail("metadata block is not UTF-8")
    if len(lines) != 2 or not lines[0].startswith("list: ") or not lines[1].startswith("recipients: "):
        fail("metadata block has an invalid shape")
    display = lines[0][6:]
    peers = lines[1][12:].split(",") if lines[1][12:] else []
    if not display_ok(display) or not peers_ok(peers) or peers != canonical_peers(peers):
        fail("metadata values are invalid or noncanonical")
    print(json.dumps({"display_name": display, "peers": peers}, separators=(",", ":")))


def snapshot(source: str) -> None:
    try:
        value = json.loads(pathlib.Path(source).read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        fail("snapshot is not valid UTF-8 JSON")
    if not isinstance(value, dict) or set(value) != {"schema_version", "display_name", "preferred_alias", "peers"}:
        fail("snapshot has unknown or missing fields")
    alias = value["preferred_alias"]
    if value["schema_version"] != 1 or not display_ok(value["display_name"]):
        fail("snapshot version or display name is invalid")
    if not isinstance(alias, str) or not ID.fullmatch(alias) or not peers_ok(value["peers"]):
        fail("snapshot alias or peers are invalid")
    value["peers"] = canonical_peers(value["peers"])
    print(json.dumps(value, separators=(",", ":")))


if len(sys.argv) < 3:
    fail("usage: antenna-list-meta.py prefix|parse|snapshot ...")
if sys.argv[1] == "prefix" and len(sys.argv) == 6:
    prefix(*sys.argv[2:])
elif sys.argv[1] == "parse" and len(sys.argv) == 3:
    parse(sys.argv[2])
elif sys.argv[1] == "snapshot" and len(sys.argv) == 3:
    snapshot(sys.argv[2])
else:
    fail("invalid metadata command")
