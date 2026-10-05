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
        context.coordinator.lastAppliedText = text
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textStorage = textView.textStorage else { return }
        let coordinator = context.coordinator

        textView.isEditable = isEditable

        // Comparing against the String we last applied is O(1) when the same
        // storage comes back on every tick. Comparing against `textView.string`
        // bridged a fresh NSString and did a full Unicode comparison each time.
        if coordinator.lastAppliedText != text {
            let selection = textView.selectedRange()
            coordinator.isApplyingUpdate = true
            textView.string = text
            textView.setSelectedRange(NSRange(
                location: min(selection.location, textStorage.length),
                length: 0
            ))
            coordinator.isApplyingUpdate = false
            coordinator.lastAppliedText = text
            coordinator.lastHighlightState = nil
            coordinator.lastActiveRange = nil
        }

        let fullRange = NSRange(location: 0, length: textStorage.length)
        let highlightState = HighlightState(
            textLength: fullRange.length,
            playedTextLength: playedTextLength,
            playedTextRanges: playedTextRanges,
            activeTextRange: activeTextRange
        )
        let previousState = coordinator.lastHighlightState
        guard previousState != highlightState else { return }
        coordinator.lastHighlightState = highlightState

        let playedRanges = Self.playedRanges(for: highlightState, in: fullRange)
        let activeRange = activeTextRange
            .map { NSIntersectionRange($0, fullRange) }
            .flatMap { $0.length > 0 ? $0 : nil }

        // Playback ticks ~10x per second. Touching temporary attributes over the
        // whole document each tick invalidated layout and display for every
        // line, so only the characters whose highlight can change are rewritten:
        // the newly played prefix plus the old and new active sentence.
        let dirtyRange: NSRange
        if let previousState,
           previousState.textLength == highlightState.textLength,
           previousState.playedTextRanges == highlightState.playedTextRanges {
            var pieces: [NSRange] = []
            if highlightState.playedTextRanges == nil {
                let before = min(max(previousState.playedTextLength, 0), fullRange.length)
                let after = min(max(highlightState.playedTextLength, 0), fullRange.length)
                if before != after {
                    pieces.append(NSRange(location: min(before, after), length: abs(after - before)))
                }
            }
            if let previousActive = coordinator.lastActiveRange { pieces.append(previousActive) }
            if let activeRange { pieces.append(activeRange) }
            dirtyRange = Self.union(of: pieces) ?? NSRange(location: 0, length: 0)
        } else {
            dirtyRange = fullRange
        }

        if dirtyRange.length > 0 {
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: dirtyRange)
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: dirtyRange)
            layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: dirtyRange)

            for playedRange in playedRanges {
                let safeRange = NSIntersectionRange(playedRange, dirtyRange)
                guard safeRange.length > 0 else { continue }
                layoutManager.addTemporaryAttributes([
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .backgroundColor: NSColor.systemGreen.withAlphaComponent(0.10)
                ], forCharacterRange: safeRange)
            }

            if let activeRange {
                let safeRange = NSIntersectionRange(activeRange, dirtyRange)
                if safeRange.length > 0 {
                    layoutManager.addTemporaryAttributes([
                        .foregroundColor: NSColor.labelColor,
                        .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.24),
                        .underlineStyle: NSUnderlineStyle.single.rawValue
                    ], forCharacterRange: safeRange)
                }
            }
        }

        if let activeRange {
            if coordinator.lastActiveRange != activeRange {
                textView.scrollRangeToVisible(activeRange)
            }
        }
        coordinator.lastActiveRange = activeRange
    }

    private static func playedRanges(for state: HighlightState, in fullRange: NSRange) -> [NSRange] {
        let ranges = state.playedTextRanges ?? [NSRange(
            location: 0,
            length: min(max(state.playedTextLength, 0), fullRange.length)
        )]
        return ranges
            .map { NSIntersectionRange($0, fullRange) }
            .filter { $0.length > 0 }
    }

    private static func union(of ranges: [NSRange]) -> NSRange? {
        guard let first = ranges.first else { return nil }
        return ranges.dropFirst().reduce(first, NSUnionRange)
    }

    struct HighlightState: Equatable {
        var textLength: Int
        var playedTextLength: Int
        var playedTextRanges: [NSRange]?
        var activeTextRange: NSRange?
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var lastHighlightState: HighlightState?
        var lastAppliedText: String?
        private var text: Binding<String>
        var isApplyingUpdate = false
        var lastActiveRange: NSRange?

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingUpdate,
                  let textView = notification.object as? NSTextView else { return }
            let edited = textView.string
            lastAppliedText = edited
            text.wrappedValue = edited
        }
    }
}
