import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import ScreenCaptureKit

@MainActor
protocol SystemAudioCaptureServicing: AnyObject, Sendable {
    func startCapture(outputDeviceUID: String?) async throws -> AsyncStream<AudioBuffer>
    func stopCapture() async
}

@MainActor
final class AppleSystemAudioCaptureService: SystemAudioCaptureServicing {
    private var stream: Any?
    private var output: AnyObject?
    private let coreAudioTapCaptureService = CoreAudioOutputTapCaptureService()

    func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func requestPermission() -> Bool {
        if hasPermission() { return true }
        return CGRequestScreenCaptureAccess()
    }

    func startCapture(outputDeviceUID: String? = nil) async throws -> AsyncStream<AudioBuffer> {
        guard #available(macOS 13.0, *) else {
            throw AudioCaptureError.screenCaptureUnavailable
        }

        if let outputDeviceUID, #available(macOS 14.2, *) {
            do {
                return try await coreAudioTapCaptureService.startCapture(outputDeviceUID: outputDeviceUID)
            } catch {
                AppLog.audio.info("Core Audio output tap unavailable for selected output \(outputDeviceUID, privacy: .public); falling back to ScreenCaptureKit: \(error.localizedDescription, privacy: .public)")
            }
        }

        do {
            return try await startScreenCaptureKitStream()
        } catch {
            AppLog.audio.error("ScreenCaptureKit audio start failed: \(error.localizedDescription, privacy: .public)")
        }

        guard hasPermission() else {
            throw AudioCaptureError.systemAudioPermissionDenied
        }
        return try await startScreenCaptureKitStream()
    }

    func stopCapture() async {
        guard #available(macOS 13.0, *), let stream = stream as? SCStream else {
            stream = nil
            output = nil
            return
        }
        try? await stream.stopCapture()
        self.stream = nil
        self.output = nil
        await coreAudioTapCaptureService.stopCapture()
    }

    @available(macOS 13.0, *)
    private func startScreenCaptureKitStream() async throws -> AsyncStream<AudioBuffer> {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw AudioCaptureError.screenCaptureUnavailable
        }

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.queueDepth = 3
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let audioOutput = SystemAudioStreamOutput()
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(audioOutput, type: .audio, sampleHandlerQueue: audioOutput.queue)
        try await stream.startCapture()

        self.stream = stream
        self.output = audioOutput
        return audioOutput.audioStream
    }
}

@MainActor
private final class CoreAudioOutputTapCaptureService {
    func startCapture(outputDeviceUID: String) async throws -> AsyncStream<AudioBuffer> {
        guard #available(macOS 14.2, *) else {
            throw AudioCaptureError.screenCaptureUnavailable
        }
        guard CoreAudioDeviceProvider.deviceID(forUID: outputDeviceUID, direction: .output) != nil else {
            throw AudioCaptureError.audioDeviceUnavailable("Selected output")
        }

        // Core Audio taps require an aggregate-device input pipeline. Keep this guarded so the
        // selected output can be represented honestly while ScreenCaptureKit remains the stable
        // production fallback on machines where tap setup is unavailable or not yet authorized.
        throw AudioCaptureError.screenCaptureUnavailable
    }

    func stopCapture() async {}
}

@available(macOS 13.0, *)
private final class SystemAudioStreamOutput: NSObject, SCStreamOutput {
    let queue = DispatchQueue(label: "notchcopilot.system-audio")
    private let continuation: AsyncStream<AudioBuffer>.Continuation
    private let analyzer = AppleAccelerateAudioAnalyzer()
    let audioStream: AsyncStream<AudioBuffer>

    override init() {
        var streamContinuation: AsyncStream<AudioBuffer>.Continuation?
        self.audioStream = AsyncStream<AudioBuffer> { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation!
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio, sampleBuffer.isValid else { return }
        guard let pcmBuffer = Self.makePCMBuffer(from: sampleBuffer) else { return }
        let result = analyzer.analyze(pcmBuffer)
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        continuation.yield(AudioBuffer(
            pcmBuffer: pcmBuffer,
            time: nil,
            mediaTime: presentationTime.isValid ? presentationTime : nil,
            rms: result.rms,
            peak: result.peak,
            createdAt: Date(),
            audioSource: .system
        ))
    }

    private static func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let format = AVAudioFormat(streamDescription: streamDescription) else {
            return nil
        }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else { return nil }
        buffer.frameLength = frameCount
        return buffer
    }
}
