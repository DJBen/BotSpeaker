import Foundation

/// Local playback assignments are saved by speaker seat for each meeting template.
struct RecallLocalSpeakerPreferences {
    var indices: Set<Int>
    let legacyHostName: String?

    init(saved: [String: Any]?, speakerCount: Int) {
        let seats = saved?["localSpeakerIndices"] as? [Int]
        let legacyHost = seats == nil && saved?["includeHost"] as? Bool == true
        indices = Set((seats ?? (legacyHost ? [0] : [])).filter { (0..<speakerCount).contains($0) })
        let name = (saved?["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        legacyHostName = legacyHost && name?.isEmpty == false ? name : nil
    }

    func hasOverlappingLocalSpeakers(_ turns: [(speaker: Int, overlapWithPrevious: Bool)]) -> Bool {
        var localCount = 0
        for turn in turns {
            if !turn.overlapWithPrevious { localCount = 0 }
            if indices.contains(turn.speaker) { localCount += 1 }
            if localCount > 1 { return true }
        }
        return false
    }

    var saved: [String: Any] {
        ["localSpeakerIndices": indices.sorted()]
    }
}
