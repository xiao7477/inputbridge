import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Equatable, Sendable {
    let uid: String
    let name: String

    var id: String { uid }
}

enum AudioInputDeviceManager {
    static func availableDevices() -> [AudioInputDevice] {
        allDeviceIDs()
            .filter(hasInputChannels)
            .compactMap { deviceID in
                guard let uid = stringProperty(
                    deviceID,
                    selector: kAudioDevicePropertyDeviceUID
                ) else { return nil }
                let name = stringProperty(
                    deviceID,
                    selector: kAudioObjectPropertyName
                ) ?? uid
                return AudioInputDevice(uid: uid, name: name)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func configure(_ engine: AVAudioEngine, deviceUID: String) throws {
        guard !deviceUID.isEmpty else { return }
        guard let deviceID = allDeviceIDs().first(where: {
            stringProperty($0, selector: kAudioDevicePropertyDeviceUID) == deviceUID &&
                hasInputChannels($0)
        }) else {
            throw BridgeError.transport("所选麦克风当前不可用，请重新连接设备或改为“跟随系统”。")
        }
        guard let audioUnit = engine.inputNode.audioUnit else {
            throw BridgeError.transport("无法打开所选麦克风。")
        }
        var selectedDevice = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &selectedDevice,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw BridgeError.transport("无法切换到所选麦克风（错误码：\(status)）。")
        }
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &byteCount
        ) == noErr else { return [] }

        let count = Int(byteCount) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = Array(repeating: AudioDeviceID(0), count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &byteCount,
            &deviceIDs
        ) == noErr else { return [] }
        return deviceIDs
    }

    private static func hasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &byteCount
        ) == noErr, byteCount > 0 else { return false }

        let rawBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(byteCount),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBuffer.deallocate() }
        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &byteCount,
            rawBuffer
        ) == noErr else { return false }

        let list = rawBuffer.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(list).contains { $0.mNumberChannels > 0 }
    }

    private static func stringProperty(
        _ deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var byteCount = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &byteCount,
                pointer
            )
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}
