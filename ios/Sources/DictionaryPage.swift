import SwiftUI
import WebKit
import UniformTypeIdentifiers

struct DictionaryPage: UIViewRepresentable {
    let html: String
    let root: URL
    let code: String
    var paperRGB: Int? = nil
    var accentRGB: Int? = nil
    var textSize: Double = 19
    var sansFont = false
    var initialOffset: CGPoint = .zero
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
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src jpread: data:; media-src jpread:; font-src jpread:; style-src 'unsafe-inline' jpread:; script-src 'none'; frame-src 'none'; connect-src 'none'; form-action 'none'; base-uri 'none'">
        <style>\(safeCSS)</style><style>\(DictionaryBookStyle.css)</style><style>ddudm,ddudc,ddudt{display:block}img{max-width:100%;height:auto;border-radius:6px}audio{max-width:100%;margin:5px 0}</style></head><body>\(rendered)</body></html>
        """
    }
    static let selectionWorld = WKContentWorld.world(name: "JapaneseReaderSelection")
    static func evaluateSelectionScript(_ script: String, in view: WKWebView, completion: @escaping (Any?, Error?) -> Void) {
        JPReaderEvaluate(view, script, completion)
    }
    static let selectionScript = """
    (() => {
        let pending, previous = "";
        document.addEventListener("selectionchange", () => {
            clearTimeout(pending);
            const text = window.getSelection()?.toString().trim() || "";
            if (!text || Array.from(text).length > 40) { previous = ""; window.webkit.messageHandlers.readerSelection.postMessage(""); return; }
            pending = setTimeout(() => {
                const current = window.getSelection()?.toString().trim() || "";
                if (current !== text || current === previous) return;
                previous = current;
                window.webkit.messageHandlers.readerSelection.postMessage(current);
            }, 400);
        });
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
    static func makeWebView(html: String, coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(coordinator, forURLScheme: "jpread")
        configuration.userContentController.add(coordinator, contentWorld: selectionWorld, name: "readerSelection")
        configuration.userContentController.addUserScript(WKUserScript(source: selectionScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: selectionWorld))
        // Entry pages follow the chosen iOS theme through the book stylesheet's
        // --e-* variables: background, readable ink, accent, example colour, type.
        let themeCSS = DictionaryBookStyle.variables(backgroundRGB: coordinator.paperRGB, accentRGB: coordinator.accentRGB,
                                                     size: coordinator.textSize, sans: coordinator.sansFont)
        if !themeCSS.isEmpty {
            let script = "const s=document.createElement('style');s.textContent='\(themeCSS)';document.head.appendChild(s);"
            configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: selectionWorld))
        }
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.scrollView.delegate = coordinator
        view.accessibilityIdentifier = "dictionaryEntryPage"
        view.navigationDelegate = coordinator
        view.loadHTMLString(html, baseURL: URL(string: "jpread://dictionary/"))
        return view
    }
    func makeUIView(context: Context) -> WKWebView { Self.makeWebView(html: html, coordinator: context.coordinator) }
    // Search results update the surrounding SwiftUI view. Never reload the document
    // here: that would discard the native selection handles and scroll position.
    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.lookup = lookup
        context.coordinator.followLink = followLink
        view.backgroundColor = paperRGB.map { UIColor(Palette.color($0)) } ?? .systemBackground
        view.scrollView.backgroundColor = view.backgroundColor
        context.coordinator.paperRGB = paperRGB
        context.coordinator.accentRGB = accentRGB
        context.coordinator.saveOffset = saveOffset
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
        var sansFont = false
        var initialOffset: CGPoint = .zero
        var saveOffset: ((CGPoint) -> Void)?
        private var loaded = false
        func scrollViewDidScroll(_ scrollView: UIScrollView) { if loaded { saveOffset?(scrollView.contentOffset) } }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.scrollView.setContentOffset(initialOffset, animated: false)
            loaded = true
        }
        let queue = DispatchQueue(label: "JapaneseReader.media")
        var cancelled = Set<ObjectIdentifier>()
        init(root: URL, code: String, followLink: ((String) -> Void)? = nil, lookup: @escaping (String) -> Void) { self.root = root; self.code = code; self.lookup = lookup; self.followLink = followLink }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "readerSelection", message.frameInfo.isMainFrame,
                  let text = message.body as? String else { return }
            let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard word.count <= 40 else { return }
            lookup(word)
        }
        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            let id = ObjectIdentifier(urlSchemeTask)
            cancelled.remove(id)
            let url = urlSchemeTask.request.url!
            queue.async {
                let result = Result { try DictionaryStore(root: self.root).media(code: self.code, name: url.path) }
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
