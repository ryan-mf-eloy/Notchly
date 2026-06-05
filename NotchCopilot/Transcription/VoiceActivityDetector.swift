import AVFoundation
import Foundation

enum VoiceActivityState: String, Sendable, Equatable {
    case silence
    case noise
    case lowAudio
    case speechLikely
    case speechActive
    case hangover
}

enum VoiceActivityDetectionEngine: String, Codable, Sendable, Equatable, Hashable {
    case heuristicEnergy = "heuristic_energy"
    case appleSpeechDetector = "apple_speech_detector"
    case vadDisabledPassthrough = "vad_disabled_passthrough"
    case evaluationReplay = "evaluation_replay"
}

struct VoiceActivityDecision: Sendable, Equatable {
    var source: TranscriptAudioSource
    var detectionEngine: VoiceActivityDetectionEngine
    var state: VoiceActivityState
    var shouldForwardToASR: Bool
    var speechProbability: Double
    var rms: Float
    var peak: Float
    var noiseFloor: Float
    var snrDb: Double
    var zeroCrossingRate: Double
    var dynamicRange: Float
    var envelopeVariation: Double
    var isClipping: Bool
    var reason: String

    var isSpeech: Bool {
        state == .lowAudio || state == .speechLikely || state == .speechActive || state == .hangover
    }
}

struct VoiceActivityDetectorConfiguration: Sendable, Hashable {
    var absoluteSpeechRMS: Float
    var likelySpeechSNRDb: Double
    var activeSpeechSNRDb: Double
    var clickPeakThreshold: Float
    var clickRMSRatio: Float
    var tonalEnvelopeVariationThreshold: Double
    var broadbandNoiseZeroCrossingThreshold: Double
    var broadbandNoiseEnvelopeVariationThreshold: Double
    var hangoverDuration: TimeInterval
    var noiseFloorAdaptation: Float

    init(
        absoluteSpeechRMS: Float = 0.00085,
        likelySpeechSNRDb: Double = 5.5,
        activeSpeechSNRDb: Double = 9.5,
        clickPeakThreshold: Float = 0.55,
        clickRMSRatio: Float = 0.16,
        tonalEnvelopeVariationThreshold: Double = 0.045,
        broadbandNoiseZeroCrossingThreshold: Double = 0.42,
        broadbandNoiseEnvelopeVariationThreshold: Double = 0.24,
        hangoverDuration: TimeInterval = 1.55,
        noiseFloorAdaptation: Float = 0.05
    ) {
        self.absoluteSpeechRMS = absoluteSpeechRMS
        self.likelySpeechSNRDb = likelySpeechSNRDb
        self.activeSpeechSNRDb = activeSpeechSNRDb
        self.clickPeakThreshold = clickPeakThreshold
        self.clickRMSRatio = clickRMSRatio
        self.tonalEnvelopeVariationThreshold = tonalEnvelopeVariationThreshold
        self.broadbandNoiseZeroCrossingThreshold = broadbandNoiseZeroCrossingThreshold
        self.broadbandNoiseEnvelopeVariationThreshold = broadbandNoiseEnvelopeVariationThreshold
        self.hangoverDuration = hangoverDuration
        self.noiseFloorAdaptation = min(max(noiseFloorAdaptation, 0.01), 0.35)
    }
}

struct VoiceActivityDetector: Sendable {
    private(set) var configuration: VoiceActivityDetectorConfiguration
    private var noiseFloorBySource: [TranscriptAudioSource: Float] = [:]
    private var lastSpeechAtBySource: [TranscriptAudioSource: Date] = [:]

    init(configuration: VoiceActivityDetectorConfiguration = VoiceActivityDetectorConfiguration()) {
        self.configuration = configuration
    }

    mutating func reset() {
        noiseFloorBySource.removeAll()
        lastSpeechAtBySource.removeAll()
    }

