#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
PASS=0 FAIL=0
check() { local n="$1"; shift; if "$@"; then echo "PASS $n"; PASS=$((PASS+1)); else echo "FAIL $n"; FAIL=$((FAIL+1)); fi; }

mkdir -p "$TMP/runtime"
TMPDIR="$TMP/runtime" ROOT="$ROOT" node --input-type=module <<'JS'
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
const transform = (await import(pathToFileURL(path.join(process.env.ROOT,"hooks/antenna-stage.mjs")))).default;
const exact = "[ANTENNA_RELAY]\nsubject: em — dash\nuser: Zoë\n\nline one\nline two\n\n[/ANTENNA_RELAY]";
const action = transform({payload:{message:exact}});
const staged = action.message.split("\n")[1].slice(6);
if (!fs.readFileSync(staged).equals(Buffer.from(exact,"utf8"))) throw new Error("byte mismatch");
if (action.message.includes("em — dash") || action.message.includes("[ANTENNA_RELAY]")) throw new Error("prompt leak");
if (!/^hook:antenna:[0-9a-f-]{36}$/.test(action.sessionKey) || action.sessionKeySource!=="static") throw new Error("session");
if ((fs.statSync(staged).mode & 0o777)!==0o600 || (fs.statSync(path.dirname(staged)).mode & 0o777)!==0o700) throw new Error("mode");
fs.unlinkSync(staged);

const originalFsync=fs.fsyncSync;
fs.fsyncSync=()=>{throw new Error("fixture fsync failure")};
let failed=false;
try { transform({payload:{message:"will fail"}}); } catch { failed=true; }
fs.fsyncSync=originalFsync;
if (!failed) throw new Error("failure not surfaced");
const leftovers=fs.readdirSync(path.dirname(staged)).filter(n=>n.endsWith(".envelope"));
if (leftovers.length) throw new Error("partial file not cleaned");
JS
check "transform preserves UTF-8/LFs, hides content, uses private unique static session, and cleans failed writes" true

# Parallel processes must never collide, even while sharing one staging dir.
mkdir -p "$TMP/parallel"
for i in 1 2 3 4 5 6 7 8; do
  TMPDIR="$TMP/parallel" ROOT="$ROOT" N="$i" node --input-type=module >"$TMP/p.$i" <<'JS' &
import path from "node:path";
import { pathToFileURL } from "node:url";
const transform=(await import(pathToFileURL(path.join(process.env.ROOT,"hooks/antenna-stage.mjs")))).default;
const a=transform({payload:{message:`parallel-${process.env.N}—\n\n[/ANTENNA_RELAY]`}});
console.log(a.message.split("\n")[1].slice(6));
JS
done
wait
parallel_count="$(sort -u "$TMP"/p.* | wc -l)"
check "parallel transforms create eight unique files" test "$parallel_count" -eq 8
for i in 1 2 3 4 5 6 7 8; do
  p="$(cat "$TMP/p.$i")"
  check "parallel staged bytes $i" grep -Fqx "parallel-$i—" <(head -n1 "$p")
  rm -f -- "$p"
done

# Prune only stale owned regular Antenna files; never follow/remove a symlink.
TMPDIR="$TMP/prune" ROOT="$ROOT" node --input-type=module <<'JS'
import fs from "node:fs"; import os from "node:os"; import path from "node:path";
import {pathToFileURL} from "node:url";
const uid=process.getuid(), dir=path.join(os.tmpdir(),`antenna-relay-${uid}`);
fs.mkdirSync(dir,{recursive:true,mode:0o700}); fs.chmodSync(dir,0o700);
const stale=path.join(dir,"antenna-00000000-0000-4000-8000-000000000001.envelope");
const link=path.join(dir,"antenna-00000000-0000-4000-8000-000000000002.envelope");
const outside=path.join(os.tmpdir(),"outside-envelope");
fs.writeFileSync(stale,"stale",{mode:0o600}); fs.utimesSync(stale,new Date(0),new Date(0));
fs.writeFileSync(outside,"outside"); fs.symlinkSync(outside,link);
const transform=(await import(pathToFileURL(path.join(process.env.ROOT,"hooks/antenna-stage.mjs")))).default;
const a=transform({payload:{message:"fresh"}}); const fresh=a.message.split("\n")[1].slice(6);
if(fs.existsSync(stale)||!fs.lstatSync(link).isSymbolicLink()||fs.readFileSync(outside,"utf8")!=="outside") throw Error("unsafe prune");
fs.unlinkSync(link); fs.unlinkSync(outside); fs.unlinkSync(fresh);
JS
check "stale pruning removes only owned regular files and leaves symlink target untouched" true

