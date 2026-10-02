import SwiftUI
import PhotosUI
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
    var id = UUID()
    let hit: DictionaryHit
    /// Empty for a page restored from a previous launch until it is shown again.
    var html: String
    let query: String
    let matches: [DictionaryHit]
    /// Filled in after the entry is on screen (it searches every dictionary).
    var alternatives: [DictionaryHit]
}

/// Cancels a background scan from the main thread.
final class CancelFlag {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

struct LookupSnapshot {
    let visit: EntryVisit?
    let visits: [EntryVisit]
    let query: String
    let hits: [DictionaryHit]
    let showingLookup: Bool
    /// On a results page: the result that was opened from it, scrolled back into view.
    var anchor: DictionaryHit? = nil
    /// How the page looked when it was left, for the page-turn swipe back (nil while that is off).
    var picture: PagePicture? = nil
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
    /// When Back returns to a results list, the result that was opened from it.
    var resultsAnchor: DictionaryHit?
    /// Set when a results list is about to be shown again (Back, or at launch).
    var revealResultsAnchor = false
    /// The tab on screen (0 Read, 1 Search, 2 Library, 3 文法), kept up to date by the view.
    var currentTab = 1
    /// True while the Search tab is on screen. Lookups started anywhere else (Read,
    /// 文法) begin a new Search stack instead of piling onto the one kept there.
    var onSearchTab: Bool {
        get { currentTab == 1 }
        set { currentTab = newValue ? 1 : 0 }
    }
    /// Where Back goes once the Search stack is used up: the page the lookup came
    /// from (the 文法 lesson or the Read passage where the text was selected).
    var returnTab: Int?
    private func snapshot() -> LookupSnapshot {
        let visit = showingEntry ? visits.last : nil
        return LookupSnapshot(visit: visit, visits: visits, query: visit?.query ?? word, hits: visit?.matches ?? hits,
                              showingLookup: showingLookup, anchor: visit == nil ? resultsAnchor : nil)
    }
    private func startFreshLookup() {
        lookupHistory = []; visits = []; entryOffsets = [:]; resultsAnchor = nil
        if currentTab != 1 { returnTab = currentTab }
    }
    /// A lookup from this selection belongs to the page on the Search tab.
    private func continuesSearch(inDictionary: Bool) -> Bool { inDictionary && onSearchTab }
    /// The picture of the page Back leads to inside Search.
    var backPicture: PagePicture? { lookupHistory.last?.picture }
    private func remember(_ page: LookupSnapshot) {
        // Called just before the next page is shown, so the screen still shows this one.
        var page = page
        if currentTab == 1 { page.picture = PageTurn.shared.picture() }
        lookupHistory.append(page)
        if lookupHistory.count > 30 { lookupHistory.removeFirst() }
    }
    /// Every definition page still reachable: the current stack and each Back step.
    private var reachableVisits: [EntryVisit] {
        var seen = Set<UUID>(), result: [EntryVisit] = []
        for visit in lookupHistory.flatMap({ $0.visits + [$0.visit].compactMap { $0 } }) + visits where seen.insert(visit.id).inserted {
            result.append(visit)
        }
        return result
    }
    private func pruneOffsets() {
        let reachable = Set(reachableVisits.map(\.id))
        entryOffsets = entryOffsets.filter { reachable.contains($0.key) }
    }
    var entryOffsets: [UUID: CGPoint] = [:]
    var readerOffset: CGPoint = .zero
    private var liveSearch: DispatchWorkItem?
    func typedSearch(_ query: String, clearSelection: Bool = false) {
        cancelPendingSearch()
        resultsAnchor = nil
        if clearSelection { readerSelection = ""; dictionarySelection = "" }
        word = query
        hits = []
        status = ""
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let pending = DispatchWorkItem { [weak self] in self?.search(dismissKeyboard: false) }
        liveSearch = pending
        // Full text reads every dictionary: wait until typing pauses.
        DispatchQueue.main.asyncAfter(deadline: .now() + (searchMode == .fullText ? 0.6 : 0.18), execute: pending)
    }
    func followEntryLink(_ query: String) {
        word = query
        search(dismissKeyboard: true, navigate: true, openBestMatch: true)
    }
    private func display(_ visit: EntryVisit) {
        entryHTML = visit.html; entryRoot = visit.hit.root; entryCode = visit.hit.code
        entryTitle = visit.hit.word; entryDictionary = visit.hit.dictionary; entryHitIdentity = visit.hit.identity
        entryID = visit.id; entryMatches = visit.alternatives
        entryHighlight = visit.hit.match
        word = visit.query; hits = visit.matches; dictionarySelection = ""
        closePeek()
        showingEntry = true; showingLookup = true; status = ""
        lookupNavigation = UUID()
        if visit.html.isEmpty { loadPage(of: visit) }
    }
    /// Re-reads a definition that was restored from a previous launch.
    private func loadPage(of visit: EntryVisit) {
        let hit = visit.hit, visitID = visit.id, query = visit.query
        queue.async {
            let result = Result { () -> String in
                let store = try DictionaryStore.shared(root: hit.root)
                return DictionaryPage.make(body: try store.entry(hit), css: try store.stylesheet(code: hit.code), code: hit.code)
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let html):
                    for index in self.visits.indices where self.visits[index].id == visitID { self.visits[index].html = html }
                    guard self.entryID == visitID, self.showingEntry else { return }
                    self.entryHTML = html
                    let enabled = self.dictionaries.filter { !self.disabledDictionaries.contains($0.id) }
                    if !enabled.isEmpty { self.loadAlternatives(for: visitID, hit: hit, query: query, enabled: enabled) }
                case .failure:
                    guard self.entryID == visitID, self.showingEntry else { return }
                    self.showingEntry = false
                    self.status = "「\(hit.word)」 couldn't be reopened. Its dictionary may have been moved or removed."
                }
            }
        }
    }
    func backToPreviousEntry() {
        cancelPendingSearch()
        guard let previous = lookupHistory.popLast() else { showingEntry = false; showingLookup = false; return }
        visits = previous.visits
        if let visit = previous.visit { display(visit) }
        else {
            word = previous.query; hits = previous.hits; dictionarySelection = ""
            resultsAnchor = previous.anchor; revealResultsAnchor = previous.anchor != nil
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
        let reopen = SelectionBridge.shared.reopenText
        SelectionBridge.shared.reopenText = nil
        if let reopen, !reopen.isEmpty, reopen == text {
            reopenPeek(text, inDictionary: inDictionary)
            return
        }
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
        search(dismissKeyboard: false, navigate: true, onlyIfMatched: true, fresh: !continuesSearch(inDictionary: inDictionary))
    }
    /// A tap on a selection that has no card (the card was closed, or the page was
    /// left and reopened) brings the card back: with the iPhone bar hidden it is
    /// the only place to Copy or Translate the selection.
    func reopenPeek(_ text: String, inDictionary: Bool) {
        guard selectionPeek, !text.isEmpty else { return }
        if let current = peek, current.inDictionary == inDictionary, current.text == text { return }
        selectionFromDictionary = inDictionary
        if inDictionary { dictionarySelection = text } else { readerSelection = text }
        cancelPendingSearch()
        peekLookup(text, inDictionary: inDictionary)
    }
    func searchSelected(inDictionary: Bool) {
        let selected = inDictionary ? dictionarySelection : readerSelection
        guard !selected.isEmpty else { return }
        if selectionPeek {
            peekLookup(selected, inDictionary: inDictionary)
            return
        }
        word = selected
        search(dismissKeyboard: true, navigate: true, fresh: !continuesSearch(inDictionary: inDictionary))
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
        // A sentence or paragraph is not looked up: the card shows the whole
        // selection with Copy, Translate and Share instead.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).count > SelectionLimit.current {
            next.long = true
            next.busy = false
            peek = next
            return
        }
        // Keep the previous results on screen while a refined lookup runs.
        if let current = peek, current.inDictionary == inDictionary, !current.long {
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
        open(hit, fresh: !continuesSearch(inDictionary: current.inDictionary))
    }
    func showPeekResults() {
        guard let current = peek else { return }
        let fresh = !continuesSearch(inDictionary: current.inDictionary)
        let previousPage = showingEntry && !fresh ? snapshot() : nil
        word = current.matched.isEmpty ? current.text.trimmingCharacters(in: .whitespacesAndNewlines) : current.matched
        closePeek()
        guard !current.hits.isEmpty else {
            search(dismissKeyboard: true, navigate: true, fresh: fresh)
            return
        }
        cancelPendingSearch()
        if fresh { startFreshLookup() }
        if let previousPage { remember(previousPage) }
        resultsAnchor = nil
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
    /// A word sent from another app (share sheet shortcut or a jpreader:// link).
    /// It is looked up like a selection on the card, dictionary form first
    /// (食べました → 食べる), and the results open on the Search tab. Back returns
    /// to the tab that was open.
    private var pendingExternalLookup: String?
    /// The dictionary list has been read at least once since launch.
    private(set) var dictionariesLoaded = false
    func lookUpExternal(_ text: String) {
        let query = ExternalLookup.clean(text)
        guard !query.isEmpty else { return }
        let enabled = dictionaries.filter { !disabledDictionaries.contains($0.id) }
        guard !enabled.isEmpty else {
            if dictionariesLoaded {
                status = dictionaries.isEmpty
                    ? "Add your dictionaries in Library to look up 「\(query)」."
                    : "Turn on a dictionary in Library to look up 「\(query)」."
            } else {
                // Launched by the lookup: the dictionaries are still being opened.
                pendingExternalLookup = query
            }
            return
        }
        pendingExternalLookup = nil
        closePeek()
        cancelPendingSearch()
        let generation = searchGeneration
        lookupBusy = true
        queue.async {
            let found = PeekSearch.bestMatch(for: query, in: enabled)
            DispatchQueue.main.async {
                guard generation == self.searchGeneration else { return }
                self.lookupBusy = false
                self.startFreshLookup()
                self.word = found.query.isEmpty ? query : found.query
                self.hits = found.hits
                self.searchScope = ""
                self.status = found.hits.isEmpty ? "No match for 「\(query)」. Try the dictionary form of the word." : ""
                self.recordSearch(self.word)
                self.showingEntry = false; self.showingLookup = true; self.lookupNavigation = UUID()
            }
        }
    }

    /// Leaving the Search tab keeps its page, Back history and scroll positions.
    func leaveLookup() {
        closePeek()
        cancelPendingSearch()
    }
    private var searchGeneration = 0 {
        didSet { fullTextCancel?.cancel(); if !fullTextProgress.isEmpty { fullTextProgress = "" } }
    }
    private var libraryWritable = true
    let queue = DispatchQueue(label: "JapaneseReader.dictionary", qos: .userInitiated)
    /// Full-text scans read whole dictionaries; they get their own queue so card
    /// lookups and opening entries never wait behind them.
    private let fullTextQueue = DispatchQueue(label: "JapaneseReader.fullText", qos: .userInitiated)
    private var fullTextCancel: CancelFlag?
    /// "Searching 大辞泉… 3/11" while a full-text search runs.
    @Published private(set) var fullTextProgress = ""
    /// The searched text to mark on the open entry (full-text results only).
    @Published private(set) var entryHighlight = ""
    static let fullTextLimit = 300
    static let fullTextPerDictionary = 80
    let documents: URL
    private let preferences: UserDefaults
    var dictionaryRoot: URL { documents.appendingPathComponent("dictionaries", isDirectory: true) }
    var libraryURL: URL { documents.appendingPathComponent("reading-library.json") }
    /// Where the reading position is kept between launches; nil keeps nothing.
    let sessionURL: URL?
    /// The tab that was open when the app was last put away.
    private(set) var restoredTab = 0
    /// The last saved state, for the 文法 tab to restore its own part from.
    private(set) var restoredSession: SessionState?
    init(documents: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0], preferences: UserDefaults = .standard, session: URL? = nil) {
        self.documents = documents
        self.preferences = preferences
        self.sessionURL = session
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
        if let session, let state = SessionState.load(from: session) { restore(state) }
        reload()
    }

    // MARK: Where you left off

    /// Dictionary folders as the dictionary list names them (see `reload`).
    private var dictionaryFolders: [URL] {
        let extras = documents.appendingPathComponent("Dictionary Packs", isDirectory: true)
        return [dictionaryRoot] + ((try? FileManager.default.contentsOfDirectory(at: extras, includingPropertiesForKeys: nil)) ?? [])
    }
    /// Reading and Search state; the 文法 tab adds its own part (`GrammarStore.fill`).
    func sessionState(tab: Int) -> SessionState {
        let docs = documents
        func stored(_ hit: DictionaryHit) -> SessionHit { SessionHit(hit, documents: docs) }
        var state = SessionState()
        state.tab = tab
        state.text = text
        state.readerOffset = readerOffset
        state.pages = reachableVisits.map { visit in
            SessionPage(id: visit.id, hit: stored(visit.hit), query: visit.query,
                        matches: visit.matches.map(stored), offset: entryOffsets[visit.id])
        }
        state.stack = visits.map(\.id)
        state.showingEntry = showingEntry && !visits.isEmpty
        state.showingLookup = showingLookup
        state.returnTab = returnTab
        state.word = word
        state.hits = hits.map(stored)
        state.anchor = resultsAnchor.map(stored)
        state.history = lookupHistory.map { step in
            SessionStep(stack: step.visits.map(\.id), page: step.visit?.id, query: step.query,
                        hits: step.hits.map(stored), showingLookup: step.showingLookup, anchor: step.anchor.map(stored))
        }
        return state
    }
    func restore(_ state: SessionState) {
        restoredSession = state
        let roots = SessionRoots(documents: documents, candidates: dictionaryFolders)
        var pages: [UUID: EntryVisit] = [:]
        for page in state.pages {
            let hit = page.hit.hit(roots)
            pages[page.id] = EntryVisit(id: page.id, hit: hit, html: "", query: page.query,
                                        matches: page.matches.map { $0.hit(roots) }, alternatives: [hit])
            if let offset = page.offset { entryOffsets[page.id] = offset }
        }
        text = state.text
        readerOffset = state.readerOffset
        restoredTab = (0...3).contains(state.tab) ? state.tab : 0
        lookupHistory = state.history.map { step in
            LookupSnapshot(visit: step.page.flatMap { pages[$0] }, visits: step.stack.compactMap { pages[$0] },
                           query: step.query, hits: step.hits.map { $0.hit(roots) },
                           showingLookup: step.showingLookup, anchor: step.anchor.map { $0.hit(roots) })
        }
        visits = state.stack.compactMap { pages[$0] }
        word = state.word
        hits = state.hits.map { $0.hit(roots) }
        resultsAnchor = state.anchor.map { $0.hit(roots) }
        revealResultsAnchor = resultsAnchor != nil
        showingLookup = state.showingLookup
        returnTab = state.returnTab
        if state.showingEntry, let visit = visits.last {
            // Set directly: no navigation event at launch.
            entryRoot = visit.hit.root; entryCode = visit.hit.code
            entryTitle = visit.hit.word; entryDictionary = visit.hit.dictionary; entryHitIdentity = visit.hit.identity
            entryID = visit.id; entryMatches = visit.alternatives; entryHighlight = visit.hit.match; entryHTML = ""
            showingEntry = true
            loadPage(of: visit)
        }
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
                self.dictionariesLoaded = true
                if let waiting = self.pendingExternalLookup {
                    self.pendingExternalLookup = nil
                    if items.isEmpty { self.status = "Add your dictionaries in Library to look up 「\(waiting)」." }
                    else { self.lookUpExternal(waiting) }
                }
                // A page reopened at launch fills in its dictionary switcher now.
                if self.showingEntry, let visit = self.visits.last, visit.id == self.entryID, self.entryMatches.count <= 1 {
                    let enabled = self.dictionaries.filter { !self.disabledDictionaries.contains($0.id) }
                    self.loadAlternatives(for: visit.id, hit: visit.hit, query: visit.query, enabled: enabled)
                }
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
    func search(dismissKeyboard: Bool = true, navigate: Bool = false, onlyIfMatched: Bool = false, openBestMatch: Bool = false, fresh: Bool = false) {
        if dismissKeyboard { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
        liveSearch?.cancel(); liveSearch = nil
        searchGeneration += 1
        let generation = searchGeneration, query = word
        let previousPage = showingEntry && !fresh ? snapshot() : nil
        let preferredRoot = entryRoot, preferredCode = entryCode
        let mode: DictionarySearchMode = openBestMatch ? .exact : (navigate ? .prefix : searchMode)
        let selected = dictionaries.filter { !disabledDictionaries.contains($0.id) && (navigate || searchScope.isEmpty || $0.id == searchScope) }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { hits = []; lookupBusy = false; status = ""; return }
        if dismissKeyboard || navigate { recordSearch(query) }
        if mode == .fullText {
            fullTextSearch(query, in: selected, generation: generation)
            return
        }
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
                    if !navigate && !openBestMatch { self.resultsAnchor = nil }
                    self.hits = hits
                    self.status = hits.isEmpty ? "No match. Try the dictionary form of the word." : ""
                    if openBestMatch, let hit = hits.first(where: { $0.root == preferredRoot && $0.code == preferredCode }) ?? hits.first {
                        self.open(hit)
                    } else if navigate && (!onlyIfMatched || !hits.isEmpty) {
                        if fresh { self.startFreshLookup() }
                        self.resultsAnchor = nil
                        if let previousPage { self.remember(previousPage) }
                        self.showingEntry = false; self.showingLookup = true; self.lookupNavigation = UUID()
                    }
                case .failure(let error): self.hits = []; self.status = error.localizedDescription
                }
            }
        }
    }
    /// 全文: every entry whose definition or example sentences contain the text.
    /// Results appear dictionary by dictionary while the scan continues.
    private func fullTextSearch(_ query: String, in selected: [InstalledDictionary], generation: Int) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        resultsAnchor = nil
        guard !selected.isEmpty else {
            hits = []; lookupBusy = false; status = "Enable a dictionary in Library first, or add the dictionaries folder."
            return
        }
        let flag = CancelFlag()
        fullTextCancel = flag
        hits = []; status = ""; lookupBusy = true
        fullTextProgress = "Searching \(selected[0].name)… 1/\(selected.count)"
        let overall = Self.fullTextLimit, perDictionary = Self.fullTextPerDictionary
        fullTextQueue.async {
            var stores: [String: DictionaryStore] = [:]
            var total = 0
            for (index, dictionary) in selected.enumerated() {
                if flag.isCancelled || total >= overall { break }
                if index > 0 {
                    let label = "Searching \(dictionary.name)… \(index + 1)/\(selected.count)"
                    DispatchQueue.main.async { if generation == self.searchGeneration { self.fullTextProgress = label } }
                }
                // A private store: the scan must not hold the shared one's lock.
                let key = dictionary.root.standardizedFileURL.path
                guard let store = stores[key] ?? (try? DictionaryStore(root: dictionary.root)) else { continue }
                stores[key] = store
                let limit = min(perDictionary, overall - total)
                let found = (try? store.searchText(text, code: dictionary.code, dictionary: dictionary.name,
                                                   limit: limit, cancelled: { flag.isCancelled })) ?? []
                total += found.count
                if !found.isEmpty {
                    DispatchQueue.main.async { if generation == self.searchGeneration { self.hits += found } }
                }
            }
            let capped = total >= overall
            DispatchQueue.main.async {
                guard generation == self.searchGeneration else { return }
                self.lookupBusy = false
                self.fullTextProgress = ""
                if self.hits.isEmpty {
                    self.status = "No definition or example sentence contains “\(text)”."
                } else if capped {
                    self.status = "Showing the first \(overall) entries. Add more characters to narrow it down."
                }
            }
        }
    }
    func open(_ hit: DictionaryHit, replacingCurrent: Bool = false, fresh: Bool = false) {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        liveSearch?.cancel(); liveSearch = nil
        searchGeneration += 1
        let generation = searchGeneration
        let root = hit.root
        let query = replacingCurrent ? (visits.last?.query ?? word) : word
        let matches = replacingCurrent ? (visits.last?.matches ?? hits) : hits
        let wasEntry = showingEntry
        var previousPage = snapshot()
        if !wasEntry { previousPage.anchor = hit }
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
                    // From a card outside Search, Back leads straight back to the page
                    // the text was selected on (see `returnTab`), not to a result list.
                    if fresh { self.startFreshLookup() }
                    else if !replacingCurrent { self.remember(previousPage) }
                    // Scroll positions stay while any Back step can still reach their page.
                    if replacingCurrent, !self.visits.isEmpty {
                        self.visits.removeLast()
                    } else if !wasEntry && !self.showingLookup {
                        self.visits = []
                    }
                    let visit = EntryVisit(hit: hit, html: html, query: query, matches: matches, alternatives: alternatives)
                    self.visits.append(visit)
                    if self.visits.count > 30 { self.visits.removeFirst() }
                    self.pruneOffsets()
                    self.display(visit)
                    self.loadAlternatives(for: visit.id, hit: hit, query: query, enabled: enabled)
                case .failure(let error): self.status = error.localizedDescription
                }
            }
        }
    }
    /// The same word in every enabled dictionary, in the switcher list's order
    /// (dictionary order first, then each dictionary's own order).
    var orderedEntryMatches: [DictionaryHit] {
        let rank = Dictionary(dictionaries.enumerated().map { ($0.element.root.path + "/" + $0.element.code, $0.offset) },
                              uniquingKeysWith: { first, _ in first })
        return entryMatches.enumerated().sorted { a, b in
            let x = rank[a.element.root.path + "/" + a.element.code] ?? Int.max
            let y = rank[b.element.root.path + "/" + b.element.code] ?? Int.max
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element)
    }
    /// Position of the open definition among `orderedEntryMatches`.
    var entryMatchIndex: Int? { orderedEntryMatches.firstIndex { $0.identity == entryHitIdentity } }
    /// The ‹ › arrows beside the title: the previous / next dictionary's entry for
    /// the same word, without opening the switcher list.
    func stepEntry(_ step: Int) {
        let matches = orderedEntryMatches
        guard let index = entryMatchIndex, matches.indices.contains(index + step) else { return }
        closePeek()
        open(matches[index + step], replacingCurrent: true)
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
    @StateObject private var grammar: GrammarStore
    @UIApplicationDelegateAdaptor(FlipAppDelegate.self) private var appDelegate
    init() {
        HandFont.register()
        #if DEBUG
        // Interface tests run upright unless a test asks for the flipped screen.
        if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--ui-") }) {
            let flip = ProcessInfo.processInfo.arguments.contains("--ui-flip-on") ? FlipMode.on : FlipMode.off
            UserDefaults.standard.set(flip.rawValue, forKey: FlipMode.key)
            // The page-turn swipe back starts from its default (off) unless a test asks for it.
            UserDefaults.standard.removeObject(forKey: PageTurn.key)
            if ProcessInfo.processInfo.arguments.contains("--ui-page-turn") { UserDefaults.standard.set(true, forKey: PageTurn.key) }
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-reset-search-keyboard") {
            UserDefaults.standard.removeObject(forKey: "automaticallyShowSearchKeyboard")
        }
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--ui-clipboard"),
           ProcessInfo.processInfo.arguments.indices.contains(index + 1) {
            UIPasteboard.general.string = ProcessInfo.processInfo.arguments[index + 1]
        }
        // What the share-sheet shortcut does: hand text to the app (after launch).
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--ui-external-lookup"),
           ProcessInfo.processInfo.arguments.indices.contains(index + 1) {
            let text = ProcessInfo.processInfo.arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { ExternalLookupInbox.shared.deliver(text) }
        }
        // What the Back Tap shortcut does: look up what was just copied.
        if ProcessInfo.processInfo.arguments.contains("--ui-lookup-clipboard") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { ExternalLookupInbox.shared.deliverClipboard() }
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-dictionary-fixture") {
            UserDefaults.standard.set(false, forKey: "savePassagesOnRead")
            UserDefaults.standard.set(true, forKey: "readerAutoSearch")
            UserDefaults.standard.removeObject(forKey: GrammarStore.learnedKey)
            UserDefaults.standard.removeObject(forKey: "grammarLevel")
            let documents = UITestFixture.documents()
            // Relaunch tests keep the saved place between launches.
            let keep = ProcessInfo.processInfo.arguments.contains("--ui-keep-session")
            if ProcessInfo.processInfo.arguments.contains("--ui-clear-session") { try? FileManager.default.removeItem(at: SessionState.defaultURL) }
            _model = StateObject(wrappedValue: ReaderModel(documents: documents, session: keep ? SessionState.defaultURL : nil))
            _grammar = StateObject(wrappedValue: GrammarStore(documents: documents, bundled: nil))
        } else if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--ui-") }) {
            // Interface tests start from a clean screen every launch.
            _model = StateObject(wrappedValue: ReaderModel())
            _grammar = StateObject(wrappedValue: GrammarStore())
        } else {
            _model = StateObject(wrappedValue: ReaderModel(session: SessionState.defaultURL))
            _grammar = StateObject(wrappedValue: GrammarStore())
        }
        #else
        _model = StateObject(wrappedValue: ReaderModel(session: SessionState.defaultURL))
        _grammar = StateObject(wrappedValue: GrammarStore())
        #endif
    }
    var body: some Scene {
        WindowGroup { ReaderHome().environmentObject(model).environmentObject(grammar).tint(Palette.color(0x1F7A73)).modifier(FlipHost()) }
    }
}

