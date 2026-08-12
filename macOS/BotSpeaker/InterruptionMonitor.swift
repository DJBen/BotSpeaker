import AVFoundation
import AudioToolbox
import Combine
import Foundation

@MainActor
final class InterruptionMonitor: ObservableObject {
    @Published private(set) var isMonitoring = false
    @Published private(set) var isHearingAudio = false
    @Published private(set) var errorMessage: String?

    var onActivityChanged: ((Bool) -> Void)?

    private let engine = AVAudioEngine()
    private var tapInstalled = false
    private var monitoringStartedAt: TimeInterval?
    private var calibrationLevels: [Float] = []
    private var ambientEstimateDB: Float?
    private var activityWindowStartedAt: TimeInterval?
    private var activityLevels: [Float] = []
    private var ambientWindowStartedAt: TimeInterval?
    private var ambientReturnLevels: [Float] = []

    private let calibrationDuration: TimeInterval = 0.75
    private let activityWindowDuration: TimeInterval = 0.4
    private let ambientReturnWindowDuration: TimeInterval = 0.75
    private let activityMarginDB: Float = 10
    private let ambientReturnMarginDB: Float = 4
    private let minimumActivityThresholdDB: Float = -45
    private let maximumActivityThresholdDB: Float = -18
    private let ambientSmoothing: Float = 0.04

    func start(inputUID: String) async {
        stop(clearError: false)
        errorMessage = nil

        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            authorized = true
        case .notDetermined:
            authorized = await AVCaptureDevice.requestAccess(for: .audio)
        default:
            authorized = false
        }

        guard authorized else {
            errorMessage = "Microphone access is required for interruption detection."
            return
        }

        do {
            let inputNode = engine.inputNode
            if !inputUID.isEmpty {
                guard let deviceID = AudioDeviceManager.deviceID(forUID: inputUID),
                      let unit = inputNode.audioUnit else {
                    throw AppError("The interruption input is unavailable.")
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
                    throw AppError("Could not monitor that input (Core Audio \(status)).")
                }
            }

            let format = inputNode.outputFormat(forBus: 0)
            guard format.channelCount > 0, format.sampleRate > 0 else {
                throw AppError("The interruption input has no active audio channels.")
            }

            inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
                guard let self, let channels = buffer.floatChannelData else { return }
                let frameCount = Int(buffer.frameLength)
                let channelCount = Int(buffer.format.channelCount)
                guard frameCount > 0, channelCount > 0 else { return }

                var sum: Float = 0
                for channel in 0..<channelCount {
                    let samples = channels[channel]
                    for frame in 0..<frameCount {
                        let value = samples[frame]
                        sum += value * value
                    }
                }
                let rms = sqrt(sum / Float(frameCount * channelCount))
                let decibels = 20 * log10(max(rms, 0.000_000_1))
                DispatchQueue.main.async { [weak self] in
                    self?.receive(decibels: decibels)
                }
            }
            tapInstalled = true
            monitoringStartedAt = ProcessInfo.processInfo.systemUptime
            engine.prepare()
            try engine.start()
            isMonitoring = true
        } catch {
            stop(clearError: false)
            errorMessage = error.localizedDescription
        }
    }

    func stop(clearError: Bool = true) {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        monitoringStartedAt = nil
        calibrationLevels.removeAll()
        ambientEstimateDB = nil
        activityWindowStartedAt = nil
        activityLevels.removeAll()
        ambientWindowStartedAt = nil
        ambientReturnLevels.removeAll()
        isMonitoring = false
        setHearingAudio(false)
        if clearError { errorMessage = nil }
    }

    private func receive(decibels: Float) {
        let now = ProcessInfo.processInfo.systemUptime
        guard let monitoringStartedAt else { return }

        if now - monitoringStartedAt < calibrationDuration {
            calibrationLevels.append(decibels)
            ambientEstimateDB = percentile(calibrationLevels, fraction: 0.3)
            return
        }

        if ambientEstimateDB == nil { ambientEstimateDB = decibels }
        let ambient = ambientEstimateDB ?? decibels
        let activityThreshold = min(
            max(ambient + activityMarginDB, minimumActivityThresholdDB),
            maximumActivityThresholdDB
        )

        if isHearingAudio {
            collectAmbientReturn(decibels: decibels, now: now, ambient: ambient)
        } else {
            collectPossibleActivity(decibels: decibels, now: now, threshold: activityThreshold)
            if activityWindowStartedAt == nil, decibels < activityThreshold {
                ambientEstimateDB = smoothedAmbient(current: ambient, sample: decibels)
            }
        }
    }

    private func collectPossibleActivity(decibels: Float, now: TimeInterval, threshold: Float) {
        guard let startedAt = activityWindowStartedAt else {
            if decibels >= threshold {
                activityWindowStartedAt = now
                activityLevels = [decibels]
            }
            return
        }

        activityLevels.append(decibels)
        guard now - startedAt >= activityWindowDuration else { return }

        if averagePowerDB(activityLevels) >= threshold {
            activityWindowStartedAt = nil
            activityLevels.removeAll()
            ambientWindowStartedAt = nil
            ambientReturnLevels.removeAll()
            setHearingAudio(true)
        } else {
            activityWindowStartedAt = decibels >= threshold ? now : nil
            activityLevels = decibels >= threshold ? [decibels] : []
        }
    }

    private func collectAmbientReturn(decibels: Float, now: TimeInterval, ambient: Float) {
        let returnThreshold = ambient + ambientReturnMarginDB
        guard decibels <= returnThreshold else {
            ambientWindowStartedAt = nil
            ambientReturnLevels.removeAll()
            return
        }

        if ambientWindowStartedAt == nil {
            ambientWindowStartedAt = now
            ambientReturnLevels = [decibels]
            return
        }

        ambientReturnLevels.append(decibels)
        guard let startedAt = ambientWindowStartedAt,
              now - startedAt >= ambientReturnWindowDuration,
              averagePowerDB(ambientReturnLevels) <= returnThreshold else { return }

        let returnedAmbient = averagePowerDB(ambientReturnLevels)
        ambientEstimateDB = ambient + (returnedAmbient - ambient) * 0.2
        ambientWindowStartedAt = nil
        ambientReturnLevels.removeAll()
        activityWindowStartedAt = nil
        activityLevels.removeAll()
        setHearingAudio(false)
    }

    private func smoothedAmbient(current: Float, sample: Float) -> Float {
        current + (sample - current) * ambientSmoothing
    }

    private func averagePowerDB(_ levels: [Float]) -> Float {
        guard !levels.isEmpty else { return -160 }
        let meanPower = levels.reduce(Float.zero) { partial, decibels in
            partial + pow(10, decibels / 10)
        } / Float(levels.count)
        return 10 * log10(max(meanPower, 0.000_000_000_000_000_1))
    }

    private func percentile(_ levels: [Float], fraction: Double) -> Float? {
        guard !levels.isEmpty else { return nil }
        let sorted = levels.sorted()
        let index = min(Int(Double(sorted.count - 1) * fraction), sorted.count - 1)
        return sorted[index]
    }

    private func setHearingAudio(_ value: Bool) {
        guard isHearingAudio != value else { return }
        isHearingAudio = value
        onActivityChanged?(value)
    }
}
