import SwiftUI
import UniformTypeIdentifiers
import Translation

struct SavedText: Identifiable, Codable {
    var id = UUID()
    var text: String
    var note = ""
    var date = Date()
}

struct InstalledDictionary: Identifiable {
    let id: String
    let code: String
    let name: String
    let root: URL
}

struct EntryVisit {
    let id = UUID()
    let hit: DictionaryHit
    let html: String
    let query: String
    let matches: [DictionaryHit]
    let alternatives: [DictionaryHit]
}

struct LookupSnapshot {
    let visit: EntryVisit?
    let visits: [EntryVisit]
    let query: String
    let hits: [DictionaryHit]
    let showingLookup: Bool
}

@MainActor final class ReaderModel: ObservableObject {
    @Published var text = "" { didSet { if text != oldValue { readerSelection = "" } } }
    @Published var word = ""
    @Published var hits: [DictionaryHit] = []
    @Published var status = ""
    @Published var dictionaries: [InstalledDictionary] = []
    @Published var disabledDictionaries = Set(UserDefaults.standard.stringArray(forKey: "disabledDictionaries") ?? [])
    var dictionaryOrder = UserDefaults.standard.stringArray(forKey: "dictionaryOrder") ?? []
    @Published var entryRoot: URL?
    @Published var busy = false
    @Published var lookupBusy = false
    @Published var saved: [SavedText] = []
    @Published var autoSave = UserDefaults.standard.bool(forKey: "savePassagesOnRead") {
        didSet { UserDefaults.standard.set(autoSave, forKey: "savePassagesOnRead") }
    }
    @Published private(set) var recentlyDeleted: [SavedText] = []
    @Published var entryHTML = ""
    @Published var entryID = UUID()
    @Published var entryCode = ""
    @Published var showingEntry = false
    @Published var showingLookup = false
    @Published var lookupNavigation = UUID()
    @Published var entryTitle = ""
    @Published var entryDictionary = ""
    @Published var entryHitIdentity = ""
    @Published var entryMatches: [DictionaryHit] = []
    @Published var searchMode: DictionarySearchMode = .prefix
    @Published var searchScope = ""
    @Published private(set) var visits: [EntryVisit] = []
    private var lookupHistory: [LookupSnapshot] = []
    var canGoBack: Bool { !lookupHistory.isEmpty }
    private func snapshot() -> LookupSnapshot {
        let visit = showingEntry ? visits.last : nil
        return LookupSnapshot(visit: visit, visits: visits, query: visit?.query ?? word, hits: visit?.matches ?? hits, showingLookup: showingLookup)
    }
    private func remember(_ page: LookupSnapshot) {
        lookupHistory.append(page)
        if lookupHistory.count > 30 { lookupHistory.removeFirst() }
    }
    var entryOffsets: [UUID: CGPoint] = [:]
    var readerOffset: CGPoint = .zero
    private var liveSearch: DispatchWorkItem?
    func typedSearch(_ query: String, clearSelection: Bool = false) {
        cancelPendingSearch()
        if clearSelection { readerSelection = ""; dictionarySelection = "" }
        word = query
        hits = []
        status = ""
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let pending = DispatchWorkItem { [weak self] in self?.search(dismissKeyboard: false) }
        liveSearch = pending
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: pending)
    }
    func followEntryLink(_ query: String) {
        word = query
        search(dismissKeyboard: true, navigate: true, openBestMatch: true)
    }
    private func display(_ visit: EntryVisit) {
        entryHTML = visit.html; entryRoot = visit.hit.root; entryCode = visit.hit.code
        entryTitle = visit.hit.word; entryDictionary = visit.hit.dictionary; entryHitIdentity = visit.hit.identity
        entryID = visit.id; entryMatches = visit.alternatives
        word = visit.query; hits = visit.matches; dictionarySelection = ""
        showingEntry = true; showingLookup = true; status = ""
        lookupNavigation = UUID()
    }
    func backToPreviousEntry() {
        cancelPendingSearch()
        guard let previous = lookupHistory.popLast() else { showingEntry = false; showingLookup = false; return }
        visits = previous.visits
        if let visit = previous.visit { display(visit) }
        else {
            word = previous.query; hits = previous.hits; dictionarySelection = ""
            showingEntry = false; showingLookup = previous.showingLookup; status = ""
            // Already on Search: do not emit a new navigation event here, which
            // would override the Back action's request to focus the search field.
        }
    }
    func showResults() {
        cancelPendingSearch()
        if showingEntry { remember(snapshot()) }
        showingEntry = false; showingLookup = false
    }
    @Published var selectionFromDictionary = false
    @Published var readerSelection = ""
    @Published var dictionarySelection = ""
    @Published var readerAutoSearch = true {
        didSet { preferences.set(readerAutoSearch, forKey: "readerAutoSearch"); cancelPendingSearch() }
    }
    @Published var dictionaryAutoSearch = true {
        didSet { preferences.set(dictionaryAutoSearch, forKey: "dictionaryAutoSearch"); cancelPendingSearch() }
    }
    func cancelPendingSearch() { liveSearch?.cancel(); liveSearch = nil; searchGeneration += 1; lookupBusy = false }
    func select(_ text: String, inDictionary: Bool) {
        if !text.isEmpty { selectionFromDictionary = inDictionary }
        if inDictionary { dictionarySelection = text } else { readerSelection = text }
        cancelPendingSearch()
        guard !text.isEmpty, (inDictionary ? dictionaryAutoSearch : readerAutoSearch) else { return }
        word = text
        search(dismissKeyboard: false, navigate: true, onlyIfMatched: true)
    }
    func searchSelected(inDictionary: Bool) {
        word = inDictionary ? dictionarySelection : readerSelection
        guard !word.isEmpty else { return }
        search(dismissKeyboard: true, navigate: true)
    }
    func closeLookup() {
        cancelPendingSearch()
        lookupHistory = []
        showingLookup = false
        showingEntry = false
    }
    private var searchGeneration = 0
    private var libraryWritable = true
    let queue = DispatchQueue(label: "JapaneseReader.dictionary", qos: .userInitiated)
    let documents: URL
    private let preferences: UserDefaults
    var dictionaryRoot: URL { documents.appendingPathComponent("dictionaries", isDirectory: true) }
    var libraryURL: URL { documents.appendingPathComponent("reading-library.json") }
    init(documents: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0], preferences: UserDefaults = .standard) {
        self.documents = documents
        self.preferences = preferences
        readerAutoSearch = (preferences.object(forKey: "readerAutoSearch") as? Bool) ?? true
        dictionaryAutoSearch = (preferences.object(forKey: "dictionaryAutoSearch") as? Bool) ?? true
        do {
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            let help = documents.appendingPathComponent("ABOUT THIS FOLDER.txt")
            if !FileManager.default.fileExists(atPath: help.path) {
                try "Japanese Reader\n\nMove the supplied dictionaries folder here, keeping mdict-index.sqlite3 and sources inside it. Then open Library and tap Refresh dictionaries.\n\nSaved passages and notes are in reading-library.json. Copy that file for backup before uninstalling the app.\n".write(to: help, atomically: true, encoding: .utf8)
            }
        } catch { status = "Could not prepare the Files folder: \(error.localizedDescription)" }
        if let bytes = try? Data(contentsOf: libraryURL) {
            do { saved = try JSONDecoder().decode([SavedText].self, from: bytes) }
            catch { libraryWritable = false; status = "The saved library could not be read. Its file has been preserved." }
        }
        reload()
    }
    func reload() {
        let root = dictionaryRoot
        let extras = documents.appendingPathComponent("Dictionary Packs", isDirectory: true)
        queue.async {
            let roots = [root] + ((try? FileManager.default.contentsOfDirectory(at: extras, includingPropertiesForKeys: nil)) ?? []).sorted { $0.path < $1.path }
            let items = roots.flatMap { folder -> [InstalledDictionary] in
                guard let catalog = try? DictionaryStore(root: folder).catalog() else { return [] }
                return catalog.compactMap { row in
                    guard let code = row["code"], let name = row["name"] else { return nil }
                    let id = (folder == root ? "base" : folder.lastPathComponent) + ":" + code
                    return InstalledDictionary(id: id, code: code, name: name, root: folder)
                }
            }
            DispatchQueue.main.async {
                let order = self.dictionaryOrder
                self.dictionaries = items.sorted { (order.firstIndex(of: $0.id) ?? Int.max) < (order.firstIndex(of: $1.id) ?? Int.max) }
            }
        }
    }
    func enableDictionary(_ id: String, enabled: Bool) {
        if enabled { disabledDictionaries.remove(id) } else { disabledDictionaries.insert(id) }
        UserDefaults.standard.set(Array(disabledDictionaries), forKey: "disabledDictionaries")
        searchGeneration += 1; hits = []; lookupBusy = false
    }
    func moveDictionaries(from: IndexSet, to: Int) {
        dictionaries.move(fromOffsets: from, toOffset: to)
        dictionaryOrder = dictionaries.map(\.id)
        UserDefaults.standard.set(dictionaryOrder, forKey: "dictionaryOrder")
        searchGeneration += 1; hits = []; lookupBusy = false
    }
    func searchSelection(_ selected: String) {
        word = selected
        search(dismissKeyboard: false)
    }
    func search(dismissKeyboard: Bool = true, navigate: Bool = false, onlyIfMatched: Bool = false, openBestMatch: Bool = false) {
        if dismissKeyboard { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
        liveSearch?.cancel(); liveSearch = nil
        searchGeneration += 1
        let generation = searchGeneration, query = word
        let previousPage = showingEntry ? snapshot() : nil
        let preferredRoot = entryRoot, preferredCode = entryCode
        let mode: DictionarySearchMode = openBestMatch ? .exact : (navigate ? .prefix : searchMode)
        let selected = dictionaries.filter { !disabledDictionaries.contains($0.id) && (navigate || searchScope.isEmpty || $0.id == searchScope) }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { hits = []; lookupBusy = false; status = ""; return }
        lookupBusy = true
        queue.async {
            let result = Result { () -> [DictionaryHit] in
                guard !selected.isEmpty else { throw ReaderError("Enable a dictionary in Library first, or add the dictionaries folder.") }
                return try selected.flatMap { try DictionaryStore(root: $0.root).search(query, codes: [$0.code], mode: mode) }
            }
            DispatchQueue.main.async {
                guard generation == self.searchGeneration else { return }
                self.lookupBusy = false
                switch result {
                case .success(let hits):
                    self.hits = hits
                    self.status = hits.isEmpty ? "No match. Try the dictionary form of the word." : ""
                    if openBestMatch, let hit = hits.first(where: { $0.root == preferredRoot && $0.code == preferredCode }) ?? hits.first {
                        self.open(hit)
                    } else if navigate && (!onlyIfMatched || !hits.isEmpty) {
                        if let previousPage { self.remember(previousPage) }
                        self.showingEntry = false; self.showingLookup = true; self.lookupNavigation = UUID()
                    }
                case .failure(let error): self.hits = []; self.status = error.localizedDescription
                }
            }
        }
    }
    func open(_ hit: DictionaryHit, replacingCurrent: Bool = false) {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        liveSearch?.cancel(); liveSearch = nil
        searchGeneration += 1
        let generation = searchGeneration
        let root = hit.root
        let query = replacingCurrent ? (visits.last?.query ?? word) : word
        let matches = replacingCurrent ? (visits.last?.matches ?? hits) : hits
        let wasEntry = showingEntry
        let previousPage = snapshot()
        let enabled = dictionaries.filter { !disabledDictionaries.contains($0.id) }
        lookupBusy = true
        queue.async {
            let result = Result { () -> (String, [DictionaryHit]) in
                let store = try DictionaryStore(root: root)
                let html = DictionaryPage.make(body: try store.entry(hit), css: try store.stylesheet(code: hit.code), code: hit.code)
                // The title switcher spans all enabled dictionaries, even if Search
                // was scoped to one dictionary (as in the reference recording).
                var seen = Set<String>()
                let alternatives = enabled.flatMap { dictionary -> [DictionaryHit] in
                    guard let source = try? DictionaryStore(root: dictionary.root) else { return [] }
                    var candidates = (try? source.search(hit.word, codes: [dictionary.code], mode: .exact)) ?? []
                    if DictionaryStore.normalize(query) != DictionaryStore.normalize(hit.word) {
                        candidates += (try? source.search(query, codes: [dictionary.code], mode: .exact)) ?? []
                    }
                    return candidates.filter { seen.insert($0.identity).inserted }
                }
                return (html, alternatives.isEmpty ? [hit] : alternatives)
            }
            DispatchQueue.main.async {
                guard generation == self.searchGeneration else { return }
                self.lookupBusy = false
                switch result {
                case .success(let (html, alternatives)):
                    if !replacingCurrent { self.remember(previousPage) }
                    if replacingCurrent, !self.visits.isEmpty {
                        let removed = self.visits.removeLast(); self.entryOffsets.removeValue(forKey: removed.id)
                    } else if !wasEntry && !self.showingLookup {
                        self.visits = []; self.entryOffsets = [:]
                    }
                    let visit = EntryVisit(hit: hit, html: html, query: query, matches: matches, alternatives: alternatives)
                    self.visits.append(visit)
                    if self.visits.count > 30 { let removed = self.visits.removeFirst(); self.entryOffsets.removeValue(forKey: removed.id) }
                    self.display(visit)
                case .failure(let error): self.status = error.localizedDescription
                }
            }
        }
    }
    @discardableResult private func store(_ passages: [SavedText]) -> Bool {
        guard libraryWritable else { status = "The saved library file needs repair before saving new passages. Copy reading-library.json from Files for safekeeping."; return false }
        do {
            try JSONEncoder().encode(passages).write(to: libraryURL, options: .atomic)
            saved = passages
            return true
        } catch { status = "Could not update your library: \(error.localizedDescription)"; return false }
    }
    func save() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !saved.contains(where: { $0.text == text }) else { status = "Already in your library."; return }
        if store([SavedText(text: text)] + saved) { status = "Saved to your library." }
    }
    func readPassage() {
        if autoSave { save() }
        else { status = "Auto-save is off. Tap Save if you want to keep this passage." }
    }
    func updateNote(id: UUID, note: String) {
        var next = saved
        guard let index = next.firstIndex(where: { $0.id == id }) else { return }
        next[index].note = note
        store(next)
    }
    func delete(ids: Set<UUID>) {
        let removed = saved.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        if store(saved.filter { !ids.contains($0.id) }) {
            recentlyDeleted = removed
            status = "Deleted \(removed.count) saved passage(s). Undo is available below."
        }
    }
    func undoDelete() {
        let existing = Set(saved.map(\.id))
        let restored = recentlyDeleted.filter { !existing.contains($0.id) }
        if store((saved + restored).sorted { $0.date > $1.date }) {
            recentlyDeleted = []; status = "Deleted passages restored."
        }
    }
    func prompt(inDictionary: Bool = false) -> String {
        let selection = (inDictionary ? dictionarySelection : readerSelection).trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = selection.isEmpty ? text : selection
        let kind = selection.isEmpty ? "passage" : "selected text"
        return "Help me study this Japanese \(kind). Translate into natural English and Traditional Chinese, explain grammar and vocabulary, give readings, and preserve the original Japanese. Do not invent missing context.\n\n\(subject)"
    }
    func importFolder(_ source: URL) {
        guard !busy else { return }
        busy = true; status = "Copying dictionaries. Keep this app open until it finishes."
        UIApplication.shared.isIdleTimerDisabled = true
        let destination = FileManager.default.fileExists(atPath: dictionaryRoot.path)
            ? documents.appendingPathComponent("Dictionary Packs", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
            : dictionaryRoot
        queue.async {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            let fm = FileManager.default
            let staging = self.documents.appendingPathComponent("dictionary-import-" + UUID().uuidString)
            let result = Result { () -> Void in
                guard source.standardizedFileURL != destination.standardizedFileURL else { return }
                guard !fm.fileExists(atPath: destination.path) else { throw ReaderError("A dictionaries folder already exists. Use Files to move it out before replacing it; your existing dictionaries have been kept.") }
                let store = try DictionaryStore(root: source)
                guard !(try store.catalog()).isEmpty else { throw ReaderError("This folder contains no indexed dictionaries.") }
                try store.validateFiles()
                try fm.copyItem(at: source, to: staging)
                try DictionaryStore(root: staging).validateFiles()
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: staging, to: destination)
            }
            try? fm.removeItem(at: staging)
            DispatchQueue.main.async {
                self.busy = false; UIApplication.shared.isIdleTimerDisabled = false
                switch result {
                case .success: self.status = "Dictionaries are on this iPhone. You can read offline."; self.reload()
                case .failure(let error): self.status = error.localizedDescription
                }
            }
        }
    }
}

