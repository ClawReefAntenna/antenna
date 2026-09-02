// antenna-hook-transform: id=antenna-deterministic-staging v=1
// OpenClaw hook-mapping transform: stage the exact parsed message string before
// any model sees it, then expose only a private file reference to the relay.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";

const MAX_ENVELOPE_BYTES = 1048576;
const STALE_AFTER_MS = 60 * 60 * 1000;
const FILE_RE = /^antenna-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.envelope$/;

function stagingDirectory() {
  const uid = typeof process.getuid === "function" ? process.getuid() : null;
  if (!Number.isSafeInteger(uid) || uid < 0) throw new Error("Antenna staging requires a numeric gateway-user uid");
  const dir = path.resolve(os.tmpdir(), `antenna-relay-${uid}`);
  if (!path.isAbsolute(dir)) throw new Error("Antenna staging requires an absolute temporary path");
  if (!/^[A-Za-z0-9_./-]+$/.test(dir)) throw new Error("Antenna staging path is not shell-safe");
  return { dir, uid };
}

function ensurePrivateDirectory(dir, uid) {
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const stat = fs.lstatSync(dir);
  if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== uid) {
    throw new Error("Antenna staging directory is not a gateway-user-owned regular directory");
  }
  if ((stat.mode & 0o077) !== 0) fs.chmodSync(dir, 0o700);
}

function pruneOwnedStaleFiles(dir, uid, now) {
  for (const name of fs.readdirSync(dir)) {
    if (!FILE_RE.test(name)) continue;
    const candidate = path.join(dir, name);
    let stat;
    try { stat = fs.lstatSync(candidate); } catch { continue; }
    if (!stat.isFile() || stat.isSymbolicLink() || stat.uid !== uid) continue;
    if (now - stat.mtimeMs <= STALE_AFTER_MS) continue;
    try { fs.unlinkSync(candidate); } catch { /* best-effort safe pruning */ }
  }
}

export default function antennaStage(ctx) {
  const message = ctx?.payload?.message;
  if (typeof message !== "string") throw new Error("Antenna hook payload.message must be a string");
  const bytes = Buffer.from(message, "utf8");
  if (bytes.length === 0 || bytes.length > MAX_ENVELOPE_BYTES || message.includes("\0")) {
    throw new Error("Antenna hook message is empty, oversized, or contains NUL");
  }

  const { dir, uid } = stagingDirectory();
  ensurePrivateDirectory(dir, uid);
  pruneOwnedStaleFiles(dir, uid, Date.now());

  const uuid = randomUUID();
  const stagedPath = path.join(dir, `antenna-${uuid}.envelope`);
  const flags = fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL |
    (fs.constants.O_NOFOLLOW ?? 0);
  const fd = fs.openSync(stagedPath, flags, 0o600);
  try {
    fs.writeFileSync(fd, bytes);
    fs.fchmodSync(fd, 0o600);
    fs.fsyncSync(fd);
  } catch (error) {
    try { fs.closeSync(fd); } catch { /* preserve the original failure */ }
    try { fs.unlinkSync(stagedPath); } catch { /* best effort: never dispatch it */ }
    throw error;
  } finally {
    try { fs.closeSync(fd); } catch { /* already closed on the failure path */ }
  }

  return {
    kind: "agent",
    message: `[ANTENNA_STAGED_FILE_V1]\npath: ${stagedPath}\nRun the one permitted relay shell call for this staged path.`,
    agentId: "antenna",
    sessionKey: `hook:antenna:${uuid}`,
    sessionKeySource: "static",
    wakeMode: "now",
    deliver: false,
    allowUnsafeExternalContent: false,
  };
}
