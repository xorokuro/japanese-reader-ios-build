import SwiftUI

// Public input-mode APIs expose language, not the Japanese Kana/Romaji layout.
final class JapaneseTextField: UITextField {
    var requestFocus = false
    override var textInputMode: UITextInputMode? {
        UITextInputMode.activeInputModes.first { $0.primaryLanguage?.hasPrefix("ja") == true } ?? super.textInputMode
    }
    override var textInputContextIdentifier: String? { "JapaneseReader.Search.Japanese" }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, requestFocus { focusAndSelect() }
    }
    func focusAndSelect() {
        guard window != nil, requestFocus else { return }
        becomeFirstResponder()
        selectAll(nil)
    }
}

struct JapaneseSearchField: UIViewRepresentable {
    @Binding var text: String
    let focusRequest: Int
    let active: Bool
    let ink: UIColor
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
        // Do not replace marked text while the Japanese IME is composing.
        if field.markedTextRange == nil, field.text != text { field.text = text }
        field.textColor = ink
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
