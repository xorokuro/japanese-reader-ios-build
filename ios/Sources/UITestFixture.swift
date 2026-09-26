import Foundation
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
            try GrammarFixture.write(to: root.appendingPathComponent("Grammar", isDirectory: true))
        } catch { preconditionFailure("Cannot prepare isolated UI fixture: \(error)") }
        return root
    }
}
#endif

/// A small, synthetic grammar folder in the desktop layout (index page + lessons/),
/// used by the tests and the simulator fixture.
enum GrammarFixture {
    static let index = #"""
    <!DOCTYPE html><html lang="zh-Hant"><head><meta charset="UTF-8"><title>JLPT 文法總目錄</title></head>
    <body><main id="main"></main>
    <script>var LESSONS = {};</script>
    <script src="lessons/manifest.js"></script>
    <script>
    "use strict";
    const DATA = {};
    DATA["N5"]=[
    {c:"助詞",i:[
    ["〜は","提示主題或對比"],
    ["〜が（主語）","標示主語",[["N5","〜は","「は」設定主題；「が」標示主語"]]]
    ]}
    ];
    DATA["N2"]=[
    {c:"完成・貫徹",i:[
    ["〜ぬく","貫徹到底；把動作做到極致",[["N3","〜きる","「きる」做完分量；「ぬく」克服困難"]]],
    ["〜きる","全部做完",[["N2","〜ぬく","「ぬく」帶有困難與意志"]]],
    ["〜つつある","正在逐漸〜"]
    ]}
    ];
    const ORDER=["N5","N2"];
    const META={N5:"入門：基礎助詞",N2:"中高級：書面機能語"};
    const $=s=>document.querySelector(s);
    function norm(s){return String(s).replace(/（[^）]*）/g,"").replace(/[〜～\s／・()（）]/g,"").toLowerCase();}
    const NUM={};
    for(const lv of ORDER){let n=1;DATA[lv].forEach(c=>c.i.forEach(it=>{NUM[lv+"|"+it[0]]=String(n++).padStart(3,"0");}));}
    const LESSON_REVISIONS={"N2_ぬく.html":"20260927-v2"};
    const NLESSONS={};
    (function(){for(const k in LESSONS){const p=k.indexOf("|");if(p<0)continue;NLESSONS[k.slice(0,p)+"|"+norm(k.slice(p+1))]=LESSONS[k];}})();
    function lessonFile(lv,pat){return LESSONS[lv+"|"+pat]||NLESSONS[lv+"|"+norm(pat)]||null;}
    function init(){ $("#main").innerHTML="x"; window.addEventListener("scroll",()=>{}); localStorage.getItem("k"); }
    init();
    </script></body></html>
    """#

    static let manifest = #"""
    // 登記檔
    LESSONS["N5|〜は"] = "N5_は.html";
    LESSONS["N2|〜ぬく"] = "N2_ぬく.html";
    LESSONS["N2|〜きる"] = "N2_きる.html";
    """#

    static func lesson(level: String, title: String, reading: String, summary: String, link: String) -> String {
        """
        <!DOCTYPE html><html lang="zh-Hant"><head><meta charset="utf-8"><title>\(level)｜\(title)</title>
        <style>body{background:#f6f2e7;color:red}</style></head><body><div class="wrap">
        <a class="back" href="../JLPT文法總目錄N5-N1.html?q=\(title)">« 回總目錄</a>
        <header class="h"><span class="badge">\(level)</span><h1>\(title)（\(reading)）</h1>
        <div class="hsub">\(summary)</div><p class="revision-note" style="font-size:13px;color:var(--lv)">修正版｜v2</p></header>
        <section><h2>意思<small>語感核心與構造</small></h2><div class="box">
        <p>① <b>貫徹：克服困難，堅持到最後</b>。「<ruby>最後<rt>さいご</rt></ruby>までやり<ruby>抜<rt>ぬ</rt></ruby>く」。</p>
        <div class="ety"><b>構造拆解：</b>動詞連用形＋「<ruby>抜<rt>ぬ</rt></ruby>く」。</div></div></section>
        <section><h2>接續</h2><div class="setsu">動詞連用形 ＋ <b><ruby>抜<rt>ぬ</rt></ruby>く</b><span class="sn">（やります → やり<ruby>抜<rt>ぬ</rt></ruby>く）</span></div></section>
        <section><h2>例句<small>各文體語料</small></h2>
        <div class="ex"><span class="reg">日常會話</span><div class="jp"><ruby>最後<rt>さいご</rt></ruby>まで<mark>やり<ruby>抜<rt>ぬ</rt></ruby>こう</mark>よ。</div><div class="zh">堅持到最後吧。</div></div>
        <div class="ex"><span class="reg">新聞</span><div class="jp">エースは<ruby>一人<rt>ひとり</rt></ruby>で<mark><ruby>投<rt>な</rt></ruby>げ<ruby>抜<rt>ぬ</rt></ruby>いた</mark>。</div><div class="zh">王牌投手一個人投完全場。</div></div></section>
        <section><h2>類義比較</h2><div class="cmp"><span class="vs v-N3">N3</span><h3>〜きる</h3>
        <div class="pt"><b>像：</b>都能表示做到最後。<br><b>差：</b>「きる」著眼於分量。<a href="\(link)">→ 該句型詳解</a></div>
        <div class="swap"><b>互換測試：</b>「<ruby>食<rt>た</rt></ruby>べきった」。</div></div></section>
        <section><h2>常見共起表現</h2><div class="box"><div class="col"><span class="chip"><ruby>最後<rt>さいご</rt></ruby>まで〜<ruby>抜<rt>ぬ</rt></ruby>く</span><span class="chip">〜<ruby>抜<rt>ぬ</rt></ruby>いた<ruby>末<rt>すえ</rt></ruby>に</span></div></div></section>
        <section><h2>注意點</h2><div class="box"><ul><li><b>不接辭書形：</b>「× <ruby>走<rt>はし</rt></ruby>る<ruby>抜<rt>ぬ</rt></ruby>く」。</li></ul></div></section>
        <section><h2>小測驗</h2><div class="q"><div class="qt">①〔文法形式判斷〕</div>
        <div class="jp"><ruby>最後<rt>さいご</rt></ruby>まで（　　）。</div><p>1　やりかけた　　2　やり<ruby>抜<rt>ぬ</rt></ruby>いた</p>
        <details><summary>看答案與解說</summary><p><b>答案：2。</b></p></details></div></section>
        <footer>JLPT 文法詳解｜\(level)｜\(title)</footer></div><script>alert(1)</script></body></html>
        """
    }

    static func write(to root: URL) throws {
        let lessons = root.appendingPathComponent("lessons", isDirectory: true)
        try FileManager.default.createDirectory(at: lessons, withIntermediateDirectories: true)
        try index.write(to: root.appendingPathComponent("JLPT文法總目錄N5-N1.html"), atomically: true, encoding: .utf8)
        try manifest.write(to: lessons.appendingPathComponent("manifest.js"), atomically: true, encoding: .utf8)
        try lesson(level: "N2", title: "〜ぬく", reading: "〜<ruby>抜<rt>ぬ</rt></ruby>く", summary: "「〜到底／徹底地〜」", link: "N2_きる.html")
            .write(to: lessons.appendingPathComponent("N2_ぬく.html"), atomically: true, encoding: .utf8)
        try lesson(level: "N2", title: "〜きる", reading: "〜<ruby>切<rt>き</rt></ruby>る", summary: "「全部〜完」", link: "N2_ぬく.html")
            .write(to: lessons.appendingPathComponent("N2_きる.html"), atomically: true, encoding: .utf8)
        try lesson(level: "N5", title: "〜は", reading: "は", summary: "主題", link: "N2_ぬく.html")
            .write(to: lessons.appendingPathComponent("N5_は.html"), atomically: true, encoding: .utf8)
    }
}
