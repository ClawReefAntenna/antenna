#!/usr/bin/env python3
"""Strict visible-recipient metadata encoder for local Distribution Lists."""
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


if len(sys.argv) < 3:
    fail("usage: antenna-list-meta.py prefix ...")
if sys.argv[1] == "prefix" and len(sys.argv) == 6:
    prefix(*sys.argv[2:])
else:
    fail("invalid metadata command")