SKILL_DIR="$ROOT"
source "$ROOT/lib/relay-policy.sh"
source "$ROOT/lib/hook-staging.sh"
GW="$TMP/openclaw.json"
mkdir -p "$TMP/hooks/transforms/custom"
cat >"$GW" <<'JSON'
{"hooks":{"transformsDir":"custom","mappings":[{"id":"foreign","match":{"path":"foreign"},"action":"wake","textTemplate":"keep"}]},"foreign":{"keep":true}}
JSON
DIR=""
check "relative transformsDir resolves beneath default transforms root" hook_staging_resolve_transforms_dir "$GW" DIR
check "relative transformsDir target is correct" test "$DIR" = "$TMP/hooks/transforms/custom"
TILDE_HOME="$TMP/tilde-home"
mkdir -p "$TILDE_HOME/.openclaw/hooks/transforms/nested"
printf '%s\n' '{"hooks":{"transformsDir":"~/.openclaw/hooks/transforms/nested"}}' > "$TILDE_HOME/.openclaw/openclaw.json"
TILDE_DIR=""
HOME="$TILDE_HOME" hook_staging_resolve_transforms_dir "$TILDE_HOME/.openclaw/openclaw.json" TILDE_DIR
check "tilde transformsDir resolves under the gateway default root" test "$TILDE_DIR" = "$TILDE_HOME/.openclaw/hooks/transforms/nested"
OUT="$TMP/out.json"
check "canonical mapping candidate builds" hook_staging_write_gateway_candidate "$GW" "$OUT"
check "mapping preserves unrelated entries and adds OpenClaw-required hook prefix" jq -e '
  .foreign.keep==true and (.hooks.mappings|map(.id)|index("foreign"))!=null
  and (.hooks.mappings|map(.id)|index("antenna-deterministic-staging"))!=null
  and (.hooks.allowedSessionKeyPrefixes|index("hook:"))!=null' "$OUT"
check "OpenClaw and Antenna namespaces pass prefix audit" bash -c '
  source "$1/lib/hook-staging.sh"
  [[ "$(hook_staging_session_prefix_audit "$2")" == pass\|* ]]' _ "$ROOT" "$OUT"
printf '%s\n' '{"hooks":{"allowedSessionKeyPrefixes":["hook:antenna:"]}}' > "$TMP/narrow-only.json"
check "8.1 narrow-only prefix is diagnosed before gateway startup" bash -c '
  source "$1/lib/hook-staging.sh"
  [[ "$(hook_staging_session_prefix_audit "$2")" == fail\|OpenClaw* ]]' _ "$ROOT" "$TMP/narrow-only.json"
jq '.hooks.mappings += [{"id":"collision","match":{"path":"/antenna/"},"action":"wake"}]' "$GW" >"$TMP/conflict.json"
if hook_staging_write_gateway_candidate "$TMP/conflict.json" "$TMP/nope" 2>/dev/null; then false; else true; fi
check "conflicting /hooks/antenna path refuses" test ! -e "$TMP/nope"

