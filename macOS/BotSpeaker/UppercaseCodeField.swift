import AppKit
import SwiftUI

/// A text field that rewrites its contents to uppercase on every keystroke.
///
/// SwiftUI's `TextField` does not reliably push a transformed binding back into
/// a field that is currently first responder, so typed lowercase characters stay
/// visible until editing ends. Doing the transform in `controlTextDidChange`
/// means AppKit rewrites the string before it is ever drawn.
struct UppercaseCodeField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var characterLimit: Int
    var onSubmit: () -> Void

    init(
        text: Binding<String>,
        placeholder: String = "",
        characterLimit: Int = 6,
        onSubmit: @escaping () -> Void = {}
    ) {
        self._text = text
        self.placeholder = placeholder
        self.characterLimit = characterLimit
        self.onSubmit = onSubmit
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize(for: .large), weight: .semibold)
        field.bezelStyle = .roundedBezel
        field.isBordered = true
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: UppercaseCodeField

        init(parent: UppercaseCodeField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let normalized = String(field.stringValue.uppercased().prefix(parent.characterLimit))
            if field.stringValue != normalized {
                let editor = field.currentEditor()
                let caret = editor?.selectedRange
                field.stringValue = normalized
                if let caret, caret.location <= normalized.count {
                    editor?.selectedRange = caret
                } else {
                    editor?.selectedRange = NSRange(location: normalized.count, length: 0)
                }
            }
            parent.text = normalized
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            parent.onSubmit()
            return true
        }
    }
}
