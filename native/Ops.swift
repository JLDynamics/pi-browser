import AppKit
import WebKit

typealias Done = (Reply) -> Void

/// The reply envelope: `{ok: …}` or `{error: {kind, message}}`.
struct Reply {
    let body: [String: Any]
    static func ok(_ v: [String: Any] = [:]) -> Reply { Reply(body: ["ok": v]) }
    static func error(_ e: PanelError) -> Reply { Reply(body: ["error": ["kind": e.kind, "message": e.message]]) }
}

/// One op as it arrived. The CLI validated it against lib/protocol.json, so
/// handlers read fields without re-checking them.
struct Op {
    let raw: [String: Any]
    func string(_ key: String) -> String? { raw[key] as? String }
    func number(_ key: String) -> Double? { (raw[key] as? NSNumber)?.doubleValue }
    var timeout: Double { number("timeout") ?? 20 }
}

/// The op handlers, one per op in lib/protocol.json (checked at startup).
final class Ops {
    static let table: [String: (Ops) -> (Op, @escaping Done) -> Void] = [
        "ping": Ops.ping, "quit": Ops.quit, "geometry": Ops.geometry,
        "open": Ops.open, "show": Ops.show, "goto": Ops.goto, "nav": Ops.nav, "wait": Ops.wait,
        "state": Ops.state, "blocks": Ops.blocks, "snapshot": Ops.snapshot, "act": Ops.act,
        "eval": Ops.eval, "input": Ops.input, "capture": Ops.capture, "events": Ops.events,
        "viewport": Ops.viewport, "resize": Ops.resize, "dialogs": Ops.dialogs,
        "release": Ops.release, "close": Ops.close,
    ]

    private let card: Card
    private let browser: Browser
    private let input: Input
    private var web: WKWebView { browser.web }

    init(card: Card, browser: Browser, input: Input) {
        self.card = card
        self.browser = browser
        self.input = input
    }

    func handle(_ raw: [String: Any], _ done: @escaping Done) {
        let name = raw["op"] as? String ?? ""
        guard let handler = Self.table[name] else {
            return done(.error(PanelError(kind: "invalid", message: "unknown web call \"\(name)\"")))
        }
        handler(self)(Op(raw: raw), done)
    }

    private func invalid(_ message: String) -> Reply { .error(PanelError(kind: "invalid", message: message)) }

    // ------------------------------------------------------------ process

    func ping(_ op: Op, _ done: @escaping Done) {
        done(.ok(["pid": ProcessInfo.processInfo.processIdentifier]))
    }

    func quit(_ op: Op, _ done: @escaping Done) {
        done(.ok())
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
    }

    func geometry(_ op: Op, _ done: @escaping Done) { done(.ok(card.geometry)) }

    // ------------------------------------------------------------ navigation

    /// Load `url` (if given), then answer once it settled, so the caller's next
    /// op reads the new page, not the old one.
    private func navigate(_ url: String?, timeout: Double, _ reply: @escaping ([String: Any]) -> Void,
                          _ done: @escaping Done) {
        if let url, url != "about:blank", let e = browser.load(url) { return done(.error(e)) }
        browser.waitForLoad(timeout: timeout) { result in
            switch result {
            case .failure(let e): done(.error(e))
            case .success(let timedOut): reply(timedOut ? ["timeout": true] : [:])
            }
        }
    }

    func open(_ op: Op, _ done: @escaping Done) {
        if let owner = op.string("owner") { browser.owner = owner }
        card.show()
        navigate(op.string("url"), timeout: op.timeout, { _ in
            done(.ok(["block": "main", "url": self.browser.url, "visible": true]))
        }, done)
    }

    func show(_ op: Op, _ done: @escaping Done) {
        card.show()
        navigate(op.string("url"), timeout: op.timeout, { _ in
            done(.ok(["block": "main", "reused": true, "size": self.card.sizeName,
                      "url": self.browser.url, "title": self.browser.title]))
        }, done)
    }

    func goto(_ op: Op, _ done: @escaping Done) {
        navigate(op.string("url"), timeout: op.timeout, { done(.ok($0)) }, done)
    }

    func nav(_ op: Op, _ done: @escaping Done) {
        switch op.string("go") {
        case "back":
            guard web.canGoBack else { return done(invalid("nav: no back entry")) }
            web.goBack()
        case "forward":
            guard web.canGoForward else { return done(invalid("nav: no forward entry")) }
            web.goForward()
        case "stop": web.stopLoading()
        default: web.reload()
        }
        navigate(nil, timeout: op.timeout, { done(.ok($0)) }, done)
    }

