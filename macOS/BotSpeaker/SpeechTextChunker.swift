import Foundation

struct SpeechChunkPlan: Sendable {
    let text: String
    let sourceRange: NSRange
}

enum SpeechTextChunker {
    private static let targetCharacterCount = 420
    private static let minimumCharacterCount = 240
    private static let maximumCharacterCount = 650

    static func chunks(for source: String) -> [SpeechChunkPlan] {
        guard let contentRange = source.rangeOfCharacter(from: .whitespacesAndNewlines.inverted) else {
            return []
        }

        let upperBound = source.rangeOfCharacter(
            from: .whitespacesAndNewlines.inverted,
            options: .backwards
        )!.upperBound
        let fullContentRange = contentRange.lowerBound..<upperBound
        var rawRanges: [Range<String.Index>] = []
        var cursor = fullContentRange.lowerBound

        while cursor < fullContentRange.upperBound {
            let remaining = source.distance(from: cursor, to: fullContentRange.upperBound)
            if remaining <= maximumCharacterCount {
                rawRanges.append(cursor..<fullContentRange.upperBound)
                break
            }

            let maximumEnd = source.index(
                cursor,
                offsetBy: maximumCharacterCount,
                limitedBy: fullContentRange.upperBound
            ) ?? fullContentRange.upperBound
            let minimumEnd = source.index(
                cursor,
                offsetBy: minimumCharacterCount,
                limitedBy: maximumEnd
            ) ?? maximumEnd
            let targetEnd = source.index(
                cursor,
                offsetBy: targetCharacterCount,
                limitedBy: maximumEnd
            ) ?? maximumEnd

            var sentenceBreaks: [String.Index] = []
            var wordBreaks: [String.Index] = []
            var index = cursor

            while index < maximumEnd {
                let character = source[index]
                let next = source.index(after: index)
                if character.isWhitespace {
                    wordBreaks.append(next)
                }
                if character == "." || character == "!" || character == "?" || character == "\n" {
                    sentenceBreaks.append(next)
                }
                index = next
            }

            let sentenceEnd = bestBreak(
                in: sentenceBreaks,
                minimum: minimumEnd,
                target: targetEnd,
                maximum: maximumEnd
            )
            let wordEnd = bestBreak(
                in: wordBreaks,
                minimum: minimumEnd,
                target: targetEnd,
                maximum: maximumEnd
            )
            let end = sentenceEnd ?? wordEnd ?? maximumEnd
            rawRanges.append(cursor..<end)

            cursor = end
            while cursor < fullContentRange.upperBound, source[cursor].isWhitespace {
                cursor = source.index(after: cursor)
            }
        }

        return rawRanges.enumerated().map { index, range in
            let text = String(source[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            let sourceRange = NSRange(range, in: source)
            return SpeechChunkPlan(text: text, sourceRange: sourceRange)
        }
        .filter { !$0.text.isEmpty }
    }

    private static func bestBreak(
        in candidates: [String.Index],
        minimum: String.Index,
        target: String.Index,
        maximum: String.Index
    ) -> String.Index? {
        let valid = candidates.filter { $0 >= minimum && $0 <= maximum }
        return valid.first(where: { $0 >= target }) ?? valid.last
    }
}
