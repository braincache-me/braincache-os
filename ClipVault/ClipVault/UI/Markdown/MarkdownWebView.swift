import AppKit
import WebKit

/// Flipped `NSView` — y=0 at the top. Useful as the document view of an
/// `NSScrollView` that hosts top-aligned auto-layout content like a long
/// markdown answer that grows downward.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// `WKWebView` subclass that forwards scroll-wheel events to its next
/// responder when `forwardScrollWheel == true`. Used when the web view is
/// embedded inside an outer `NSScrollView` (e.g. as a chat bubble) — the
/// host scroll view should handle scrolling, not the web view's internal
/// page scroll.
private final class PassthroughWKWebView: WKWebView {
    var forwardScrollWheel: Bool = false

    override func scrollWheel(with event: NSEvent) {
        if forwardScrollWheel {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// AppKit view that renders Markdown via a bundled `WKWebView` + `marked.js` +
/// `highlight.js` + `mermaid.js`. Supports tables, fenced code blocks with
/// syntax highlighting, inline code, links, blockquotes, and Mermaid diagrams.
///
/// Height auto-grows: JavaScript posts the document height back via the
/// `sizeChanged` message handler and the view updates its internal height
/// constraint, so callers can drop it into a vertical layout the same way they
/// would an `NSTextField` and let it self-size.
final class MarkdownWebView: NSView {

    // MARK: - Public API

    /// Called whenever the rendered content height changes. Use this to
    /// re-layout a host scroll view if the web view is inside one. Always
    /// dispatched on the main thread.
    var onHeightChanged: ((CGFloat) -> Void)?

    /// Called when the user clicks a link inside the rendered markdown. If
    /// `nil`, the link opens in the default browser via `NSWorkspace`.
    var onLinkActivated: ((URL) -> Void)?

    /// Compact spacing — used for chat bubbles where vertical room is tight.
    /// AI Assist uses the default (false).
    var compact: Bool = false {
        didSet {
            guard compact != oldValue else { return }
            queueOrEvaluate("setCompact(\(compact ? "true" : "false"));")
        }
    }

    /// When true the web view scrolls itself (no auto-height bridging) —
    /// use this when the view is a full-size panel like the AI Assist
    /// response area. When false (default) the view sizes to its content
    /// and disables its own scrolling, suitable for chat bubbles inside an
    /// outer scroll view.
    let scrollable: Bool

    /// Latest markdown that's been pushed to the view (rendered, or queued
    /// until the page finishes loading).
    private(set) var markdown: String = ""

    // MARK: - Internals

    private let webView: WKWebView
    private var isReady = false
    private var pendingScripts: [String] = []
    private var heightConstraint: NSLayoutConstraint?
    private weak var handlerProxy: ScriptHandlerProxy?

    // MARK: - Init

    init(compact: Bool = false, scrollable: Bool = false) {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = false
        // Defer interactive media — we never load video anyway, but mermaid
        // can pull in large libs and we want them out of the critical path.
        config.mediaTypesRequiringUserActionForPlayback = .all

        let userContent = WKUserContentController()
        config.userContentController = userContent

        let wv = PassthroughWKWebView(frame: .zero, configuration: config)
        // Inline (non-scrollable) usage means the web view is hosted inside an
        // outer NSScrollView. Forward scroll-wheel events up the responder
        // chain so the host scroll view can scroll the conversation when the
        // cursor is over a rendered bubble.
        wv.forwardScrollWheel = !scrollable
        self.webView = wv
        self.compact = compact
        self.scrollable = scrollable

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        configureWebView(userContent: userContent)
        loadTemplate()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    deinit {
        // Detach script handlers so the proxy can be released. WKUserContent
        // Controller holds them strongly otherwise.
        let names = ["ready", "sizeChanged", "copyCode"]
        for name in names {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: name)
        }
    }

    // MARK: - Setup

    private func configureWebView(userContent: WKUserContentController) {
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self

        // Transparent background — the parent view supplies the bubble or
        // panel chrome behind us. WKWebView paints opaque by default; the
        // documented escape hatch is the `drawsBackground` KVC key.
        webView.setValue(false, forKey: "drawsBackground")
        webView.layer?.backgroundColor = NSColor.clear.cgColor

        addSubview(webView)

        var constraints: [NSLayoutConstraint] = [
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        if !scrollable {
            // Height is bridged from JS — start at a small placeholder so the
            // view doesn't collapse to zero before the page reports back.
            let h = heightAnchor.constraint(equalToConstant: 24)
            h.priority = .defaultHigh
            heightConstraint = h
            constraints.append(h)
        }
        NSLayoutConstraint.activate(constraints)

        let proxy = ScriptHandlerProxy(owner: self)
        handlerProxy = proxy
        userContent.add(proxy, name: "ready")
        userContent.add(proxy, name: "sizeChanged")
        userContent.add(proxy, name: "copyCode")
    }

    private func loadTemplate() {
        guard let htmlURL = Bundle.main.url(forResource: "markdown", withExtension: "html") else {
            assertionFailure("markdown.html is missing from the app bundle")
            return
        }
        let resourceDir = htmlURL.deletingLastPathComponent()
        webView.loadFileURL(htmlURL, allowingReadAccessTo: resourceDir)
    }

    // MARK: - Public methods

    /// Replace the rendered markdown with `text`. Safe to call before the
    /// page has finished loading — the call is queued and replayed once
    /// `ready` fires from JS.
    func setMarkdown(_ text: String) {
        markdown = text
        let escaped = encodeForJS(text)
        queueOrEvaluate("setMarkdown(\(escaped));")
    }

    /// Clear the rendered content. Useful when reusing the view for a new
    /// streaming response.
    func reset() {
        markdown = ""
        queueOrEvaluate("resetContent();")
    }

    // MARK: - Bridge helpers

    fileprivate func handleScriptMessage(name: String, body: Any) {
        switch name {
        case "ready":
            isReady = true
            evaluate("setCompact(\(compact ? "true" : "false"));")
            evaluate("setScrollable(\(scrollable ? "true" : "false"));")
            for script in pendingScripts { evaluate(script) }
            pendingScripts.removeAll()

        case "sizeChanged":
            guard let hc = heightConstraint else { return }
            guard let dict = body as? [String: Any],
                  let h = dict["height"] as? CGFloat else { return }
            // Clamp to a sane upper bound — runaway content (very long
            // mermaid SVG, huge tables) could otherwise push layout past
            // what AppKit can render in one pass.
            let clamped = max(1, min(h, 100_000))
            if abs(hc.constant - clamped) > 0.5 {
                hc.constant = clamped
                onHeightChanged?(clamped)
            }

        case "copyCode":
            guard let dict = body as? [String: Any],
                  let text = dict["text"] as? String else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)

        default:
            break
        }
    }

    private func queueOrEvaluate(_ script: String) {
        if isReady {
            evaluate(script)
        } else {
            pendingScripts.append(script)
        }
    }

    private func evaluate(_ script: String) {
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    /// JSON-encode a string so it can be safely embedded as a JS literal —
    /// e.g. `setMarkdown(<this>);`. Falls back to `""` on encoder failure.
    private func encodeForJS(_ s: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [s], options: []),
           let arr = String(data: data, encoding: .utf8),
           arr.count >= 2 {
            // ["…"] → "…"
            return String(arr.dropFirst().dropLast())
        }
        return "\"\""
    }
}

// MARK: - Navigation delegate (link policy)

extension MarkdownWebView: WKNavigationDelegate {

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // First load (the bundled template) is .other and we always allow it.
        if navigationAction.navigationType == .other,
           navigationAction.request.url?.isFileURL == true {
            decisionHandler(.allow)
            return
        }
        // Link clicks: hand to the system browser or the caller's handler.
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url {
            if let onLinkActivated {
                onLinkActivated(url)
            } else {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

// MARK: - Script handler proxy

/// WKUserContentController retains its message handlers; using the view as
/// its own handler would create a retain cycle. The proxy weakly references
/// the owning view and forwards messages back to it.
private final class ScriptHandlerProxy: NSObject, WKScriptMessageHandler {
    weak var owner: MarkdownWebView?

    init(owner: MarkdownWebView) {
        self.owner = owner
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        owner?.handleScriptMessage(name: message.name, body: message.body)
    }
}
