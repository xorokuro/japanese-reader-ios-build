import Foundation
import SQLite3
import zlib

struct ReaderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}
enum DictionarySearchMode: String { case prefix, exact }

struct DictionaryHit: Identifiable, Equatable {
    let id: Int64
    let root: URL
    var identity: String { root.path + "/" + code + "/" + String(id) }
    let code: String
    let dictionary: String
    let word: String
    var preview: String = ""
}

// One open connection per dictionary folder, shared by every lookup. Opening the
// SQLite index, re-reading the catalog and re-inflating the same compressed block
// for every keystroke was the main source of lag, so all of that is cached here.
// Each store serialises its own work with a lock: it is used from the model's
// dictionary queue and from WebKit's media loader.
final class DictionaryStore {
    let root: URL
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var catalogCache: [[String: String]]?
    private var mdxFiles: [String: String] = [:]
    private var missingMdx = Set<String>()
    private var fileRows: [String: [String: String]] = [:]
    private var handles: [String: FileHandle] = [:]
    private var stylesheets: [String: String] = [:]
    private var previews: [String: String] = [:]
    private var blockCache: [String: Data] = [:]
    private var blockOrder: [String] = []
    private var blockBytes = 0
    private static let blockBudget = 24 * 1024 * 1024

    private static let sharedLock = NSLock()
    private static var sharedStores: [String: DictionaryStore] = [:]

    /// A long-lived store for lookups. Use `init` for one-off validation of a folder.
    static func shared(root: URL) throws -> DictionaryStore {
        let key = root.standardizedFileURL.path
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if let store = sharedStores[key] { return store }
        let store = try DictionaryStore(root: root)
        sharedStores[key] = store
        return store
    }

    /// Forget every open store, e.g. after dictionaries were added or moved.
    static func purgeShared() {
        sharedLock.lock()
        sharedStores.removeAll()
        sharedLock.unlock()
    }

