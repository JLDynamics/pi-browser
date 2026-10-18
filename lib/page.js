// Injected into every page as a WKUserScript (main frame only).
//
// This is Tern's own injected script, recovered from the Tern 0.9.3 binary
// (`globalThis.__tern` at file offset 122281150) and adapted only in that it is
// installed once as `globalThis.__pi(op)` instead of being re-evaluated per call.
// The ref registry, the accessibility walk, the error kinds and the text format
// are byte-for-byte the same algorithm, so `snapshot` and `act` answer the same
// shapes and the same error strings as `tern browser`.
//
// The host calls `__pi(op)` for `act` and `snapshot` only. Everything else
// (navigation, viewport, capture, events, dialogs) is native and never runs here.
(() => {
  // Installed once per document. The host re-evaluates this script before each
  // call (a user script does not run on the initial empty document), and that
  // must not reset the ref counter.
  if (!globalThis.__pi) globalThis.__pi = function (op) {
    "use strict";
    const store = globalThis.__piStore ??= {refs: new Map(), ids: new WeakMap(), next: 1};
    store.notes ??= new Map();
    const clean = value => String(value ?? "").replace(/\s+/g, " ").trim();
    const clip = value => clean(value).slice(0, 120);
    const failure = (kind, message) => ({error: {kind, message}});

    // A ref must outlive the node it was handed out for. A page that renders its
    // own DOM throws the node away the moment its state changes — Wikipedia's
    // search box is rebuilt as soon as it is focused, so the ref taken before
    // the click names a node that is already gone — and it does not put the
    // replacement back where the old one was, it re-renders the subtree around
    // it somewhere else. A WeakRef cannot recover from that: once the node dies
    // there is nothing left to deref. So a ref also records what the node
    // *was*, and `lookup` uses that to find the node that replaced it.
    const fingerprint = element => {
      const attr = name => element.getAttribute(name) ?? "";
      const named = attr("type") + attr("name") + attr("aria-label")
        + attr("placeholder") + attr("title") + attr("href");
      // A form control is identified by its attributes; anything else — a
      // button, a link, a listbox row — is identified by what it says.
      return [element.localName, attr("type"), attr("name"), attr("aria-label"),
        attr("placeholder"), attr("title"), attr("href"),
        named ? "" : clip(element.textContent)].join("\u0000");
    };
    const ref = element => {
      let id = store.ids.get(element);
      if (!id) {
        id = "e" + store.next++;
        store.ids.set(element, id);
        store.refs.set(id, new WeakRef(element));
        // A shadow root is not reachable from `document`, so only nodes the
        // document itself can be searched for are worth describing.
        if (element.getRootNode() === document) {
          store.notes.set(id, {tag: element.localName, print: fingerprint(element)});
        }
      }
      return id;
    };
    const refind = id => {
      const note = store.notes.get(id);
      if (!note) return null;
      // Search the whole document, not the place the node used to be: the page
      // is free to have re-rendered it anywhere.
      let found = [];
      try {
        found = Array.from(document.querySelectorAll(note.tag))
          .filter(element => fingerprint(element) === note.print);
      } catch (_) { return null; }
      // One node that looks like the old one is the answer. Several is a guess,
      // and acting on the wrong node is worse than failing — so take the only
      // visible one if there is exactly one, and otherwise give up.
      const live = found.filter(visible);
      const pick = live.length === 1 ? live[0]
        : live.length === 0 && found.length === 1 ? found[0] : null;
      if (!pick) return null;
      // Adopt it, so the page and the snapshot agree on one id per node again.
      store.ids.set(pick, id);
      store.refs.set(id, new WeakRef(pick));
      return pick;
    };
    const lookup = id => {
      const held = store.refs.get(id)?.deref();
      if (held?.isConnected) return held;
      return refind(id);
    };
    const hidden = element => {
      const style = getComputedStyle(element);
      return element.hidden || element.inert || element.getAttribute("aria-hidden") === "true"
        || style.display === "none" || style.visibility === "hidden"
        || style.visibility === "collapse";
    };
    const visible = element => {
      for (let current = element; current; current = current.parentElement
        ?? current.getRootNode().host) {
        if (hidden(current)) return false;
      }
      return true;
    };
    if (op.op === "act") {
      const element = lookup(op.ref);
      if (!element || !visible(element)) {
        return failure("not_found", "stale or hidden ref: " + op.ref);
      }
      if (element.matches(":disabled") || element.getAttribute("aria-disabled") === "true") {
        return failure("invalid", "element is disabled");
      }
      if (op.action === "fill" && !(element.isContentEditable
        || element instanceof HTMLTextAreaElement
        || element instanceof HTMLInputElement && !["checkbox", "radio", "file", "button",
          "submit", "reset", "hidden", "image", "range", "color"].includes(element.type))) {
        return failure("invalid", "fill requires a text field or editable element");
      }
      if (op.action === "fill" && element.readOnly) {
        return failure("invalid", "element is read-only");
      }
      element.scrollIntoView({block: "center", inline: "center", behavior: "instant"});
      if (op.action === "press") element.focus({preventScroll: true});
      if (op.action === "select") {
        if (!(element instanceof HTMLSelectElement)) {
          return failure("invalid", "select requires a select element");
        }
        const option = Array.from(element.options).find(option => option.value === op.text);
        if (!option || option.disabled) {
          return failure("invalid", "no enabled option: " + op.text);
        }
        element.value = op.text;
        element.dispatchEvent(new Event("input", {bubbles: true, composed: true}));
        element.dispatchEvent(new Event("change", {bubbles: true}));
        return {skip: true};
      }
      if (op.action === "check" || op.action === "uncheck") {
        const native = element instanceof HTMLInputElement
          && ["checkbox", "radio"].includes(element.type);
        const aria = element.getAttribute("aria-checked");
        if (!native && aria === null) return failure("invalid", "element is not checkable");
        const wanted = op.action === "check";
        if (native && element.type === "radio" && !wanted && element.checked) {
          return failure("invalid", "a radio button cannot be unchecked by clicking");
        }
        if ((native ? element.checked : aria === "true") === wanted) return {skip: true};
      }
      const rect = element.getBoundingClientRect();
      const left = Math.max(0, rect.left), right = Math.min(innerWidth, rect.right);
      const top = Math.max(0, rect.top), bottom = Math.min(innerHeight, rect.bottom);
      if (right <= left || bottom <= top) {
        return failure("not_found", "element has no visible bounds");
      }
      return {x: (left + right) / 2, y: (top + bottom) / 2};
    }
    const implicit = element => {
      const tag = element.localName;
      if (/^h[1-6]$/.test(tag)) return "heading";
      if (tag === "input") {
        return ({checkbox: "checkbox", radio: "radio", range: "slider", number: "spinbutton",
          button: "button", submit: "button", reset: "button", image: "button",
          search: "searchbox", hidden: "none"})[element.type] ?? "textbox";
      }
      if (tag === "a") return element.hasAttribute("href") ? "link" : "generic";
      if (tag === "select") return element.multiple || element.size > 1 ? "listbox" : "combobox";
      return ({button: "button", textarea: "textbox", img: "img", nav: "navigation",
        main: "main", aside: "complementary", header: "banner", footer: "contentinfo",
        ul: "list", ol: "list", li: "listitem", table: "table", tr: "row", td: "cell",
        th: element.scope === "row" ? "rowheader" : "columnheader", option: "option",
        progress: "progressbar", meter: "meter", summary: "button", details: "group",
        iframe: "iframe", dialog: "dialog", fieldset: "group", form: "form",
        section: "region", article: "article"})[tag]
        ?? (element.isContentEditable ? "textbox" : "generic");
    };
    const children = element => element.shadowRoot?.childNodes
      ?? (element.localName === "slot" && element.assignedNodes().length
        ? element.assignedNodes() : element.childNodes);
    const content = element => {
      let text = "";
      const collect = node => {
        if (node.nodeType === Node.TEXT_NODE) text += " " + node.textContent;
        else if (node instanceof Element && !hidden(node)
          && !["script", "style", "template", "iframe"].includes(node.localName)) {
          for (const child of children(node)) collect(child);
        }
      };
      collect(element);
      return clean(text);
    };
    const name = (element, role) => {
      const root = element.getRootNode();
      const ids = element.getAttribute("aria-labelledby");
      if (ids) {
        const value = clean(ids.split(/\s+/).map(id => root.getElementById?.(id)?.textContent ?? "")
          .join(" "));
        if (value) return clip(value);
      }
      if (element.hasAttribute("aria-label")) return clip(element.getAttribute("aria-label"));
      if (element.labels?.length) return clip(Array.from(element.labels).map(content).join(" "));
      if (element.localName === "fieldset") {
        const legend = element.querySelector(":scope > legend");
        if (legend) return clip(content(legend));
      }
      if (element.localName === "img" || element.type === "image") return clip(element.alt);
      if (element.localName === "input" && ["button", "submit", "reset"].includes(element.type)) {
        return clip(element.value || (element.type === "submit" ? "Submit" : "Reset"));
      }
      if (["button", "link", "heading", "option", "cell", "columnheader", "rowheader",
        "listitem"].includes(role)) return clip(content(element));
      return clip(element.getAttribute("title") || element.getAttribute("placeholder"));
    };
    const interactive = (element, role) => ["button", "link", "textbox", "searchbox", "checkbox",
      "radio", "combobox", "listbox", "slider", "spinbutton", "switch", "menuitem",
      "menuitemcheckbox", "menuitemradio", "tab", "treeitem", "option"].includes(role)
      || element.tabIndex >= 0 || element.isContentEditable;
    let root = document.body ?? document.documentElement;
    if (op.root) {
      try { root = /^e\d+$/.test(op.root) ? lookup(op.root) : document.querySelector(op.root); }
      catch (_) { return failure("invalid", "invalid root selector"); }
      if (!root || !visible(root)) return failure("not_found", "no visible root: " + op.root);
    }
    const limit = Math.min(3000, Math.max(1, op.nodes ?? 400));
    const depth = op.depth ?? Infinity;
    const frames = [];
    let used = 1, more = 0, further;
    const walk = (element, parent, level, blocked = false) => {
      if (hidden(element) || ["script", "style", "template"].includes(element.localName)) return;
      const role = element.getAttribute("role")?.split(/\s+/)[0] || implicit(element);
      const label = name(element, role);
      const generic = ["none", "presentation", "generic"].includes(role)
        || ["form", "region"].includes(role) && !label;
      const active = interactive(element, role);
      if (element.localName === "iframe") {
        frames.push({title: element.title || undefined, src: element.src});
      }
      let next = parent, nextLevel = level, cut = blocked;
      if (!generic || active) {
        if (blocked || level > depth || used >= limit) {
          more++;
          cut = true;
          if (!further && active) further = ref(element);
        } else {
          const node = {role: generic ? "group" : role};
          if (label) node.name = label;
          if (active) node.ref = ref(element);
          if (role === "heading") node.level = Number(element.getAttribute("aria-level")
            || element.localName.slice(1)) || undefined;
          if ("value" in element && !["button", "link", "option"].includes(role)) {
            node.value = element.type === "password" ? "\u2022\u2022\u2022\u2022" : String(element.value);
          } else if (element.isContentEditable) node.value = content(element);
          const states = [];
          for (const state of ["checked", "disabled", "expanded", "selected", "required"]) {
            const aria = element.getAttribute("aria-" + state);
            if (aria === "mixed") states.push(state + "=mixed");
            else if (aria === "true" || aria === null && element[state] === true
              || state === "disabled" && element.matches(":disabled")) states.push(state);
          }
          if (element.getRootNode().activeElement === element) states.push("focused");
          if (states.length) node.states = states;
          (parent.children ??= []).push(node);
          used++;
          next = node;
          nextLevel++;
        }
      }
      if (element.localName === "iframe") return;
      for (const child of children(element)) {
        if (child instanceof Element) walk(child, next, nextLevel, cut);
        else if (child.nodeType === Node.TEXT_NODE && (generic || !label || op.mode === "text")) {
          const text = clip(child.textContent);
          if (!text) continue;
          if (cut || nextLevel > depth || used >= limit) more++;
          else { (next.children ??= []).push({role: "text", name: text}); used++; }
        }
      }
    };
    const tree = {role: "document", name: clip(document.title)};
    if (root) walk(root, tree, 0);
    const answer = {url: location.href, title: document.title, more, frames};
    if (op.format === "text") {
      const lines = [];
      const render = (node, level) => {
        lines.push("  ".repeat(level) + "- " + node.role
          + (node.name ? " " + JSON.stringify(node.name) : "")
          + (node.ref ? " [" + node.ref + "]" : "")
          + (node.value !== undefined ? " value=" + JSON.stringify(node.value) : "")
          + (node.states ? " (" + node.states.join(", ") + ")" : ""));
        for (const child of node.children ?? []) render(child, level + 1);
      };
      render(tree, 0);
      if (more) lines.push("[\u2026 " + more + " more nodes; " + (further
        ? 'root="' + further + '" reads further' : "increase depth/nodes to read further") + "]");
      answer.text = lines.join("\n");
    } else answer.tree = tree;
    return answer;
  };
})();
