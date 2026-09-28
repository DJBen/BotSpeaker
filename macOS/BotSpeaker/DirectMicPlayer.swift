import AVFoundation
import CoreAudio
import Foundation

@MainActor
final class DirectMicPlayer {
    static let deviceUID = "com.local.DirectMic.input"
    let samples: [Int16]
    let device: AudioDeviceID
    private var task: Task<Void, Never>?
    private(set) var isPlaying = false
    private(set) var lastError: String?
    var duration: Double { Double(samples.count) / 48000 + 0.15 }

    init(url: URL) throws {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid = Self.deviceUID as CFString
        var found = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafePointer(to: &uid) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), $0, &size, &found)
        }
        guard status == noErr, found != 0 else { throw NSError(domain: "DirectMic", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "DirectMic input device is not installed."]) }
        device = found
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, file.length <= 48000 * 60 * 20,
              let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(file.length) * 48000 / file.processingFormat.sampleRate + 4096))
        else { throw NSError(domain: "DirectMic", code: 1) }
        try file.read(into: source)
        var supplied = false
        var error: NSError?
        let result = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .endOfStream; return nil }
            supplied = true; state.pointee = .haveData; return source
        }
        if let error { throw error }
        guard result != .error, let pcm = output.int16ChannelData?[0], output.frameLength > 0 else { throw NSError(domain: "DirectMic", code: 2) }
        samples = Array(UnsafeBufferPointer(start: pcm, count: Int(output.frameLength)))
    }
    func stop() { task?.cancel(); task = nil; isPlaying = false }
    func play() {
        stop(); isPlaying = true; lastError = nil
        task = Task { [weak self] in
            guard let self else { return }
            var base = mach_timebase_info_data_t(); mach_timebase_info(&base)
            let ticksPerFrame = 1e9 * Double(base.denom) / Double(base.numer) / 48000
            let start = UInt64(Double(mach_absolute_time()) / ticksPerFrame) + 7200
            var address = AudioObjectPropertyAddress(mSelector: 0x6470636d,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            for offset in stride(from: 0, to: samples.count, by: 960) {
                if Task.isCancelled { break }
                var frame = start + UInt64(offset)
                var data = withUnsafeBytes(of: &frame) { Data($0) }
                samples.withUnsafeBytes { data.append(contentsOf: $0[(offset * 2)..<(min(offset + 960, self.samples.count) * 2)]) }
                var property = data as CFData
                let status = withUnsafePointer(to: &property) { AudioObjectSetPropertyData(self.device, &address, 0, nil, UInt32(MemoryLayout<CFData>.size), $0) }
                if status != noErr { lastError = "PCM IPC failed: \(status)"; break }
                let target = UInt64(Double(start - 7200 + UInt64(offset + 960)) * ticksPerFrame)
                let now = mach_absolute_time()
                if target > now { try? await Task.sleep(nanoseconds: UInt64(Double(target - now) * Double(base.numer) / Double(base.denom))) }
            }
            if !Task.isCancelled { try? await Task.sleep(nanoseconds: 150_000_000) }
            isPlaying = false
        }
    }
}
