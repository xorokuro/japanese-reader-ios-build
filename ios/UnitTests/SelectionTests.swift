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

    private func loaded(_ body: String, css: String, size: Double = 30) async throws -> (WKWebView, UIWindow) {
        let coordinator = DictionaryPage.Coordinator(root: FileManager.default.temporaryDirectory, code: "TEST") { _ in }
        coordinator.margins = .wide
        coordinator.textSize = size
        let view = DictionaryPage.makeWebView(html: DictionaryPage.make(body: body, css: css, code: "TEST"), coordinator: coordinator)
        let window = host(view)
        for _ in 0..<600 {
            if !view.isLoading && view.url != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        return (view, window)
    }

    /// ジーニアス「そこまで」: the headword has a drawn rule under it (so the fit leaves it
    /// alone) and every other line is an indented example. Moving the entry left by the
    /// examples' indent pushed the headword off the left side of the screen.
    func testHeadwordStaysOnThePageWhenOnlyExamplesAreIndented() async throws {
        let css = ".head{position:relative;padding-bottom:.5em}.head::after{content:'';position:absolute;left:0;right:0;bottom:0;height:4px}"
            + ".example{margin-left:1.4em}.example span{display:block}"
        let body = "<div class='dic_item'><div class='head' id='head'><span id='word'>そこまで</span> [そこ迄]</div>"
            + "<div class='example'><span>そこまですることはないよ</span><span>You don't have to do that much.</span></div>"
            + "<div class='example'><span>君がそこまで言うなら一緒に行くよ</span><span>I'll go with you if you insist.</span></div></div>"
        let (view, window) = try await loaded(body, css: css)
        defer {
            view.configuration.userContentController.removeScriptMessageHandler(forName: "readerSelection", contentWorld: DictionaryPage.selectionWorld)
            window.isHidden = true
        }
        let measure = "(() => { const edge = parseFloat(getComputedStyle(document.body).paddingLeft) || 0; let left = 9999; for (const e of document.body.querySelectorAll('*')) { const r = e.getBoundingClientRect(); if (r.width > 0 && r.height > 0) left = Math.min(left, r.left); } return JSON.stringify({ left: left - edge, word: document.getElementById('word').getBoundingClientRect().left - edge }); })()"
        for scale in [0.4, 1.0] {
            _ = try await evaluate("window.__jpIndent(\(scale))", in: view)
            let raw = try await evaluate(measure, in: view) as? String
            let result = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(raw?.data(using: .utf8))) as? [String: Double])
            XCTAssertGreaterThanOrEqual(result["left"] ?? -99, -0.6, "Nothing is left of the page padding at scale \(scale): \(result)")
            XCTAssertGreaterThanOrEqual(result["word"] ?? -99, -0.6, "The headword starts on the page at scale \(scale): \(result)")
        }
    }

    /// NHK accent boxes: the play control is gone, the whole box is the button, and a
    /// long reading is drawn smaller instead of running off the right side.
    func testAccentBoxIsThePlayButtonAndFitsThePage() async throws {
        let css = "dic-item .body>accent{display:inline-flex;align-items:center;padding:.2em .8em;font-size:1.3em;letter-spacing:.08em;white-space:nowrap}"
            + "con_table{display:grid;grid-template-columns:repeat(auto-fill,minmax(12.5em,1fr));gap:.45em}con_table>accent{display:flex;padding:.3em .7em}"
        let body = "<dic-item><div class='head'><headword>そうべつかい</headword></div><div class='body'>"
            + "<accent id='first'><accent_text>ソーベツ<symbol_backslash>＼</symbol_backslash>カイ<sound><a href=\"sound://a/1.aac\">♪</a></sound></accent_text></accent>"
            + "<con_table><accent id='long'><accent_text>ヒト<symbol_backslash>＼</symbol_backslash>ツダケノモノデスカラネエソウデスネ<sound><a href=\"sound://a/2.aac\">♪</a></sound></accent_text></accent></con_table>"
            + "</div><p>発音 <a href=\"sound://a/3.aac\">♪</a></p></dic-item>"
        let (view, window) = try await loaded(body, css: css)
        defer {
            view.configuration.userContentController.removeScriptMessageHandler(forName: "readerSelection", contentWorld: DictionaryPage.selectionWorld)
            window.isHidden = true
        }
        _ = try await evaluate("window.__jpIndent(1)", in: view)
        let measure = "(() => { let right = 0; for (const e of document.body.querySelectorAll('*')) { const r = e.getBoundingClientRect(); if (r.width > 0 && r.height > 0) right = Math.max(right, r.right); } const audios = Array.from(document.querySelectorAll('audio')); const long = document.getElementById('long'); return JSON.stringify({ over: right - innerWidth, page: document.documentElement.scrollWidth - innerWidth, inner: long.scrollWidth - long.clientWidth, audios: audios.length, controls: audios.filter(a => a.hasAttribute('controls')).length, buttons: document.querySelectorAll('accent.jp-play').length, shown: audios.filter(a => getComputedStyle(a).display !== 'none').length }); })()"
        let raw = try await evaluate(measure, in: view) as? String
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(raw?.data(using: .utf8))) as? [String: Double])
        XCTAssertEqual(result["audios"], 3, "Every sound link became a recording: \(result)")
        XCTAssertEqual(result["buttons"], 2, "Both accent boxes are play buttons: \(result)")
        XCTAssertEqual(result["controls"], 1, "Only the recording outside an accent box keeps its control: \(result)")
        XCTAssertEqual(result["shown"], 1, "The recordings inside accent boxes take no room: \(result)")
        XCTAssertLessThanOrEqual(result["over"] ?? 99, 0.6, "Nothing reaches past the right edge of the page: \(result)")
        XCTAssertLessThanOrEqual(result["page"] ?? 99, 0.6, "The page does not scroll sideways: \(result)")
        XCTAssertLessThanOrEqual(result["inner"] ?? 99, 1.5, "The long reading is fitted inside its box: \(result)")
        // A tap anywhere on the box starts its recording.
        let tap = "(() => { window.__played = []; const box = document.getElementById('first'); box.__jpAudio.play = function () { window.__played.push(this.getAttribute('src')); return Promise.resolve(); }; box.dispatchEvent(new MouseEvent('click', { bubbles: true })); return JSON.stringify({ played: window.__played.length, lit: box.classList.contains('jp-playing') ? 1 : 0, src: window.__played[0] === 'jpread://dictionary/a/1.aac' ? 1 : 0 }); })()"
        let tapped = try await evaluate(tap, in: view) as? String
        let outcome = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(tapped?.data(using: .utf8))) as? [String: Double])
        XCTAssertEqual(outcome["played"], 1, "The tap starts the recording: \(outcome)")
        XCTAssertEqual(outcome["src"], 1, "It is the box's own recording: \(outcome)")
        XCTAssertEqual(outcome["lit"], 1, "The box shows that it is playing: \(outcome)")
    }
}
