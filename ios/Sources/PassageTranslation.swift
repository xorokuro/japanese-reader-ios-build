import SwiftUI
import Translation

/// Splits a passage into sentences for line-by-line translation. Joining the
/// pieces gives back the exact passage: closing quotes stay with their sentence,
/// and a line break ends a piece.
enum PassageSegments {
    private static let enders: Set<Character> = ["。", "！", "？", "!", "?", "…", "．"]
    private static let closers: Set<Character> = ["」", "』", "）", ")", "】", "〕", "〉", "》", "”", "’", "〟"]
    static func split(_ text: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        var ended = false
        for character in text {
            // 「…！」と言った stays one sentence.
            if ended, character == "と", let last = current.last, closers.contains(last) { ended = false }
            if ended && !closers.contains(character) && !enders.contains(character) && character != "\n" {
                pieces.append(current)
                current = ""
                ended = false
            }
            current.append(character)
            if character == "\n" {
                pieces.append(current)
                current = ""
                ended = false
            } else if enders.contains(character) {
                ended = true
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }
}

/// Languages offered for the line-by-line translation.
enum TranslationTarget: String, CaseIterable, Identifiable {
    case english = "en", traditionalChinese = "zh-Hant", simplifiedChinese = "zh-Hans", korean = "ko"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .english: return "English"
        case .traditionalChinese: return "繁體中文"
        case .simplifiedChinese: return "简体中文"
        case .korean: return "한국어"
        }
    }
    static func resolve(_ raw: String) -> TranslationTarget { TranslationTarget(rawValue: raw) ?? .english }
}

/// Runs Apple's on-device translation for every sentence of the passage. iOS asks
/// to download a language the first time it is needed.
@available(iOS 18.0, *)
struct PassageTranslationTask: ViewModifier {
    let segments: [String]
    let target: String
    /// Changes whenever the passage or language changes.
    let requestKey: String
    let active: Bool
    /// Called with the request key and one line per segment, or nil on failure.
    let finished: (String, [String]?) -> Void
    @State private var configuration: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .translationTask(configuration) { session in
                let key = requestKey
                let pieces = segments
                var requests: [TranslationSession.Request] = []
                for (index, piece) in pieces.enumerated() {
                    let clean = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clean.isEmpty { requests.append(TranslationSession.Request(sourceText: clean, clientIdentifier: String(index))) }
                }
                var lines = Array(repeating: "", count: pieces.count)
                do {
                    if !requests.isEmpty {
                        let responses = try await session.translations(from: requests)
                        for response in responses {
                            if let id = response.clientIdentifier, let index = Int(id), index < lines.count {
                                lines[index] = response.targetText
                            }
                        }
                    }
                    let result = lines
                    await MainActor.run { finished(key, result) }
                } catch {
                    await MainActor.run { finished(key, nil) }
                }
            }
            .onAppear { refresh() }
            .onChange(of: active) { _, _ in refresh() }
            .onChange(of: requestKey) { _, _ in refresh() }
    }

    private func refresh() {
        guard active else { configuration = nil; return }
        let language = Locale.Language(identifier: target)
        if configuration?.target == language {
            configuration?.invalidate()
        } else {
            configuration = TranslationSession.Configuration(source: Locale.Language(identifier: "ja"), target: language)
        }
    }
}
