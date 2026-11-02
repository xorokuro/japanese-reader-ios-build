import Foundation
import CryptoKit
import UIKit
import WebKit

// 存到手機 · Save on this phone: the whole story kept inside the app, so 物語 opens with no
// network and no website.
//
// The reader's site lists its files in `data/files.json` (encrypted like its data). Each file is
// fetched once, unlocked with the page's key (AES-GCM, as the page itself does it: "TOT1", a 12-byte
// nonce, then ciphertext and tag) and kept unlocked in Application Support, out of iCloud backups.
// `StoryFiles` serves them to the page at jpstory://story/…, where the page runs with
// `window.__storyLocal` (no key, no network, no Cache Storage). Saving again (the page's 檢查更新)
// fetches only the files whose hash changed. Nothing about the site is written in this repository:
// its address and key come from the page on the phone and are kept with the copy.

enum StoryCopyError: LocalizedError, Equatable {
    case noKey, wrongKey, badList, badPath(String), http(Int), damaged(String), space(Int64), noSite

    var errorDescription: String? {
        switch self {
        case .noKey:
            return "The page has no key yet: open it once with its whole link (#k=…). · 頁面還沒有密鑰：請先用完整的連結打開一次。"
        case .wrongKey:
            return "The page's key doesn't open the story's files. · 頁面的密鑰打不開故事檔。"
        case .badList:
            return "The story's file list couldn't be read. · 讀不到故事的檔案清單。"
        case .badPath(let path):
            return "The file list names an unexpected file (\(path)). · 檔案清單裡有不對的檔名。"
        case .http(let code):
            return "The site answered \(code). Continue tries again. · 網站回應 \(code)，按「繼續」再試一次。"
        case .damaged(let path):
            return "\(path) didn't arrive whole. Continue tries again. · 有檔案沒有完整下載，按「繼續」再試一次。"
        case .space(let need):
            return "Not enough room on this phone: about \(need / 1_000_000) MB more is needed. · 手機空間不夠，還需要約 \(need / 1_000_000) MB。"
        case .noSite:
            return "The story's link isn't kept with this copy. Remove it and save it again from the page. · 這份故事沒有記下網址，請刪除後從網頁再存一次。"
        }
    }
}

/// The page's key and its file format.
enum StoryKey {
    /// `k=` in a link's fragment, or the bare key: base64url, 32 bytes.
    static func from(_ text: String) -> SymmetricKey? {
        bytes(text).map { SymmetricKey(data: $0) }
    }

    static func bytes(_ text: String) -> Data? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let mark = value.range(of: "#") {
            let fragment = value[mark.upperBound...]
            value = fragment.split(separator: "&").first(where: { $0.hasPrefix("k=") }).map { String($0.dropFirst(2)) } ?? ""
        }
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64), data.count == 32 else { return nil }
        return data
    }

    /// "TOT1" + nonce + ciphertext + tag → the file as it was. Throws if the key is wrong or the file damaged.
    static func open(_ blob: Data, with key: SymmetricKey) throws -> Data {
        guard blob.count >= 32, blob.prefix(4).elementsEqual("TOT1".utf8) else { throw StoryCopyError.badList }
        let box = try AES.GCM.SealedBox(combined: Data(blob.dropFirst(4)))
        return try AES.GCM.open(box, using: key)
    }
}

enum StoryPath {
    /// Only plain relative paths of the reader's files (letters, digits, `. _ - /`), never `..` or a hidden name.
    static func isSafe(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count < 240, !path.hasPrefix("/"), !path.hasSuffix("/") else { return false }
        guard path.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-/".unicodeScalars.contains($0)) }) else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") }
    }
}

struct StoryFileList: Decodable {
    struct Entry: Decodable, Sendable {
        /// Path in the site, size as served, first 16 hex digits of its SHA-256, 1 if encrypted.
        let p: String
        let s: Int64
        let h: String
        let e: Int
    }
    let version: String
    let files: [Entry]
}

