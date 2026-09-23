import Foundation

enum MeetingGroundTruth {
    // Seat-based keys remain unique even when meeting display names collide.
    static func key(_ index: Int) -> String { "speaker_\(index + 1)" }
    static func turn(speaker: Int, name: String, text: String, start: Double, duration: Double, local: Bool) -> [String: Any] {
        ["speaker_key": key(speaker), "speaker_name": name,
         "text": text.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines),
         "start_ms": max(0, Int((start * 1000).rounded())), "end_ms": max(0, Int(((start + duration) * 1000).rounded())),
         "confidence": "low", "cluster": NSNull(), "provenance": "orchestrated",
         "why": local ? "Script identity; local playback start plus clip duration. Not recording-aligned." : "Script identity; Recall acceptance plus clip duration. Remote playback latency is unknown."]
    }
    static func save(meetingID: String, names: [String], host: Int?, origin: Date, turns: [[String: Any]]) throws -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let speakers: [[String: Any]] = names.enumerated().map { index, name in
            var speaker: [String: Any] = ["speaker_key": key(index), "name": name, "ax_pids": [Int]()]
            if index == host { speaker["recorder"] = true }
            return speaker
        }
        let artifact: [String: Any] = ["schema": "gt_final_v1", "meeting_id": meetingID, "speakers": speakers,
            "cluster_priors": NSNull(), "turns": turns,
            "timing": ["basis": "estimated_playback", "origin": formatter.string(from: origin), "recording_aligned": false],
            "text_provenance": "script"]
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = root.appendingPathComponent("BotSpeaker/GroundTruth/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = directory.appendingPathComponent("gt_final.json")
        try JSONSerialization.data(withJSONObject: artifact, options: [.prettyPrinted, .sortedKeys]).write(to: json, options: .atomic)
        return json
    }
}
