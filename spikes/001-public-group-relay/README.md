# PUB-001 Public Group Relay Spike

This is a local, disposable feasibility proof for the protocol in
`../../references/PUBLIC-GROUP-PROTOCOL-V1.md`. It is not Antenna or ClawReef
production code.

## Question

Can one Ed25519-authenticated sender create one multi-recipient age ciphertext
that a deterministic ClawReef fixture fans out byte-identically, while only
current intended members decrypt and verify it and all authorization/key
conflicts fail closed?

## Run

```bash
python3 proof.py
```

Dependencies: Python standard library, OpenSSL, `age`, and `age-keygen`.

The proof generates every identity, member record, trust pin, message, and
ciphertext under a temporary directory. The directory is deleted on exit.
It opens no socket, calls no live endpoint, reads no Antenna runtime secret,
and writes no database.

## Verdict

**VALIDATED — 21/21 checks passed.** The corrected proof uses the registered
Ed25519 host key as the submission credential, with no separate Public Group
API key. It includes actual multi-recipient age encryption, byte-identical
fan-out, recipient decryption and sender verification, non-member/ClawReef
decryption failure, unregistered and disabled-host rejection, membership/role
and rate authorization, freshness, replay, key conflicts, partial delivery,
downstream hook-token isolation, and temporary-artifact cleanup.

The 256-recipient ceiling was exercised with one 25,671-byte ciphertext; age
encryption took approximately 0.09 seconds on the validation host, and both the first and
last recipients decrypted the exact inner object. This is feasibility evidence,
not a production capacity guarantee.

See `../../references/PUB-001-FEASIBILITY-REPORT-2026-08-16.md`.
