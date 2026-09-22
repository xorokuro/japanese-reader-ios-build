#if DEBUG
import Foundation
import SQLite3
import zlib

// Opt-in simulator fixture only; never touches the user's library or dictionaries.
enum UITestFixture {
    static func documents() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReaderUITest-" + UUID().uuidString)
        let folder = root.appendingPathComponent("dictionaries")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let bodies = [
                "<h2>みほん【見本】</h2><p>sample</p><p><a href='entry://実物'>実物</a>の見本</p>",
                "<h2>みほんいち【見本市】</h2><p>trade fair</p>",
                "<h2>じつぶつ【実物】</h2><p>the real thing</p><p><a href='entry://製品'>製品</a></p>",
                "<h2>せいひん【製品】</h2><p>product</p>"
            ]
            let words = ["みほん", "みほんいち", "実物", "製品"]
            let bytes = bodies.map { Data($0.utf8) }
            var body = Data(); bytes.forEach { body.append($0) }
            let checksum = body.withUnsafeBytes { adler32(1, $0.bindMemory(to: Bytef.self).baseAddress, uInt(body.count)) }
            var source = Data([0, 0, 0, 0, UInt8((checksum >> 24) & 255), UInt8((checksum >> 16) & 255), UInt8((checksum >> 8) & 255), UInt8(checksum & 255)])
            source.append(body)
            try source.write(to: folder.appendingPathComponent("fixture.mdx"))
            var db: OpaquePointer?
            guard sqlite3_open(folder.appendingPathComponent("mdict-index.sqlite3").path, &db) == SQLITE_OK else { return root }
            defer { sqlite3_close(db) }
            func sql(_ statement: String) { precondition(sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK) }
            sql("CREATE TABLE dictionaries(code TEXT,name TEXT,root TEXT,css TEXT)")
            sql("CREATE TABLE files(id INTEGER,code TEXT,path TEXT,kind TEXT,size INTEGER,encoding TEXT)")
            sql("CREATE TABLE records(id INTEGER,file INTEGER,word TEXT,norm TEXT,start INTEGER,end INTEGER)")
            sql("CREATE TABLE blocks(file INTEGER,start INTEGER,end INTEGER,offset INTEGER,size INTEGER)")
            for (file, code, name) in [(1, "DEMO_A", "Demo Japanese"), (2, "DEMO_B", "Demo English–Japanese")] {
                sql("INSERT INTO dictionaries VALUES('\(code)','\(name)','.','')")
                sql("INSERT INTO files VALUES(\(file),'\(code)','fixture.mdx','.mdx',\(source.count),'utf-8')")
                sql("INSERT INTO blocks VALUES(\(file),0,\(body.count),0,\(source.count))")
                var start = 0
                for i in words.indices {
                    sql("INSERT INTO records VALUES(\(file * 10 + i),\(file),'\(words[i])','\(words[i])',\(start),\(start + bytes[i].count))")
                    start += bytes[i].count
                }
            }
        } catch { preconditionFailure("Cannot prepare isolated UI fixture: \(error)") }
        return root
    }
}
#endif