struct ReaderHome: View {
    @EnvironmentObject var model: ReaderModel
    @ObservedObject private var inbox = ExternalLookupInbox.shared
    /// The passage replaced by one sent from another app, for Undo.
    @State private var replacedPassage: String?
    @EnvironmentObject var grammar: GrammarStore
    @Environment(\.scenePhase) private var scenePhase
    /// The last session's tab is reopened once, at launch.
    @State private var restoredTab = false
    @State private var importing = false
    @State private var keyboardVisible = false
    @State private var clearedPassage: String?
    @State private var translation = false
    @State private var selectedTab = 0
    @State private var searchFocusRequest = 0
    @AppStorage("automaticallyShowSearchKeyboard") private var automaticallyShowSearchKeyboard = false
    @AppStorage("searchKeyboardLanguage") private var searchKeyboardLanguage = "ja"
    @AppStorage(FlipMode.key) private var flipModeRaw = FlipMode.off.rawValue
    @AppStorage(ImmersiveController.gestureKey) private var immersiveGesture = true
    /// Appearance → Going back: swiping back turns the screen like a page.
    @AppStorage(PageTurn.key) private var pageTurnBack = false
    @GestureState private var edgeSwiping = false
    @ObservedObject private var immersive = ImmersiveController.shared
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
    // Reading text from photos, screenshots and the camera.
    @State private var showingPhotoPicker = false
    @State private var showingCamera = false
    @State private var photoItem: PhotosPickerItem?
    @State private var photoImport: ImportedImage?
    @State private var showTranslation = false
    /// The size shown while a two-finger swipe changes it.
    @State private var sizeHUD: Int?
    @State private var translatedLines: [String] = []
    @State private var translatedKey = ""
    // One-time switch of light-theme installs to the desktop's Washi look (2.0).
    @AppStorage("washiRedesignApplied") private var washiRedesignApplied = false
    @AppStorage("readerTextSize") private var readerTextSize = 23.0
    @AppStorage("readerLineSpacing") private var readerLineSpacing = 1.35
    /// Ruled notebook lines behind the passage (desktop look).
    @AppStorage("ruledPaper") private var ruledPaper = true
    /// Ruled-line visibility and thickness multipliers (1 = default).
    @AppStorage("ruleStrength") private var ruleStrength = 1.0
    @AppStorage("ruleThickness") private var ruleThickness = 1.0
    @AppStorage("dictionaryTextSize") private var dictionaryTextSize = 19.0
    @AppStorage(DictionaryTextSizes.key) private var dictionaryTextSizes = ""
    @AppStorage("dictionarySans") private var dictionarySans = false
    @AppStorage("pageMargins") private var pageMarginsRaw = PageMargins.compact.rawValue
    private var pageMargins: PageMargins { PageMargins.resolve(pageMarginsRaw) }
    // Search header: hides while scrolling down through results, returns on scroll up.
    @State private var headerCollapsed = false
    /// Side of the last double-tap dictionary step, shown briefly as a chevron.
    @State private var entryStepFlash: Int?
    /// How far the results are pulled down past the top (pull to clear).
    @State private var searchPull: CGFloat = 0
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
        replacedPassage = nil
        model.cancelPendingSearch()
        model.text = ""; model.readerOffset = .zero; model.readerSelection = ""
        model.status = "Passage cleared."
        dismissKeyboard()
    }
    /// A word is looked up on the Search tab; a sentence or more opens on the Read
    /// page (the previous passage can be brought back with Undo).
    private func receiveExternal(_ text: String) {
        if ExternalLookup.isPassage(text) {
            let previous = model.text
            dismissKeyboard()
            pastePassage([text])
            if !previous.isEmpty && previous != text { replacedPassage = previous }
            selectedTab = 0
            model.status = "Opened from another app. Select any word to look it up."
        } else {
            model.returnTab = selectedTab == 1 ? model.returnTab : selectedTab
            dismissKeyboard()
            model.lookUpExternal(text)
        }
    }

    private func pastePassage(_ strings: [String]) {
        guard !strings.isEmpty else { return }
        replacedPassage = nil
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
            if tab == 1 { openSearchTab() } else { selectedTab = tab }
        })) {
            readerTab
            searchTab
            libraryTab
            grammarTab
        }
        .sheet(isPresented: $showingHistory) { historySheet }
        .background(SelectionTouchObserver(enabled: selectedTab == 0 || selectedTab == 3 || (selectedTab == 1 && model.showingEntry)) { down, cancelled in
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
        .overlay(alignment: .top) { sizeBadge }
        .overlay(alignment: .bottom) {
            if let hint = immersive.hint {
                ImmersiveHint(text: hint, style: style)
                    .padding(.bottom, 28)
                    .transition(.opacity)
            }
        }
        .background(ImmersiveGesture(enabled: immersiveGesture))
        .onAppear {
            if !restoredTab {
                restoredTab = true
                if let state = model.restoredSession { grammar.restore(state) }
                selectedTab = model.restoredTab
                model.currentTab = selectedTab
            }
            applyRedesignOnce()
            YohakuChrome.apply(style)
            PageTurn.shared.paper = UIColor(paper); PageTurn.shared.look = style.identity
            // Start WebKit once the first screen is up, so the first definition opens fast.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { DictionaryPage.prewarm() }
        }
        .onChange(of: style.identity) { _, _ in
            PageTurn.shared.paper = UIColor(paper); PageTurn.shared.look = style.identity
            YohakuChrome.apply(style)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { YohakuChrome.apply(style) }
        }
        .onChange(of: selectedTab) { previous, tab in
            // Still on screen at this point: the tab a swipe back from Search returns to.
            if tab == 1 { PageTurn.shared.leaving(tab: previous) }
            if style.isYohaku { DispatchQueue.main.async { YohakuChrome.apply(style) } }
            // Programmatic lookup navigation must keep the keyboard hidden.
            // User tab taps are handled separately, including reselection.
            model.currentTab = tab
            if tab != 1 {
                // The Search page, its Back history and scroll positions stay put.
                wantsSearchFocus = false; model.leaveLookup()
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        }
        .onChange(of: model.lookupNavigation) { _, _ in wantsSearchFocus = false; selectedTab = 1 }
        // Text sent from other apps: the share-sheet shortcut or a jpreader:// link.
        .onOpenURL { url in
            if let text = ExternalLookup.text(from: url) { receiveExternal(text) }
        }
        .onReceive(inbox.$pending) { text in
            guard let text else { return }
            inbox.pending = nil
            receiveExternal(text)
        }
        .onReceive(inbox.$notice) { note in
            guard let note else { return }
            inbox.notice = nil
            model.status = note
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { saveSession() } }
        // Also straight from UIKit, in case the scene phase reaches this view late.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in saveSession() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in saveSession() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in saveSession() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let folder): model.importFolder(folder)
            case .failure(let error): model.status = error.localizedDescription
            }
        }
    }

    /// Saved whenever the app is put away, so a closed app reopens where it was.
    private func saveSession() {
        guard let url = model.sessionURL else { return }
        var state = model.sessionState(tab: selectedTab)
        grammar.fill(&state)
        state.write(to: url)
    }

    // Stays reachable above the keyboard on every screen.
    private var keyboardBar: some View {
        HStack {
            Button("Read") { dismissKeyboard(); selectedTab = 0 }.accessibilityIdentifier("keyboardReadTab")
            Spacer()
            Button("Search") { openSearchTab() }.accessibilityIdentifier("keyboardSearchTab")
            Spacer()
            Button("Library") { dismissKeyboard(); selectedTab = 2 }.accessibilityIdentifier("keyboardLibraryTab")
            Spacer()
            Button("Grammar") { dismissKeyboard(); selectedTab = 3 }.accessibilityIdentifier("keyboardGrammarTab")
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

    /// Tab icon: SF Symbols normally; in 余白 Yohaku geometric line icons, the active
    /// one with a small navy square above it.
    @ViewBuilder private func tabLabel(_ title: String, system: String, yohaku: YohakuIcons.Kind, tag: Int) -> some View {
        if style.isYohaku {
            Label { Text(title) } icon: { Image(uiImage: YohakuIcons.image(yohaku, selected: selectedTab == tag)) }
        } else {
            Label(title, systemImage: system)
        }
    }

    // MARK: - Grammar

    private var grammarTab: some View {
        GrammarTab(style: style, margins: pageMargins, quietMenu: quietMenu, active: selectedTab == 3,
                   typeface: readerTypeface,
                   showSize: { sizeHUD = $0 }, hideSize: hideSizeHUD)
            .toolbarBackground(paper, for: .tabBar, .navigationBar)
            .toolbarBackground(.visible, for: .tabBar, .navigationBar)
            .tabItem { tabLabel("Grammar", system: "text.book.closed", yohaku: .grammar, tag: 3) }.tag(3)
    }

    // MARK: - Read

    private var readerTab: some View {
        NavigationStack {
            translating(VStack(spacing: 0) {
                if !immersive.on {
                    Group {
                        if style.isYohaku {
                            YohakuHeader(style: style, index: "01", title: "読む", latin: "Reading",
                                         detail: model.text.isEmpty ? nil : "\(model.text.count) 字",
                                         drawing: .sprig, height: 112) {
                                HStack(spacing: 2) { clearButton; translateButton; readerOptionsMenu }
                            }
                        } else {
                            readerHeader
                        }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                readingView
            })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(paperBackground)
            .translationPresentation(isPresented: $translation, text: model.text)
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(immersive.on ? .hidden : .automatic, for: .tabBar)
            .photosPicker(isPresented: $showingPhotoPicker, selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                photoItem = nil
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        beginPhotoImport(image)
                    } else {
                        model.status = "That photo couldn't be opened."
                    }
                }
            }
            .fullScreenCover(isPresented: $showingCamera) {
                CameraPicker { image in
                    showingCamera = false
                    if let image { beginPhotoImport(image) }
                }
                .ignoresSafeArea()
            }
            .fullScreenCover(item: $photoImport) { imported in
                PhotoTextImport(image: imported.image, style: style,
                                finish: { text in
                                    photoImport = nil
                                    pastePassage([text])
                                    model.status = "Read from photo. Select any word to look it up."
                                },
                                cancel: { photoImport = nil })
            }
        }
        .toolbarBackground(paper, for: .tabBar, .navigationBar)
        .toolbarBackground(.visible, for: .tabBar, .navigationBar)
        .tabItem { tabLabel("Read", system: "book", yohaku: .read, tag: 0) }.tag(0)
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
        if let previous = replacedPassage, !model.text.isEmpty {
            // A passage sent from another app replaced this one.
            Button("Undo") { model.text = previous; model.readerOffset = .zero; replacedPassage = nil; model.status = "" }
                .buttonStyle(HandSoftButtonStyle(style: style, prominent: true))
                .accessibilityIdentifier("undoReplacedPassage")
        } else if model.text.isEmpty, let previous = clearedPassage {
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
            Button { immersive.set(true) } label: { Label("Full screen · 全螢幕", systemImage: "arrow.up.left.and.arrow.down.right") }
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

    /// The open dictionary's own definition size, or the default one.
    private var entryTextSize: Double {
        DictionaryTextSizes.size(for: model.entryCode, in: dictionaryTextSizes, fallback: dictionaryTextSize)
    }
    private var entryHasOwnSize: Bool { DictionaryTextSizes.decode(dictionaryTextSizes)[model.entryCode] != nil }
    private func setEntryTextSize(_ value: Double) {
        dictionaryTextSizes = DictionaryTextSizes.setting(value, for: model.entryCode, in: dictionaryTextSizes)
    }
    private func hideSizeHUD() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { withAnimation(.easeOut(duration: 0.25)) { sizeHUD = nil } }
    }

    /// Size readout while two fingers change the text size.
    private var sizeBadge: some View {
        Group {
            if let size = sizeHUD {
                HStack(spacing: 6) {
                    Image(systemName: "textformat.size")
                    Text("\(size) pt").monospacedDigit()
                }
                .font(HandFont.title(17))
                .foregroundStyle(style.onAccent)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(style.accent.opacity(0.92), in: SketchShape(radius: 14))
                .padding(.top, 70)
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
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
                               sideInset: pageMargins.readerInset,
                               ruled: ruledPaper,
                               ruleColor: UIColor(style.paperRule).withAlphaComponent(min(1, (style.isDark ? 0.30 : 0.26) * ruleStrength)),
                               ruleWidth: CGFloat(1.5 * ruleThickness),
                               marginColor: UIColor(style.isFable ? style.spark : accent).withAlphaComponent(style.isFable ? 0.42 : 0.38),
                               resize: TextResize(value: readerTextSize, range: 16...48,
                                                  set: { readerTextSize = $0; sizeHUD = Int($0) },
                                                  ended: hideSizeHUD),
                               saveOffset: { model.readerOffset = $0 }) { word in
                guard selectedTab == 0 else { return }
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
            .padding(.horizontal, pageMargins.cardInset + 4)
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

    private func beginPhotoImport(_ image: UIImage) {
        let upright = TextRecognizer.upright(image)
        // Let any sheet that is still closing finish first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { photoImport = ImportedImage(image: upright) }
    }

    private var photoMenu: some View {
        Menu {
            Button { showingPhotoPicker = true } label: {
                Label("Choose photo or screenshot", systemImage: "photo.on.rectangle")
            }
            Button { showingCamera = true } label: { Label("Take picture", systemImage: "camera") }
                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
            Button {
                if let image = UIPasteboard.general.image { beginPhotoImport(image) }
                else { model.status = "There's no image on the clipboard. Copy an image first, or take a screenshot and choose it from Photos." }
            } label: { Label("Paste image", systemImage: "doc.on.clipboard") }
        } label: {
            Label("Photo", systemImage: "text.viewfinder")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(accent)
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .sketchPill(style)
        }
        .accessibilityLabel("Read text from a photo")
        .accessibilityIdentifier("photoImport")
    }

    private var readingActions: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                PasteButton(payloadType: String.self, onPaste: pastePassage)
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .tint(accent)
                    .accessibilityIdentifier("pastePassage")
                photoMenu
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
                if model.showingEntry {
                    if model.entryHTML.isEmpty { reopeningEntry } else { entryView }
                } else { lookup(focusSearch: wantsSearchFocus) }
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
            .toolbar(model.showingEntry && !immersive.on ? .visible : .hidden, for: .navigationBar)
            .toolbar(searchChromeHidden || immersive.on ? .hidden : .visible, for: .tabBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if model.showingEntry {
                        Button { goBackInSearch() } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Back")
                    }
                }
                ToolbarItem(placement: .principal) {
                    if model.showingEntry {
                        HStack(spacing: 4) {
                            entryStepButton(-1)
                            entryTitleButton
                            entryStepButton(1)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if model.showingEntry {
                        Menu {
                            Button("Search results") { model.showResults(); applySearchKeyboardPreference() }
                            Picker("Page margins", selection: $pageMarginsRaw) {
                                ForEach(PageMargins.allCases) { margin in Text(margin.title).tag(margin.rawValue) }
                            }
                            .pickerStyle(.menu)
                            Menu {
                                Button { setEntryTextSize(entryTextSize + 1) } label: { Label("Larger", systemImage: "textformat.size.larger") }
                                    .disabled(entryTextSize >= DictionaryTextSizes.range.upperBound)
                                Button { setEntryTextSize(entryTextSize - 1) } label: { Label("Smaller", systemImage: "textformat.size.smaller") }
                                    .disabled(entryTextSize <= DictionaryTextSizes.range.lowerBound)
                                if entryHasOwnSize {
                                    Button("Use default size (\(Int(dictionaryTextSize)) pt)") {
                                        dictionaryTextSizes = DictionaryTextSizes.removing(model.entryCode, in: dictionaryTextSizes)
                                    }
                                }
                            } label: {
                                Label("Text size for this dictionary · \(Int(entryTextSize)) pt", systemImage: "textformat.size")
                            }
                            Button("Copy learning prompt") { UIPasteboard.general.string = model.prompt(inDictionary: true); model.status = "Learning prompt copied." }
                            Button("Back to Main Page") { selectedTab = 0 }
                            Button { immersive.set(true) } label: { Label("Full screen · 全螢幕", systemImage: "arrow.up.left.and.arrow.down.right") }
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
        .background(SearchTabObserver { reselected in if reselected { activateSearchTab() } })
        .tabItem { tabLabel("Search", system: "magnifyingglass", yohaku: .search, tag: 1) }.tag(1)
    }

    /// Double-tap on the right / left half of a definition = › / ‹.
    private func doubleTapStep(_ step: Int) {
        guard selectedTab == 1, model.showingEntry else { return }
        guard let index = model.entryMatchIndex, model.orderedEntryMatches.indices.contains(index + step) else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.easeOut(duration: 0.12)) { entryStepFlash = step }
        model.stepEntry(step)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            withAnimation(.easeIn(duration: 0.2)) { if entryStepFlash == step { entryStepFlash = nil } }
        }
    }

    /// Progress (and the final note) of a full-text search, above the tab bar.
    private var fullTextStatus: AnyView { AnyView(fullTextStatusContent) }
    @ViewBuilder private var fullTextStatusContent: some View {
        let text = !model.fullTextProgress.isEmpty ? model.fullTextProgress
            : (model.searchMode == .fullText && !model.word.isEmpty ? model.status : "")
        if !text.isEmpty && !model.showingEntry {
            HStack(spacing: 8) {
                if !model.fullTextProgress.isEmpty { ProgressView().controlSize(.small) }
                Text(text).font(.system(size: 12.5, weight: .medium)).foregroundStyle(style.secondary)
                    .lineLimit(2).multilineTextAlignment(.center)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(style.surface, in: Capsule())
            .overlay(Capsule().stroke(style.separator, lineWidth: 1))
            .padding(.horizontal, 16).padding(.bottom, 12)
            .allowsHitTesting(false)
            .accessibilityIdentifier("fullTextStatus")
        }
    }

    /// Pull the results (or the empty page) down and let go: with text in the box
    /// it is cleared; with an empty box the keyboard comes up. Like pull to
    /// refresh, so a typo needs no tap on the small ✕.
    private static let searchPullThreshold: CGFloat = 70
    private var searchPullRelease: PullRelease {
        PullRelease(threshold: Self.searchPullThreshold,
                    pulled: { pull in
                        if abs(pull - searchPull) > 0.5 || pull == 0 {
                            let crossed = (pull >= Self.searchPullThreshold) != (searchPull >= Self.searchPullThreshold)
                            searchPull = pull
                            if crossed && pull >= Self.searchPullThreshold { UISelectionFeedbackGenerator().selectionChanged() }
                        }
                    },
                    released: { searchPullReleased() })
    }
    private func searchPullReleased() {
        guard selectedTab == 1, !model.showingEntry else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        // Clearing can swap the result list for the empty page mid-bounce.
        searchPull = 0
        if !model.word.isEmpty { model.typedSearch("", clearSelection: true) }
        // After the list springs back, so the drag does not dismiss the keyboard again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if selectedTab == 1, !model.showingEntry { requestSearchFocus() }
        }
    }
    /// "↑ Release to clear", shown in the gap above the pulled-down list.
    private var searchPullHint: AnyView { AnyView(searchPullHintContent) }
    private var searchPullHintContent: some View {
        let progress = min(searchPull / Self.searchPullThreshold, 1)
        let ready = progress >= 1
        let text = model.word.isEmpty
            ? (ready ? "Release to show keyboard" : "Pull down to show keyboard")
            : (ready ? "Release to clear" : "Pull down to clear")
        return HStack(spacing: 8) {
            Image(systemName: "arrow.up")
                .font(.system(size: 20, weight: .light))
                .rotationEffect(.degrees(ready ? 0 : 180))
                .animation(.snappy(duration: 0.18), value: ready)
            Text(text).font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(style.secondary)
        .frame(maxWidth: .infinity)
        .frame(height: max(searchPull, 0))
        .opacity(Double(min(1, searchPull / 30)))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// ‹ / › : the same word in the previous / next dictionary.
    private func entryStepButton(_ step: Int) -> AnyView { AnyView(entryStepButtonContent(step)) }
    private func entryStepButtonContent(_ step: Int) -> some View {
        let count = model.orderedEntryMatches.count
        let index = model.entryMatchIndex
        let enabled = index.map { count > 1 && (0..<count).contains($0 + step) } ?? false
        return Button { model.stepEntry(step) } label: {
            Image(systemName: step < 0 ? "chevron.left" : "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(accent)
                .frame(width: 26, height: 30)
                .sketchPill(style)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .accessibilityLabel(step < 0 ? "Previous dictionary" : "Next dictionary")
        .accessibilityIdentifier(step < 0 ? "previousDictionaryEntry" : "nextDictionaryEntry")
    }

    private var entryTitleButton: AnyView { AnyView(entryTitleButtonContent) }
    private var entryTitleButtonContent: some View {
        Button { switchingDictionary = true } label: {
            HStack(spacing: 6) {
                HandSeal(text: "辞", style: style, size: 22)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        Text(model.entryDictionary)
                            .font(.system(size: 10.5, weight: .semibold)).lineLimit(1).foregroundStyle(style.secondary)
                        if let index = model.entryMatchIndex, model.orderedEntryMatches.count > 1 {
                            Text("\(index + 1)/\(model.orderedEntryMatches.count)")
                                .font(.system(size: 10, weight: .bold).monospacedDigit()).foregroundStyle(accent)
                                .fixedSize()
                        }
                    }
                    HStack(spacing: 4) {
                        Text(model.entryTitle).font(HandFont.title(17)).lineLimit(1).foregroundStyle(style.ink)
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(accent)
                    }
                }
                // Leaves room for the ‹ › arrows and the ☰ menu on the narrowest
                // iPhones; long dictionary names truncate.
                .frame(maxWidth: 124, alignment: .leading)
            }
            .padding(.leading, 5).padding(.trailing, 9).padding(.vertical, 3)
            .sketchPill(style)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("switchDictionary")
    }

    private var entryPeekVisible: Bool { model.peek?.inDictionary ?? false }

    /// Shown for a moment while a page from the last session is read again.
    private var reopeningEntry: some View {
        ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("reopeningEntry")
    }

    private var entryView: AnyView { AnyView(entryViewContent) }
    private var entryViewContent: some View {
        let visitID = model.entryID
        return ZStack(alignment: .bottom) {
            DictionaryPage(html: model.entryHTML, root: model.entryRoot ?? model.dictionaryRoot, code: model.entryCode,
                           paperRGB: style.isYohaku ? style.backgroundRGB : style.surfaceRGB, accentRGB: style.accentRGB,
                           textSize: entryTextSize, sansFont: dictionarySans,
                           initialOffset: model.entryOffsets[visitID] ?? .zero,
                           bottomInset: entryPeekVisible ? 300 : 0,
                           quietMenu: quietMenu,
                           resize: TextResize(value: entryTextSize, range: DictionaryTextSizes.range,
                                              set: { setEntryTextSize($0); sizeHUD = Int($0) },
                                              ended: hideSizeHUD),
                           margins: pageMargins,
                           saveOffset: { model.entryOffsets[visitID] = $0 },
                           followLink: { model.followEntryLink($0) },
                           doubleTapStep: { doubleTapStep($0) },
                           highlight: model.entryHighlight) { word in
                guard selectedTab == 1, model.showingEntry else { return }
                model.select(word, inDictionary: true)
            }
            .id(visitID.uuidString + style.identity + "-\(dictionarySans)")
            .clipShape(SketchShape(radius: 18))
            .padding(pageMargins == .compact ? 1 : 3)
            .sketchCard(style, radius: 20, tape: .marker, tapeTrailing: true, fill: nil)
            .padding(.horizontal, pageMargins.cardInset)
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
        .overlay(alignment: entryStepFlash == -1 ? .leading : .trailing) {
            if let flash = entryStepFlash {
                Image(systemName: flash < 0 ? "chevron.left" : "chevron.right")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(style.onAccent)
                    .frame(width: 52, height: 52)
                    .background(accent.opacity(0.85), in: Circle())
                    .padding(.horizontal, 22)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    .allowsHitTesting(false)
            }
        }
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

    private func lookup(focusSearch: Bool) -> AnyView { AnyView(lookupContent(focusSearch: focusSearch)) }
    private func lookupContent(focusSearch: Bool) -> some View {
        ZStack(alignment: .top) {
            Group {
                if model.hits.isEmpty {
                    ScrollView {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: headerHeight)
                        EmptyHint(symbol: model.word.isEmpty ? "character.book.closed" : "magnifyingglass",
                                  title: model.word.isEmpty ? "Look up any Japanese word"
                                    : (model.fullTextProgress.isEmpty ? "Nothing found yet" : "Searching…"),
                                  detail: model.word.isEmpty
                                    ? (model.searchMode == .fullText
                                       ? "Full text: type a word or phrase to find it anywhere in the definitions and example sentences of every enabled dictionary."
                                       : "Type above, or highlight a word while reading. Enabled dictionaries are searched in your chosen order.")
                                    : (model.searchMode == .fullText
                                       ? "Full text searches every definition and example sentence; results appear dictionary by dictionary."
                                       : "Exact matches appear first, then words that start with your text. Try the dictionary form."),
                                  style: style)
                            .padding(.top, 36)
                        Spacer(minLength: 0)
                    }
                    .background(searchPullRelease)
                    }
                    .scrollBounceBehavior(.always, axes: .vertical)
                    .scrollDismissesKeyboard(.immediately)
                } else {
                    resultGroups(model.hits, topInset: headerHeight)
                }
            }
            if searchPull > 4 && !searchChromeHidden {
                searchPullHint.padding(.top, headerHeight + 4)
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
        .overlay(alignment: .bottom) { fullTextStatus }
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

    // The search bar is built from separately type-erased rows. As one nested
    // view, its type got so deep that decoding it at launch overflowed the main
    // thread's stack in the optimized device build (2.7 build 29 crash).
    private func searchHeader(focusSearch: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if style.isYohaku {
                YohakuLabel(text: "SEARCH", style: style).padding(.leading, 40).padding(.bottom, -8)
            }
            searchFieldRow(focusSearch: focusSearch)
            searchChipsRow
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .background(paper.opacity(0.94))
        .overlay(alignment: .bottom) { HandRule(style: style).offset(y: 4) }
    }

    /// The Paste button beside the search field: the copied text (its first line)
    /// replaces the search and the results open straight away.
    private func pasteIntoSearch(_ strings: [String]) {
        let pasted = ExternalLookup.clean(strings.joined(separator: " "))
        let line = pasted.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let query = String(line.trimmingCharacters(in: .whitespaces).prefix(200))
        guard !query.isEmpty else { return }
        model.typedSearch(query, clearSelection: true)
        model.search()
    }

    private func searchFieldRow(focusSearch: Bool) -> AnyView {
        AnyView(
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
                    // Paste what was copied and search for it, replacing what is in the
                    // field. The system paste button needs no "Allow Paste" question.
                    PasteButton(payloadType: String.self) { strings in pasteIntoSearch(strings) }
                        .labelStyle(.iconOnly)
                        .buttonBorderShape(style.isYohaku ? .roundedRectangle(radius: 2) : .capsule)
                        .controlSize(.small)
                        .tint(accent)
                        .accessibilityIdentifier("pasteSearch")
                        .background(KeyboardControlArea())
                    if !model.word.isEmpty {
                        Button { model.search() } label: {
                            Image(systemName: "arrow.forward")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(style.onAccent)
                                .frame(width: 30, height: 30)
                                .background(accent, in: RoundedRectangle(cornerRadius: style.isYohaku ? 0 : 15))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Search dictionaries")
                        .background(KeyboardControlArea())
                    }
                }
                .padding(.leading, style.isYohaku ? 2 : 14).padding(.trailing, 6).padding(.vertical, 3)
                .modifier(SearchFieldChrome(style: style))
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
        )
    }

    private var searchChipsRow: AnyView {
        AnyView(
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
        )
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

    private var matchModeSymbol: String {
        switch model.searchMode {
        case .prefix: return "text.line.first.and.arrowtriangle.forward"
        case .exact: return "equal"
        case .fullText: return "text.magnifyingglass"
        }
    }
    private var matchModeTitle: String {
        switch model.searchMode {
        case .prefix: return "Starts with"
        case .exact: return "Exact word"
        case .fullText: return "Full text"
        }
    }

    private var matchModeChip: AnyView {
        AnyView(Menu {
            Picker("Match", selection: $model.searchMode) {
                Label("Starts with", systemImage: "text.line.first.and.arrowtriangle.forward").tag(DictionarySearchMode.prefix)
                Label("Exact word", systemImage: "equal").tag(DictionarySearchMode.exact)
                Label("Full text · 全文 (definitions & examples)", systemImage: "text.magnifyingglass").tag(DictionarySearchMode.fullText)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: matchModeSymbol)
                    .font(.system(size: 11, weight: .bold))
                Text(matchModeTitle)
                    .font(.system(size: 13, weight: .semibold))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(accent)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(style.accentSoft, in: SketchShape(radius: 12))
            .overlay(SketchShape(radius: 12).stroke(accent.opacity(0.35), lineWidth: 1.2))
        }
        .background(KeyboardControlArea())
        .accessibilityLabel("Match"))
    }

    private func scopeChip(_ name: String, id: String) -> some View {
        let selected = model.searchScope == id
        return Button { model.searchScope = id; model.typedSearch(model.word) } label: {
            Text(name)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .lineLimit(1)
                .foregroundStyle(selected ? style.onPill : style.ink)
                .padding(.horizontal, 13).padding(.vertical, 7)
                .sketchPill(style, selected: selected)
        }
        .buttonStyle(.plain)
        .background(KeyboardControlArea())
        .accessibilityIdentifier("searchScope_" + id)
    }

    private func resultGroups(_ hits: [DictionaryHit], switching: Bool = false, topInset: CGFloat = 0) -> AnyView {
        AnyView(resultGroupsContent(hits, switching: switching, topInset: topInset))
    }
    private func resultGroupsContent(_ hits: [DictionaryHit], switching: Bool, topInset: CGFloat) -> some View {
        ScrollViewReader { reader in
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
                                .id(hit.identity)
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
            .background { if !switching { searchPullRelease } }
        }
        .coordinateSpace(name: switching ? "switcherResults" : "searchResults")
        .onPreferenceChange(ResultsScrollOffsetKey.self) { minY in
            if !switching { resultsScrolled(to: minY) }
        }
        .scrollDismissesKeyboard(.immediately)
        .onAppear {
            // Back to a result list (or reopened at launch): show the result opened from it.
            guard !switching, model.revealResultsAnchor, let anchor = model.resultsAnchor,
                  hits.contains(where: { $0.identity == anchor.identity }) else { return }
            model.revealResultsAnchor = false
            DispatchQueue.main.async { reader.scrollTo(anchor.identity, anchor: .center) }
        }
        }
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

    /// The full-text match in bold accent colour inside its preview line.
    private func highlighted(_ text: String, _ match: String) -> AttributedString {
        var value = AttributedString(text)
        guard !match.isEmpty else { return value }
        var cursor = value.startIndex
        while cursor < value.endIndex, let range = value[cursor...].range(of: match) {
            value[range].foregroundColor = accent
            value[range].inlinePresentationIntent = .stronglyEmphasized
            cursor = range.upperBound
        }
        return value
    }

    private func resultRow(_ hit: DictionaryHit, switching: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(hit.word).font(style.isYohaku ? YohakuFont.headword(22) : HandFont.title(20)).foregroundStyle(ink)
                if !hit.preview.isEmpty {
                    Text(highlighted(hit.preview, hit.match)).font(.subheadline).foregroundStyle(style.secondary)
                        .lineLimit(hit.match.isEmpty ? 2 : 3)
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
        } else {
            // Back to where the lookup came from: the 文法 lesson or the Read page.
            dismissKeyboard()
            selectedTab = model.returnTab ?? 0
        }
    }
    private func backSwipeEdge(fromLeft: Bool) -> some View {
        // Narrow, so taps on text near the page edge still reach the page.
        GeometryReader { strip in
            Color.clear.contentShape(Rectangle())
                .accessibilityIdentifier(fromLeft ? "backSwipeLeftEdge" : "backSwipeRightEdge")
                .gesture(DragGesture(minimumDistance: pageTurnBack ? 8 : 25)
                    .updating($edgeSwiping) { _, swiping, _ in swiping = true }
                    .onChanged { value in
                        if pageTurnBack { turnPage(value, fromLeft: fromLeft, top: strip.frame(in: .global).minY) }
                    }
                    .onEnded { value in
                        if PageTurn.shared.tracking {
                            PageTurn.shared.end(velocity: value.velocity.width)
                            return
                        }
                        guard !pageTurnBack else { return }
                        let horizontal = value.translation.width
                        if abs(horizontal) > 65 && abs(horizontal) > abs(value.translation.height) * 2 && (fromLeft ? horizontal > 0 : horizontal < 0) {
                            goBackInSearch()
                        }
                    })
        }
        .frame(width: 16)
        // A swipe the system takes away never reports its end: lay the page down again.
        .onChange(of: edgeSwiping) { _, swiping in if !swiping { PageTurn.shared.fingerLifted() } }
    }
    /// Page-turn swipe back: the screen peels away under the finger, showing where Back leads.
    private func turnPage(_ value: DragGesture.Value, fromLeft: Bool, top: CGFloat) {
        let turn = PageTurn.shared
        let width = PageTurn.window?.bounds.width ?? UIScreen.main.bounds.width
        let start = CGPoint(x: fromLeft ? value.startLocation.x : width - 16 + value.startLocation.x, y: top + value.startLocation.y)
        if !turn.active {
            let across = value.translation.width * (fromLeft ? 1 : -1)
            guard across > 4, across > abs(value.translation.height) else { return }
            let under = model.canGoBack ? model.backPicture : turn.picture(ofTab: model.returnTab ?? 0)
            dismissKeyboard()
            guard turn.begin(fromLeft: fromLeft, at: start, under: under, complete: { goBackInSearch() }) else { return }
        }
        turn.move(to: CGPoint(x: start.x + value.translation.width, y: start.y + value.translation.height))
    }
    private func applySearchKeyboardPreference() {
        if automaticallyShowSearchKeyboard { requestSearchFocus() }
        else { dismissKeyboard() }
    }
    /// Tapping Search from another tab returns to the open definition, if any.
    private func openSearchTab() {
        // Back from Search, once its pages are used up, returns to this tab.
        if selectedTab != 1 { model.returnTab = selectedTab }
        if selectedTab != 1 && model.showingEntry {
            dismissKeyboard()
            selectedTab = 1
            return
        }
        activateSearchTab()
    }
    /// Tapping Search again while on it (or with no open definition) goes to the search field.
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

    /// Section titles of Library, in page order (目次).
    static let librarySections = ["Search keyboard", "Keyboard language", "Saved passages", "Offline dictionaries", "Dictionary search",
                                  "Upside down · 倒過來", "Full screen · 全螢幕", "Keep a backup", "Translation"]

    private var libraryTab: some View {
        NavigationStack {
          ScrollViewReader { proxy in
            List {
                if style.isYohaku {
                    YohakuHeader(style: style, index: "03", title: "書庫", latin: "Library",
                                 detail: "saved passages", numeral: "\(model.saved.count)", drawing: .teacup, height: 128) { EmptyView() }
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(style.background)
                }
                Group {
                    librarySettingsTop
                    savedSection
                    dictionariesSection
                    librarySettingsRest
                }
                .listRowBackground(style.isYohaku ? style.background : style.surface)
            }
            .modifier(YohakuList(style: style))
            .scrollContentBackground(.hidden)
            .background(paperBackground)
            .pageTurnStackPage()
            .navigationTitle("書庫 · Library")
            .navigationBarTitleDisplayMode(style.isYohaku ? .inline : .automatic)
            .toolbar(immersive.on ? .hidden : .automatic, for: .navigationBar, .tabBar)
            .searchable(text: $librarySearch, prompt: "Find saved text or notes")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
                ToolbarItem(placement: .topBarLeading) {
                    SectionJump(style: style, titles: Self.librarySections) { index in
                        withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo("jump." + Self.librarySections[index], anchor: .top) }
                    }
                }
            }
            .confirmationDialog("Delete all \(model.saved.count) saved passages and their notes?", isPresented: $deleteAll, titleVisibility: .visible) {
                Button("Delete all", role: .destructive) { model.delete(ids: Set(model.saved.map(\.id))) }
                Button("Cancel", role: .cancel) {}
            }
          }
        }
        .toolbarBackground(paper, for: .tabBar, .navigationBar)
        .toolbarBackground(.visible, for: .tabBar, .navigationBar)
        .tabItem { tabLabel("Library", system: "books.vertical", yohaku: .library, tag: 2) }.tag(2)
    }

    // Library's settings in two type-erased groups (see the note on appearancePage:
    // one long expression here is built on the main thread's stack at launch).
    private var librarySettingsTop: AnyView {
        AnyView(Group {
                    appearanceLink
                    Section {
                        Toggle("Show keyboard when returning from definitions", isOn: $automaticallyShowSearchKeyboard)
                            .accessibilityIdentifier("automaticallyShowSearchKeyboard")
                        Text("Tapping the Search tab always opens the keyboard and selects the previous search. Tap blank space to hide the keyboard.")
                            .font(.caption).foregroundStyle(style.secondary)
                    } header: { Text("Search keyboard").textCase(nil).id("jump.Search keyboard") }
                    Section {
                        Picker("Search keyboard", selection: $searchKeyboardLanguage) {
                            Text("Japanese").tag("ja")
                            Text("English").tag("en")
                            Text("System keyboard").tag("system")
                        }
                        Text("Enable your preferred language in iPhone Settings → General → Keyboard → Keyboards. System keyboard lets you choose any installed language.").font(.caption)
                    } header: { Text("Keyboard language").textCase(nil).id("jump.Keyboard language") }
        })
    }
    private var librarySettingsRest: AnyView {
        AnyView(Group {
                    Section {
                        Toggle("Show selection results in a card", isOn: $model.selectionPeek).accessibilityIdentifier("librarySelectionPeek")
                        Stepper(value: $selectionLimit, in: SelectionLimit.range, step: 5) {
                            HStack {
                                Text("Look up selections up to")
                                Spacer()
                                Text("\(selectionLimit) characters").foregroundStyle(style.secondary).monospacedDigit()
                            }
                        }
                        .accessibilityIdentifier("selectionLookupLimit")
                        Text("Selections up to this length are looked up in the dictionary card. Longer selections (a sentence or a paragraph) open the same card with the whole text and Copy, Translate and Share.").font(.caption).foregroundStyle(style.secondary)
                        Toggle("Hide the iPhone Copy / Look Up bar", isOn: $quietSystemTextMenu)
                            .disabled(!model.selectionPeek)
                            .accessibilityIdentifier("quietSystemTextMenu")
                        Text("On: selecting text opens a dictionary card on the same page. Drag the selection handles, or drag across the characters on the card, to look up just part of a phrase. Off: selecting jumps straight to the results page.").font(.caption).foregroundStyle(style.secondary)
                        Toggle("Auto-search inside all dictionaries", isOn: $model.dictionaryAutoSearch).accessibilityIdentifier("dictionaryAutoSearch")
                        Text("Independent of Reader auto-search. A matching selection opens results across enabled dictionaries. When off, use Search selected text.").font(.caption).foregroundStyle(style.secondary)
                        Text("Search prefers an enabled Japanese keyboard. Enable Japanese – Romaji in iPhone Settings → General → Keyboard → Keyboards. iOS controls the exact Japanese layout.").font(.caption).foregroundStyle(style.secondary)
                    } header: { Text("Dictionary search").textCase(nil).id("jump.Dictionary search") }
                    Section {
                        Picker("Flip the screen", selection: $flipModeRaw) {
                            ForEach(FlipMode.allCases) { Text($0.label).tag($0.rawValue) }
                        }
                        .accessibilityIdentifier("flipMode")
                        Text("For using the phone upside down on a stand while it charges. iPhones with Face ID can't turn apps upside down, so the app turns its own screen. Auto flips when you turn the phone over and flips back when you turn it upright. Always keeps it flipped. While flipped, the iPhone keyboard still appears the other way up, so turn the phone upright to type (Auto flips back for you).")
                            .font(.caption).foregroundStyle(style.secondary)
                    } header: { Text("Upside down · 倒過來").textCase(nil).id("jump.Upside down · 倒過來") }
                    Section {
                        Toggle("Two-finger tap for full screen", isOn: $immersiveGesture)
                            .accessibilityIdentifier("immersiveGesture")
                        Text("Tap anywhere with two fingers to hide the tabs, the title bar, the page buttons and the clock, so the page fills the screen. Tap with two fingers again to bring them back. Also in the ⋯ / ≡ menus of the Read, dictionary and grammar pages. With this switch off, only the menus turn full screen on, and a two-finger tap still turns it off.")
                            .font(.caption).foregroundStyle(style.secondary)
                    } header: { Text("Full screen · 全螢幕").textCase(nil).id("jump.Full screen · 全螢幕") }
                    Section {
                        Text("Your passages and notes are in reading-library.json in Files → On My iPhone → Japanese Reader. Copy this file before uninstalling. Dictionary files can also be copied from here.").font(.footnote).foregroundStyle(style.secondary)
                    } header: { Text("Keep a backup").textCase(nil).id("jump.Keep a backup") }
                    Section {
                        Text("Translate opens Apple's translation panel. Apple may ask you to download languages. Argos and LM Studio from the Windows app are not included in this iPhone edition. Copy learning prompt works with any AI app you choose.").font(.footnote).foregroundStyle(style.secondary)
                    } header: { Text("Translation").textCase(nil).id("jump.Translation") }
                    if model.busy { ProgressView("Working…") }
                    if !model.status.isEmpty { Text(model.status).font(.footnote).foregroundStyle(style.secondary) }
                    Section {
                        Text("Japanese Reader \(ReaderHome.appVersion)")
                            .font(.footnote).foregroundStyle(style.secondary)
                            .accessibilityIdentifier("appVersion")
                    }
        })
    }

    /// "2.7.3 (32)": shown at the bottom of Library, so it is easy to tell which build is installed.
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private var savedSection: some View {
        Section {
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
        } header: { Text("Saved passages · \(model.saved.count)").textCase(nil).id("jump.Saved passages") }
    }

    private var dictionariesSection: some View {
        Section {
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
        } header: { Text("Offline dictionaries · \(model.dictionaries.count)").textCase(nil).id("jump.Offline dictionaries") }
    }

    // MARK: - Appearance

    private var appearanceLink: some View {
        Section {
            NavigationLink {
                // Built only when the page is opened, not every time Library is drawn.
                LazyPage { AnyView(appearancePage) }
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

    // The page is built from five type-erased groups. As one expression its view
    // type was nested so deeply that resolving it overflowed the main thread's stack
    // on device at launch (the Library tab builds this page for its link).
    /// Section titles of Appearance, in page order (目次).
    static let appearanceSections = ["Automatic & custom", "Fable · 糸 (Claude style)", "Fable variations · 変奏", "Self-portraits · 自画像",
                                     "Editorial · 余白 (choose a paper)", "Hand-drawn · 手描き (same as desktop)", "Section button · 目次",
                                     "Going back · 翻頁", "Reading text · 本文", "Dictionary pages · 辞書"]

    private var appearancePage: some View {
      ScrollViewReader { proxy in
        List {
            Group {
                appearanceIntro
                appearanceFable
                appearanceClassic
                appearanceSectionButton
                appearancePageTurn
                appearanceReading
                appearanceDictionary
            }
            .listRowBackground(style.isYohaku ? style.background : style.surface)
        }
        .modifier(YohakuList(style: style))
        .scrollContentBackground(.hidden)
        .background(paperBackground)
        .pageTurnStackPage()
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                SectionJump(style: style, titles: Self.appearanceSections) { index in
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo("jump." + Self.appearanceSections[index], anchor: .top) }
                }
            }
        }
        .tint(accent)
        .foregroundStyle(ink)
        .preferredColorScheme(style.colorScheme)
      }
    }

    private var appearanceIntro: AnyView {
        AnyView(Group {
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
                } header: { Text("Automatic & custom").textCase(nil).id("jump.Automatic & custom") }
        })
    }

    private var appearanceFable: AnyView {
        AnyView(Group {
                Section {
                    themeGrid(ReaderTheme.fableFilm)
                } header: { Text("Fable · 糸 (Claude style)").textCase(nil).id("jump.Fable · 糸 (Claude style)") } footer: {
                    Text("The film, as drawn: cream paper, a hand-wound ring, a thread through the header, handwritten notes.")
                }
                Section {
                    themeGrid(ReaderTheme.fableVariations)
                } header: { Text("Fable variations · 変奏").textCase(nil).id("jump.Fable variations · 変奏") } footer: {
                    Text("Same hand, other pictures: a graph-paper notebook, a linocut sunset, a moon and a lit window, watercolour rain and dusk, blue biro, an echo of rings, roots on slate.")
                }
                Section {
                    themeGrid(ReaderTheme.fablePortraits)
                } header: { Text("Self-portraits · 自画像").textCase(nil).id("jump.Self-portraits · 自画像") } footer: {
                    Text("One figure, a different craft each time: sashiko stitching, marbling, cyanotype, a route map, a single line, truck-art flowers, gold-tooled leather.")
                }
        })
    }

    private var appearanceClassic: AnyView {
        AnyView(Group {
                Section { themeGrid(ReaderTheme.editorial) } header: { Text("Editorial · 余白 (choose a paper)").textCase(nil).id("jump.Editorial · 余白 (choose a paper)") }
                Section {
                    themeGrid(ReaderTheme.desk)
                    Toggle("Paper grain & doodles", isOn: $handDrawnPaper).accessibilityIdentifier("handDrawnPaper")
                } header: { Text("Hand-drawn · 手描き (same as desktop)").textCase(nil).id("jump.Hand-drawn · 手描き (same as desktop)") }
        })
    }

    private var appearanceSectionButton: AnyView {
        AnyView(Group {
                Section {
                    JumpIconPicker(style: style)
                } header: { Text("Section button · 目次").textCase(nil).id("jump.Section button · 目次") } footer: {
                    Text("The small button at the top of Library, Appearance, the 文法 list and every lesson. It opens the list of sections on that page; tap one to jump to it. Choose its drawing here.")
                }
        })
    }

    private var appearancePageTurn: AnyView {
        AnyView(Group {
                Section {
                    Toggle("Page-turn swipe back · 翻頁返回", isOn: $pageTurnBack).accessibilityIdentifier("pageTurnBack")
                } header: { Text("Going back · 翻頁").textCase(nil).id("jump.Going back · 翻頁") } footer: {
                    Text("Swiping back from the edge of the screen turns it like a page: the sheet curls under your finger and shows the screen you came from. Swipe far enough and let go to go back; let go early and the page lies down again. Works on definitions and search results, grammar lessons and this page.")
                }
        })
    }

    private var appearanceReading: AnyView {
        AnyView(Group {
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
                        Slider(value: $readerTextSize, in: 16...48, step: 1)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Line spacing")
                            Spacer()
                            Text(String(format: "%.2f×", readerLineSpacing)).foregroundStyle(style.secondary).monospacedDigit()
                        }
                        Slider(value: $readerLineSpacing, in: 1.05...2.0, step: 0.05)
                    }
                    Toggle("Ruled notebook lines · 罫線", isOn: $ruledPaper).accessibilityIdentifier("ruledPaper")
                    if ruledPaper {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Line visibility · 可見度")
                                Spacer()
                                Text("\(Int((ruleStrength * 100).rounded()))%").foregroundStyle(style.secondary).monospacedDigit()
                            }
                            Slider(value: $ruleStrength, in: 0.5...3.5, step: 0.25).accessibilityIdentifier("ruleStrength")
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Line thickness · 太さ")
                                Spacer()
                                Text(String(format: "%.2f×", ruleThickness)).foregroundStyle(style.secondary).monospacedDigit()
                            }
                            Slider(value: $ruleThickness, in: 0.5...3, step: 0.25).accessibilityIdentifier("ruleThickness")
                        }
                        Text("For the ruled lines on the Read page and in grammar lessons.").font(.caption).foregroundStyle(style.secondary)
                    }
                } header: { Text("Reading text · 本文").textCase(nil).id("jump.Reading text · 本文") }
        })
    }

    private var appearanceDictionary: AnyView {
        AnyView(Group {
                Section {
                    Picker("Page margins", selection: $pageMarginsRaw) {
                        ForEach(PageMargins.allCases) { margin in Text(margin.title).tag(margin.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("pageMargins")
                    Picker("Dictionary typeface", selection: $dictionarySans) {
                        Text("Book serif · 明朝").tag(false)
                        Text("Sans · ゴシック").tag(true)
                    }
                    .pickerStyle(.segmented)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Default definition size")
                            Spacer()
                            Text("\(Int(dictionaryTextSize)) pt").foregroundStyle(style.secondary).monospacedDigit()
                        }
                        Slider(value: $dictionaryTextSize, in: DictionaryTextSizes.range, step: 1)
                    }
                    let ownSizes = DictionaryTextSizes.decode(dictionaryTextSizes).count
                    Text(ownSizes == 0
                         ? "Each dictionary keeps its own size: swipe up or down with two fingers (or pinch) on a definition, or use ☰ → Text size. Dictionaries you have not resized use this default."
                         : (ownSizes == 1 ? "1 dictionary has its own size" : "\(ownSizes) dictionaries have their own size") + " (set with two fingers on a definition, or ☰ → Text size). The others use this default.")
                        .font(.caption).foregroundStyle(style.secondary)
                    if ownSizes > 0 {
                        Button("Use the default size for every dictionary") { dictionaryTextSizes = "" }
                            .accessibilityIdentifier("resetDictionarySizes")
                    }
                    Text("Dictionary pages keep each publisher's layout and use your theme: large headwords, muted labels, and examples as an indented phrase with the translation underneath.")
                        .font(.caption).foregroundStyle(style.secondary)
                } header: { Text("Dictionary pages · 辞書").textCase(nil).id("jump.Dictionary pages · 辞書") }
                Section {
                    Button("Reset appearance", role: .destructive) {
                        themeID = "hand-washi"; accentRGB = 0x1F7A73; paperRGB = 0xFFFFFF; customPaper = false
                        readerTypefaceRaw = ReaderTypeface.kyokasho.rawValue; readerTextSize = 23; readerLineSpacing = 1.35
                        handDrawnPaper = true; ruledPaper = true; ruleStrength = 1; ruleThickness = 1
                        pageTurnBack = false
                        dictionaryTextSize = 19; dictionaryTextSizes = ""; dictionarySans = false
                    }
                }
        })
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
    /// Left and right space inside the reading card.
    var sideInset: CGFloat = 20
    /// Ruled notebook lines and a margin line behind the text, like the desktop.
    var ruled = false
    var ruleColor: UIColor = .clear
    var ruleWidth: CGFloat = 1.5
    var marginColor: UIColor = .clear
    /// Two-finger swipe up / down to change the text size.
    var resize: TextResize? = nil
    var saveOffset: ((CGPoint) -> Void)? = nil
    let selected: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(selected) }
    static let translationKey = NSAttributedString.Key("JapaneseReaderTranslation")
    // Reading typography: comfortable line height and page margins for Japanese.
    static func styled(_ text: String, ink: UIColor, font: UIFont = .systemFont(ofSize: 23), lineSpacing: CGFloat = 1.3, ruled: Bool = false) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = lineSpacing
        paragraph.paragraphSpacing = font.pointSize * 0.5
        if ruled { paragraph.setParagraphStyle(RuledTextView.paragraph(font: font, lineSpacing: lineSpacing)) }
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: ink,
            .paragraphStyle: paragraph
        ])
    }
    /// The passage with each sentence followed by its translation in small print.
    static func interlinear(_ text: String, translations: [String], ink: UIColor, font: UIFont, lineSpacing: CGFloat, ruled: Bool = false) -> NSAttributedString {
        let pieces = PassageSegments.split(text)
        guard !translations.isEmpty, translations.count == pieces.count else {
            return styled(text, ink: ink, font: font, lineSpacing: lineSpacing, ruled: ruled)
        }
        let original = NSMutableParagraphStyle()
        original.lineHeightMultiple = lineSpacing
        original.paragraphSpacing = font.pointSize * 0.12
        let translated = NSMutableParagraphStyle()
        translated.lineHeightMultiple = 1.15
        translated.paragraphSpacing = font.pointSize * 0.75
        if ruled {
            // On ruled paper each translation line takes one ruled line too.
            original.setParagraphStyle(RuledTextView.paragraph(font: font, lineSpacing: lineSpacing))
            translated.setParagraphStyle(original)
        }
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
        let view = RuledTextView(); view.isEditable = false; view.isSelectable = true
        view.accessibilityIdentifier = "selectablePassage"
        view.font = .systemFont(ofSize: 23); view.backgroundColor = .clear; view.delegate = context.coordinator
        view.textContainerInset = UIEdgeInsets(top: 24, left: 20, bottom: 40, right: 20)
        view.alwaysBounceVertical = true
        if #available(iOS 18.0, *) { view.writingToolsBehavior = UIWritingToolsBehavior.none }
        context.coordinator.sizeSwipe.attach(to: view, scrollView: view)
        let coordinator = context.coordinator
        coordinator.reopenTap.enabled = quietMenu
        coordinator.reopenTap.attach(to: view)
        coordinator.reopenTap.tapped = { [weak view, weak coordinator] point in
            guard let view, let coordinator else { return }
            coordinator.reopen(in: view, at: point)
        }
        SelectionBridge.shared.readerView = view
        return view
    }
    /// Left inset of the text: ruled paper leaves room for the margin line.
    private var leftInset: CGFloat { ruled ? sideInset + 16 : sideInset }
    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        if let paper = view as? RuledTextView {
            paper.ruled = ruled
            paper.ruleColor = ruleColor
            paper.ruleWidth = ruleWidth
            paper.marginColor = marginColor
            paper.marginX = ruled ? max(6, sideInset - 2) : nil
        }
        coordinator.selected = selected
        coordinator.saveOffset = saveOffset
        coordinator.quietMenu = quietMenu
        coordinator.reopenTap.enabled = quietMenu
        coordinator.sizeSwipe.resize = resize
        if view.textContainerInset.left != leftInset || view.textContainerInset.right != sideInset {
            view.textContainerInset = UIEdgeInsets(top: 24, left: leftInset, bottom: 40, right: sideInset)
        }
        // Rebuilding the attributed text clears the selection, so only do it when
        // the passage, its translations or the theme's ink actually changed.
        let textChanged = coordinator.appliedText != text
        let content = translations.joined(separator: "\u{1}")
        let typography = "\(font.fontName)-\(font.pointSize)-\(lineSpacing)-\(ruled)"
        if textChanged || coordinator.appliedTranslations != content
            || coordinator.appliedInk != ink || coordinator.appliedTypography != typography {
            view.attributedText = Self.interlinear(text, translations: translations, ink: ink, font: font, lineSpacing: lineSpacing, ruled: ruled)
            coordinator.appliedText = text
            coordinator.appliedTranslations = content
            coordinator.appliedInk = ink
            coordinator.appliedTypography = typography
        }
        if textChanged {
            // The passage (possibly reopened at launch) may still be laying out, so
            // re-apply its saved place a few times unless the reader has scrolled.
            let target = initialOffset
            for delay in [0.0, 0.15, 0.4, 0.9] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak view] in
                    guard let view, !view.isTracking, !view.isDecelerating,
                          context.coordinator.appliedText == text,
                          delay == 0 || !context.coordinator.userScrolled else { return }
                    view.setContentOffset(target, animated: false)
                }
            }
            context.coordinator.userScrolled = false
        }
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
        let sizeSwipe = TextSizeSwipe()
        let reopenTap = SelectionReopenTap()
        /// A tap on the text that is still selected reopens the card for it.
        func reopen(in textView: UITextView, at point: CGPoint) {
            guard let range = textView.selectedTextRange, !range.isEmpty,
                  let word = textView.text(in: range), !word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let hit = textView.selectionRects(for: range).contains { $0.rect.width > 0 && $0.rect.insetBy(dx: -12, dy: -12).contains(point) }
            guard hit else { return }
            let selectedRange = textView.selectedRange
            if selectedRange.location < textView.attributedText.length,
               textView.attributedText.attribute(SelectableJapanese.translationKey, at: selectedRange.location, effectiveRange: nil) != nil { return }
            pending?.cancel()
            SelectionBridge.shared.readerContext = Self.context(in: textView.text ?? "", range: selectedRange, word: word)
            SelectionBridge.shared.reopenText = word
            selected(word)
        }
        /// Every selection goes to the card (short ones are looked up, long ones get
        /// Copy / Translate / Share), so the iPhone's own bar would only cover it.
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard quietMenu, range.length > 0 else { return nil }
            return UIMenu(children: [])
        }
        func scrollViewDidScroll(_ scrollView: UIScrollView) { saveOffset?(scrollView.contentOffset) }
        var userScrolled = false
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { userScrolled = true }
        var pending: DispatchWorkItem?
        init(_ selected: @escaping (String) -> Void) { self.selected = selected }
        func textViewDidChangeSelection(_ textView: UITextView) {
            pending?.cancel()
            guard let range = textView.selectedTextRange, let word = textView.text(in: range), !word.isEmpty else {
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
