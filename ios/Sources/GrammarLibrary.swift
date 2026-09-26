import Foundation
import JavaScriptCore
import SwiftUI
import UIKit

// The JLPT grammar collection (文法): the same folder the desktop uses —
// 「JLPT文法總目錄N5-N1.html」 plus its `lessons` folder — read directly.
// The index page's own data script is run (with a stand-in for the browser),
// so the app sees exactly the entries, numbers, lesson links and 修正版 marks
// that the desktop page shows, even after the page is edited.

struct GrammarReference: Codable, Hashable {
    let level: String
    let pattern: String
    let note: String
}

struct GrammarEntry: Codable, Identifiable, Hashable {
    let level: String
    let category: String
    let pattern: String
    let meaning: String
    /// Running number within the level (001 = first), as on the desktop index.
    let number: Int
    let refs: [GrammarReference]
    /// Lesson file inside `lessons/`, when a 詳解 page is registered.
    let file: String?
    /// Revision stamp for lessons that have been corrected (修正版).
    let revision: String?

    /// Same key the desktop page uses for its 已讀 progress: "N2|〜ぬく".
    var id: String { level + "|" + pattern }
    var code: String { level + "-" + String(format: "%03d", number) }
    var hasLesson: Bool { file != nil }
    var isRevised: Bool { revision != nil }
}

struct GrammarIndex: Codable {
    let levels: [String]
    let meta: [String: String]
    let entries: [GrammarEntry]
}

enum GrammarIndexError: LocalizedError {
    case noIndexPage
    case noEntries(String)
    var errorDescription: String? {
        switch self {
        case .noIndexPage:
            return "This folder has no grammar index page. Choose the JLPT文法 folder that holds 「JLPT文法總目錄N5-N1.html」 and the lessons folder."
        case .noEntries(let detail):
            return "The grammar index page could not be read. \(detail)"
        }
    }
}

enum GrammarIndexParser {
    static let preferredIndexName = "JLPT文法總目錄N5-N1.html"

    /// The index page in `root`: the usual name, or any page that defines the DATA table.
    static func indexPage(in root: URL) -> URL? {
        let fm = FileManager.default
        let preferred = root.appendingPathComponent(preferredIndexName)
        if fm.fileExists(atPath: preferred.path) { return preferred }
        let pages = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "html" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for page in pages where page.lastPathComponent.contains("總目錄") || page.lastPathComponent.contains("总目录") {
            if let text = try? String(contentsOf: page, encoding: .utf8), text.contains("DATA[") { return page }
        }
        for page in pages {
            if let text = try? String(contentsOf: page, encoding: .utf8), text.contains("DATA[\"N") { return page }
        }
        return nil
    }

    /// Browser stand-ins: every DOM call returns a harmless object, so the page's
    /// rendering code runs to the end without touching anything.
    static let prelude = """
    var __stub=new Proxy(function(){},{get:function(t,k){if(k===Symbol.toPrimitive)return function(){return ""};if(k==="length")return 0;return __stub},apply:function(){return __stub},construct:function(){return __stub},set:function(){return true}});
    var window=__stub,document=__stub,localStorage=__stub,navigator=__stub,location=__stub,history=__stub,alert=function(){},confirm=function(){return false},prompt=function(){},setTimeout=function(){},clearTimeout=function(){},setInterval=function(){},requestAnimationFrame=function(){},URLSearchParams=function(){return {get:function(){return null}}},Blob=function(){},FileReader=function(){},URL=__stub;
    """

    /// Collects what the page computed, using its own lessonFile() matching.
    static let extract = """
    (function(){var out=[];var order=(typeof ORDER!=="undefined")?ORDER:Object.keys(DATA);
    var meta=(typeof META!=="undefined")?META:{};var revs=(typeof LESSON_REVISIONS!=="undefined")?LESSON_REVISIONS:{};
    var find=(typeof lessonFile==="function")?lessonFile:function(lv,p){return (typeof LESSONS!=="undefined"&&LESSONS[lv+"|"+p])||null};
    order.forEach(function(lv){var n=1;(DATA[lv]||[]).forEach(function(c){(c.i||[]).forEach(function(it){
    var f=null;try{f=find(lv,it[0])}catch(e){}
    out.push({level:String(lv),category:String(c.c||""),pattern:String(it[0]),meaning:String(it[1]||""),number:n++,
    refs:(it[2]||[]).map(function(r){return {level:String(r[0]),pattern:String(r[1]),note:String(r[2]||"")}}),
    file:f?String(f):null,revision:(f&&revs[f])?String(revs[f]):null})})})});
    var m={};for(var k in meta){m[k]=String(meta[k])}
    return JSON.stringify({levels:order.map(String),meta:m,entries:out})})()
    """

