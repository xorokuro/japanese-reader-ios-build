import SwiftUI
import WebKit
import UniformTypeIdentifiers

// A grammar lesson (詳解) shown in the reader's own hand-drawn look instead of the
// lesson file's stylesheet. The lesson's structure is kept (意思・接續・例句・
// 類義比較・常見共起表現・注意點・小測驗); only its presentation changes.
// Furigana is drawn by the stylesheet, so selecting a word selects only the
// word itself and the dictionary card can look it up directly.

enum GrammarLessonHTML {
    /// Turns a lesson file into a page for the app. `css` is the theme stylesheet.
    static func make(source: String, css: String) -> String {
        var body = source
        if let open = source.range(of: "<body[^>]*>", options: [.regularExpression, .caseInsensitive]),
           let close = source.range(of: "</body>", options: [.caseInsensitive, .backwards]),
           open.upperBound <= close.lowerBound {
            body = String(source[open.upperBound..<close.lowerBound])
        }
        body = body
            .replacingOccurrences(of: "(?is)<(script|iframe|object|embed|form|style|head|noscript)\\b[^>]*>.*?</\\1\\s*>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "(?is)<(base|meta|link|input)\\b[^>]*>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "(?is)<a\\b[^>]*class=\"back\"[^>]*>.*?</a>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "(?i)\\son[a-z]+\\s*=\\s*(\"[^\"]*\"|'[^']*')", with: "", options: .regularExpression)
            .replacingOccurrences(of: "(?i)href\\s*=\\s*\"(javascript|https?|file):[^\"]*\"", with: "href=\"#\"", options: .regularExpression)
        body = movingReadings(body)
        return """
        <!doctype html><html lang="zh-Hant"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src jpgrammar: data:; font-src jpgrammar:; style-src 'unsafe-inline'; script-src 'none'; frame-src 'none'; connect-src 'none'; form-action 'none'; base-uri 'none'">
        <style>\(css)</style></head><body>\(body)</body></html>
        """
    }

    /// `<rt>ぬ</rt>` → `<rt data-r="ぬ"></rt>`: the reading is drawn by CSS, so it is
    /// never part of a text selection (選んだ「抜く」 stays 「抜く」, not 「抜ぬく」).
    static func movingReadings(_ html: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<rt\\b[^>]*>([\\s\\S]*?)</rt>", options: [.caseInsensitive]) else { return html }
        let text = html as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: html, range: NSRange(location: 0, length: text.length)) {
            result += text.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let reading = text.substring(with: match.range(at: 1))
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "<", with: "&lt;")
            result += "<rt data-r=\"\(reading)\"></rt>"
            cursor = match.range.location + match.range.length
        }
        result += text.substring(from: cursor)
        return result
    }
}

enum GrammarLessonStyle {
    /// Theme colours for the page, from the active reader theme.
    static func variables(style: ReaderStyle, size: Double, typeface: ReaderTypeface) -> String {
        let dark = style.isDark
        let bg = style.surfaceRGB ?? (dark ? 0x1C1C1E : 0xFFFFFF)
        let ink = style.usesSystemSurfaces ? (dark ? 0xF2F2F7 : 0x1C1C1E) : Palette.rgb(style.ink)
        let accent = Palette.rgb(style.accent)
        let tape = Palette.rgb(style.tape)
        let marker = Palette.rgb(style.marker)
        let hex = Palette.hexString
        let jp: String
        switch typeface {
        case .kyokasho: jp = "\"GKlee\",\"Hiragino Sans\",\"PingFang TC\",sans-serif"
        case .gothic: jp = "\"Hiragino Sans\",\"PingFang TC\",sans-serif"
        case .mincho: jp = "\"Hiragino Mincho ProN\",\"Songti TC\",serif"
        case .rounded: jp = "\"Hiragino Maru Gothic ProN\",\"PingFang TC\",sans-serif"
        }
        var rules = ":root{"
        rules += "--g-bg:\(hex(bg));--g-ink:\(hex(ink));"
        rules += "--g-muted:\(hex(Palette.mix(ink, toward: bg, 0.36)));--g-faint:\(hex(Palette.mix(ink, toward: bg, 0.55)));"
        rules += "--g-line:\(hex(Palette.mix(ink, toward: bg, 0.74)));--g-hair:\(hex(Palette.mix(ink, toward: bg, 0.86)));"
        rules += "--g-raised:\(hex(Palette.mix(bg, toward: ink, dark ? 0.06 : 0.035)));"
        rules += "--g-paper2:\(hex(Palette.mix(bg, toward: tape, dark ? 0.10 : 0.08)));"
        rules += "--g-accent:\(hex(accent));--g-accent-soft:\(hex(Palette.mix(bg, toward: accent, dark ? 0.20 : 0.11)));"
        rules += "--g-on-accent:\(hex(Palette.rgb(style.onAccent)));"
        rules += "--g-tape:\(hex(tape));--g-marker:\(hex(marker));"
        rules += "--g-marker-soft:\(hex(Palette.mix(bg, toward: marker, dark ? 0.34 : 0.42)));"
        rules += "--g-rt:\(hex(Palette.mix(accent, toward: bg, 0.18)));"
        rules += "--g-shade:\(dark ? "rgba(0,0,0,.34)" : hex(Palette.mix(bg, toward: ink, 0.14)));"
        rules += "--g-size:\(Int(size.rounded()))px;--g-jp:\(jp);"
        rules += "color-scheme:\(dark ? "dark" : "light");}"
        return rules
    }

