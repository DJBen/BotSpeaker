import Foundation
struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
struct ElevenLabsVoice { static func shortName(from name: String) -> String { name } }
@main struct MeetingGroundTruthTests {
    static func main() throws {
        for template in [OrchestratedMeetingTemplate.quickFivePerson, .quickFourPerson] {
            let turns = try template.parsedTurns()
            precondition(Set(turns.map(\.speakerIndex)).count == template.speakerCount)
            precondition(turns.allSatisfy { $0.text.split(separator: " ").count <= 25 })
            for index in turns.indices { precondition(index.isMultiple(of: 2) == (turns[index].speakerIndex == 0)) }
        }
        let turn = MeetingGroundTruth.turn(speaker: 1, name: "Same name", text: "[laughs] Hello.", start: 1.234, duration: 0.765, local: false)
        precondition(turn["start_ms"] as? Int == 1234 && turn["end_ms"] as? Int == 1999)
        precondition(turn["text"] as? String == "Hello.")
        let url = try MeetingGroundTruth.save(meetingID: "test-meeting", names: ["Same name", "Same name"], host: 0, origin: Date(timeIntervalSince1970: 0), turns: [turn])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        precondition(url.lastPathComponent == "gt_final.json")
        let data = try Data(contentsOf: url)
        let artifact = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        precondition(artifact["schema"] as? String == "gt_final_v1")
        let speakers = artifact["speakers"] as! [[String: Any]]
        precondition(speakers[0]["recorder"] as? Bool == true && speakers[1]["recorder"] == nil)
        precondition(speakers[0]["speaker_key"] as? String != speakers[1]["speaker_key"] as? String)
        precondition((artifact["timing"] as! [String: Any])["recording_aligned"] as? Bool == false)
        print("PASS: short host-alternating scenarios, timing, unique speaker keys, host identity, JSON schema round-trip")
    }
}
