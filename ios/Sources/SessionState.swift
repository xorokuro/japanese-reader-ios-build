import Foundation
import CoreGraphics

/// Where the reader left off, saved when the app goes to the background and read
/// back at launch: the Read passage and its scroll, the open tab, and the whole
/// Search stack (the open definition, the pages Back returns to, the results
/// list and every page's scroll position). Definitions themselves are not stored;
/// they are re-read from the dictionary when a page is shown again.
struct SessionState: Codable {
    static let version = 1
    var version = SessionState.version
    var tab = 0
    var text = ""
    var readerOffset: CGPoint = .zero
    /// Every definition page still reachable, current or through Back.
    var pages: [SessionPage] = []
    /// The current Search stack, oldest first.
    var stack: [UUID] = []
    var showingEntry = false
    var showingLookup = false
    var word = ""
    var hits: [SessionHit] = []
    /// The result last opened from the results list, scrolled back into view.
    var anchor: SessionHit?
    /// Pages Back returns to, oldest first.
    var history: [SessionStep] = []
}

struct SessionPage: Codable {
    var id: UUID
    var hit: SessionHit
    var query: String
    var matches: [SessionHit]
    var offset: CGPoint?
}

struct SessionStep: Codable {
    var stack: [UUID]
    var page: UUID?
    var query: String
    var hits: [SessionHit]
    var showingLookup: Bool
    var anchor: SessionHit?
}

/// A dictionary hit with its folder stored relative to Documents, because the
/// app's container path changes when the app is reinstalled or updated.
struct SessionHit: Codable {
    var id: Int64
    var root: String
    var code: String
    var dictionary: String
    var word: String
    var preview: String

    init(_ hit: DictionaryHit, documents: URL) {
        id = hit.id; code = hit.code; dictionary = hit.dictionary; word = hit.word; preview = hit.preview
        root = SessionPaths.relative(hit.root, to: documents)
    }

    func hit(_ roots: SessionRoots) -> DictionaryHit {
        DictionaryHit(id: id, root: roots.resolve(root), code: code, dictionary: dictionary, word: word, preview: preview)
    }
}

enum SessionPaths {
    static func canonical(_ url: URL) -> String {
        var path = url.resolvingSymlinksInPath().standardizedFileURL.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
    static func relative(_ url: URL, to documents: URL) -> String {
        let base = canonical(documents), path = canonical(url)
        if path == base { return "." }
        if path.hasPrefix(base + "/") { return String(path.dropFirst(base.count + 1)) }
        return path
    }
}

/// Maps stored folder names back to the exact URLs the dictionary list uses, so
/// restored hits compare equal to freshly searched ones.
struct SessionRoots {
    let documents: URL
    private var known: [String: URL] = [:]

    init(documents: URL, candidates: [URL]) {
        self.documents = documents
        for url in candidates { known[SessionPaths.canonical(url)] = url }
    }

    func resolve(_ stored: String) -> URL {
        let url: URL
        if stored.hasPrefix("/") { url = URL(fileURLWithPath: stored, isDirectory: true) }
        else if stored == "." { url = documents }
        else { url = documents.appendingPathComponent(stored, isDirectory: true) }
        return known[SessionPaths.canonical(url)] ?? url
    }
}

extension SessionState {
    static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("reader-session.json")
    }

    static func load(from url: URL) -> SessionState? {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(SessionState.self, from: data),
              state.version == SessionState.version else { return nil }
        return state
    }

    func write(to url: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
