import Foundation

/// Where an ad hoc speech request should play.
enum SpeechTarget: Hashable {
    /// The audio output configured on this Mac.
    case local
    /// A paired attendee in the hosted group, addressed by its anonymous participant UID.
    case participant(String)

    var participantUID: String? {
        if case let .participant(uid) = self { return uid }
        return nil
    }
}

enum SpeechRequestStatus: String, Codable {
    case queued
    case preparing
    case speaking
    case completed
    case failed
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        default: false
        }
    }

    var displayName: String {
        switch self {
        case .queued: "Queued"
        case .preparing: "Preparing"
        case .speaking: "Speaking"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}

/// One-off speech that is not part of the orchestrated script. Local requests
/// live only in memory; requests aimed at a paired attendee are mirrored from
/// the room's `speechRequests` collection.
struct SpeechRequest: Identifiable, Hashable {
    let id: String
    let target: SpeechTarget
    let targetName: String
    let text: String
    let voiceID: String?
    let voiceName: String?
    let requestedBy: String
    var status: SpeechRequestStatus
    let createdAt: Date
    var startedAt: Date?
    var endedAt: Date?
    var error: String?

    var isRemote: Bool { target != .local }
}
