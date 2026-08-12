# SIG-002 Owner Security Review

**Date:** 2026-08-11

**Reviewed implementation:** `a6a5757..6e1be6f`

**Verdict:** clear after follow-up repairs; no release authorization implied

## Review focus

- exact per-peer mode selection and downgrade resistance;
- legacy secret file ownership, mode, and content validation;
- schema-v2 credential exclusivity and schema-v1 legacy mapping;
- validation-before-mutation for imported Ed25519 keys;
- pinned-key directory trust and fresh-install behavior;
- consistency between `antenna bundle verify` and real import;
- complexity and absence of negotiation/recovery state.

## Finding and repair

The committed implementation validated a real Ed25519 PEM before import but the
shared bundle-shape verifier accepted any value beginning with a PEM header.
That allowed `antenna bundle verify` to report success for material the importer
would later reject. Full, bounded Ed25519 public-key validation now lives in the
shared bundle validator used by both paths. The redundant import-only check was
removed. The same follow-up made legacy secret content exact rather than
discarding arbitrary embedded whitespace, exposed public-key presence in safe
bundle summaries, and corrected a stale development-state sentence.

## Evidence

- focused authentication: 72/72;
- migration/bundle: 9/9, including invalid-PEM verifier rejection and no
  peer/token mutation;
- nonce-scoped rejection regression: 16/16;
- hermetic Tier A: 20/20;
- isolated deterministic scripts: all non-Tier scripts passed; Tier A was run
  separately because the owner's packaging harness deliberately excluded the
  worktree bootstrap `AGENTS.md` and thereby also omitted the tracked fixture's
  `agent/AGENTS.md`;
- Bash syntax, Python compilation, and `git diff --check`: clean;
- runtime delta: +95 net lines against `a6a5757`, below the 200-line stop gate.

## Residual boundaries

Encrypted bootstrap provenance remains an operator-approved exchange trust
decision, as in the existing Antenna pairing model. Re-pairing may leave old,
unreferenced credential files on disk; SIG-002 deliberately does not add
automatic deletion, rollback, rotation, a journal, or recovery state. No live
host, push, tag, release, or public claim was reviewed or authorized.
