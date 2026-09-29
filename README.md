# Japanese Reader iOS build source

Source-only snapshot for a user-authorized public iOS build. No personal passages, dictionary packs, credentials, or private repository history are included.

Build locally on macOS with bash ios/build.sh. The manual GitHub workflow refuses to run build jobs when this repository is private.

Source snapshot: xorokuro/jp-game-reader commit 0473b05 (iOS 1.6, build 7), with later iOS-only updates (currently 2.7.5, build 34).

## 2.7.5 — ruled lines in 文法 lessons

- 文法 lessons now have the same **ruled notebook lines** as the Read page: one faint rule under every line of text, placed from where each line actually lands (furigana, headings and boxes included), across the width of the paragraph or box. They follow the two-finger text size gesture, rotation and fonts loading. The same switch turns them off: Library → Appearance → Reading text → *Ruled notebook lines · 罫線*.

## 2.7.4 — ruled notebook lines (with 文法 kept)

- The Read page passage sits on **ruled notebook paper** like the desktop reader: a faint rule between every line and a double margin line on the left. The rules are placed from where each line of text actually lands, so the text always sits between two rules at any text size (two-finger swipe / pinch), line spacing, typeface, page margin or rotation; translation lines get their own ruled line too. Library → Appearance → Reading text → *Ruled notebook lines · 罫線* turns it off.
- The dictionary card's Results, Translate and Copy buttons are icons only; touch and hold one and drop it on another to change their order (remembered).
- Library shows the installed version at the bottom.
- The ruled lines were first built on an older copy without the 文法 tab (branch `ruled-lines`); this build has both.

## 2.7.2 — picks up where you left off

- **Reopens where you left off**: closing and reopening the app returns to the same tab and the same place in it:
  - **文法**: the lesson that was open, at the same scroll position (Back still returns through the lessons you came from), and the list at the same pattern.
  - **Search**: the same definition at the same position, with Back walking through the earlier pages and the result list.
  - **Read**: the same passage at the same place.
- **Each 文法 level keeps its place in the list**: switching N5 → N2 → N5 returns each level's list to where you were instead of the top.
- **Switching tabs keeps your place in Search**: going to another tab and tapping Search again returns to the page you were on, with its Back history. Tapping Search while already on it still goes to the search field. A lookup started from Read or a 文法 lesson begins a fresh Search history, as before.
- **Long pages keep their position**: going back to a long lesson or definition used to land short or at the top, because the position was applied before the page finished laying out. It is now re-applied until the page is ready, and only positions you scrolled to are remembered. Back to a result list shows the result you opened.

## 2.7.1 — launch crash fix

- 2.7 (build 29) closed at once on iPhone: in the optimized device build the search bar was one very deeply nested SwiftUI type, and decoding it at launch overflowed the main thread's stack. The search bar, result list, entry page and title are now built from separately type-erased parts. CI also launches the optimized build in the simulator before packaging.

## 2.7 — Full-text search (全文)

- **New match mode "Full text · 全文"** (Search → the *Starts with* chip): finds your text anywhere in the definitions and **example sentences** of every enabled dictionary, not just in headwords. Matches may cross bold words and ignore furigana, so 「間際に」 finds 「大引け**間際**に急落した」.
- Results appear dictionary by dictionary while the rest are still being searched (a small "Searching 大辞泉… 3/11" note shows progress). Each row shows the sentence around the match with the match in bold.
- Opening a result marks every occurrence on the page and scrolls to the first one.
- The first 300 entries (80 per dictionary) are listed; add more characters to narrow it down. Full text waits until you pause typing, and a new search stops the old one at once.

## 2.6.3 — double-tap to switch dictionaries, pull to clear search

- **Double-tap a definition** on its right half to go to the same word in the next dictionary, or on its left half for the previous one (same as the ‹ › arrows). A chevron flashes on that side; at the first / last dictionary the phone just buzzes.
- **Pull down and release to clear the search box** (build 28): on the Search tab, pull the results (or the "Nothing found" page) down; *↑ Release to clear* appears, and letting go clears the text with the keyboard ready for a new word. With the box already empty, pull and release brings up the keyboard. No need to hit the small ✕.
- The top-bar ‹ › arrows no longer overlap the ☰ menu.

## 2.6.2 — per-dictionary text size, ‹ › dictionary arrows, selection card, Takoboto layout