    mutating func analyze(
        _ buffer: AudioBuffer,
        quality: SpeechAudioQualitySnapshot? = nil,
        now: Date? = nil
    ) -> VoiceActivityDecision {
        let source = buffer.audioSource == .unknown ? (quality?.source ?? .unknown) : buffer.audioSource
        let features = Self.features(from: buffer)
        let timestamp = now ?? buffer.createdAt
        let sensitivity = VoiceActivitySourceSensitivity.profile(for: source)
        let previousNoiseFloor = noiseFloorBySource[source]
        let rawMeasuredNoiseFloor = quality?.noiseFloor ?? previousNoiseFloor ?? max(features.rms * 0.35, 0.00025)
        let bootstrappedNoiseFloor = previousNoiseFloor == nil
            ? min(rawMeasuredNoiseFloor, max(features.rms * 0.35, 0.00025))
            : rawMeasuredNoiseFloor
        let unclampedMeasuredNoiseFloor = bootstrappedNoiseFloor
        let priorNoiseFloor = previousNoiseFloor ?? unclampedMeasuredNoiseFloor
        let measuredNoiseFloor = previousNoiseFloor == nil
            ? unclampedMeasuredNoiseFloor
            : min(unclampedMeasuredNoiseFloor, max(priorNoiseFloor, 0.0002) * 1.25)
        let adaptiveNoiseFloor = max(0.0002, min(max(priorNoiseFloor, measuredNoiseFloor), 0.04))
        let snrDb = Self.snrDb(rms: features.rms, noiseFloor: adaptiveNoiseFloor)
        let isClipping = (quality?.isClipping ?? false) || features.peak >= 0.98
        let impulseDominance = features.peak / max(features.rms, 0.000001)
        let isImpulseClick = features.peak >= configuration.clickPeakThreshold &&
            features.duration <= 0.14 &&
            (features.rms <= max(0.00001, features.peak * configuration.clickRMSRatio) || impulseDominance >= 14)
        let isSustainedTonalAudio = features.envelopeVariation < configuration.tonalEnvelopeVariationThreshold &&
            features.rms >= 0.003 &&
            features.zeroCrossingRate > 0.012 &&
            features.zeroCrossingRate < 0.18
        let isSustainedBroadbandNoise = features.duration >= 0.08 &&
            features.rms >= 0.0018 &&
            features.zeroCrossingRate >= configuration.broadbandNoiseZeroCrossingThreshold &&
            features.envelopeVariation <= configuration.broadbandNoiseEnvelopeVariationThreshold &&
            impulseDominance <= 8
        let adaptiveSpeechRMS = max(configuration.absoluteSpeechRMS * sensitivity.absoluteRMSMultiplier, adaptiveNoiseFloor * sensitivity.noiseFloorLift)
        let likelyByEnergy = features.rms >= adaptiveSpeechRMS || features.peak >= sensitivity.likelyPeak
        let activeByEnergy = features.rms >= max(adaptiveSpeechRMS * sensitivity.activeRMSMultiplier, sensitivity.activeRMSFloor) || features.peak >= sensitivity.activePeak
        let speechShapeLikely = features.zeroCrossingRate > 0.010 &&
            features.zeroCrossingRate < 0.48 &&
            features.dynamicRange > sensitivity.minimumSpeechDynamicRange &&
            features.envelopeVariation > 0.030
        let onsetSpeechShapeLikely = features.zeroCrossingRate > 0.010 &&
            features.zeroCrossingRate < 0.48 &&
            features.dynamicRange > sensitivity.minimumSpeechDynamicRange * 0.72 &&
            features.envelopeVariation > 0.012
        let lowEnergySpeechOnset = onsetSpeechShapeLikely &&
            features.rms >= max(sensitivity.onsetRMSFloor, adaptiveNoiseFloor * 1.02) &&
            features.peak >= sensitivity.onsetPeakFloor
        let recentlyHadSpeech = lastSpeechAtBySource[source].map { timestamp.timeIntervalSince($0) <= 0.85 } ?? false
        let lowEnergySpeechContinuation = recentlyHadSpeech &&
            features.zeroCrossingRate > 0.008 &&
            features.zeroCrossingRate < 0.50 &&
            features.dynamicRange > sensitivity.minimumSpeechDynamicRange * 0.48 &&
            features.envelopeVariation > 0.006 &&
            features.rms >= max(sensitivity.silenceRMSFloor * 0.66, adaptiveNoiseFloor * 0.14) &&
            (features.peak >= sensitivity.silencePeakFloor * 1.32 || snrDb >= -18.0)

        let state: VoiceActivityState
        let probability: Double
        let reason: String
        if buffer.pcmBuffer == nil || ((features.rms <= sensitivity.silenceRMSFloor || features.peak <= sensitivity.silencePeakFloor) && !lowEnergySpeechContinuation) {
            state = .silence
            probability = 0.0
            reason = "below_floor"
            updateNoiseFloor(source: source, rms: features.rms)
        } else if isImpulseClick {
            state = .noise
            probability = 0.03
            reason = "impulse_click"
            updateNoiseFloor(source: source, rms: min(features.rms, adaptiveNoiseFloor))
        } else if isSustainedTonalAudio && lastSpeechAtBySource[source] == nil {
            state = .noise
            probability = 0.08
            reason = "sustained_tonal_non_speech"
            updateNoiseFloor(source: source, rms: min(features.rms, adaptiveNoiseFloor))
        } else if isSustainedBroadbandNoise {
            state = .noise
            probability = 0.06
            reason = "sustained_broadband_non_speech"
            updateNoiseFloor(source: source, rms: min(features.rms, adaptiveNoiseFloor))
        } else if activeByEnergy && (snrDb >= configuration.activeSpeechSNRDb || speechShapeLikely) {
            state = .speechActive
            probability = min(0.99, max(0.75, 0.70 + snrDb / 55.0))
            reason = isClipping ? "speech_active_clipping_guard" : "speech_active"
            lastSpeechAtBySource[source] = timestamp
        } else if (likelyByEnergy && (snrDb >= configuration.likelySpeechSNRDb || speechShapeLikely)) || lowEnergySpeechOnset {
            state = .speechLikely
            probability = lowEnergySpeechOnset
                ? min(0.78, max(0.56, 0.54 + snrDb / 80.0))
                : min(0.88, max(0.52, 0.48 + snrDb / 60.0))
            reason = lowEnergySpeechOnset ? "low_energy_speech_onset" : "speech_likely"
            lastSpeechAtBySource[source] = timestamp
        } else if lowEnergySpeechContinuation {
            state = .lowAudio
            probability = min(0.66, max(0.38, 0.36 + snrDb / 95.0))
            reason = "low_audio_speech_continuation"
            lastSpeechAtBySource[source] = timestamp
        } else if let lastSpeechAt = lastSpeechAtBySource[source],
                  timestamp.timeIntervalSince(lastSpeechAt) <= configuration.hangoverDuration,
                  features.rms >= max(sensitivity.hangoverRMSFloor, adaptiveNoiseFloor * 1.08) {
            state = .hangover
            probability = 0.42
            reason = "hangover"
        } else {
            state = features.rms > adaptiveNoiseFloor * 1.7 ? .noise : .silence
            probability = state == .noise ? 0.12 : 0.0
            reason = state == .noise ? "non_speech_noise" : "silence"
            updateNoiseFloor(source: source, rms: features.rms)
        }

        return VoiceActivityDecision(
            source: source,
            detectionEngine: .heuristicEnergy,
            state: state,
            shouldForwardToASR: state == .lowAudio || state == .speechLikely || state == .speechActive || state == .hangover,
            speechProbability: probability,
            rms: features.rms,
            peak: features.peak,
            noiseFloor: adaptiveNoiseFloor,
            snrDb: snrDb,
            zeroCrossingRate: features.zeroCrossingRate,
            dynamicRange: features.dynamicRange,
            envelopeVariation: features.envelopeVariation,
            isClipping: isClipping,
            reason: reason
        )
    }

