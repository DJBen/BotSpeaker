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

@MainActor
final class AudioDeviceManager: ObservableObject {
    @Published private(set) var outputDevices: [AudioDevice] = []
    @Published private(set) var inputDevices: [AudioDevice] = []

    func refresh() {
        let devices = Self.readDevices()
        outputDevices = devices.filter { Self.channelCount(for: $0.id, scope: kAudioDevicePropertyScopeOutput) > 0 }.sorted {
            if $0.isBlackHole != $1.isBlackHole { return $0.isBlackHole }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        inputDevices = devices.filter { Self.channelCount(for: $0.id, scope: kAudioDevicePropertyScopeInput) > 0 }.sorted {
            if $0.isBlackHole != $1.isBlackHole { return !$0.isBlackHole }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
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