@main struct JapaneseReaderApp: App {
    @StateObject private var model: ReaderModel
    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-dictionary-fixture") {
            _model = StateObject(wrappedValue: ReaderModel(documents: UITestFixture.documents()))
        } else { _model = StateObject(wrappedValue: ReaderModel()) }
        #else
        _model = StateObject(wrappedValue: ReaderModel())
        #endif
    }
    var body: some Scene { WindowGroup { ReaderHome().environmentObject(model).tint(Palette.color(0x1F7A73)) } }
}

struct ReaderHome: View {
    @EnvironmentObject var model: ReaderModel
    @State private var importing = false
    @State private var keyboardVisible = false
    @State private var clearedPassage: String?
    @State private var translation = false
    @State private var selectedTab = 0
    @State private var editing = true
    @State private var searchFocusRequest = 0
    @State private var wantsSearchFocus = false
    @State private var switchingDictionary = false
    @State private var librarySearch = ""
    @State private var deleteAll = false
    @FocusState private var passageFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("paletteAccent") private var accentRGB = 0x1F7A73
    @AppStorage("palettePaper") private var paperRGB = 0xFFFFFF
    @AppStorage("customReadingPaper") private var customPaper = false
    // Empty on upgrade: existing installs keep the colors they already chose.
    @AppStorage("readerThemePreset") private var themeID = ""