    private mutating func updateNoiseFloor(source: TranscriptAudioSource, rms: Float) {
        guard rms >= 0, rms < 0.04 else { return }
        let previous = noiseFloorBySource[source] ?? max(rms, 0.00025)
        let alpha = configuration.noiseFloorAdaptation
        noiseFloorBySource[source] = max(0.0002, previous * (1 - alpha) + rms * alpha)
    }

    private static func snrDb(rms: Float, noiseFloor: Float) -> Double {
        20.0 * log10(Double(max(rms, 0.000001) / max(noiseFloor, 0.000001)))
    }

    private static func features(from buffer: AudioBuffer) -> (rms: Float, peak: Float, zeroCrossingRate: Double, dynamicRange: Float, envelopeVariation: Double, duration: TimeInterval) {
        guard let pcmBuffer = buffer.pcmBuffer,
              let channelData = pcmBuffer.floatChannelData,
              pcmBuffer.frameLength > 0,
              pcmBuffer.format.channelCount > 0 else {
            return (max(buffer.rms, 0), max(buffer.peak, 0), 0, max(buffer.peak - buffer.rms, 0), 0, 0)
        }

        let frames = Int(pcmBuffer.frameLength)
        let channels = Int(pcmBuffer.format.channelCount)
        let envelopeBlockSize = max(80, min(320, frames / 8))
        var blockSquares = Array(repeating: Float(0), count: max(1, Int(ceil(Double(frames) / Double(envelopeBlockSize)))))
        var blockCounts = Array(repeating: 0, count: blockSquares.count)
        var squareSum: Float = 0
        var peak: Float = 0
        var minimum: Float = .greatestFiniteMagnitude
        var maximum: Float = -.greatestFiniteMagnitude
        var crossings = 0
        var previous: Float = 0
        var hasPrevious = false

        for channelIndex in 0..<channels {
            let channel = channelData[channelIndex]
            for frameIndex in 0..<frames {
                let sample = channel[frameIndex]
                squareSum += sample * sample
                let blockIndex = min(blockSquares.count - 1, frameIndex / envelopeBlockSize)
                blockSquares[blockIndex] += sample * sample
                blockCounts[blockIndex] += 1
                peak = max(peak, abs(sample))
                minimum = min(minimum, sample)
                maximum = max(maximum, sample)
                if hasPrevious && ((sample >= 0 && previous < 0) || (sample < 0 && previous >= 0)) {
                    crossings += 1
                }
                previous = sample
                hasPrevious = true
            }
        }

        let sampleCount = max(1, frames * channels)
        let rms = sqrt(squareSum / Float(sampleCount))
        let blockRMSValues = zip(blockSquares, blockCounts).compactMap { square, count -> Double? in
            guard count > 0 else { return nil }
            return Double(sqrt(square / Float(count)))
        }
        let envelopeVariation = coefficientOfVariation(blockRMSValues)
        let duration = pcmBuffer.format.sampleRate > 0 ? Double(frames) / pcmBuffer.format.sampleRate : 0
        return (
            max(rms, buffer.rms),
            max(peak, buffer.peak),
            Double(crossings) / Double(sampleCount),
            max(0, maximum - minimum),
            envelopeVariation,
            duration
        )
    }

