import CoreAudio
import Foundation
import SwiftUI

enum AudioDeviceDirection: String, Sendable {
    case input
    case output

    var coreAudioScope: AudioObjectPropertyScope {
        switch self {
        case .input:
            kAudioDevicePropertyScopeInput
        case .output:
            kAudioDevicePropertyScopeOutput
        }
    }
}

struct AudioDevice: Identifiable, Hashable, Sendable {
    let uid: String
    let name: String
    let direction: AudioDeviceDirection
    let isDefault: Bool

    var id: String { uid }
}

struct AudioDeviceSnapshot: Equatable, Sendable {
    var inputDevices: [AudioDevice]
    var outputDevices: [AudioDevice]
    var defaultInputDeviceUID: String?
    var defaultOutputDeviceUID: String?

    static let empty = AudioDeviceSnapshot(
        inputDevices: [],
        outputDevices: [],
        defaultInputDeviceUID: nil,
        defaultOutputDeviceUID: nil
    )
}

protocol AudioDeviceProviding: AnyObject, Sendable {
    func snapshot() -> AudioDeviceSnapshot
    func startMonitoring(onChange: @escaping @Sendable () -> Void)
    func stopMonitoring()
}

@MainActor
final class AudioDeviceManager: ObservableObject {
    @Published private(set) var snapshot: AudioDeviceSnapshot = .empty

    private let provider: AudioDeviceProviding

    var inputDevices: [AudioDevice] { snapshot.inputDevices }
    var outputDevices: [AudioDevice] { snapshot.outputDevices }

    init(provider: AudioDeviceProviding = CoreAudioDeviceProvider()) {
        self.provider = provider
        refresh()
        provider.startMonitoring { [weak self] in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    deinit {
        provider.stopMonitoring()
    }

    func refresh() {
        snapshot = provider.snapshot()
    }

    func deviceName(for uid: String?, direction: AudioDeviceDirection) -> String {
        guard let uid else {
            return defaultDeviceName(for: direction).map { "System Default (\($0))" } ?? "System Default"
        }
        return devices(for: direction).first { $0.uid == uid }?.name ?? "Disconnected device"
    }

    func isAvailable(_ uid: String?, direction: AudioDeviceDirection) -> Bool {
        guard let uid else { return true }
        return devices(for: direction).contains { $0.uid == uid }
    }

    func defaultDeviceName(for direction: AudioDeviceDirection) -> String? {
        switch direction {
        case .input:
            guard let uid = snapshot.defaultInputDeviceUID else { return nil }
            return snapshot.inputDevices.first { $0.uid == uid }?.name
        case .output:
            guard let uid = snapshot.defaultOutputDeviceUID else { return nil }
            return snapshot.outputDevices.first { $0.uid == uid }?.name
        }
    }

    func devices(for direction: AudioDeviceDirection) -> [AudioDevice] {
        switch direction {
        case .input:
            snapshot.inputDevices
        case .output:
            snapshot.outputDevices
        }
    }
}

final class CoreAudioDeviceProvider: AudioDeviceProviding, @unchecked Sendable {
    private let queue = DispatchQueue(label: "notchly.audio-device-monitor")
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var observedSelectors: [AudioObjectPropertySelector] = []

    func snapshot() -> AudioDeviceSnapshot {
        let defaultInputUID = defaultDeviceUID(selector: kAudioHardwarePropertyDefaultInputDevice)
        let defaultOutputUID = defaultDeviceUID(selector: kAudioHardwarePropertyDefaultOutputDevice)
        let allDeviceIDs = deviceIDs()

        let inputDevices = allDeviceIDs
            .compactMap { device(id: $0, direction: .input, defaultUID: defaultInputUID) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let outputDevices = allDeviceIDs
            .compactMap { device(id: $0, direction: .output, defaultUID: defaultOutputUID) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        return AudioDeviceSnapshot(
            inputDevices: inputDevices,
            outputDevices: outputDevices,
            defaultInputDeviceUID: defaultInputUID,
            defaultOutputDeviceUID: defaultOutputUID
        )
    }

    func startMonitoring(onChange: @escaping @Sendable () -> Void) {
        stopMonitoring()
        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDefaultOutputDevice
        ]
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            onChange()
        }
        listenerBlock = block
        observedSelectors = selectors

        for selector in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                queue,
                block
            )
            if status != noErr {
                AppLog.audio.info("Audio device listener failed for selector \(selector, privacy: .public): \(status, privacy: .public)")
            }
        }
    }

    func stopMonitoring() {
        guard let listenerBlock else { return }
        for selector in observedSelectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                queue,
                listenerBlock
            )
        }
        self.listenerBlock = nil
        observedSelectors = []
    }

    static func deviceID(forUID uid: String, direction: AudioDeviceDirection? = nil) -> AudioDeviceID? {
        let provider = CoreAudioDeviceProvider()
        return provider.deviceIDs().first { deviceID in
            guard provider.deviceUID(deviceID) == uid else { return false }
            guard let direction else { return true }
            return provider.hasChannels(deviceID, direction: direction)
        }
    }

    private func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr else {
            return []
        }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        var ids = Array(repeating: AudioDeviceID(0), count: count)
        let status = ids.withUnsafeMutableBufferPointer { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                pointer.baseAddress!
            )
        }
        guard status == noErr else { return [] }
        return ids.filter { $0 != 0 }
    }

    private func defaultDeviceUID(selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceUID(deviceID)
    }

    private func device(id: AudioDeviceID, direction: AudioDeviceDirection, defaultUID: String?) -> AudioDevice? {
        guard hasChannels(id, direction: direction),
              let uid = deviceUID(id),
              let name = deviceName(id) else {
            return nil
        }
        return AudioDevice(uid: uid, name: name, direction: direction, isDefault: uid == defaultUID)
    }

    private func deviceName(_ deviceID: AudioDeviceID) -> String? {
        cfStringProperty(
            objectID: deviceID,
            selector: kAudioObjectPropertyName,
            scope: kAudioObjectPropertyScopeGlobal
        )
    }

    private func deviceUID(_ deviceID: AudioDeviceID) -> String? {
        cfStringProperty(
            objectID: deviceID,
            selector: kAudioDevicePropertyDeviceUID,
            scope: kAudioObjectPropertyScopeGlobal
        )
    }

    private func cfStringProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        let pointer = UnsafeMutablePointer<Unmanaged<CFString>?>.allocate(capacity: 1)
        pointer.initialize(to: nil)
        defer {
            pointer.deinitialize(count: 1)
            pointer.deallocate()
        }

        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &dataSize,
            pointer
        )
        guard status == noErr, let value = pointer.pointee else { return nil }
        return value.takeRetainedValue() as String
    }

    private func hasChannels(_ deviceID: AudioDeviceID, direction: AudioDeviceDirection) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: direction.coreAudioScope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else {
            return false
        }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }

        let bufferList = rawPointer.assumingMemoryBound(to: AudioBufferList.self)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferList)
        guard status == noErr else { return false }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.contains { $0.mNumberChannels > 0 }
    }
}