    static func parse(root: URL) throws -> GrammarIndex {
        guard let page = indexPage(in: root) else { throw GrammarIndexError.noIndexPage }
        let html = try String(contentsOf: page, encoding: .utf8)
        guard let context = JSContext() else { throw GrammarIndexError.noEntries("JavaScript is unavailable.") }
        var firstError: String?
        context.exceptionHandler = { _, value in
            if firstError == nil { firstError = value?.toString() }
        }
        context.evaluateScript(prelude)
        let pattern = try NSRegularExpression(pattern: "<script\\b([^>]*)>([\\s\\S]*?)</script>", options: [.caseInsensitive])
        let source = html as NSString
        for match in pattern.matches(in: html, range: NSRange(location: 0, length: source.length)) {
            let attributes = source.substring(with: match.range(at: 1))
            var code = source.substring(with: match.range(at: 2))
            if let src = scriptSource(attributes) {
                let url = page.deletingLastPathComponent().appendingPathComponent(src)
                guard let external = try? String(contentsOf: url, encoding: .utf8) else { continue }
                code = external
            }
            // A page script that stops early (for example on a browser-only call)
            // still leaves everything it defined before that point.
            context.evaluateScript(code)
        }
        context.exceptionHandler = { _, _ in }
        guard let json = context.evaluateScript(extract)?.toString(), json != "undefined",
              let data = json.data(using: .utf8) else {
            throw GrammarIndexError.noEntries(firstError ?? "")
        }
        let index = try JSONDecoder().decode(GrammarIndex.self, from: data)
        guard !index.entries.isEmpty else { throw GrammarIndexError.noEntries(firstError ?? "") }
        return index
    }

    private static func scriptSource(_ attributes: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "src\\s*=\\s*[\"']([^\"']+)[\"']", options: [.caseInsensitive]),
              let match = regex.firstMatch(in: attributes, range: NSRange(attributes.startIndex..., in: attributes)),
              let range = Range(match.range(at: 1), in: attributes) else { return nil }
        let value = String(attributes[range])
        return value.removingPercentEncoding ?? value
    }

    /// The desktop search's normalisation: drop （notes）, 〜, spaces and separators.
    static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "（[^）]*）", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[〜～\\s／・()（）]", with: "", options: .regularExpression)
            .lowercased()
    }
}

@MainActor final class GrammarStore: ObservableObject {
    enum Source: Equatable {
        case none
        case builtIn
        case imported(Date?)
    }

    @Published private(set) var index: GrammarIndex?
    @Published private(set) var source: Source = .none
    @Published private(set) var root: URL?
    @Published private(set) var learned: Set<String>
    @Published private(set) var loading = false
    @Published var busy = false
    @Published var status = ""
    /// Where each lesson was scrolled to (this session only).
    var offsets: [String: CGPoint] = [:]

    let documents: URL
    private let preferences: UserDefaults
    private let bundled: URL?
    private let queue = DispatchQueue(label: "JapaneseReader.grammar", qos: .userInitiated)
    static let learnedKey = "grammarLearned"

    var importedRoot: URL { documents.appendingPathComponent("Grammar", isDirectory: true) }
    var entries: [GrammarEntry] { index?.entries ?? [] }
    var levels: [String] { index?.levels ?? [] }

