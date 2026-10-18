// The panel client: find, start and stop the native panel, and exchange one
// JSON line per op over its Unix socket. Everything about browsing lives in
// native/; this module only knows the process and the socket.
import fs from "node:fs";
import net from "node:net";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const STATE = process.env.PIBROWSE_STATE || path.join(ROOT, "state");
const SOCKET = path.join(STATE, "panel.sock");
const BINARY = path.join(ROOT, "native", "panel");
const LOG = path.join(STATE, "panel.log");

const fail = (message) => ({ error: { kind: "failed", message } });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Send one op and resolve its reply envelope. Never throws. */
export function send(op, timeout = 40000) {
  return new Promise((resolve) => {
    const sock = net.createConnection(SOCKET);
    let buf = "";
    const finish = (v) => {
      clearTimeout(timer);
      sock.destroy();
      resolve(v);
    };
    const timer = setTimeout(() => finish(fail(`panel: no answer in ${timeout} ms`)), timeout);
    sock.setEncoding("utf8");
    sock.on("connect", () => sock.write(JSON.stringify(op) + "\n"));
    sock.on("data", (chunk) => {
      buf += chunk;
      const nl = buf.indexOf("\n");
      if (nl < 0) return;
      try {
        finish(JSON.parse(buf.slice(0, nl)));
      } catch {
        finish(fail("panel: malformed reply " + buf.slice(0, 200)));
      }
    });
    sock.on("error", (e) => finish(fail("panel: " + e.message)));
    sock.on("close", () => finish(fail("panel: connection closed with no reply")));
  });
}

const ping = async () => (await send({ op: "ping" }, 2000)).ok;

/** Start the panel unless one already answers. Idempotent. */
async function ensure({ zoom } = {}) {
  const live = await ping();
  if (live) return { pid: live.pid, reused: true };
  if (!fs.existsSync(BINARY)) throw new Error(`no panel binary at ${BINARY}; run make`);
  fs.mkdirSync(STATE, { recursive: true });
  const out = fs.openSync(LOG, "a");
  const args = ["--state", STATE, ...(zoom ? ["--zoom", String(zoom)] : [])];
  const child = spawn(BINARY, args, { detached: true, stdio: ["ignore", out, out] });
  child.unref();
  fs.closeSync(out);
  for (const deadline = Date.now() + 15000; Date.now() < deadline; await sleep(120)) {
    // A panel that finds another one already serving exits; that one answers.
    const up = await ping();
    if (up) return { pid: up.pid, reused: up.pid !== child.pid };
    if (child.exitCode !== null && child.exitCode !== 0) break;
  }
  throw new Error("panel did not come up; see " + LOG);
}

/** Bring the panel up and on screen, on `url` once it has loaded. */
export async function up({ url, size, zoom, width, height } = {}) {
  const started = await ensure({ zoom });
  if (width || height) await send({ op: "viewport", width: width ?? 1280, height: height ?? 800 });
  if (size) await send({ op: "resize", size });
  const shown = await send({ op: "show", url }, 60000);
  if (shown.error) throw new Error(shown.error.message);
  return { ...started, url: shown.ok.url };
}

/** Quit the panel if one is running, and return once it has gone. */
export async function down() {
  const r = await send({ op: "quit" }, 3000);
  // The panel answers before it exits; an `--up` racing its exit would reuse it.
  for (const deadline = Date.now() + 3000; r.ok && (await ping()) && Date.now() < deadline; ) await sleep(50);
  return { ok: { stopped: !!r.ok } };
}

/** Run one validated op, starting the panel first if needed. */
export async function run(op) {
  try {
    if (op.op === "up") return { ok: await up(op) };
    await ensure();
    // A reply waits on the op's own timeout (seconds), so wait a little longer.
    return await send(op, Math.max(40000, (op.timeout ?? 20) * 1000 + 10000));
  } catch (e) {
    return fail(e.message);
  }
}
