import XCTest
import WebKit
@testable import JapaneseReader

@MainActor final class SelectionTests: XCTestCase {
    private func evaluate(_ script: String, in view: WKWebView) async throws -> Any? {
        // Use the Objective-C completion API: the runner's iOS runtime does not
        // include the newer libswiftWebKit async overlay. Both worlds share DOM.
        try await withCheckedThrowingContinuation { continuation in
            var completed = false
            let timeout = DispatchWorkItem {
                guard !completed else { return }
                completed = true
                continuation.resume(throwing: NSError(domain: "SelectionTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "WebKit evaluation timed out"]))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
            DictionaryPage.evaluateSelectionScript(script, in: view) { value, error in
                guard !completed else { return }
                completed = true; timeout.cancel()
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value) }
            }
        }
    }
    private func host(_ view: UIView) -> UIWindow {
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            window = UIWindow(windowScene: scene)
        } else { window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844)) }
        let controller = UIViewController()
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller
        view.frame = CGRect(x: 0, y: 80, width: 390, height: 500)
        controller.view.addSubview(view)
        window.makeKeyAndVisible()
        return window
    }
    func testPassageSelectionSurvivesLookupAndCanBeAdjusted() async throws {
        let model = ReaderModel()
        let view = UITextView()
        view.isEditable = false; view.isSelectable = true
        view.text = "日本語の勉強"
        let window = host(view)
        defer { window.isHidden = true }
        let first = expectation(description: "first selection searched")
        let second = expectation(description: "adjusted selection searched")
        var calls = 0
        let coordinator = SelectableJapanese.Coordinator { word in
            guard !word.isEmpty else { return }
            model.searchSelection(word)
            calls += 1
            if calls == 1 { first.fulfill() } else if calls == 2 { second.fulfill() }
        }
        view.delegate = coordinator
        XCTAssertTrue(view.becomeFirstResponder())
        view.selectedRange = NSRange(location: 0, length: 2)
        coordinator.textViewDidChangeSelection(view)
        await fulfillment(of: [first], timeout: 5)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(model.word, "日本")
        XCTAssertTrue(view.isFirstResponder)
        XCTAssertEqual(view.selectedRange, NSRange(location: 0, length: 2))
        view.selectedRange = NSRange(location: 0, length: 3)
        coordinator.textViewDidChangeSelection(view)
        await fulfillment(of: [second], timeout: 5)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(model.word, "日本語")
        XCTAssertTrue(view.isFirstResponder)
        XCTAssertEqual(view.selectedRange, NSRange(location: 0, length: 3))
    }
    func testDictionarySelectionBridgeKeepsRangeAndPage() async throws {
        let model = ReaderModel()
        model.showingEntry = true
        let first = expectation(description: "dictionary selection searched")
        let second = expectation(description: "dictionary range adjusted")
        var calls = 0
        let coordinator = DictionaryPage.Coordinator(root: model.dictionaryRoot, code: "TEST") { word in
            guard !word.isEmpty else { return }
            model.searchSelection(word)
            calls += 1
            if calls == 1 { first.fulfill() } else if calls == 2 { second.fulfill() }
        }
        let html = DictionaryPage.make(body: "<p id='passage'>日本語の勉強</p><p id='unsafe' onclick=\"document.body.dataset.unsafe='yes'\">unsafe</p>", css: "", code: "TEST")
        let view = DictionaryPage.makeWebView(html: html, coordinator: coordinator)
        let window = host(view)
        defer {
            view.configuration.userContentController.removeScriptMessageHandler(forName: "readerSelection", contentWorld: DictionaryPage.selectionWorld)
            window.isHidden = true
        }
        // A cold WebKit process on a hosted simulator can take over ten seconds.
        for _ in 0..<600 {
            if !view.isLoading && view.url != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(view.isLoading, "Dictionary document must finish loading before selecting text")
        XCTAssertFalse(view.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        let select = "const r=document.createRange(); const n=document.getElementById('passage').firstChild; r.setStart(n,0); r.setEnd(n,END); const s=window.getSelection(); s.removeAllRanges(); s.addRange(r);"
        _ = try await evaluate("(() => {" + select.replacingOccurrences(of: "END", with: "2") + "return true;})()", in: view)
        await fulfillment(of: [first], timeout: 5)
        try await Task.sleep(nanoseconds: 300_000_000)
        var selected = try await evaluate("window.getSelection().toString()", in: view)
        XCTAssertEqual(selected as? String, "日本")
        XCTAssertEqual(model.word, "日本")
        XCTAssertTrue(model.showingEntry)
        _ = try await evaluate("(() => {" + select.replacingOccurrences(of: "END", with: "3") + "return true;})()", in: view)
        await fulfillment(of: [second], timeout: 5)
        selected = try await evaluate("window.getSelection().toString()", in: view)
        XCTAssertEqual(selected as? String, "日本語")
        XCTAssertEqual(model.word, "日本語")
        XCTAssertTrue(model.showingEntry)
        let unsafe = try await evaluate("document.getElementById('unsafe').click(); document.body.dataset.unsafe || 'blocked'", in: view)
        XCTAssertEqual(unsafe as? String, "blocked")
    }
    /// Takoboto-style hanging indents stay on the page at Compact margins, and a
    /// tap on a selection that has lost its card posts it again for the card.
    func testHangingIndentsStayOnPageAndLeftoverSelectionReposts() async throws {
        let posted = expectation(description: "selection posted again")
        posted.assertForOverFulfill = false
        var words: [String] = []
        let coordinator = DictionaryPage.Coordinator(root: FileManager.default.temporaryDirectory, code: "TEST") { word in
            guard !word.isEmpty else { return }
            words.append(word)
            if SelectionBridge.shared.reopenText == word { posted.fulfill() }
        }
        coordinator.margins = .compact
        let css = ".def2{text-indent:-2em;padding-left:3em}.read{display:block;font-size:1.3em;text-indent:-1em;padding-left:1em}.dfen{display:block}"
        let body = "<div class='tkbt-entry'><div class='read'>まぎわ magiwa</div><div class='def2'><span class='dfen'><span class='dfcn' id='cn'>之前的那个点,做的那个点,即将发生的那个点</span>the point just before</span></div></div>"
        let view = DictionaryPage.makeWebView(html: DictionaryPage.make(body: body, css: css, code: "TEST"), coordinator: coordinator)
        let window = host(view)
        defer {
            view.configuration.userContentController.removeScriptMessageHandler(forName: "readerSelection", contentWorld: DictionaryPage.selectionWorld)
            window.isHidden = true
            SelectionBridge.shared.reopenText = nil
        }
        for _ in 0..<600 {
            if !view.isLoading && view.url != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        _ = try await evaluate("window.__jpIndent(0.4)", in: view)
        let offPage = try await evaluate("""
        (() => { const edge = document.body.getBoundingClientRect().left + parseFloat(getComputedStyle(document.body).paddingLeft);
          let worst = 0; const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT); let node;
          while ((node = walker.nextNode())) { if (!node.data.trim()) continue; const range = document.createRange(); range.selectNodeContents(node);
            for (const rect of range.getClientRects()) worst = Math.max(worst, edge - rect.left); }
          return worst; })()
        """, in: view)
        XCTAssertLessThanOrEqual((offPage as? Double) ?? 0, 0.5, "No line may start left of the page padding")
        _ = try await evaluate("(() => { const n = document.getElementById('cn').firstChild; const r = document.createRange(); r.setStart(n, 0); r.setEnd(n, 5); const s = getSelection(); s.removeAllRanges(); s.addRange(r); return true; })()", in: view)
        try await Task.sleep(nanoseconds: 600_000_000)
        let missed = try await evaluate("window.__jpRepost(2, 2000)", in: view)
        XCTAssertEqual(missed as? Bool, false)
        let hit = try await evaluate("(() => { const q = getSelection().getRangeAt(0).getClientRects()[0]; return window.__jpRepost(q.left + q.width / 2 + scrollX, q.top + q.height / 2 + scrollY); })()", in: view)
        XCTAssertEqual(hit as? Bool, true)
        await fulfillment(of: [posted], timeout: 5)
        XCTAssertEqual(words.last, "之前的那个")
    }

    /// Nested publisher indents (entry > sense > examples) may not push the examples
    /// to the right: every line starts within a small share of the page width, at
    /// large text sizes too. Padding that holds a sense number is kept.
    func testNestedIndentsStayWithinTheBudget() async throws {
        let coordinator = DictionaryPage.Coordinator(root: FileManager.default.temporaryDirectory, code: "TEST") { _ in }
        coordinator.margins = .compact
        coordinator.textSize = 30
        let css = ".w{margin-left:3em}.s{padding-left:2.5em}.ex{margin-left:4em}.tr{margin-left:1.5em}dd{margin-left:40px}"
            + ".n{position:relative;padding-left:2.2em}.n::before{content:'1';position:absolute;left:0}.h{text-indent:-2em;padding-left:3em}"
        let body = "<div class='w'><div class='s'><p id='def'>definition of the word</p><div class='ex'><p>彼らは森の中で道に迷った</p>"
            + "<p class='tr'>They got lost in the woods.</p></div><dl><dd>dd text</dd></dl><div class='h'>hanging sense text that wraps onto a second line for sure, yes</div></div>"
            + "<div class='n' id='num'>numbered sense</div></div>"
        let view = DictionaryPage.makeWebView(html: DictionaryPage.make(body: body, css: css, code: "TEST"), coordinator: coordinator)
        let window = host(view)
        defer {
            view.configuration.userContentController.removeScriptMessageHandler(forName: "readerSelection", contentWorld: DictionaryPage.selectionWorld)
            window.isHidden = true
        }
        for _ in 0..<600 {
            if !view.isLoading && view.url != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let measure = """
        (() => { const edge = document.body.getBoundingClientRect().left + parseFloat(getComputedStyle(document.body).paddingLeft);
          let right = 0, leftOf = 0; const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT); let node;
          while ((node = walker.nextNode())) { if (!node.data.trim() || node.parentElement.closest('#num')) continue; const range = document.createRange(); range.selectNodeContents(node);
            const first = range.getClientRects()[0]; if (first) { right = Math.max(right, first.left - edge); leftOf = Math.max(leftOf, edge - first.left); } }
          const def = document.getElementById('def').getBoundingClientRect().left - edge;
          return JSON.stringify({ right, leftOf, def, width: innerWidth, number: parseFloat(getComputedStyle(document.getElementById('num')).paddingLeft) }); })()
        """
        for scale in [0.4, 1.0] {
            _ = try await evaluate("window.__jpIndent(\(scale))", in: view)
            let raw = try await evaluate(measure, in: view) as? String
            let data = try XCTUnwrap(raw?.data(using: .utf8))
            let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Double])
            let width = result["width"] ?? 390
            let budget = width * (scale < 0.5 ? 0.03 : 0.06)
            XCTAssertLessThanOrEqual(result["right"] ?? 999, budget + 1, "Indents add up to at most the budget at scale \(scale): \(result)")
            XCTAssertLessThanOrEqual(result["leftOf"] ?? 999, 0.5, "Nothing starts left of the page padding: \(result)")
            XCTAssertGreaterThan(result["number"] ?? 0, 8, "Padding that holds a sense number is kept: \(result)")
            XCTAssertLessThanOrEqual(abs(result["def"] ?? 999), 1, "The entry's own outer inset is removed: its text starts at the page edge: \(result)")
        }
    }

    /// The NHK accent box is a flex row (kana, pitch mark, play button). The fit must
    /// leave its pieces where the row put them: the mark stays after the kana.
    func testAccentRowIsNotPulledApart() async throws {
        let coordinator = DictionaryPage.Coordinator(root: FileManager.default.temporaryDirectory, code: "TEST") { _ in }
        coordinator.margins = .wide
        coordinator.textSize = 30
        let css = "accent{display:block;padding:.6em 1.2em}accent_text{padding-left:1.5em}symbol_macron{margin-left:-1em}.body{margin-left:1.5em}"
        let body = "<dic-item><div class='head'><headword>ほうび</headword></div><div class='body'><accent><accent_text><span id='kana'>ホービ</span>"
            + "<symbol_macron id='mark'>￣</symbol_macron><sound id='sound'>♪</sound></accent_text></accent><div>☞ごほうび</div></div></dic-item>"
        let view = DictionaryPage.makeWebView(html: DictionaryPage.make(body: body, css: css, code: "TEST"), coordinator: coordinator)
        let window = host(view)
        defer {
            view.configuration.userContentController.removeScriptMessageHandler(forName: "readerSelection", contentWorld: DictionaryPage.selectionWorld)
            window.isHidden = true
        }
        for _ in 0..<600 {
            if !view.isLoading && view.url != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let gaps = "(() => { const k = document.getElementById('kana').getBoundingClientRect(), m = document.getElementById('mark').getBoundingClientRect(), s = document.getElementById('sound').getBoundingClientRect(); return JSON.stringify({ mark: m.left - k.left, sound: s.left - k.right }); })()"
        func measure() async throws -> [String: Double] {
            let raw = try await evaluate(gaps, in: view) as? String
            return try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(raw?.data(using: .utf8))) as? [String: Double])
        }
        _ = try await evaluate("window.__jpIndent(1)", in: view)
        let fitted = try await measure()
        XCTAssertGreaterThan(fitted["mark"] ?? -1, 20, "The pitch mark stays after the kana, not on top of the first one: \(fitted)")
        XCTAssertGreaterThanOrEqual(fitted["sound"] ?? -99, -1, "The play button does not cover the kana: \(fitted)")
    }
}
