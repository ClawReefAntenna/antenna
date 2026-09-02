# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in Antenna, **please report it privately** rather than opening a public GitHub issue.

**Email:** [help@clawreef.io](mailto:help@clawreef.io)

Include:
- A description of the vulnerability
- Steps to reproduce (if applicable)
- The version of Antenna you're running
- Any relevant logs or configuration (redact secrets)

We will acknowledge your report within 48 hours and aim to provide a fix or mitigation within 7 days for critical issues.

## Scope

This policy covers the Antenna skill itself — scripts, relay protocol, trust model, and configuration handling. For vulnerabilities in OpenClaw core, please report to the [OpenClaw project](https://github.com/openclaw/openclaw) directly.

## Supported Versions

| Version | Supported |
|---------|-----------|
| 1.6.3 (unreleased) | 🧪 Development candidate |
| 1.6.2 | ✅ Current GitHub release |
| 1.6.0 – 1.6.1 | ⚠️ Superseded; install 1.6.2 |
| 1.5.2 | ⚠️ Upgrade recommended |
| 1.5.0 – 1.5.1 | ⚠️ Upgrade recommended |
| 1.3.0 – 1.4.x | ⚠️ Upgrade strongly recommended |
| < 1.3.0 | ❌ Unsupported |

The v1.6.3 development candidate includes deterministic pre-model signed-envelope staging,
the dedicated `/hooks/antenna` mapping with no legacy endpoint fallback,
Ed25519 sender signatures, exact message-ID
replay rejection, the envelope-marker guard (REF-400),
message freshness window (REF-402), relay temp-file hygiene (REF-403), self-ID
fallback removal (REF-404), constant-time plaintext identity-secret comparison
(REF-501), expired-bundle refusal (REF-601), plaintext bootstrap-bundle cleanup
(REF-603), Himalaya `From:`-address resolution (REF-616), legacy raw-secret
export non-TTY refusal (REF-605), gateway `hooks.token` preservation on setup
rerun (REF-901), and operator `tools.exec` preservation on setup rerun
(REF-903).

The release also includes explicit warned `plaintext-legacy` migration,
local Distribution Lists, and ClawReef-attested Listed Public Groups. For a
Public Group send, ClawReef verifies the signed sender envelope and active
membership, then signs and fans an ordinary Antenna message to the other active
members. ClawReef can read plaintext during fan-out, but discards the subject,
body, and raw envelope afterward. It retains only content-free replay and
delivery-audit metadata.

## Security-Relevant Design

Antenna's current security model is documented in [SKILL.md](SKILL.md#trust-model),
this policy, and the [User Guide](references/USER-GUIDE.md). The
[Relay Protocol FSD](references/ANTENNA-RELAY-FSD.md) is retained as a
historical v1.5.2 reference and does not define v1.6.3 ingress. The following
commitments are load-bearing and in scope for vulnerability reports:

- **Deterministic pre-model staging —** OpenClaw's built-in local hook-mapping
  transform writes `ctx.payload.message` to an exclusive private 0600 file
  before dispatch. The model receives only the safe path instruction, makes one
  shell-tool call, and never parses, encodes, copies, writes, or sees signed
  envelope content. There is no `/hooks/agent` fallback.
- **Layered trust in v1.6.3 —** HTTPS transport, hook bearer token, locally
  pinned Ed25519 sender public keys, exact message-ID replay rejection, peer
  allowlists (inbound and outbound), session allowlist (full keys only),
  envelope-marker guard, message-freshness window, rate limiting, and log
  sanitization. The explicitly selected `plaintext-legacy` compatibility mode
  still transmits a reusable identity secret and must not be mistaken for HMAC
  or signature authentication.
- **Layer A encrypted bootstrap —** peer onboarding uses `age`. Export streams bundle JSON directly into `age` with no plaintext temp file. Import decrypts to a temp file that is cleaned up on every exit path (normal return, validation failure, preview failure, write failure, `SIGINT`, `SIGTERM`). Expired bundles are refused by default; `--force-expired` is the disaster-recovery override. Legacy raw-secret export refuses non-TTY stdout.
- **Read-only bundle verification —** `antenna bundle verify <file>` decrypts a received bootstrap bundle in place and validates shape / endpoint URL / freshness without touching `antenna-peers.json` or `antenna-config.json`. Human and `--json` output never print the raw hooks token or identity secret, only presence booleans. Shared validation logic in `lib/bundles.sh` keeps `bundle verify` and `peers exchange import` in agreement on what "valid" means.
- **Self-identity is mandatory —** the sender refuses to run without `self_id` configured. There is no `$(hostname)` fallback.
- **Concurrency safety —** unique UUID-named 0600 staged files under a
  gateway-user-owned 0700 directory, fresh static hook sessions per delivery,
  and `flock`-based transaction locking around inbox and rate-limit state.
- **Setup is idempotent and conservative —** `antenna setup` reruns preserve an existing gateway `hooks.token` and preserve any operator-customized `tools.exec` overrides on the Antenna agent. Operators will not silently lose trust material by rerunning setup after a `clawhub update`.

## Known Security Considerations

These are openly acknowledged trade-offs and limitations of the current design. They are **not** vulnerabilities — they are intentional boundaries. Reports that rediscover them will be politely closed.

- **Sandbox off on the relay agent.** The Antenna agent runs with `sandbox: { mode: "off" }` because OpenClaw sandboxing silently clamps session visibility to `tree`, which breaks the deliver script's gateway RPC calls. Mitigations include deterministic pre-model staging, a one-shell-call policy, restrictive tool denial, peer/session allowlists, rate limits, marker/freshness guards, and strict staged-path validation. Operator-customized `tools.exec` remains an explicit local trust boundary and is preserved on setup reruns.
- **Secrets at rest.** Hooks tokens, Ed25519 private signing keys, exchange
  private keys, and any `plaintext-legacy` identity secrets are stored as
  plaintext files with restrictive permissions. No encryption at rest.
  `antenna status` audits the active credential type and permissions. If your
  host filesystem is untrusted, Antenna is not the right transport.
- **Email is convenience transport only.** The optional `--send-email` path for bootstrap bundles and public keys uses Himalaya to deliver already-encrypted (`age`) artifacts. Email is not part of the trust model; a compromised email account cannot impersonate a peer or read bundle contents without the recipient's `age` private key.
- **ClawReef has two bounded roles.** For ordinary pairing it is a discovery
  and invitation surface; ordinary peer-to-peer Antenna unicast does not
  traverse ClawReef. For Listed Public Groups it is the membership-verifying
  relay and can read plaintext while fanning it out. It does not retain the
  message content, store private age or Ed25519 signing keys, or make local
  peer/session trust decisions for ordinary unicast.
- **Untrusted input framing is advisory.** Relayed content is framed with a security notice so receiving agents treat it as external input, but enforcement ultimately depends on the receiving agent's own behavior. This is why the relay-agent itself is kept deliberately thin and non-interpreting.

For deeper architectural detail, see
[`references/ANTENNA-RELAY-FSD.md`](references/ANTENNA-RELAY-FSD.md),
[`references/ED25519-PROTOCOL-V1.md`](references/ED25519-PROTOCOL-V1.md), and
the [User Guide](references/USER-GUIDE.md).

## Out of Scope

The following are not Antenna vulnerabilities and should be reported elsewhere:

- Issues in OpenClaw core (gateway, agent runtime, session delivery) → [OpenClaw repo](https://github.com/openclaw/openclaw)
- Issues in ClawReef discovery / registry → `help@clawreef.io` with subject prefix `[ClawReef]`
- Issues in `age` / `age-keygen`, `himalaya`, `jq`, `curl`, `openssl`, `flock` → respective upstream projects
- Host-level compromise of a peer (e.g. an attacker with shell on your laptop) — Antenna's trust model assumes the local host is trusted by its operator
