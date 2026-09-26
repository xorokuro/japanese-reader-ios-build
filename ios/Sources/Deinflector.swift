import Foundation

/// Turns a selected phrase into the words a dictionary is likely to list, longest first:
/// 食べました → 食べる, 書いていた → 書く, 高かった → 高い, 干しえびを → 干しえび.
/// Candidates that are not real words are harmless: they simply find nothing.
enum Deinflector {
    private static let iRow: [(String, String)] = [("い", "う"), ("き", "く"), ("ぎ", "ぐ"), ("し", "す"), ("ち", "つ"), ("に", "ぬ"), ("び", "ぶ"), ("み", "む"), ("り", "る")]
    private static let aRow: [(String, String)] = [("わ", "う"), ("か", "く"), ("が", "ぐ"), ("さ", "す"), ("た", "つ"), ("な", "ぬ"), ("ば", "ぶ"), ("ま", "む"), ("ら", "る")]
    private static let eRow: [(String, String)] = [("え", "う"), ("け", "く"), ("げ", "ぐ"), ("せ", "す"), ("て", "つ"), ("ね", "ぬ"), ("べ", "ぶ"), ("め", "む"), ("れ", "る")]
    private static let oRow: [(String, String)] = [("お", "う"), ("こ", "く"), ("ご", "ぐ"), ("そ", "す"), ("と", "つ"), ("の", "ぬ"), ("ぼ", "ぶ"), ("も", "む"), ("ろ", "る")]

    /// (inflected ending, dictionary ending). Applied repeatedly, up to three times.
    static let rules: [(String, String)] = {
        var rules: [(String, String)] = []
        // Helpers that sit after the て/で form: reduce them to the bare て/で first.
        let teHelpers = ["いる", "いた", "います", "いました", "いない", "いなかった", "いて", "る", "た", "ない",
                         "おく", "おいた", "しまう", "しまった", "ある", "あった", "くる", "きた", "いく", "いった",
                         "ほしい", "ください", "くれる", "くれた", "もらう", "もらった", "あげる", "あげた", "みる", "みた", "も", "は"]
        for helper in teHelpers {
            rules.append(("て" + helper, "て"))
            rules.append(("で" + helper, "で"))
        }
        rules += [("ちゃう", "て"), ("ちゃった", "て"), ("ちゃ", "て"), ("じゃう", "で"), ("じゃった", "で"), ("じゃ", "で"),
                  ("とく", "て"), ("といた", "て"), ("たら", "た"), ("たり", "た"), ("だら", "だ"), ("だり", "だ")]
        // Polite and other forms built on the -masu stem.
        let stemEndings = ["ます", "ました", "ません", "ませんでした", "ましょう", "たい", "たかった", "たくない", "たくて",
                           "ながら", "なさい", "そうだ", "そうな", "そうに", "そう", "すぎる", "すぎた", "やすい", "にくい", "方"]
        for ending in stemEndings {
            rules.append((ending, "る"))
            for (stem, dictionary) in iRow { rules.append((stem + ending, dictionary)) }
            rules.append(("し" + ending, "する"))
            rules.append(("来" + ending, "来る"))
            rules.append(("き" + ending, "くる"))
        }
        // て / た forms.
        rules += [("て", "る"), ("た", "る"),
                  ("いて", "く"), ("いた", "く"), ("いで", "ぐ"), ("いだ", "ぐ"), ("して", "す"), ("した", "す"),
                  ("って", "う"), ("って", "つ"), ("って", "る"), ("った", "う"), ("った", "つ"), ("った", "る"),
                  ("んで", "む"), ("んで", "ぶ"), ("んで", "ぬ"), ("んだ", "む"), ("んだ", "ぶ"), ("んだ", "ぬ"),
                  ("して", "する"), ("した", "する"), ("きて", "くる"), ("きた", "くる"), ("来て", "来る"), ("来た", "来る"),
                  ("行って", "行く"), ("行った", "行く"), ("いって", "いく"), ("いった", "いく")]
        // Negatives.
        rules += [("ない", "る"), ("しない", "する"), ("こない", "くる"), ("来ない", "来る"),
                  ("なかった", "ない"), ("なくて", "ない"), ("なければ", "ない"), ("なきゃ", "ない"), ("なくちゃ", "ない"),
                  ("ないで", "ない"), ("ず", "ない"), ("ずに", "ない"), ("ません", "ない")]
        for (stem, dictionary) in aRow { rules.append((stem + "ない", dictionary)) }
        // Passive, causative, potential.
        rules += [("られる", "る"), ("させる", "る"), ("させられる", "る"), ("れる", "る"),
                  ("される", "する"), ("させる", "する"), ("できる", "する"), ("こられる", "くる"), ("来られる", "来る")]
        for (stem, dictionary) in aRow {
            rules.append((stem + "れる", dictionary))
            rules.append((stem + "せる", dictionary))
            rules.append((stem + "せられる", dictionary))
        }
        for (stem, dictionary) in eRow { rules.append((stem + "る", dictionary)) }
        // Volitional, conditional, imperative.
        rules += [("よう", "る"), ("しよう", "する"), ("こよう", "くる"), ("れば", "る"), ("すれば", "する"), ("くれば", "くる"),
                  ("ろ", "る"), ("よ", "る"), ("しろ", "する"), ("せよ", "する"), ("こい", "くる")]
        for (stem, dictionary) in oRow { rules.append((stem + "う", dictionary)) }
        for (stem, dictionary) in eRow { rules.append((stem + "ば", dictionary)) }
        // い-adjectives.
        rules += [("かった", "い"), ("くない", "い"), ("くて", "い"), ("く", "い"), ("ければ", "い"), ("さ", "い"),
                  ("そう", "い"), ("すぎる", "い"), ("げ", "い"), ("かろう", "い"), ("き", "い")]
        // Copula, な-adjectives and する nouns.
        rules += [("です", ""), ("でした", ""), ("だ", ""), ("だった", ""), ("な", ""), ("に", ""), ("の", ""),
                  ("じゃない", ""), ("ではない", ""), ("する", ""), ("さん", ""), ("たち", ""), ("達", "")]
        // A bare -masu stem used on its own (進み → 進む).
        rules += iRow
        return rules
    }()

