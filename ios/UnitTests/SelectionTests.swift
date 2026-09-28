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
}