    private var style: ReaderStyle {
        ReaderStyle.resolve(themeID: themeID, customPaper: customPaper, paperRGB: paperRGB,
                            customAccentRGB: accentRGB, systemDark: colorScheme == .dark)
    }
    private var activeTheme: ReaderTheme { ReaderTheme.resolve(themeID, hasCustomPaper: customPaper) }
    private var paper: Color { style.background }
    private var ink: Color { style.ink }
    private var accent: Color { style.accent }
    private func colorBinding(_ value: Binding<Int>) -> Binding<Color> {
        Binding(get: { Palette.color(value.wrappedValue) }, set: { value.wrappedValue = Palette.rgb($0) })
    }
    private func dismissKeyboard() {
        passageFocused = false
        wantsSearchFocus = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    private func clearPassage() {
        clearedPassage = model.text
        model.cancelPendingSearch()
        model.text = ""; model.readerOffset = .zero; model.readerSelection = ""
        model.status = "Passage cleared."
        editing = true
        dismissKeyboard()
    }
    private func read() {
        passageFocused = false
        model.readPassage(); editing = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    private var filteredPassages: [SavedText] {
        guard !librarySearch.isEmpty else { return model.saved }
        return model.saved.filter { $0.text.localizedCaseInsensitiveContains(librarySearch) || $0.note.localizedCaseInsensitiveContains(librarySearch) }
    }
    var body: some View {
        TabView(selection: $selectedTab) {
            readerTab
            searchTab
            libraryTab
        }
        .background(KeyboardDismissArea(enabled: keyboardVisible && selectedTab != 2, dismiss: dismissKeyboard))
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if keyboardVisible { keyboardBar }
        }
        .tint(accent)
        .foregroundStyle(ink)
        .preferredColorScheme(style.colorScheme)
        .background(paper.ignoresSafeArea())
        .environment(\.readerStyle, style)
        .onChange(of: selectedTab) { _, tab in
            if tab == 1 {
                wantsSearchFocus = !model.showingLookup
                if wantsSearchFocus { model.showResults(); searchFocusRequest += 1 }
            } else {
                wantsSearchFocus = false; model.closeLookup()
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        }
        .onChange(of: model.lookupNavigation) { _, _ in wantsSearchFocus = false; selectedTab = 1 }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let folder): model.importFolder(folder)
            case .failure(let error): model.status = error.localizedDescription
            }
        }
    }

    // Stays reachable above the keyboard on every screen.
    private var keyboardBar: some View {
        HStack {
            if selectedTab == 0 && passageFocused {
                Button("Read") { read() }.accessibilityIdentifier("openPassage")
            } else {
                Button("Read") { dismissKeyboard(); selectedTab = 0 }.accessibilityIdentifier("keyboardReadTab")
            }
            Spacer()
            Button("Search") { selectedTab = 1; requestSearchFocus() }.accessibilityIdentifier("keyboardSearchTab")
            Spacer()
            Button("Library") { dismissKeyboard(); selectedTab = 2 }.accessibilityIdentifier("keyboardLibraryTab")
            Spacer()
            Button("Done") { dismissKeyboard() }.accessibilityIdentifier("dismissKeyboard").fontWeight(.semibold)
        }
        .font(.subheadline)
        .tint(accent)
        .padding(.horizontal)
        .frame(minHeight: 44)
        .background(paper)
        .background(KeyboardControlArea())
        .overlay(alignment: .top) { Rectangle().fill(style.separator).frame(height: 1) }
    }

    // MARK: - Read

    private var readerTab: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if editing { composeView } else { readingView }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(paper)
            .navigationTitle("Japanese Reader").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if model.text.isEmpty, let previous = clearedPassage {
                        Button("Undo clear") { model.text = previous; clearedPassage = nil; model.status = "" }.accessibilityIdentifier("undoClearPassage")
                    } else {
                        Button("Clear") { clearPassage() }.disabled(model.text.isEmpty).accessibilityIdentifier("clearPassage")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !editing {
                        Menu("Actions") {
                            Button("Translate") { translation = true }.disabled(model.text.isEmpty)
                            Button("Copy learning prompt") { UIPasteboard.general.string = model.prompt(); model.status = "Learning prompt copied." }
                        }.translationPresentation(isPresented: $translation, text: model.text)
                    }
                }
            }
        }
        .toolbarBackground(paper, for: .tabBar, .navigationBar)
        .toolbarBackground(.visible, for: .tabBar, .navigationBar)
        .tabItem { Label("Read", systemImage: "book") }.tag(0)
    }

    private var composeView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ReaderMetrics.stack) {
                HStack(spacing: 10) {
                    PasteButton(payloadType: String.self) { strings in
                        guard !strings.isEmpty else { return }
                        model.text = strings.joined(separator: "\n"); model.readerOffset = .zero
                        model.status = ""
                        editing = true
                        passageFocused = false
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .foregroundStyle(style.onAccent)
                    .accessibilityIdentifier("pastePassage")
                    Text("Paste Japanese from another app").font(.caption).foregroundStyle(style.secondary)
                    Spacer(minLength: 0)
                }
                Text("Paste a passage. Select a word to look it up.").font(.subheadline).foregroundStyle(style.secondary)
                optionsPanel
                Picker("Reading mode", selection: $editing) {
                    Text("Paste / edit").tag(true); Text("Read / select words").tag(false)
                }
                .pickerStyle(.segmented)
                .background(KeyboardControlArea())
                editorPanel
                HStack(spacing: 10) {
                    if !passageFocused {
                        Button("Read") { read() }
                            .buttonStyle(PrimaryActionStyle(style: style))
                            .accessibilityIdentifier("openPassage")
                    }
                    Button("Save") { model.save() }
                    Button("Translate") { translation = true }
                        .disabled(model.text.isEmpty)
                        .translationPresentation(isPresented: $translation, text: model.text)
                    Spacer(minLength: 0)
                }
                .buttonStyle(SoftActionStyle(style: style))
                Button {
                    UIPasteboard.general.string = model.prompt()
                    model.status = "Learning prompt copied. Paste it into your preferred AI app."
                } label: {
                    Label("Copy learning prompt", systemImage: "doc.on.doc")
                }
                .buttonStyle(SoftActionStyle(style: style, prominent: true))
                if !model.status.isEmpty { StatusNote(text: model.status, style: style) }
            }
            .padding(.horizontal, ReaderMetrics.gutter)
            .padding(.top, 12)
            .padding(.bottom, 26)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var optionsPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            Toggle("Auto-search selected words", isOn: $model.readerAutoSearch)
                .background(KeyboardControlArea())
                .accessibilityIdentifier("readerAutoSearch")
            Rectangle().fill(style.separator).frame(height: 1)
            Toggle("Auto-save passages", isOn: $model.autoSave)
                .background(KeyboardControlArea())
                .accessibilityIdentifier("autoSavePassages")
            Text(model.autoSave ? "Saved when you tap Read. Your choice is remembered." : "Off: pasted text stays temporary unless you tap Save.")
                .font(.caption).foregroundStyle(style.faint)
        }
        .font(.subheadline)
        .readerInset(style, padding: 12)
    }

    private var editorPanel: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $model.text)
                .scrollContentBackground(.hidden)
                .foregroundStyle(ink)
                .background(Color.clear)
                .font(.system(size: 21))
                .lineSpacing(5)
                .focused($passageFocused)
                .frame(height: 220)
                .accessibilityIdentifier("passageEditor")
            if model.text.isEmpty {
                Text("日本語をここに貼り付け")
                    .font(.system(size: 20))
                    .foregroundStyle(style.faint)
                    .padding(.top, 9).padding(.leading, 6)
                    .allowsHitTesting(false)
            }
        }
        .padding(8)
        .background(style.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(passageFocused ? accent.opacity(0.8) : style.hairline,
                              lineWidth: passageFocused ? 1.8 : 1)
        )
        .animation(.easeOut(duration: 0.18), value: passageFocused)
    }

    private var readingView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Toggle("Auto-search selected words", isOn: $model.readerAutoSearch)
                    .background(KeyboardControlArea())
                    .accessibilityIdentifier("readerAutoSearch")
            }
            .font(.subheadline)
            .foregroundStyle(style.secondary)
            .padding(.horizontal, ReaderMetrics.gutter)
            .padding(.vertical, 9)
            Rectangle().fill(style.separator).frame(height: 1)
            SelectableJapanese(text: model.text, ink: UIColor(ink), paper: UIColor(style.surface),
                               tint: UIColor(accent), initialOffset: model.readerOffset,
                               saveOffset: { model.readerOffset = $0 }) { word in
                guard !model.showingLookup, selectedTab == 0 else { return }
                model.select(word, inDictionary: false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(style.surface)
            readingActions
        }
    }

    private var readingActions: some View {
        VStack(spacing: 8) {
            HStack(spacing: 9) {
                Button("Paste / edit") { editing = true; model.readerSelection = "" }
                Button("Save") { model.save() }
                Spacer(minLength: 0)
                Button("Search selected text") { model.searchSelected(inDictionary: false) }
                    .buttonStyle(SoftActionStyle(style: style, prominent: true))
                    .disabled(model.readerSelection.isEmpty)
            }
            .buttonStyle(SoftActionStyle(style: style))
            if !model.status.isEmpty {
                Text(model.status).font(.caption).foregroundStyle(style.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(paper)
        .overlay(alignment: .top) { Rectangle().fill(style.separator).frame(height: 1) }
    }

    // MARK: - Search

    private var searchTab: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if model.showingEntry { entryView } else { lookup(focusSearch: wantsSearchFocus) }
                if !model.status.isEmpty {
                    StatusNote(text: model.status, style: style, symbol: "book.closed")
                        .padding(.horizontal, 12).padding(.bottom, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(paper)
            .overlay(alignment: .leading) { backSwipeEdge(fromLeft: true) }
            .overlay(alignment: .trailing) { backSwipeEdge(fromLeft: false) }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if model.showingEntry {
                        Button { goBackInSearch() } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Back")
                    } else { Button(model.canGoBack ? "Back" : "Back to Main Page") { goBackInSearch() } }
                }
                ToolbarItem(placement: .principal) {
                    if model.showingEntry { entryTitleButton }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if model.showingEntry {
                        Menu {
                            Button("Search results") { model.showResults(); requestSearchFocus() }
                            Button("Copy learning prompt") { UIPasteboard.general.string = model.prompt(inDictionary: true); model.status = "Learning prompt copied." }
                            Button("Back to Main Page") { selectedTab = 0 }
                        } label: { Image(systemName: "line.3.horizontal") }.accessibilityLabel("Dictionary navigation")
                    } else {
                        Button {
                            UIPasteboard.general.string = model.prompt(inDictionary: model.selectionFromDictionary)
                            model.status = "Learning prompt copied."
                        } label: { Image(systemName: "doc.on.doc") }.accessibilityLabel("Copy learning prompt")
                    }
                }
            }
            .sheet(isPresented: $switchingDictionary) {
                NavigationStack {
                    resultGroups(model.entryMatches, switching: true)
                        .navigationTitle(model.entryTitle).navigationBarTitleDisplayMode(.inline)
                        .toolbar { Button("Done") { switchingDictionary = false } }
                        .background(paper)
                }
                .presentationDetents([.medium, .large])
                .presentationBackground(paper)
            }
        }
        .toolbarBackground(paper, for: .tabBar, .navigationBar)
        .toolbarBackground(.visible, for: .tabBar, .navigationBar)
        .tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(1)
    }

    private var entryTitleButton: some View {
        Button { switchingDictionary = true } label: {
            VStack(spacing: 1) {
                Text(model.entryDictionary)
                    .font(.caption2).lineLimit(1).foregroundStyle(style.secondary)
                HStack(spacing: 4) {
                    Text(model.entryTitle).font(.headline).lineLimit(1).foregroundStyle(style.ink)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(accent)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(style.accentSoft, in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("switchDictionary")
    }

    private var entryView: some View {
        let visitID = model.entryID
        return ZStack(alignment: .bottom) {
            DictionaryPage(html: model.entryHTML, root: model.entryRoot ?? model.dictionaryRoot, code: model.entryCode,
                           paperRGB: style.backgroundRGB, accentRGB: style.accentRGB,
                           initialOffset: model.entryOffsets[visitID] ?? .zero,
                           saveOffset: { model.entryOffsets[visitID] = $0 },
                           followLink: { model.followEntryLink($0) }) { word in
                guard selectedTab == 1, model.showingEntry else { return }
                model.select(word, inDictionary: true)
            }
            .id(visitID.uuidString + style.identity)
            if !model.dictionarySelection.isEmpty {
                Button("Search selected text") { model.searchSelected(inDictionary: true) }
                    .buttonStyle(SoftActionStyle(style: style, prominent: true))
                    .shadow(color: style.shadow, radius: 10, y: 4)
                    .padding(.bottom, 12)
            }
        }
        .overlay(alignment: .top) {
            if model.lookupBusy {
                ProgressView().controlSize(.small).padding(8)
                    .background(style.surface, in: Capsule()).padding(.top, 6)
            }
        }
    }

    private func lookup(focusSearch: Bool) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(accent)
                JapaneseSearchField(text: $model.word, focusRequest: searchFocusRequest,
                                    active: focusSearch && selectedTab == 1 && !model.showingEntry,
                                    ink: UIColor(ink), accent: UIColor(accent),
                                    changed: { model.typedSearch($0, clearSelection: true) }) { model.search() }
                    .frame(height: 36)
                if model.lookupBusy { ProgressView().controlSize(.small) }
                Button { model.search() } label: { Image(systemName: "arrow.forward") }
                    .buttonStyle(GlyphActionStyle(style: style))
                    .accessibilityLabel("Search dictionaries")
                    .background(KeyboardControlArea())
            }
            .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 7)
            .readerCard(style, padding: 0, radius: 16)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    scopeChip("All", id: "")
                    ForEach(model.dictionaries.filter { !model.disabledDictionaries.contains($0.id) }) { scopeChip($0.name, id: $0.id) }
                }
                .padding(.horizontal, 12)
            }
            HStack(spacing: 10) {
                Picker("Match", selection: $model.searchMode) {
                    Text("Starts with").tag(DictionarySearchMode.prefix)
                    Text("Exact word").tag(DictionarySearchMode.exact)
                }
                .pickerStyle(.menu)
                .tint(accent)
                .background(KeyboardControlArea())
                Spacer()
                Button { requestSearchFocus() } label: { Image(systemName: "keyboard") }
                    .buttonStyle(GlyphActionStyle(style: style))
                    .accessibilityLabel("Show search keyboard")
                    .background(KeyboardControlArea())
            }
            .padding(.horizontal, 14)
            if model.hits.isEmpty {
                EmptyHint(symbol: model.word.isEmpty ? "character.book.closed" : "magnifyingglass",
                          title: model.word.isEmpty ? "Look up any Japanese word" : "Nothing found yet",
                          detail: model.word.isEmpty
                            ? "Type above, or highlight a word while reading. Enabled dictionaries are searched in your chosen order."
                            : "Exact matches appear first, then words that start with your text. Try the dictionary form.",
                          style: style)
                Spacer(minLength: 0)
            } else {
                resultGroups(model.hits)
            }
        }
        .background(paper)
        .onChange(of: model.searchMode) { _, _ in model.typedSearch(model.word) }
    }

    private func scopeChip(_ name: String, id: String) -> some View {
        let selected = model.searchScope == id
        return Button { model.searchScope = id; model.typedSearch(model.word) } label: {
            Text(name)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .lineLimit(1)
                .foregroundStyle(selected ? style.onAccent : style.ink)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(selected ? accent : style.raised, in: Capsule(style: .continuous))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(selected ? Color.clear : style.hairline, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .background(KeyboardControlArea())
        .accessibilityIdentifier("searchScope_" + id)
    }

    private func resultGroups(_ hits: [DictionaryHit], switching: Bool = false) -> some View {
        List {
            ForEach(model.dictionaries) { dictionary in
                let matches = hits.filter { $0.root == dictionary.root && $0.code == dictionary.code }
                if !matches.isEmpty {
                    Section {
                        ForEach(matches, id: \.identity) { hit in
                            Button {
                                switchingDictionary = false
                                wantsSearchFocus = false
                                model.open(hit, replacingCurrent: switching)
                            } label: {
                                resultRow(hit, switching: switching)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
                            .accessibilityIdentifier("dictionaryResult_" + hit.word)
                        }
                    } header: {
                        HStack(spacing: 7) {
                            Image(systemName: "book.closed").font(.system(size: 11, weight: .semibold))
                            Text(dictionary.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Spacer()
                            Text("\(matches.count)")
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(style.accentSoft, in: Capsule())
                        }
                        .textCase(nil)
                        .foregroundStyle(accent)
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 5, trailing: 16))
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(paper)
    }

    private func resultRow(_ hit: DictionaryHit, switching: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(hit.word).font(.system(size: 19, weight: .semibold)).foregroundStyle(ink)
                if !hit.preview.isEmpty {
                    Text(hit.preview).font(.subheadline).foregroundStyle(style.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if switching && hit.identity == model.entryHitIdentity {
                Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(accent)
            } else {
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(style.faint)
            }
        }
        .padding(.vertical, 11).padding(.horizontal, 14)
        .readerCard(style, padding: 0, radius: 14, elevated: false)
    }

    private func goBackInSearch() {
        if model.canGoBack {
            model.backToPreviousEntry()
            if !model.showingEntry { requestSearchFocus() }
        } else { selectedTab = 0 }
    }
    private func backSwipeEdge(fromLeft: Bool) -> some View {
        Color.clear.frame(width: 24).contentShape(Rectangle())
            .accessibilityIdentifier(fromLeft ? "backSwipeLeftEdge" : "backSwipeRightEdge")
            .gesture(DragGesture(minimumDistance: 25).onEnded { value in
                let horizontal = value.translation.width
                if abs(horizontal) > 65 && abs(horizontal) > abs(value.translation.height) * 2 && (fromLeft ? horizontal > 0 : horizontal < 0) {
                    goBackInSearch()
                }
            })
    }
    private func requestSearchFocus() { wantsSearchFocus = true; searchFocusRequest += 1 }

    // MARK: - Library

    private var libraryTab: some View {
        NavigationStack {
            List {
                Group {
                    savedSection
                    dictionariesSection
                    Section("Dictionary search") {
                        Toggle("Auto-search inside all dictionaries", isOn: $model.dictionaryAutoSearch).accessibilityIdentifier("dictionaryAutoSearch")
                        Text("Independent of Reader auto-search. A matching selection opens results across enabled dictionaries. When off, use Search selected text.").font(.caption).foregroundStyle(style.secondary)
                        Text("Search prefers an enabled Japanese keyboard. Enable Japanese – Romaji in iPhone Settings → General → Keyboard → Keyboards. iOS controls the exact Japanese layout.").font(.caption).foregroundStyle(style.secondary)
                    }
                    appearanceSection
                    Section("Keep a backup") {
                        Text("Your passages and notes are in reading-library.json in Files → On My iPhone → Japanese Reader. Copy this file before uninstalling. Dictionary files can also be copied from here.").font(.footnote).foregroundStyle(style.secondary)
                    }
                    Section("Translation") {
                        Text("Translate opens Apple's translation panel. Apple may ask you to download languages. Argos and LM Studio from the Windows app are not included in this iPhone edition. Copy learning prompt works with any AI app you choose.").font(.footnote).foregroundStyle(style.secondary)
                    }
                    if model.busy { ProgressView("Working…") }
                    if !model.status.isEmpty { Text(model.status).font(.footnote).foregroundStyle(style.secondary) }
                }
                .listRowBackground(style.surface)
            }
            .scrollContentBackground(.hidden)
            .background(paper)
            .navigationTitle("Library & setup")
            .searchable(text: $librarySearch, prompt: "Find saved text or notes")
            .toolbar { EditButton() }
            .confirmationDialog("Delete all \(model.saved.count) saved passages and their notes?", isPresented: $deleteAll, titleVisibility: .visible) {
                Button("Delete all", role: .destructive) { model.delete(ids: Set(model.saved.map(\.id))) }
                Button("Cancel", role: .cancel) {}
            }
        }
        .toolbarBackground(paper, for: .tabBar, .navigationBar)
        .toolbarBackground(.visible, for: .tabBar, .navigationBar)
        .tabItem { Label("Library", systemImage: "books.vertical") }.tag(2)
    }

    private var savedSection: some View {
        Section("Saved passages · \(model.saved.count)") {
            if model.saved.isEmpty {
                Text("No saved passages. Use Save, or turn on Auto-save and tap Read.").foregroundStyle(style.secondary).accessibilityIdentifier("emptyLibrary")
            } else if filteredPassages.isEmpty {
                Text("No passages match your search.").foregroundStyle(style.secondary)
            }
            ForEach(filteredPassages) { item in
                VStack(alignment: .leading, spacing: 7) {
                    Button { model.text = item.text; model.readerOffset = .zero; selectedTab = 0; editing = false } label: {
                        Text(item.text)
                            .lineLimit(3)
                            .font(.system(size: 16))
                            .foregroundStyle(style.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    HStack(spacing: 6) {
                        Image(systemName: "calendar").font(.system(size: 10, weight: .semibold))
                        Text(item.date, style: .date).font(.caption)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(style.faint)
                    TextField("Study note", text: Binding(get: { model.saved.first(where: { $0.id == item.id })?.note ?? "" }, set: { model.updateNote(id: item.id, note: $0) }), axis: .vertical)
                        .font(.subheadline)
                        .foregroundStyle(style.secondary)
                }
                .padding(.vertical, 3)
            }.onDelete { offsets in
                let ids = Set(offsets.map { filteredPassages[$0].id })
                model.delete(ids: ids)
            }
            if !model.recentlyDeleted.isEmpty { Button("Undo delete") { model.undoDelete() } }
            if !model.saved.isEmpty {
                ShareLink(item: model.libraryURL) { Label("Export saved texts", systemImage: "square.and.arrow.up") }
                Button("Delete all saved passages", role: .destructive) { deleteAll = true }
            }
        }
    }

    private var dictionariesSection: some View {
        Section("Offline dictionaries · \(model.dictionaries.count)") {
            Text("Move the supplied dictionaries folder into On My iPhone → Japanese Reader using Files, then tap Refresh. Or import the folder below.").font(.subheadline).foregroundStyle(style.secondary)
            Button("Add dictionary pack") { importing = true }.disabled(model.busy)
            Button("Refresh dictionaries") { model.reload() }
            Text("Switch dictionaries on or off. Tap Edit, then drag the handles to set lookup order. Add another prepared pack without downloading your existing dictionaries again.").font(.caption).foregroundStyle(style.faint)
            HStack {
                Button("Enable all") { for item in model.dictionaries { model.enableDictionary(item.id, enabled: true) } }
                Button("Disable all") { for item in model.dictionaries { model.enableDictionary(item.id, enabled: false) } }
            }
            ForEach(model.dictionaries) { item in
                Toggle(item.name, isOn: Binding(get: { !model.disabledDictionaries.contains(item.id) }, set: { model.enableDictionary(item.id, enabled: $0) })).font(.footnote)
            }.onMove { model.moveDictionaries(from: $0, to: $1) }
        }
    }

    private var appearanceSection: some View {
        Section("Appearance") {
            VStack(alignment: .leading, spacing: 9) {
                SectionLabel("THEME", symbol: "paintpalette", style: style).padding(.trailing, 16)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(ReaderTheme.all) { theme in
                            Button { themeID = theme.id } label: {
                                ThemeSwatch(theme: theme, style: style,
                                            selected: activeTheme.id == theme.id,
                                            accentOverride: theme.family == .custom ? accentRGB : nil,
                                            backgroundOverride: theme.family == .custom && customPaper ? paperRGB : nil)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("theme_" + theme.id)
                            .accessibilityLabel(theme.name)
                            .accessibilityAddTraits(activeTheme.id == theme.id ? [.isSelected] : [])
                        }
                    }
                    .padding(.vertical, 3)
                    .padding(.trailing, 16)
                }
                Text("\(activeTheme.name) · \(activeTheme.detail)").font(.caption).foregroundStyle(style.secondary)
                    .padding(.trailing, 16)
            }
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 0))
            if activeTheme.family == .custom {
                ColorPicker("Accent color", selection: colorBinding($accentRGB), supportsOpacity: false).accessibilityIdentifier("accentColor")
                Toggle("Custom app background", isOn: $customPaper).accessibilityIdentifier("customPaper")
                if customPaper {
                    ColorPicker("App background", selection: colorBinding($paperRGB), supportsOpacity: false)
                }
            }
            appearancePreview
            Text("Reading text automatically switches between black and white for contrast, and dictionary pages follow the same theme. Your choice is remembered.").font(.caption).foregroundStyle(style.faint)
            Button("Reset colors") {
                themeID = ReaderTheme.systemID; accentRGB = 0x1F7A73; paperRGB = 0xFFFFFF; customPaper = false
            }
        }
    }

    private var appearancePreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("日本語 · Reading preview").font(.title3).foregroundStyle(ink)
                Spacer(minLength: 0)
                Circle().fill(accent).frame(width: 15, height: 15)
            }
            Text("選んだ単語はここで調べられます。").font(.subheadline).foregroundStyle(style.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(paper, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(style.hairline, lineWidth: 1)
        )
    }
}

struct SelectableJapanese: UIViewRepresentable {
    let text: String
    var ink: UIColor = .label
    var paper: UIColor = .systemBackground
    var tint: UIColor? = nil
    var initialOffset: CGPoint = .zero
    var saveOffset: ((CGPoint) -> Void)? = nil
    let selected: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(selected) }
    // Reading typography: comfortable line height and page margins for Japanese.
    static func styled(_ text: String, ink: UIColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.30
        paragraph.paragraphSpacing = 11
        return NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: 23),
            .foregroundColor: ink,
            .paragraphStyle: paragraph
        ])
    }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(); view.isEditable = false; view.isSelectable = true
        view.accessibilityIdentifier = "selectablePassage"
        view.font = .systemFont(ofSize: 23); view.backgroundColor = .clear; view.delegate = context.coordinator
        view.textContainerInset = UIEdgeInsets(top: 18, left: 14, bottom: 34, right: 14)
        view.alwaysBounceVertical = true
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.selected = selected
        context.coordinator.saveOffset = saveOffset
        // Rebuilding the attributed text clears the selection, so only do it when
        // the passage itself or the theme's ink actually changed.
        let textChanged = view.text != text
        if textChanged || context.coordinator.appliedInk != ink {
            view.attributedText = Self.styled(text, ink: ink)
            context.coordinator.appliedInk = ink
        }
        if textChanged { DispatchQueue.main.async { view.setContentOffset(initialOffset, animated: false) } }
        // The attributed text above already carries the ink color; assigning
        // textColor here would re-apply attributes and drop a live selection.
        if view.backgroundColor != paper { view.backgroundColor = paper }
        if let tint, view.tintColor != tint { view.tintColor = tint }
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var selected: (String) -> Void
        var saveOffset: ((CGPoint) -> Void)?
        var appliedInk: UIColor?
        func scrollViewDidScroll(_ scrollView: UIScrollView) { saveOffset?(scrollView.contentOffset) }
        var pending: DispatchWorkItem?
        init(_ selected: @escaping (String) -> Void) { self.selected = selected }
        func textViewDidChangeSelection(_ textView: UITextView) {
            pending?.cancel()
            guard let range = textView.selectedTextRange, let word = textView.text(in: range), !word.isEmpty, word.count <= 40 else {
                // UIKit can clear selection inside updateUIView; publish after that update.
                let action = DispatchWorkItem { [weak self] in self?.selected("") }
                pending = action
                DispatchQueue.main.async(execute: action)
                return
            }
            let selectedRange = textView.selectedRange
            let action = DispatchWorkItem { [weak textView, weak self] in
                guard let textView, textView.selectedRange == selectedRange else { return }
                self?.selected(word)
            }
            pending = action; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: action)
        }
    }
}