    func wait(_ op: Op, _ done: @escaping Done) {
        navigate(nil, timeout: op.timeout, { _ in
            done(.ok(["url": self.browser.url, "title": self.browser.title]))
        }, done)
    }

    // ------------------------------------------------------------ reading

    func state(_ op: Op, _ done: @escaping Done) {
        done(.ok([
            "url": browser.url, "title": browser.title,
            "loading": web.isLoading, "progress": web.estimatedProgress,
            "back": web.canGoBack, "forward": web.canGoForward,
            "width": card.pageSize.width, "height": card.pageSize.height,
            "shown": card.window.isVisible, "focused": card.window.isKeyWindow,
            "error": browser.lastError as Any? ?? NSNull(),
        ]))
    }

    func blocks(_ op: Op, _ done: @escaping Done) {
        done(.ok(["blocks": [[
            "block": "main", "url": browser.url, "title": browser.title,
            "owner": browser.owner as Any? ?? NSNull(), "shown": card.window.isVisible, "driven": true,
        ]]]))
    }

    func snapshot(_ op: Op, _ done: @escaping Done) {
        var call: [String: Any] = ["op": "snapshot"]
        for k in ["root", "depth", "nodes", "mode", "format"] { call[k] = op.raw[k] }
        browser.callPage(call) { result in
            switch result {
            case .failure(let e): done(.error(e))
            case .success(let v): done(.ok(v))
            }
        }
    }

    func events(_ op: Op, _ done: @escaping Done) {
        let from = Int(op.number("from") ?? 0)
        let list = browser.events.filter { ($0["seq"] as? Int ?? 0) > from }
        done(.ok(["events": list, "next": browser.seq, "dropped": browser.dropped]))
    }

    func eval(_ op: Op, _ done: @escaping Done) {
        browser.eval(op.string("function") ?? "") { result in
            switch result {
            case .failure(let e): done(.error(e))
            case .success(let v): done(.ok(["value": v]))
            }
        }
    }

    func capture(_ op: Op, _ done: @escaping Done) {
        let jpeg = op.string("format") == "jpeg"
        let w = Int(card.pageSize.width), h = Int(card.pageSize.height)
        let cfg = WKSnapshotConfiguration()
        cfg.rect = web.bounds
        cfg.snapshotWidth = NSNumber(value: w)
        web.takeSnapshot(with: cfg) { image, error in
            guard let image else {
                return done(.error(PanelError(kind: "failed", message: error?.localizedDescription ?? "capture: no image")))
            }
            // One pixel per CSS pixel, like Tern: draw into a 1x bitmap rather
            // than keeping the Retina backing store.
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
                return done(.error(PanelError(kind: "failed", message: "capture: no bitmap")))
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
            NSGraphicsContext.restoreGraphicsState()
            guard let data = rep.representation(using: jpeg ? .jpeg : .png, properties: [:]) else {
                return done(.error(PanelError(kind: "failed", message: "capture: cannot encode")))
            }
            done(.ok(["data": data.base64EncodedString(), "mime": jpeg ? "image/jpeg" : "image/png",
                      "width": w, "height": h]))
        }
    }

    // ------------------------------------------------------------ the card

    func viewport(_ op: Op, _ done: @escaping Done) {
        card.setPageSize(op.number("width") ?? 1280, op.number("height") ?? 800)
        done(.ok())
    }

    func resize(_ op: Op, _ done: @escaping Done) {
        let name = op.string("size") ?? "card"
        let size = card.resize(name)
        done(.ok(["size": name, "width": size.width, "height": size.height]))
    }

    func close(_ op: Op, _ done: @escaping Done) {
        card.hide()
        done(.ok())
    }

    func dialogs(_ op: Op, _ done: @escaping Done) {
        browser.dialogPolicy = op.string("policy") ?? "default"
        done(.ok())
    }

    func release(_ op: Op, _ done: @escaping Done) {
        browser.dialogPolicy = "default"
        done(.ok())
    }

    // ------------------------------------------------------------ acting