/// What is on the phone (copy.json next to the files).
struct StoryCopyRecord: Codable {
    var version = ""
    /// The hash of every file kept, by path.
    var hashes: [String: String] = [:]
    /// Every file of the list arrived at least once: the copy can be read.
    var complete = false
    var savedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    /// Where the copy came from and the key that opens it, for 檢查更新 (the page on the phone has neither).
    var site: String?
    var key: String?

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(String.self, forKey: .version) ?? ""
        hashes = try values.decodeIfPresent([String: String].self, forKey: .hashes) ?? [:]
        complete = try values.decodeIfPresent(Bool.self, forKey: .complete) ?? false
        savedBytes = try values.decodeIfPresent(Int64.self, forKey: .savedBytes) ?? 0
        totalBytes = try values.decodeIfPresent(Int64.self, forKey: .totalBytes) ?? 0
        site = try values.decodeIfPresent(String.self, forKey: .site)
        key = try values.decodeIfPresent(String.self, forKey: .key)
    }
}

/// The numbers of a save in progress, apart from `StoryCopy` so that only the banner redraws for each file.
@MainActor final class StoryProgress: ObservableObject {
    @Published var done: Int64 = 0
    @Published var total: Int64 = 0
}

@MainActor final class StoryCopy: ObservableObject {
    static let shared: StoryCopy = {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-story-local-fixture") { return StoryCopy.fixture() }
        if arguments.contains(where: { $0.hasPrefix("--ui-story") }) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("StoryEmpty", isDirectory: true)
            try? FileManager.default.removeItem(at: root)
            return StoryCopy(root: root)
        }
        #endif
        return StoryCopy()
    }()

    enum Phase: Equatable {
        case idle
        /// Fetching files: the first save, or bringing the copy up to date.
        case saving
        /// Paused or stopped by a problem; Continue picks up where it stopped.
        case stopped(String)
    }

    /// A whole copy is on the phone (saved once, maybe updated since): 物語 reads from it.
    @Published private(set) var complete: Bool
    /// Some files are saved, not all (a save that stopped, maybe in an earlier launch).
    @Published private(set) var partial: Bool
    @Published private(set) var phase: Phase = .idle
    /// A short word after an update (up to date, or how many files changed), shown for a moment.
    @Published var note: String?
    /// Bumped when the files on the phone change, so the page is loaded from them again.
    @Published private(set) var revision = 0
    let progress = StoryProgress()

    let root: URL
    private let configuration: URLSessionConfiguration
    /// Wait before trying a file again (tests make it short).
    var retryDelay: Double = 1.5
    private var work: Task<Void, Never>?
    private var lastRun: (site: URL, key: String, handover: (@MainActor @Sendable () async -> Void)?)?
    private var background = UIBackgroundTaskIdentifier.invalid
    private var resumeOnReturn = false
    private var activeObserver: NSObjectProtocol?

    init(root: URL = StoryCopy.defaultRoot, configuration: URLSessionConfiguration = .default) {
        self.root = root
        let config = configuration
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60
        config.waitsForConnectivity = false
        self.configuration = config
        let record = Self.readRecord(at: root)
        let readable = record.complete && FileManager.default.fileExists(atPath: root.appendingPathComponent("files/index.html").path)
        complete = readable
        partial = !readable && !record.hashes.isEmpty
        progress.done = record.savedBytes
        progress.total = record.totalBytes
        activeObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cameBack() }
        }
    }

    nonisolated static var defaultRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Story", isDirectory: true)
    }

    var files: URL { root.appendingPathComponent("files", isDirectory: true) }
    var saving: Bool { phase == .saving }
    /// A save that stopped in this launch can go on from where it was.
    var canResume: Bool { lastRun != nil }

    func record() -> StoryCopyRecord { Self.readRecord(at: root) }

    private nonisolated static func readRecord(at root: URL) -> StoryCopyRecord {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("copy.json")),
              let record = try? JSONDecoder().decode(StoryCopyRecord.self, from: data) else { return StoryCopyRecord() }
        return record
    }

    private func write(_ record: StoryCopyRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: root.appendingPathComponent("copy.json"), options: .atomic)
    }

    // MARK: Saving

    /// Saves the story from `site` (the page's folder, ending in /) with the page's key, or brings the
    /// saved copy up to date. `handover` runs once every file is in, before the tab turns to the copy.
    func save(from site: URL, key: String, handover: (@MainActor @Sendable () async -> Void)? = nil) {
        guard work == nil else { return }
        lastRun = (site, key, handover)
        resumeOnReturn = false
        note = nil
        phase = .saving
        UIApplication.shared.isIdleTimerDisabled = true
        holdBackground()
        let updating = complete
        work = Task { [weak self] in
            guard let self else { return }
            var next = Phase.idle
            do {
                let written = try await self.run(site: site, key: key)
                self.lastRun = nil
                if let handover { await handover() }
                if updating {
                    self.note = written == 0 ? "Up to date · 已是最新" : "Updated \(written) files · 已更新 \(written) 個檔案"
                    if written > 0 { self.revision += 1 }
                } else {
                    self.partial = false
                    self.complete = true
                    self.revision += 1
                }
            } catch {
                next = .stopped(Self.describe(error))
            }
            self.phase = next
            self.work = nil
            UIApplication.shared.isIdleTimerDisabled = false
            self.releaseBackground()
            if self.resumeOnReturn, UIApplication.shared.applicationState == .active { self.cameBack() }
        }
    }

    /// 檢查更新: the same save, from where the copy came from.
    func update() {
        let record = self.record()
        guard let text = record.site, let site = URL(string: text), let key = record.key else {
            phase = .stopped(StoryCopyError.noSite.errorDescription ?? "")
            return
        }
        save(from: site, key: key)
    }

    func pause() { work?.cancel() }

    /// Continue after a pause or a problem in this launch.
    func resume() {
        guard let lastRun else { return }
        save(from: lastRun.site, key: lastRun.key, handover: lastRun.handover)
    }

    /// Shows a problem found before saving could start.
    func report(_ message: String) {
        guard work == nil else { return }
        phase = .stopped(message)
    }

    func dismiss() {
        guard work == nil else { return }
        phase = .idle
        note = nil
    }

    /// Removes the saved story (the page's 刪除).
    func remove() {
        let running = work
        running?.cancel()
        Task { [weak self] in
            _ = await running?.value
            guard let self else { return }
            let fileManager = FileManager.default
            let away = self.root.deletingLastPathComponent().appendingPathComponent("Story-removed-\(UUID().uuidString)", isDirectory: true)
            let moved = (try? fileManager.moveItem(at: self.root, to: away)) != nil
            let gone = moved ? away : self.root
            self.complete = false
            self.partial = false
            self.phase = .idle
            self.note = nil
            self.lastRun = nil
            self.resumeOnReturn = false
            self.progress.done = 0
            self.progress.total = 0
            self.revision += 1
            _ = await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: gone) }.value
        }
    }

    /// The whole run: the file list, then every file missing or changed, four at a time.
    /// Returns how many files it wrote.
    @discardableResult
    func run(site: URL, key keyText: String) async throws -> Int {
        guard let keyData = StoryKey.bytes(keyText) else { throw StoryCopyError.noKey }
        let key = SymmetricKey(data: keyData)
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: files, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var rootURL = root
        try? rootURL.setResourceValues(values)

        let listBlob = try await Self.fetch("data/files.json", from: site, session: session)
        let listData: Data
        do { listData = try StoryKey.open(listBlob, with: key) } catch { throw StoryCopyError.wrongKey }
        guard let list = try? JSONDecoder().decode(StoryFileList.self, from: listData),
              list.files.contains(where: { $0.p == "index.html" }) else { throw StoryCopyError.badList }
        for entry in list.files where !StoryPath.isSafe(entry.p) || entry.s < 0 || entry.h.count != 16 {
            throw StoryCopyError.badPath(entry.p)
        }

        var record = self.record()
        let folder = files
        let needed = list.files.filter { entry in
            record.hashes[entry.p] != entry.h || !fileManager.fileExists(atPath: folder.appendingPathComponent(entry.p).path)
        }
        let total = list.files.reduce(Int64(0)) { $0 + $1.s }
        let missing = needed.reduce(Int64(0)) { $0 + $1.s }
        record.totalBytes = total
        record.savedBytes = total - missing
        progress.total = total
        progress.done = total - missing
        if missing > 0,
           let free = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           free < missing + 100_000_000 {
            throw StoryCopyError.space(missing + 100_000_000 - free)
        }

        var written = 0
        // Keeps what arrived, also when the save stops halfway.
        defer { write(record) }
        let delay = retryDelay
        try await withThrowingTaskGroup(of: StoryFileList.Entry.self) { group in
            var next = 0
            while next < min(4, needed.count) {
                let entry = needed[next]
                next += 1
                group.addTask { try await Self.keep(entry, from: site, into: folder, key: keyData, session: session, delay: delay) }
            }
            while let entry = try await group.next() {
                record.hashes[entry.p] = entry.h
                record.savedBytes += entry.s
                progress.done = record.savedBytes
                written += 1
                if written % 50 == 0 { write(record) }
                if next < needed.count {
                    let entry = needed[next]
                    next += 1
                    group.addTask { try await Self.keep(entry, from: site, into: folder, key: keyData, session: session, delay: delay) }
                }
            }
        }
        // Files the list no longer has go (a later version of the story may drop some).
        let listed = Set(list.files.map(\.p))
        for path in record.hashes.keys where !listed.contains(path) {
            try? fileManager.removeItem(at: folder.appendingPathComponent(path))
        }
        record.hashes = record.hashes.filter { listed.contains($0.key) }
        record.version = list.version
        record.complete = true
        record.savedBytes = total
        record.site = site.absoluteString
        record.key = keyText
        return written
    }

    /// One file: fetched, checked against the list, unlocked if it is encrypted, written in place.
    nonisolated static func keep(_ entry: StoryFileList.Entry, from site: URL, into folder: URL,
                                 key: Data, session: URLSession, delay: Double) async throws -> StoryFileList.Entry {
        var attempt = 0
        while true {
            do {
                let blob = try await fetch(entry.p, from: site, session: session)
                let digest = SHA256.hash(data: blob).map { String(format: "%02x", $0) }.joined()
                guard Int64(blob.count) == entry.s, digest.hasPrefix(entry.h.lowercased()) else { throw StoryCopyError.damaged(entry.p) }
                let data: Data
                if entry.e == 1 {
                    do { data = try StoryKey.open(blob, with: SymmetricKey(data: key)) } catch { throw StoryCopyError.damaged(entry.p) }
                } else {
                    data = blob
                }
                let target = folder.appendingPathComponent(entry.p)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
                return entry
            } catch {
                attempt += 1
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled || attempt >= 3 { throw error }
                try await Task.sleep(nanoseconds: UInt64(delay * Double(attempt) * 1_000_000_000))
            }
        }
    }

    nonisolated static func fetch(_ path: String, from site: URL, session: URLSession) async throws -> Data {
        guard StoryPath.isSafe(path), let url = URL(string: path, relativeTo: site)?.absoluteURL else { throw StoryCopyError.badPath(path) }
        let (data, response) = try await session.data(from: url)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw StoryCopyError.http(code) }
        return data
    }

    static func describe(_ error: Error) -> String {
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return "Paused. Continue picks up where it stopped. · 已暫停，按「繼續」會接著存。"
        }
        if let error = error as? StoryCopyError { return error.errorDescription ?? "" }
        if let error = error as? URLError {
            return "The connection stopped (\(error.localizedDescription)). Continue picks up where it stopped. · 網路中斷了，按「繼續」會從斷掉的地方接著存。"
        }
        return error.localizedDescription
    }

    // MARK: Leaving the app while saving

    /// A little time to finish when the app is left; when it runs out the save pauses and goes on
    /// by itself once the app is back.
    private func holdBackground() {
        guard background == .invalid else { return }
        background = UIApplication.shared.beginBackgroundTask(withName: "Saving the story") { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.work != nil {
                    self.resumeOnReturn = true
                    self.work?.cancel()
                }
                self.releaseBackground()
            }
        }
    }

    private func releaseBackground() {
        guard background != .invalid else { return }
        UIApplication.shared.endBackgroundTask(background)
        background = .invalid
    }

    private func cameBack() {
        guard resumeOnReturn, work == nil else { return }
        resumeOnReturn = false
        resume()
    }

    #if DEBUG
    /// Interface tests (`--ui-story-local-fixture`): a tiny saved story, in its own folder.
    static func fixture() -> StoryCopy {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StoryFixture", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        let data = root.appendingPathComponent("files/data", isDirectory: true)
        try? FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let page = """
        <!doctype html><html lang="ja"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>body{font:20px/1.8 -apple-system,sans-serif;padding:18px;background:#f6f1e6;color:#1d2a3a}</style></head>
        <body><h2 id="word">…</h2><p id="store">…</p><p>気持ちを伝えるのは、思ったより難しい。</p>
        <script>
        fetch('data/test.json').then(r => r.json()).then(j => { document.getElementById('word').textContent = j.word; })
          .catch(e => { document.getElementById('word').textContent = 'fetch failed'; });
        try {
          localStorage.setItem('fixture.check', '1');
          document.getElementById('store').textContent =
            (localStorage.getItem('fixture.check') === '1' && window.__storyLocal === true) ? 'storage ok' : 'storage missing';
        } catch (e) { document.getElementById('store').textContent = 'storage error'; }
        </script></body></html>
        """
        try? Data(page.utf8).write(to: root.appendingPathComponent("files/index.html"))
        try? Data(#"{"word":"意思"}"#.utf8).write(to: data.appendingPathComponent("test.json"))
        var record = StoryCopyRecord()
        record.version = "fixture"
        record.complete = true
        if let json = try? JSONEncoder().encode(record) { try? json.write(to: root.appendingPathComponent("copy.json")) }
        return StoryCopy(root: root)
    }
    #endif
}

