# pi-browser

A browser for the pi agent: a native `WKWebView` in a floating card, driven
with a JSON op protocol and an accessibility-tree `snapshot` that hands back
stable refs. macOS only, plain Node 22+, no dependencies. `SKILL.md` is the
agent-facing guide; this file is for whoever changes the code.

```sh
make                                           # build native/panel (swiftc)
bin/pibrowse.mjs --up --url https://example.com
bin/pibrowse.mjs '{"op":"snapshot","format":"text"}'
bin/pibrowse.mjs --down
make test                                      # end-to-end check, ~5 s
```

Install as a pi skill: `ln -sfn ~/Documents/pi-browser ~/.pi/agent/skills/pi-browser`.

## Layout

```
bin/pibrowse.mjs        CLI: flags, then one op validated and sent
lib/protocol.json       the op table: every op and its fields
lib/protocol.mjs        parses and validates an op against that table
lib/panel.mjs           starts/stops the panel, one JSON line per op over the socket
lib/page.js             injected into every page: ref registry, snapshot, act targeting
native/main.swift       launch arguments (--state DIR, --zoom N), starts the app
native/Panel.swift      wires the parts, checks Ops.table against protocol.json
native/Card.swift       the floating window and page scaling
native/Browser.swift    the web view: profile, navigation, dialogs, events, JS calls
native/Input.swift      synthesised mouse and key events
native/Ops.swift        one handler per op
native/SocketServer.swift  the Unix socket: JSON line in, JSON line out
demo/serve.mjs          test page with a form, a modal and a shadow-DOM widget
test.mjs                the end-to-end check `make test` runs
```

`state/` (or `$PIBROWSE_STATE`) holds `panel.sock`, `panel.log` and
`profile-id.txt`, which names the WebKit profile under `~/Library/WebKit/panel/`.
Delete it to start with a clean profile.

## How it works

- **Adding an op** means a line in `lib/protocol.json` and a handler in
  `native/Ops.swift`. The CLI rejects ops the table does not allow, and the panel
  refuses to start if the two disagree.
- **The page keeps its own size.** The web view is laid out at
  `pageSize * scale` with `pageZoom == scale`, so `innerWidth` stays 1280 while the
  card is small, and a CSS point maps to the view by multiplying by the zoom.
- **Input is real AppKit events.** The card is a non-activating panel and the web
  view accepts the first click, so clicks land while another app is in front.
  Key chords go straight to the web view; ⌘-chords also perform their editing
  command (`Meta+a` selects all).
- **Navigation waits on WebKit's `isLoading`**, which is true from the moment a
  load is requested until it, or a same-document change, settles. A navigation
  cancelled by another one is not a failure.
- **lib/page.js** is Tern's injected snapshot algorithm, installed in its own
  `WKContentWorld` so the page cannot see it. A ref also records a fingerprint of
  its node, so a page that re-renders a field on focus (Wikipedia's search box)
  still resolves it.
