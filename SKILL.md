---
name: pi-browser
description: Drive a native WKWebView panel from pi - open pages, read an accessibility-tree snapshot with stable refs, then click/fill/press. Use when a task needs a live page, a logged-in session, JS-rendered content, or form filling, instead of curl or a headless test runner.
---

# pi-browser

A browser this agent owns: a native `WKWebView` in a small always-on-top card,
driven with one JSON op per CLI call. The human watches the same page you drive.

CLI: `~/Documents/pi-browser/bin/pibrowse.mjs` (add `~/Documents/pi-browser/bin`
to `PATH` to type `pibrowse`). Every op answers `{"ok": …}` or
`{"error": {"kind", "message"}}` with exit 1. Kinds: `invalid` (a bad op, caught
before it reaches the page), `not_found` (a stale or hidden ref), `failed`.

## The loop

```sh
pibrowse --up --url https://example.com       # answers once the page has loaded
pibrowse '{"op":"snapshot","format":"text","nodes":40}'
pibrowse '{"op":"act","action":"click","ref":"e3"}'
pibrowse --down                               # quit the panel when done
```

Any op starts the panel if it is not running, so `--up` is optional.

## Ops

The full table, with field types, is `lib/protocol.json`.

| op | fields | answer |
|---|---|---|
| `open` | `url?`, `owner?` | `{block, url, visible}` |
| `goto` | `url`, `timeout?` (s, default 20) | `{}` (`{timeout:true}` if it never settled) |
| `nav` | `go`: back, forward, reload, stop | `{}` |
| `state` | | `{url,title,loading,progress,back,forward,width,height,shown,focused,error}` |
| `snapshot` | `root?`, `depth?`, `nodes?` (400, max 3000), `mode?`, `format?` text, tree | `{url,title,more,frames,text\|tree}` |
| `act` | `action`, `ref`, plus `text` / `keys` / `dx`,`dy` | `{done,url,title}` |
| `eval` | `function`: a function, an expression or statements | `{value}` |
| `input` | `events`: `[{type: mouse\|wheel\|key\|text, …}]` | `{}` |
| `capture` | `format?` png, jpeg | `{data (base64), mime, width, height}` |
| `events` | `from?` | `{events, next, dropped}` (navigation, responses, dialogs) |
| `viewport` | `width`, `height` | `{}` (the page's own size, default 1280×800) |
| `resize` | `size`: card, medium, full | `{size, width, height}` (the card on screen) |
| `show` / `close` | `url?` / | puts the card on screen / hides it (the panel keeps running) |
| `dialogs` | `policy`: accept, dismiss, default | `{}`; `release` resets it |
| `blocks`, `geometry` | | the one page `main`; layout and focus, for debugging |

`act` actions: `click`, `dblclick`, `hover`, `fill` (`text`), `press` (`keys`),
`select` (`text` = option value), `check`, `uncheck`, `scroll` (`dy`, `dx`; no
`ref` scrolls the page).

## Rules

- **Snapshot before acting.** Never guess a ref. Refs stay valid until
  navigation; a ref whose node the page re-rendered is found again by what it
  was. A ref with no visible bounds answers `not_found`.
- **Clicks are real AppKit events** at the element's centre, so `isTrusted` is
  true and pages that check it work.
- **`fill` replaces the field's value** the way a person would: click, select
  all, one text insertion. `input`/`beforeinput` fire; `.value` is not assigned.
- **`press` takes a chord or a list:** `"Enter"`, `"Meta+a"`, `["Backspace","x"]`.
  Names follow Playwright (Escape, ArrowLeft, Tab, F1). An unknown key is an
  error. After `Enter`, the reply waits briefly for the navigation it caused.
- **Batch calls in one shell command** with `;` and `echo '--- step'` markers.
  The panel stays up, so each call is cheap.
- **Don't report what you didn't read.**
- The profile persists, so logins survive a restart. Never point it at a
  personal browser profile.

## Traps

- `eval` runs in the page's own world and awaits promises. A value that is not
  JSON (a DOM node, a Date) answers `failed`; return plain data.
- `snapshot` never changes the dialog policy. Alerts are accepted and confirms
  answered per `dialogs`; check `events` for what was shown.
- `state/panel.log` holds the panel's stderr. After editing `native/*.swift`,
  run `make` and `pibrowse --down` so the next op starts the new build.
