import AppKit
import WebKit

/// A non-activating panel: it becomes key, so the page gets pointer and key
/// events, without activating the app, which macOS refuses to a background
/// app anyway. Borderless windows refuse key status unless told otherwise.
final class PanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The floating card: a rounded window with a drag header, showing the page at
/// its own layout size shrunk to fit.
///
/// The web view is laid out at `pageSize * scale` with `pageZoom == scale`, so
/// `innerWidth` stays at the page size while the card is small, hit testing
/// stays exact, and a CSS point is a view point times `pageZoom`.
final class Card: NSObject, NSWindowDelegate {
    static let sizes: [String: NSSize] = [
        "card": NSSize(width: 560, height: 430),
        "medium": NSSize(width: 900, height: 700),
    ]
    private static let headerHeight: CGFloat = 26

    let window = PanelWindow(contentRect: .zero, styleMask: [.borderless, .resizable, .fullSizeContentView, .nonactivatingPanel],
                             backing: .buffered, defer: false)
    private let holder = NSView()
    private let titleLabel = NSTextField(labelWithString: "pi-browser")
    private let web: WKWebView
    private let zoom: Double
    private(set) var pageSize = NSSize(width: 1280, height: 800)
    private(set) var sizeName = "card"

    var title: String {
        get { titleLabel.stringValue }
        set { titleLabel.stringValue = newValue.isEmpty ? "pi-browser" : newValue }
    }

    init(web: WKWebView, zoom: Double) {
        self.web = web
        self.zoom = zoom
        super.init()
        let size = Self.sizes["card"]!
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        window.setFrame(NSRect(x: screen.maxX - size.width - 12, y: screen.minY + 12,
                               width: size.width, height: size.height), display: false)
        window.level = .floating
        window.hidesOnDeactivate = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.minSize = NSSize(width: 240, height: 160)
        window.delegate = self
        buildViews(size)
        window.makeKeyAndOrderFront(nil)
        fit()
    }

    private func buildViews(_ size: NSSize) {
        let h = Self.headerHeight
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor(white: 0.25, alpha: 0.9).cgColor
        container.layer?.backgroundColor = NSColor(white: 0.09, alpha: 1).cgColor
        container.autoresizingMask = [.width, .height]
        window.contentView = container

        let header = NSView(frame: NSRect(x: 0, y: size.height - h, width: size.width, height: h))
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor(white: 0.14, alpha: 1).cgColor
        header.autoresizingMask = [.width, .minYMargin]
        container.addSubview(header)

        let dot = NSView(frame: NSRect(x: 10, y: (h - 7) / 2, width: 7, height: 7))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.layer?.backgroundColor = NSColor(white: 0.45, alpha: 1).cgColor
        header.addSubview(dot)

        titleLabel.frame = NSRect(x: 24, y: 4, width: size.width - 64, height: 18)
        titleLabel.font = NSFont.systemFont(ofSize: 11.5)
        titleLabel.textColor = NSColor(white: 0.72, alpha: 1)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.autoresizingMask = [.width]
        header.addSubview(titleLabel)

        let close = NSButton(frame: NSRect(x: size.width - 26, y: 3, width: 20, height: 20))
        close.title = "✕"
        close.bezelStyle = .inline
        close.isBordered = false
        close.font = NSFont.systemFont(ofSize: 11)
        close.contentTintColor = NSColor(white: 0.55, alpha: 1)
        close.target = self
        close.action = #selector(hide)
        close.autoresizingMask = [.minXMargin]
        header.addSubview(close)

        holder.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height - h)
        holder.wantsLayer = true
        holder.layer?.masksToBounds = true
        holder.layer?.backgroundColor = NSColor(white: 0.07, alpha: 1).cgColor
        holder.autoresizingMask = [.width, .height]
        container.addSubview(holder)

        web.autoresizingMask = []
        web.wantsLayer = true
        holder.addSubview(web)
    }

    /// Scale the page into the holder, centred; a card whose aspect differs from
    /// the page letterboxes instead of distorting it.
    private func fit() {
        let avail = holder.bounds
        let scale = max(0.02, min(1, avail.width / pageSize.width, avail.height / pageSize.height))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        web.pageZoom = scale * zoom
        let w = pageSize.width * scale, h = pageSize.height * scale
        web.frame = NSRect(x: (avail.width - w) / 2, y: (avail.height - h) / 2, width: w, height: h)
        CATransaction.commit()
    }

    func windowDidResize(_ notification: Notification) { fit() }

    func setPageSize(_ w: Double, _ h: Double) {
        pageSize = NSSize(width: max(80, w), height: max(80, h))
        fit()
    }

    /// `card` and `medium` keep the card's bottom-right corner; `full` fills the screen.
    func resize(_ name: String) -> NSSize {
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        var frame = screen
        if let size = Self.sizes[name] {
            frame = NSRect(x: window.frame.maxX - size.width, y: window.frame.minY,
                           width: size.width, height: size.height)
            frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - size.width)
            frame.origin.y = min(max(frame.minY, screen.minY), screen.maxY - size.height)
        }
        window.setFrame(frame, display: true)
        sizeName = name
        return frame.size
    }

    func show() {
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }

    @objc func hide() { window.orderOut(nil) }

    var geometry: [String: Any] {
        func rect(_ r: NSRect) -> [String: Double] {
            ["x": r.origin.x, "y": r.origin.y, "w": r.width, "h": r.height]
        }
        return [
            "window": rect(window.frame),
            "holder": rect(holder.convert(holder.bounds, to: nil)),
            "web": rect(web.frame),
            "page": ["w": pageSize.width, "h": pageSize.height],
            "scale": Double(web.pageZoom) / zoom,
            "zoom": Double(web.pageZoom),
            "key": window.isKeyWindow,
            "main": window.isMainWindow,
            "webIsFirst": window.firstResponder === web,
        ]
    }
}
