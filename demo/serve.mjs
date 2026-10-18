#!/usr/bin/env node
// A tiny demo site for watching pi-browser work. Pure stdlib, no deps.
//   node demo/serve.mjs          -> http://127.0.0.1:8787
import http from "node:http";

const PAGE = `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<title>pi-browser demo</title>
<style>
  :root{--bg:#0f1115;--fg:#e6e6e6;--mut:#8b93a1;--acc:#6ea8fe;--ok:#4ade80;--warn:#fbbf24}
  *{box-sizing:border-box}
  body{margin:0;font:15px/1.55 ui-sans-serif,-apple-system,Segoe UI,Roboto,sans-serif;
       background:var(--bg);color:var(--fg);padding:40px 24px}
  main{max-width:760px;margin:0 auto}
  h1{font-size:26px;margin:0 0 4px}
  p.sub{color:var(--mut);margin:0 0 28px}
  .card{background:#161a21;border:1px solid #242a34;border-radius:12px;padding:20px;margin:0 0 16px}
  label{display:block;font-size:13px;color:var(--mut);margin:0 0 6px}
  input,select,textarea{width:100%;background:#0f1319;color:var(--fg);border:1px solid #2b3341;
       border-radius:8px;padding:9px 11px;font:inherit}
  input:focus,select:focus,textarea:focus{outline:2px solid var(--acc);outline-offset:1px}
  button{background:var(--acc);color:#08111f;border:0;border-radius:8px;padding:10px 18px;
       font:inherit;font-weight:600;cursor:pointer}
  button.ghost{background:#20262f;color:var(--fg)}
  .row{display:flex;gap:10px;align-items:center}
  .row > *{flex:1}
  .row > button{flex:0 0 auto}
  #log{font:13px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--ok);
       background:#0b0e13;border:1px solid #1d232c;border-radius:8px;padding:12px;
       min-height:120px;white-space:pre-wrap;max-height:260px;overflow:auto}
  .badge{display:inline-block;font-size:11px;padding:2px 8px;border-radius:99px;
       background:#1e2632;color:var(--mut);margin-left:8px;vertical-align:middle}
  #out{font-size:20px;font-weight:600;color:var(--warn);min-height:28px}
  .chk{display:flex;gap:8px;align-items:center;color:var(--mut);font-size:14px}
  .chk input{width:auto}
  .hidden{display:none}
</style></head>
<body><main>
  <h1>pi-browser demo <span class="badge" id="clock">--:--:--</span></h1>
  <p class="sub">A page with a form, a select, checkboxes, a modal and a shadow-DOM widget.
     Everything is instrumented: watch the log fill as the agent acts.</p>

  <div class="card">
    <label for="name">Your name</label>
    <input id="name" name="name" placeholder="type something">
    <div style="height:12px"></div>
    <label for="lang">Favourite language</label>
    <select id="lang" name="lang">
      <option value="">choose…</option>
      <option value="rust">Rust</option>
      <option value="swift">Swift</option>
      <option value="python">Python</option>
      <option value="js">JavaScript</option>
    </select>
    <div style="height:12px"></div>
    <label class="chk"><input type="checkbox" id="agree"> I am watching a robot use my browser</label>
    <div style="height:16px"></div>
    <div class="row">
      <button id="submit">Submit form</button>
      <button id="modal-btn" class="ghost">Open modal</button>
      <button id="reset" class="ghost">Reset</button>
    </div>
  </div>

  <div class="card">
    <label>Result</label>
    <div id="out">—</div>
  </div>

  <div class="card">
    <label>Event log</label>
    <div id="log"></div>
  </div>

  <div class="card">
    <label>Shadow-DOM widget (inside a custom element)</label>
    <shadow-counter id="widget"></shadow-counter>
  </div>

  <dialog id="dlg" style="background:#161a21;color:#e6e6e6;border:1px solid #2b3341;border-radius:12px;padding:24px">
    <h2 style="margin:0 0 8px;font-size:18px">A modal</h2>
    <p style="color:#8b93a1;margin:0 0 16px">Only reachable while open — good test for snapshot pruning.</p>
    <div class="row">
      <button id="modal-ok">Confirm</button>
      <button id="modal-cancel" class="ghost">Cancel</button>
    </div>
  </dialog>
</main>
<script>
  const log = (m) => {
    const el = document.getElementById('log');
    const t = new Date().toLocaleTimeString();
    el.textContent += \`[\${t}] \${m}\\n\`;
    el.scrollTop = el.scrollHeight;
  };
  setInterval(() => {
    document.getElementById('clock').textContent = new Date().toLocaleTimeString();
  }, 1000);

  const name = document.getElementById('name');
  const lang = document.getElementById('lang');
  const agree = document.getElementById('agree');
  const out = document.getElementById('out');
  const dlg = document.getElementById('dlg');

  for (const ev of ['input', 'change']) {
    name.addEventListener(ev, () => log(\`name \${ev}: "\${name.value}"\`));
    lang.addEventListener(ev, () => log(\`lang \${ev}: "\${lang.value}"\`));
    agree.addEventListener(ev, () => log(\`agree \${ev}: \${agree.checked}\`));
  }
  document.addEventListener('click', (e) => {
    const id = e.target.id || e.target.closest('[id]')?.id || e.target.localName;
    log(\`click on \${id} (isTrusted=\${e.isTrusted})\`);
  }, true);

  document.getElementById('submit').addEventListener('click', () => {
    const missing = [];
    if (!name.value.trim()) missing.push('name');
    if (!lang.value) missing.push('language');
    if (!agree.checked) missing.push('checkbox');
    out.textContent = missing.length
      ? 'Missing: ' + missing.join(', ')
      : \`Hello \${name.value.trim()}, you like \${lang.value}. (submitted)\`;
    log(missing.length ? 'submit rejected' : 'submit accepted');
  });

  document.getElementById('reset').addEventListener('click', () => {
    name.value = ''; lang.value = ''; agree.checked = false; out.textContent = '—';
    log('reset');
  });

  document.getElementById('modal-btn').addEventListener('click', () => {
    dlg.showModal(); log('modal opened');
  });
  document.getElementById('modal-ok').addEventListener('click', () => {
    dlg.close(); out.textContent = 'Modal confirmed'; log('modal confirmed');
  });
  document.getElementById('modal-cancel').addEventListener('click', () => {
    dlg.close(); log('modal cancelled');
  });

  customElements.define('shadow-counter', class extends HTMLElement {
    constructor() {
      super();
      const root = this.attachShadow({ mode: 'open' });
      root.innerHTML = \`
        <style>
          .box{display:flex;gap:12px;align-items:center;background:#0f1319;
               border:1px solid #2b3341;border-radius:10px;padding:14px}
          button{background:#20262f;color:#e6e6e6;border:1px solid #2b3341;border-radius:8px;
                 padding:6px 14px;font:inherit;cursor:pointer}
          span{font:600 18px ui-monospace,monospace;min-width:2ch;text-align:center;color:#6ea8fe}
        </style>
        <div class="box">
          <button part="dec" id="dec" aria-label="decrease">−</button>
          <span id="val" role="status" aria-live="polite">0</span>
          <button part="inc" id="inc" aria-label="increase">+</button>
        </div>\`;
      this._v = 0;
      root.getElementById('inc').addEventListener('click', () => this._set(this._v + 1));
      root.getElementById('dec').addEventListener('click', () => this._set(this._v - 1));
    }
    _set(v) { this._v = v; this.shadowRoot.getElementById('val').textContent = String(v); log('counter -> ' + v); }
  });
</script></body></html>`;

const server = http.createServer((req, res) => {
  if (req.url === "/favicon.ico") {
    res.writeHead(204).end();
    return;
  }
  res.writeHead(200, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" });
  res.end(PAGE);
});

const PORT = Number(process.env.DEMO_PORT || 8787);
server.listen(PORT, "127.0.0.1", () => {
  console.log(`demo site: http://127.0.0.1:${PORT}`);
});
