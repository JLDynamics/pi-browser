// pi-browser panel: a native WKWebView in a floating card, driven over a Unix
// socket. main.swift reads the launch arguments and starts the app.
//
//   native/panel [--state DIR] [--zoom N]
import AppKit

func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func die(_ message: String) -> Never {
    FileHandle.standardError.write(("panel: " + message + "\n").data(using: .utf8)!)
    exit(1)
}

/// The project folder: the binary lives at `<root>/native/panel`.
let root = Bundle.main.executableURL!.resolvingSymlinksInPath()
    .deletingLastPathComponent().deletingLastPathComponent()
let stateDir = URL(fileURLWithPath: argument("--state") ?? root.appendingPathComponent("state").path)
let pageZoom = Double(argument("--zoom") ?? "") ?? 1

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let panel = Panel()
app.delegate = panel
app.run()
