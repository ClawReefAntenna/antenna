# Antenna Development State

**Maintainer baseline:** 2026-08-08  
**Checked-out baseline:** `v1.5.2`, commit `6f48bec` (`local-v1.4` / public `origin/main`)  
**Development branch:** `dev/antenna-next`

## Current truth

- v1.5.2 added the transport-first pairing wizard (Email / ClawReef / Manual).
- The current relay-agent contract is `write` the raw envelope to a temp file,
  then `exec` `antenna-relay-deliver.sh` with the file path. The wrapper owns
  validation, delivery, and cleanup.
- The current release line retains plaintext runtime-secret authentication with
  constant-time comparison. It does not include `lib/antenna-hmac.sh`.
- Group/broadcast messaging is proposed, not implemented. The controlling
  design record is local `docs/broadcast-design.md`; it supersedes the older
  FSD group/cluster proposal.

## Historical branches and notes

- The separate `v1.5` branch contains experimental HMAC-SHA256 canonicalization
  and `secret_mode` work (`67a3cf2`, `dab77d8`). It is not an ancestor of this
  baseline and must not be described as shipped.
- `docs/` is local/ignored working material. It contains useful history but
  includes stale baselines, unpruned REF statuses, and obsolete architecture
  assumptions.

## First maintenance objective

Create an evidence-backed rationalization plan before changing behavior:

1. inventory current documentation and generated/runtime artifacts;
2. classify each as current, historical, stale-but-retain, or removable only
   after an approved retention decision;
3. reconcile version, relay-contract, HMAC, and test-suite claims;
4. convert the live REF ledger into a verified active backlog;
5. present the HMAC path as a deliberate decision gate, not an implicit merge.

## Release boundary

Local commits may be prepared on `dev/antenna-next`. Betty owns pushes, tags,
GitHub Releases, ClawHub publication, and any public announcement.
