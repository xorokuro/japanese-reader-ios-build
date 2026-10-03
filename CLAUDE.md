# Japanese Reader (iOS) — notes for anyone working on this repo

- **`main` is the app.** Start every change from the latest `main` (currently 3.7.2, build 62).
  Do not start from older branches (`ruled-lines`, `grammar-tab`, `fix/…`, `claude/…`): they are
  snapshots of past versions, and building from one of them drops features such as the 文法 tab.
- The app has four tabs: Read, Search, Library and **文法 (Grammar)**. A build without the Grammar tab
  is a regression.
- Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `ios/project.yml` for every build the owner
  installs; the version shows at the bottom of Library.
- Builds run on GitHub Actions (`.github/workflows/ios.yml`, manual dispatch). Run it on `main`.
- Keep big SwiftUI pages in pieces. A page written as one long expression (the Appearance page with all
  its sections) gets a view type so large that building it overflows the iPhone's main-thread stack at
  launch; the simulator has a bigger stack and does not show it. Split such pages into `AnyView` groups
  and put pages behind `LazyPage` in a `NavigationLink`.
- The script in `DictionaryPage.selectionScript` is one JavaScript program: a syntax error anywhere
  (a name declared twice, say) silently disables all of it on the phone. Before shipping a change to it,
  run the changed function in a real browser against a sample page.
- The page-turn swipe back (`PageTurn.swift`, Appearance → Going back, off by default) shows a picture of the
  previous screen under the turning sheet. Pictures are taken just before a screen is left (`remember` in the
  model, the tab change in `ReaderHome`, `PageTurnStackHook` on NavigationStack pages) and only while the
  setting is on. A new page pushed in a NavigationStack needs `.pageTurnStackPage()` to take part.
  While the setting is off nothing of it is in the view tree (no hook, the plain swipe strips in Search).
- Do not add `CADisableMinimumFrameDurationOnPhone` to `Info.plist` (it lets the page turn run at 120 Hz;
  without it the turn runs at 60). With the key, a lesson or definition page came up blank in 3 of 12 full
  simulator test runs; without it, 0 of 9, and 0 of 4 on the code before the page turn.
- `YohakuDesign` (the app-wide "current design") is set by `ReaderStyle.resolve` and read by fonts. Anything
  that only needs to look a style up passes `activate: false`; dictionary pages get their theme passed in
  (`DictionaryPage.themed`) instead of reading the global.
- The Paste buttons (Read page, Search field) are the system `PasteButton`, which iOS draws itself. On the
  owner's phone it has come out with no size (button missing) while the simulator drew it. `PasteControl`
  shows the app's own button in its place when that happens; keep new paste buttons inside it.
