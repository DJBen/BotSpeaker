import AVFoundation
import Foundation

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Hardware integration test. Sends only silence; requires an installed DirectMic driver.
@main
struct DirectMicPlaybackTests {
    @MainActor
    static func main() async throws {
        let devices = AudioDeviceManager()
        devices.refresh()
        guard devices.audioDestinations.contains(where: { $0.uid == DirectMicPlayer.deviceUID }) else {
            print("SKIP: DirectMic driver is not installed")
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24000)!
        buffer.frameLength = 24000
        buffer.floatChannelData![0].initialize(repeating: 0, count: 24000)
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }

        let player = AudioPlaybackController()
        try player.selectOutputDevice(uid: DirectMicPlayer.deviceUID)
        var finished = 0
        player.onPlaybackFinished = { finished += 1 }
        player.beginSequence(totalChunks: 2)
        try player.append(url: url, timing: SpeechTiming(), sourceRange: NSRange(location: 0, length: 1))
        try player.append(url: url, timing: SpeechTiming(), sourceRange: NSRange(location: 1, length: 1))
        player.finishSequence()
        try await Task.sleep(for: .milliseconds(350))
        player.pause()
        let pausedTime = player.currentTime
        precondition(!player.isPlaying && pausedTime > 0)
        try await Task.sleep(for: .milliseconds(200))
        precondition(player.currentTime == pausedTime)
        player.play()
        try await Task.sleep(for: .seconds(2))
        precondition(finished == 1 && !player.isPlaying && player.lastError == nil)
        precondition(player.currentTime == player.duration && player.playedTextLength == 2)

        player.play()
        try await Task.sleep(for: .milliseconds(250))
        try player.seek(to: 0.7)
        try await Task.sleep(for: .seconds(1))
        precondition(finished == 2 && player.lastError == nil)
        player.play()
        player.stop()
        try await Task.sleep(for: .milliseconds(250))
        precondition(!player.isPlaying && player.currentTime == 0 && finished == 2)
        if let output = devices.outputDevices.first {
            try player.selectOutputDevice(uid: output.uid)
            try player.selectOutputDevice(uid: DirectMicPlayer.deviceUID)
        }
        player.play()
        try await Task.sleep(for: .seconds(2))
        precondition(finished == 3 && player.lastError == nil)
        player.reset()
        precondition(!player.hasAudio)
        print("PASS: DirectMic discovery, queued chunks, pause/resume, replay, seek, stop, and reset")
    }
}
