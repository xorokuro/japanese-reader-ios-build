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
    var body: some Scene { WindowGroup { ReaderHome().environmentObject(model).tint(Color(red: 0.12, green: 0.48, blue: 0.45)) } }
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
    private var paper: Color { customPaper ? Palette.color(paperRGB) : Color(uiColor: .systemBackground) }
    private var ink: Color { customPaper ? Palette.ink(paperRGB) : .primary }
    private var appDark: Bool { customPaper ? Palette.luminance(Palette.channels(paperRGB)) < 0.179 : colorScheme == .dark }
    private var accent: Color { Palette.accessibleAccent(accentRGB, dark: appDark, backgroundRGB: customPaper ? paperRGB : nil) }
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
            if keyboardVisible {
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
                    Button("Done") { dismissKeyboard() }.accessibilityIdentifier("dismissKeyboard")
                }.font(.subheadline).padding(.horizontal).frame(minHeight: 44).background(paper).background(KeyboardControlArea())
                    .overlay(alignment: .top) { Divider() }
            }
        }
        .tint(accent)
        .foregroundStyle(ink)
        .preferredColorScheme(customPaper ? (appDark ? .dark : .light) : nil)
        .background(paper.ignoresSafeArea())
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
    private var readerTab: some View {
        NavigationStack {
                VStack(spacing: 0) {
                if editing {
                ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        PasteButton(payloadType: String.self) { strings in
                            guard !strings.isEmpty else { return }
                            model.text = strings.joined(separator: "\n"); model.readerOffset = .zero
                            model.status = ""
                            editing = true
                            passageFocused = false
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        }.buttonStyle(.borderedProminent).tint(Palette.color(accentRGB)).foregroundStyle(Palette.ink(accentRGB)).accessibilityIdentifier("pastePassage")
                        Text("Paste Japanese from another app").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Paste a passage. Select a word to look it up.").font(.subheadline).foregroundStyle(.secondary)
                    Toggle("Auto-search selected words", isOn: $model.readerAutoSearch).background(KeyboardControlArea()).accessibilityIdentifier("readerAutoSearch")
                    Toggle("Auto-save passages", isOn: $model.autoSave).background(KeyboardControlArea()).accessibilityIdentifier("autoSavePassages")
                    Text(model.autoSave ? "Saved when you tap Read. Your choice is remembered." : "Off: pasted text stays temporary unless you tap Save.").font(.caption).foregroundStyle(.secondary)
                    Picker("Reading mode", selection: $editing) {
                        Text("Paste / edit").tag(true); Text("Read / select words").tag(false)
                    }.pickerStyle(.segmented).background(KeyboardControlArea())
                    TextEditor(text: $model.text).scrollContentBackground(.hidden).foregroundStyle(ink).background(paper).font(.system(size: 21)).focused($passageFocused).frame(height: 220).accessibilityIdentifier("passageEditor").overlay(RoundedRectangle(cornerRadius: 12).stroke(.secondary.opacity(0.3)))
                    HStack {
                        if !passageFocused { Button("Read") { read() }.buttonStyle(.borderedProminent).tint(Palette.color(accentRGB)).foregroundStyle(Palette.ink(accentRGB)).accessibilityIdentifier("openPassage") }
                        Button("Save") { model.save() }.buttonStyle(.bordered)
                        Button("Translate") { translation = true }.buttonStyle(.bordered).disabled(model.text.isEmpty)
                            .translationPresentation(isPresented: $translation, text: model.text)
                    }
                    Button { UIPasteboard.general.string = model.prompt(); model.status = "Learning prompt copied. Paste it into your preferred AI app." } label: { Label("Copy learning prompt", systemImage: "doc.on.doc") }
                    if !model.status.isEmpty { Text(model.status).font(.footnote).foregroundStyle(.secondary) }
                }.padding()
                }.scrollDismissesKeyboard(.interactively)
                } else {
                    Toggle("Auto-search selected words", isOn: $model.readerAutoSearch).padding(.horizontal).background(KeyboardControlArea()).accessibilityIdentifier("readerAutoSearch")
                    SelectableJapanese(text: model.text, ink: UIColor(ink), paper: UIColor(paper), initialOffset: model.readerOffset, saveOffset: { model.readerOffset = $0 }) { word in
                        guard !model.showingLookup, selectedTab == 0 else { return }
                        model.select(word, inDictionary: false)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    HStack {
                        Button("Paste / edit") { editing = true; model.readerSelection = "" }
                        Button("Save") { model.save() }
                        Button("Search selected text") { model.searchSelected(inDictionary: false) }.disabled(model.readerSelection.isEmpty)
                    }.buttonStyle(.bordered).padding(8)
                    if !model.status.isEmpty { Text(model.status).font(.caption).padding(.horizontal) }
                }
                }.background(paper)
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
    private var searchTab: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if model.showingEntry {
                    let visitID = model.entryID
                    DictionaryPage(html: model.entryHTML, root: model.entryRoot ?? model.dictionaryRoot, code: model.entryCode,
                                   paperRGB: customPaper ? paperRGB : nil,
                                   initialOffset: model.entryOffsets[visitID] ?? .zero,
                                   saveOffset: { model.entryOffsets[visitID] = $0 },
                                   followLink: { model.followEntryLink($0) }) { word in
                        guard selectedTab == 1, model.showingEntry else { return }
                        model.select(word, inDictionary: true)
                    }.id(visitID.uuidString + (customPaper ? String(paperRGB) : "system"))
                    if !model.dictionarySelection.isEmpty {
                        Button("Search selected text") { model.searchSelected(inDictionary: true) }.padding(6)
                    }
                    if model.lookupBusy { ProgressView() }
                } else { lookup(focusSearch: wantsSearchFocus) }
                if !model.status.isEmpty { Text(model.status).font(.caption).padding(.horizontal, 8) }
            }.background(paper)
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
                        if model.showingEntry {
                            Button { switchingDictionary = true } label: {
                                VStack(spacing: 1) {
                                    Text(model.entryDictionary).font(.caption2).lineLimit(1)
                                    HStack { Text(model.entryTitle).lineLimit(1); Image(systemName: "chevron.down").font(.caption) }
                                }
                            }.accessibilityIdentifier("switchDictionary")
                        }
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
                    }.presentationDetents([.medium, .large])
                }
        }
        .toolbarBackground(paper, for: .tabBar, .navigationBar)
        .toolbarBackground(.visible, for: .tabBar, .navigationBar)
        .tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(1)
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
    private var libraryTab: some View {
        NavigationStack {
                List {
                    Group {
                    Section("Saved passages · \(model.saved.count)") {
                        if model.saved.isEmpty {
                            Text("No saved passages. Use Save, or turn on Auto-save and tap Read.").foregroundStyle(.secondary).accessibilityIdentifier("emptyLibrary")
                        } else if filteredPassages.isEmpty {
                            Text("No passages match your search.").foregroundStyle(.secondary)
                        }
                        ForEach(filteredPassages) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                Button { model.text = item.text; model.readerOffset = .zero; selectedTab = 0; editing = false } label: { Text(item.text).lineLimit(3).foregroundStyle(.primary) }
                                Text(item.date, style: .date).font(.caption).foregroundStyle(.secondary)
                                TextField("Study note", text: Binding(get: { model.saved.first(where: { $0.id == item.id })?.note ?? "" }, set: { model.updateNote(id: item.id, note: $0) }), axis: .vertical)
                            }
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
                    Section("Offline dictionaries · \(model.dictionaries.count)") {
                        Text("Move the supplied dictionaries folder into On My iPhone → Japanese Reader using Files, then tap Refresh. Or import the folder below.").font(.subheadline)
                        Button("Add dictionary pack") { importing = true }.disabled(model.busy)
                        Button("Refresh dictionaries") { model.reload() }
                        Text("Switch dictionaries on or off. Tap Edit, then drag the handles to set lookup order. Add another prepared pack without downloading your existing dictionaries again.").font(.caption)
                        HStack {
                            Button("Enable all") { for item in model.dictionaries { model.enableDictionary(item.id, enabled: true) } }
                            Button("Disable all") { for item in model.dictionaries { model.enableDictionary(item.id, enabled: false) } }
                        }
                        ForEach(model.dictionaries) { item in
                            Toggle(item.name, isOn: Binding(get: { !model.disabledDictionaries.contains(item.id) }, set: { model.enableDictionary(item.id, enabled: $0) })).font(.footnote)
                        }.onMove { model.moveDictionaries(from: $0, to: $1) }
                    }
                    Section("Dictionary search") {
                        Toggle("Auto-search inside all dictionaries", isOn: $model.dictionaryAutoSearch).accessibilityIdentifier("dictionaryAutoSearch")
                        Text("Independent of Reader auto-search. A matching selection opens results across enabled dictionaries. When off, use Search selected text.").font(.caption)
                        Text("Search prefers an enabled Japanese keyboard. Enable Japanese – Romaji in iPhone Settings → General → Keyboard → Keyboards. iOS controls the exact Japanese layout.").font(.caption)
                    }
                    Section("Colors & contrast") {
                        ColorPicker("Accent color", selection: colorBinding($accentRGB), supportsOpacity: false).accessibilityIdentifier("accentColor")
                        Toggle("Custom app background", isOn: $customPaper).accessibilityIdentifier("customPaper")
                        if customPaper {
                            ColorPicker("App background", selection: colorBinding($paperRGB), supportsOpacity: false)
                        }
                        Text("日本語 · Reading preview").font(.title3).foregroundStyle(ink).padding().frame(maxWidth: .infinity).background(paper, in: RoundedRectangle(cornerRadius: 10))
                        Text("Text automatically switches between black and white for contrast. Links adjust for light and dark mode. Colors are remembered.").font(.caption)
                        Button("Reset colors") { accentRGB = 0x1F7A73; paperRGB = 0xFFFFFF; customPaper = false }
                    }
                    Section("Keep a backup") {
                        Text("Your passages and notes are in reading-library.json in Files → On My iPhone → Japanese Reader. Copy this file before uninstalling. Dictionary files can also be copied from here.").font(.footnote)
                    }
                    Section("Translation") {
                        Text("Translate opens Apple's translation panel. Apple may ask you to download languages. Argos and LM Studio from the Windows app are not included in this iPhone edition. Copy learning prompt works with any AI app you choose.").font(.footnote)
                    }
                    if model.busy { ProgressView("Working…") }
                    if !model.status.isEmpty { Text(model.status).font(.footnote) }
                    }.listRowBackground(paper)
                }.scrollContentBackground(.hidden).background(paper)
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
    private func lookup(focusSearch: Bool) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                JapaneseSearchField(text: $model.word, focusRequest: searchFocusRequest,
                                    active: focusSearch && selectedTab == 1 && !model.showingEntry,
                                    ink: UIColor(ink), changed: { model.typedSearch($0, clearSelection: true) }) { model.search() }.frame(height: 36)
                if model.lookupBusy { ProgressView() }
                Button { model.search() } label: { Image(systemName: "arrow.right.circle") }.accessibilityLabel("Search dictionaries")
            }.padding(.horizontal, 10).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    scopeChip("All", id: "")
                    ForEach(model.dictionaries.filter { !model.disabledDictionaries.contains($0.id) }) { scopeChip($0.name, id: $0.id) }
                }
            }
            resultGroups(model.hits)
            HStack {
                Picker("Match", selection: $model.searchMode) {
                    Text("Starts with").tag(DictionarySearchMode.prefix)
                    Text("Exact word").tag(DictionarySearchMode.exact)
                }.pickerStyle(.menu)
                Spacer()
                Button { requestSearchFocus() } label: { Image(systemName: "keyboard") }.accessibilityLabel("Show search keyboard")
            }.padding(.horizontal, 8)
        }.padding(.horizontal, 8).background(paper)
            .onChange(of: model.searchMode) { _, _ in model.typedSearch(model.word) }
    }
    private func scopeChip(_ name: String, id: String) -> some View {
        Button { model.searchScope = id; model.typedSearch(model.word) } label: {
            Text(name).font(.caption).padding(.horizontal, 10).padding(.vertical, 7)
                .background(model.searchScope == id ? accent.opacity(0.18) : .clear, in: Capsule())
        }.foregroundStyle(ink).background(KeyboardControlArea()).accessibilityIdentifier("searchScope_" + id)
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
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(hit.word).font(.headline).foregroundStyle(ink)
                                        if !hit.preview.isEmpty { Text(hit.preview).font(.subheadline).foregroundStyle(ink.opacity(0.8)).lineLimit(2) }
                                    }
                                    Spacer(minLength: 0)
                                    if switching && hit.identity == model.entryHitIdentity { Image(systemName: "checkmark").foregroundStyle(accent) }
                                }.padding(.vertical, 3)
                            }.listRowBackground(paper).accessibilityIdentifier("dictionaryResult_" + hit.word)
                        }
                    } header: {
                        HStack { Image(systemName: "book.closed"); Text(dictionary.name); Spacer(); Text("\(matches.count)") }
                    }
                }
            }
        }.listStyle(.plain).scrollContentBackground(.hidden).background(paper)
    }
}

struct SelectableJapanese: UIViewRepresentable {
    let text: String
    var ink: UIColor = .label
    var paper: UIColor = .systemBackground
    var initialOffset: CGPoint = .zero
    var saveOffset: ((CGPoint) -> Void)? = nil
    let selected: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(selected) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(); view.isEditable = false; view.isSelectable = true
        view.accessibilityIdentifier = "selectablePassage"
        view.font = .systemFont(ofSize: 23); view.backgroundColor = .clear; view.delegate = context.coordinator
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.selected = selected
        context.coordinator.saveOffset = saveOffset
        if view.text != text {
            view.text = text
            DispatchQueue.main.async { view.setContentOffset(initialOffset, animated: false) }
        }
        if view.textColor != ink { view.textColor = ink }
        if view.backgroundColor != paper { view.backgroundColor = paper }
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var selected: (String) -> Void
        var saveOffset: ((CGPoint) -> Void)?
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
