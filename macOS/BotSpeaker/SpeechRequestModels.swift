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
    /// Number of passes to play. `1` plays once; `nil` repeats until cancelled.
    var cycles: Int? = 1
    /// Passes that have finished so far on the machine doing the playing.
    var completedCycles: Int = 0
    /// A pre-recorded file to play instead of synthesizing `text`. Only local
    /// requests carry one; the file lives in the app's own container.
    var audioURL: URL? = nil

    var isRemote: Bool { target != .local }
    var isLooping: Bool { cycles != 1 }
    var isAudioFile: Bool { audioURL != nil }

    /// "2/5" for a counted repeat, "3/∞" for an endless loop, nil for a single pass.
    var cyclesDescription: String? {
        guard isLooping else { return nil }
        return "\(completedCycles)/\(cycles.map(String.init) ?? "∞")"
    }

    /// Firestore stores endless loops as 0 because the host must set a value the
    /// attendee can distinguish from an absent (single-pass) field.
    static func cycles(fromStored value: Any?) -> Int? {
        let stored: Int? = switch value {
        case let number as Int: number
        case let number as NSNumber: number.intValue
        default: nil
        }
        guard let stored else { return 1 }
        return stored <= 0 ? nil : stored
    }
}
