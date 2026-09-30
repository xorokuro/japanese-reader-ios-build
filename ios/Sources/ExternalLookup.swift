import AppIntents
import Foundation
import UIKit

// Looking up text from other apps.
//
// iOS does not let an app add its own item to the Copy / Look Up menu of other
// apps, but that menu has Share…, and a shortcut can sit in the share sheet. The
// "Look Up in Japanese Reader" action below appears in the Shortcuts app by
// itself; a one-time shortcut that receives text from the share sheet and runs
// it puts Japanese Reader in every app's Share menu. The same lookup is also
// reachable as a link: jpreader://lookup?q=…

/// Text sent from outside the app, waiting for the app's screen to pick it up.
@MainActor final class ExternalLookupInbox: ObservableObject {
    static let shared = ExternalLookupInbox()
    @Published var pending: String?
    /// A note to show when there was nothing to look up.
    @Published var notice: String?

    func deliver(_ text: String) {
        let clean = ExternalLookup.clean(text)
        guard !clean.isEmpty else { return }
        pending = clean
    }

    /// Whatever was just copied (Back Tap / Action button: Copy, then tap).
    func deliverClipboard() {
        let copied = ExternalLookup.clean(UIPasteboard.general.string ?? "")
        if copied.isEmpty { notice = "Nothing is copied. Select a word, tap Copy, then try again." }
        else { pending = copied }
    }
}

enum ExternalLookup {
    static let scheme = "jpreader"

    /// Trims and limits what arrives (a whole web page shared by mistake stays manageable).
    static func clean(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20_000))
    }

    /// `jpreader://lookup?q=食べる` (also `jpreader://食べる` and `jpreader://read?q=…`).
    static func text(from url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let query = parts?.queryItems?.first(where: { ["q", "text"].contains($0.name) })?.value {
            let clean = clean(query)
            return clean.isEmpty ? nil : clean
        }
        let host = parts?.host?.removingPercentEncoding ?? ""
        guard !["lookup", "read", "search"].contains(host.lowercased()) else { return nil }
        let clean = clean(host + (parts?.path.removingPercentEncoding ?? ""))
        return clean.isEmpty ? nil : clean
    }

    /// Short text is looked up; a sentence or more is opened on the Read page instead,
    /// where any word in it can be selected.
    static func isPassage(_ text: String) -> Bool {
        if text.count > SelectionLimit.current || text.contains("\n") { return true }
        // A whole sentence (「…しました。」) reads better on the Read page too.
        let sentence = text.dropLast().contains { "。！？!?".contains($0) }
        return sentence && text.count > 8
    }

    static func url(for text: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = "lookup"
        parts.queryItems = [URLQueryItem(name: "q", value: text)]
        return parts.url
    }
}

/// "Look Up in Japanese Reader": the action a share-sheet shortcut runs.
struct LookUpInReaderIntent: AppIntent {
    static var title: LocalizedStringResource = "Look Up in Japanese Reader"
    static var description = IntentDescription("Opens Japanese Reader with the text: a word or phrase is looked up in your dictionaries; a longer passage opens on the Read page. With no text (Back Tap, Control Center), it looks up what you just copied.")
    static var openAppWhenRun = true

    @Parameter(title: "Text", description: "The Japanese word, phrase or passage.")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Look up \(\.$text) in Japanese Reader")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        // Run without text (Back Tap, Control Center, AssistiveTouch: there is no
        // share-sheet input), it looks up what was just copied instead.
        if ExternalLookup.clean(text).isEmpty { ExternalLookupInbox.shared.deliverClipboard() }
        else { ExternalLookupInbox.shared.deliver(text) }
        return .result()
    }
}

/// "Look Up Copied Text in Japanese Reader": no settings to fill in, so a
/// one-action shortcut for Back Tap or the Action button is all it takes:
/// select → Copy → tap the back of the phone.
struct LookUpCopiedTextIntent: AppIntent {
    static var title: LocalizedStringResource = "Look Up Copied Text in Japanese Reader"
    static var description = IntentDescription("Opens Japanese Reader and looks up the text you just copied. Put it on Back Tap (Settings → Accessibility → Touch → Back Tap) or the Action button.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        ExternalLookupInbox.shared.deliverClipboard()
        return .result()
    }
}

/// Makes the actions show up in Shortcuts and Spotlight without any setup.
struct ReaderShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: LookUpCopiedTextIntent(),
                    phrases: ["Look up copied text in \(.applicationName)", "Look up the clipboard in \(.applicationName)"],
                    shortTitle: "Look Up Copied Text",
                    systemImageName: "doc.on.clipboard")
        AppShortcut(intent: LookUpInReaderIntent(),
                    phrases: ["Look up in \(.applicationName)", "Search \(.applicationName)"],
                    shortTitle: "Look Up",
                    systemImageName: "character.book.closed")
    }
}