/// Where the page finds the saved story: jpstory://story/… (its own folder, as on the site).
enum StoryFiles {
    static let scheme = "jpstory"
    static let home = URL(string: "jpstory://story/index.html")!

    /// The answer for one path (and maybe a byte range, as media players ask for).
    static func answer(path rawPath: String, range: String?, in folder: URL) -> (status: Int, headers: [String: String], body: Data) {
        var path = rawPath.removingPercentEncoding ?? rawPath
        while path.hasPrefix("/") { path.removeFirst() }
        if path.isEmpty { path = "index.html" }
        guard StoryPath.isSafe(path),
              let data = try? Data(contentsOf: folder.appendingPathComponent(path), options: .mappedIfSafe) else {
            return (404, ["Content-Type": "text/plain; charset=utf-8", "Content-Length": "0", "Cache-Control": "no-store"], Data())
        }
        var headers = ["Content-Type": mime(for: path), "Accept-Ranges": "bytes", "Cache-Control": "no-store"]
        if let bytes = byteRange(range, count: data.count) {
            headers["Content-Range"] = "bytes \(bytes.lowerBound)-\(bytes.upperBound)/\(data.count)"
            headers["Content-Length"] = "\(bytes.count)"
            return (206, headers, data.subdata(in: bytes.lowerBound..<(bytes.upperBound + 1)))
        }
        headers["Content-Length"] = "\(data.count)"
        return (200, headers, data)
    }

