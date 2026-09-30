# Japanese Reader (iOS) — notes for anyone working on this repo

- **`main` is the app.** Start every change from the latest `main` (currently 2.7.6, build 35).
  Do not start from older branches (`ruled-lines`, `grammar-tab`, `fix/…`, `claude/…`): they are
  snapshots of past versions, and building from one of them drops features such as the 文法 tab.
- The app has four tabs: Read, Search, Library and **文法 (Grammar)**. A build without the Grammar tab
  is a regression.
- Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `ios/project.yml` for every build the owner
  installs; the version shows at the bottom of Library.
- Builds run on GitHub Actions (`.github/workflows/ios.yml`, manual dispatch). Run it on `main`.
