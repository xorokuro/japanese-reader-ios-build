import SwiftUI
import WebKit
import AVFoundation

// 物語 · Stories: a visual-novel reader that lives on the web (the owner's own phone
// reader page) shown inside the app, so that selecting a word in the story opens the
// dictionary card exactly as on the Read page and in 文法 lessons. The page keeps its
// own state (where you are, its key) in its web storage; the app remembers the page's
// address and, once the story is saved on the phone (存到手機, `StoryCopy`), reads it
// from there with no network.
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

    /// The page's folder, where its files are: the address without its file name, query or key.
    /// A last part with no dot is a folder (…/reader → …/reader/), as the site itself treats it.
    static func folder(of page: URL) -> URL? {
        guard var parts = URLComponents(url: page, resolvingAgainstBaseURL: true),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty else { return nil }
        parts.fragment = nil
        parts.query = nil
        if parts.path.isEmpty { parts.path = "/" }
        if !parts.path.hasSuffix("/"), let last = parts.path.split(separator: "/").last, !last.contains(".") {
            parts.path += "/"
        }
        guard let clean = parts.url else { return nil }
        return URL(string: "./", relativeTo: clean)?.absoluteURL
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

/// What the app tells the story page as it starts, and asks it.
enum StoryLook {
    /// The story page's selection colour. The theme's tint (which iOS uses for a selection and its
    /// handles) can all but vanish on the page's own paper, so the page gets a blue of its own. The page
    /// is told (`window.__storyAppTint`) and then leaves the selection to the app instead of drawing it.
    static let tint = UIColor(red: 47.0 / 255, green: 111.0 / 255, blue: 214.0 / 255, alpha: 1)
    static let announce = "window.__storyAppTint = true;"
    /// The page on the web: this app can save the story (the page's 設定 then offers 存到手機).
    static let canSave = "window.__storyAppCopy = true;"
    /// The copy on the phone: the files are unlocked already, no key and no network.
    static let local = "window.__storyLocal = true;"
    /// The page's key, to unlock the files the app saves ("-" from a page too old to give it).
    static let keyScript = "(typeof window.__storyKey === 'function' ? String(window.__storyKey() || '') : '-')"
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
    /// The story saved on this phone (存到手機).
    @ObservedObject private var copy = StoryCopy.shared
    /// The page on screen, asked for its key and its storage.
    @State private var page = StoryPageHandle()
    /// The offer to save was closed (until the next launch).
    @State private var offerClosed = false
    @State private var confirmRemove = false
    /// Why the page on the web didn't open (no network, say); nil while it is fine.
    @State private var failure: String?
    @State private var attempt = 0
    @Environment(\.scenePhase) private var scenePhase

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
                if copy.complete {
                    reader(StoryFiles.home, local: true)
                } else if let pageURL {
                    reader(pageURL, local: false)
                } else {
                    setup
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PaperBackground(style: style, texture: handDrawnPaper).equatable())
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(immersive.on ? .hidden : .automatic, for: .tabBar)
            .alert("Remove the story saved on this phone? · 刪除手機裡的故事？", isPresented: $confirmRemove) {
                Button("Remove · 刪除", role: .destructive) { remove() }
                Button("Cancel · 取消", role: .cancel) {}
            } message: {
                Text("This frees the space it takes. Where you are is kept, and the story opens from the web again (that needs a network). · 會釋放空間；閱讀進度會保留，之後改從網路讀。")
            }
        }
        // The page's own storage is copied into the app whenever the page is left (see `StoryState`).
        .onChange(of: scenePhase) { _, phase in if phase != .active { snapshot() } }
        .onChange(of: active) { _, now in if !now { snapshot() } }
    }

    // MARK: Reader

    private func reader(_ url: URL, local: Bool) -> some View {
        VStack(spacing: 0) {
            StoryCopyBanner(copy: copy, progress: copy.progress, style: style, offer: !local && !offerClosed,
                            save: startSaving, close: { offerClosed = true })
            ZStack(alignment: .bottom) {
                StoryPage(url: url, files: local ? copy.files : nil, fixtureHTML: local ? nil : fixtureHTML,
                          quietMenu: quietMenu,
                          bottomInset: peekVisible ? FrameReader.cover(of: pageFrame, by: cardFrame, fallback: 300) : 0,
                          handle: page,
                          act: act,
                          loaded: { reason in if !local { failure = reason } }) { word in
                    guard active else { return }
                    model.select(word, inDictionary: true)
                }
                .id(local ? "local-\(copy.revision)" : "web-\(url.absoluteString)-\(attempt)")
                .background(FrameReader { pageFrame = $0 })
                .overlay { if !local, let failure { failed(failure) } }
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
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: peekVisible)
        .onDisappear { if model.peek?.inDictionary == true { model.closePeek() } }
    }

    /// The page on the web didn't open: try again, or use another link.
    private func failed(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The story page didn't open. · 打不開故事頁面。")
                .font(.headline)
                .foregroundStyle(style.ink)
            Text(reason)
                .font(.footnote)
                .foregroundStyle(style.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Try again · 再試一次") {
                    failure = nil
                    attempt += 1
                }
                .buttonStyle(HandSoftButtonStyle(style: style, prominent: true))
                .accessibilityIdentifier("storyRetry")
                Button("Change link · 更換連結") { forgetLink() }
                    .buttonStyle(HandSoftButtonStyle(style: style, prominent: false))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sketchCard(style, radius: 20, fill: nil)
        .padding(.horizontal, 16)
    }

    private var fixtureHTML: String? {
        #if DEBUG
        if fixture { return StoryLink.fixture }
        #endif
        return nil
    }

    /// The page's own buttons that need the app.
    private func act(_ action: String) {
        switch action {
        case "save": startSaving()
        case "update": copy.update()
        case "remove": confirmRemove = true
        case "changeLink": forgetLink()
        default: break
        }
    }

    /// Save · 存 and Continue · 繼續: a new save asks the page for its key and folder; a save that
    /// stopped goes on; with a copy on the phone already, it is brought up to date.
    private func startSaving() {
        if copy.complete {
            copy.update()
            return
        }
        if copy.canResume {
            copy.resume()
            return
        }
        let handle = self.page
        let link = self.savedLink
        let saver = self.copy
        Task { @MainActor in
            guard let answer = await handle.run(StoryLook.keyScript, in: .page) else {
                saver.report("The story page isn't open yet. Wait until it shows, then tap Continue. · 故事頁面還沒打開，等它出現再按「繼續」。")
                return
            }
            if answer == "-" {
                handle.view?.reloadFromOrigin()
                saver.report("The page was out of date and has been reloaded. Tap Continue. · 頁面已重新載入，請按「繼續」。")
                return
            }
            guard StoryKey.bytes(answer) != nil else {
                saver.report(StoryCopyError.noKey.errorDescription ?? "")
                return
            }
            guard let site = handle.view?.url.flatMap(StoryLink.folder(of:)) ?? URL(string: link).flatMap(StoryLink.folder(of:)) else {
                saver.report("The story page's address couldn't be read. · 讀不到故事頁面的網址。")
                return
            }
            // A snapshot now, and the last one once every file is in, just before the tab turns to the copy.
            await StoryState.capture(from: handle)
            saver.save(from: site, key: answer) { await StoryState.capture(from: handle) }
        }
    }

    /// 刪除: where you are goes back to the page on the web first.
    private func remove() {
        let handle = self.page
        let saver = self.copy
        Task { @MainActor in
            await StoryState.capture(from: handle)
            saver.remove()
        }
    }

    private func snapshot() {
        let handle = self.page
        Task { @MainActor in await StoryState.capture(from: handle) }
    }

    private func forgetLink() {
        savedLink = ""
        firstOpen = nil
        failure = nil
    }

    private func use(_ text: String) {
        guard let link = StoryLink.parse(text) else { problem = true; return }
        problem = false
        draft = ""
        failure = nil
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
                    Text("Only the address is kept on this phone; the page remembers its key and where you are. Once it opens, Save · 存 keeps the whole story in the app, to read with no network. To use another link later, open the page's 設定 and tap 更換.")
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

/// 存到手機 above the story: the offer, a save in progress, a pause or a problem, a word after an update.
struct StoryCopyBanner: View {
    @ObservedObject var copy: StoryCopy
    @ObservedObject var progress: StoryProgress
    let style: ReaderStyle
    /// Offer to save (the page on the web, until the offer is closed).
    let offer: Bool
    let save: () -> Void
    let close: () -> Void

    var body: some View {
        Group {
            switch copy.phase {
            case .saving:
                saving
            case .stopped(let message):
                stopped(message)
            case .idle:
                if let note = copy.note {
                    noted(note)
                } else if offer {
                    offering
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: copy.phase)
        .task(id: copy.note) {
            guard copy.note != nil else { return }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { copy.note = nil }
        }
    }

    private var offering: some View {
        card {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(style.accent)
                Text(copy.partial ? "Finish saving the story on this phone · 繼續存到手機" : "Save the whole story on this phone · 存到手機")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(style.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                closeButton(close)
            }
            HStack(alignment: .center, spacing: 10) {
                Text(copy.partial
                     ? "\(mb(progress.done)) of \(mb(progress.total)) MB are saved. Then it opens with no network. · 已存 \(mb(progress.done)) / \(mb(progress.total)) MB；存好後不用網路也能讀。"
                     : "Then it opens with no network. Hundreds of MB: best on Wi-Fi. · 存好後不用網路也能讀；約幾百 MB，建議用 Wi-Fi。")
                    .font(.caption)
                    .foregroundStyle(style.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button(action: save) { Text(copy.partial ? "Continue · 繼續" : "Save · 存") }
                    .buttonStyle(HandSoftButtonStyle(style: style, prominent: true))
                    .accessibilityIdentifier("storySave")
            }
        }
    }

    private var saving: some View {
        card {
            HStack(spacing: 8) {
                Text(copy.complete ? "Updating the story on this phone · 更新手機裡的故事" : "Saving the story on this phone · 存到手機中")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(style.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Pause · 暫停") { copy.pause() }
                    .buttonStyle(HandSoftButtonStyle(style: style, prominent: false))
                    .accessibilityIdentifier("storyPause")
            }
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                .tint(style.accent)
            Text(progress.total > 0
                 ? "\(mb(progress.done)) / \(mb(progress.total)) MB · Keep the app open; if you leave, it goes on when you come back. · 請留在 App 裡；離開的話，回來會接著存。"
                 : "Getting the list of files… · 讀取檔案清單…")
                .font(.caption)
                .foregroundStyle(style.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stopped(_ message: String) -> some View {
        card {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "pause.circle")
                    .foregroundStyle(style.accent)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(style.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                closeButton { copy.dismiss() }
            }
            HStack(spacing: 10) {
                if progress.total > 0 {
                    Text("\(mb(progress.done)) / \(mb(progress.total)) MB")
                        .font(.caption)
                        .foregroundStyle(style.secondary)
                }
                Spacer(minLength: 4)
                Button("Continue · 繼續", action: save)
                    .buttonStyle(HandSoftButtonStyle(style: style, prominent: true))
                    .accessibilityIdentifier("storyContinue")
            }
        }
    }

    private func noted(_ note: String) -> some View {
        card {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(style.accent)
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(style.ink)
                Spacer(minLength: 0)
            }
        }
    }

    private func closeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.footnote.weight(.semibold))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(style.secondary)
        .accessibilityLabel("Close")
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) { content() }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sketchCard(style, radius: 18, fill: nil, shadow: CGSize(width: 2, height: 3))
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("storyCopyBanner")
    }

    private func mb(_ bytes: Int64) -> String { String(format: "%.0f", Double(bytes) / 1_000_000) }
}

/// The story page. Its own scripts run (voices, pictures, choices); the app's selection
/// observer runs beside them in its own script world, as on dictionary and lesson pages.
struct StoryPage: UIViewRepresentable {
    let url: URL
    /// The story saved on this phone, served at jpstory://story/ (nil: the page on the web).
    var files: URL? = nil
    /// Interface tests: a page given as text instead of loaded from `url`.
    var fixtureHTML: String? = nil
    var quietMenu = false
    /// Room kept free at the bottom while the dictionary card covers the page.
    var bottomInset: CGFloat = 0
    /// Lets the tab ask the page for its key and its storage.
    var handle: StoryPageHandle? = nil
    /// The page's buttons that need the app: save (存到手機), update (檢查更新), remove (刪除), changeLink (更換).
    var act: (String) -> Void = { _ in }
    /// The page opened (nil) or didn't (why).
    var loaded: (String?) -> Void = { _ in }
    let lookup: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(home: url, lookup: lookup, act: act, loaded: loaded)
    }

    func makeUIView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        let configuration = WKWebViewConfiguration()
        // The page keeps its key and its place between launches.
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        // Voices follow one another (auto-play) without a tap for every line.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        if #available(iOS 18.0, *) { configuration.writingToolsBehavior = UIWritingToolsBehavior.none }
        if let files {
            let handler = StoryFileHandler(folder: files)
            coordinator.files = handler
            configuration.setURLSchemeHandler(handler, forURLScheme: StoryFiles.scheme)
        }
        let scripts = configuration.userContentController
        scripts.add(coordinator, contentWorld: DictionaryPage.selectionWorld, name: "readerSelection")
        scripts.add(coordinator, contentWorld: .page, name: "storyApp")
        scripts.addUserScript(WKUserScript(source: "window.__jpLimit = \(SelectionLimit.current);", injectionTime: .atDocumentStart, forMainFrameOnly: true, in: DictionaryPage.selectionWorld))
        scripts.addUserScript(WKUserScript(source: DictionaryPage.selectionScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: DictionaryPage.selectionWorld))
        scripts.addUserScript(WKUserScript(source: StoryLook.announce + (files == nil ? StoryLook.canSave : StoryLook.local), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        if let snapshot = StoryState.load() {
            scripts.addUserScript(WKUserScript(source: StoryState.restoreScript(snapshot), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
        }
        let view = ReaderWebView(frame: .zero, configuration: configuration)
        view.tintColor = StoryLook.tint
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
        coordinator.handle = handle
        handle?.view = view
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
        coordinator.act = act
        coordinator.loaded = loaded
        (view as? ReaderWebView)?.quietMenu = quietMenu
        coordinator.reopenTap.enabled = quietMenu
        if view.tintColor != StoryLook.tint { view.tintColor = StoryLook.tint }
        // Selections here drive the dictionary card while this page is on screen.
        if view.window != nil {
            SelectionBridge.shared.dictionaryView = view
            if let handle, handle.view !== view { handle.view = view }
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
        let scripts = view.configuration.userContentController
        scripts.removeScriptMessageHandler(forName: "readerSelection", contentWorld: DictionaryPage.selectionWorld)
        scripts.removeScriptMessageHandler(forName: "storyApp", contentWorld: .page)
        if let handle = coordinator.handle, handle.view === view { handle.view = nil }
        view.stopLoading()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let home: URL
        var lookup: (String) -> Void
        var act: (String) -> Void
        var loaded: (String?) -> Void
        weak var handle: StoryPageHandle?
        /// Serves the saved story (kept here as long as the page is).
        var files: StoryFileHandler?
        let reopenTap = SelectionReopenTap()

        init(home: URL, lookup: @escaping (String) -> Void, act: @escaping (String) -> Void, loaded: @escaping (String?) -> Void) {
            self.home = home
            self.lookup = lookup
            self.act = act
            self.loaded = loaded
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "storyApp" {
                guard message.frameInfo.isMainFrame,
                      let body = message.body as? [String: Any],
                      let action = body["action"] as? String,
                      ["save", "update", "remove", "changeLink"].contains(action) else { return }
                DispatchQueue.main.async { self.act(action) }
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
            if ["about", "blob", "data", StoryFiles.scheme].contains(scheme) || action.targetFrame?.isMainFrame == false || StoryLink.sameSite(url, as: home) {
                decisionHandler(.allow)
                return
            }
            // A link out of the story opens in Safari.
            if scheme == "https" || scheme == "http" { UIApplication.shared.open(url) }
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded(nil) }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }

        private func failed(_ error: Error) {
            // A load replaced by another one, or a link sent to Safari instead (WebKit's 102), is no failure.
            let code = (error as NSError).code
            if code == NSURLErrorCancelled || code == 102 { return }
            loaded(error.localizedDescription)
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
