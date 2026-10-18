import WebKit

/// Takes the first click while the card is not key, so a click is never
/// swallowed as the one that makes the window key.
final class PageView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct PanelError: Error {
    let kind: String
    let message: String
}

/// The web view and what happens in it: profile, injected script, navigation,
/// dialogs and the event log. Page state (url, title, loading) is read from the
/// web view itself, never cached.
final class Browser: NSObject, WKNavigationDelegate, WKUIDelegate {
    /// The injected script's own content world: the page cannot see or clobber it.
    private static let world = WKContentWorld.world(name: "pi")

    let web: WKWebView
    private let script: String
    private var titleObservation: NSKeyValueObservation?
    var onTitle: (String) -> Void = { _ in }

    var lastError: String?
    var dialogPolicy = "default"
    var owner: String?
    private(set) var events: [[String: Any]] = []
    private(set) var seq = 0
    private(set) var dropped = 0

    var url: String { web.url?.absoluteString ?? "about:blank" }
    var title: String { web.title ?? "" }

    init(profileID: UUID, script: String) {
        self.script = script
        let cfg = WKWebViewConfiguration()
        if #available(macOS 14.0, *) {
            cfg.websiteDataStore = WKWebsiteDataStore(forIdentifier: profileID)
        }
        cfg.preferences.setValue(true, forKey: "developerExtrasEnabled")
        cfg.userContentController.addUserScript(
            WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.world))
        web = PageView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: cfg)
        super.init()
        web.allowsBackForwardNavigationGestures = false
        web.allowsMagnification = false
        web.setValue(false, forKey: "drawsBackground")
        if #available(macOS 13.3, *) { web.isInspectable = true }
        web.uiDelegate = self
        web.navigationDelegate = self
        titleObservation = web.observe(\.title) { [weak self] web, _ in
            self?.onTitle(web.title ?? "")
            self?.note("title", ["title": web.title ?? ""])
        }
    }

    // ------------------------------------------------------------ navigation

    func load(_ target: String) -> PanelError? {
        guard let parsed = URL(string: target),
              let url = parsed.scheme == nil ? URL(string: "https://" + target) : parsed else {
            return PanelError(kind: "invalid", message: "Not a web address: \(target)")
        }
        lastError = nil
        web.load(URLRequest(url: url))
        return nil
    }

    /// Wait for the current load to settle. WebKit's `isLoading` is true from the
    /// moment a load is requested and false once it, or a same-document
    /// navigation that never reports `didFinish`, is done.
    func waitForLoad(timeout: Double, _ done: @escaping (Result<Bool, PanelError>) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if let e = lastError { return done(.failure(PanelError(kind: "failed", message: e))) }
            if !web.isLoading { return done(.success(false)) }
            if Date() > deadline { return done(.success(true)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
        }
        poll()
    }

    func note(_ type: String, _ extra: [String: Any] = [:]) {
        seq += 1
        events.append(extra.merging(["type": type, "seq": seq]) { $1 })
        if events.count > 500 { events.removeFirst(); dropped += 1 }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        lastError = nil
        note("url", ["url": url])
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        note("redirect", ["url": url])
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        note("committed", ["url": url])
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        note("loaded", ["url": url])
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    /// A navigation replaced by another one (a redirect, a click mid-load, a new
    /// `goto`) reports NSURLErrorCancelled. The page did not fail, so it must not
    /// fail whoever is waiting on the navigation that replaced it.
    private func failed(_ error: Error) {
        let e = error as NSError
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
        lastError = e.localizedDescription
        note("error", ["message": e.localizedDescription])
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let http = navigationResponse.response as? HTTPURLResponse {
            var headers: [String: String] = [:]
            for (k, v) in http.allHeaderFields { headers["\(k)"] = "\(v)" }
            note("response", ["url": http.url?.absoluteString ?? "", "status": http.statusCode,
                              "mime": http.mimeType ?? "", "headers": headers,
                              "main": navigationResponse.isForMainFrame])
        }
        decisionHandler(.allow)
    }

    /// `target=_blank` and `window.open` load in this panel: one panel, one page.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = navigationAction.request.url { web.load(URLRequest(url: u)) }
        return nil
    }

    // ------------------------------------------------------------ dialogs

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        note("dialog", ["kind": "alert", "message": message])
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        note("dialog", ["kind": "confirm", "message": message])
        completionHandler(dialogPolicy != "dismiss")
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        note("dialog", ["kind": "prompt", "message": prompt])
        completionHandler(dialogPolicy == "dismiss" ? nil : (defaultText ?? ""))
    }

    // ------------------------------------------------------------ javascript

    /// Run `__pi(op)` (lib/page.js) in the injected world. A user script does not
    /// run on the initial empty document, so the script is evaluated first; its
    /// once-only guard makes that free.
    func callPage(_ op: [String: Any], _ done: @escaping (Result<[String: Any], PanelError>) -> Void) {
        web.evaluateJavaScript(script, in: nil, in: Self.world) { _ in
            self.web.callAsyncJavaScript("return __pi(op);", arguments: ["op": op], in: nil, in: Self.world) { result in
                switch result {
                case .failure(let e): done(.failure(PanelError(kind: "failed", message: Self.message(e))))
                case .success(let v):
                    guard let v = v as? [String: Any] else {
                        return done(.failure(PanelError(kind: "failed", message: "the page answered nothing")))
                    }
                    if let e = v["error"] as? [String: Any] {
                        return done(.failure(PanelError(kind: e["kind"] as? String ?? "failed",
                                                        message: e["message"] as? String ?? "page call failed")))
                    }
                    done(.success(v))
                }
            }
        }
    }

    /// Run agent JS in the page's own world. A function is called and a promise
    /// awaited; source that is not an expression (statements) runs as-is.
    func eval(_ source: String, _ done: @escaping (Result<Any, PanelError>) -> Void) {
        let body = "const v = (\n\(source)\n);\nreturn typeof v === \"function\" ? await v() : await v;"
        web.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .success(let v): done(.success(v))
            case .failure(let e) where Self.message(e).hasPrefix("SyntaxError"):
                self.web.evaluateJavaScript(source) { v, e in
                    if let e { return done(.failure(PanelError(kind: "failed", message: Self.message(e)))) }
                    done(.success(v ?? NSNull()))
                }
            case .failure(let e): done(.failure(PanelError(kind: "failed", message: Self.message(e))))
            }
        }
    }

    /// WebKit's `localizedDescription` for a script error is only "A JavaScript
    /// exception occurred"; the exception's own text is in the user info.
    private static func message(_ error: Error) -> String {
        (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
    }
}
