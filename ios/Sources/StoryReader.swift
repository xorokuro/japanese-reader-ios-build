import SwiftUI
import WebKit
import AVFoundation

// 物語 · Stories: a visual-novel reader that lives on the web (the owner's own phone
// reader page) shown inside the app, so that selecting a word in the story opens the
// dictionary card exactly as on the Read page and in 文法 lessons. The page keeps its
// own state (where you are, its key, the chapters saved for offline reading) in the
// app's web storage; the app only remembers the page's address.
//
// This repository is public: the address is never written here, only pasted on the phone.

enum StoryLink {
    static let key = "storyReaderLink"

    /// A pasted link: the first https address in the text, maybe with a `#k=…` key for
    /// the page. `open` is loaded once (with the key, which the page stores itself);
    /// `keep` is the address remembered for later visits (without it).
    static func parse(_ text: String) -> (open: URL, keep: URL)? {
        guard let word = text.split(whereSeparator: { $0.isWhitespace })
                .first(where: { $0.lowercased().hasPrefix("https://") }),
              var parts = URLComponents(string: String(word)),
              parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty,
              let open = parts.url else { return nil }
        parts.fragment = nil
        guard let keep = parts.url else { return nil }
        return (open, keep)
    }

    /// Only the page's own site opens inside the tab; any other link goes to Safari.
    static func sameSite(_ url: URL, as home: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == home.host?.lowercased()
    }

    #if DEBUG
    /// Interface tests (`--ui-story-fixture`): a small story page instead of a real one.
    static let fixtureURL = URL(string: "https://story.invalid/")!
    static let fixture = """
    <!doctype html><html lang="ja"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <style>body{font:20px/1.8 -apple-system,sans-serif;padding:18px;background:#f6f1e6;color:#1d2a3a}</style></head>
    <body><h2>意思</h2><p>気持ちを伝えるのは、思ったより難しい。</p></body></html>
    """
    #endif
}

/// Voices play with the ring/silent switch on, as a video or a podcast would.
enum StoryAudio {
    static func prepare() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [])
    }
}

struct StoryTab: View {
    @EnvironmentObject var model: ReaderModel
    let style: ReaderStyle
    let quietMenu: Bool
    /// True while this tab is the one on screen.
    let active: Bool

    @AppStorage(StoryLink.key) private var savedLink = ""
    /// The pasted link with its key, loaded once (the page keeps the key).
    @State private var firstOpen: URL?
    @State private var draft = ""
    @State private var problem = false
    /// Where the page and the dictionary card are: the card's cover keeps a selection visible.
    @State private var pageFrame = CGRect.zero
    @State private var cardFrame = CGRect.zero
    @AppStorage("handDrawnPaper") private var handDrawnPaper = true
    @ObservedObject private var immersive = ImmersiveController.shared

    private var peekVisible: Bool { active && (model.peek?.inDictionary ?? false) }

