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
        let baseline = try OrchestratedMeetingTemplate.quickFivePerson.parsedTurns().reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
        for name in ["release-deep-dive", "incident-workshop", "customer-research"] {
            let url = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name + ".json")
            let data = try Data(contentsOf: url)
            let file = try JSONDecoder().decode(OrchestratedPlanFile.self, from: data)
            let template = try file.template(id: name)
            let turns = try template.parsedTurns()
            let lengths = turns.map { $0.text.split(whereSeparator: \.isWhitespace).count }
            precondition(template.speakerCount == 5 && Set(turns.map(\.speakerIndex)).count == 5)
            precondition(lengths.reduce(0, +) >= baseline + (name == "incident-workshop" ? 2000 : 1000))
            precondition(lengths.min()! < 15 && lengths.max()! > 100 && !template.overlapTurnIndices.isEmpty)
            let roundTrip = try JSONDecoder().decode(OrchestratedPlanFile.self, from: JSONEncoder().encode(OrchestratedPlanFile(template: template))).template(id: name)
            precondition(roundTrip == template)
            let persisted = try JSONDecoder().decode(OrchestratedMeetingTemplate.self, from: JSONEncoder().encode(template))
            precondition(persisted == template)
            let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            for invalid in ["version", "speaker", "firstOverlap", "sameSpeaker", "emptyText"] {
                var mutated = object
                var items = object["turns"] as! [[String: Any]]
                switch invalid {
                case "version": mutated["version"] = 99
                case "speaker": items[0]["speaker"] = 0
                case "firstOverlap": items[0]["overlapWithPrevious"] = true
                case "sameSpeaker": items[1]["speaker"] = items[0]["speaker"]; items[1]["overlapWithPrevious"] = true
                default: items[0]["text"] = "   "
                }
                mutated["turns"] = items
                do {
                    _ = try JSONDecoder().decode(OrchestratedPlanFile.self, from: JSONSerialization.data(withJSONObject: mutated)).template()
                    fatalError("Invalid plan accepted: \(invalid)")
                } catch {}
            }
        }
        print("PASS: portable plans, persistence/export round-trip, invalid inputs, five-speaker sample lengths and overlaps")
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
