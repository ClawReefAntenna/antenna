# Antenna OpenClaw plugin — development candidate

Inbound signed v2 delivery with Off / Dumb / Smart / Both content scanning.
Default: Dumb. Both runs Dumb first and only calls Smart after a pass.
Authentication, replay checks and receiver-selected existing destinations apply
in every mode. Ordinary approval and MCS holds remain independent.

This is the packaged inbound vertical slice, not a released replacement for
the legacy Antenna skill. Legacy sending, groups, setup/Doctor/uninstall,
native subscription destination qualification and whole-install migration
remain separate release work. No atomic session-incarnation or exactly-once
delivery guarantee is made.

## Install in an isolated OpenClaw instance

Requires Node supported by OpenClaw 2026.9.5+, Bash, jq and flock.
Package with `npm pack ./plugin`; install the resulting archive with
`openclaw plugins install /absolute/path/to/archive.tgz` using the intended
isolated OpenClaw state/config environment. Do not point qualification at
production state. The OpenClaw peer dependency supplies the public gateway SDK.

Prepare a JSON policy with:
- `schemaVersion: 2`, `receiver`, a private random `bearer` (at least 32 characters);
- `peers`: map of authenticated peer names to Ed25519 PEM `publicKey`,
  allowed `destinations` array and optional `mcs` override;
- `destinations`: receiver-approved name to existing `agent:...` session key;
- absolute, distinct `inboxFile` and `replayFile`;
- optional `mcs` (default dumb), `inbox` (default on), `maxBodyChars` (65536).

For a new absent entry, `antenna-plugin /path/openclaw.json init policy.json`
writes it **disabled**. If the native installer has already added an entry,
merge the policy into its config explicitly; init refuses to overwrite it.
Set the plugin enabled and allowlisted only in the intended isolated config,
then restart that gateway. Mode/selection edits also require a restart.
The local adapter uses the gateway's configured port and token authentication.
A non-string token reference must be resolved by OpenClaw before registration;
the standalone operator process requires a resolved local gateway token.

## Operator commands

All output is JSON, including escaped message bodies; never render decoded
message bodies as terminal commands, HTML or model instructions.

```text
antenna-plugin /path/openclaw.json status
antenna-plugin /path/openclaw.json mode off|dumb|smart|both [peer]
antenna-plugin /path/openclaw.json mode default peer
antenna-plugin /path/openclaw.json check profile.json
antenna-plugin /path/openclaw.json select profile.json
antenna-plugin /path/openclaw.json inbox list
antenna-plugin /path/openclaw.json inbox show ITEM_ID
antenna-plugin /path/openclaw.json inbox release ITEM_ID '["Awaiting approval","MCS flagged"]'
antenna-plugin /path/openclaw.json inbox discard ITEM_ID
antenna-plugin /path/openclaw.json inbox approve-ordinary
```

Status is offline. Check makes one bounded synthetic request, does not save or
activate anything, and makes no quality claim. Select checks and saves one
shared Smart/Both profile without changing mode or enabling the plugin.
No automatic retries, fallback, model downloads, scheduler or dashboard.

Profile fields: `baseUrl`, `model`, declared `locality`
(local/remote/unknown), `tokenParameter` (max_tokens/max_completion_tokens),
`jsonObject` boolean, `maxInputBytes` (1–65536), optional `strictSchema`
and `reasoningEffort`. Current adapter also caps serialized requests at
16 KiB and output at 1024 tokens; oversized input holds incomplete, never crops.
Optional `credentialRef` is exactly `{"env":"VARIABLE"}` or
`{"file":"/absolute/private/file"}`; file must be regular, private and bounded.
No credential value is copied into the profile. Credential rotation at the
same reference is supported.

Optional `configuredModel` resolves an explicit configured provider/model or
unambiguous alias from OpenClaw's explicit models configuration. Only
openai-completions providers are supported here; implicit catalogs and native
subscription credentials are not silently bridged. Supply the credential
reference explicitly. Resolution changes invalidate validation. Smart/Both
without a ready profile cannot be selected; later scanner failure holds
incomplete. Remote endpoints require HTTPS; loopback HTTP is supported.

## Explicit upgrade

Stop the isolated gateway before migration. Preview:
`antenna-plugin /path/openclaw.json migrate`; apply with `migrate --apply`.
Only recognized `schemaVersion:1, policyRevision:"combined-smart-v1"`
configuration maps global/peer smart to both. Version 2 is unchanged.
Unknown legacy layouts, including old array inboxes, require manual migration;
they are rejected rather than guessed at or discarded. Existing schema-2
inbox payloads and hold reasons are never rewritten by configuration migration.
Back up config/state before operator edits. No automatic rollback conversion.
