import AudioToolbox
import Combine
import CoreAudio
import Foundation

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String

    var isBlackHole: Bool { name.localizedCaseInsensitiveContains("BlackHole") }
}

/// What Core Audio and the on-disk driver folder jointly say about BlackHole.
enum BlackHoleStatus: Equatable {
    /// Core Audio is publishing a BlackHole device — nothing to do.
    case active
    /// The driver bundle is on disk but Core Audio has not picked it up. `coreaudiod`
    /// only scans the HAL plug-in folder when it starts, so a fresh install stays
    /// invisible until the daemon is restarted or the Mac is rebooted.
    case installedButNotLoaded
    /// No driver bundle found — and, if `driverFolderReadable` is false, we could not
    /// look either, so "not installed" is a guess rather than a fact.
    case notInstalled(driverFolderReadable: Bool)
}

@MainActor
final class AudioDeviceManager: ObservableObject {
    @Published private(set) var outputDevices: [AudioDevice] = []
    @Published private(set) var inputDevices: [AudioDevice] = []
    @Published private(set) var blackHoleStatus: BlackHoleStatus = .notInstalled(driverFolderReadable: true)

    /// Shell command that makes Core Audio rescan the HAL folder. Sandboxed apps cannot
    /// run this themselves, so we hand it to the user instead.
    static let coreAudioRestartCommand = "sudo killall coreaudiod"

    private static let halPluginDirectory = "/Library/Audio/Plug-Ins/HAL"

    func refresh() {
        let devices = Self.readDevices()
        blackHoleStatus = Self.readBlackHoleStatus(devices: devices)
        outputDevices = devices.filter { Self.channelCount(for: $0.id, scope: kAudioDevicePropertyScopeOutput) > 0 }.sorted {
            if $0.isBlackHole != $1.isBlackHole { return $0.isBlackHole }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        inputDevices = devices.filter { Self.channelCount(for: $0.id, scope: kAudioDevicePropertyScopeInput) > 0 }.sorted {
            if $0.isBlackHole != $1.isBlackHole { return !$0.isBlackHole }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func readBlackHoleStatus(devices: [AudioDevice]) -> BlackHoleStatus {
        if devices.contains(where: \.isBlackHole) { return .active }

        // The sandbox may deny this read; treat an unreadable folder as "unknown"
        // rather than claiming the driver is missing.
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: halPluginDirectory) else {
            return .notInstalled(driverFolderReadable: false)
        }
        let hasDriverBundle = entries.contains { $0.localizedCaseInsensitiveContains("BlackHole") }
        return hasDriverBundle ? .installedButNotLoaded : .notInstalled(driverFolderReadable: true)
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        readDevices().first(where: { $0.uid == uid })?.id
    }

    static func defaultInputDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr else { return nil }
        return stringProperty(kAudioDevicePropertyDeviceUID, deviceID: deviceID)
    }

    private static func readDevices() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard let uid = stringProperty(kAudioDevicePropertyDeviceUID, deviceID: id),
                  let name = stringProperty(kAudioObjectPropertyName, deviceID: id) else { return nil }
            return AudioDevice(id: id, uid: uid, name: name)
        }
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let storage = UnsafeMutablePointer<CFString?>.allocate(capacity: 1)
        storage.initialize(to: nil)
        defer { storage.deinitialize(count: 1); storage.deallocate() }
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, storage) == noErr,
              let value = storage.pointee else { return nil }
        return value as String
    }

    private static func channelCount(for deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, list) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
