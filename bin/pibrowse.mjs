#!/usr/bin/env node
// pibrowse: drive the pi-browser panel with one JSON op per call.
import { parseOp, OPS } from "../lib/protocol.mjs";
import { run, up, down } from "../lib/panel.mjs";

const VALUE_FLAGS = { "--url": String, "--size": String, "--width": Number, "--height": Number, "--zoom": Number };
const BOOL_FLAGS = ["--up", "--down", "--json", "--help", "-h"];

const HELP = `pibrowse: drive the native pi-browser panel

  pibrowse '<json op>'        run one op (or pipe it on stdin)
  pibrowse --up [--url URL]   start the panel (or re-show it), on URL once loaded
           --size card|medium|full   --width W --height H (page size, default 1280x800)
           --zoom N                  page zoom, applied when the panel starts
  pibrowse --down             quit the panel
  --json                      pretty-print the reply

ops: ${Object.keys(OPS).filter((o) => !OPS[o]["@cli"]).join(", ")}
  {"op":"snapshot","format":"text","nodes":40}
  {"op":"act","action":"click","ref":"e3"}
  actions: ${OPS.act.action.split("|").join(", ")}

PIBROWSE_STATE overrides the state dir (socket, log, profile id).`;

const flags = {};
const rest = [];
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (VALUE_FLAGS[a]) {
    flags[a.slice(2)] = VALUE_FLAGS[a](argv[++i]);
    if (Number.isNaN(flags[a.slice(2)])) exit({ error: { kind: "invalid", message: `${a} takes a number` } });
  }
  else if (BOOL_FLAGS.includes(a)) flags[a.replace(/^-+/, "")] = true;
  else if (a.startsWith("-")) exit({ error: { kind: "invalid", message: `unknown flag ${a}; try --help` } });
  else rest.push(a);
}

function exit(reply) {
  console.log(JSON.stringify(reply, null, flags.json ? 1 : 0));
  process.exit(reply.error ? 1 : 0);
}

async function readStdin() {
  if (process.stdin.isTTY) return "";
  const chunks = [];
  for await (const c of process.stdin) chunks.push(c);
  return Buffer.concat(chunks).toString().trim();
}

if (flags.help || flags.h) {
  console.log(HELP);
  process.exit(0);
}
if (flags.down) exit(await down());
if (flags.up) exit(await up(flags).then((ok) => ({ ok }), (e) => ({ error: { kind: "failed", message: e.message } })));

const raw = rest.join(" ") || (await readStdin());
if (!raw) {
  console.error("no op given; try: pibrowse --help");
  process.exit(2);
}
const parsed = parseOp(raw);
exit(parsed.error ? parsed : await run(parsed.op));
