import AppKit
import WebKit

/// Synthesised AppKit input: real NSEvents, so the page sees `isTrusted` events.
final class Input {
    /// A parsed key chord such as `Meta+a`, `Enter` or `q`.
    struct Chord {
        let key: String
        let code: UInt16
        let flags: NSEvent.ModifierFlags
        var isCommand: Bool { flags.contains(.command) || flags.contains(.control) }
    }

    static let keyCodes: [String: UInt16] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
        "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
        "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11,
        "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17,
        "=": 0x18, "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D,
        "]": 0x1E, "o": 0x1F, "u": 0x20, "[": 0x21, "i": 0x22, "p": 0x23,
        "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29, "\\": 0x2A,
        ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, "`": 0x32,
        "enter": 0x24, "return": 0x24, "tab": 0x30, "space": 0x31, " ": 0x31,
        "backspace": 0x33, "escape": 0x35, "esc": 0x35, "delete": 0x75,
        "arrowleft": 0x7B, "arrowright": 0x7C, "arrowdown": 0x7D, "arrowup": 0x7E,
        "home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61,
        "f7": 0x62, "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
    ]

    static let modifierFlags: [String: NSEvent.ModifierFlags] = [
        "meta": .command, "cmd": .command, "command": .command, "mod": .command,
        "shift": .shift, "ctrl": .control, "control": .control,
        "alt": .option, "option": .option, "opt": .option,
    ]

    /// Editing commands a ⌘/⌃ chord means. WKWebView does not turn a synthesised
    /// chord into its command, so `press` sends the key event and performs it.
    static let commands: [String: Selector] = [
        "a": #selector(NSText.selectAll(_:)), "c": #selector(NSText.copy(_:)),
        "v": #selector(NSText.paste(_:)), "x": #selector(NSText.cut(_:)),
    ]

    static func parse(_ chord: String) -> Result<Chord, PanelError> {
        let parts = chord.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        let key = parts.last ?? ""
        var flags: NSEvent.ModifierFlags = []
        for m in parts.dropLast() {
            guard let f = modifierFlags[m.lowercased()] else {
                return .failure(PanelError(kind: "invalid", message: "act press: unknown modifier \(m)"))
            }
            flags.insert(f)
        }
        guard let code = keyCodes[key.lowercased()] else {
            return .failure(PanelError(kind: "invalid",
                message: "unknown key `\(key)` (Playwright names: Meta+k, Escape, ArrowLeft, F1, [, …)"))
        }
        return .success(Chord(key: key, code: code, flags: flags))
    }

    /// The text a key carries: a named key its control character, a single
    /// character itself, anything else (arrows, F-keys) none. Without this the
    /// web view types the key's *name*, "Enter" literally.
    static func text(for key: String) -> String {
        switch key.lowercased() {
        case "enter", "return": return "\r"
        case "tab": return "\t"
        case "space": return " "
        case "backspace": return "\u{8}"
        case "delete": return "\u{7f}"
        case "escape", "esc": return "\u{1b}"
        default: return key.count == 1 ? key : ""
        }
    }

    private let web: WKWebView
    private let window: NSWindow

    init(web: WKWebView, window: NSWindow) {
        self.web = web
        self.window = window
    }

    /// Run `work` once the window is key and the web view first responder. A
    /// person's click establishes both; a synthesised event does not, events
    /// sent without them are dropped silently, and key status lands a turn later.
    func withFocus(_ work: @escaping () -> Void) {
        var changed = false
        if !window.isKeyWindow { window.makeKeyAndOrderFront(nil); changed = true }
        if window.firstResponder !== web { window.makeFirstResponder(web); changed = true }
        if changed { DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work) } else { work() }
    }

    /// CSS point → window point. WKWebView is flipped like CSS, so the view point
    /// is the CSS point times the zoom.
    func point(_ x: Double, _ y: Double) -> NSPoint {
        let z = Double(web.pageZoom)
        return web.convert(NSPoint(x: x * z, y: y * z), to: nil)
    }

    private func mouseEvent(_ type: NSEvent.EventType, _ p: NSPoint, count: Int = 1,
                            modifiers: NSEvent.ModifierFlags = []) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: modifiers,
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                           clickCount: count, pressure: type == .mouseMoved ? 0 : 1)
    }

    func move(to p: NSPoint) {
        if let e = mouseEvent(.mouseMoved, p) { web.mouseMoved(with: e) }
    }

    /// Through the window, not straight to the view: only the window's routing
    /// focuses the field under the pointer.
    func mouse(_ type: NSEvent.EventType, at p: NSPoint, count: Int = 1, modifiers: NSEvent.ModifierFlags = []) {
        if let e = mouseEvent(type, p, count: count, modifiers: modifiers) { window.sendEvent(e) }
    }

    func click(at p: NSPoint, count: Int = 1) {
        mouse(.mouseMoved, at: p)
        mouse(.leftMouseDown, at: p, count: count)
        mouse(.leftMouseUp, at: p, count: count)
    }

    /// A wheel event at a CSS point, so the scroller under that point scrolls.
    func wheel(at p: NSPoint, dx: Double, dy: Double) {
        guard let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                               wheel1: Int32(-dy), wheel2: Int32(-dx), wheel3: 0) else { return }
        // CGEvent locations are global, top-left origin; AppKit's are bottom-left.
        let screen = window.convertPoint(toScreen: p)
        ev.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.height ?? 0) - screen.y)
        if let e = NSEvent(cgEvent: ev) { web.scrollWheel(with: e) }
    }

    func selectAll() {
        _ = web.perform(#selector(NSText.selectAll(_:)), with: nil)
    }

    /// Insert text the way an input method does: one `beforeinput`/`input`.
    /// `insertText:` is the text-input entry point the web view installs while
    /// editing; it is not public API on WKWebView.
    func insertText(_ text: String) -> Bool {
        let sel = NSSelectorFromString("insertText:")
        guard web.responds(to: sel) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector, NSString) -> Void
        unsafeBitCast(web.method(for: sel), to: Fn.self)(web, sel, text as NSString)
        return true
    }

    func key(_ c: Chord, down: Bool) {
        let text = Self.text(for: c.key)
        // A named key reports the same characters with and without modifiers
        // (Return is "\r" both ways); reporting its name made WebKit insert a
        // carriage return instead of running the key's default action.
        guard let e = NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: c.flags,
                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil,
                                       characters: text, charactersIgnoringModifiers: text.isEmpty ? c.key : text,
                                       isARepeat: false, keyCode: c.code) else { return }
        // Straight to the web view: through the window, chords become menu equivalents.
        if down { web.keyDown(with: e) } else { web.keyUp(with: e) }
    }

    func press(_ chords: [Chord]) {
        for c in chords {
            key(c, down: true)
            if c.isCommand, let sel = Self.commands[c.key.lowercased()] { _ = web.perform(sel, with: nil) }
            key(c, down: false)
        }
    }
}
