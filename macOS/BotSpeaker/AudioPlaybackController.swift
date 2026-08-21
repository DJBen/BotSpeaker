import AVFoundation
import AudioToolbox
import Combine
import Foundation

@MainActor
final class AudioPlaybackController: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var hasAudio = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isBuffering = false
    @Published private(set) var generatedChunkCount = 0
    @Published private(set) var totalChunkCount = 0
    @Published private(set) var playedTextLength = 0
    @Published private(set) var activeTextRange: NSRange?
    @Published var isLooping = false

    var onPlaybackFinished: (() -> Void)?

    var volume: Float = 1 {
        didSet {
            node.volume = min(max(volume, 0), 1)
        }
    }

    private struct PlaybackChunk {
        let file: AVAudioFile
        let timing: SpeechTiming
        let sourceRange: NSRange
        let startTime: TimeInterval

        var duration: TimeInterval {
            Double(file.length) / file.processingFormat.sampleRate
        }
    }

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var chunks: [PlaybackChunk] = []
    private var timer: AnyCancellable?
    private var currentChunkIndex = 0
    private var startFrame: AVAudioFramePosition = 0
    private var scheduledGeneration = 0
    private var isCurrentChunkScheduled = false
    private var generationComplete = true
    private var playRequested = false

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: nil)
        node.volume = volume
    }

    deinit { timer?.cancel() }

    func selectOutputDevice(uid: String) throws {
        guard let deviceID = AudioDeviceManager.deviceID(forUID: uid) else {
            throw AppError("The selected audio device is no longer available.")
        }
        let shouldResume = playRequested
        let resumeTime = currentTime
        stopEngine()

        guard let unit = engine.outputNode.audioUnit else {
            throw AppError("Could not access the Core Audio output unit.")
        }
        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw AppError("Could not route audio to that device (Core Audio \(status)).")
        }

        if hasAudio {
            try seek(to: resumeTime, resume: shouldResume)
        }
    }

    func beginSequence(totalChunks: Int, autoplay: Bool = true) {
        reset()
        totalChunkCount = totalChunks
        generationComplete = false
        playRequested = autoplay
        isBuffering = autoplay
    }

    func append(url: URL, timing: SpeechTiming, sourceRange: NSRange) throws {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0 else { throw AppError("ElevenLabs returned an empty audio file.") }

        let startTime = chunks.last.map { $0.startTime + $0.duration } ?? 0
        let chunk = PlaybackChunk(
            file: file,
            timing: timing,
            sourceRange: sourceRange,
            startTime: startTime
        )
        chunks.append(chunk)
        duration = startTime + chunk.duration
        generatedChunkCount = chunks.count
        hasAudio = true

        if currentChunkIndex >= chunks.count - 1, !isCurrentChunkScheduled {
            currentChunkIndex = chunks.count - 1
            startFrame = 0
            currentTime = startTime
            scheduleCurrentChunk()
            if playRequested {
                try prepareEngine()
                node.play()
                isPlaying = true
                isBuffering = false
                startTimer()
            }
        }
        updateTextProgress()
    }

    func finishSequence() {
        generationComplete = true
        totalChunkCount = max(totalChunkCount, generatedChunkCount)
        if isBuffering, currentChunkIndex >= chunks.count {
            finishPlayback()
        }
    }

    func reset() {
        node.stop()
        scheduledGeneration += 1
        chunks.removeAll()
        currentChunkIndex = 0
        startFrame = 0
        isCurrentChunkScheduled = false
        generationComplete = true
        playRequested = false
        isPlaying = false
        hasAudio = false
        currentTime = 0
        duration = 0
        isBuffering = false
        generatedChunkCount = 0
        totalChunkCount = 0
        playedTextLength = 0
        activeTextRange = nil
        stopTimer()
    }

    func play() {
        playRequested = true
        guard hasAudio else {
            isBuffering = !generationComplete
            return
        }

        do {
            if currentTime >= duration {
                if generationComplete {
                    try seek(to: 0, resume: false)
                } else if currentChunkIndex >= chunks.count {
                    isBuffering = true
                    return
                }
            }
            if !isCurrentChunkScheduled { scheduleCurrentChunk() }
            try prepareEngine()
            node.play()
            isBuffering = false
            isPlaying = true
            startTimer()
        } catch {
            isPlaying = false
        }
    }

    func pause() {
        updateCurrentTime()
        node.pause()
        playRequested = false
        isBuffering = false
        isPlaying = false
        stopTimer()
    }

    func stop() {
        node.stop()
        scheduledGeneration += 1
        currentChunkIndex = 0
        startFrame = 0
        currentTime = 0
        isCurrentChunkScheduled = false
        playRequested = false
        isBuffering = false
        isPlaying = false
        stopTimer()
        if hasAudio { scheduleCurrentChunk() }
        updateTextProgress()
    }

    func seek(to seconds: TimeInterval) throws {
        let shouldResume = playRequested
        try seek(to: seconds, resume: shouldResume)
    }

    private func seek(to seconds: TimeInterval, resume: Bool) throws {
        guard !chunks.isEmpty else { return }
        let clamped = min(max(seconds, 0), duration)
        let index: Int
        let localTime: TimeInterval

        if clamped >= duration {
            index = chunks.count - 1
            localTime = chunks[index].duration
        } else {
            index = chunks.lastIndex(where: { $0.startTime <= clamped }) ?? 0
            localTime = clamped - chunks[index].startTime
        }

        let chunk = chunks[index]
        let frame = min(
            AVAudioFramePosition(localTime * chunk.file.processingFormat.sampleRate),
            chunk.file.length
        )
        node.stop()
        scheduledGeneration += 1
        currentChunkIndex = index
        startFrame = frame
        currentTime = clamped
        isCurrentChunkScheduled = false
        updateTextProgress()

        if frame < chunk.file.length {
            scheduleCurrentChunk()
            if resume {
                playRequested = true
                try prepareEngine()
                node.play()
                isPlaying = true
                isBuffering = false
                startTimer()
            } else {
                playRequested = false
                isPlaying = false
                stopTimer()
            }
        } else if index + 1 < chunks.count {
            currentChunkIndex = index + 1
            startFrame = 0
            scheduleCurrentChunk()
            if resume { play() }
        } else {
            playRequested = resume
            isPlaying = false
            isBuffering = resume && !generationComplete
            stopTimer()
        }
    }

    private var currentFrame: AVAudioFramePosition {
        guard let renderTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: renderTime) else { return startFrame }
        return startFrame + playerTime.sampleTime
    }

    private func scheduleCurrentChunk() {
        guard chunks.indices.contains(currentChunkIndex) else { return }
        let chunk = chunks[currentChunkIndex]
        guard startFrame < chunk.file.length else { return }
        let remaining = AVAudioFrameCount(min(
            chunk.file.length - startFrame,
            AVAudioFramePosition(UInt32.max)
        ))
        let generation = scheduledGeneration
        let scheduledIndex = currentChunkIndex
        isCurrentChunkScheduled = true
        node.scheduleSegment(
            chunk.file,
            startingFrame: startFrame,
            frameCount: remaining,
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, generation == self.scheduledGeneration else { return }
                self.reachedEnd(of: scheduledIndex)
            }
        }
    }

    private func reachedEnd(of index: Int) {
        guard index == currentChunkIndex, chunks.indices.contains(index) else { return }
        let finishedChunk = chunks[index]
        currentTime = finishedChunk.startTime + finishedChunk.duration
        playedTextLength = max(playedTextLength, NSMaxRange(finishedChunk.sourceRange))
        isCurrentChunkScheduled = false
        startFrame = 0
        currentChunkIndex += 1

        if chunks.indices.contains(currentChunkIndex) {
            scheduleCurrentChunk()
            if playRequested {
                node.play()
                isPlaying = true
                isBuffering = false
                startTimer()
            }
        } else if generationComplete {
            finishPlayback()
            if isLooping {
                do {
                    try seek(to: 0, resume: true)
                } catch {
                    finishPlayback()
                }
            } else {
                onPlaybackFinished?()
            }
        } else {
            node.stop()
            isPlaying = false
            isBuffering = playRequested
            stopTimer()
        }
        updateTextProgress()
    }

    private func finishPlayback() {
        currentTime = duration
        currentChunkIndex = chunks.count
        isPlaying = false
        isBuffering = false
        playRequested = false
        stopTimer()
        updateTextProgress()
    }

    private func prepareEngine() throws {
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    private func stopEngine() {
        node.stop()
        engine.stop()
        scheduledGeneration += 1
        isCurrentChunkScheduled = false
        isPlaying = false
        stopTimer()
    }

    private func updateCurrentTime() {
        guard chunks.indices.contains(currentChunkIndex) else { return }
        let chunk = chunks[currentChunkIndex]
        let frame = min(currentFrame, chunk.file.length)
        currentTime = min(chunk.startTime + Double(frame) / chunk.file.processingFormat.sampleRate, duration)
        updateTextProgress()
    }

    private func updateTextProgress() {
        guard !chunks.isEmpty else {
            playedTextLength = 0
            activeTextRange = nil
            return
        }

        if currentChunkIndex >= chunks.count {
            playedTextLength = chunks.map { NSMaxRange($0.sourceRange) }.max() ?? 0
            activeTextRange = nil
            return
        }

        let chunk = chunks[currentChunkIndex]
        let localTime = max(currentTime - chunk.startTime, 0)
        let previousEnd = chunks.prefix(currentChunkIndex)
            .map { NSMaxRange($0.sourceRange) }
            .max() ?? 0
        let localOffset = min(chunk.timing.playedUTF16Offset(at: localTime), chunk.sourceRange.length)
        playedTextLength = max(previousEnd, chunk.sourceRange.location + localOffset)

        let span = chunk.timing.sentenceSpans.first(where: {
            localTime >= $0.startTime && localTime < $0.endTime
        }) ?? chunk.timing.sentenceSpans.first(where: { localTime < $0.endTime })

        if let span {
            let location = chunk.sourceRange.location + min(span.location, chunk.sourceRange.length)
            let availableLength = max(NSMaxRange(chunk.sourceRange) - location, 0)
            activeTextRange = NSRange(location: location, length: min(span.length, availableLength))
        } else {
            activeTextRange = chunk.sourceRange
        }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.updateCurrentTime() }
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }
}
