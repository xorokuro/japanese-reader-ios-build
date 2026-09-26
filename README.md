# Japanese Reader iOS build source

Source-only snapshot for a user-authorized public iOS build. No personal passages, dictionary packs, credentials, or private repository history are included.

Build locally on macOS with bash ios/build.sh. The manual GitHub workflow refuses to run build jobs when this repository is private.

Source snapshot: xorokuro/jp-game-reader commit 0473b05 (iOS 1.6, build 7), with later iOS-only updates (currently 2.3.1, build 20).

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
