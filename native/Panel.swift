import AppKit

/// The app delegate: builds the browser, the card and the op table, checks the
/// table against lib/protocol.json, and serves it on `<state>/panel.sock`.
final class Panel: NSObject, NSApplicationDelegate {
    private var server: SocketServer?
    private var ops: Ops?

    func applicationDidFinishLaunching(_ note: Notification) {
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let lib = root.appendingPathComponent("lib")
        guard let script = try? String(contentsOf: lib.appendingPathComponent("page.js"), encoding: .utf8) else {
            die("no injected script at \(lib.path)/page.js")
        }
        checkProtocol(lib.appendingPathComponent("protocol.json"))

        let browser = Browser(profileID: Self.profileID(), script: script)
        let card = Card(web: browser.web, zoom: pageZoom)
        browser.onTitle = { card.title = $0 }
        let ops = Ops(card: card, browser: browser, input: Input(web: browser.web, window: card.window))
        self.ops = ops

        let server = SocketServer(path: stateDir.appendingPathComponent("panel.sock").path) { op, reply in
            ops.handle(op, reply)
        }
        // Another panel already serves this state dir: it is the panel, not us.
        guard server.start() else { exit(0) }
        self.server = server
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ note: Notification) { server?.stop() }

    /// The op names in lib/protocol.json and the handlers in `Ops.table` must be
    /// the same set, or the CLI would accept ops the panel cannot run.
    private func checkProtocol(_ url: URL) {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let spec = json["ops"] as? [String: [String: Any]] else { die("cannot read \(url.path)") }
        let declared = Set(spec.filter { $0.value["@cli"] == nil }.keys)
        let handled = Set(Ops.table.keys)
        guard declared == handled else {
            die("protocol.json and Ops.table disagree: only in protocol \(declared.subtracting(handled).sorted()), only in panel \(handled.subtracting(declared).sorted())")
        }
    }

    /// WebKit keeps the persistent profile under this id, so logins survive restarts.
    private static func profileID() -> UUID {
        let file = stateDir.appendingPathComponent("profile-id.txt")
        if let s = try? String(contentsOf: file, encoding: .utf8),
           let id = UUID(uuidString: s.trimmingCharacters(in: .whitespacesAndNewlines)) { return id }
        let id = UUID()
        try? id.uuidString.write(to: file, atomically: true, encoding: .utf8)
        return id
    }
}
