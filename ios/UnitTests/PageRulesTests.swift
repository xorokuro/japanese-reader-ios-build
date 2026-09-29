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
    p{width:220px;margin:0 0 14px}rt{font-size:.52em}</style></head><body>
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
        while ((n = walker.nextNode())) { if (!n.data.trim()) continue; range.selectNodeContents(n); for (const r of range.getClientRects()) rects.push(r); }
        rects.sort((a, b) => a.top - b.top);
        const own = [];
        for (const r of rects) { const l = own[own.length - 1]; if (l && r.top < l.bottom - (r.bottom - r.top) * 0.5) { l.bottom = Math.max(l.bottom, r.bottom); } else own.push({ top: r.top + scrollY, bottom: r.bottom + scrollY, ink: r.top + scrollY }); }
        for (const rt of p.querySelectorAll('rt')) { const r = rt.getBoundingClientRect(); const base = own.find(l => l.top >= r.bottom + scrollY - 4); if (base) base.ink = Math.min(base.ink, r.top + scrollY); }
        lines.push(...own);
      }
      const d = document.querySelector('#jpRules path')?.getAttribute('d') || '';
      const ys = [...d.matchAll(/M[\\d.]+ ([\\d.]+)H/g)].map(m => parseFloat(m[1]));
      return JSON.stringify({ lines, ys });
    })()
    """

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
            view.loadHTMLString(page.replacingOccurrences(of: "font:20px", with: "font:\(size)px"), baseURL: nil)
        }
        try await Task.sleep(nanoseconds: 600_000_000)
        return view
    }

    private func check(_ view: WKWebView, file: StaticString = #filePath, line: UInt = #line) async throws {
        let raw = try await view.evaluateJavaScript(probe) as? String
        let data = try XCTUnwrap(raw?.data(using: .utf8), file: file, line: line)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], file: file, line: line)
        let lines = try XCTUnwrap(object["lines"] as? [[String: Double]], file: file, line: line)
        let ys = try XCTUnwrap(object["ys"] as? [Double], file: file, line: line).sorted()
        XCTAssertGreaterThan(lines.count, 3, "The long paragraph must wrap", file: file, line: line)
        XCTAssertEqual(ys.count, lines.count, "One rule per line of text", file: file, line: line)
        let sorted = lines.sorted { ($0["top"] ?? 0) < ($1["top"] ?? 0) }
        for (index, text) in sorted.enumerated() where index < ys.count {
            let y = ys[index]
            XCTAssertGreaterThan(y, text["bottom"] ?? 0, "Rule \(index) must be below its line", file: file, line: line)
            if index + 1 < sorted.count {
                XCTAssertLessThan(y, sorted[index + 1]["ink"] ?? .infinity, "Rule \(index) must be above the next line and its furigana", file: file, line: line)
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
        _ = try await small.evaluateJavaScript("document.body.style.fontSize = '34px'; true")
        try await Task.sleep(nanoseconds: 600_000_000)
        try await check(small)
    }

    func testRulesTurnOff() async throws {
        defer { closeWindows() }
        let view = try await loadPage(size: 20)
        _ = try await view.evaluateJavaScript(PageRules.update(on: false, color: "red"), in: nil, contentWorld: DictionaryPage.selectionWorld)
        try await Task.sleep(nanoseconds: 300_000_000)
        let hidden = try await view.evaluateJavaScript("document.getElementById('jpRules').style.display") as? String
        XCTAssertEqual(hidden, "none")
    }
}
