import AVFoundation
import CoreAudio
import Foundation

protocol MicrophoneUsageMonitoring {
    func isInputInUseByAnotherApplication() -> Bool
}

struct MicrophoneUsageMonitor: MicrophoneUsageMonitoring {
    var avCaptureInputInUse: () -> Bool?
    var coreAudioInputRunningSomewhere: () -> Bool

    init(
        avCaptureInputInUse: @escaping () -> Bool? = {
            AVCaptureDevice.default(for: .audio)?.isInUseByAnotherApplication
        },
        coreAudioInputRunningSomewhere: @escaping () -> Bool = {
            Self.defaultInputRunningSomewhere()
        }
    ) {
        self.avCaptureInputInUse = avCaptureInputInUse
        self.coreAudioInputRunningSomewhere = coreAudioInputRunningSomewhere
    }

    func isInputInUseByAnotherApplication() -> Bool {
        (avCaptureInputInUse() ?? false) || coreAudioInputRunningSomewhere()
    }

    private static func defaultInputRunningSomewhere() -> Bool {
        var defaultInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let deviceStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputAddress,
            0,
            nil,
            &dataSize,
            &deviceID
        )
        guard deviceStatus == noErr, deviceID != 0 else { return false }

        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var running = UInt32(0)
        dataSize = UInt32(MemoryLayout<UInt32>.size)
        let runningStatus = AudioObjectGetPropertyData(
            deviceID,
            &runningAddress,
            0,
            nil,
            &dataSize,
            &running
        )
        return runningStatus == noErr && running != 0
    }
}
