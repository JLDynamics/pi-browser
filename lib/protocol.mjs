// The op protocol: protocol.json is the one table of ops and their fields, read
// here to validate ops at the CLI boundary and by the panel at startup to check
// it handles exactly these ops.
//
// A field spec is a type (`string`, `number`, `keys` = a chord or a list of
// chords, `events` = a list of objects) or a choice (`a|b|c`), with a trailing
// `?` when optional. `@requires` names the fields each value of a choice needs.
import fs from "node:fs";

export const OPS = JSON.parse(fs.readFileSync(new URL("./protocol.json", import.meta.url), "utf8")).ops;

const TYPES = {
  string: (v) => typeof v === "string",
  number: (v) => typeof v === "number" && Number.isFinite(v),
  keys: (v) => (Array.isArray(v) ? v.length > 0 && v.every((k) => typeof k === "string" && k) : typeof v === "string" && v !== ""),
  events: (v) => Array.isArray(v) && v.every((e) => e && typeof e === "object" && !Array.isArray(e)),
};

const invalid = (message) => ({ error: { kind: "invalid", message } });

function check(name, field, spec, value) {
  const type = spec.replace(/\?$/, "");
  if (TYPES[type]) {
    return TYPES[type](value) ? null : `${name}: \`${field}\` must be ${type === "keys" ? "a key chord or a list of chords" : type === "events" ? "a list of event objects" : "a " + type}`;
  }
  const choices = type.split("|");
  return choices.includes(value) ? null : `${name}: \`${field}\` is ${choices.slice(0, -1).join(", ")} or ${choices.at(-1)}`;
}

/** Parse raw JSON text into a validated op, or an `{error}` envelope. */
export function parseOp(text) {
  let op;
  try {
    op = JSON.parse(text);
  } catch (e) {
    return invalid("malformed JSON: " + e.message);
  }
  if (!op || typeof op !== "object" || Array.isArray(op)) return invalid("a browser op is a JSON object");
  const fields = OPS[op.op];
  if (!fields) return invalid(`unknown web call ${JSON.stringify(op.op ?? null)}`);
  for (const [field, spec] of Object.entries(fields)) {
    if (field.startsWith("@")) continue;
    if (op[field] === undefined) {
      if (!spec.endsWith("?")) return invalid(`${op.op}: \`${field}\` is required`);
      continue;
    }
    const problem = check(op.op, field, spec, op[field]);
    if (problem) return invalid(problem);
  }
  for (const [field, byValue] of Object.entries(fields["@requires"] ?? {})) {
    for (const need of byValue[op[field]] ?? []) {
      if (op[need] === undefined) return invalid(`${op.op} ${op[field]}: \`${need}\` is required`);
    }
  }
  return { op };
}