    init(root: URL) throws {
        self.root = root.standardizedFileURL
        guard sqlite3_open_v2(root.appendingPathComponent("mdict-index.sqlite3").path,
            &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if db != nil { sqlite3_close(db); db = nil }
            throw ReaderError("Add the dictionaries folder in Library first.")
        }
    }
    deinit {
        for handle in handles.values { try? handle.close() }
        sqlite3_close(db)
    }
    private func query(_ sql: String, _ args: [String] = []) throws -> [[String: String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ReaderError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in args.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        var result: [[String: String]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw ReaderError(String(cString: sqlite3_errmsg(db))) }
            var row: [String: String] = [:]
            for i in 0..<sqlite3_column_count(statement) {
                if let value = sqlite3_column_text(statement, i) {
                    row[String(cString: sqlite3_column_name(statement, i))] = String(cString: value)
                }
            }
            result.append(row)
        }
    }
    static func normalize(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    func catalog() throws -> [[String: String]] {
        lock.lock(); defer { lock.unlock() }
        if let cached = catalogCache { return cached }
        let rows = try query("SELECT * FROM dictionaries ORDER BY rowid")
        catalogCache = rows
        return rows
    }
    private func mdxFile(_ code: String) throws -> String? {
        if let file = mdxFiles[code] { return file }
        if missingMdx.contains(code) { return nil }
        guard let file = try query("SELECT id FROM files WHERE code=? AND kind='.mdx'", [code]).first?["id"] else {
            missingMdx.insert(code)
            return nil
        }
        mdxFiles[code] = file
        return file
    }
    func validateFiles() throws {
        lock.lock(); defer { lock.unlock() }
        for file in try query("SELECT path,size FROM files") {
            let url = try path(file["path"]!)
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
            guard size?.int64Value == Int64(file["size"]!) else { throw ReaderError("Dictionary file is incomplete: \(url.lastPathComponent)") }
        }
    }
    func media(code: String, name: String) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let clean = name.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !clean.contains(":"), !clean.split(separator: "/").contains(".."), clean.count < 601 else { throw ReaderError("Invalid media path.") }
        if let dictionary = try catalog().first(where: { $0["code"] == code }), let folder = dictionary["root"] {
            let loose = try path(folder + "/" + clean)
            if FileManager.default.fileExists(atPath: loose.path) { return try Data(contentsOf: loose) }
        }
        guard let row = try query("SELECT r.* FROM files f JOIN records r ON r.file=f.id WHERE f.code=? AND f.kind='.mdd' AND r.norm=? ORDER BY f.id LIMIT 1", [code, clean.lowercased()]).first else { throw ReaderError("Media was not included in this dictionary.") }
        return try read(row).0
    }
    func stylesheet(code: String) throws -> String {
        lock.lock(); defer { lock.unlock() }
        if let cached = stylesheets[code] { return cached }
        guard let dictionary = try catalog().first(where: { $0["code"] == code }), let folder = dictionary["root"], let css = dictionary["css"], !css.isEmpty else {
            stylesheets[code] = ""
            return ""
        }
        let text = (try? String(contentsOf: path(folder + "/" + css), encoding: .utf8)) ?? ""
        stylesheets[code] = text
        return text
    }
    /// True when a headword with exactly this spelling exists. Cheap: no entry is read.
    func contains(_ word: String, code: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        let key = Self.normalize(word)
        guard !key.isEmpty, let file = try mdxFile(code) else { return false }
        let rows = try query("SELECT id FROM records WHERE file=? AND norm=? LIMIT 1", [file, key])
        return !rows.isEmpty
    }
    func search(_ word: String, codes: [String]? = nil, mode: DictionarySearchMode = .prefix) throws -> [DictionaryHit] {
        lock.lock(); defer { lock.unlock() }
        let key = Self.normalize(word)
        guard !key.isEmpty else { return [] }
        var hits: [DictionaryHit] = []
        let available = try catalog()
        let ordered = codes.map { order in order.compactMap { code in available.first { $0["code"] == code } } } ?? available
        for dictionary in ordered {
            guard let code = dictionary["code"], let file = try mdxFile(code) else { continue }
            let rows = try query("SELECT id,word FROM records WHERE file=? AND norm=? LIMIT 30", [file, key])
            let prefix = mode == .prefix ? try query("SELECT id,word FROM records WHERE file=? AND norm>? AND norm<? ORDER BY norm,id LIMIT 12", [file, key, key + "\u{10ffff}"]) : []
            for row in rows + prefix {
                guard let idText = row["id"], let id = Int64(idText), let headword = row["word"] else { continue }
                var hit = DictionaryHit(id: id, root: root, code: code, dictionary: dictionary["name"] ?? code, word: headword)
                // A missing preview must never hide an otherwise usable match.
                hit.preview = cachedPreview(hit)
                hits.append(hit)
            }
        }
        return hits
    }
    private func cachedPreview(_ hit: DictionaryHit) -> String {
        let key = hit.code + "/" + String(hit.id)
        if let cached = previews[key] { return cached }
        let value = (try? entry(hit)).map { Self.preview($0) } ?? ""
        if previews.count > 6000 { previews.removeAll(keepingCapacity: true) }
        previews[key] = value
        return value
    }
    static func preview(_ html: String) -> String {
        let clean = html.replacingOccurrences(of: "(?is)<(script|style|rt)\\b[^>]*>.*?</\\1>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(clean.prefix(160))
    }
    private func path(_ relative: String) throws -> URL {
        guard !relative.contains(":"), !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { throw ReaderError("Unsafe dictionary path.") }
        let value = root.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        guard value.path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw ReaderError("Dictionary path is outside its folder.") }
        return value
    }
    private func fileRow(_ id: String) throws -> [String: String] {
        if let cached = fileRows[id] { return cached }
        guard let row = try query("SELECT * FROM files WHERE id=?", [id]).first else { throw ReaderError("Missing dictionary source.") }
        fileRows[id] = row
        return row
    }
    /// Opens (and size-checks) each dictionary file once, then keeps it open.
    private func openHandle(for file: [String: String]) throws -> FileHandle {
        guard let relative = file["path"], let sizeText = file["size"], let expected = Int64(sizeText) else { throw ReaderError("Missing dictionary source.") }
        if let open = handles[relative] { return open }
        let url = try path(relative)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == expected else { throw ReaderError("Dictionary file is incomplete: \(url.lastPathComponent)") }
        let handle = try FileHandle(forReadingFrom: url)
        handles[relative] = handle
        return handle
    }
    private func decodedBlock(_ block: [String: String], fileID: String, handle: FileHandle) throws -> Data {
        let blockStart = Int64(block["start"]!)!, blockEnd = Int64(block["end"]!)!
        let key = fileID + ":" + String(blockStart)
        if let cached = blockCache[key] { return cached }
        let expected = Int(blockEnd - blockStart), count = Int(block["size"]!)!
        guard expected >= 0, expected <= 128 * 1024 * 1024, count >= 8, count <= 128 * 1024 * 1024 else { throw ReaderError("Invalid dictionary block size.") }
        try handle.seek(toOffset: UInt64(block["offset"]!)!)
        guard let raw = try handle.read(upToCount: count), raw.count == count else { throw ReaderError("Incomplete dictionary block.") }
        let bytes = [UInt8](raw.prefix(8))
        let mode = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        let checksum = UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7])
        var decoded: Data
        if mode == 0 { decoded = Data(raw.dropFirst(8)) }
        else if mode == 2 {
            decoded = Data(count: expected)
            var length = uLongf(expected)
            let status = decoded.withUnsafeMutableBytes { output in
                raw.withUnsafeBytes { input in
                    uncompress(output.bindMemory(to: Bytef.self).baseAddress!, &length,
                        input.bindMemory(to: Bytef.self).baseAddress!.advanced(by: 8), uLong(raw.count - 8))
                }
            }
            guard status == Z_OK, length == expected else { throw ReaderError("Cannot decompress dictionary block.") }
        } else { throw ReaderError("Unsupported dictionary compression.") }
        let actual = decoded.withUnsafeBytes { adler32(1, $0.bindMemory(to: Bytef.self).baseAddress, uInt(decoded.count)) }
        guard decoded.count == expected, UInt32(actual) == checksum else { throw ReaderError("Dictionary block failed its integrity check.") }
        blockCache[key] = decoded
        blockOrder.append(key)
        blockBytes += decoded.count
        while blockBytes > Self.blockBudget, blockOrder.count > 1 {
            let oldest = blockOrder.removeFirst()
            blockBytes -= blockCache.removeValue(forKey: oldest)?.count ?? 0
        }
        return decoded
    }
    private func read(_ row: [String: String]) throws -> (Data, String) {
        let fileID = row["file"]!
        let file = try fileRow(fileID)
        let handle = try openHandle(for: file)
        let start = Int64(row["start"]!)!, end = Int64(row["end"]!)!
        guard end >= start, end - start < 128 * 1024 * 1024 else { throw ReaderError("Dictionary entry is too large.") }
        var result = Data()
        for block in try query("SELECT * FROM blocks WHERE file=? AND start<? AND end>? ORDER BY start", [fileID, String(end), String(start)]) {
            let blockStart = Int64(block["start"]!)!
            let decoded = try decodedBlock(block, fileID: fileID, handle: handle)
            let expected = Int64(decoded.count)
            let from = Int(max(0, start - blockStart)), to = Int(min(expected, end - blockStart))
            guard from <= to else { continue }
            result.append(decoded.subdata(in: from..<to))
        }
        guard result.count == end - start else { throw ReaderError("Incomplete dictionary entry.") }
        return (result, file["encoding"] ?? "utf-8")
    }
    func entry(_ hit: DictionaryHit) throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard let file = try mdxFile(hit.code) else { throw ReaderError("Unknown dictionary.") }
        var rows = try query("SELECT * FROM records WHERE id=? AND file=?", [String(hit.id), file])
        var visited = Set<String>()
        for _ in 0..<12 {
            guard let row = rows.first, visited.insert(row["id"]!).inserted else { throw ReaderError("Missing or circular dictionary link.") }
            let (data, encoding) = try read(row)
            let decoder: String.Encoding = encoding.lowercased().contains("utf-16") ? .utf16LittleEndian : .utf8
            guard let text = String(data: data, encoding: decoder)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0\r\n ")) else { throw ReaderError("Cannot decode this dictionary entry.") }
            if !text.hasPrefix("@@@LINK=") { return text }
            let key = Self.normalize(String(text.dropFirst(8)))
            rows = try query("SELECT * FROM records WHERE file=? AND norm=? LIMIT 1", [file, key])
        }
        throw ReaderError("Dictionary link is too deep.")
    }
}