    /// Dictionary-form guesses for one string, nearest first. Excludes the input itself.
    static func deinflect(_ word: String, depth: Int = 3) -> [String] {
        var results: [String] = []
        var seen: Set<String> = [word]
        var frontier = [word]
        for _ in 0..<depth {
            var next: [String] = []
            for form in frontier {
                for (ending, replacement) in rules where form.hasSuffix(ending)
                    && (form.count > ending.count || (form.count == ending.count && !replacement.isEmpty)) {
                    let base = String(form.dropLast(ending.count)) + replacement
                    guard !base.isEmpty, seen.insert(base).inserted else { continue }
                    results.append(base)
                    next.append(base)
                }
            }
            if next.isEmpty { break }
            frontier = next
        }
        return results
    }

    /// Everything worth trying for a selection: the whole text and its dictionary forms,
    /// then ever-shorter leading parts (so 干しえびを finds 干しえび).
    static func lookupCandidates(_ text: String, longest: Int = 20, limit: Int = 600) -> [String] {
        let characters = Array(text)
        var candidates: [String] = []
        var seen = Set<String>()
        func add(_ value: String) {
            guard !value.isEmpty, seen.insert(value).inserted else { return }
            candidates.append(value)
        }
        let top = min(characters.count, longest)
        guard top > 0 else { return [] }
        for length in stride(from: top, through: 1, by: -1) {
            let prefix = String(characters[0..<length])
            add(prefix)
            for form in deinflect(prefix) { add(form) }
            if candidates.count >= limit { break }
        }
        return candidates
    }
}