    init(documents: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0],
         preferences: UserDefaults = .standard,
         bundled: URL? = Bundle.main.url(forResource: "Grammar", withExtension: nil)) {
        self.documents = documents
        self.preferences = preferences
        self.bundled = bundled
        learned = Set(preferences.stringArray(forKey: Self.learnedKey) ?? [])
        load()
    }

    /// Imported lessons (Files → Japanese Reader → Grammar) win over the built-in set.
    func load() {
        let imported = importedRoot, bundled = bundled
        loading = true
        queue.async {
            var result: (GrammarIndex, URL, Source)?
            var failure: Error?
            if GrammarIndexParser.indexPage(in: imported) != nil {
                do {
                    let date = (try? FileManager.default.attributesOfItem(atPath: imported.path)[.modificationDate]) as? Date
                    result = (try GrammarIndexParser.parse(root: imported), imported, .imported(date))
                } catch { failure = error }
            }
            if result == nil, let bundled, let index = try? GrammarIndexParser.parse(root: bundled) {
                result = (index, bundled, .builtIn)
            }
            DispatchQueue.main.async {
                self.loading = false
                if let result {
                    self.index = result.0; self.root = result.1; self.source = result.2
                    if let failure { self.status = "Your imported lessons could not be read, so the built-in set is shown. \(failure.localizedDescription)" }
                } else {
                    self.index = nil; self.root = nil; self.source = .none
                    if let failure { self.status = failure.localizedDescription }
                }
            }
        }
    }

    // MARK: Lookup

    func entry(id: String) -> GrammarEntry? { entries.first { $0.id == id } }
    func entry(file: String) -> GrammarEntry? {
        let name = (file.removingPercentEncoding ?? file).components(separatedBy: "/").last ?? file
        let bare = name.components(separatedBy: CharacterSet(charactersIn: "?#")).first ?? name
        return entries.first { $0.file == bare }
    }
    /// A related pattern named in the index (↔ comparisons), matched like the desktop search.
    func entry(reference: GrammarReference) -> GrammarEntry? {
        let key = GrammarIndexParser.normalize(reference.pattern)
        let sameLevel = entries.filter { $0.level == reference.level }
        return sameLevel.first { $0.pattern == reference.pattern }
            ?? sameLevel.first { GrammarIndexParser.normalize($0.pattern) == key }
            ?? entries.first { GrammarIndexParser.normalize($0.pattern) == key }
    }
    func lessonURL(_ entry: GrammarEntry) -> URL? {
        guard let root, let file = entry.file else { return nil }
        let url = root.appendingPathComponent("lessons", isDirectory: true).appendingPathComponent(file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    func lessonsInLevel(of entry: GrammarEntry) -> [GrammarEntry] {
        entries.filter { $0.level == entry.level && $0.hasLesson }
    }
    func neighbour(of entry: GrammarEntry, step: Int) -> GrammarEntry? {
        let list = lessonsInLevel(of: entry)
        guard let index = list.firstIndex(where: { $0.id == entry.id }) else { return nil }
        let target = index + step
        return list.indices.contains(target) ? list[target] : nil
    }
    func search(_ query: String) -> [GrammarEntry] {
        let raw = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !raw.isEmpty else { return [] }
        let key = GrammarIndexParser.normalize(raw)
        return entries.filter { entry in
            (!key.isEmpty && GrammarIndexParser.normalize(entry.pattern).contains(key))
                || entry.meaning.lowercased().contains(raw)
                || (!key.isEmpty && GrammarIndexParser.normalize(entry.meaning).contains(key))
        }
    }

    // MARK: Progress (compatible with the desktop page's 匯出／匯入進度)

    func isLearned(_ entry: GrammarEntry) -> Bool { learned.contains(entry.id) }
    func toggleLearned(_ entry: GrammarEntry) { setLearned(entry, !isLearned(entry)) }
    func setLearned(_ entry: GrammarEntry, _ value: Bool) {
        if value { learned.insert(entry.id) } else { learned.remove(entry.id) }
        preferences.set(Array(learned).sorted(), forKey: Self.learnedKey)
    }
    func learnedCount(in list: [GrammarEntry]) -> Int { list.reduce(0) { $0 + (learned.contains($1.id) ? 1 : 0) } }
    func resetProgress() {
        learned = []
        preferences.set([String](), forKey: Self.learnedKey)
        status = "Progress cleared."
    }
    func progressExport() throws -> URL {
        let valid = Set(entries.map(\.id))
        let done = learned.filter { valid.isEmpty || valid.contains($0) }.sorted()
        let payload: [String: Any] = ["app": "JLPT文法總目錄N5-N1", "version": 1,
                                      "exported": ISO8601DateFormatter().string(from: Date()),
                                      "count": done.count, "done": done]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        let day = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("JLPT文法進度_\(day).json")
        try data.write(to: url, options: .atomic)
        return url
    }
    func importProgress(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let object = try JSONSerialization.jsonObject(with: data)
            let list = (object as? [Any]) ?? ((object as? [String: Any])?["done"] as? [Any])
            guard let keys = list?.compactMap({ $0 as? String }) else {
                status = "That file has no progress list. Choose a file made by 匯出進度 (desktop) or Export progress (here)."
                return
            }
            let valid = Set(entries.map(\.id))
            let added = keys.filter { (valid.isEmpty || valid.contains($0)) && !learned.contains($0) }
            learned.formUnion(added)
            preferences.set(Array(learned).sorted(), forKey: Self.learnedKey)
            status = "Imported progress: \(added.count) added, \(learned.count) marked in total."
        } catch {
            status = "Could not read that progress file: \(error.localizedDescription)"
        }
    }

    // MARK: Updating the lessons

    /// Copies the index page and `lessons/` from a picked JLPT文法 folder (older
    /// versions such as 修正前版本 are skipped), checks it, then replaces the old copy.
    func importFolder(_ picked: URL) {
        guard !busy else { return }
        busy = true
        status = "Copying grammar lessons…"
        let destination = importedRoot
        let documents = documents
        queue.async {
            let scoped = picked.startAccessingSecurityScopedResource()
            defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
            let fm = FileManager.default
            let staging = documents.appendingPathComponent("grammar-import-" + UUID().uuidString, isDirectory: true)
            let result = Result { () -> Int in
                var source = picked
                if GrammarIndexParser.indexPage(in: source) == nil,
                   picked.lastPathComponent.lowercased() == "lessons" {
                    source = picked.deletingLastPathComponent()
                }
                guard let page = GrammarIndexParser.indexPage(in: source) else { throw GrammarIndexError.noIndexPage }
                let lessons = source.appendingPathComponent("lessons", isDirectory: true)
                try fm.createDirectory(at: staging.appendingPathComponent("lessons", isDirectory: true), withIntermediateDirectories: true)
                try Self.coordinatedCopy(page, to: staging.appendingPathComponent(page.lastPathComponent))
                let files = (try? fm.contentsOfDirectory(at: lessons, includingPropertiesForKeys: nil)) ?? []
                var copied = 0
                for file in files where ["html", "htm", "js", "css", "png", "jpg", "jpeg", "gif", "svg", "webp"].contains(file.pathExtension.lowercased()) {
                    try Self.coordinatedCopy(file, to: staging.appendingPathComponent("lessons", isDirectory: true).appendingPathComponent(file.lastPathComponent))
                    if file.pathExtension.lowercased().hasPrefix("htm") { copied += 1 }
                }
                let index = try GrammarIndexParser.parse(root: staging)
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.moveItem(at: staging, to: destination)
                return min(copied, index.entries.filter(\.hasLesson).count)
            }
            try? fm.removeItem(at: staging)
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let count):
                    self.status = "Updated: \(count) lessons are now on this iPhone."
                    self.offsets = [:]
                    self.load()
                case .failure(let error):
                    self.status = error.localizedDescription
                }
            }
        }
    }

    func useBuiltIn() {
        try? FileManager.default.removeItem(at: importedRoot)
        status = bundled == nil ? "Imported lessons removed." : "Showing the built-in lessons."
        offsets = [:]
        load()
    }
    var hasBuiltIn: Bool { bundled != nil }

    nonisolated private static func coordinatedCopy(_ source: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { url in
            do { try FileManager.default.copyItem(at: url, to: destination) } catch { copyError = error }
        }
        if let error = coordinationError ?? copyError { throw error }
    }
}

/// Presents the iPhone share sheet from wherever the app currently is.
enum ShareSheet {
    @MainActor static func present(_ items: [Any]) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              var top = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
        while let next = top.presentedViewController { top = next }
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = top.view
        controller.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
        top.present(controller, animated: true)
    }
}
