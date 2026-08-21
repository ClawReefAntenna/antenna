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
| 1.6.0 | ✅ Current stable |
| 1.5.2 | ⚠️ Upgrade recommended |
| 1.5.0 – 1.5.1 | ⚠️ Upgrade recommended |
| 1.3.0 – 1.4.x | ⚠️ Upgrade strongly recommended |
| < 1.3.0 | ❌ Unsupported |

The v1.6.0 release includes Ed25519 sender signatures, exact message-ID
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

Antenna's full security model is documented in the [Relay Protocol FSD](references/ANTENNA-RELAY-FSD.md), the [User Guide](references/USER-GUIDE.md), and the [SKILL.md Trust Model](SKILL.md#trust-model). The following commitments are load-bearing and in scope for vulnerability reports:

- **Script-first relay —** the relay agent is a courier that runs deterministic bash scripts. All envelope parsing, validation, formatting, and logging is done by `scripts/antenna-relay.sh` and friends. The LLM never parses, encodes, transforms, or modifies relayed content.
- **Layered trust in v1.6.0 —** HTTPS transport, hook bearer token, locally
  pinned Ed25519 sender public keys, exact message-ID replay rejection, peer
  allowlists (inbound and outbound), session allowlist (full keys only),
  envelope-marker guard, message-freshness window, rate limiting, and log
  sanitization. The explicitly selected `plaintext-legacy` compatibility mode
  still transmits a reusable identity secret and must not be mistaken for HMAC
  or signature authentication.
- **Layer A encrypted bootstrap —** peer onboarding uses `age`. Export streams bundle JSON directly into `age` with no plaintext temp file. Import decrypts to a temp file that is cleaned up on every exit path (normal return, validation failure, preview failure, write failure, `SIGINT`, `SIGTERM`). Expired bundles are refused by default; `--force-expired` is the disaster-recovery override. Legacy raw-secret export refuses non-TTY stdout.
- **Read-only bundle verification —** `antenna bundle verify <file>` decrypts a received bootstrap bundle in place and validates shape / endpoint URL / freshness without touching `antenna-peers.json` or `antenna-config.json`. Human and `--json` output never print the raw hooks token or identity secret, only presence booleans. Shared validation logic in `lib/bundles.sh` keeps `bundle verify` and `peers exchange import` in agreement on what "valid" means.
- **Self-identity is mandatory —** the sender refuses to run without `self_id` configured. There is no `$(hostname)` fallback.
- **Concurrency safety —** unique per-message relay temp files under `/tmp/antenna-relay/` (`umask 077`, `chmod 0600`, shredded before `unlink`), `flock`-based transaction locking around inbox and rate-limit state mutations.
- **Setup is idempotent and conservative —** `antenna setup` reruns preserve an existing gateway `hooks.token` and preserve any operator-customized `tools.exec` overrides on the Antenna agent. Operators will not silently lose trust material by rerunning setup after a `clawhub update`.

## Known Security Considerations

These are openly acknowledged trade-offs and limitations of the current design. They are **not** vulnerabilities — they are intentional boundaries. Reports that rediscover them will be politely closed.

- **Sandbox off on the relay agent.** The Antenna agent runs with `sandbox: { mode: "off" }` because OpenClaw sandboxing silently clamps session visibility to `tree`, which breaks the deliver script's gateway RPC calls. The mitigations are: a restrictive `tools.deny` list on the agent (blocking web, browser, image, cron, memory tools), peer authentication, peer and session allowlists, rate limiting, envelope-marker and freshness guards, and the script-first relay design that keeps the LLM out of the content path. Default advice is also **not** to set `tools.exec.security` or `tools.exec.ask` on the Antenna agent — explicit exec overrides have been shown to cause silent relay failure. Operators who intentionally customize `tools.exec` are on their own trust boundary; setup reruns now preserve those overrides (REF-903) so we don't clobber an informed choice.
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