    private static func coefficientOfVariation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        guard mean > 0 else { return 0 }
        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count)
        return sqrt(variance) / mean
    }
}

private struct VoiceActivitySourceSensitivity {
    var absoluteRMSMultiplier: Float
    var noiseFloorLift: Float
    var likelyPeak: Float
    var activePeak: Float
    var activeRMSMultiplier: Float
    var activeRMSFloor: Float
    var minimumSpeechDynamicRange: Float
    var onsetRMSFloor: Float
    var onsetPeakFloor: Float
    var hangoverRMSFloor: Float
    var silenceRMSFloor: Float
    var silencePeakFloor: Float

    static func profile(for source: TranscriptAudioSource) -> VoiceActivitySourceSensitivity {
        switch source {
        case .system:
            VoiceActivitySourceSensitivity(
                absoluteRMSMultiplier: 0.42,
                noiseFloorLift: 1.30,
                likelyPeak: 0.0065,
                activePeak: 0.052,
                activeRMSMultiplier: 1.36,
                activeRMSFloor: 0.0022,
                minimumSpeechDynamicRange: 0.00024,
                onsetRMSFloor: 0.00011,
                onsetPeakFloor: 0.00045,
                hangoverRMSFloor: 0.00016,
                silenceRMSFloor: 0.000055,
                silencePeakFloor: 0.00008
            )
        case .microphone:
            VoiceActivitySourceSensitivity(
                absoluteRMSMultiplier: 0.48,
                noiseFloorLift: 1.45,
                likelyPeak: 0.0070,
                activePeak: 0.060,
                activeRMSMultiplier: 1.42,
                activeRMSFloor: 0.0024,
                minimumSpeechDynamicRange: 0.00028,
                onsetRMSFloor: 0.00012,
                onsetPeakFloor: 0.00050,
                hangoverRMSFloor: 0.00018,
                silenceRMSFloor: 0.000060,
                silencePeakFloor: 0.00009
            )
        default:
            VoiceActivitySourceSensitivity(
                absoluteRMSMultiplier: 0.50,
                noiseFloorLift: 1.45,
                likelyPeak: 0.0075,
                activePeak: 0.062,
                activeRMSMultiplier: 1.44,
                activeRMSFloor: 0.0025,
                minimumSpeechDynamicRange: 0.00030,
                onsetRMSFloor: 0.00013,
                onsetPeakFloor: 0.00055,
                hangoverRMSFloor: 0.00019,
                silenceRMSFloor: 0.000065,
                silencePeakFloor: 0.000095
            )
        }
    }
}