- **Each dictionary keeps its own text size**: two fingers (or pinch) on a definition now resizes only that dictionary, and ☰ → *Text size for this dictionary* has Larger / Smaller / Use default. Appearance → *Default definition size* is used by dictionaries you have not resized, with a button to put every dictionary back on the default.
- **‹ › beside the dictionary title**: on a definition page, jump to the same word in the previous / next dictionary (same order as the ▾ list) without opening the list. The title shows where you are, e.g. *2/5*.
- **Tapping a leftover selection works again**: if text is still selected after you switch tabs and come back (or after closing the card), tapping the selection reopens the card with Copy, Translate and the dictionary results. Before, nothing happened because the iPhone bar is hidden. Works in lessons, dictionary pages and the Read tab.
- **Takoboto no longer runs off the left edge**: hanging indents (negative text-indent) are now scaled with the page margins, and no line may start left of the page padding, in any dictionary.

## 2.6.1 — grammar list, long selections, Copy feedback

- **文法 list scrolls properly**: it no longer repeats the first two or three patterns while scrolling; every pattern of the level appears in order.
- **Long selections open the card too**: select a sentence or a whole paragraph (longer than the lookup limit) in a lesson, a dictionary page or the Read tab, and the card shows the full selection with **Copy**, **Translate** and **Share** (no dictionary lookup for long text).
- **Copy shows that it worked**: the Copy button turns grey and reads *Copied* until you select something else, and a small 已複製 note appears. *Copy pattern* in a lesson's ↔ menu shows the note too.

## 2.6 — 文法 (Grammar) tab

- New **Grammar** tab with the JLPT grammar collection (N5–N1): level chips, categories, search by pattern or Chinese meaning, 已讀 check marks with progress, and 修正版 marks taken from the desktop index.
- Lessons (詳解) open in the reader's hand-drawn look and follow the chosen theme, typeface and page margins; two-finger swipe changes their text size. Furigana never gets into a selection, so selecting a word opens the dictionary card like on the Read page. Lesson links (→ 該句型詳解) and ↔ related patterns open the other lesson; 前／次 step through a level.
- The grammar folder is read as-is (「JLPT文法總目錄N5-N1.html」 + `lessons/`): ⋯ → *Update lessons from Files…* copies a newer folder onto the phone (older versions such as 修正前版本 are skipped). Progress export/import uses the same JSON as the desktop page's 匯出／匯入進度.
- No lesson content is part of this repository; personal builds add the folder to the app as `Grammar`.

## 2.5 — page margins

- **Page margins: Compact / Normal / Wide** (Library → Appearance → Dictionary pages, or the ≡ menu on any definition). Compact (the new default) shrinks the empty space at the page edges and scales down the dictionaries' own indents, which used to grow with the text size and waste much of the width at large sizes. Changes apply instantly without reloading. The reading card uses the same setting.

## 2.4 — step word by word on the dictionary card

- On the card's character strip, **flick left** to jump the selection to the next word and **flick right** for the previous word (or tap the ‹ › arrows at each end). The real selection, the lookup and the card all follow, so you can walk through a sentence word by word. A slow drag still picks any exact characters.

## 2.3.1 — text size gestures fixed

- The two-finger swipe now starts reliably (it used to cancel itself when the fingers were still at the first moment), and pinching also changes the text size (pinch out = bigger) instead of zooming the dictionary page.

## 2.3 — two-finger text size

- Swipe **up with two fingers** to make the text bigger, **down** to make it smaller — on the Read page and on dictionary pages. The text re-wraps at the new size (unlike pinch zoom, which still works in dictionary pages); a badge shows the size, and the choice is remembered (same settings as Appearance). Dictionary pages restyle in place without reloading.

## 2.2 — read text from photos and screenshots

- **Photo** button next to Paste on the Read page: *Choose photo or screenshot*, *Take picture*, or *Paste image*. Drag the box corners (or draw a new box) around the text, tap **Scan**, fix any misread characters, and tap **Read** — the text becomes the passage, ready for lookups, the dictionary card and translation.
- Uses Apple's on-device text recognition (Japanese and English); nothing is uploaded. Wrapped lines are joined back into sentences, paragraphs are kept, and vertical (tategaki) columns are read right to left.

## 2.1 — line-by-line translation, quieter selection