    /// The desktop "Washi" look in CSS: wobbly pencil boxes with an offset shadow,
    /// highlighter headings, washi tape, marker highlights and a wavy rule.
    static let css = #"""
@font-face{font-family:"GKlee";src:url("jpgrammar://font/KleeOne-Regular.ttf") format("truetype");font-weight:400;font-display:swap}
@font-face{font-family:"GKlee";src:url("jpgrammar://font/KleeOne-SemiBold.ttf") format("truetype");font-weight:600 800;font-display:swap}
:root{
 --g-zh:-apple-system,"PingFang TC","Hiragino Sans",sans-serif;
 --g-title:"GKlee","Hiragino Sans","PingFang TC",sans-serif;
 --g-wobble:18px 7px 16px 8px/8px 16px 7px 18px;
 --g-wobble2:9px 16px 8px 18px/16px 8px 18px 9px;
 --g-pad:14px;
 /* The lesson files' own names, mapped onto the reader theme. */
 --paper:var(--g-bg);--paper-2:var(--g-paper2);--card:var(--g-raised);--ink:var(--g-ink);--muted:var(--g-muted);--faint:var(--g-faint);
 --line:var(--g-line);--line-soft:var(--g-hair);--indigo:var(--g-accent);--lv:var(--g-accent);--lvbg:var(--g-accent-soft);
 --n5:var(--g-accent);--n4:var(--g-accent);--n3:var(--g-accent);--n2:var(--g-accent);--n1:var(--g-accent);
 --serif:var(--g-jp);--sans:var(--g-zh);
}
*{box-sizing:border-box}
html,body{margin:0;padding:0;background:var(--g-bg);color:var(--g-ink);overscroll-behavior:contain;overflow-anchor:none}
body{font:400 var(--g-size)/1.78 var(--g-zh);-webkit-text-size-adjust:none;overflow-wrap:anywhere;-webkit-font-smoothing:antialiased;
 padding:var(--g-pad) var(--g-pad) 60px;-webkit-user-select:text;user-select:text}
.wrap{max-width:760px;margin:0 auto}
p{margin:0 0 .5em}
b,strong{font-weight:700}
a{color:var(--g-accent);text-decoration:underline;text-decoration-thickness:1px;text-underline-offset:3px;text-decoration-color:color-mix(in srgb,var(--g-accent) 45%,transparent)}
::selection{background:color-mix(in srgb,var(--g-accent) 30%,transparent)}

/* Furigana: drawn from data-r, never selected or copied. */
ruby{ruby-position:over}
rt{font:500 .52em/1 var(--g-zh);color:var(--g-rt);letter-spacing:0;-webkit-user-select:none;user-select:none}
rt::before{content:attr(data-r)}

/* Header */
header.h{position:relative;margin:4px 0 22px;padding:2px 0 18px}
header.h::after{content:"";position:absolute;left:0;right:0;bottom:0;height:8px;background:var(--g-line);
 -webkit-mask:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='30' height='8'%3E%3Cpath d='M0 4 Q7.5 -1.2 15 4 T30 4' fill='none' stroke='black' stroke-width='1.6' stroke-linecap='round'/%3E%3C/svg%3E") repeat-x left center/30px 8px;
 mask:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='30' height='8'%3E%3Cpath d='M0 4 Q7.5 -1.2 15 4 T30 4' fill='none' stroke='black' stroke-width='1.6' stroke-linecap='round'/%3E%3C/svg%3E") repeat-x left center/30px 8px}
.badge{display:inline-block;font:600 .82em/1 var(--g-title);color:var(--g-on-accent);background:var(--g-accent);
 padding:7px 11px 6px;border-radius:var(--g-wobble2);transform:rotate(-4deg);box-shadow:2px 3px 0 -1px var(--g-shade);letter-spacing:.06em}
h1{font:600 1.72em/1.45 var(--g-title);margin:.35em 0 .1em;letter-spacing:.01em}
h1 rt{font-family:var(--g-zh)}
.hsub{color:var(--g-muted);font-size:.9em;line-height:1.65}
.revision-note{display:inline-block;margin-top:10px!important;font:600 11.5px/1.4 var(--g-zh)!important;color:var(--g-muted)!important;
 background:var(--g-marker-soft);padding:2px 9px;border-radius:var(--g-wobble2);letter-spacing:.04em}

/* Section headings: highlighter stroke, like the reader's titles. */
section{margin:0 0 26px}
h2{display:inline;font:600 1.18em/1.5 var(--g-title);letter-spacing:.04em;color:var(--g-ink);padding:0 3px;
 background:linear-gradient(transparent 60%,var(--g-marker-soft) 60%,var(--g-marker-soft) 92%,transparent 92%)}
h2 small{font:500 .6em var(--g-zh);color:var(--g-faint);letter-spacing:.02em;margin-left:8px;background:var(--g-bg)}
h2+*{margin-top:12px}
section>h2{display:inline-block;margin-bottom:12px}

/* Sketched boxes */
.box,.cmp,.q,.ex{background:var(--g-raised);border:1.5px solid var(--g-line);border-radius:var(--g-wobble);
 box-shadow:3px 4px 0 -1px var(--g-shade);padding:12px 14px;position:relative}
.box{margin-bottom:10px}
section:first-of-type .box::before{content:"";position:absolute;top:-11px;left:26px;width:92px;height:20px;transform:rotate(-5deg);
 background:repeating-linear-gradient(-55deg,color-mix(in srgb,var(--g-tape) 62%,transparent) 0 7px,color-mix(in srgb,var(--g-tape) 40%,transparent) 7px 14px);
 clip-path:polygon(3% 0,97% 4%,100% 22%,96% 40%,100% 62%,97% 100%,2% 96%,0 74%,4% 52%,0 30%)}
.ety{background:var(--g-paper2);border:1.3px dashed var(--g-line);border-radius:var(--g-wobble2);padding:10px 12px;margin-top:12px;font-size:.88em;color:var(--g-muted)}
.ety b{color:var(--g-ink)}

/* 接續 */
.setsu{font-family:var(--g-jp);font-size:1.02em;line-height:2.15;background:var(--g-accent-soft);border:1.5px solid var(--g-line);
 border-radius:var(--g-wobble2);box-shadow:3px 4px 0 -1px var(--g-shade);padding:10px 14px}
.setsu b{color:var(--g-accent)}
.setsu .sn,.sn{font:400 .8em/1.7 var(--g-zh);color:var(--g-muted)}

/* 例句 */
.ex{margin-bottom:12px;padding-top:10px}
.ex::after{content:"";position:absolute;left:-1px;top:14px;bottom:14px;width:3px;border-radius:3px;background:var(--g-accent);opacity:.75}
.reg{display:inline-block;font:600 .66em/1.9 var(--g-zh);letter-spacing:.06em;color:var(--g-ink);padding:0 9px;margin:0 0 4px;
 background:color-mix(in srgb,var(--g-tape) 34%,transparent);border-radius:var(--g-wobble2);transform:rotate(-1.5deg)}
.jp{font-family:var(--g-jp);font-size:1.1em;line-height:2.3}
.zh{color:var(--g-muted);font-size:.86em;line-height:1.7;margin-top:2px}
.note-l{font-size:.78em;color:var(--g-accent);margin-top:4px}
mark{color:inherit;padding:0 1px;border-radius:3px 6px 4px 7px;
 background:linear-gradient(100deg,transparent 0,var(--g-marker-soft) 3%,var(--g-marker-soft) 97%,transparent 100%)}

/* 類義比較 */
.cmp{margin-bottom:14px}
.cmp .vs{display:inline-block;font:600 .66em/1.8 var(--g-zh);color:var(--g-accent);border:1.3px solid var(--g-accent);
 border-radius:var(--g-wobble2);padding:0 7px;margin-right:7px;vertical-align:middle;background:var(--g-bg)}
.v-N5,.v-N4,.v-N3,.v-N2,.v-N1{background:var(--g-bg)}
.cmp h3{display:inline;font:600 1.05em/1.5 var(--g-title);vertical-align:middle;margin:0}
.cmp .pt{margin-top:8px;font-size:.92em}
.cmp .pt b{color:var(--g-accent)}
.swap{background:var(--g-paper2);border-left:3px dashed var(--g-accent);border-radius:0 10px 12px 0;padding:8px 12px;margin-top:9px;font-size:.88em}
.swap b{color:var(--g-accent)}

/* 常見共起表現 */
.col{display:flex;flex-wrap:wrap;gap:9px;margin:4px 0 6px}
.chip{font-family:var(--g-jp);font-size:.95em;line-height:1.9;background:var(--g-bg);border:1.3px solid var(--g-line);
 border-radius:var(--g-wobble2);box-shadow:2px 3px 0 -1px var(--g-shade);padding:1px 11px}

/* 注意點 */
ul{padding-left:1.25em;margin:0}
li{margin-bottom:.6em}
li::marker{color:var(--g-accent)}

/* 小測驗 */
.q{margin-bottom:16px}
.q .qt{font:600 .95em/1.6 var(--g-zh);margin-bottom:6px}
.q .jp{font-size:1.06em}
details{background:var(--g-paper2);border:1.3px dashed var(--g-line);border-radius:var(--g-wobble2);padding:9px 12px;margin-top:10px}
details[open]{background:var(--g-bg);border-style:solid}
summary{cursor:pointer;font:600 .88em/1.6 var(--g-title);color:var(--g-accent);-webkit-user-select:none;user-select:none;list-style:none}
summary::-webkit-details-marker{display:none}
summary::before{content:"✎ ";}
details[open] summary{margin-bottom:6px}

table{border-collapse:collapse;max-width:100%;font-size:.9em}
td,th{border:1px solid var(--g-line);padding:4px 8px;vertical-align:top}
img{max-width:100%;height:auto}
footer{margin-top:36px;padding-top:12px;border-top:1.3px dashed var(--g-line);color:var(--g-faint);font-size:.74em;text-align:center}
"""#
}

struct GrammarLessonPage: UIViewRepresentable {
    let html: String
    let lessonsFolder: URL
    var textSize: Double
    var initialOffset: CGPoint = .zero
    /// Room kept free at the bottom while the dictionary card covers the page.
    var bottomInset: CGFloat = 0
    var quietMenu = false
    var resize: TextResize? = nil
    var margins: PageMargins = .compact
    var saveOffset: ((CGPoint) -> Void)? = nil
    /// A link to another lesson file (…→ 該句型詳解).
    var openLesson: (String) -> Void
    let lookup: (String) -> Void

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(lessonsFolder: lessonsFolder, openLesson: openLesson, lookup: lookup)
        coordinator.textSize = textSize
        coordinator.margins = margins
        coordinator.initialOffset = initialOffset
        coordinator.saveOffset = saveOffset
        return coordinator
    }

    func makeUIView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = DictionaryPage.dataStore
        if #available(iOS 18.0, *) { configuration.writingToolsBehavior = UIWritingToolsBehavior.none }
        configuration.setURLSchemeHandler(coordinator, forURLScheme: "jpgrammar")
        configuration.userContentController.add(coordinator, contentWorld: DictionaryPage.selectionWorld, name: "readerSelection")
        configuration.userContentController.addUserScript(WKUserScript(source: "window.__jpLimit = \(SelectionLimit.current);", injectionTime: .atDocumentStart, forMainFrameOnly: true, in: DictionaryPage.selectionWorld))
        configuration.userContentController.addUserScript(WKUserScript(source: DictionaryPage.selectionScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: DictionaryPage.selectionWorld))
        configuration.userContentController.addUserScript(WKUserScript(source: "document.documentElement.style.setProperty('--g-pad', '\(margins.pagePadding + 2)px'); true", injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: DictionaryPage.selectionWorld))
        let view = ReaderWebView(frame: .zero, configuration: configuration)
        view.quietMenu = quietMenu
        view.scrollView.delegate = coordinator
        view.accessibilityIdentifier = "grammarLessonPage"
        view.navigationDelegate = coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.loadHTMLString(html, baseURL: URL(string: "jpgrammar://lesson/"))
        coordinator.sizeSwipe.attach(to: view, scrollView: view.scrollView)
        SelectionBridge.shared.dictionaryView = view
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.lookup = lookup
        coordinator.openLesson = openLesson
        coordinator.saveOffset = saveOffset
        (view as? ReaderWebView)?.quietMenu = quietMenu
        coordinator.sizeSwipe.resize = resize
        coordinator.sizeSwipe.claimTwoFingers()
        // Selections here drive the dictionary card while this page is on screen.
        if view.window != nil { SelectionBridge.shared.dictionaryView = view }
        if coordinator.textSize != textSize {
            coordinator.textSize = textSize
            DictionaryPage.evaluateSelectionScript("document.documentElement.style.setProperty('--g-size', '\(Int(textSize.rounded()))px'); true", in: view) { _, _ in }
        }
        if coordinator.margins != margins {
            coordinator.margins = margins
            DictionaryPage.evaluateSelectionScript("document.documentElement.style.setProperty('--g-pad', '\(margins.pagePadding + 2)px'); true", in: view) { _, _ in }
        }
        if view.scrollView.contentInset.bottom != bottomInset {
            view.scrollView.contentInset.bottom = bottomInset
            view.scrollView.verticalScrollIndicatorInsets.bottom = bottomInset
            if bottomInset > 0 {
                let script = "(() => { const s = getSelection(); if (!s || !s.rangeCount) return false; const r = s.getRangeAt(0).getBoundingClientRect(); const limit = window.innerHeight - \(Int(bottomInset)); if (r.bottom > limit - 8) window.scrollBy({ top: r.bottom - limit + 28, behavior: 'smooth' }); return true; })()"
                DictionaryPage.evaluateSelectionScript(script, in: view) { _, _ in }
            }
        }
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "readerSelection", contentWorld: DictionaryPage.selectionWorld)
        view.stopLoading()
    }

    final class Coordinator: NSObject, WKURLSchemeHandler, WKNavigationDelegate, WKScriptMessageHandler, UIScrollViewDelegate {
        let lessonsFolder: URL
        var openLesson: (String) -> Void
        var lookup: (String) -> Void
        var textSize: Double = 17
        var margins: PageMargins = .compact
        var initialOffset: CGPoint = .zero
        var saveOffset: ((CGPoint) -> Void)?
        let sizeSwipe = TextSizeSwipe()
        private var loaded = false
        private var cancelled = Set<ObjectIdentifier>()
        private let queue = DispatchQueue(label: "JapaneseReader.grammarMedia")

        init(lessonsFolder: URL, openLesson: @escaping (String) -> Void, lookup: @escaping (String) -> Void) {
            self.lessonsFolder = lessonsFolder
            self.openLesson = openLesson
            self.lookup = lookup
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) { if loaded { saveOffset?(scrollView.contentOffset) } }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if initialOffset != .zero { webView.scrollView.setContentOffset(initialOffset, animated: false) }
            sizeSwipe.claimTwoFingers()
            loaded = true
        }

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

        /// Serves the bundled Klee One font and any pictures next to the lessons.
        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            let id = ObjectIdentifier(urlSchemeTask)
            cancelled.remove(id)
            guard let url = urlSchemeTask.request.url else { return }
            let host = url.host ?? ""
            let name = (url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent)
            let folder = lessonsFolder
            queue.async {
                var data: Data?
                if host == "font" {
                    let base = (name as NSString).deletingPathExtension
                    if base.hasPrefix("KleeOne"), let file = Bundle.main.url(forResource: base, withExtension: "ttf") {
                        data = try? Data(contentsOf: file, options: .mappedIfSafe)
                    }
                } else if !name.contains("/"), !name.hasPrefix(".") {
                    data = try? Data(contentsOf: folder.appendingPathComponent(name))
                }
                DispatchQueue.main.async {
                    guard !self.cancelled.contains(id) else { self.cancelled.remove(id); return }
                    guard let data else {
                        urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                        return
                    }
                    let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                    urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
                    urlSchemeTask.didReceive(data)
                    urlSchemeTask.didFinish()
                }
            }
        }
        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) { cancelled.insert(ObjectIdentifier(urlSchemeTask)) }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if action.navigationType == .linkActivated {
                if url.scheme == "jpgrammar", url.host == "lesson" {
                    let name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
                    if name.lowercased().hasSuffix(".html") || name.lowercased().hasSuffix(".htm") { openLesson(name) }
                }
                decisionHandler(.cancel)
                return
            }
            if url.scheme == "about" || (url.scheme == "jpgrammar" && action.navigationType == .other) {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }
    }
}