    /// "bytes=a-b", "bytes=a-" or "bytes=-n" within `count` bytes; nil for none or one that doesn't fit.
    static func byteRange(_ header: String?, count: Int) -> ClosedRange<Int>? {
        guard let header, count > 0 else { return nil }
        let text = header.trimmingCharacters(in: .whitespaces)
        guard text.lowercased().hasPrefix("bytes=") else { return nil }
        let first = text.dropFirst(6).split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        let parts = first.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty {
            guard let suffix = Int(parts[1]), suffix > 0 else { return nil }
            return max(0, count - suffix)...(count - 1)
        }
        guard let start = Int(parts[0]), start >= 0, start < count else { return nil }
        let end = parts[1].isEmpty ? count - 1 : min(Int(parts[1]) ?? -1, count - 1)
        guard end >= start else { return nil }
        return start...end
    }

    static func mime(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "js": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "webp": return "image/webp"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "m4a", "mp4": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        default: return "application/octet-stream"
        }
    }
}

/// Serves the saved story to the page (`StoryFiles`).
final class StoryFileHandler: NSObject, WKURLSchemeHandler {
    let folder: URL

    init(folder: URL) { self.folder = folder }

    // Files are small (the largest about 2.5 MB) and read in place: every task is answered before
    // this returns, so WebKit never has one to stop.
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let answer = StoryFiles.answer(path: url.path, range: urlSchemeTask.request.value(forHTTPHeaderField: "Range"), in: folder)
        guard let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers) else {
            urlSchemeTask.didFailWithError(URLError(.cannotParseResponse))
            return
        }
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(answer.body)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

