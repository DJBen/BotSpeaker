import Foundation
import AVFoundation

/// Adapts local playback to the same prepare/dispatch lifecycle used by Recall.
@MainActor
final class LocalMeetingSpeech {
    private let outputDevice: String
    private var players: [String: AVAudioPlayer] = [:]
    private(set) var jobs: [[String: Any]] = []
    init(outputDevice: String) { self.outputDevice = outputDevice }
    func owns(_ id: String?) -> Bool { id.map { players[$0] != nil } ?? false }
    func stop() { for player in players.values { player.stop() } }
    func handle(_ action: String, _ body: [String: Any], model: AppModel) async throws -> [String: Any] {
        if action == "prepare" {
            guard !outputDevice.isEmpty, AudioDeviceManager.deviceID(forUID: outputDevice) != nil else {
                throw AppError("Select an available output device for the host speaker.")
            }
            guard let key = try KeychainStore().read(), !key.isEmpty else { throw AppError("Configure ElevenLabs first.") }
            let clip = try await ElevenLabsClient().synthesize(text: body["text"] as? String ?? "", voiceID: body["voice"] as? String ?? model.voiceID, modelID: model.modelID, apiKey: key, cacheNamespace: "recall-host")
            try Task.checkCancellation()
            let player = try AVAudioPlayer(contentsOf: clip.audioURL)
            player.currentDevice = outputDevice
            guard player.prepareToPlay(), player.duration.isFinite, player.duration > 0 else { throw AppError("Could not prepare host audio.") }
            let id = "local-" + UUID().uuidString
            players[id] = player
            let job: [String: Any] = ["id": id, "status": "prepared", "durationSeconds": player.duration]
            jobs.append(job)
            return ["job": job]
        }
        guard let id = body["id"] as? String, let player = players[id], let index = jobs.firstIndex(where: { $0["id"] as? String == id }) else { throw AppError("Unknown host speech job.") }
        if action == "cancel" { player.stop(); jobs[index]["status"] = "cancelled" }
        if action == "dispatch" {
            guard player.play() else { throw AppError("Could not play host audio on the selected output device.") }
            jobs[index]["acceptedAtEpoch"] = Date().timeIntervalSince1970
            jobs[index]["status"] = "dispatched"
        }
        return ["job": jobs[index]]
    }
    var currentJobs: [[String: Any]] {
        for index in jobs.indices where jobs[index]["status"] as? String == "dispatched" {
            if let id = jobs[index]["id"] as? String, players[id]?.isPlaying == false { jobs[index]["status"] = "finished_dispatching" }
        }
        return jobs
    }
}

