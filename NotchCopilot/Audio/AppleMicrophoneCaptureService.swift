@preconcurrency import AVFoundation
import Foundation

enum MicrophoneVoiceProcessingPolicy: String, Equatable, Sendable {
    case disabled
    case enabled
}

final class AppleMicrophoneCaptureService: @unchecked Sendable {
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

    func startCapture() async throws -> AsyncStream<AudioBuffer> {
        guard await requestPermission() else { throw AudioCaptureError.microphonePermissionDenied }

        stopCapture()
        let input = engine.inputNode
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

    private func configureVoiceProcessing(on input: AVAudioInputNode) {
        guard !ProcessInfo.processInfo.isRunningXCTest, #available(macOS 10.15, *) else { return }
        switch voiceProcessingPolicy {
        case .disabled:
            disableVoiceProcessingIfNeeded(on: input)
        case .enabled:
            do {
                try input.setVoiceProcessingEnabled(true)
                input.isVoiceProcessingBypassed = false
                input.isVoiceProcessingAGCEnabled = true
                AppLog.audio.info("Microphone voice processing enabled")
            } catch {
                AppLog.audio.info("Microphone voice processing unavailable: \(error.localizedDescription, privacy: .public)")
            }
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
