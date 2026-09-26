import SwiftUI
import UniformTypeIdentifiers

// 文法 tab: the JLPT grammar index (N5–N1) and each pattern's lesson, in the
// reader's hand-drawn look. Selecting words in a lesson opens the same
// dictionary card as the Read tab.

struct GrammarTab: View {
    @EnvironmentObject var model: ReaderModel
    @EnvironmentObject var grammar: GrammarStore
    let style: ReaderStyle
    let margins: PageMargins
    let quietMenu: Bool
    /// True while this tab is the one on screen.
    let active: Bool
    let typeface: ReaderTypeface
    var showSize: (Int) -> Void
    var hideSize: () -> Void

    @State private var path: [String] = []
    @State private var query = ""
    @AppStorage("grammarLevel") private var level = "N5"
    @AppStorage("grammarHideLearned") private var hideLearned = false
    @State private var importingLessons = false
    @State private var importingProgress = false
    @State private var confirmReset = false
    @State private var confirmBuiltIn = false
    @FocusState private var searchFocused: Bool
    @AppStorage("handDrawnPaper") private var handDrawnPaper = true

    var body: some View {
        NavigationStack(path: $path) {
            listScreen
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: String.self) { id in
                    GrammarLessonScreen(entryID: id, path: $path, style: style, margins: margins,
                                        quietMenu: quietMenu, active: active, typeface: typeface,
                                        showSize: showSize, hideSize: hideSize)
                }
        }
        .fileImporter(isPresented: $importingLessons, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let folder): grammar.importFolder(folder)
            case .failure(let error): grammar.status = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $importingProgress, allowedContentTypes: [.json, .plainText]) { result in
            switch result {
            case .success(let file): grammar.importProgress(from: file)
            case .failure(let error): grammar.status = error.localizedDescription
            }
        }
        .confirmationDialog("Clear all 已讀 marks?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Clear \(grammar.learned.count) marks", role: .destructive) { grammar.resetProgress() }
        } message: { Text("Export your progress first if you may want it back.") }
        .confirmationDialog("Go back to the built-in lessons?", isPresented: $confirmBuiltIn, titleVisibility: .visible) {
            Button("Remove imported lessons", role: .destructive) { grammar.useBuiltIn() }
        } message: { Text("Your 已讀 marks are kept.") }
    }

    // MARK: List

    private var shownLevels: [String] { grammar.levels.isEmpty ? ["N5", "N4", "N3", "N2", "N1"] : grammar.levels }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var levelEntries: [GrammarEntry] {
        level == "ALL" ? grammar.entries : grammar.entries.filter { $0.level == level }
    }
    private var visibleEntries: [GrammarEntry] {
        let base = searching ? grammar.search(query) : levelEntries
        return hideLearned ? base.filter { !grammar.isLearned($0) } : base
    }

    private var listScreen: some View {
        VStack(spacing: 0) {
            header
            if grammar.index == nil {
                emptyState
            } else {
                controls
                entryList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PaperBackground(style: style, texture: handDrawnPaper).equatable())
        .onAppear {
            if !shownLevels.contains(level) && level != "ALL" { level = shownLevels.first ?? "N5" }
        }
    }

    private var header: some View {
        VStack(spacing: 2) {
            HStack(spacing: 10) {
                EnsoLogo(style: style, text: "文")
                HandTitle(text: "文法", subtitle: "Grammar", style: style, size: 25)
                Spacer(minLength: 6)
                if grammar.busy || grammar.loading { ProgressView().controlSize(.small) }
                optionsMenu
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            HandRule(style: style).padding(.horizontal, 12)
        }
    }

    private var optionsMenu: some View {
        Menu {
            Section {
                Toggle("Hide 已讀 patterns", isOn: $hideLearned)
            }
            Section("Progress · \(grammar.learned.count) 已讀") {
                Button {
                    do { ShareSheet.present([try grammar.progressExport()]) }
                    catch { grammar.status = error.localizedDescription }
                } label: { Label("Export progress…", systemImage: "square.and.arrow.up") }
                Button { importingProgress = true } label: { Label("Import progress…", systemImage: "square.and.arrow.down") }
                Button(role: .destructive) { confirmReset = true } label: { Label("Clear progress…", systemImage: "trash") }
                    .disabled(grammar.learned.isEmpty)
            }
            Section(sourceDescription) {
                Button { importingLessons = true } label: { Label("Update lessons from Files…", systemImage: "folder.badge.plus") }
                if case .imported = grammar.source, grammar.hasBuiltIn {
                    Button { confirmBuiltIn = true } label: { Label("Use built-in lessons", systemImage: "arrow.uturn.backward") }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(style.accent)
                .frame(width: 40, height: 36)
                .sketchPill(style)
        }
        .accessibilityLabel("Grammar options")
        .accessibilityIdentifier("grammarOptions")
    }

    private var sourceDescription: String {
        let lessons = grammar.entries.filter(\.hasLesson).count
        switch grammar.source {
        case .none: return "No lessons yet"
        case .builtIn: return "Built-in · \(lessons) lessons"
        case .imported(let date):
            let when = date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
            return "Imported \(when) · \(lessons) lessons"
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(style.secondary)
                TextField("句型・意思で検索（例：ばかり、只要）", text: $query)
                    .font(HandFont.body(16))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($searchFocused)
                    .accessibilityIdentifier("grammarSearchField")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(style.faint) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 40)
            .sketchPill(style)
            .padding(.horizontal, 14)

            if !searching {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(shownLevels + ["ALL"], id: \.self) { item in
                            levelChip(item)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                }
            }
            progressLine
                .padding(.horizontal, 18)
            if !grammar.status.isEmpty {
                StatusNote(text: grammar.status, style: style)
                    .padding(.horizontal, 14)
                    .onTapGesture { grammar.status = "" }
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private func levelChip(_ item: String) -> some View {
        let selected = item == level
        let count = item == "ALL" ? grammar.entries.count : grammar.entries.filter { $0.level == item }.count
        return Button {
            withAnimation(.snappy(duration: 0.22)) { level = item }
        } label: {
            HStack(spacing: 5) {
                Text(item == "ALL" ? "全部" : item).font(HandFont.title(16))
                Text("\(count)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .opacity(0.75)
            }
            .foregroundStyle(selected ? style.onAccent : style.ink)
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .sketchPill(style, selected: selected)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("grammarLevel_\(item)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var progressLine: some View {
        let scope = searching ? grammar.search(query) : levelEntries
        let done = grammar.learnedCount(in: scope)
        let fraction = scope.isEmpty ? 0 : Double(done) / Double(scope.count)
        return HStack(spacing: 10) {
            Text(searching ? "「\(query)」 \(scope.count) 項" : (level == "ALL" ? "全部" : (grammar.index?.meta[level] ?? level)))
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(style.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("已讀 \(done)／\(scope.count)")
                .font(HandFont.title(13))
                .foregroundStyle(style.ink)
                .monospacedDigit()
            ZStack(alignment: .leading) {
                SketchShape(radius: 4).fill(style.hairline)
                SketchShape(radius: 4).fill(style.accent).frame(width: max(0, 64 * fraction))
            }
            .frame(width: 64, height: 7)
        }
    }

    private var entryList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if visibleEntries.isEmpty {
                    EmptyHint(symbol: searching ? "magnifyingglass" : "checkmark.seal",
                              title: searching ? "找不到符合的句型" : "All done here",
                              detail: searching ? "Try a shorter part of the pattern (ばかり, として) or a Chinese meaning (只要, 既然)." : "Every pattern at this level is marked 已讀. Turn off Hide 已讀 in the ⋯ menu to see them again.",
                              style: style)
                        .padding(.top, 30)
                } else if searching {
                    ForEach(visibleEntries) { entry in row(entry, showLevel: true) }
                } else {
                    ForEach(groups, id: \.key) { group in
                        groupHeader(group.title, count: group.entries.count, level: group.level)
                        ForEach(group.entries) { entry in row(entry, showLevel: level == "ALL") }
                    }
                }
            }
            .padding(.horizontal, margins.cardInset + 8)
            .padding(.bottom, 28)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private struct EntryGroup {
        let key: String
        let level: String
        let title: String
        let entries: [GrammarEntry]
    }

    private var groups: [EntryGroup] {
        var result: [EntryGroup] = []
        for entry in visibleEntries {
            let key = entry.level + "|" + entry.category
            if let last = result.last, last.key.hasPrefix(key + "#") {
                result[result.count - 1] = EntryGroup(key: key, level: last.level, title: last.title, entries: last.entries + [entry])
            } else {
                result.append(EntryGroup(key: key + "#\(result.count)", level: entry.level, title: entry.category, entries: [entry]))
            }
        }
        return result
    }

    private func groupHeader(_ title: String, count: Int, level: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if self.level == "ALL" {
                Text(level).font(HandFont.title(12)).foregroundStyle(style.onAccent)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(style.accent, in: SketchShape(radius: 6))
            }
            HandTitle(text: title, style: style, size: 17)
            Text("\(count) 項").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(style.faint)
            Spacer()
        }
        .padding(.top, 20)
        .padding(.bottom, 10)
        .padding(.leading, 4)
    }

    private func row(_ entry: GrammarEntry, showLevel: Bool) -> some View {
        let learned = grammar.isLearned(entry)
        return HStack(alignment: .top, spacing: 10) {
            Button { withAnimation(.easeOut(duration: 0.15)) { grammar.toggleLearned(entry) } } label: {
                Image(systemName: learned ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(learned ? style.accent : style.faint)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(learned ? "Marked 已讀" : "Mark 已讀")
            .accessibilityIdentifier("grammarLearned_\(entry.id)")

            Button {
                guard entry.hasLesson else { return }
                searchFocused = false
                path.append(entry.id)
            } label: {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(showLevel ? entry.code : String(format: "%03d", entry.number))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(style.faint)
                            if entry.isRevised {
                                tag("修正版", filled: false)
                            } else if entry.hasLesson {
                                tag("校對中", filled: false, faint: true)
                            } else {
                                tag("講義なし", filled: false, faint: true)
                            }
                        }
                        Text(entry.pattern)
                            .font(HandFont.title(18))
                            .foregroundStyle(style.ink)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(entry.meaning)
                            .font(.system(size: 13.5))
                            .foregroundStyle(style.secondary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(3)
                    }
                    Spacer(minLength: 0)
                    if entry.hasLesson {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(style.faint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!entry.hasLesson)
            .accessibilityIdentifier("grammarEntry_\(entry.id)")
        }
        .padding(.vertical, 10)
        .padding(.leading, 4)
        .padding(.trailing, 12)
        .opacity(learned && !hideLearned ? 0.72 : 1)
        .sketchCard(style, radius: 16, fill: learned ? style.surface.opacity(0.75) : nil, shadow: CGSize(width: 3, height: 4))
        .padding(.bottom, 12)
    }

    private func tag(_ text: String, filled: Bool, faint: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(faint ? style.faint : style.accent)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .overlay(SketchShape(radius: 5).stroke(faint ? style.hairline : style.accent.opacity(0.6), lineWidth: 1))
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 20)
            EnsoLogo(style: style, text: "文", size: 88)
            Text(grammar.loading ? "Opening the lessons…" : "No grammar lessons yet")
                .font(HandFont.title(20))
            if !grammar.loading {
                Text("Choose your JLPT文法 folder (the one with 「JLPT文法總目錄N5-N1.html」 and the lessons folder) — for example from Google Drive in Files. It is copied onto this iPhone and works offline.")
                    .font(HandFont.body(14.5))
                    .foregroundStyle(style.secondary)
                    .multilineTextAlignment(.center)
                Button { importingLessons = true } label: { Label("Choose JLPT文法 folder", systemImage: "folder") }
                    .buttonStyle(HandPrimaryButtonStyle(style: style))
                    .accessibilityIdentifier("grammarImport")
                if !grammar.status.isEmpty {
                    StatusNote(text: grammar.status, style: style)
                }
            }
            Spacer()
        }
        .padding(28)
    }
}

// MARK: - Lesson

struct GrammarLessonScreen: View {
    @EnvironmentObject var model: ReaderModel
    @EnvironmentObject var grammar: GrammarStore
    let entryID: String
    @Binding var path: [String]
    let style: ReaderStyle
    let margins: PageMargins
    let quietMenu: Bool
    let active: Bool
    let typeface: ReaderTypeface
    var showSize: (Int) -> Void
    var hideSize: () -> Void

    @AppStorage("grammarTextSize") private var textSize = 17.0
    @State private var html = ""
    @State private var failed = false
    @AppStorage("handDrawnPaper") private var handDrawnPaper = true

    private var entry: GrammarEntry? { grammar.entry(id: entryID) }
    private var peekVisible: Bool { active && (model.peek?.inDictionary ?? false) }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                page
                if active, let peek = model.peek, peek.inDictionary {
                    LookupPeekCard(peek: peek, style: style,
                                   refine: { model.refinePeek($0) },
                                   open: { hit in model.openPeekHit(hit) },
                                   showAll: { model.showPeekResults() },
                                   copy: {
                                       UIPasteboard.general.string = peek.text
                                       grammar.status = "Copied 「\(peek.text)」."
                                   },
                                   close: { model.closePeek() })
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: peekVisible)
            if !peekVisible { bottomBar }
        }
        .background(PaperBackground(style: style, texture: handDrawnPaper).equatable())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(entry?.pattern ?? "")
                        .font(HandFont.title(16))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if let entry {
                        Text(entry.code + (entry.isRevised ? " · 修正版" : entry.hasLesson ? " · 校對中" : ""))
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(style.secondary)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) { relatedMenu }
        }
        .task(id: entryID) { load() }
        .onChange(of: grammar.root) { _, _ in load() }
        .onChange(of: style.identity) { _, _ in load() }
        .onChange(of: typeface) { _, _ in load() }
        .onDisappear { if model.peek?.inDictionary == true { model.closePeek() } }
    }

    private var page: some View {
        Group {
            if let entry, let folder = grammar.lessonURL(entry)?.deletingLastPathComponent(), !html.isEmpty {
                GrammarLessonPage(html: html, lessonsFolder: folder, textSize: textSize,
                                  initialOffset: grammar.offsets[entry.id] ?? .zero,
                                  bottomInset: peekVisible ? 300 : 0,
                                  quietMenu: quietMenu,
                                  resize: TextResize(value: textSize, range: 13...28,
                                                     set: { textSize = $0; showSize(Int($0)) },
                                                     ended: hideSize),
                                  margins: margins,
                                  saveOffset: { grammar.offsets[entry.id] = $0 },
                                  openLesson: { open(file: $0) }) { word in
                    guard active, !model.showingLookup else { return }
                    model.select(word, inDictionary: true)
                }
                .id(entry.id + style.identity + typeface.rawValue)
                .clipShape(SketchShape(radius: 18))
                .padding(margins == .compact ? 1 : 3)
                .sketchCard(style, radius: 20, tape: .marker, tapeTrailing: true)
                .padding(.horizontal, margins.cardInset)
                .padding(.top, 14)
                .padding(.bottom, 8)
            } else if failed {
                EmptyHint(symbol: "doc.questionmark", title: "This lesson file is missing",
                          detail: "It is listed in the index but not in the lessons folder. Update the lessons from Files (⋯ on the 文法 list).",
                          style: style)
                    .frame(maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var bottomBar: some View {
        let previous = entry.flatMap { grammar.neighbour(of: $0, step: -1) }
        let next = entry.flatMap { grammar.neighbour(of: $0, step: 1) }
        let learned = entry.map { grammar.isLearned($0) } ?? false
        return HStack(spacing: 10) {
            Button { if let previous { replace(with: previous) } } label: {
                Label("前", systemImage: "chevron.left").labelStyle(.titleAndIcon)
            }
            .buttonStyle(HandSoftButtonStyle(style: style))
            .disabled(previous == nil)
            .opacity(previous == nil ? 0.4 : 1)
            .accessibilityLabel("Previous lesson")
            Spacer(minLength: 4)
            Button {
                if let entry { withAnimation(.easeOut(duration: 0.15)) { grammar.toggleLearned(entry) } }
            } label: {
                Label(learned ? "已讀" : "標記已讀", systemImage: learned ? "checkmark.circle.fill" : "circle")
            }
            .buttonStyle(HandSoftButtonStyle(style: style, prominent: learned))
            .accessibilityIdentifier("grammarLessonLearned")
            Spacer(minLength: 4)
            Button { if let next { replace(with: next) } } label: {
                HStack(spacing: 4) { Text("次"); Image(systemName: "chevron.right") }
            }
            .buttonStyle(HandSoftButtonStyle(style: style))
            .disabled(next == nil)
            .opacity(next == nil ? 0.4 : 1)
            .accessibilityLabel("Next lesson")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .padding(.top, 2)
    }

    private var relatedMenu: some View {
        Menu {
            if let entry {
                let related = entry.refs.compactMap { ref -> (GrammarReference, GrammarEntry?) in (ref, grammar.entry(reference: ref)) }
                if !related.isEmpty {
                    Section("類義・關聯 ↔") {
                        ForEach(Array(related.enumerated()), id: \.offset) { _, pair in
                            Button {
                                if let target = pair.1, target.hasLesson { path.append(target.id) }
                            } label: {
                                Text("\(pair.0.level)  \(pair.0.pattern)")
                                Text(pair.0.note)
                            }
                            .disabled(!(pair.1?.hasLesson ?? false))
                        }
                    }
                }
                Section {
                    Text(entry.meaning)
                    Button { UIPasteboard.general.string = entry.pattern } label: { Label("Copy pattern", systemImage: "doc.on.doc") }
                    Button {
                        path = []
                    } label: { Label("Back to the list", systemImage: "list.bullet") }
                }
            }
        } label: {
            Image(systemName: "arrow.left.arrow.right.circle")
                .font(.system(size: 17, weight: .semibold))
        }
        .accessibilityLabel("Related patterns")
        .accessibilityIdentifier("grammarRelated")
    }

    private func load() {
        guard let entry, let url = grammar.lessonURL(entry), let source = try? String(contentsOf: url, encoding: .utf8) else {
            html = ""
            failed = grammar.index != nil
            return
        }
        failed = false
        let css = GrammarLessonStyle.css + GrammarLessonStyle.variables(style: style, size: textSize, typeface: typeface)
        html = GrammarLessonHTML.make(source: source, css: css)
    }

    private func open(file: String) {
        guard let target = grammar.entry(file: file), target.hasLesson else {
            grammar.status = "「\(file)」 is not in the index."
            return
        }
        model.closePeek()
        path.append(target.id)
    }

    private func replace(with target: GrammarEntry) {
        model.closePeek()
        if path.isEmpty { path = [target.id] } else { path[path.count - 1] = target.id }
    }
}
