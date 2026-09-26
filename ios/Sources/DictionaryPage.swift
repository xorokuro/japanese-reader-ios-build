import SwiftUI
import WebKit
import UniformTypeIdentifiers

/// Entry page web view that can keep the iPhone's Copy / Look Up bar and Writing
/// Tools out of the way while the dictionary card handles selections.
final class ReaderWebView: WKWebView {
    var quietMenu = false
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        quietMenu ? false : super.canPerformAction(action, withSender: sender)
    }
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard quietMenu else { return }
        builder.remove(menu: .lookup)
        builder.remove(menu: .share)
        builder.remove(menu: .standardEdit)
        builder.remove(menu: .replace)
    }
}

struct DictionaryPage: UIViewRepresentable {
    let html: String
    let root: URL
    let code: String
    var paperRGB: Int? = nil
    var accentRGB: Int? = nil
    var textSize: Double = 19
    var sansFont = false
    var initialOffset: CGPoint = .zero
    /// Room kept free at the bottom while the dictionary card covers the page.
    var bottomInset: CGFloat = 0
    /// Hide the iPhone Copy / Look Up bar (the dictionary card replaces it).
    var quietMenu = false
    /// Two-finger swipe up / down to change the definition text size.
    var resize: TextResize? = nil
    var saveOffset: ((CGPoint) -> Void)? = nil
    var followLink: ((String) -> Void)? = nil
    let lookup: (String) -> Void
    static func audioLinks(_ source: String) -> String {
        guard let pattern = try? NSRegularExpression(pattern: "(?is)<a\\b[^>]*href=[\"']sound://([^\"']+)[\"'][^>]*>.*?</a>") else { return source }
        var result = source
        for match in pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            guard let range = Range(match.range, in: result), let nameRange = Range(match.range(at: 1), in: source) else { continue }
            let name = String(source[nameRange]).replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
            result.replaceSubrange(range, with: "<audio controls preload=\"none\" src=\"jpread://dictionary/\(encoded)\"></audio>")
        }
        return result
    }
    static func make(body: String, css: String, code: String) -> String {
        // Dictionary-authored JavaScript is disabled; only our isolated selection observer runs.
        // CSP continues to prevent external requests and page scripts.
        let clean = body.replacingOccurrences(of: "(?is)<(script|iframe|object|embed|form|head)\\b[^>]*>.*?</\\1\\s*>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "(?is)<(base|meta|link)\\b[^>]*>", with: "", options: .regularExpression)
        let safeCSS = css.replacingOccurrences(of: "(?is)</style", with: "", options: .regularExpression)
        let rendered = audioLinks(clean)
        return """
        <!doctype html><html lang="ja"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src jpread: data:; media-src jpread:; font-src jpread:; style-src 'unsafe-inline' jpread:; script-src 'none'; frame-src 'none'; connect-src 'none'; form-action 'none'; base-uri 'none'">
        <style>\(safeCSS)</style><style>\(DictionaryBookStyle.css)</style><style>ddudm,ddudc,ddudt{display:block}img{max-width:100%;height:auto;border-radius:6px}audio{max-width:100%;margin:5px 0}</style></head><body>\(rendered)</body></html>
        """
    }
    static let selectionWorld = WKContentWorld.world(name: "JapaneseReaderSelection")
    static func evaluateSelectionScript(_ script: String, in view: WKWebView, completion: @escaping (Any?, Error?) -> Void) {
        JPReaderEvaluate(view, script, completion)
    }
    /// Posts the selection (with a few neighbouring characters) after it settles, and
    /// exposes `__jpRefine` so the peek card can move the selection by characters.
    static let selectionScript = """
    (() => {
        let pending, previous = "";
        const LIMIT = 12;
        const post = (value) => window.webkit.messageHandlers.readerSelection.postMessage(value);
        const blockOf = (node) => {
            let element = node && node.nodeType === 1 ? node : (node ? node.parentElement : null);
            while (element && element !== document.body) {
                const display = getComputedStyle(element).display || "";
                if (display !== "contents" && !display.startsWith("inline") && display !== "ruby" && display !== "ruby-text") return element;
                element = element.parentElement;
            }
            return document.body;
        };
        const clip = (text, tail) => {
            const lines = text.split(/\\s/);
            let part = tail ? lines[lines.length - 1] : lines[0];
            if (tail) {
                part = part.slice(-LIMIT);
                if (/^[\\uDC00-\\uDFFF]/.test(part)) part = part.slice(1);
            } else {
                part = part.slice(0, LIMIT);
                if (/[\\uD800-\\uDBFF]$/.test(part)) part = part.slice(0, -1);
            }
            return part;
        };
        const context = (range) => {
            try {
                const head = document.createRange();
                head.setStart(blockOf(range.startContainer), 0);
                head.setEnd(range.startContainer, range.startOffset);
                const endBlock = blockOf(range.endContainer);
                const tail = document.createRange();
                tail.setStart(range.endContainer, range.endOffset);
                tail.setEnd(endBlock, endBlock.childNodes.length);
                return { before: clip(head.toString(), true), after: clip(tail.toString(), false) };
            } catch (error) { return { before: "", after: "" }; }
        };
        document.addEventListener("selectionchange", () => {
            clearTimeout(pending);
            const text = window.getSelection()?.toString().trim() || "";
            if (!text || Array.from(text).length > (window.__jpLimit || 40)) { previous = ""; post(""); return; }
            pending = setTimeout(() => {
                const selection = window.getSelection();
                const raw = selection ? selection.toString() : "";
                const current = raw.trim();
                if (current !== text || current === previous) return;
                previous = current;
                const range = selection.rangeCount ? selection.getRangeAt(0).cloneRange() : null;
                window.__jpLast = range;
                const around = range ? context(range) : { before: "", after: "" };
                const lead = raw.length - raw.trimStart().length, trail = raw.length - raw.trimEnd().length;
                post({ text: current, before: around.before + raw.slice(0, lead), after: raw.slice(raw.length - trail) + around.after });
            }, 250);
        });
        const textNodes = () => {
            const nodes = [], walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
            let node;
            while ((node = walker.nextNode())) nodes.push(node);
            return nodes;
        };
        const indexOf = (container, offset) => {
            const range = document.createRange();
            range.setStart(document.body, 0);
            range.setEnd(container, offset);
            return range.toString().length;
        };
        const pointAt = (nodes, target, preferNext) => {
            let total = 0;
            for (const node of nodes) {
                const length = node.data.length;
                if (preferNext ? target < total + length : target <= total + length) return [node, Math.max(0, target - total)];
                total += length;
            }
            const last = nodes[nodes.length - 1];
            return last ? [last, last.data.length] : null;
        };
        window.__jpRefine = (startDelta, endDelta) => {
            const base = window.__jpLast;
            if (!base) return false;
            const nodes = textNodes();
            if (!nodes.length) return false;
            const start = indexOf(base.startContainer, base.startOffset) + startDelta;
            const end = indexOf(base.endContainer, base.endOffset) + endDelta;
            if (start < 0 || end <= start) return false;
            const from = pointAt(nodes, start, true), to = pointAt(nodes, end, false);
            if (!from || !to) return false;
            const range = document.createRange();
            range.setStart(from[0], from[1]);
            range.setEnd(to[0], to[1]);
            const selection = window.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
            return true;
        };
    })();
    """
    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(root: root, code: code, followLink: followLink, lookup: lookup)
        coordinator.paperRGB = paperRGB
        coordinator.accentRGB = accentRGB
        coordinator.textSize = textSize
        coordinator.sansFont = sansFont
        coordinator.initialOffset = initialOffset
        coordinator.saveOffset = saveOffset
        return coordinator
    }
    /// One private, in-memory data store for every entry page, so WebKit can reuse
    /// its web-content process instead of starting a fresh one for each definition.
    static let dataStore = WKWebsiteDataStore.nonPersistent()
    private static var warmView: WKWebView?
    /// Starts WebKit before the first lookup so the first definition opens quickly.
    static func prewarm() {
        guard warmView == nil else { return }
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = dataStore
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 10, height: 10), configuration: configuration)
        view.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: nil)
        warmView = view
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { DictionaryPage.warmView = nil }
    }
    static func makeWebView(html: String, coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = dataStore
        if #available(iOS 18.0, *) { configuration.writingToolsBehavior = UIWritingToolsBehavior.none }
        configuration.setURLSchemeHandler(coordinator, forURLScheme: "jpread")
        configuration.userContentController.add(coordinator, contentWorld: selectionWorld, name: "readerSelection")
        configuration.userContentController.addUserScript(WKUserScript(source: "window.__jpLimit = \(SelectionLimit.current);", injectionTime: .atDocumentStart, forMainFrameOnly: true, in: selectionWorld))
        configuration.userContentController.addUserScript(WKUserScript(source: selectionScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: selectionWorld))
        // Entry pages follow the chosen iOS theme through the book stylesheet's
        // --e-* variables: background, readable ink, accent, example colour, type.
        let themeCSS = DictionaryBookStyle.variables(backgroundRGB: coordinator.paperRGB, accentRGB: coordinator.accentRGB,
                                                     size: coordinator.textSize, sans: coordinator.sansFont)
        if !themeCSS.isEmpty {
            let script = "const s=document.createElement('style');s.textContent='\(themeCSS)';document.head.appendChild(s);"
            configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: selectionWorld))
        }
        let view = ReaderWebView(frame: .zero, configuration: configuration)
        view.scrollView.delegate = coordinator
        view.accessibilityIdentifier = "dictionaryEntryPage"
        view.navigationDelegate = coordinator
        view.isOpaque = false
        view.loadHTMLString(html, baseURL: URL(string: "jpread://dictionary/"))
        coordinator.sizeSwipe.attach(to: view, scrollView: view.scrollView)
        SelectionBridge.shared.dictionaryView = view
        return view
    }
    func makeUIView(context: Context) -> WKWebView { Self.makeWebView(html: html, coordinator: context.coordinator) }
    // Search results update the surrounding SwiftUI view. Never reload the document
    // here: that would discard the native selection handles and scroll position.
    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.lookup = lookup
        context.coordinator.followLink = followLink
        (view as? ReaderWebView)?.quietMenu = quietMenu
        context.coordinator.sizeSwipe.resize = resize
        context.coordinator.sizeSwipe.claimTwoFingers()
        // Size changes restyle the open page in place (no reload, scroll kept).
        if context.coordinator.textSize != textSize {
            context.coordinator.textSize = textSize
            Self.evaluateSelectionScript("document.documentElement.style.setProperty('--e-size', '\(Int(textSize.rounded()))px'); true", in: view) { _, _ in }
        }
        view.backgroundColor = paperRGB.map { UIColor(Palette.color($0)) } ?? .systemBackground
        view.scrollView.backgroundColor = view.backgroundColor
        context.coordinator.paperRGB = paperRGB
        context.coordinator.accentRGB = accentRGB
        context.coordinator.saveOffset = saveOffset
        if view.scrollView.contentInset.bottom != bottomInset {
            view.scrollView.contentInset.bottom = bottomInset
            view.scrollView.verticalScrollIndicatorInsets.bottom = bottomInset
            if bottomInset > 0 {
                // Scroll the selected words above the card.
                let script = "(() => { const s = getSelection(); if (!s || !s.rangeCount) return false; const r = s.getRangeAt(0).getBoundingClientRect(); const limit = window.innerHeight - \(Int(bottomInset)); if (r.bottom > limit - 8) window.scrollBy({ top: r.bottom - limit + 28, behavior: 'smooth' }); return true; })()"
                Self.evaluateSelectionScript(script, in: view) { _, _ in }
            }
        }
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "readerSelection", contentWorld: selectionWorld)
        view.stopLoading()
    }
    final class Coordinator: NSObject, WKURLSchemeHandler, WKNavigationDelegate, WKScriptMessageHandler, UIScrollViewDelegate {
        let root: URL
        let code: String
        var lookup: (String) -> Void
        var followLink: ((String) -> Void)?
        var paperRGB: Int?
        var accentRGB: Int?
        var textSize: Double = 19
        let sizeSwipe = TextSizeSwipe()
        var sansFont = false
        var initialOffset: CGPoint = .zero
        var saveOffset: ((CGPoint) -> Void)?
        private var loaded = false
        func scrollViewDidScroll(_ scrollView: UIScrollView) { if loaded { saveOffset?(scrollView.contentOffset) } }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.scrollView.setContentOffset(initialOffset, animated: false)
            sizeSwipe.claimTwoFingers()
            loaded = true
        }
        let queue = DispatchQueue(label: "JapaneseReader.media")
        var cancelled = Set<ObjectIdentifier>()
        init(root: URL, code: String, followLink: ((String) -> Void)? = nil, lookup: @escaping (String) -> Void) { self.root = root; self.code = code; self.lookup = lookup; self.followLink = followLink }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "readerSelection", message.frameInfo.isMainFrame else { return }
            var context = SelectionContext()
            if let text = message.body as? String {
                context.text = text
            } else if let body = message.body as? [String: Any], let text = body["text"] as? String {
                context.text = text
                context.before = body["before"] as? String ?? ""
                context.after = body["after"] as? String ?? ""
            } else { return }
            let word = context.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard word.count <= SelectionLimit.current else { return }
            context.text = word
            SelectionBridge.shared.dictionaryContext = context
            lookup(word)
        }
        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            let id = ObjectIdentifier(urlSchemeTask)
            cancelled.remove(id)
            let url = urlSchemeTask.request.url!
            queue.async {
                let result = Result { try DictionaryStore.shared(root: self.root).media(code: self.code, name: url.path) }
                DispatchQueue.main.async {
                    guard !self.cancelled.contains(id) else { self.cancelled.remove(id); return }
                    switch result {
                    case .success(let data):
                        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
                        urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
                    case .failure(let error): urlSchemeTask.didFailWithError(error)
                    }
                }
            }
        }
        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) { cancelled.insert(ObjectIdentifier(urlSchemeTask)) }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if url.scheme == "entry" {
                let value = String(url.absoluteString.dropFirst("entry://".count)).components(separatedBy: "#")[0].removingPercentEncoding ?? ""
                (followLink ?? lookup)(value); decisionHandler(.cancel)
            } else if action.navigationType == .other && (url.scheme == "about" || url.scheme == "jpread") { decisionHandler(.allow) }
            else { decisionHandler(.cancel) }
        }
    }
}
