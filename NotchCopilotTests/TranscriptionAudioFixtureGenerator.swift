import AVFoundation
import Foundation
@testable import NotchCopilot

enum TranscriptionAudioFixtureProfile: String, Codable, Sendable {
    case clean
    case noisy
    case reverb
    case overlap
    case lowVolume
    case clipping
    case silence
    case clicks
    case music
    case breathing
    case codeSwitching
}

struct TranscriptionAudioFixtureManifestItem: Codable, Sendable {
    var id: String
    var locale: String
    var profile: TranscriptionAudioFixtureProfile
    var reference: String
    var jargon: [String]
}

enum TranscriptionAudioFixtureGenerator {
    static func manifest() throws -> [TranscriptionAudioFixtureManifestItem] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/transcription_audio_fixtures.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([TranscriptionAudioFixtureManifestItem].self, from: data)
    }

    static func buffers(
        profile: TranscriptionAudioFixtureProfile,
        source: TranscriptAudioSource = .microphone,
        chunks: Int = 6,
        sampleRate: Double = 16_000
    ) -> [NotchCopilot.AudioBuffer] {
        (0..<chunks).map { index in
            switch profile {
            case .silence:
                return buffer(samples: Array(repeating: 0, count: 1_600), sampleRate: sampleRate, source: source, offset: index)
            case .clicks:
                var samples = Array(repeating: Float(0), count: 1_600)
                if index % 2 == 0 {
                    samples[24] = 0.95
                    samples[25] = -0.92
                }
                return buffer(samples: samples, sampleRate: sampleRate, source: source, offset: index)
            case .music:
                return tonalMusicBuffer(sampleRate: sampleRate, source: source, offset: index)
            case .breathing:
                return breathingNoiseBuffer(sampleRate: sampleRate, source: source, offset: index)
            case .lowVolume:
                return speechLikeBuffer(amplitude: 0.006, sampleRate: sampleRate, source: source, offset: index)
            case .clipping:
                return speechLikeBuffer(amplitude: 1.05, sampleRate: sampleRate, source: source, offset: index)
            case .noisy:
                return speechLikeBuffer(amplitude: 0.035, noise: 0.008, sampleRate: sampleRate, source: source, offset: index)
            case .reverb:
                return speechLikeBuffer(amplitude: 0.028, echo: 0.35, sampleRate: sampleRate, source: source, offset: index)
            case .overlap:
                return speechLikeBuffer(amplitude: 0.030, secondTone: 330, sampleRate: sampleRate, source: source, offset: index)
            case .codeSwitching, .clean:
                return speechLikeBuffer(amplitude: 0.032, sampleRate: sampleRate, source: source, offset: index)
            }
        }
    }

    static func speechLikeBuffer(
        amplitude: Float = 0.032,
        noise: Float = 0,
        echo: Float = 0,
        secondTone: Double? = nil,
        sampleRate: Double = 16_000,
        source: TranscriptAudioSource = .microphone,
        offset: Int = 0
    ) -> NotchCopilot.AudioBuffer {
        let frames = 1_600
        var samples = [Float]()
        samples.reserveCapacity(frames)
        for index in 0..<frames {
            let t = Double(index + offset * frames) / sampleRate
            let envelope = 0.55 + 0.45 * sin(2 * .pi * 5.0 * t)
            var value = Double(amplitude) * envelope * (sin(2 * .pi * 180 * t) + 0.55 * sin(2 * .pi * 410 * t))
            if let secondTone {
                value += Double(amplitude) * 0.55 * sin(2 * .pi * secondTone * t)
            }
            if echo > 0, index > 180 {
                value += Double(samples[index - 180]) * Double(echo)
            }
            if noise > 0 {
                let deterministicNoise = Float(((index * 1_103 + offset * 97) % 200) - 100) / 100
                value += Double(noise * deterministicNoise)
            }
            samples.append(Float(max(-0.98, min(0.98, value))))
        }
        return buffer(samples: samples, sampleRate: sampleRate, source: source, offset: offset)
    }

    static func tonalMusicBuffer(
        amplitude: Float = 0.045,
        sampleRate: Double = 16_000,
        source: TranscriptAudioSource = .microphone,
        offset: Int = 0
    ) -> NotchCopilot.AudioBuffer {
        let frames = 1_600
        var samples = [Float]()
        samples.reserveCapacity(frames)
        for index in 0..<frames {
            let t = Double(index + offset * frames) / sampleRate
            let value = Double(amplitude) * (
                sin(2 * .pi * 440 * t) +
                0.35 * sin(2 * .pi * 880 * t)
            )
            samples.append(Float(max(-0.98, min(0.98, value))))
        }
        return buffer(samples: samples, sampleRate: sampleRate, source: source, offset: offset)
    }

    static func breathingNoiseBuffer(
        amplitude: Float = 0.018,
        sampleRate: Double = 16_000,
        source: TranscriptAudioSource = .microphone,
        offset: Int = 0
    ) -> NotchCopilot.AudioBuffer {
        let frames = 1_600
        var samples = [Float]()
        samples.reserveCapacity(frames)
        for index in 0..<frames {
            let t = Double(index + offset * frames) / sampleRate
            let slowEnvelope = 0.84 + 0.16 * sin(2 * .pi * 1.1 * t)
            let deterministic = Float((index * 1_729 + offset * 241) % 1_000) / 1_000
            let alternatingSign: Float = index.isMultiple(of: 2) ? 1 : -1
            let broadbandNoise = alternatingSign * (0.55 + deterministic * 0.45)
            let sample = Double(amplitude) * slowEnvelope * Double(broadbandNoise)
            samples.append(Float(max(-0.98, min(0.98, sample))))
        }
        return buffer(samples: samples, sampleRate: sampleRate, source: source, offset: offset)
    }

    static func buffer(
        samples: [Float],
        sampleRate: Double = 16_000,
        source: TranscriptAudioSource = .microphone,
        offset: Int = 0
    ) -> NotchCopilot.AudioBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        pcm.frameLength = AVAudioFrameCount(samples.count)
        let channel = pcm.floatChannelData!.pointee
        var squareSum: Float = 0
        var peak: Float = 0
        for (index, sample) in samples.enumerated() {
            channel[index] = sample
            squareSum += sample * sample
            peak = max(peak, abs(sample))
        }
        let rms = sqrt(squareSum / Float(max(samples.count, 1)))
        return NotchCopilot.AudioBuffer(
            pcmBuffer: pcm,
            time: AVAudioTime(sampleTime: AVAudioFramePosition(offset * samples.count), atRate: sampleRate),
            mediaTime: nil,
            rms: rms,
            peak: peak,
            createdAt: Date(timeIntervalSinceReferenceDate: Double(offset) * Double(samples.count) / sampleRate),
            audioSource: source
        )
    }
}
