# ANT-163-001 — Deterministic Signed-Relay Staging

**Date:** 2026-09-01  
**Status:** Historical v1.6.3 design; superseded by DEC-2026-09-02-002
**Scope:** Supported OpenClaw 2026.5.12, 2026.7.x, and 2026.8.1 generations

> **Do not implement this architecture for v1.6.4.** The owner rejected its
> coordinated-upgrade and network-partitioning cost. The corrective release
> restores `/hooks/agent` interoperability and retains only the independent
> relay-policy installation and integrity hardening. This document remains as
> immutable design history for the public v1.6.3 artifact.

## Corrected source finding

OpenClaw's built-in hook-mapping transform surface is the required pre-model
boundary; no plugin is required. `applyHookMappings(mappings, ctx)` supplies the
parsed JSON payload to a local JS/TS transform beneath the gateway config's
`hooks/transforms` root. The transform's returned agent action becomes the
isolated hook turn before `dispatchAgentHook`.

JSON parsing a valid JSON string and writing that JavaScript string as UTF-8
preserves Antenna's valid UTF-8 envelope bytes. The sender already rejects
invalid UTF-8 and NUL. Focused tests cover non-ASCII text, an em dash, embedded
and trailing LFs, and exact closing-marker bytes.

## Implemented flow

1. Sender posts `{ "message": "<signed envelope>" }` only to
   `/hooks/antenna`. There is no `/hooks/agent` fallback.
2. The static `antenna-deterministic-staging` mapping fixes the target agent,
   disables external-content bypass and final delivery, and invokes the exact
   package-owned `antenna-stage.mjs` transform.
3. The transform validates the string and size, creates a gateway-user-owned
   0700 staging directory, and writes a unique 0600 regular file with
   exclusive/no-follow semantics.
4. The transform returns only a staged-file instruction and a fresh static
   `hook:antenna:<UUID>` session. Signed envelope content never enters the
   model prompt.
5. The relay agent makes exactly one shell-tool call:
   `bash ../scripts/antenna-relay-deliver.sh <safe-staged-path>`. It never
   reads, writes, copies, parses, or reproduces the envelope.
6. The deterministic wrapper validates the staged path, verifies and routes
   the signed envelope, and removes the staged file.

Setup and side-by-side upgrade preserve unrelated hook mappings and valid
nested `hooks.transformsDir` settings, fail closed on conflicts or unsafe
roots, atomically install the transform, and retain rollback coverage. Doctor
audits mapping, transform, manifest, and relay policy read-only. Uninstall
removes only the canonical Antenna mapping/transform and preserves customized
or conflicting content with a warning.

## Compatibility boundary

Peers not configured for the v1.6.3 `/hooks/antenna` mapping fail closed and
must upgrade. Silent fallback to `/hooks/agent` would reintroduce model byte
transcription and is forbidden.

ClawReef Listed Public Group fan-out is not yet qualified for this flow. The
Registry currently appends `/hooks/agent` in `src/lib/antenna.ts`; that separate
repository must be reconciled to `/hooks/antenna` and requalified before full
Public Group compatibility may be claimed. This Antenna pass does not modify
the Registry.
