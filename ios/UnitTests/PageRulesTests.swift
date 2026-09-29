import XCTest
import WebKit
@testable import JapaneseReader

/// Loads a small page in a real web view with the rules script and checks that
/// every line of text gets exactly one rule, and that each rule sits in the gap
/// between its line and the next one (furigana included), at two text sizes.
@MainActor final class PageRulesTests: XCTestCase {
    private final class Loaded: NSObject, WKNavigationDelegate {
        var done: (() -> Void)?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?() }
    }

    /// Kept on screen for the whole test: WebKit pauses animation frames off screen.
    private var windows: [UIWindow] = []

    private let page = """
    <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
    <style>body{margin:0;padding:12px;font:20px/1.78 -apple-system,sans-serif}
    p{width:220px;margin:0 0 14px}ruby{ruby-position:over}rt{font:500 .52em/1 sans-serif}rt::before{content:attr(data-r)}</style></head><body>
    <p id="a">これは<ruby>長<rt>なが</rt></ruby>い<ruby>文章<rt>ぶんしょう</rt></ruby>です。何行にもわたって折り返されるように、十分に長く書いておきます。まだ続きます。</p>
    <p id="b">短い行。</p>
    </body></html>
    """

    /// Lines of text (tops/bottoms of glyphs, furigana tops) and the rule y values.
    private let probe = """
    (() => {
      const lines = [];
      for (const p of document.querySelectorAll('p')) {
        const range = document.createRange(); const rects = [];
        const walker = document.createTreeWalker(p, NodeFilter.SHOW_TEXT); let n;
        while ((n = walker.nextNode())) { if (!n.data.trim() || n.parentElement.closest('rt')) continue; range.selectNodeContents(n); for (const r of range.getClientRects()) rects.push(r); }
        rects.sort((a, b) => a.top - b.top);
        const own = [];
        // Independent line count: one line per distinct baseline row of characters.
        for (const r of rects) {
          const t = r.top + scrollY, b = r.bottom + scrollY, mid = (t + b) / 2;
          const l = own.find(l => mid > l.top && mid < l.bottom);
          if (l) { l.top = Math.min(l.top, t); l.bottom = Math.max(l.bottom, b); l.ink = Math.min(l.ink, t); }
          else own.push({ top: t, bottom: b, ink: t, first: t });
        }
        own.sort((a, b) => a.top - b.top);
        for (const rt of p.querySelectorAll('rt')) {
          const r = rt.getBoundingClientRect(); const rb = r.bottom + scrollY;
          const below = own.filter(l => l.bottom > rb).sort((a, b) => Math.abs(a.first - rb) - Math.abs(b.first - rb));
          if (below.length) below[0].ink = Math.min(below[0].ink, r.top + scrollY);
        }
        lines.push(...own);
      }
      const raw = [];
      for (const p of document.querySelectorAll('p')) {
        const range = document.createRange(); const walker = document.createTreeWalker(p, NodeFilter.SHOW_TEXT); let n;
        while ((n = walker.nextNode())) { if (!n.data.trim()) continue; range.selectNodeContents(n); for (const r of range.getClientRects()) raw.push(n.data.slice(0, 2) + Math.round(r.top + scrollY) + '-' + Math.round(r.bottom + scrollY)); }
        for (const rt of p.querySelectorAll('rt')) { const r = rt.getBoundingClientRect(); raw.push('R' + Math.round(r.top + scrollY) + '-' + Math.round(r.bottom + scrollY)); }
      }
      const d = document.querySelector('#jpRules path')?.getAttribute('d') || '';
      const ys = [...d.matchAll(/M[\\d.]+ ([\\d.]+)H/g)].map(m => parseFloat(m[1]));
      return JSON.stringify({ lines, ys, raw: raw.join(' ') });
    })()
    """

    /// Runs a script through the app's own bridge (the Swift-only WebKit calls are
    /// not linked into the test bundle).
    private func run(_ script: String, in view: WKWebView) async -> Any? {
        await withCheckedContinuation { (done: CheckedContinuation<Any?, Never>) in
            DictionaryPage.evaluateSelectionScript(script, in: view) { value, _ in done.resume(returning: value) }
        }
    }

    private func loadPage(size: Int) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(WKUserScript(source: PageRules.initial(on: true, color: "rgba(0,0,0,.3)"), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: DictionaryPage.selectionWorld))
        configuration.userContentController.addUserScript(WKUserScript(source: PageRules.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: DictionaryPage.selectionWorld))
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        let window = UIWindow(frame: view.frame)
        window.addSubview(view)
        window.makeKeyAndVisible()
        windows.append(window)
        let loaded = Loaded()
        view.navigationDelegate = loaded
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            loaded.done = { done.resume() }
            // Furigana as the app prepares lessons: drawn from data-r, not text.
            let html = GrammarLessonHTML.movingReadings(page.replacingOccurrences(of: "font:20px", with: "font:\(size)px"))
            view.loadHTMLString(html, baseURL: nil)
        }
        try await waitForRules(view, after: 0)
        return view
    }

    /// Waits until the script has drawn (again) after `after` earlier drawings.
    private func waitForRules(_ view: WKWebView, after count: Int) async throws {
        for _ in 0..<50 {
            let drawn = await run("(() => { const s = document.getElementById('jpRules'); return s ? Number(s.getAttribute('data-drawn') || 0) : 0; })()", in: view) as? Int ?? 0
            // Then let the follow-up redraws (load, fonts, settle timer) finish.
            if drawn > count { try await Task.sleep(nanoseconds: 1_600_000_000); return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("The rules were never drawn")
    }
    private func drawnCount(_ view: WKWebView) async -> Int {
        await run("Number(document.getElementById('jpRules')?.getAttribute('data-drawn') || 0)", in: view) as? Int ?? 0
    }

    private func check(_ view: WKWebView, file: StaticString = #filePath, line: UInt = #line) async throws {
        let raw = await run(probe, in: view) as? String
        let data = try XCTUnwrap(raw?.data(using: .utf8), file: file, line: line)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], file: file, line: line)
        let lines = try XCTUnwrap(object["lines"] as? [[String: Double]], file: file, line: line)
        let ys = try XCTUnwrap(object["ys"] as? [Double], file: file, line: line).sorted()
        XCTAssertGreaterThan(lines.count, 3, "The long paragraph must wrap", file: file, line: line)
        let sorted = lines.sorted { ($0["top"] ?? 0) < ($1["top"] ?? 0) }
        let boxes = sorted.map { "\(Int($0["top"] ?? 0))-\(Int($0["bottom"] ?? 0))/\(Int($0["ink"] ?? 0))" }.joined(separator: " ")
        let dump = "RAW \(object["raw"] as? String ?? "") LINES \(boxes) YS \(ys.map { ($0 * 10).rounded() / 10 })"
        guard ys.count == lines.count else {
            XCTFail("One rule per line expected. " + dump, file: file, line: line)
            return
        }
        for (index, text) in sorted.enumerated() {
            let y = ys[index]
            let below = y > (text["bottom"] ?? 0)
            let above = index + 1 >= sorted.count || y < (sorted[index + 1]["ink"] ?? .infinity)
            if !below || !above {
                XCTFail("Rule \(index) is not between its line and the next. " + dump, file: file, line: line)
                return
            }
        }
    }

    private func closeWindows() {
        windows.forEach { $0.isHidden = true }
        windows = []
    }

    func testRulesSitBetweenLinesAtAnySize() async throws {
        defer { closeWindows() }
        let small = try await loadPage(size: 18)
        try await check(small)
        let large = try await loadPage(size: 30)
        try await check(large)
        // Changing the text size on a loaded page (the two-finger gesture) redraws them.
        let before = await drawnCount(small)
        _ = await run("document.body.style.fontSize = '34px'; true", in: small)
        try await waitForRules(small, after: before)
        try await check(small)
    }

    func testRulesTurnOff() async throws {
        defer { closeWindows() }
        let view = try await loadPage(size: 20)
        _ = await run(PageRules.update(on: false, color: "red"), in: view)
        try await Task.sleep(nanoseconds: 300_000_000)
        let hidden = await run("document.getElementById('jpRules').style.display", in: view) as? String
        XCTAssertEqual(hidden, "none")
    }
}
