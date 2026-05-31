@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

protocol MicrophoneCaptureServicing: AnyObject, Sendable {
    func startCapture(inputDeviceUID: String?) async throws -> AsyncStream<AudioBuffer>
    func stopCapture()
}

enum MicrophoneVoiceProcessingPolicy: String, Equatable, Sendable {
    case disabled
    case enabled
    case adaptive
}

struct MicrophoneVoiceProcessingDecision: Equatable, Sendable {
    var shouldEnable: Bool
    var reason: String
}

enum MicrophoneVoiceProcessingSelector {
    static func decision(policy: MicrophoneVoiceProcessingPolicy, deviceName: String?) -> MicrophoneVoiceProcessingDecision {
        switch policy {
        case .disabled:
            return MicrophoneVoiceProcessingDecision(shouldEnable: false, reason: "disabled_by_policy")
        case .enabled:
            return MicrophoneVoiceProcessingDecision(shouldEnable: true, reason: "enabled_by_policy")
        case .adaptive:
            return adaptiveDecision(deviceName: deviceName)
        }
    }

    private static func adaptiveDecision(deviceName: String?) -> MicrophoneVoiceProcessingDecision {
        let normalized = (deviceName ?? "").lowercased()
        let externalRawDevices = [
            "airpods", "headset", "headphone", "usb", "external", "rode",
            "shure", "yeti", "scarlett", "focusrite", "elgato", "mv7", "sm7"
        ]
        if externalRawDevices.contains(where: { normalized.contains($0) }) {
            return MicrophoneVoiceProcessingDecision(shouldEnable: false, reason: "external_or_headset_raw_capture")
        }
        let echoRiskDevices = ["built-in", "macbook", "studio display", "display audio", "iphone microphone"]
        if normalized.isEmpty || echoRiskDevices.contains(where: { normalized.contains($0) }) {
            return MicrophoneVoiceProcessingDecision(shouldEnable: true, reason: "echo_risk_voice_processing")
        }
        return MicrophoneVoiceProcessingDecision(shouldEnable: true, reason: "unknown_route_voice_processing")
    }
}

final class AppleMicrophoneCaptureService: MicrophoneCaptureServicing, @unchecked Sendable {
    static let defaultVoiceProcessingPolicy: MicrophoneVoiceProcessingPolicy = .disabled

    private let engine = AVAudioEngine()
    private let analyzer = AppleAccelerateAudioAnalyzer()
    private let continuationBox = AudioBufferContinuationBox()
    private let voiceProcessingPolicy: MicrophoneVoiceProcessingPolicy

    init(voiceProcessingPolicy: MicrophoneVoiceProcessingPolicy = AppleMicrophoneCaptureService.defaultVoiceProcessingPolicy) {
        self.voiceProcessingPolicy = voiceProcessingPolicy
    }

    func hasPermission() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    func startCapture(inputDeviceUID: String? = nil) async throws -> AsyncStream<AudioBuffer> {
        guard await requestPermission() else { throw AudioCaptureError.microphonePermissionDenied }

        stopCapture()
        let input = engine.inputNode
        if let inputDeviceUID {
            try configureInputDevice(uid: inputDeviceUID, on: input)
        }
        configureVoiceProcessing(on: input)
        let format = input.outputFormat(forBus: 0)

        let stream = AsyncStream<AudioBuffer> { continuation in
            self.continuationBox.set(continuation)
        }

        let continuationBox = continuationBox
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [analyzer, continuationBox] buffer, time in
            let result = analyzer.analyze(buffer)
            continuationBox.yield(AudioBuffer(pcmBuffer: buffer.copiedForAsyncUse(), time: time, rms: result.rms, peak: result.peak, createdAt: Date(), audioSource: .microphone))
        }

        engine.prepare()
        try engine.start()
        return stream
    }

    func stopCapture() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        disableVoiceProcessingIfNeeded(on: engine.inputNode)
        continuationBox.finish()
    }

    private func configureInputDevice(uid: String, on input: AVAudioInputNode) throws {
        guard let deviceID = CoreAudioDeviceProvider.deviceID(forUID: uid, direction: .input) else {
            throw AudioCaptureError.audioDeviceUnavailable("Selected microphone")
        }

        var mutableDeviceID = deviceID
        guard let audioUnit = input.audioUnit else {
            throw AudioCaptureError.audioDeviceUnavailable("Selected microphone")
        }

        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            AppLog.audio.error("Failed to select microphone device \(uid, privacy: .public): \(status, privacy: .public)")
            throw AudioCaptureError.audioDeviceUnavailable("Selected microphone")
        }
    }

    private func configureVoiceProcessing(on input: AVAudioInputNode) {
        guard !ProcessInfo.processInfo.isRunningXCTest, #available(macOS 10.15, *) else { return }
        let decision = MicrophoneVoiceProcessingSelector.decision(
            policy: voiceProcessingPolicy,
            deviceName: AVCaptureDevice.default(for: .audio)?.localizedName
        )
        guard decision.shouldEnable else {
            disableVoiceProcessingIfNeeded(on: input)
            AppLog.audio.info("Microphone voice processing disabled reason=\(decision.reason, privacy: .public)")
            return
        }
        do {
            try input.setVoiceProcessingEnabled(true)
            input.isVoiceProcessingBypassed = false
            input.isVoiceProcessingAGCEnabled = true
            AppLog.audio.info("Microphone voice processing enabled reason=\(decision.reason, privacy: .public)")
        } catch {
            AppLog.audio.info("Microphone voice processing unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func disableVoiceProcessingIfNeeded(on input: AVAudioInputNode) {
        guard !ProcessInfo.processInfo.isRunningXCTest, #available(macOS 10.15, *) else { return }
        do {
            input.isVoiceProcessingBypassed = true
            input.isVoiceProcessingAGCEnabled = false
            try input.setVoiceProcessingEnabled(false)
            AppLog.audio.info("Microphone voice processing disabled to preserve system playback")
        } catch {
            AppLog.audio.info("Microphone voice processing disable skipped: \(error.localizedDescription, privacy: .public)")
        }
    }
}

private final class AudioBufferContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<AudioBuffer>.Continuation?

    func set(_ continuation: AsyncStream<AudioBuffer>.Continuation) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func yield(_ buffer: AudioBuffer) {
        lock.lock()
        let continuation = continuation
        lock.unlock()
        continuation?.yield(buffer)
    }

    func finish() {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.finish()
    }
}
