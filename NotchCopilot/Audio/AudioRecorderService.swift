@preconcurrency import AVFoundation
import Foundation

@MainActor
final class AudioRecorderService {
    private var file: AVAudioFile?
    private var outputFormat: AVAudioFormat?

    var isRecording: Bool {
        file != nil
    }

    private var defaultOutputFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    }

    func startRecording(to url: URL, format: AVAudioFormat) throws {
        file = try AVAudioFile(forWriting: url, settings: format.settings)
        outputFormat = format
    }

    func startRecording(to url: URL) throws {
        let format = defaultOutputFormat
        file = try AVAudioFile(forWriting: url, settings: format.settings)
        outputFormat = format
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let file, let outputFormat else { return }
        do {
            let writableBuffer = try convertedBuffer(from: buffer, to: outputFormat)
            try file.write(from: writableBuffer)
        } catch {
            AppLog.audio.error("Failed to write audio buffer: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stopRecording() {
        file = nil
        outputFormat = nil
    }

    private func convertedBuffer(from buffer: AVAudioPCMBuffer, to outputFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if buffer.format == outputFormat {
            return buffer
        }

        guard let converter = AVAudioConverter(from: buffer.format, to: outputFormat) else {
            throw AudioCaptureError.recorderUnavailable
        }

        let sourceRate = max(buffer.format.sampleRate, 1)
        let ratio = outputFormat.sampleRate / sourceRate
        let capacity = AVAudioFrameCount(max(1, Double(buffer.frameLength) * ratio + 16))
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw AudioCaptureError.recorderUnavailable
        }

        let inputState = ConverterInputState(buffer: buffer)
        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { _, status in
            if inputState.didProvideInput {
                status.pointee = .noDataNow
                return nil
            }
            inputState.didProvideInput = true
            status.pointee = .haveData
            return inputState.buffer
        }

        if let error {
            throw error
        }
        return outputBuffer
    }
}

private final class ConverterInputState: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var didProvideInput = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}