- **Translate button (speech-bubble icon) on the Read page**: shows Apple's on-device translation in small print under every sentence. Reader options → *Translate into* picks English, 繁體中文, 简体中文 or 한국어 (iOS asks to download a language the first time). Needs iOS 18; older iOS opens the translation panel instead. Selecting a translation line never triggers a dictionary lookup.
- **Adjustable lookup length**: Library → Dictionary search → *Look up selections up to N characters* (5–200, default 40). Selections within the limit open the dictionary card; longer ones get the normal iPhone menu.
- **No more overlapping menus**: for short selections the iPhone's Copy / Look Up / Writing Tools bar is hidden, because the dictionary card now has Copy and Translate buttons. Longer selections (over the limit above) still get the normal menu. Library → Dictionary search → *Hide the iPhone Copy / Look Up bar* turns this off.

## 2.0 — desktop hand-drawn design, dictionary card, faster lookups

- **Select part of a phrase**: selecting text no longer jumps to another page. A dictionary card slides up on the same page with the best matches, and the selection handles stay put, so you can drag them shorter or longer (iOS always starts with a whole word). The card also shows the phrase as big characters: drag across (or tap) exactly the characters you want. Tap a result for the full entry, or *All results* for the list. Works in the passage and inside dictionary pages. Library → Dictionary search → *Show selection results in a card* switches back to the old jump-to-results behaviour.
- **Finds the dictionary form**: 食べました → 食べる, 書いていた → 書く, 高かった → 高い, and trailing particles are trimmed (干しえびを → 干しえび).
- **Looks like the desktop reader**: Klee One pencil-textbook font (bundled, SIL OFL), paper grain and doodles, pencil-outlined cards with an offset shadow, washi tape, highlighter titles, the 辞 seal, wavy rules, and the eight desktop palettes (和紙, 桜, 海辺, 墨, 抹茶, 夜の縁側, 紅葉, 星空). Light-theme installs switch to 和紙 once; Appearance changes it back. Paper grain & doodles can be turned off there.
- **Smoother**: one shared database connection per dictionary with cached catalogues, files, decompressed blocks and previews; definitions open before the dictionary switcher list is built; WebKit is started early and shares one process; shorter selection delays; theme colours are resolved once.

## 1.6 — appearance themes

Library → Appearance offers System, four light themes (Washi Paper, Sakura, Morning Mist, Sepia Study), four dark themes (Midnight Ink, Jade Lantern, Plum Night, True Black) and Custom, which keeps the earlier accent and background pickers. Each theme derives its own reading ink and adjusts its accent until it clears 4.8:1 contrast against both the page and the card surface. Reading, text selection, dictionary lookup, saved passages, notes, navigation and every stored preference are unchanged; existing colour choices are preserved on upgrade.

## Single-screen reader

Read opens directly to the full-height selectable passage. Tap Paste to replace the current passage and immediately look up words; there is no editor mode or Read confirmation. Reader options holds Save, Translate, Copy learning prompt, auto-search and auto-save. Auto-save now runs when pasting; it remains off by default. Clear can still be undone, and saved passages open on the same reading surface.

Search keeps the keyboard hidden by default. Library → Search keyboard → Open keyboard automatically restores automatic focus, and remembers the choice. The search field and keyboard button always allow manual typing.

Auto-search waits until all fingers are lifted before using the final selection, in both the passage and dictionary pages. Starting another touch or cancelling the gesture cancels the pending selection lookup.

Tap a dictionary result heading to collapse or expand its entries. Its name and result count stay visible. Each group keeps its own state while using the app; the dictionary switcher has separate collapse state.

## 1.9 — redesign

- **Search**: the header (back, search field, match mode, dictionary chips) is one compact block. Scrolling down through results slides it and the tab bar away so results fill the screen; scrolling up, reaching the top, typing, or tapping the small query pill brings them back. History, Copy learning prompt and Show search keyboard live in the ⋯ menu. Chips use short dictionary names; result groups are lighter and still collapse.
- **Appearance** (Library → Appearance): 29 presets — 14 light (Washi, Kinari Silk, Sepia, Sumi-e, Sakura, Peach Tea, Yuzu, Matcha Latte, Moss Garden, Morning Mist, Glacier, Hydrangea, Wisteria, Pure White) and 15 dark (Midnight Ink, Sumi Night, Kissaten, Lantern Night, Night Sakura, Autumn Maple, Firefly, Jade Lantern, Matcha Night, Deep Sea, Galaxy, Plum Night, Moonlight, Frost, True Black) — plus System and Custom, shown as a grid with a live preview.
- **Reading text**: Gothic, Mincho or Rounded Hiragino; size 16–38 pt; line spacing.
- **Dictionary pages**: built-in book style (publisher layout kept; large headword, muted labels, indented example phrases with the translation underneath) following the theme; serif or sans; size 14–28 pt. Replacing .css files on the phone is no longer needed.
