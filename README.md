# Japanese Reader iOS build source

Source-only snapshot for a user-authorized public iOS build. No personal passages, dictionary packs, credentials, or private repository history are included.

Build locally on macOS with bash ios/build.sh. The manual GitHub workflow refuses to run build jobs when this repository is private.

Source snapshot: xorokuro/jp-game-reader commit 0473b05 (iOS 1.6, build 7).

## 1.6 — appearance themes

Library → Appearance offers System, four light themes (Washi Paper, Sakura, Morning Mist, Sepia Study), four dark themes (Midnight Ink, Jade Lantern, Plum Night, True Black) and Custom, which keeps the earlier accent and background pickers. Each theme derives its own reading ink and adjusts its accent until it clears 4.8:1 contrast against both the page and the card surface. Reading, text selection, dictionary lookup, saved passages, notes, navigation and every stored preference are unchanged; existing colour choices are preserved on upgrade.

## Single-screen reader

Read opens directly to the full-height selectable passage. Tap Paste to replace the current passage and immediately look up words; there is no editor mode or Read confirmation. Reader options holds Save, Translate, Copy learning prompt, auto-search and auto-save. Auto-save now runs when pasting; it remains off by default. Clear can still be undone, and saved passages open on the same reading surface.

Search keeps the keyboard hidden by default. Library → Search keyboard → Open keyboard automatically restores automatic focus, and remembers the choice. The search field and keyboard button always allow manual typing.

Auto-search waits until all fingers are lifted before using the final selection, in both the passage and dictionary pages. Starting another touch or cancelling the gesture cancels the pending selection lookup.

Tap a dictionary result heading to collapse or expand its entries. Its name and result count stay visible. Each group keeps its own state while using the app; the dictionary switcher has separate collapse state.
