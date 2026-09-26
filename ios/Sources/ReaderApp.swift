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
    /// Filled in after the entry is on screen (it searches every dictionary).
    var alternatives: [DictionaryHit]
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
    @Published private(set) var searchHistory: [String] = []
    func recordSearch(_ query: String) {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        searchHistory.removeAll { $0 == value }
        searchHistory.insert(value, at: 0)
        searchHistory = Array(searchHistory.prefix(200))
        preferences.set(searchHistory, forKey: "searchHistory")
    }
    func deleteSearchHistory(at offsets: IndexSet) {
        searchHistory.remove(atOffsets: offsets)
        preferences.set(searchHistory, forKey: "searchHistory")
    }
    func clearSearchHistory() {
        searchHistory = []
        preferences.set(searchHistory, forKey: "searchHistory")
    }
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
        closePeek()
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
    private var selectionTouchDown = false
    private var selectionTouchCancelled = false
    private var heldSelection: (text: String, inDictionary: Bool)?
    private var releasedSelection: DispatchWorkItem?
    func cancelPendingSearch() {
        liveSearch?.cancel(); liveSearch = nil
        releasedSelection?.cancel(); releasedSelection = nil; heldSelection = nil
        searchGeneration += 1; lookupBusy = false
    }
    func selectionTouchChanged(down: Bool, cancelled: Bool) {
        selectionTouchDown = down
        selectionTouchCancelled = cancelled
        if down || cancelled {
            // Invalidate even a lookup already running on the dictionary queue.
            cancelPendingSearch()
            return
        }
        guard let selection = heldSelection else { return }
        let generation = searchGeneration
        let action = DispatchWorkItem { [weak self] in
            guard let self, !self.selectionTouchDown, !self.selectionTouchCancelled,
                  self.searchGeneration == generation else { return }
            self.select(selection.text, inDictionary: selection.inDictionary)
        }
        releasedSelection = action
        // Let UIKit/WebKit deliver the final selection update after touch-up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: action)
    }
    func select(_ text: String, inDictionary: Bool) {
        if !text.isEmpty { selectionFromDictionary = inDictionary }
        if inDictionary { dictionarySelection = text } else { readerSelection = text }
        cancelPendingSearch()
        // An open card keeps following the selection, even with auto-search off.
        let following = selectionPeek && peek?.inDictionary == inDictionary
        if text.isEmpty {
            if following { closePeek() }
            return
        }
        guard !selectionTouchCancelled,
              following || (inDictionary ? dictionaryAutoSearch : readerAutoSearch) else { return }
        if selectionTouchDown {
            heldSelection = (text, inDictionary)
            return
        }
        if selectionPeek {
            peekLookup(text, inDictionary: inDictionary)
            return
        }
        word = text
        search(dismissKeyboard: false, navigate: true, onlyIfMatched: true)
    }
    func searchSelected(inDictionary: Bool) {
        let selected = inDictionary ? dictionarySelection : readerSelection
        guard !selected.isEmpty else { return }
        if selectionPeek {
            peekLookup(selected, inDictionary: inDictionary)
            return
        }
        word = selected
        search(dismissKeyboard: true, navigate: true)
    }

    // MARK: Selection peek

    /// Selecting shows a dictionary card instead of leaving the page (default on).
    @Published var selectionPeek = true {
        didSet { preferences.set(selectionPeek, forKey: "selectionPeek"); if !selectionPeek { closePeek() } }
    }
    @Published private(set) var peek: PeekState?
    private var peekGeneration = 0
    private func selectionContext(for text: String, inDictionary: Bool) -> SelectionContext {
        let stored = inDictionary ? SelectionBridge.shared.dictionaryContext : SelectionBridge.shared.readerContext
        if stored.text == text { return stored }
        return SelectionContext(text: text, before: "", after: "", location: -1)
    }
    func peekLookup(_ text: String, inDictionary: Bool) {
        let context = selectionContext(for: text, inDictionary: inDictionary)
        peekGeneration += 1
        let generation = peekGeneration
        let enabled = dictionaries.filter { !disabledDictionaries.contains($0.id) }
        var next = PeekState(text: text, before: context.before, after: context.after,
                             location: context.location, inDictionary: inDictionary)
        // Keep the previous results on screen while a refined lookup runs.
        if let current = peek, current.inDictionary == inDictionary {
            next.hits = current.hits; next.matched = current.matched
        }
        peek = next
        queue.async {
            let found = PeekSearch.bestMatch(for: text, in: enabled)
            DispatchQueue.main.async {
                guard generation == self.peekGeneration, var current = self.peek else { return }
                current.matched = found.query
                current.hits = found.hits
                current.busy = false
                self.peek = current
            }
        }
    }
    /// Look up another part of the phrase: moves the real selection when possible.
    func refinePeek(_ range: ClosedRange<Int>) {
        guard let current = peek else { return }
        let characters = current.characters
        guard range.lowerBound >= 0, range.upperBound < characters.count else { return }
        let text = characters[range].joined()
        let before = characters[..<range.lowerBound].joined()
        let after = characters[(range.upperBound + 1)...].joined()
        let offset = before.utf16.count
        let location = current.location >= 0 ? current.location - current.before.utf16.count + offset : -1
        let inDictionary = current.inDictionary
        let direct: () -> Void = { [weak self] in
            guard let self else { return }
            let stored = SelectionContext(text: text, before: before, after: after, location: location)
            if inDictionary {
                SelectionBridge.shared.dictionaryContext = stored
                self.dictionarySelection = text
            } else {
                SelectionBridge.shared.readerContext = stored
                self.readerSelection = text
            }
            self.peekLookup(text, inDictionary: inDictionary)
        }
        if !SelectionBridge.shared.refine(current, offset: offset, length: text.utf16.count, fallback: direct) { direct() }
    }
    func closePeek() {
        peekGeneration += 1
        if peek != nil { peek = nil }
    }
    func openPeekHit(_ hit: DictionaryHit) {
        guard let current = peek else { return }
        word = current.matched.isEmpty ? current.text.trimmingCharacters(in: .whitespacesAndNewlines) : current.matched
        hits = current.hits
        status = ""
        closePeek()
        open(hit)
    }
    func showPeekResults() {
        guard let current = peek else { return }
        let previousPage = showingEntry ? snapshot() : nil
        word = current.matched.isEmpty ? current.text.trimmingCharacters(in: .whitespacesAndNewlines) : current.matched
        closePeek()
        guard !current.hits.isEmpty else {
            search(dismissKeyboard: true, navigate: true)
            return
        }
        cancelPendingSearch()
        if let previousPage { remember(previousPage) }
        hits = current.hits
        status = ""
        recordSearch(word)
        showingEntry = false; showingLookup = true; lookupNavigation = UUID()
    }

    func closeLookup() {
        closePeek()
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
        searchHistory = preferences.stringArray(forKey: "searchHistory") ?? []
        readerAutoSearch = (preferences.object(forKey: "readerAutoSearch") as? Bool) ?? true
        dictionaryAutoSearch = (preferences.object(forKey: "dictionaryAutoSearch") as? Bool) ?? true
        selectionPeek = (preferences.object(forKey: "selectionPeek") as? Bool) ?? true
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
            DictionaryStore.purgeShared()
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
        if dismissKeyboard || navigate { recordSearch(query) }
        lookupBusy = true
        queue.async {
            let result = Result { () -> [DictionaryHit] in
                guard !selected.isEmpty else { throw ReaderError("Enable a dictionary in Library first, or add the dictionaries folder.") }
                return try selected.flatMap { try DictionaryStore.shared(root: $0.root).search(query, codes: [$0.code], mode: mode) }
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
            let result = Result { () -> String in
                let store = try DictionaryStore.shared(root: root)
                return DictionaryPage.make(body: try store.entry(hit), css: try store.stylesheet(code: hit.code), code: hit.code)
            }
            DispatchQueue.main.async {
                guard generation == self.searchGeneration else { return }
                self.lookupBusy = false
                switch result {
                case .success(let html):
                    // Show the definition at once; the dictionary switcher fills in after.
                    let alternatives = [hit]
                    self.recordSearch(query)
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
                    self.loadAlternatives(for: visit.id, hit: hit, query: query, enabled: enabled)
                case .failure(let error): self.status = error.localizedDescription
                }
            }
        }
    }
    /// The title switcher spans all enabled dictionaries, even if Search was scoped
    /// to one dictionary. It is loaded after the definition is already visible.
    private func loadAlternatives(for visitID: UUID, hit: DictionaryHit, query: String, enabled: [InstalledDictionary]) {
        queue.async {
            var seen = Set<String>()
            let alternatives = enabled.flatMap { dictionary -> [DictionaryHit] in
                guard let source = try? DictionaryStore.shared(root: dictionary.root) else { return [] }
                var candidates = (try? source.search(hit.word, codes: [dictionary.code], mode: .exact)) ?? []
                if DictionaryStore.normalize(query) != DictionaryStore.normalize(hit.word) {
                    candidates += (try? source.search(query, codes: [dictionary.code], mode: .exact)) ?? []
                }
                return candidates.filter { seen.insert($0.identity).inserted }
            }
            let value = alternatives.isEmpty ? [hit] : alternatives
            DispatchQueue.main.async {
                if let index = self.visits.firstIndex(where: { $0.id == visitID }) { self.visits[index].alternatives = value }
                if self.entryID == visitID { self.entryMatches = value }
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
        HandFont.register()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-reset-search-keyboard") {
            UserDefaults.standard.removeObject(forKey: "automaticallyShowSearchKeyboard")
        }
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--ui-clipboard"),
           ProcessInfo.processInfo.arguments.indices.contains(index + 1) {
            UIPasteboard.general.string = ProcessInfo.processInfo.arguments[index + 1]
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-dictionary-fixture") {
            UserDefaults.standard.set(false, forKey: "savePassagesOnRead")
            UserDefaults.standard.set(true, forKey: "readerAutoSearch")
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
    @State private var searchFocusRequest = 0
    @AppStorage("automaticallyShowSearchKeyboard") private var automaticallyShowSearchKeyboard = false
    @AppStorage("searchKeyboardLanguage") private var searchKeyboardLanguage = "ja"
    @State private var showingHistory = false
    @State private var clearHistoryConfirmation = false
    @State private var wantsSearchFocus = false
    @State private var switchingDictionary = false
    @State private var collapsedResultGroups = Set<String>()
    @State private var librarySearch = ""
    @State private var deleteAll = false
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("paletteAccent") private var accentRGB = 0x1F7A73
    @AppStorage("palettePaper") private var paperRGB = 0xFFFFFF
    @AppStorage("customReadingPaper") private var customPaper = false
    // Empty on upgrade: existing installs keep the colors they already chose.
    @AppStorage("readerThemePreset") private var themeID = ""
    @AppStorage("readerTypeface") private var readerTypefaceRaw = ReaderTypeface.kyokasho.rawValue
    @AppStorage("handDrawnPaper") private var handDrawnPaper = true
    // Keep the iPhone's own Copy / Look Up bar away from the dictionary card.
    @AppStorage("quietSystemTextMenu") private var quietSystemTextMenu = true
    @AppStorage(SelectionLimit.key) private var selectionLimit = SelectionLimit.standard
    // Line-by-line translation under the passage (Apple Translation, iOS 18+).
    @AppStorage("translationTarget") private var translationTarget = TranslationTarget.english.rawValue
    @State private var showTranslation = false
    @State private var translatedLines: [String] = []
    @State private var translatedKey = ""
    // One-time switch of light-theme installs to the desktop's Washi look (2.0).
    @AppStorage("washiRedesignApplied") private var washiRedesignApplied = false
    @AppStorage("readerTextSize") private var readerTextSize = 23.0
    @AppStorage("readerLineSpacing") private var readerLineSpacing = 1.35
    @AppStorage("dictionaryTextSize") private var dictionaryTextSize = 19.0
    @AppStorage("dictionarySans") private var dictionarySans = false
    // Search header: hides while scrolling down through results, returns on scroll up.
    @State private var headerCollapsed = false
    @State private var headerHeight: CGFloat = 104
    @State private var scrollTracker = ScrollTracker()
    private var readerTypeface: ReaderTypeface { ReaderTypeface.resolve(readerTypefaceRaw) }

    private var style: ReaderStyle {
        ReaderStyle.resolve(themeID: themeID, customPaper: customPaper, paperRGB: paperRGB,
                            customAccentRGB: accentRGB, systemDark: colorScheme == .dark)
    }
    private var activeTheme: ReaderTheme { ReaderTheme.resolve(themeID, hasCustomPaper: customPaper) }
    private var paper: Color { style.background }
    private var paperBackground: some View { PaperBackground(style: style, texture: handDrawnPaper).equatable() }
    private func applyRedesignOnce() {
        guard !washiRedesignApplied else { return }
        washiRedesignApplied = true
        if activeTheme.family == .light || activeTheme.family == .system { themeID = "hand-washi" }
    }
    private var ink: Color { style.ink }
    private var accent: Color { style.accent }
    private func colorBinding(_ value: Binding<Int>) -> Binding<Color> {
        Binding(get: { Palette.color(value.wrappedValue) }, set: { value.wrappedValue = Palette.rgb($0) })
    }
    private func dismissKeyboard() {
        wantsSearchFocus = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    private func clearPassage() {
        clearedPassage = model.text
        model.cancelPendingSearch()
        model.text = ""; model.readerOffset = .zero; model.readerSelection = ""
        model.status = "Passage cleared."
        dismissKeyboard()
    }
    private func pastePassage(_ strings: [String]) {
        guard !strings.isEmpty else { return }
        model.closeLookup()
        model.text = strings.joined(separator: "\n")
        model.readerOffset = .zero
        model.readerSelection = ""
        model.status = ""
        clearedPassage = nil
        if model.autoSave { model.save() }
        dismissKeyboard()
    }
    private var filteredPassages: [SavedText] {
        guard !librarySearch.isEmpty else { return model.saved }
        return model.saved.filter { $0.text.localizedCaseInsensitiveContains(librarySearch) || $0.note.localizedCaseInsensitiveContains(librarySearch) }
    }
    var body: some View {
        TabView(selection: Binding(get: { selectedTab }, set: { tab in
            if tab == 1 { activateSearchTab() } else { selectedTab = tab }
        })) {
            readerTab
            searchTab
            libraryTab
        }
        .sheet(isPresented: $showingHistory) { historySheet }
        .background(SelectionTouchObserver(enabled: selectedTab == 0 || (selectedTab == 1 && model.showingEntry)) { down, cancelled in
            model.selectionTouchChanged(down: down, cancelled: cancelled)
        })
        .background(KeyboardDismissArea(enabled: keyboardVisible && selectedTab != 2, dismiss: dismissKeyboard))
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if keyboardVisible { keyboardBar }
        }
        .tint(accent)
        .foregroundStyle(ink)
        .preferredColorScheme(style.colorScheme)
        .background(paperBackground)
        .environment(\.readerStyle, style)
        .onAppear {
            applyRedesignOnce()
            // Start WebKit once the first screen is up, so the first definition opens fast.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { DictionaryPage.prewarm() }
        }
        .onChange(of: selectedTab) { _, tab in
            // Programmatic lookup navigation must keep the keyboard hidden.
            // User tab taps are handled separately, including reselection.
            if tab != 1 {
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
            Button("Read") { dismissKeyboard(); selectedTab = 0 }.accessibilityIdentifier("keyboardReadTab")
            Spacer()
            Button("Search") { activateSearchTab() }.accessibilityIdentifier("keyboardSearchTab")
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
            translating(VStack(spacing: 0) {
                readerHeader
                readingView
            })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(paperBackground)
            .translationPresentation(isPresented: $translation, text: model.text)
            .toolbar(.hidden, for: .navigationBar)
        }
        .toolbarBackground(paper, for: .tabBar, .navigationBar)
        .toolbarBackground(.visible, for: .tabBar, .navigationBar)
        .tabItem { Label("Read", systemImage: "book") }.tag(0)
    }

    /// Desktop-style header: ensō logo, highlighted 読む title, wavy pencil rule.
    private var readerHeader: some View {
        VStack(spacing: 2) {
            HStack(spacing: 10) {
                EnsoLogo(style: style)
                HandTitle(text: "読む", subtitle: "Reading", style: style, size: 25)
                Spacer(minLength: 6)
                clearButton
                translateButton
                readerOptionsMenu
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            HandRule(style: style).padding(.horizontal, 4)
        }
    }

    @ViewBuilder private var clearButton: some View {
        if model.text.isEmpty, let previous = clearedPassage {
            Button("Undo clear") { model.text = previous; clearedPassage = nil; model.status = "" }
                .buttonStyle(HandSoftButtonStyle(style: style, prominent: true))
                .accessibilityIdentifier("undoClearPassage")
        } else {
            Button("Clear") { clearPassage() }
                .buttonStyle(HandSoftButtonStyle(style: style))
                .disabled(model.text.isEmpty)
                .opacity(model.text.isEmpty ? 0.45 : 1)
                .accessibilityIdentifier("clearPassage")
        }
    }

    private var readerOptionsMenu: some View {
        Menu {
            Button("Save") { model.save() }.disabled(model.text.isEmpty)
            Picker("Translate into", selection: $translationTarget) {
                ForEach(TranslationTarget.allCases) { target in Text(target.title).tag(target.rawValue) }
            }
            .pickerStyle(.menu)
            Button("Translate in a panel") { translation = true }.disabled(model.text.isEmpty)
            Button("Copy learning prompt") { UIPasteboard.general.string = model.prompt(); model.status = "Learning prompt copied." }
                .disabled(model.text.isEmpty)
            Divider()
            Toggle("Auto-search selected words", isOn: $model.readerAutoSearch)
                .accessibilityIdentifier("readerAutoSearch")
            Toggle("Show results in a card", isOn: $model.selectionPeek)
                .accessibilityIdentifier("selectionPeek")
            Toggle("Auto-save pasted passages", isOn: $model.autoSave)
                .accessibilityIdentifier("autoSavePassages")
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(accent)
                .frame(width: 40, height: 36)
                .sketchPill(style)
        }
        .accessibilityLabel("Reader options")
        .accessibilityIdentifier("readerOptions")
    }

    private var readerPeekVisible: Bool { model.peek.map { !$0.inDictionary } ?? false }
    private var quietMenu: Bool { quietSystemTextMenu && model.selectionPeek }
    private var translationKey: String { translationTarget + "|" + model.text }
    private var translationReady: Bool { showTranslation && translatedKey == translationKey }
    private var translationPending: Bool { showTranslation && !model.text.isEmpty && translatedKey != translationKey }

    private func toggleTranslation() {
        guard !model.text.isEmpty else { return }
        if #available(iOS 18.0, *) {
            withAnimation(.easeInOut(duration: 0.2)) { showTranslation.toggle() }
        } else {
            translation = true
        }
    }

    private func translationFinished(_ key: String, _ lines: [String]?) {
        guard key == translationKey else { return }
        if let lines {
            translatedLines = lines
            translatedKey = key
        } else {
            showTranslation = false
            model.status = "Translation isn't available right now. Check Settings → Apps → Translate for downloaded languages."
        }
    }

    @ViewBuilder private func translating<Content: View>(_ content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.modifier(PassageTranslationTask(segments: PassageSegments.split(model.text),
                                                    target: translationTarget,
                                                    requestKey: translationKey,
                                                    active: translationPending,
                                                    finished: translationFinished))
        } else {
            content
        }
    }

    private var translateButton: some View {
        Button { toggleTranslation() } label: {
            ZStack {
                if translationPending {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "character.bubble")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(showTranslation ? style.onAccent : accent)
                }
            }
            .frame(width: 40, height: 36)
            .sketchPill(style, selected: showTranslation)
        }
        .buttonStyle(.plain)
        .disabled(model.text.isEmpty)
        .opacity(model.text.isEmpty ? 0.45 : 1)
        .accessibilityLabel(showTranslation ? "Hide translation" : "Show translation")
        .accessibilityIdentifier("toggleTranslation")
    }

    private var readingView: some View {
        VStack(spacing: 0) {
            SelectableJapanese(text: model.text, ink: UIColor(ink), paper: .clear,
                               tint: UIColor(accent),
                               font: readerTypeface.uiFont(size: CGFloat(readerTextSize)),
                               lineSpacing: CGFloat(readerLineSpacing),
                               initialOffset: model.readerOffset,
                               bottomInset: readerPeekVisible ? 250 : 0,
                               translations: translationReady ? translatedLines : [],
                               quietMenu: quietMenu,
                               saveOffset: { model.readerOffset = $0 }) { word in
                guard !model.showingLookup, selectedTab == 0 else { return }
                model.select(word, inDictionary: false)
            }
            .clipShape(SketchShape(radius: 20))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if model.text.isEmpty {
                    VStack(spacing: 14) {
                        EnsoLogo(style: style, size: 88)
                        Text("Paste a passage to start reading")
                            .font(HandFont.title(19)).foregroundStyle(ink)
                        Text("Copy Japanese from another app, then tap Paste. Select any word — or any part of a phrase — to look it up.")
                            .font(HandFont.body(14.5)).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(style.secondary)
                    .padding(32)
                    .allowsHitTesting(false)
                }
            }
            .sketchCard(style, radius: 22, tape: .tape)
            .padding(.horizontal, 14)
            .padding(.top, 18)
            .padding(.bottom, 8)
            readingActions
        }
        .overlay(alignment: .bottom) {
            if let peek = model.peek, !peek.inDictionary {
                peekCard(peek)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: readerPeekVisible)
    }

    private func peekCard(_ peek: PeekState) -> some View {
        LookupPeekCard(peek: peek, style: style,
                       refine: { model.refinePeek($0) },
                       open: { hit in wantsSearchFocus = false; model.openPeekHit(hit) },
                       showAll: { wantsSearchFocus = false; model.showPeekResults() },
                       copy: {
                           UIPasteboard.general.string = peek.text
                           model.status = "Copied 「\(peek.text)」."
                       },
                       close: { model.closePeek() })
    }

    private var readingActions: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                PasteButton(payloadType: String.self, onPaste: pastePassage)
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .tint(accent)
                    .accessibilityIdentifier("pastePassage")
                if !model.readerSelection.isEmpty && model.peek == nil {
                    Button("Search selected text") { model.searchSelected(inDictionary: false) }
                        .buttonStyle(HandSoftButtonStyle(style: style, prominent: true))
                }
                Spacer(minLength: 0)
            }
            if !model.status.isEmpty {
                Text(model.status).font(HandFont.body(13)).foregroundStyle(style.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 10)
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
            .background(paperBackground)
            // Edge swipes start below the compact header so its buttons stay tappable.
            .overlay(alignment: .leading) { backSwipeEdge(fromLeft: true).padding(.top, model.showingEntry ? 0 : headerHeight) }
            .overlay(alignment: .trailing) { backSwipeEdge(fromLeft: false).padding(.top, model.showingEntry ? 0 : headerHeight) }
            .navigationBarTitleDisplayMode(.inline)
            // Results draw their own compact header; definitions keep the title bar.
            .toolbar(model.showingEntry ? .visible : .hidden, for: .navigationBar)
            .toolbar(searchChromeHidden ? .hidden : .visible, for: .tabBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if model.showingEntry {
                        Button { goBackInSearch() } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Back")
                    }
                }
                ToolbarItem(placement: .principal) {
                    if model.showingEntry { entryTitleButton }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if model.showingEntry {
                        Menu {
                            Button("Search results") { model.showResults(); applySearchKeyboardPreference() }
                            Button("Copy learning prompt") { UIPasteboard.general.string = model.prompt(inDictionary: true); model.status = "Learning prompt copied." }
                            Button("Back to Main Page") { selectedTab = 0 }
                        } label: { Image(systemName: "line.3.horizontal") }.accessibilityLabel("Dictionary navigation")
                    }
                }
            }
            .sheet(isPresented: $switchingDictionary) {
                NavigationStack {
                    resultGroups(model.entryMatches, switching: true)
                        .navigationTitle(model.entryTitle).navigationBarTitleDisplayMode(.inline)
                        .toolbar { Button("Done") { switchingDictionary = false } }
                        .background(paperBackground)
                }
                .presentationDetents([.medium, .large])
                .presentationBackground(paper)
            }
        }
        .toolbarBackground(paper, for: .tabBar, .navigationBar)
        .toolbarBackground(.visible, for: .tabBar, .navigationBar)
        .background(SearchTabObserver { activateSearchTab() })
        .tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(1)
    }

    private var entryTitleButton: some View {
        Button { switchingDictionary = true } label: {
            HStack(spacing: 8) {
                HandSeal(text: "辞", style: style, size: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.entryDictionary)
                        .font(.system(size: 10.5, weight: .semibold)).lineLimit(1).foregroundStyle(style.secondary)
                    HStack(spacing: 4) {
                        Text(model.entryTitle).font(HandFont.title(17)).lineLimit(1).foregroundStyle(style.ink)
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(accent)
                    }
                }
            }
            .padding(.leading, 6).padding(.trailing, 12).padding(.vertical, 3)
            .sketchPill(style)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("switchDictionary")
    }

    private var entryPeekVisible: Bool { model.peek?.inDictionary ?? false }

    private var entryView: some View {
        let visitID = model.entryID
        return ZStack(alignment: .bottom) {
            DictionaryPage(html: model.entryHTML, root: model.entryRoot ?? model.dictionaryRoot, code: model.entryCode,
                           paperRGB: style.surfaceRGB, accentRGB: style.accentRGB,
                           textSize: dictionaryTextSize, sansFont: dictionarySans,
                           initialOffset: model.entryOffsets[visitID] ?? .zero,
                           bottomInset: entryPeekVisible ? 300 : 0,
                           quietMenu: quietMenu,
                           saveOffset: { model.entryOffsets[visitID] = $0 },
                           followLink: { model.followEntryLink($0) }) { word in
                guard selectedTab == 1, model.showingEntry else { return }
                model.select(word, inDictionary: true)
            }
            .id(visitID.uuidString + style.identity + "-\(Int(dictionaryTextSize))-\(dictionarySans)")
            .clipShape(SketchShape(radius: 18))
            .padding(3)
            .sketchCard(style, radius: 20, tape: .marker, tapeTrailing: true)
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 8)
            if let peek = model.peek, peek.inDictionary {
                peekCard(peek)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if !model.dictionarySelection.isEmpty {
                Button("Search selected text") { model.searchSelected(inDictionary: true) }
                    .buttonStyle(HandSoftButtonStyle(style: style, prominent: true))
                    .padding(.bottom, 16)
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: entryPeekVisible)
        .overlay(alignment: .top) {
            if model.lookupBusy {
                ProgressView().controlSize(.small).padding(8)
                    .background(style.surface, in: Capsule()).padding(.top, 6)
            }
        }
    }

    /// Header and tab bar step aside while reading down a result list.
    private var searchChromeHidden: Bool {
        headerCollapsed && !model.showingEntry && !keyboardVisible && !model.hits.isEmpty
    }

    private func lookup(focusSearch: Bool) -> some View {
        ZStack(alignment: .top) {
            Group {
                if model.hits.isEmpty {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: headerHeight)
                        EmptyHint(symbol: model.word.isEmpty ? "character.book.closed" : "magnifyingglass",
                                  title: model.word.isEmpty ? "Look up any Japanese word" : "Nothing found yet",
                                  detail: model.word.isEmpty
                                    ? "Type above, or highlight a word while reading. Enabled dictionaries are searched in your chosen order."
                                    : "Exact matches appear first, then words that start with your text. Try the dictionary form.",
                                  style: style)
                            .padding(.top, 36)
                        Spacer(minLength: 0)
                    }
                } else {
                    resultGroups(model.hits, topInset: headerHeight)
                }
            }
            searchHeader(focusSearch: focusSearch)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: SearchHeaderHeightKey.self, value: proxy.size.height)
                })
                .offset(y: searchChromeHidden ? -(headerHeight + 8) : 0)
                .opacity(searchChromeHidden ? 0 : 1)
            if searchChromeHidden {
                compactSearchPill
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .clipped()
        .onPreferenceChange(SearchHeaderHeightKey.self) { height in
            if height > 0 && abs(height - headerHeight) > 0.5 { headerHeight = height }
        }
        .onChange(of: model.searchMode) { _, _ in model.typedSearch(model.word) }
        .onChange(of: model.word) { _, _ in revealSearchHeader() }
        .onChange(of: keyboardVisible) { _, visible in if visible { revealSearchHeader() } }
    }

    private func revealSearchHeader() {
        scrollTracker.anchor = 0
        guard headerCollapsed else { return }
        withAnimation(.snappy(duration: 0.28)) { headerCollapsed = false }
    }

    /// Scrolling down by a short distance hides the header; any upward scroll of the
    /// same distance (or reaching the top) brings it back.
    private func resultsScrolled(to minY: CGFloat) {
        let offset = -minY
        let tracker = scrollTracker
        if offset < 24 {
            tracker.anchor = max(offset, 0)
            if headerCollapsed { withAnimation(.snappy(duration: 0.28)) { headerCollapsed = false } }
            return
        }
        let delta = offset - tracker.anchor
        if !headerCollapsed {
            if delta > 28 {
                tracker.anchor = offset
                withAnimation(.snappy(duration: 0.28)) { headerCollapsed = true }
            } else if delta < 0 { tracker.anchor = offset }
        } else {
            if delta < -28 {
                tracker.anchor = offset
                withAnimation(.snappy(duration: 0.28)) { headerCollapsed = false }
            } else if delta > 0 { tracker.anchor = offset }
        }
    }

    private func searchHeader(focusSearch: Bool) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Button { goBackInSearch() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 34, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent)
                .background(KeyboardControlArea())
                .accessibilityLabel(model.canGoBack ? "Back" : "Back to Main Page")
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(accent)
                    JapaneseSearchField(text: $model.word, focusRequest: searchFocusRequest,
                                        active: focusSearch && selectedTab == 1 && !model.showingEntry,
                                        ink: UIColor(ink), accent: UIColor(accent),
                                        preferredLanguage: searchKeyboardLanguage,
                                        changed: { model.typedSearch($0, clearSelection: true) }) { model.search() }
                        .frame(height: 38)
                    if model.lookupBusy { ProgressView().controlSize(.small) }
                    if !model.word.isEmpty {
                        Button { model.search() } label: {
                            Image(systemName: "arrow.forward")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(style.onAccent)
                                .frame(width: 30, height: 30)
                                .background(accent, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Search dictionaries")
                        .background(KeyboardControlArea())
                    }
                }
                .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 3)
                .background(style.surface, in: SketchShape(radius: 16))
                .overlay(SketchShape(radius: 16).stroke(style.lineStrong, lineWidth: 1.5))
                .background(SketchShape(radius: 16).fill(style.shade).offset(x: 3, y: 4))
                Menu {
                    Button { dismissKeyboard(); showingHistory = true } label: {
                        Label("Search history", systemImage: "clock.arrow.circlepath")
                    }
                    Button {
                        UIPasteboard.general.string = model.prompt(inDictionary: model.selectionFromDictionary)
                        model.status = "Learning prompt copied."
                    } label: { Label("Copy learning prompt", systemImage: "doc.on.doc") }
                    Button { requestSearchFocus() } label: { Label("Show search keyboard", systemImage: "keyboard") }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(accent)
                        .frame(width: 36, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Search options")
                .accessibilityIdentifier("searchOptions")
                .background(KeyboardControlArea())
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    matchModeChip
                    Rectangle().fill(style.hairline).frame(width: 1, height: 18)
                    scopeChip("All", id: "")
                    ForEach(model.dictionaries.filter { !model.disabledDictionaries.contains($0.id) }) {
                        scopeChip(ReaderText.shortDictionaryName($0.name), id: $0.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 1)
                .padding(.bottom, 4)
            }
            .padding(.horizontal, -12)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .background(paper.opacity(0.94))
        .overlay(alignment: .bottom) { HandRule(style: style).offset(y: 4) }
    }

    /// While the header is away, a small pill keeps the query in view; tap to return.
    private var compactSearchPill: some View {
        Button { revealSearchHeader() } label: {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .bold)).foregroundStyle(accent)
                Text(model.word).font(.system(size: 13, weight: .semibold)).foregroundStyle(ink).lineLimit(1)
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .sketchPill(style)
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
        .accessibilityLabel("Show search bar")
        .accessibilityIdentifier("showSearchHeader")
    }

    private var matchModeChip: some View {
        Menu {
            Picker("Match", selection: $model.searchMode) {
                Text("Starts with").tag(DictionarySearchMode.prefix)
                Text("Exact word").tag(DictionarySearchMode.exact)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: model.searchMode == .prefix ? "text.line.first.and.arrowtriangle.forward" : "equal")
                    .font(.system(size: 11, weight: .bold))
                Text(model.searchMode == .prefix ? "Starts with" : "Exact word")
                    .font(.system(size: 13, weight: .semibold))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(accent)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(style.accentSoft, in: SketchShape(radius: 12))
            .overlay(SketchShape(radius: 12).stroke(accent.opacity(0.35), lineWidth: 1.2))
        }
        .background(KeyboardControlArea())
        .accessibilityLabel("Match")
    }

    private func scopeChip(_ name: String, id: String) -> some View {
        let selected = model.searchScope == id
        return Button { model.searchScope = id; model.typedSearch(model.word) } label: {
            Text(name)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .lineLimit(1)
                .foregroundStyle(selected ? style.onAccent : style.ink)
                .padding(.horizontal, 13).padding(.vertical, 7)
                .sketchPill(style, selected: selected)
        }
        .buttonStyle(.plain)
        .background(KeyboardControlArea())
        .accessibilityIdentifier("searchScope_" + id)
    }

    private func resultGroups(_ hits: [DictionaryHit], switching: Bool = false, topInset: CGFloat = 0) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(model.dictionaries) { dictionary in
                    let matches = hits.filter { $0.root == dictionary.root && $0.code == dictionary.code }
                    let groupID = (switching ? "switcher:" : "results:") + dictionary.id
                    let collapsed = collapsedResultGroups.contains(groupID)
                    if !matches.isEmpty {
                        resultGroupHeader(dictionary, count: matches.count, groupID: groupID, collapsed: collapsed)
                        if !collapsed {
                            ForEach(matches, id: \.identity) { hit in
                                Button {
                                    switchingDictionary = false
                                    wantsSearchFocus = false
                                    model.open(hit, replacingCurrent: switching)
                                } label: {
                                    resultRow(hit, switching: switching)
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 12)
                                .accessibilityIdentifier("dictionaryResult_" + hit.word)
                            }
                        }
                    }
                }
            }
            .padding(.top, topInset + 4)
            .padding(.bottom, 28)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: ResultsScrollOffsetKey.self,
                                       value: proxy.frame(in: .named(switching ? "switcherResults" : "searchResults")).minY - topInset - 4)
            })
        }
        .coordinateSpace(name: switching ? "switcherResults" : "searchResults")
        .onPreferenceChange(ResultsScrollOffsetKey.self) { minY in
            if !switching { resultsScrolled(to: minY) }
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private func resultGroupHeader(_ dictionary: InstalledDictionary, count: Int, groupID: String, collapsed: Bool) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.22)) {
                if collapsed { collapsedResultGroups.remove(groupID) }
                else { collapsedResultGroups.insert(groupID) }
            }
        } label: {
            HStack(spacing: 9) {
                Rectangle()
                    .fill(accent)
                    .frame(width: 8, height: 8)
                    .rotationEffect(.degrees(45))
                Text(dictionary.name)
                    .font(HandFont.title(14))
                    .foregroundStyle(ink.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(accent)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(style.accentSoft, in: Capsule())
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(style.faint)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
        .background(KeyboardControlArea())
        .accessibilityIdentifier("dictionaryGroup_" + groupID)
        .accessibilityLabel(dictionary.name + ", \(count) results")
        .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
        .accessibilityHint(collapsed ? "Expand dictionary results" : "Collapse dictionary results")
    }

    private func resultRow(_ hit: DictionaryHit, switching: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(hit.word).font(HandFont.title(20)).foregroundStyle(ink)
                if !hit.preview.isEmpty {
                    Text(hit.preview).font(.subheadline).foregroundStyle(style.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if switching && hit.identity == model.entryHitIdentity {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 17, weight: .semibold)).foregroundStyle(accent)
            } else {
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(style.faint)
            }
        }
        .padding(.vertical, 10).padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sketchCard(style, radius: 15, shadow: CGSize(width: 2, height: 3))
        .padding(.bottom, 2)
    }

    private func goBackInSearch() {
        if model.canGoBack {
            model.backToPreviousEntry()
            if !model.showingEntry { applySearchKeyboardPreference() }
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
    private func applySearchKeyboardPreference() {
        if automaticallyShowSearchKeyboard { requestSearchFocus() }
        else { dismissKeyboard() }
    }
    private func activateSearchTab() {
        model.showResults()
        selectedTab = 1
        requestSearchFocus()
    }
    private var historySheet: some View {
        NavigationStack {
            List {
                if model.searchHistory.isEmpty {
                    Text("No searches yet. Submitted searches and opened results appear here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.searchHistory, id: \.self) { query in
                    Button(query) {
                        showingHistory = false
                        wantsSearchFocus = false
                        model.showResults()
                        model.word = query
                        model.searchScope = ""
                        model.search(dismissKeyboard: true)
                    }
                }.onDelete { model.deleteSearchHistory(at: $0) }
            }
            .navigationTitle("Search history")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { showingHistory = false } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear", role: .destructive) { clearHistoryConfirmation = true }
                        .disabled(model.searchHistory.isEmpty)
                }
            }
            .confirmationDialog("Clear search history?", isPresented: $clearHistoryConfirmation, titleVisibility: .visible) {
                Button("Clear history", role: .destructive) { model.clearSearchHistory() }
            }
        }
    }
    private func requestSearchFocus() { wantsSearchFocus = true; searchFocusRequest += 1 }

    // MARK: - Library

    private var libraryTab: some View {
        NavigationStack {
            List {
                Group {
                    appearanceLink
                    Section("Search keyboard") {
                        Toggle("Show keyboard when returning from definitions", isOn: $automaticallyShowSearchKeyboard)
                            .accessibilityIdentifier("automaticallyShowSearchKeyboard")
                        Text("Tapping the Search tab always opens the keyboard and selects the previous search. Tap blank space to hide the keyboard.")
                            .font(.caption).foregroundStyle(style.secondary)
                    }
                    Section("Keyboard language") {
                        Picker("Search keyboard", selection: $searchKeyboardLanguage) {
                            Text("Japanese").tag("ja")
                            Text("English").tag("en")
                            Text("System keyboard").tag("system")
                        }
                        Text("Enable your preferred language in iPhone Settings → General → Keyboard → Keyboards. System keyboard lets you choose any installed language.").font(.caption)
                    }
                    savedSection
                    dictionariesSection
                    Section("Dictionary search") {
                        Toggle("Show selection results in a card", isOn: $model.selectionPeek).accessibilityIdentifier("librarySelectionPeek")
                        Stepper(value: $selectionLimit, in: SelectionLimit.range, step: 5) {
                            HStack {
                                Text("Look up selections up to")
                                Spacer()
                                Text("\(selectionLimit) characters").foregroundStyle(style.secondary).monospacedDigit()
                            }
                        }
                        .accessibilityIdentifier("selectionLookupLimit")
                        Text("Selecting this many characters or fewer opens the dictionary card (and hides the iPhone bar below). Longer selections get the normal iPhone menu, e.g. to copy a paragraph. New dictionary pages use the new limit.").font(.caption).foregroundStyle(style.secondary)
                        Toggle("Hide the iPhone Copy / Look Up bar for short selections", isOn: $quietSystemTextMenu)
                            .disabled(!model.selectionPeek)
                            .accessibilityIdentifier("quietSystemTextMenu")
                        Text("On: selecting text opens a dictionary card on the same page. Drag the selection handles, or drag across the characters on the card, to look up just part of a phrase. Off: selecting jumps straight to the results page.").font(.caption).foregroundStyle(style.secondary)
                        Toggle("Auto-search inside all dictionaries", isOn: $model.dictionaryAutoSearch).accessibilityIdentifier("dictionaryAutoSearch")
                        Text("Independent of Reader auto-search. A matching selection opens results across enabled dictionaries. When off, use Search selected text.").font(.caption).foregroundStyle(style.secondary)
                        Text("Search prefers an enabled Japanese keyboard. Enable Japanese – Romaji in iPhone Settings → General → Keyboard → Keyboards. iOS controls the exact Japanese layout.").font(.caption).foregroundStyle(style.secondary)
                    }
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
            .background(paperBackground)
            .navigationTitle("書庫 · Library")
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
                    Button { model.text = item.text; model.readerOffset = .zero; selectedTab = 0 } label: {
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

    // MARK: - Appearance

    private var appearanceLink: some View {
        Section {
            NavigationLink {
                appearancePage
            } label: {
                HStack(spacing: 14) {
                    ThemeSwatch(theme: activeTheme, style: style, selected: false,
                                accentOverride: activeTheme.family == .custom ? accentRGB : nil,
                                backgroundOverride: activeTheme.family == .custom && customPaper ? paperRGB : nil,
                                compact: true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Appearance").font(.headline).foregroundStyle(ink)
                        Text("\(activeTheme.name) · \(readerTypeface.title)")
                            .font(.caption).foregroundStyle(style.secondary).lineLimit(1)
                    }
                }
                .padding(.vertical, 4)
            }
            .accessibilityIdentifier("openAppearance")
        }
    }

    private let themeColumns = [GridItem(.adaptive(minimum: 92, maximum: 120), spacing: 12)]

    private func themeGrid(_ themes: [ReaderTheme]) -> some View {
        LazyVGrid(columns: themeColumns, alignment: .leading, spacing: 14) {
            ForEach(themes) { theme in
                Button { withAnimation(.easeInOut(duration: 0.25)) { themeID = theme.id } } label: {
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
        .padding(.vertical, 6)
    }

    private var appearancePage: some View {
        List {
            Group {
                Section {
                    appearancePreview
                        .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                }
                Section {
                    themeGrid([ReaderTheme.system, ReaderTheme.custom])
                    if activeTheme.family == .custom {
                        ColorPicker("Accent color", selection: colorBinding($accentRGB), supportsOpacity: false).accessibilityIdentifier("accentColor")
                        Toggle("Custom app background", isOn: $customPaper).accessibilityIdentifier("customPaper")
                        if customPaper {
                            ColorPicker("App background", selection: colorBinding($paperRGB), supportsOpacity: false)
                        }
                    }
                } header: { Text("Automatic & custom") }
                Section {
                    themeGrid(ReaderTheme.desk)
                    Toggle("Paper grain & doodles", isOn: $handDrawnPaper).accessibilityIdentifier("handDrawnPaper")
                } header: { Text("Hand-drawn · 手描き (same as desktop)") }
                Section { themeGrid(ReaderTheme.light) } header: { Text("Light · 昼") }
                Section { themeGrid(ReaderTheme.dark) } header: { Text("Dark · 夜") }
                Section {
                    Picker("Typeface", selection: $readerTypefaceRaw) {
                        ForEach(ReaderTypeface.allCases) { face in
                            Text(face.title).tag(face.rawValue)
                        }
                    }
                    .accessibilityIdentifier("readerTypeface")
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Text size")
                            Spacer()
                            Text("\(Int(readerTextSize)) pt").foregroundStyle(style.secondary).monospacedDigit()
                        }
                        Slider(value: $readerTextSize, in: 16...38, step: 1)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Line spacing")
                            Spacer()
                            Text(String(format: "%.2f×", readerLineSpacing)).foregroundStyle(style.secondary).monospacedDigit()
                        }
                        Slider(value: $readerLineSpacing, in: 1.05...2.0, step: 0.05)
                    }
                } header: { Text("Reading text · 本文") }
                Section {
                    Picker("Dictionary typeface", selection: $dictionarySans) {
                        Text("Book serif · 明朝").tag(false)
                        Text("Sans · ゴシック").tag(true)
                    }
                    .pickerStyle(.segmented)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Definition size")
                            Spacer()
                            Text("\(Int(dictionaryTextSize)) pt").foregroundStyle(style.secondary).monospacedDigit()
                        }
                        Slider(value: $dictionaryTextSize, in: 14...28, step: 1)
                    }
                    Text("Dictionary pages keep each publisher's layout and use your theme: large headwords, muted labels, and examples as an indented phrase with the translation underneath.")
                        .font(.caption).foregroundStyle(style.secondary)
                } header: { Text("Dictionary pages · 辞書") }
                Section {
                    Button("Reset appearance", role: .destructive) {
                        themeID = "hand-washi"; accentRGB = 0x1F7A73; paperRGB = 0xFFFFFF; customPaper = false
                        readerTypefaceRaw = ReaderTypeface.kyokasho.rawValue; readerTextSize = 23; readerLineSpacing = 1.35
                        handDrawnPaper = true
                        dictionaryTextSize = 19; dictionarySans = false
                    }
                }
            }
            .listRowBackground(style.surface)
        }
        .scrollContentBackground(.hidden)
        .background(paperBackground)
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .tint(accent)
        .foregroundStyle(ink)
        .preferredColorScheme(style.colorScheme)
    }

    private var appearancePreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(activeTheme.name).font(.system(size: 12, weight: .bold)).tracking(0.8)
                    .foregroundStyle(accent)
                Spacer(minLength: 0)
                Circle().fill(accent).frame(width: 10, height: 10)
            }
            Text("吾輩は猫である。名前はまだ無い。")
                .font(readerTypeface.font(size: CGFloat(min(readerTextSize, 30))))
                .lineSpacing(CGFloat(min(readerTextSize, 30)) * CGFloat(readerLineSpacing - 1))
                .foregroundStyle(ink)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("ぼける").font(.system(size: 20, weight: .bold, design: dictionarySans ? .default : .serif))
                    Text("【惚ける】").font(.system(size: 16, design: dictionarySans ? .default : .serif))
                }
                .foregroundStyle(ink)
                Text("ぼけた頭で考える")
                    .font(.system(size: 15, design: dictionarySans ? .default : .serif))
                    .foregroundStyle(Palette.color(style.isDark ? 0xA9C8F5 : 0x23408E))
                    .padding(.leading, 14)
                Text("think while befuddled")
                    .font(.system(size: 15, design: dictionarySans ? .default : .serif))
                    .foregroundStyle(style.secondary)
                    .padding(.leading, 14)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(style.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(paper, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(style.hairline, lineWidth: 1)
        )
    }
}

struct SelectableJapanese: UIViewRepresentable {
    let text: String
    var ink: UIColor = .label
    var paper: UIColor = .systemBackground
    var tint: UIColor? = nil
    var font: UIFont = .systemFont(ofSize: 23)
    var lineSpacing: CGFloat = 1.3
    var initialOffset: CGPoint = .zero
    /// Room kept free under the text while the dictionary card is open.
    var bottomInset: CGFloat = 0
    /// One translation per `PassageSegments.split(text)` piece; empty hides them.
    var translations: [String] = []
    /// Hide the iPhone Copy / Look Up menu for short selections (the card has those).
    var quietMenu = false
    var saveOffset: ((CGPoint) -> Void)? = nil
    let selected: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(selected) }
    static let translationKey = NSAttributedString.Key("JapaneseReaderTranslation")
    // Reading typography: comfortable line height and page margins for Japanese.
    static func styled(_ text: String, ink: UIColor, font: UIFont = .systemFont(ofSize: 23), lineSpacing: CGFloat = 1.3) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = lineSpacing
        paragraph.paragraphSpacing = font.pointSize * 0.5
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: ink,
            .paragraphStyle: paragraph
        ])
    }
    /// The passage with each sentence followed by its translation in small print.
    static func interlinear(_ text: String, translations: [String], ink: UIColor, font: UIFont, lineSpacing: CGFloat) -> NSAttributedString {
        let pieces = PassageSegments.split(text)
        guard !translations.isEmpty, translations.count == pieces.count else {
            return styled(text, ink: ink, font: font, lineSpacing: lineSpacing)
        }
        let original = NSMutableParagraphStyle()
        original.lineHeightMultiple = lineSpacing
        original.paragraphSpacing = font.pointSize * 0.12
        let translated = NSMutableParagraphStyle()
        translated.lineHeightMultiple = 1.15
        translated.paragraphSpacing = font.pointSize * 0.75
        let small = UIFont.systemFont(ofSize: max(13, font.pointSize * 0.62))
        let result = NSMutableAttributedString()
        for (index, piece) in pieces.enumerated() {
            let body = piece.hasSuffix("\n") ? String(piece.dropLast()) : piece
            let translation = translations[index].trimmingCharacters(in: .whitespacesAndNewlines)
            let last = index == pieces.count - 1
            if translation.isEmpty {
                result.append(NSAttributedString(string: piece, attributes: [.font: font, .foregroundColor: ink, .paragraphStyle: original]))
                continue
            }
            result.append(NSAttributedString(string: body + "\n", attributes: [.font: font, .foregroundColor: ink, .paragraphStyle: original]))
            result.append(NSAttributedString(string: translation + (last ? "" : "\n"), attributes: [
                .font: small, .foregroundColor: ink.withAlphaComponent(0.58), .paragraphStyle: translated,
                translationKey: true
            ]))
        }
        return result
    }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(); view.isEditable = false; view.isSelectable = true
        view.accessibilityIdentifier = "selectablePassage"
        view.font = .systemFont(ofSize: 23); view.backgroundColor = .clear; view.delegate = context.coordinator
        view.textContainerInset = UIEdgeInsets(top: 24, left: 20, bottom: 40, right: 20)
        view.alwaysBounceVertical = true
        if #available(iOS 18.0, *) { view.writingToolsBehavior = UIWritingToolsBehavior.none }
        SelectionBridge.shared.readerView = view
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.selected = selected
        coordinator.saveOffset = saveOffset
        coordinator.quietMenu = quietMenu
        // Rebuilding the attributed text clears the selection, so only do it when
        // the passage, its translations or the theme's ink actually changed.
        let textChanged = coordinator.appliedText != text
        let content = translations.joined(separator: "\u{1}")
        let typography = "\(font.fontName)-\(font.pointSize)-\(lineSpacing)"
        if textChanged || coordinator.appliedTranslations != content
            || coordinator.appliedInk != ink || coordinator.appliedTypography != typography {
            view.attributedText = Self.interlinear(text, translations: translations, ink: ink, font: font, lineSpacing: lineSpacing)
            coordinator.appliedText = text
            coordinator.appliedTranslations = content
            coordinator.appliedInk = ink
            coordinator.appliedTypography = typography
        }
        if textChanged { DispatchQueue.main.async { view.setContentOffset(initialOffset, animated: false) } }
        // The attributed text above already carries the ink color; assigning
        // textColor here would re-apply attributes and drop a live selection.
        if view.backgroundColor != paper { view.backgroundColor = paper }
        if let tint, view.tintColor != tint { view.tintColor = tint }
        if view.contentInset.bottom != bottomInset {
            view.contentInset.bottom = bottomInset
            view.verticalScrollIndicatorInsets.bottom = bottomInset
            // Keep the selected words visible above the dictionary card.
            if bottomInset > 0, let range = view.selectedTextRange, !range.isEmpty {
                let caret = view.caretRect(for: range.end)
                let visibleBottom = view.contentOffset.y + view.bounds.height - bottomInset
                if caret.maxY > visibleBottom - 8 {
                    let target = CGPoint(x: view.contentOffset.x, y: view.contentOffset.y + caret.maxY - visibleBottom + 28)
                    DispatchQueue.main.async { view.setContentOffset(target, animated: true) }
                }
            }
        }
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var selected: (String) -> Void
        var saveOffset: ((CGPoint) -> Void)?
        var appliedInk: UIColor?
        var appliedTypography = ""
        var appliedText: String?
        var appliedTranslations = ""
        var quietMenu = false
        /// Short selections go to the dictionary card, so the iPhone's own
        /// Copy / Look Up bar would only cover it. Long selections keep it.
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard quietMenu, range.length > 0,
                  let text = textView.text, range.location + range.length <= (text as NSString).length,
                  (text as NSString).substring(with: range).count <= SelectionLimit.current else { return nil }
            return UIMenu(children: [])
        }
        func scrollViewDidScroll(_ scrollView: UIScrollView) { saveOffset?(scrollView.contentOffset) }
        var pending: DispatchWorkItem?
        init(_ selected: @escaping (String) -> Void) { self.selected = selected }
        func textViewDidChangeSelection(_ textView: UITextView) {
            pending?.cancel()
            guard let range = textView.selectedTextRange, let word = textView.text(in: range), !word.isEmpty, word.count <= SelectionLimit.current else {
                // UIKit can clear selection inside updateUIView; publish after that update.
                let action = DispatchWorkItem { [weak self] in self?.selected("") }
                pending = action
                DispatchQueue.main.async(execute: action)
                return
            }
            let selectedRange = textView.selectedRange
            // Translation lines are for reading, not for dictionary lookups.
            if selectedRange.location < textView.attributedText.length,
               textView.attributedText.attribute(SelectableJapanese.translationKey, at: selectedRange.location, effectiveRange: nil) != nil {
                let action = DispatchWorkItem { [weak self] in self?.selected("") }
                pending = action
                DispatchQueue.main.async(execute: action)
                return
            }
            let context = Self.context(in: textView.text ?? "", range: selectedRange, word: word)
            let action = DispatchWorkItem { [weak textView, weak self] in
                guard let textView, textView.selectedRange == selectedRange else { return }
                SelectionBridge.shared.readerContext = context
                self?.selected(word)
            }
            pending = action; DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: action)
        }
        /// Up to 12 characters on each side of the selection, within the same line.
        static func context(in text: String, range: NSRange, word: String) -> SelectionContext {
            let passage = text as NSString
            guard range.location != NSNotFound, range.location + range.length <= passage.length else {
                return SelectionContext(text: word, before: "", after: "", location: -1)
            }
            let end = range.location + range.length
            var start = max(0, range.location - 12)
            if start > 0 { start = passage.rangeOfComposedCharacterSequence(at: start).location }
            var stop = min(passage.length, end + 12)
            if stop > end && stop < passage.length {
                let composed = passage.rangeOfComposedCharacterSequence(at: stop - 1)
                stop = composed.location + composed.length
            }
            var before = passage.substring(with: NSRange(location: start, length: range.location - start))
            var after = passage.substring(with: NSRange(location: end, length: max(0, stop - end)))
            if let cut = before.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards) {
                before = String(before[cut.upperBound...])
            }
            if let cut = after.rangeOfCharacter(from: .whitespacesAndNewlines) {
                after = String(after[..<cut.lowerBound])
            }
            return SelectionContext(text: word, before: before, after: after, location: range.location)
        }
    }
}
