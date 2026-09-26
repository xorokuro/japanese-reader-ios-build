"""Build a synthetic MDX fixture; run the real Swift reader on macOS CI."""
import pathlib, sqlite3, struct, subprocess, tempfile, zlib

with tempfile.TemporaryDirectory() as directory:
    root = pathlib.Path(directory)
    db = sqlite3.connect(root / 'mdict-index.sqlite3')
    db.executescript('''
        CREATE TABLE files(id INTEGER PRIMARY KEY,code TEXT,path TEXT,kind TEXT,size INTEGER,mtime INTEGER,encoding TEXT);
        CREATE TABLE blocks(file INTEGER,start INTEGER,end INTEGER,offset INTEGER,size INTEGER,PRIMARY KEY(file,start));
        CREATE TABLE records(id INTEGER PRIMARY KEY,file INTEGER,word TEXT,norm TEXT,start INTEGER,end INTEGER);
        CREATE TABLE dictionaries(code TEXT PRIMARY KEY,name TEXT,root TEXT,css TEXT);
    ''')
    db.execute('INSERT INTO dictionaries VALUES(?,?,?,?)', ('TEST', 'Synthetic test dictionary', '.', ''))
    texts = ['<p>日本語 test definition</p>', '@@@LINK=日本語', '@@@LINK=loop', '<p>second</p>']
    words = ['日本語', 'alias', 'loop', '日本語学']
    records = [t.encode() for t in texts]
    data = b''.join(records)
    # Split through the middle of a multibyte Japanese character.
    split = 5
    offset = 0
    encoded = bytearray()
    for start, end in [(0, split), (split, len(data))]:
        block = data[start:end]
        raw = struct.pack('<I', 2) + struct.pack('>I', zlib.adler32(block)) + zlib.compress(block)
        db.execute('INSERT INTO blocks VALUES(?,?,?,?,?)', (1, start, end, offset, len(raw)))
        offset += len(raw)
        encoded.extend(raw)
    (root / 'test.mdx').write_bytes(encoded)
    db.execute('INSERT INTO files VALUES(?,?,?,?,?,?,?)', (1, 'TEST', 'test.mdx', '.mdx', len(encoded), 0, 'utf-8'))
    start = 0
    for i, (word, record) in enumerate(zip(words, records), 1):
        db.execute('INSERT INTO records VALUES(?,?,?,?,?,?)', (i, 1, word, word, start, start + len(record)))
        start += len(record)
    db.execute('INSERT INTO dictionaries VALUES(?,?,?,?)', ('OTHER', 'Second dictionary', '.', ''))
    db.execute("INSERT INTO files SELECT 2,'OTHER',path,kind,size,mtime,encoding FROM files WHERE id=1")
    db.execute('INSERT INTO blocks SELECT 2,start,end,offset,size FROM blocks WHERE file=1')
    db.execute('INSERT INTO records SELECT id+10,2,word,norm,start,end FROM records WHERE file=1')
    db.commit()
    source = pathlib.Path(__file__).resolve().parent / 'Sources/DictionaryStore.swift'
    (root / 'main.swift').write_text(r'''
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let store = try DictionaryStore(root: root)
let catalog = try store.catalog()
assert(catalog.count == 2)
let ordered = try store.search("日本語", codes: ["OTHER", "TEST"])
assert(ordered.map { $0.code } == ["OTHER", "OTHER", "TEST", "TEST"])
let reverse = try store.search("日本語", codes: ["TEST", "OTHER"])
assert(reverse.map { $0.code } == ["TEST", "TEST", "OTHER", "OTHER"])
let disabled = try store.search("日本語", codes: [])
assert(disabled.isEmpty)
let enabled = try store.search("日本語", codes: ["MISSING", "TEST"])
assert(enabled.count == 2)
let hits = try store.search(" 日本語 ", codes: ["TEST"])
assert(hits.count == 2 && hits[0].word == "日本語" && hits[1].word == "日本語学")
assert(hits[0].preview == "日本語 test definition")
assert(DictionaryStore.preview("<style>hide</style><ruby>原因<rt>げんいん</rt></ruby>&nbsp;理由") == "原因 理由")
let unmatched = try store.search("unmatched", codes: ["TEST"])
assert(unmatched.isEmpty)
let exactOnly = try store.search("日本語", codes: ["TEST"], mode: .exact)
assert(exactOnly.count == 1)
let definition = try store.entry(hits[0])
assert(definition == "<p>日本語 test definition</p>")
let aliases = try store.search("alias", codes: ["TEST"])
let alias = try store.entry(aliases[0])
assert(alias == definition)
let prefix = try store.search("日本", codes: ["TEST"])
assert(prefix.count == 2)
let loops = try store.search("loop", codes: ["TEST"])
do { _ = try store.entry(loops[0]); fatalError("Circular alias accepted") } catch {}
do { _ = try store.media(code: "TEST", name: "../secret"); fatalError("Traversal accepted") } catch {}
let known = try store.contains(" 日本語 ", code: "TEST")
let partial = try store.contains("日本", code: "TEST")
let missing = try store.contains("日本語", code: "MISSING")
assert(known && !partial && !missing)
// Shared stores are reused, and cached blocks give identical entries.
let shared = try DictionaryStore.shared(root: root)
let again = try DictionaryStore.shared(root: root)
assert(shared === again)
let first = try shared.entry(hits[0])
let cached = try shared.entry(hits[0])
assert(first == definition && cached == definition)
let candidates = Deinflector.lookupCandidates("日本語を")
assert(candidates.first == "日本語を" && candidates.contains("日本語"))
assert(Deinflector.deinflect("食べました").contains("食べる") && Deinflector.deinflect("書いていた").contains("書く"))
DictionaryStore.purgeShared()
let file = root.appendingPathComponent("test.mdx")
var damaged = try Data(contentsOf: file)
damaged[4] ^= 1
try damaged.write(to: file)
// A damaged file is caught the next time it is opened.
let reopened = try DictionaryStore(root: root)
do { _ = try reopened.entry(hits[0]); fatalError("Checksum damage accepted") } catch {}
print("PASS: real Swift dictionary engine: Japanese, split blocks, exact/prefix search, aliases, circular links, traversal, corruption, caching, de-inflection")
''', encoding='utf-8')
    deinflector = source.parent / 'Deinflector.swift'
    subprocess.run(['swiftc', str(source), str(deinflector), str(root / 'main.swift'), '-o', str(root / 'test')], check=True)
    subprocess.run([str(root / 'test'), str(root)], check=True)
