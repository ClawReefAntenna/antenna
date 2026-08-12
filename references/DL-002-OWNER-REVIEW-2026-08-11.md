# DL-002 Owner Review — 2026-08-11

The original DL-002 implementation combined visible-recipient metadata with a
reply-all CLI and credential-free list export/import. All three were correct
and tested, but the latter two added substantially more machinery than value.

Corey and Betty therefore retained only `--show-recipients`. Antenna's intended
primary users are agents, which can read peer IDs from the signed visible block
and issue ordinary sends without a dedicated reply protocol. Humans can copy
the same IDs. Local list JSON can likewise be copied manually when genuinely
needed.

Removed:

- `antenna reply-all` and detached-body metadata parsing;
- `antenna lists export/import` and the snapshot schema;
- richer list objects, collision rules, mutation locks, and readiness warnings.

Retained:

- canonical signed-body prefix generation;
- alias and sorted/deduplicated recipient display;
- body preservation, delimiter protection, and signature-tamper coverage;
- ordinary DL-001 independent-unicast semantics.

Git history preserves the fuller implementation at `9a71c0b`; sunk cost is not
a reason to ship it.

Post-prune verification passed: visible-prefix 15/15, DL-001 30/30, Tier A
20/20, and all 23 deterministic scripts. The retained slice is +36 net runtime
lines over DL-001 and removes 203 net runtime lines from the pre-prune state.