/// The page's own storage (where you were, chapters read, choices, settings), kept by the app too.
/// The page on the web and the copy on the phone are different origins with separate storage, and
/// iOS may clear web storage when space runs low. So the app takes a snapshot whenever the page is
/// left, and a page that starts gets the newest snapshot unless it has that one or a newer one already
/// (`__storyAppState` holds the number of the snapshot a page's storage matches).
enum StoryState {
    static let defaultsKey = "storyPageState"
    static let marker = "__storyAppState"

    struct Snapshot: Codable, Equatable {
        let number: Int64
        let json: String
    }

    /// Run in a page: marks its storage with `number` and returns every entry but keys and tokens.
    static func captureScript(number: Int64) -> String {
        """
        (() => { try {
          localStorage.setItem('\(marker)', '\(number)');
          const out = {};
          for (let i = 0; i < localStorage.length; i++) {
            const k = localStorage.key(i);
            if (k === null || k === '\(marker)' || /key|token/i.test(k)) continue;
            out[k] = localStorage.getItem(k);
          }
          return JSON.stringify(out);
        } catch (e) { return ''; } })()
        """
    }

    /// Run as a page starts: gives it the snapshot unless its storage already matches that one or a newer one.
    static func restoreScript(_ snapshot: Snapshot) -> String {
        let base64 = Data(snapshot.json.utf8).base64EncodedString()
        return """
        (() => { try {
          if (Number(localStorage.getItem('\(marker)') || 0) >= \(snapshot.number)) return;
          const bytes = Uint8Array.from(atob('\(base64)'), c => c.charCodeAt(0));
          const data = JSON.parse(new TextDecoder().decode(bytes));
          for (const k of Object.keys(data)) {
            if (typeof data[k] === 'string' && k !== '\(marker)' && !/key|token/i.test(k)) localStorage.setItem(k, data[k]);
          }
          localStorage.setItem('\(marker)', '\(snapshot.number)');
        } catch (e) {} })();
        """
    }

