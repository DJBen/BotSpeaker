import AppKit
import SwiftUI

struct HighlightedTextEditor: NSViewRepresentable {
    @Binding var text: String
    let playedTextLength: Int
    let activeTextRange: NSRange?
    var isEditable = true
    var playedTextRanges: [NSRange]? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.backgroundColor = .clear
        textView.font = .preferredFont(forTextStyle: .body)
        textView.string = text
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              let layoutManager = textView.layoutManager else { return }

        textView.isEditable = isEditable

        if textView.string != text {
            let selection = textView.selectedRange()
            context.coordinator.isApplyingUpdate = true
            textView.string = text
            textView.setSelectedRange(NSRange(
                location: min(selection.location, (text as NSString).length),
                length: 0
            ))
            context.coordinator.isApplyingUpdate = false
            context.coordinator.lastHighlightState = nil
        }

        let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
        let highlightState = HighlightState(
            textLength: fullRange.length,
            playedTextLength: playedTextLength,
            playedTextRanges: playedTextRanges,
            activeTextRange: activeTextRange
        )
        // Playback ticks ~10x per second; re-applying attributes over the whole
        // text on every tick is wasted layout work when nothing changed.
        guard context.coordinator.lastHighlightState != highlightState else { return }
        context.coordinator.lastHighlightState = highlightState

        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)
        layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: fullRange)

        let defaultPlayedRange = NSRange(
            location: 0,
            length: min(max(playedTextLength, 0), fullRange.length)
        )
        let rangesToHighlight = playedTextRanges ?? [defaultPlayedRange]
        for playedRange in rangesToHighlight {
            let safeRange = NSIntersectionRange(playedRange, fullRange)
            guard safeRange.length > 0 else { continue }
            layoutManager.addTemporaryAttributes([
                .foregroundColor: NSColor.secondaryLabelColor,
                .backgroundColor: NSColor.systemGreen.withAlphaComponent(0.10)
            ], forCharacterRange: safeRange)
        }

        if let activeTextRange {
            let safeRange = NSIntersectionRange(activeTextRange, fullRange)
            if safeRange.length > 0 {
                layoutManager.addTemporaryAttributes([
                    .foregroundColor: NSColor.labelColor,
                    .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.24),
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ], forCharacterRange: safeRange)

                if context.coordinator.lastActiveRange != safeRange {
                    textView.scrollRangeToVisible(safeRange)
                    context.coordinator.lastActiveRange = safeRange
                }
            }
        } else {
            context.coordinator.lastActiveRange = nil
        }
    }

    struct HighlightState: Equatable {
        var textLength: Int
        var playedTextLength: Int
        var playedTextRanges: [NSRange]?
        var activeTextRange: NSRange?
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var lastHighlightState: HighlightState?
        private var text: Binding<String>
        var isApplyingUpdate = false
        var lastActiveRange: NSRange?

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingUpdate,
                  let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}
