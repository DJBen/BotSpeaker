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

    var isCustom: Bool {
        if case .custom = kind { return true }
        return false
    }

    var cacheNamespace: String { id }
    var wordCount: Int { text.split(whereSeparator: \.isWhitespace).count }
}

struct CustomSpeechScript: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    var text: String
}

extension ExampleExcerpt {
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
