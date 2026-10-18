#!/usr/bin/env node
// End-to-end check of the core paths: the real CLI drives a real panel against
// demo/serve.mjs, in its own state dir so a panel pi is using is left alone.
//   make test
import { execFile, spawn } from "node:child_process";
import fs from "node:fs";

const STATE = "/tmp/pibrowse-test";
const PORT = 8799;
const URL_ = `http://127.0.0.1:${PORT}/`;
for (const f of ["panel.sock", "panel.log"]) fs.rmSync(`${STATE}/${f}`, { force: true });

const env = { ...process.env, PIBROWSE_STATE: STATE };
const pibrowse = (...args) =>
  new Promise((resolve) =>
    execFile("bin/pibrowse.mjs", args.map((a) => (typeof a === "string" ? a : JSON.stringify(a))), { env },
      (err, stdout) => resolve({ code: err?.code ?? 0, ...JSON.parse(stdout) })));
const ok = async (op) => {
  const r = await pibrowse(op);
  if (!r.ok) throw new Error(`${JSON.stringify(op)} -> ${JSON.stringify(r)}`);
  return r.ok;
};
const value = async (fn) => (await ok({ op: "eval", function: fn })).value;
const snapshot = async () => (await ok({ op: "snapshot", format: "text" })).text;
const refOf = (text, line) => text.split("\n").find((l) => l.includes(line))?.match(/\[(e\d+)\]/)?.[1];

let failures = 0;
const check = (cond, what) => {
  console.log(`${cond ? "ok  " : "FAIL"} ${what}`);
  if (!cond) failures++;
};

const demo = spawn(process.execPath, ["demo/serve.mjs"], { env: { ...env, DEMO_PORT: String(PORT) }, stdio: "ignore" });
await new Promise((r) => setTimeout(r, 300));
let pid;
try {
  const up = await pibrowse("--up", "--url", URL_);
  pid = up.ok?.pid;
  check(up.ok?.url === URL_, "--up --url answers once the page loaded");

  const state = await ok({ op: "state" });
  check(state.url === URL_ && state.width === 1280 && state.loading === false && state.shown, "state reports the page");

  let text = await snapshot();
  const name = refOf(text, 'textbox "Your name"');
  check(name && refOf(text, 'button "increase"') && !text.includes("Confirm"),
    "snapshot has refs, reaches shadow DOM, prunes the closed modal");

  await ok({ op: "act", action: "fill", ref: name, text: "Ada" });
  await ok({ op: "act", action: "fill", ref: name, text: "Grace" });
  check(await value("() => document.getElementById('name').value") === "Grace", "fill replaces the field's value");

  await ok({ op: "act", action: "press", ref: name, keys: ["Backspace", "y"] });
  check(await value("() => document.getElementById('name').value") === "Gracy", "press sends named keys and characters");

  await ok({ op: "act", action: "select", ref: refOf(text, 'combobox "Favourite language"'), text: "rust" });
  await ok({ op: "act", action: "check", ref: refOf(text, 'checkbox "I am watching') });
  await ok({ op: "act", action: "click", ref: refOf(text, 'button "Submit form"') });
  check(await value("document.getElementById('out').textContent") === "Hello Gracy, you like rust. (submitted)"
    && (await value("document.getElementById('log').textContent")).includes("isTrusted=true"),
    "select, check and a trusted click submit the form");

  await ok({ op: "act", action: "click", ref: refOf(text, 'button "increase"') });
  check(await value("() => document.getElementById('widget').shadowRoot.getElementById('val').textContent") === "1",
    "click inside shadow DOM");

  await ok({ op: "act", action: "click", ref: refOf(text, 'button "Open modal"') });
  text = await snapshot();
  await ok({ op: "act", action: "click", ref: refOf(text, 'button "Confirm"') });
  check(await value("document.getElementById('out').textContent") === "Modal confirmed", "modal opens, shows in snapshot, confirms");

  check(JSON.stringify(await value("[1, 2].map((x) => x * 2)")) === "[2,4]", "eval runs an expression containing an arrow");

  const bad = await pibrowse({ op: "act", action: "fill", ref: name });
  const unknown = await pibrowse({ op: "nope" });
  const stale = await pibrowse({ op: "act", action: "click", ref: "e999" });
  check(bad.code === 1 && bad.error.kind === "invalid" && unknown.error.kind === "invalid" && stale.error.kind === "not_found",
    "bad ops answer invalid, a stale ref answers not_found");
} catch (e) {
  check(false, e.message);
} finally {
  const down = await pibrowse("--down");
  await new Promise((r) => setTimeout(r, 500));
  let alive = false;
  try { process.kill(pid, 0); alive = true; } catch {}
  check(down.ok?.stopped && !alive && !fs.existsSync(`${STATE}/panel.sock`), "--down quits the panel and removes its socket");
  demo.kill();
}
console.log(failures ? `${failures} failed` : "all passed");
process.exit(failures ? 1 : 0);