    static func load(from defaults: UserDefaults = .standard) -> Snapshot? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    static func store(_ snapshot: Snapshot, in defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(snapshot) { defaults.set(data, forKey: defaultsKey) }
    }

    /// A number above every earlier one.
    static func nextNumber(after last: Int64?) -> Int64 {
        max(Int64(Date().timeIntervalSince1970 * 1000), (last ?? 0) + 1)
    }

    /// Takes a snapshot of the page in `page` (nothing if there is no page or it doesn't answer).
    @MainActor static func capture(from page: StoryPageHandle, defaults: UserDefaults = .standard) async {
        let number = nextNumber(after: load(from: defaults)?.number)
        // An empty storage (a page still opening, say) never replaces a snapshot that has something.
        guard let json = await page.run(captureScript(number: number), in: .defaultClient),
              json.hasPrefix("{"), json != "{}" else { return }
        store(Snapshot(number: number, json: json), in: defaults)
    }
}

/// The story page's web view, for the few things the tab asks it directly (its key, its storage).
@MainActor final class StoryPageHandle {
    weak var view: WKWebView?

    /// Runs `script` and returns its text, or nil (no page, an error, or no answer within 3 seconds).
    func run(_ script: String, in world: WKContentWorld) async -> String? {
        guard let view else { return nil }
        let once = Once()
        return await withCheckedContinuation { (done: CheckedContinuation<String?, Never>) in
            // The Objective-C call (WebViewBridge), as everywhere in the app: no Swift WebKit overlay.
            JPReaderEvaluateInWorld(view, script, world) { value, _ in
                if once.first() { done.resume(returning: value as? String) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if once.first() { done.resume(returning: nil) }
            }
        }
    }
}

/// True the first time only: a continuation is resumed once, by its answer or by its time running out.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func first() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}
