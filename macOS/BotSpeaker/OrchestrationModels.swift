import Foundation

enum OrchestrationMode: String, CaseIterable, Identifiable {
    case host
    case remote

    var id: String { rawValue }
    var title: String { self == .host ? "Host" : "Remote Client" }
}

enum OrchestrationSessionStatus: String, Codable {
    case lobby
    case running
    case paused
    case completed
    case stopped

    var displayName: String {
        switch self {
        case .lobby: "Waiting for speakers"
        case .running: "Meeting in progress"
        case .paused: "Meeting paused"
        case .completed: "Meeting completed"
        case .stopped: "Meeting stopped"
        }
    }
}

enum OrchestrationTurnStatus: String, Codable {
    case queued
    case assigned
    case preparing
    case speaking
    case paused
    case completed
    case skipped
    case failed
    case stopped

    var isTerminal: Bool {
        switch self {
        case .completed, .skipped, .failed, .stopped: true
        default: false
        }
    }
}

struct OrchestrationParticipant: Identifiable, Hashable {
    let id: String
    let displayName: String
    let scriptTitle: String
    let voiceName: String
    let segmentCount: Int
    let preparedSegmentCount: Int
    let preparationError: String?
    let status: String
    let isConnected: Bool
    let lastSeenAt: Date?

    var isRecentlyConnected: Bool {
        guard isConnected, let lastSeenAt else { return false }
        return Date().timeIntervalSince(lastSeenAt) < 90
    }

    var isFirstTurnPrepared: Bool {
        segmentCount > 0 && preparedSegmentCount > 0
    }
}

struct OrchestrationTurn: Identifiable, Hashable {
    let id: String
    let index: Int
    let participantUID: String
    let speakerName: String
    let scriptTitle: String
    let segmentIndex: Int
    let status: OrchestrationTurnStatus
    let text: String?
    let startedAtClient: Date?
    let startedAtServer: Date?
    let endedAtClient: Date?
    let endedAtServer: Date?
    let error: String?
}

struct OrchestrationTranscript: Codable {
    let schemaVersion: Int
    let sessionID: String
    let pairingCode: String
    let status: String
    let startedAt: Date?
    let endedAt: Date?
    let exportedAt: Date
    let speakers: [Speaker]
    let turns: [Turn]

    struct Speaker: Codable {
        let id: String
        let name: String
        let scriptTitle: String
        let voiceName: String
    }

    struct Turn: Codable {
        let index: Int
        let speakerID: String
        let speakerName: String
        let scriptTitle: String
        let segmentIndex: Int
        let text: String?
        let status: String
        let startedAt: Date?
        let endedAt: Date?
        let serverReceivedStartedAt: Date?
        let serverReceivedEndedAt: Date?
        let durationMilliseconds: Int?
        let error: String?
    }
}

enum OrchestrationScriptSegmenter {
    private static let fallbackTargetLength = 900

    static func segments(for text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let paragraphs = normalized
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if paragraphs.count > 1 {
            return paragraphs.flatMap { splitOversizedParagraph($0) }
        }
        return splitOversizedParagraph(normalized.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func splitOversizedParagraph(_ paragraph: String) -> [String] {
        guard paragraph.count > fallbackTargetLength * 2 else {
            return paragraph.isEmpty ? [] : [paragraph]
        }

        var segments: [String] = []
        var current = ""
        paragraph.enumerateSubstrings(
            in: paragraph.startIndex..<paragraph.endIndex,
            options: [.bySentences, .substringNotRequired]
        ) { _, range, _, _ in
            let sentence = paragraph[range].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sentence.isEmpty else { return }
            if !current.isEmpty, current.count + sentence.count > fallbackTargetLength {
                segments.append(current)
                current = sentence
            } else {
                current += current.isEmpty ? sentence : " \(sentence)"
            }
        }
        if !current.isEmpty { segments.append(current) }
        return segments.isEmpty ? [paragraph] : segments
    }
}
