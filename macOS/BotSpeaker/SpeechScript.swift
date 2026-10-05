import Foundation

struct SpeechScript: Identifiable, Hashable {
    enum Kind: Hashable {
        case example
        case custom(UUID)
    }

    let id: String
    let title: String
    let detail: String
    let text: String
    let kind: Kind
    /// Counted once at construction. The composer header re-renders on every
    /// playback tick, so recounting a multi-thousand-word script there is waste.
    let wordCount: Int

    init(id: String, title: String, detail: String, text: String, kind: Kind) {
        self.id = id
        self.title = title
        self.detail = detail
        self.text = text
        self.kind = kind
        wordCount = text.split(whereSeparator: \.isWhitespace).count
    }

    var isCustom: Bool {
        if case .custom = kind { return true }
        return false
    }

    var cacheNamespace: String { id }
}

extension StringProtocol {
    /// True when the text is empty or all whitespace. Stops at the first
    /// non-blank character instead of trimming and copying the whole string.
    var isBlank: Bool { allSatisfy(\.isWhitespace) }
}

struct CustomSpeechScript: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    var text: String
    var detail: String?
}

extension ExampleExcerpt {
    /// Bundled scripts never change, so build their `SpeechScript` values once.
    static let allSpeechScripts: [SpeechScript] = all.map(\.speechScript)

    var speechScript: SpeechScript {
        SpeechScript(
            id: "example:\(id)",
            title: role,
            detail: meeting,
            text: text,
            kind: .example
        )
    }
}
