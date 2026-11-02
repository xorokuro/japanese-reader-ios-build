import XCTest
import CryptoKit
import WebKit
@testable import JapaneseReader

/// A site kept in memory and served to the session a test's `StoryCopy` uses (https://story.invalid/site/…).
final class StubStorySite: URLProtocol {
    nonisolated(unsafe) static var files: [String: Data] = [:]
    nonisolated(unsafe) static var requested: [String] = []
    private static let lock = NSLock()

    static func reset(_ files: [String: Data]) {
        lock.lock()
        defer { lock.unlock() }
        self.files = files
        requested = []
    }

    static func asked() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "story.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let path = url.path.hasPrefix("/site/") ? String(url.path.dropFirst("/site/".count)) : url.path
        Self.lock.lock()
        Self.requested.append(path)
        let data = Self.files[path]
        Self.lock.unlock()
        let response = HTTPURLResponse(url: url, statusCode: data == nil ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// 存到手機: the site's file format, the file list, a whole save with the network stubbed, an update
/// that fetches only what changed, the file server, and the page's storage moving between the page on
/// the web and the copy (in real web views).
final class StoryCopyTests: XCTestCase {
    /// The same key and file as the site's own tools make (Python `cryptography`): key bytes 0…31,
    /// nonce bytes 0…11, "物語のテスト".
    private let keyText = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
    private let vector = "VE9UMQABAgMEBQYHCAkKC6CLf/NveyGaI6IUDVJrwY4AXg54GfAyyivDH/2zc4a8Eh4="
    private let site = URL(string: "https://story.invalid/site/")!

    func testTheKeyComesFromALinkOrOnItsOwn() {
        let bytes = Data((0..<32).map { UInt8($0) })
        XCTAssertEqual(StoryKey.bytes(keyText), bytes)
        XCTAssertEqual(StoryKey.bytes("  https://example.invalid/reader/#k=\(keyText)\n"), bytes)
        XCTAssertEqual(StoryKey.bytes("https://example.invalid/reader/#x=1&k=\(keyText)"), bytes)
        XCTAssertNil(StoryKey.bytes(""))
        XCTAssertNil(StoryKey.bytes("https://example.invalid/reader/"))
        XCTAssertNil(StoryKey.bytes(String(keyText.dropLast(4))))
        XCTAssertNil(StoryKey.bytes(keyText + "AAAA"))
        XCTAssertNil(StoryKey.bytes("not a key at all"))
    }

    func testTheSitesFilesOpenWithItsKeyOnly() throws {
        let key = try XCTUnwrap(StoryKey.from(keyText))
        let blob = try XCTUnwrap(Data(base64Encoded: vector))
        XCTAssertEqual(String(data: try StoryKey.open(blob, with: key), encoding: .utf8), "物語のテスト")
        var damaged = blob
        damaged[damaged.count - 1] ^= 1
        XCTAssertThrowsError(try StoryKey.open(damaged, with: key))
        XCTAssertThrowsError(try StoryKey.open(blob, with: SymmetricKey(size: .bits256)))
        XCTAssertThrowsError(try StoryKey.open(Data("<!doctype html><title>404</title>".utf8), with: key))
    }

    func testOnlyPlainPathsAreSavedOrServed() {
        for path in ["index.html", "data/files.json", "data/s/001.json", "data/p/001_0.bin", "img/ev_01-a.webp", "tips/t_1.webp"] {
            XCTAssertTrue(StoryPath.isSafe(path), path)
        }
        for path in ["", "/etc/passwd", "../x", "data/../x", "a//b", "a/./b", ".hidden", "data/.x", "data/", "a b", "data/%2e%2e", "物語.json", "a\\b"] {
            XCTAssertFalse(StoryPath.isSafe(path), path)
        }
    }

    func testTheFileServerAnswersWholeFilesAndRanges() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("StoryFiles-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("data"), withIntermediateDirectories: true)
        let bytes = Data((0..<100).map { UInt8($0) })
        try bytes.write(to: folder.appendingPathComponent("data/a.bin"))
        try Data("<p>page</p>".utf8).write(to: folder.appendingPathComponent("index.html"))

        let whole = StoryFiles.answer(path: "/data/a.bin", range: nil, in: folder)
        XCTAssertEqual(whole.status, 200)
        XCTAssertEqual(whole.body, bytes)
        XCTAssertEqual(whole.headers["Content-Length"], "100")
        XCTAssertEqual(whole.headers["Accept-Ranges"], "bytes")

        let part = StoryFiles.answer(path: "/data/a.bin", range: "bytes=10-19", in: folder)
        XCTAssertEqual(part.status, 206)
        XCTAssertEqual(part.body, bytes.subdata(in: 10..<20))
        XCTAssertEqual(part.headers["Content-Range"], "bytes 10-19/100")
        XCTAssertEqual(part.headers["Content-Length"], "10")
        XCTAssertEqual(StoryFiles.answer(path: "/data/a.bin", range: "bytes=90-", in: folder).body, bytes.subdata(in: 90..<100))
        XCTAssertEqual(StoryFiles.answer(path: "/data/a.bin", range: "bytes=-5", in: folder).body, bytes.subdata(in: 95..<100))
        XCTAssertEqual(StoryFiles.byteRange("bytes=0-500", count: 100), 0...99)
        XCTAssertNil(StoryFiles.byteRange("bytes=200-", count: 100))
        XCTAssertNil(StoryFiles.byteRange("bytes=9-3", count: 100))
        XCTAssertNil(StoryFiles.byteRange("items=0-1", count: 100))

        let home = StoryFiles.answer(path: "/", range: nil, in: folder)
        XCTAssertEqual(home.status, 200)
        XCTAssertEqual(home.headers["Content-Type"], "text/html; charset=utf-8")
        XCTAssertEqual(StoryFiles.answer(path: "/../index.html", range: nil, in: folder).status, 404)
        XCTAssertEqual(StoryFiles.answer(path: "/missing.json", range: nil, in: folder).status, 404)
        XCTAssertEqual(StoryFiles.mime(for: "img/a.webp"), "image/webp")
        XCTAssertEqual(StoryFiles.mime(for: "data/p/1.bin"), "application/octet-stream")
    }

    // MARK: Saving, with the site stubbed

    private func encrypt(_ data: Data, key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.seal(data, using: key)
        return Data("TOT1".utf8) + (try XCTUnwrap(box.combined))
    }

    private func hash(_ data: Data) -> String {
        String(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    /// Puts a site on the stub: index.html as it is, everything else encrypted, and the encrypted list.
    private func publish(_ plain: [String: Data], key: SymmetricKey, version: String = "1") throws -> [String: Data] {
        var served: [String: Data] = [:]
        var entries: [[String: Any]] = []
        for (path, data) in plain.sorted(by: { $0.key < $1.key }) {
            let encrypted = path != "index.html"
            let blob = encrypted ? try encrypt(data, key: key) : data
            served[path] = blob
            entries.append(["p": path, "s": blob.count, "h": hash(blob), "e": encrypted ? 1 : 0])
        }
        let list = try JSONSerialization.data(withJSONObject: ["version": version, "files": entries])
        served["data/files.json"] = try encrypt(list, key: key)
        StubStorySite.reset(served)
        return served
    }

    @MainActor private func makeCopy() -> StoryCopy {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StoryCopy-\(UUID().uuidString)", isDirectory: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubStorySite.self]
        let copy = StoryCopy(root: root, configuration: configuration)
        copy.retryDelay = 0.01
        return copy
    }

    @MainActor func testASaveKeepsEveryFileUnlockedAndAnUpdateFetchesOnlyWhatChanged() async throws {
        let key = try XCTUnwrap(StoryKey.from(keyText))
        let copy = makeCopy()
        defer { try? FileManager.default.removeItem(at: copy.root) }
        let page = Data("<!doctype html><title>story</title>".utf8)
        let scene = Data(#"{"t":"共通 01"}"#.utf8)
        let picture = Data((0..<3000).map { UInt8($0 % 251) })
        _ = try publish(["index.html": page, "data/s/001.json": scene, "img/a.webp": picture], key: key)
        XCTAssertFalse(copy.complete)

        let first = try await copy.run(site: site, key: keyText)
        XCTAssertEqual(first, 3)
        XCTAssertEqual(try Data(contentsOf: copy.files.appendingPathComponent("index.html")), page)
        XCTAssertEqual(try Data(contentsOf: copy.files.appendingPathComponent("data/s/001.json")), scene)
        XCTAssertEqual(try Data(contentsOf: copy.files.appendingPathComponent("img/a.webp")), picture)
        let record = copy.record()
        XCTAssertTrue(record.complete)
        XCTAssertEqual(record.site, site.absoluteString)
        XCTAssertEqual(record.key, keyText)
        XCTAssertEqual(copy.progress.done, copy.progress.total)
        XCTAssertEqual(try copy.root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true,
                       "The copy stays out of iCloud backups")
        XCTAssertTrue(StoryCopy(root: copy.root).complete, "A later launch reads the copy")

        // Nothing changed: only the list is fetched.
        StubStorySite.requested = []
        let unchanged = try await copy.run(site: site, key: keyText)
        XCTAssertEqual(unchanged, 0)
        XCTAssertEqual(StubStorySite.asked(), ["data/files.json"])

        // One file changed and one is gone: only the changed one is fetched, the other is removed.
        let scene2 = Data(#"{"t":"共通 01（改）"}"#.utf8)
        _ = try publish(["index.html": page, "data/s/001.json": scene2], key: key, version: "2")
        let updated = try await copy.run(site: site, key: keyText)
        XCTAssertEqual(updated, 1)
        XCTAssertEqual(StubStorySite.asked().sorted(), ["data/files.json", "data/s/001.json"])
        XCTAssertEqual(try Data(contentsOf: copy.files.appendingPathComponent("data/s/001.json")), scene2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.files.appendingPathComponent("img/a.webp").path))
        XCTAssertEqual(copy.record().version, "2")

        // A file lost on the phone is fetched again.
        try FileManager.default.removeItem(at: copy.files.appendingPathComponent("index.html"))
        StubStorySite.requested = []
        let repaired = try await copy.run(site: site, key: keyText)
        XCTAssertEqual(repaired, 1)
        XCTAssertEqual(StubStorySite.asked().sorted(), ["data/files.json", "index.html"])
    }

    @MainActor func testAWrongKeyOrADamagedFileStopsTheSave() async throws {
        let key = try XCTUnwrap(StoryKey.from(keyText))
        let copy = makeCopy()
        defer { try? FileManager.default.removeItem(at: copy.root) }
        var served = try publish(["index.html": Data("<p>x</p>".utf8), "data/a.json": Data("{}".utf8), "img/b.webp": Data(repeating: 7, count: 500)], key: key)

        let other = Data((100..<132).map { UInt8($0) }).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        do { _ = try await copy.run(site: site, key: other); XCTFail("Another key must not open the list") }
        catch { XCTAssertEqual(error as? StoryCopyError, .wrongKey) }
        do { _ = try await copy.run(site: site, key: ""); XCTFail("No key, no save") }
        catch { XCTAssertEqual(error as? StoryCopyError, .noKey) }

        var picture = try XCTUnwrap(served["img/b.webp"])
        picture[picture.count - 1] ^= 1
        served["img/b.webp"] = picture
        StubStorySite.reset(served)
        do { _ = try await copy.run(site: site, key: keyText); XCTFail("A damaged file must stop the save") }
        catch { XCTAssertEqual(error as? StoryCopyError, .damaged("img/b.webp")) }
        XCTAssertFalse(copy.record().complete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.files.appendingPathComponent("img/b.webp").path))
        XCTAssertEqual(StubStorySite.asked().filter { $0 == "img/b.webp" }.count, 3, "A damaged file is tried three times")

        served.removeValue(forKey: "data/a.json")
        StubStorySite.reset(served)
        do { _ = try await copy.run(site: site, key: keyText); XCTFail("A missing file must stop the save") }
        catch {
            let stopped = error as? StoryCopyError
            XCTAssertTrue(stopped == .http(404) || stopped == .damaged("img/b.webp"), "\(error)")
        }
        XCTAssertFalse(copy.record().complete)
    }

    // MARK: The page's storage, in real web views

    private final class Loaded: NSObject, WKNavigationDelegate {
        var done: (() -> Void)?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            done?()
            done = nil
        }
    }

    @MainActor private func load(_ address: String, store: WKWebsiteDataStore, restore: StoryState.Snapshot?) async -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        if let restore {
            configuration.userContentController.addUserScript(WKUserScript(source: StoryState.restoreScript(restore), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
        }
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: configuration)
        let loaded = Loaded()
        view.navigationDelegate = loaded
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            loaded.done = { done.resume() }
            view.loadHTMLString("<!doctype html><title>story</title><p>page</p>", baseURL: URL(string: address))
        }
        return view
    }

    @MainActor func testThePlaceReadMovesBetweenThePageOnTheWebAndTheCopy() async throws {
        let store = WKWebsiteDataStore.nonPersistent()
        let suite = "StoryStateTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let handle = StoryPageHandle()
        // The handle holds its page weakly, as the app's does: the test keeps them.
        var pages: [WKWebView] = []
        func show(_ view: WKWebView) {
            pages.append(view)
            handle.view = view
        }

        // The page on the web: read up to 025, with its key.
        show(await load("https://web.invalid/reader/", store: store, restore: nil))
        let wrote = await handle.run(#"localStorage.setItem('story.pos', '{"sid":"025"}'); localStorage.setItem('story.key', '"k"'); 'ok'"#, in: .page)
        XCTAssertEqual(wrote, "ok")
        await StoryState.capture(from: handle, defaults: defaults)
        let first = try XCTUnwrap(StoryState.load(from: defaults), "The page's storage is kept in the app")
        XCTAssertTrue(first.json.contains("story.pos"))
        XCTAssertFalse(first.json.contains("story.key"), "Keys stay with their page")

        // The copy on the phone (another origin) starts at 025, without the key.
        show(await load("https://copy.invalid/", store: store, restore: first))
        let started = await handle.run("localStorage.getItem('story.pos') || ''", in: .page)
        XCTAssertEqual(started, #"{"sid":"025"}"#)
        let noKey = await handle.run("String(localStorage.getItem('story.key'))", in: .page)
        XCTAssertEqual(noKey, "null")

        // Reading goes on in the copy; starting it again with the older snapshot keeps the newer place.
        _ = await handle.run(#"localStorage.setItem('story.pos', '{"sid":"030"}'); 'ok'"#, in: .page)
        show(await load("https://copy.invalid/", store: store, restore: first))
        let kept = await handle.run("localStorage.getItem('story.pos') || ''", in: .page)
        XCTAssertEqual(kept, #"{"sid":"030"}"#)

        // 刪除: the place goes back to the page on the web, which keeps its own key.
        await StoryState.capture(from: handle, defaults: defaults)
        let second = try XCTUnwrap(StoryState.load(from: defaults))
        XCTAssertGreaterThan(second.number, first.number)
        show(await load("https://web.invalid/reader/", store: store, restore: second))
        let back = await handle.run("localStorage.getItem('story.pos') + ' ' + localStorage.getItem('story.key')", in: .page)
        XCTAssertEqual(back, #"{"sid":"030"} "k""#)

        // A page that can't be asked gives no snapshot and changes nothing.
        handle.view = nil
        await StoryState.capture(from: handle, defaults: defaults)
        XCTAssertEqual(StoryState.load(from: defaults), second)
        XCTAssertEqual(pages.count, 4)
    }
}