    func act(_ op: Op, _ done: @escaping Done) {
        let action = op.string("action") ?? ""
        let dx = op.number("dx") ?? 0, dy = op.number("dy") ?? 600
        if action == "scroll" && op.string("ref") == nil {
            return browser.eval("scrollBy(\(dx), \(dy))") { _ in self.settle(done) }
        }
        var chords: [Input.Chord] = []
        if action == "press" {
            let keys = op.raw["keys"] as? [String] ?? [op.string("keys") ?? ""]
            for k in keys {
                switch Input.parse(k) {
                case .success(let c): chords.append(c)
                case .failure(let e): return done(.error(e))
                }
            }
        }
        var call: [String: Any] = ["op": "act", "action": action, "ref": op.string("ref") ?? ""]
        call["text"] = op.raw["text"]
        browser.callPage(call) { result in
            let v: [String: Any]
            switch result {
            case .failure(let e): return done(.error(e))
            case .success(let value): v = value
            }
            // select, and check on an element already in the wanted state, finish in the page.
            if v["skip"] as? Bool == true { return self.settle(done) }
            guard let x = (v["x"] as? NSNumber)?.doubleValue, let y = (v["y"] as? NSNumber)?.doubleValue else {
                return done(.error(PanelError(kind: "failed", message: "act: the page gave no point")))
            }
            let p = self.input.point(x, y)
            self.input.withFocus {
                switch action {
                case "dblclick":
                    self.input.click(at: p, count: 1)
                    self.input.click(at: p, count: 2)
                case "hover": self.input.move(to: p)
                case "fill": return self.fill(at: p, text: op.string("text") ?? "", done)
                case "press": self.input.press(chords)
                case "scroll": self.browser.eval("scrollBy(\(dx), \(dy))") { _ in }
                default: self.input.click(at: p)
                }
                self.settle(done, mayNavigate: action == "press" && chords.contains { $0.key.lowercased() == "enter" })
            }
        }
    }

    /// Click the field, then replace its contents with one text insertion, as a
    /// person selecting and typing would. The click alone would leave the caret
    /// where it landed and splice the text into the existing value.
    private func fill(at p: NSPoint, text: String, _ done: @escaping Done) {
        input.click(at: p)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            self.input.selectAll()
            guard self.input.insertText(text) else {
                return done(.error(PanelError(kind: "failed", message: "fill: the web view takes no text input")))
            }
            self.settle(done)
        }
    }

    /// Answer once the page settled: a turn for the action to land, and if it
    /// started a navigation, until that finishes (capped at 3 s). A single-page
    /// app answers Enter with a fetch and pushState, so after Enter the address
    /// gets a short grace period to change.
    private func settle(_ done: @escaping Done, mayNavigate: Bool = false) {
        let before = web.url
        let deadline = Date().addingTimeInterval(3)
        let grace = Date().addingTimeInterval(mayNavigate ? 0.8 : 0)
        func check() {
            if (web.isLoading && Date() < deadline) || (web.url == before && Date() < grace) {
                return DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: check)
            }
            done(.ok(["done": true, "url": browser.url, "title": browser.title]))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: check)
    }

    /// Raw input events. Every event is parsed before any is sent, so a bad
    /// event fails the op without half of it having happened.
    func input(_ op: Op, _ done: @escaping Done) {
        var steps: [() -> Void] = []
        for e in op.raw["events"] as? [[String: Any]] ?? [] {
            let type = e["type"] as? String ?? ""
            let action = e["action"] as? String ?? ""
            let p = input.point((e["x"] as? NSNumber)?.doubleValue ?? 0, (e["y"] as? NSNumber)?.doubleValue ?? 0)
            switch (type, action) {
            case ("mouse", "move"): steps.append { self.input.move(to: p) }
            case ("mouse", "down"): steps.append { self.input.mouse(.leftMouseDown, at: p) }
            case ("mouse", "up"): steps.append { self.input.mouse(.leftMouseUp, at: p) }
            case ("mouse", _): return done(invalid("input: unknown mouse action \(action) (move, down, up)"))
            case ("wheel", _):
                let dx = (e["dx"] as? NSNumber)?.doubleValue ?? 0, dy = (e["dy"] as? NSNumber)?.doubleValue ?? 0
                steps.append { self.input.wheel(at: p, dx: dx, dy: dy) }
            case ("key", "down"), ("key", "up"):
                let mods = (e["modifiers"] as? [String] ?? []).map { $0 + "+" }.joined()
                switch Input.parse(mods + (e["key"] as? String ?? "")) {
                case .success(let c): steps.append { self.input.key(c, down: action == "down") }
                case .failure(let err): return done(.error(err))
                }
            case ("key", _): return done(invalid("input: unknown key action \(action) (down, up)"))
            case ("text", _):
                let text = e["text"] as? String ?? ""
                steps.append { _ = self.input.insertText(text) }
            default: return done(invalid("input: unknown type \"\(type)\" (mouse, wheel, key, text)"))
            }
        }
        input.withFocus {
            steps.forEach { $0() }
            done(.ok())
        }
    }
}
