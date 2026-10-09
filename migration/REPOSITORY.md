# Antenna migration kit — v1.6.9

Move a relay installation running **v1.6.3–v1.6.7** to native Antenna while preserving
identity, permissions and unresolved held work. The kit stages the conversion,
retires the old relay on a stopped host and retains private recovery copies.
Remote peers need Ed25519 signing; see the guide for fresh unsigned self identities.
Native v1.6.8 and later use the normal update path.

[Download the kit](https://github.com/ClawReefAntenna/antenna-migration/releases/download/v1.6.9/antenna-migration-1.6.9.tgz) · [SHA256SUMS](https://github.com/ClawReefAntenna/antenna-migration/releases/download/v1.6.9/SHA256SUMS)

Start with the [migration guide](migration/README.md): rehearse on an isolated
copy, review the plan, then cut over with the gateway and Antenna writers stopped.
The native plugin and companion are separate downloads from
[Antenna for OpenClaw v1.6.9](https://github.com/ClawReefAntenna/antenna-openclaw/releases/tag/v1.6.9).

This repository contains conversion and retirement tools and their dependencies,
not a legacy installer or relay starter. License: [MIT](LICENSE).
