# Japanese Reader (iOS) — notes for anyone working on this repo

- **`main` is the app.** Start every change from the latest `main` (currently 3.4.1, build 52).
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