# Conservative uninstall keeps a customized mapping and its transform intact.
CU="$TMP/custom-uninstall"; CUS="$CU/skill"; CUH="$CU/home"; CUG="$CUH/.openclaw/openclaw.json"
mkdir -p "$CUS/scripts" "$CUS/lib/relay-policy/agent" "$CUS/hooks" "$CUH/.openclaw/hooks/transforms"
cp "$ROOT/scripts/antenna-uninstall.sh" "$CUS/scripts/"
cp "$ROOT/lib/relay-policy.sh" "$ROOT/lib/hook-staging.sh" "$CUS/lib/"
cp "$ROOT/lib/relay-policy/manifest.sha256" "$CUS/lib/relay-policy/"
cp "$ROOT/lib/relay-policy/agent/AGENTS.md" "$CUS/lib/relay-policy/agent/"
cp "$ROOT/hooks/antenna-stage.mjs" "$CUS/hooks/"
cp "$ROOT/hooks/antenna-stage.mjs" "$CUH/.openclaw/hooks/transforms/"
cat >"$CUG" <<'JSON'
{"agents":{"entries":{"main":{},"antenna":{"name":"Antenna Relay"}}},"hooks":{"allowedAgentIds":["main","antenna"],"allowedSessionKeyPrefixes":["hook:","foreign:"],"mappings":[{"id":"antenna-deterministic-staging","match":{"path":"antenna"},"action":"agent","agentId":"antenna","wakeMode":"now","name":"Operator Customized Antenna","sessionKey":"hook:antenna","deliver":false,"allowUnsafeExternalContent":false,"transform":{"module":"antenna-stage.mjs","export":"default"}}]}}
JSON
HOME="$CUH" USER=fixture bash "$CUS/scripts/antenna-uninstall.sh" --yes --gateway "$CUG" >/dev/null
check "uninstall preserves customized /hooks/antenna mapping" jq -e '(.hooks.mappings|length)==1 and .hooks.mappings[0].name=="Operator Customized Antenna"' "$CUG"
check "uninstall preserves transform referenced by customized mapping" cmp -s "$ROOT/hooks/antenna-stage.mjs" "$CUH/.openclaw/hooks/transforms/antenna-stage.mjs"
check "uninstall preserves shared hook prefix and unrelated prefix" jq -e '(.hooks.allowedSessionKeyPrefixes|index("hook:"))!=null and (.hooks.allowedSessionKeyPrefixes|index("foreign:"))!=null' "$CUG"

check "sender and probe post only to dedicated endpoint" bash -c '
  ! rg -n "POST .*hooks/agent" "$1/scripts/antenna-send.sh" "$1/bin/antenna.sh" >/dev/null &&
  rg -n "POST .*hooks/antenna" "$1/scripts/antenna-send.sh" "$1/bin/antenna.sh" >/dev/null' _ "$ROOT"
check "relay policy mechanically rejects raw envelopes and permits one shell call" bash -c '
  rg -q "Rejected: invalid staged-file instruction" "$1/agent/AGENTS.md" &&
  rg -q "Exactly one tool call" "$1/agent/AGENTS.md" &&
  rg -q "Never use .write" "$1/agent/AGENTS.md"' _ "$ROOT"

# If verification fails after the atomic hard-link install, remove only the
# inode this installer created; do not leave an unverified transform behind.
check "failed post-install verification removes the just-installed transform" bash -c '
  set -euo pipefail
  root="$1"; case_root="$2"; gateway="$case_root/openclaw.json"
  mkdir -p "$case_root/hooks/transforms"
  printf "%s\n" "{}" > "$gateway"
  SKILL_DIR="$root"
  source "$root/lib/relay-policy.sh"
  source "$root/lib/hook-staging.sh"
  hook_staging_transform_audit() {
    if [[ -e "$1" ]]; then printf "fail|forced post-install audit failure\n"
    else printf "missing|transform absent\n"
    fi
  }
  if hook_staging_install_transform "$gateway"; then exit 1; fi
  [[ ! -e "$case_root/hooks/transforms/antenna-stage.mjs" ]]
' _ "$ROOT" "$TMP/post-audit-failure"

echo "SUMMARY $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