    private var fixture: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--ui-story-fixture")
        #else
        return false
        #endif
    }

    private var pageURL: URL? {
        #if DEBUG
        if fixture { return StoryLink.fixtureURL }
        #endif
        return firstOpen ?? (savedLink.isEmpty ? nil : URL(string: savedLink))
    }

    var body: some View {
        NavigationStack {
            Group {
                if let pageURL { reader(pageURL) } else { setup }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PaperBackground(style: style, texture: handDrawnPaper).equatable())
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(immersive.on ? .hidden : .automatic, for: .tabBar)
        }
    }

    // MARK: Reader

    private func reader(_ url: URL) -> some View {
        ZStack(alignment: .bottom) {
            StoryPage(url: url, fixtureHTML: fixtureHTML, quietMenu: quietMenu,
                      bottomInset: peekVisible ? FrameReader.cover(of: pageFrame, by: cardFrame, fallback: 300) : 0,
                      changeLink: forgetLink) { word in
                guard active else { return }
                model.select(word, inDictionary: true)
            }
            .id(url.absoluteString)
            .background(FrameReader { pageFrame = $0 })
            if active, let peek = model.peek, peek.inDictionary {
                LookupPeekCard(peek: peek, style: style,
                               refine: { model.refinePeek($0) },
                               open: { hit in model.openPeekHit(hit) },
                               showAll: { model.showPeekResults() },
                               copy: { UIPasteboard.general.string = peek.text },
                               close: { model.closePeek() })
                    .background(FrameReader { cardFrame = $0 })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: peekVisible)
        .onDisappear { if model.peek?.inDictionary == true { model.closePeek() } }
    }

    private var fixtureHTML: String? {
        #if DEBUG
        if fixture { return StoryLink.fixture }
        #endif
        return nil
    }

    private func forgetLink() {
        savedLink = ""
        firstOpen = nil
    }

    private func use(_ text: String) {
        guard let link = StoryLink.parse(text) else { problem = true; return }
        problem = false
        draft = ""
        firstOpen = link.open
        savedLink = link.keep.absoluteString
    }

    // MARK: Setup

    private var setup: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Read a story here")
                        .font(HandFont.title(19))
                        .foregroundStyle(style.ink)
                        .accessibilityIdentifier("storySetupTitle")
                    Text("Paste the link to your phone reader page, the whole link with its #k=… part. The story opens in this tab, and any word you select in it opens the dictionary card, as on the Read page.")
                        .font(.footnote)
                        .foregroundStyle(style.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("https://…", text: $draft)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit { use(draft) }
                        .font(.system(size: 15))
                        .padding(.horizontal, 14)
                        .frame(minHeight: 42)
                        .sketchPill(style)
                        .accessibilityIdentifier("storyLinkField")
                    HStack(spacing: 10) {
                        PasteControl(paste: { use($0.joined(separator: " ")) }) {
                            PasteButton(payloadType: String.self) { use($0.joined(separator: " ")) }
                                .buttonStyle(.borderedProminent)
                                .buttonBorderShape(.capsule)
                                .tint(style.accent)
                        } standIn: { paste in
                            Button(action: paste) { Label("Paste", systemImage: "doc.on.clipboard") }
                                .buttonStyle(.borderedProminent)
                                .buttonBorderShape(.capsule)
                                .tint(style.accent)
                        }
                        Button("Open") { use(draft) }
                            .buttonStyle(HandSoftButtonStyle(style: style, prominent: false))
                            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("storyOpen")
                        Spacer(minLength: 0)
                    }
                    if problem {
                        Text("That doesn't look like an https:// link.")
                            .font(.footnote)
                            .foregroundStyle(style.accent)
                    }
                    Text("Only the address is kept on this phone. The page itself remembers its key, where you are, and the chapters you saved for reading offline. To use another link later, open the page's 設定 and tap 更換.")
                        .font(.footnote)
                        .foregroundStyle(style.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .sketchCard(style, radius: 20, tape: .marker, tapeTrailing: true, fill: nil)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    @ViewBuilder private var header: some View {
        if style.isYohaku {
            YohakuHeader(style: style, index: "05", title: "物語", latin: "Stories", drawing: .book, height: 112) {
                EmptyView()
            }
        } else {
            VStack(spacing: 2) {
                HStack(spacing: 10) {
                    EnsoLogo(style: style, text: "物")
                    HandTitle(text: "物語", subtitle: "Stories", style: style, size: 25)
                    Spacer(minLength: 6)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                HandRule(style: style).padding(.horizontal, 12)
            }
        }
    }
}

/// The story page. Its own scripts run (voices, pictures, choices); the app's selection
/// observer runs beside them in its own script world, as on dictionary and lesson pages.
struct StoryPage: UIViewRepresentable {
    let url: URL
    /// Interface tests: a page given as text instead of loaded from `url`.
    var fixtureHTML: String? = nil
    var quietMenu = false
    /// Room kept free at the bottom while the dictionary card covers the page.
    var bottomInset: CGFloat = 0
    /// The page's 設定 → 更換: forget the address and ask for a new one.
    var changeLink: () -> Void
    let lookup: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(home: url, lookup: lookup, changeLink: changeLink)
    }

    func makeUIView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        let configuration = WKWebViewConfiguration()
        // The page keeps its key, its place and its offline chapters between launches.
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        // Voices follow one another (auto-play) without a tap for every line.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        if #available(iOS 18.0, *) { configuration.writingToolsBehavior = UIWritingToolsBehavior.none }
        let scripts = configuration.userContentController
        scripts.add(coordinator, contentWorld: DictionaryPage.selectionWorld, name: "readerSelection")
        scripts.add(coordinator, contentWorld: .page, name: "storyApp")
        scripts.addUserScript(WKUserScript(source: "window.__jpLimit = \(SelectionLimit.current);", injectionTime: .atDocumentStart, forMainFrameOnly: true, in: DictionaryPage.selectionWorld))
        scripts.addUserScript(WKUserScript(source: DictionaryPage.selectionScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: DictionaryPage.selectionWorld))
        let view = ReaderWebView(frame: .zero, configuration: configuration)
        view.quietMenu = quietMenu
        view.navigationDelegate = coordinator
        view.uiDelegate = coordinator
        view.allowsBackForwardNavigationGestures = false
        view.allowsLinkPreview = false
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.accessibilityIdentifier = "storyPage"
        coordinator.reopenTap.enabled = quietMenu
        coordinator.reopenTap.attach(to: view)
        SelectionBridge.shared.dictionaryView = view
        StoryAudio.prepare()
        if let fixtureHTML {
            view.loadHTMLString(fixtureHTML, baseURL: url)
        } else {
            view.load(URLRequest(url: url))
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.lookup = lookup
        coordinator.changeLink = changeLink
        (view as? ReaderWebView)?.quietMenu = quietMenu
        coordinator.reopenTap.enabled = quietMenu
        // Selections here drive the dictionary card while this page is on screen.
        if view.window != nil { SelectionBridge.shared.dictionaryView = view }
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
        let scripts = view.configuration.userContentController
        scripts.removeScriptMessageHandler(forName: "readerSelection", contentWorld: DictionaryPage.selectionWorld)
        scripts.removeScriptMessageHandler(forName: "storyApp", contentWorld: .page)
        view.stopLoading()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let home: URL
        var lookup: (String) -> Void
        var changeLink: () -> Void
        let reopenTap = SelectionReopenTap()

        init(home: URL, lookup: @escaping (String) -> Void, changeLink: @escaping () -> Void) {
            self.home = home
            self.lookup = lookup
            self.changeLink = changeLink
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "storyApp" {
                guard message.frameInfo.isMainFrame,
                      let body = message.body as? [String: Any],
                      body["action"] as? String == "changeLink" else { return }
                DispatchQueue.main.async { self.changeLink() }
                return
            }
            guard message.name == "readerSelection", message.frameInfo.isMainFrame else { return }
            var context = SelectionContext()
            if let text = message.body as? String {
                context.text = text
            } else if let body = message.body as? [String: Any], let text = body["text"] as? String {
                context.text = text
                context.before = body["before"] as? String ?? ""
                context.after = body["after"] as? String ?? ""
                if body["again"] as? Bool == true { SelectionBridge.shared.reopenText = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            } else { return }
            let word = context.text.trimmingCharacters(in: .whitespacesAndNewlines)
            context.text = word
            SelectionBridge.shared.dictionaryContext = context
            lookup(word)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            let scheme = url.scheme?.lowercased() ?? ""
            if ["about", "blob", "data"].contains(scheme) || action.targetFrame?.isMainFrame == false || StoryLink.sameSite(url, as: home) {
                decisionHandler(.allow)
                return
            }
            // A link out of the story opens in Safari.
            if scheme == "https" || scheme == "http" { UIApplication.shared.open(url) }
            decisionHandler(.cancel)
        }

        /// Links that ask for a new window open in Safari.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url, ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                UIApplication.shared.open(url)
            }
            return nil
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }
    }
}
