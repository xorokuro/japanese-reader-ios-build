import SwiftUI

// Public input-mode APIs expose language, not the Japanese Kana/Romaji layout.
final class JapaneseTextField: UITextField {
    var requestFocus = false
    var preferredLanguage = "ja"
    override var textInputMode: UITextInputMode? {
        guard preferredLanguage != "system" else { return super.textInputMode }
        return UITextInputMode.activeInputModes.first { $0.primaryLanguage?.hasPrefix(preferredLanguage) == true } ?? super.textInputMode
    }
    override var textInputContextIdentifier: String? { "JapaneseReader.Search." + preferredLanguage }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, requestFocus { focusAndSelect() }
    }
    func focusAndSelect() {
        guard window != nil, requestFocus else { return }
        unmarkText()
        becomeFirstResponder()
        selectedTextRange = textRange(from: beginningOfDocument, to: endOfDocument)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.requestFocus, self.isFirstResponder else { return }
            self.selectedTextRange = self.textRange(from: self.beginningOfDocument, to: self.endOfDocument)
        }
    }
}

struct JapaneseSearchField: UIViewRepresentable {
    @Binding var text: String
    let focusRequest: Int
    let active: Bool
    let ink: UIColor
    /// Caret and selection color; `nil` keeps the inherited tint.
    var accent: UIColor? = nil
    var preferredLanguage: String = "ja"
    var changed: ((String) -> Void)? = nil
    let submit: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> JapaneseTextField {
        let field = JapaneseTextField()
        field.placeholder = "Search Japanese…"
        field.accessibilityIdentifier = "dictionarySearchField"
        field.accessibilityLabel = "Search Japanese…"
        field.returnKeyType = .search
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.clearButtonMode = .whileEditing
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateUIView(_ field: JapaneseTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if field.preferredLanguage != preferredLanguage {
            field.preferredLanguage = preferredLanguage
            if field.isFirstResponder { field.reloadInputViews() }
        }
        // Do not replace marked text while the Japanese IME is composing.
        if field.markedTextRange == nil, field.text != text { field.text = text }
        field.textColor = ink
        if let accent, field.tintColor != accent { field.tintColor = accent }
        // Keep the placeholder legible on every theme background.
        if coordinator.placeholderInk != ink {
            coordinator.placeholderInk = ink
            field.attributedPlaceholder = NSAttributedString(
                string: "Search Japanese…",
                attributes: [.foregroundColor: ink.withAlphaComponent(0.42)])
        }
        let shouldFocus = active && (!coordinator.wasActive || coordinator.lastRequest != focusRequest)
        coordinator.wasActive = active
        coordinator.lastRequest = focusRequest
        field.requestFocus = active
        if shouldFocus {
            DispatchQueue.main.async { [weak field] in field?.focusAndSelect() }
        } else if !active && field.isFirstResponder && coordinator.autoFocused {
            field.resignFirstResponder()
        }
        coordinator.autoFocused = active
    }
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: JapaneseSearchField
        var wasActive = false
        var autoFocused = false
        var lastRequest = -1
        var placeholderInk: UIColor?
        init(_ parent: JapaneseSearchField) { self.parent = parent }
        @objc func changed(_ field: UITextField) {
            let query = field.text ?? ""
            parent.text = query
            parent.changed?(query)
        }
        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            guard textField.markedTextRange == nil else { return false }
            parent.submit()
            textField.resignFirstResponder()
            return true
        }
    }
}
