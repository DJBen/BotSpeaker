import Foundation

/// Portable scripts use one-based speaker numbers, independent of live bot IDs.
struct OrchestratedPlanFile: Codable {
    struct Speaker: Codable {
        let role: String
        var gender: String?
    }
    struct Turn: Codable {
        let speaker: Int
        let text: String
        var overlapWithPrevious: Bool?
    }
    let version: Int
    let title: String
    let speakers: [Speaker]
    let turns: [Turn]

    init(template: OrchestratedMeetingTemplate) throws {
        version = 1
        title = template.title
        speakers = template.speakerRoles.enumerated().map { index, role in
            Speaker(role: role, gender: template.defaultVoiceGenders.indices.contains(index) ? template.defaultVoiceGenders[index] : nil)
        }
        turns = try template.parsedTurns().enumerated().map { index, turn in
            Turn(speaker: turn.speakerIndex + 1, text: turn.text,
                 overlapWithPrevious: template.overlapTurnIndices.contains(index) ? true : nil)
        }
    }

    func template(id: String = UUID().uuidString) throws -> OrchestratedMeetingTemplate {
        guard version == 1 else { throw AppError("Unsupported plan version. Use version 1.") }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (2...12).contains(speakers.count), speakers.allSatisfy({ !$0.role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              (1...450).contains(turns.count) else {
            throw AppError("A plan needs a title, 2–12 speakers with roles, and 1–450 turns.")
        }
        var group: Set<Int> = []
        for (index, turn) in turns.enumerated() {
            guard (1...speakers.count).contains(turn.speaker), !turn.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AppError("Turn \(index + 1) needs text and a valid one-based speaker number.")
            }
            if turn.overlapWithPrevious == true {
                guard index > 0, !group.contains(turn.speaker) else {
                    throw AppError("Turn \(index + 1) cannot overlap: each simultaneous speaker must be different, and the first turn cannot overlap.")
                }
            } else { group = [] }
            group.insert(turn.speaker)
        }
        let words = turns.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
        var result = OrchestratedMeetingTemplate(
            id: id, title: title, detail: "\(speakers.count) speakers · \(words) words",
            speakerRoles: speakers.map(\.role), defaultVoiceGenders: speakers.map { $0.gender ?? "" },
            text: turns.map { "{{speaker_\($0.speaker)}}: " + $0.text.components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " ") }.joined(separator: "\n\n")
        )
        result.overlapTurnIndices = turns.indices.filter { turns[$0].overlapWithPrevious == true }
        return result
    }
}
