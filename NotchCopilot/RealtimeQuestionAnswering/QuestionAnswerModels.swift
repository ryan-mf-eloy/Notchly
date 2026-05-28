import Accelerate
import AVFoundation
import CoreML
import Foundation

struct QuestionCandidate: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let meetingId: UUID
    let rawText: String
    let normalizedText: String
    let language: String?
    let speakerId: UUID?
    let speakerLabel: String?
    let startTime: TimeInterval
    let endTime: TimeInterval?
    let sourceSegmentIds: [UUID]
    let isPartial: Bool
    let detectedAt: Date
    let multimodalSignal: QuestionMultimodalSignal?
    var classification: QuestionClassification?
    var status: QuestionStatus

    init(
        id: UUID = UUID(),
        meetingId: UUID,
        rawText: String,
        normalizedText: String,
        language: String? = nil,
        speakerId: UUID? = nil,
        speakerLabel: String? = nil,
        startTime: TimeInterval,
        endTime: TimeInterval? = nil,
        sourceSegmentIds: [UUID],
        isPartial: Bool,
        detectedAt: Date = Date(),
        multimodalSignal: QuestionMultimodalSignal? = nil,
        classification: QuestionClassification? = nil,
        status: QuestionStatus = .candidate
    ) {
        self.id = id
        self.meetingId = meetingId
        self.rawText = rawText
        self.normalizedText = normalizedText
        self.language = language
        self.speakerId = speakerId
        self.speakerLabel = speakerLabel
        self.startTime = startTime
        self.endTime = endTime
        self.sourceSegmentIds = sourceSegmentIds
        self.isPartial = isPartial
        self.detectedAt = detectedAt
        self.multimodalSignal = multimodalSignal
        self.classification = classification
        self.status = status
    }
}

struct QuestionMultimodalSignal: Codable, Hashable, Sendable {
    var language: String?
    var asrConfidence: Double?
    var isFinal: Bool
    var isPartial: Bool
    var speakerLabel: String?
    var audioSource: TranscriptAudioSource
    var duration: TimeInterval
    var hasTerminalPause: Bool
    var partialStability: Double
    var partialRevisionCount: Int
    var rms: Double?
    var peak: Double?
    var isClipping: Bool
    var isSilence: Bool
    var isTooQuiet: Bool
    var gapCount: Int
    var noiseFloor: Double?
    var audioEnergy: Double?
    var audioLogMel: QuestionAudioLogMelFeature?
    var createdAt: Date

    init(
        language: String? = nil,
        asrConfidence: Double? = nil,
        isFinal: Bool,
        isPartial: Bool,
        speakerLabel: String? = nil,
        audioSource: TranscriptAudioSource = .unknown,
        duration: TimeInterval,
        hasTerminalPause: Bool,
        partialStability: Double = 1,
        partialRevisionCount: Int = 0,
        rms: Double? = nil,
        peak: Double? = nil,
        isClipping: Bool = false,
        isSilence: Bool = false,
        isTooQuiet: Bool = false,
        gapCount: Int = 0,
        noiseFloor: Double? = nil,
        audioEnergy: Double? = nil,
        audioLogMel: QuestionAudioLogMelFeature? = nil,
        createdAt: Date = Date()
    ) {
        self.language = language
        self.asrConfidence = asrConfidence
        self.isFinal = isFinal
        self.isPartial = isPartial
        self.speakerLabel = speakerLabel
        self.audioSource = audioSource
        self.duration = max(0, duration)
        self.hasTerminalPause = hasTerminalPause
        self.partialStability = min(max(partialStability, 0), 1)
        self.partialRevisionCount = max(0, partialRevisionCount)
        self.rms = rms.map { min(max($0, 0), 1) }
        self.peak = peak.map { min(max($0, 0), 1) }
        self.isClipping = isClipping
        self.isSilence = isSilence
        self.isTooQuiet = isTooQuiet
        self.gapCount = max(0, gapCount)
        self.noiseFloor = noiseFloor.map { min(max($0, 0), 1) }
        self.audioEnergy = audioEnergy.map { min(max($0, 0), 1) }
        self.audioLogMel = audioLogMel
        self.createdAt = createdAt
    }

    init(segment: TranscriptSegment, quality: SpeechAudioQualitySnapshot? = nil, partialStability: Double = 1, partialRevisionCount: Int = 0) {
        let duration = segment.endTime > segment.startTime ? segment.endTime - segment.startTime : 0
        self.init(
            language: segment.originalLanguage ?? segment.sourceLanguage,
            asrConfidence: segment.engineConfidence ?? segment.confidence,
            isFinal: segment.isFinal,
            isPartial: !segment.isFinal,
            speakerLabel: segment.speakerLabel,
            audioSource: segment.audioSource,
            duration: duration,
            hasTerminalPause: segment.isFinal,
            partialStability: partialStability,
            partialRevisionCount: partialRevisionCount,
            rms: quality.map { Double($0.rms) },
            peak: quality.map { Double($0.peak) },
            isClipping: quality?.isClipping ?? false,
            isSilence: quality.map { SpeechActivityPolicy().classify($0) == .silence } ?? false,
            isTooQuiet: quality?.isTooQuiet ?? false,
            gapCount: quality?.gapCount ?? 0,
            noiseFloor: quality.map { Double($0.noiseFloor) },
            audioEnergy: segment.audioEnergy,
            audioLogMel: nil,
            createdAt: segment.createdAt
        )
    }

    func withPartialStability(_ stability: Double, revisionCount: Int) -> QuestionMultimodalSignal {
        var copy = self
        copy.partialStability = min(max(stability, 0), 1)
        copy.partialRevisionCount = max(0, revisionCount)
        return copy
    }
}

struct QuestionAudioLogMelFeature: Codable, Hashable, Sendable {
    static let expectedBandCount = 40
    static let trainedModelFrameCount = 240
    static let maximumFrameCount = 600

    var bands: Int
    var frames: Int
    var values: [Double]
    var source: String

    init(
        bands: Int = Self.expectedBandCount,
        frames: Int,
        values: [Double],
        source: String = "logmel"
    ) {
        let safeBands = min(max(bands, 1), Self.expectedBandCount)
        let safeFrames = min(max(frames, 1), Self.maximumFrameCount)
        let expectedCount = safeBands * safeFrames
        var normalized = Array(values.prefix(expectedCount)).map { min(max($0, -8), 8) }
        if normalized.count < expectedCount {
            normalized += Array(repeating: 0, count: expectedCount - normalized.count)
        }
        self.bands = safeBands
        self.frames = safeFrames
        self.values = normalized
        self.source = source
    }

    static func proxy(from signal: QuestionMultimodalSignal, targetFrames: Int) -> QuestionAudioLogMelFeature {
        let frames = min(max(targetFrames, 1), maximumFrameCount)
        let energy = min(max(signal.audioEnergy ?? signal.rms ?? 0.006, 0.0001), 1)
        let peak = min(max(signal.peak ?? energy, 0.0001), 1)
        let noise = min(max(signal.noiseFloor ?? 0.001, 0.00001), 1)
        let durationScale = min(max(signal.duration / 8, 0.12), 1)
        let confidence = min(max(signal.asrConfidence ?? 0.85, 0), 1)
        let silencePenalty = (signal.isSilence || signal.isTooQuiet) ? 0.42 : 1
        let clippingPenalty = signal.isClipping ? 0.82 : 1
        let gapPenalty = signal.gapCount > 0 ? max(0.55, 1 - Double(signal.gapCount) * 0.08) : 1
        let baseDb = log10(max(energy, 0.0001)) * 2.4
        let peakLift = log10(max(peak, 0.0001) / max(energy, 0.0001)) * 0.25
        let noiseLift = log10(max(noise, 0.00001)) * 0.18
        var values: [Double] = []
        values.reserveCapacity(expectedBandCount * frames)
        for band in 0..<expectedBandCount {
            let bandPosition = Double(band) / Double(max(expectedBandCount - 1, 1))
            let speechEnvelope = exp(-pow((bandPosition - 0.38) / 0.28, 2))
            let highBandRollOff = 1 - bandPosition * 0.42
            for frame in 0..<frames {
                let framePosition = Double(frame) / Double(max(frames - 1, 1))
                let onset = 0.80 + 0.20 * sin(framePosition * .pi)
                let terminalPause = signal.hasTerminalPause && framePosition > 0.88 ? 0.68 : 1
                let partialPenalty = signal.isPartial ? min(max(signal.partialStability, 0.35), 1) : 1
                let shaped = (baseDb + speechEnvelope * 1.35 + highBandRollOff * 0.35 + peakLift - noiseLift)
                    * durationScale
                    * silencePenalty
                    * clippingPenalty
                    * gapPenalty
                    * onset
                    * terminalPause
                    * partialPenalty
                    * (0.72 + confidence * 0.28)
                values.append(min(max(shaped, -8), 8))
            }
        }
        return QuestionAudioLogMelFeature(frames: frames, values: values, source: "signal_proxy")
    }

    func value(band: Int, frame: Int) -> Double {
        guard band >= 0, band < bands, frame >= 0, frame < frames else { return 0 }
        return values[(band * frames) + frame]
    }
}

final class QuestionAudioLogMelRingBuffer: @unchecked Sendable {
    private struct Chunk {
        var startFrame: Int64
        var endFrame: Int64
        var startTime: TimeInterval
        var endTime: TimeInterval
        var samples: [Float]
    }

    private let lock = NSLock()
    private var chunksBySource: [TranscriptAudioSource: [Chunk]] = [:]
    private var nextFrameBySource: [TranscriptAudioSource: Int64] = [:]
    private let retentionSeconds: TimeInterval
    private let sampleRate = QuestionAudioLogMelExtractor.sampleRate

    init(retentionSeconds: TimeInterval = 45) {
        self.retentionSeconds = max(4, retentionSeconds)
    }

    func reset() {
        lock.lock()
        chunksBySource = [:]
        nextFrameBySource = [:]
        lock.unlock()
    }

    func append(_ buffer: AudioBuffer, meetingStartedAt: Date) {
        guard let pcmBuffer = buffer.pcmBuffer,
              let samples = QuestionAudioLogMelExtractor.monoSamples16k(from: pcmBuffer),
              !samples.isEmpty else { return }
        let source = normalizedSource(buffer.audioSource)
        let duration = TimeInterval(samples.count) / sampleRate
        let endTime = max(0, buffer.createdAt.timeIntervalSince(meetingStartedAt))
        let startTime = max(0, endTime - duration)

        lock.lock()
        let startFrame = nextFrameBySource[source] ?? Int64((startTime * sampleRate).rounded(.down))
        let endFrame = startFrame + Int64(samples.count)
        nextFrameBySource[source] = endFrame
        var chunks = chunksBySource[source] ?? []
        chunks.append(Chunk(
            startFrame: startFrame,
            endFrame: endFrame,
            startTime: startTime,
            endTime: endTime,
            samples: samples
        ))
        trim(&chunks, latestEndTime: endTime)
        chunksBySource[source] = chunks
        lock.unlock()
    }

    func feature(for segment: TranscriptSegment, targetFrames: Int = QuestionAudioLogMelFeature.trainedModelFrameCount) -> QuestionAudioLogMelFeature? {
        let source = normalizedSource(segment.audioSource)
        let fallbackSources = fallbackOrder(for: source)
        lock.lock()
        let candidateChunks = fallbackSources.compactMap { chunksBySource[$0] }.first { !$0.isEmpty } ?? []
        lock.unlock()
        let samples = samples(for: segment, in: candidateChunks)
        guard let samples, !samples.isEmpty else { return nil }
        return QuestionAudioLogMelExtractor.feature(
            from: samples,
            targetFrames: targetFrames,
            source: "captured_logmel"
        )
    }

    private func samples(for segment: TranscriptSegment, in chunks: [Chunk]) -> [Float]? {
        guard !chunks.isEmpty else { return nil }
        if let range = segment.sourceFrameRange {
            let preRollFrames = Int64(sampleRate * 0.18)
            let postRollFrames = Int64(sampleRate * 0.10)
            let samples = samplesByFrameRange(
                chunks: chunks,
                start: max(0, range.start - preRollFrames),
                end: max(range.start + 1, range.end + postRollFrames)
            )
            if samples.count >= Int(sampleRate * 0.12) {
                return samples
            }
        }

        let duration = max(segment.endTime - segment.startTime, 0)
        guard segment.startTime.isFinite, segment.endTime.isFinite, duration > 0 else {
            return nil
        }
        let samples = samplesByTimeRange(
            chunks: chunks,
            start: max(0, segment.startTime - 0.18),
            end: max(segment.startTime + 0.12, segment.endTime + 0.10)
        )
        return samples.count >= Int(sampleRate * 0.12) ? samples : nil
    }

    private func samplesByFrameRange(chunks: [Chunk], start: Int64, end: Int64) -> [Float] {
        var output: [Float] = []
        for chunk in chunks where chunk.endFrame > start && chunk.startFrame < end {
            let localStart = Int(max(0, start - chunk.startFrame))
            let localEnd = Int(min(Int64(chunk.samples.count), end - chunk.startFrame))
            guard localEnd > localStart else { continue }
            output.append(contentsOf: chunk.samples[localStart..<localEnd])
        }
        return output
    }

    private func samplesByTimeRange(chunks: [Chunk], start: TimeInterval, end: TimeInterval) -> [Float] {
        var output: [Float] = []
        for chunk in chunks where chunk.endTime > start && chunk.startTime < end {
            let localStart = Int(max(0, ((start - chunk.startTime) * sampleRate).rounded(.down)))
            let localEnd = Int(min(Double(chunk.samples.count), ((end - chunk.startTime) * sampleRate).rounded(.up)))
            guard localEnd > localStart else { continue }
            output.append(contentsOf: chunk.samples[localStart..<localEnd])
        }
        return output
    }

    private func trim(_ chunks: inout [Chunk], latestEndTime: TimeInterval) {
        let cutoff = max(0, latestEndTime - retentionSeconds)
        chunks.removeAll { $0.endTime < cutoff }
    }

    private func normalizedSource(_ source: TranscriptAudioSource) -> TranscriptAudioSource {
        source == .unknown ? .mixed : source
    }

    private func fallbackOrder(for source: TranscriptAudioSource) -> [TranscriptAudioSource] {
        switch source {
        case .mixed:
            [.mixed, .microphone, .system, .cloud, .unknown]
        case .microphone:
            [.microphone, .mixed, .unknown]
        case .system:
            [.system, .mixed, .unknown]
        case .cloud:
            [.cloud, .mixed, .microphone, .system, .unknown]
        case .unknown:
            [.mixed, .microphone, .system, .cloud, .unknown]
        }
    }
}

private enum QuestionAudioLogMelExtractor {
    static let sampleRate: TimeInterval = 16_000
    private static let bandCount = QuestionAudioLogMelFeature.expectedBandCount
    private static let windowLength = 320
    private static let hopLength = 160
    private static let fftSize = 512
    private static let binCount = (fftSize / 2) + 1
    private static let minimumUsableSamples = 640

    static func monoSamples16k(from buffer: AVAudioPCMBuffer) -> [Float]? {
        let frameCount = Int(buffer.frameLength)
        let channelCount = max(1, Int(buffer.format.channelCount))
        guard frameCount > 0 else { return nil }

        var mono = [Float](repeating: 0, count: frameCount)
        if let channelData = buffer.floatChannelData {
            for frame in 0..<frameCount {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += channelData[channel][frame]
                }
                mono[frame] = sum / Float(channelCount)
            }
        } else if let channelData = buffer.int16ChannelData {
            for frame in 0..<frameCount {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += Float(channelData[channel][frame]) / Float(Int16.max)
                }
                mono[frame] = sum / Float(channelCount)
            }
        } else {
            return nil
        }

        return resampleLinear(mono, sourceRate: buffer.format.sampleRate, targetRate: sampleRate)
    }

    static func feature(
        from samples: [Float],
        targetFrames: Int,
        source: String
    ) -> QuestionAudioLogMelFeature? {
        let safeFrames = min(max(targetFrames, 1), QuestionAudioLogMelFeature.maximumFrameCount)
        guard samples.count >= minimumUsableSamples else { return nil }
        guard let fft = vDSP.FFT(
            log2n: vDSP_Length(log2(Double(fftSize))),
            radix: .radix2,
            ofType: DSPSplitComplex.self
        ) else {
            return nil
        }

        var raw = [Double](repeating: 0, count: bandCount * safeFrames)
        let frameCount = min(safeFrames, max(1, Int(ceil(Double(max(samples.count - windowLength, 0)) / Double(hopLength))) + 1))
        for frame in 0..<frameCount {
            let start = frame * hopLength
            let power = spectrumPower(samples: samples, start: start, fft: fft)
            for band in 0..<bandCount {
                let energy = melWeights[band].reduce(Double(0)) { partial, item in
                    partial + Double(power[item.bin]) * item.weight
                }
                raw[(band * safeFrames) + frame] = log1p(max(0, energy))
            }
        }

        let activeEnergy = raw.reduce(0) { $0 + abs($1) }
        guard activeEnergy > 0.00001 else { return nil }

        let mean = raw.reduce(0, +) / Double(raw.count)
        let variance = raw.reduce(0) { $0 + pow($1 - mean, 2) } / Double(raw.count)
        let std = max(sqrt(variance), 0.0001)
        let normalized = raw.map { ($0 - mean) / std }
        return QuestionAudioLogMelFeature(frames: safeFrames, values: normalized, source: source)
    }

    private static func resampleLinear(_ samples: [Float], sourceRate: Double, targetRate: Double) -> [Float] {
        guard sourceRate.isFinite, sourceRate > 0, targetRate.isFinite, targetRate > 0, !samples.isEmpty else {
            return samples
        }
        guard abs(sourceRate - targetRate) > 0.5 else { return samples }
        let outputCount = max(1, Int((Double(samples.count) * targetRate / sourceRate).rounded()))
        guard outputCount > 1, samples.count > 1 else { return samples }
        let scale = sourceRate / targetRate
        return (0..<outputCount).map { index in
            let sourcePosition = Double(index) * scale
            let lower = min(Int(sourcePosition.rounded(.down)), samples.count - 1)
            let upper = min(lower + 1, samples.count - 1)
            let fraction = Float(sourcePosition - Double(lower))
            return samples[lower] + (samples[upper] - samples[lower]) * fraction
        }
    }

    private static func spectrumPower(samples: [Float], start: Int, fft: vDSP.FFT<DSPSplitComplex>) -> [Float] {
        var frame = [Float](repeating: 0, count: fftSize)
        for sampleIndex in 0..<windowLength {
            let sourceIndex = start + sampleIndex
            frame[sampleIndex] = (sourceIndex < samples.count ? samples[sourceIndex] : 0) * hannWindow[sampleIndex]
        }

        var real = [Float](repeating: 0, count: fftSize / 2)
        var imaginary = [Float](repeating: 0, count: fftSize / 2)
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(
                    realp: realPointer.baseAddress!,
                    imagp: imaginaryPointer.baseAddress!
                )
                frame.withUnsafeBufferPointer { framePointer in
                    framePointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPointer in
                        vDSP_ctoz(complexPointer, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                fft.forward(input: split, output: &split)
            }
        }

        var power = [Float](repeating: 0, count: binCount)
        power[0] = real[0] * real[0]
        for bin in 1..<(fftSize / 2) {
            power[bin] = real[bin] * real[bin] + imaginary[bin] * imaginary[bin]
        }
        power[fftSize / 2] = imaginary[0] * imaginary[0]
        return power
    }

    private static let hannWindow: [Float] = {
        (0..<windowLength).map { index in
            0.5 - 0.5 * cos((2 * .pi * Float(index)) / Float(max(windowLength - 1, 1)))
        }
    }()

    private static let melWeights: [[(bin: Int, weight: Double)]] = {
        let minMel = melFrequency(0)
        let maxMel = melFrequency(sampleRate / 2)
        let melPoints = (0..<(bandCount + 2)).map { index in
            minMel + (maxMel - minMel) * Double(index) / Double(bandCount + 1)
        }
        let hzPoints = melPoints.map(inverseMelFrequency)
        let binFrequencies = (0..<binCount).map { Double($0) * sampleRate / Double(fftSize) }
        return (0..<bandCount).map { band in
            let lower = hzPoints[band]
            let center = hzPoints[band + 1]
            let upper = hzPoints[band + 2]
            var weights: [(bin: Int, weight: Double)] = []
            for (bin, frequency) in binFrequencies.enumerated() {
                let weight: Double
                if frequency < lower || frequency > upper {
                    weight = 0
                } else if frequency <= center {
                    weight = (frequency - lower) / max(center - lower, 0.0001)
                } else {
                    weight = (upper - frequency) / max(upper - center, 0.0001)
                }
                if weight > 0 {
                    weights.append((bin, weight))
                }
            }
            return weights
        }
    }()

    private static func melFrequency(_ frequency: Double) -> Double {
        2595 * log10(1 + frequency / 700)
    }

    private static func inverseMelFrequency(_ mel: Double) -> Double {
        700 * (pow(10, mel / 2595) - 1)
    }
}

protocol QuestionTrainedMultimodalModelRunning: Sendable {
    func prediction(
        for candidate: QuestionCandidate,
        signal: QuestionMultimodalSignal?
    ) async -> QuestionTrainedMultimodalPrediction?
}

struct QuestionTrainedMultimodalPrediction: Codable, Hashable, Sendable {
    var responseScore: Double
    var label: String?
    var completeScore: Double?
    var rhetoricalScore: Double?
    var threshold: Double
    var decisionLatencyMs: Double?
    var decisionSignals: [String]
    var suppressionSignals: [String]

    var shouldAllow: Bool {
        responseScore >= threshold
            && (completeScore ?? 1) >= 0.5
            && (rhetoricalScore ?? 0) < 0.5
            && suppressionSignals.isEmpty
    }
}

struct QuestionMultiQTModelMetadata: Codable, Hashable, Sendable {
    struct Config: Codable, Hashable, Sendable {
        var maxTokens: Int
        var maxFrames: Int
        var scalarCount: Int

        enum CodingKeys: String, CodingKey {
            case maxTokens = "max_tokens"
            case maxFrames = "max_frames"
            case scalarCount = "scalar_count"
        }
    }

    struct LabelPolicy: Codable, Hashable, Sendable {
        var positiveLabels: [String]?
        var criticalNegativeLabels: [String]?
        var noncriticalNegativeLabels: [String]?
        var languages: [String]?

        enum CodingKeys: String, CodingKey {
            case positiveLabels = "positive_labels"
            case criticalNegativeLabels = "critical_negative_labels"
            case noncriticalNegativeLabels = "noncritical_negative_labels"
            case languages
        }
    }

    struct AudioFeatureContract: Codable, Hashable, Sendable {
        var preferredRuntimeFeature: String?

        enum CodingKeys: String, CodingKey {
            case preferredRuntimeFeature = "preferred_runtime_feature"
        }
    }

    var modelResourceName: String?
    var labels: [String]
    var labelPolicy: LabelPolicy?
    var vocab: [String: Int]
    var threshold: Double
    var languageThresholds: [String: Double]?
    var config: Config
    var audioFeatureContract: AudioFeatureContract?

    enum CodingKeys: String, CodingKey {
        case modelResourceName = "model_resource_name"
        case labels
        case labelPolicy = "label_policy"
        case vocab
        case threshold
        case languageThresholds = "language_thresholds"
        case config
        case audioFeatureContract = "audio_feature_contract"
    }
}

final class CoreMLQuestionMultiQTModelRunner: QuestionTrainedMultimodalModelRunning, @unchecked Sendable {
    private let modelResourceName: String
    private var cachedModel: MLModel?
    private var cachedMetadata: QuestionMultiQTModelMetadata?

    init(modelResourceName: String = "notchly-multiqt-v1") {
        self.modelResourceName = modelResourceName
    }

    func prediction(
        for candidate: QuestionCandidate,
        signal: QuestionMultimodalSignal?
    ) async -> QuestionTrainedMultimodalPrediction? {
        do {
            guard let model = try loadModel(),
                  let metadata = try loadMetadata() else {
                return nil
            }
            let encoder = QuestionMultiQTFeatureEncoder(metadata: metadata)
            let input = try encoder.featureProvider(for: candidate, signal: signal)
            let started = Date()
            let options = MLPredictionOptions()
            let output = try await model.prediction(from: input, options: options)
            let elapsedMs = Date().timeIntervalSince(started) * 1000
            guard let responseLogit = scalarOutput(named: "response_logit", from: output) else {
                return nil
            }
            let label = labelOutput(named: "label_logits", from: output, labels: metadata.labels)
            let complete = scalarOutput(named: "complete_logit", from: output).map(sigmoid)
            let rhetorical = scalarOutput(named: "rhetorical_logit", from: output).map(sigmoid)
            let score = sigmoid(responseLogit)
            let resolvedThreshold = threshold(for: candidate, signal: signal, metadata: metadata)
            var suppression: [String] = []
            if let complete, complete < 0.5 {
                suppression.append("trained_incomplete")
            }
            if let rhetorical, rhetorical >= 0.5 {
                suppression.append("trained_rhetorical")
            }
            if let label, criticalNegativeLabels(metadata: metadata).contains(label) {
                suppression.append("trained_critical_negative_label:\(label)")
            }
            if score < resolvedThreshold {
                suppression.append("trained_below_threshold")
            }
            return QuestionTrainedMultimodalPrediction(
                responseScore: min(max(score, 0), 1),
                label: label,
                completeScore: complete,
                rhetoricalScore: rhetorical,
                threshold: resolvedThreshold,
                decisionLatencyMs: elapsedMs,
                decisionSignals: ["trained_multiqt_coreml"]
                    + (label.map { ["trained_label:\($0)"] } ?? [])
                    + thresholdSignals(global: metadata.threshold, resolved: resolvedThreshold, candidate: candidate, signal: signal),
                suppressionSignals: suppression
            )
        } catch {
            return nil
        }
    }

    private func loadModel() throws -> MLModel? {
        if let cachedModel {
            return cachedModel
        }
        guard let url = resourceURL(name: modelResourceName, extension: "mlmodelc") else {
            return nil
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let model = try MLModel(contentsOf: url, configuration: configuration)
        cachedModel = model
        return model
    }

    private func loadMetadata() throws -> QuestionMultiQTModelMetadata? {
        if let cachedMetadata {
            return cachedMetadata
        }
        guard let url = resourceURL(name: "\(modelResourceName).metadata", extension: "json") else {
            return nil
        }
        let data = try Data(contentsOf: url)
        let metadata = try JSONDecoder().decode(QuestionMultiQTModelMetadata.self, from: data)
        cachedMetadata = metadata
        return metadata
    }

    private func resourceURL(name: String, extension fileExtension: String) -> URL? {
        for bundle in [Bundle.main, Bundle(for: QuestionMultiQTBundleMarker.self)] {
            if let url = bundle.url(forResource: name, withExtension: fileExtension) {
                return url
            }
            if let url = bundle.url(forResource: name, withExtension: fileExtension, subdirectory: "Models") {
                return url
            }
        }
        return nil
    }

    private func scalarOutput(named name: String, from output: MLFeatureProvider) -> Double? {
        guard let value = output.featureValue(for: name) else { return nil }
        if value.type == .double {
            return value.doubleValue
        }
        if value.type == .int64 {
            return Double(value.int64Value)
        }
        if let array = value.multiArrayValue, array.count > 0 {
            return array[0].doubleValue
        }
        return nil
    }

    private func labelOutput(named name: String, from output: MLFeatureProvider, labels: [String]) -> String? {
        guard let array = output.featureValue(for: name)?.multiArrayValue,
              array.count > 0 else {
            return nil
        }
        var bestIndex = 0
        var bestValue = array[0].doubleValue
        for index in 1..<array.count {
            let value = array[index].doubleValue
            if value > bestValue {
                bestValue = value
                bestIndex = index
            }
        }
        guard labels.indices.contains(bestIndex) else { return nil }
        return labels[bestIndex]
    }

    private func threshold(
        for candidate: QuestionCandidate,
        signal: QuestionMultimodalSignal?,
        metadata: QuestionMultiQTModelMetadata
    ) -> Double {
        let language = signal?.language ?? candidate.language
        guard let language,
              let languageThreshold = metadata.languageThresholds?[language],
              languageThreshold.isFinite else {
            return metadata.threshold
        }
        return min(max(max(metadata.threshold, languageThreshold), 0), 1)
    }

    private func thresholdSignals(
        global: Double,
        resolved: Double,
        candidate: QuestionCandidate,
        signal: QuestionMultimodalSignal?
    ) -> [String] {
        guard abs(global - resolved) > 0.0001 else { return [] }
        let language = signal?.language ?? candidate.language ?? "unknown"
        return ["trained_language_threshold:\(language):\(String(format: "%.3f", resolved))"]
    }

    private func criticalNegativeLabels(metadata: QuestionMultiQTModelMetadata) -> Set<String> {
        let fallback = [
            "small_talk",
            "operational_check",
            "rhetorical",
            "reported_question",
            "self_answered",
            "fragment",
            "title_noise"
        ]
        return Set(metadata.labelPolicy?.criticalNegativeLabels ?? fallback)
    }

    private func sigmoid(_ value: Double) -> Double {
        1 / (1 + exp(-value))
    }
}

private final class QuestionMultiQTBundleMarker {}

private struct QuestionMultiQTFeatureEncoder {
    var metadata: QuestionMultiQTModelMetadata

    func featureProvider(
        for candidate: QuestionCandidate,
        signal: QuestionMultimodalSignal?
    ) throws -> MLFeatureProvider {
        let text = try textTokens(for: candidate.rawText)
        let audio = try audioLogMelTensor(for: signal)
        let scalars = try scalarTensor(for: signal, language: candidate.language)
        return try MLDictionaryFeatureProvider(dictionary: [
            "text_tokens": text,
            "audio_logmel": audio,
            "scalars": scalars
        ])
    }

    private func textTokens(for text: String) throws -> MLMultiArray {
        let maxTokens = max(1, metadata.config.maxTokens)
        let output = try MLMultiArray(
            shape: [NSNumber(value: 1), NSNumber(value: maxTokens)],
            dataType: .int32
        )
        let tokens = tokenize(text)
        for index in 0..<maxTokens {
            let tokenId: Int
            if index < tokens.count {
                tokenId = metadata.vocab[tokens[index]] ?? metadata.vocab["<unk>"] ?? 1
            } else {
                tokenId = metadata.vocab["<pad>"] ?? 0
            }
            output[[NSNumber(value: 0), NSNumber(value: index)]] = NSNumber(value: tokenId)
        }
        return output
    }

    private func audioLogMelTensor(for signal: QuestionMultimodalSignal?) throws -> MLMultiArray {
        let maxFrames = max(1, metadata.config.maxFrames)
        let output = try MLMultiArray(
            shape: [NSNumber(value: 1), NSNumber(value: 40), NSNumber(value: maxFrames)],
            dataType: .float32
        )
        let prefersSignalProxy = metadata.audioFeatureContract?.preferredRuntimeFeature == "signal_proxy"
        let feature = prefersSignalProxy
            ? signal.map { QuestionAudioLogMelFeature.proxy(from: $0, targetFrames: maxFrames) }
            : signal?.audioLogMel ?? signal.map {
                QuestionAudioLogMelFeature.proxy(from: $0, targetFrames: maxFrames)
            }
        guard let feature else {
            for index in 0..<output.count {
                output[index] = 0
            }
            return output
        }
        for band in 0..<QuestionAudioLogMelFeature.expectedBandCount {
            for frame in 0..<maxFrames {
                let sourceFrame = min(frame, max(feature.frames - 1, 0))
                output[[NSNumber(value: 0), NSNumber(value: band), NSNumber(value: frame)]] = NSNumber(
                    value: feature.value(band: min(band, feature.bands - 1), frame: sourceFrame)
                )
            }
        }
        return output
    }

    private func scalarTensor(for signal: QuestionMultimodalSignal?, language: String?) throws -> MLMultiArray {
        let scalarCount = max(1, metadata.config.scalarCount)
        let output = try MLMultiArray(
            shape: [NSNumber(value: 1), NSNumber(value: scalarCount)],
            dataType: .float32
        )
        let resolvedLanguage = signal?.language ?? language
        let duration = min(max((signal?.duration ?? 0) / 20, 0), 1)
        let values = [
            signal?.asrConfidence ?? 1,
            signal?.isPartial == true ? 1 : 0,
            duration,
            resolvedLanguage == "pt-BR" ? 1 : 0,
            resolvedLanguage == "en-US" ? 1 : 0,
            resolvedLanguage == "es-ES" ? 1 : 0,
            resolvedLanguage == "ja-JP" ? 1 : 0
        ]
        for index in 0..<scalarCount {
            output[[NSNumber(value: 0), NSNumber(value: index)]] = NSNumber(value: index < values.count ? values[index] : 0)
        }
        return output
    }

    private func tokenize(_ text: String) -> [String] {
        let lowercased = text.lowercased()
        let parts = lowercased
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        if !parts.isEmpty {
            return parts
        }
        let compact = lowercased.trimmingCharacters(in: .whitespacesAndNewlines)
        return compact.isEmpty ? [] : [compact]
    }
}

enum QuestionStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case candidate
    case confirmed
    case ignored
    case merged
    case answered
    case dismissed
    case expired

    var id: String { rawValue }
}

struct QuestionClassification: Codable, Hashable, Sendable {
    let isQuestion: Bool
    let rhetorical: Bool
    let complete: Bool
    let actionable: Bool
    let responseNeeded: Bool
    let userAttentionNeeded: Bool
    let directedToUser: Bool
    let directedToGroup: Bool
    let questionType: QuestionType
    let priority: QuestionPriority
    let confidence: Double
    let reason: String
    let extractedQuestion: String
    let expectedAnswerStyle: AnswerStyle
    var textualConfidence: Double? = nil
    var multimodalConfidence: Double? = nil
    var decisionScore: Double? = nil
    var decisionSignals: [String]? = nil
    var suppressionSignals: [String]? = nil
}

enum LocalQuestionIntent: String, Codable, CaseIterable, Identifiable, Sendable {
    case answerableQuestion = "answerable_question"
    case actionRequest = "action_request"
    case statement
    case smallTalk = "small_talk"
    case operationalCheck = "operational_check"
    case reportedQuestion = "reported_question"
    case rhetorical
    case fragment
    case ambiguous

    var id: String { rawValue }

    var isQuestionLike: Bool {
        switch self {
        case .answerableQuestion, .actionRequest:
            true
        case .statement, .smallTalk, .operationalCheck, .reportedQuestion, .rhetorical, .fragment, .ambiguous:
            false
        }
    }
}

enum QuestionUnderstandingSignal: String, Codable, CaseIterable, Identifiable, Sendable {
    case terminalQuestionMark = "terminal_question_mark"
    case interrogativeStarter = "interrogative_starter"
    case modalQuestionFrame = "modal_question_frame"
    case indirectQuestionFrame = "indirect_question_frame"
    case actionRequestFrame = "action_request_frame"
    case directedToUser = "directed_to_user"
    case directedToGroup = "directed_to_group"
    case concreteObject = "concrete_object"
    case domainObject = "domain_object"
    case finalUtterance = "final_utterance"
    case contextualCarryover = "contextual_carryover"

    var id: String { rawValue }
}

struct LocalQuestionUnderstanding: Codable, Hashable, Sendable {
    var intent: LocalQuestionIntent
    var confidence: Double
    var strongSignals: Set<QuestionUnderstandingSignal>
    var negativeSignals: [String]
    var reason: String
    var extractedQuestion: String

    var responseNeeded: Bool {
        intent == .answerableQuestion || intent == .actionRequest
    }
}

enum QuestionPriority: String, Codable, CaseIterable, Identifiable, Sendable {
    case low
    case medium
    case high
    case urgent

    var id: String { rawValue }

    var ttl: TimeInterval {
        switch self {
        case .low: 30
        case .medium: 60
        case .high: 120
        case .urgent: 10 * 60
        }
    }
}

enum QuestionType: String, Codable, CaseIterable, Identifiable, Sendable {
    case statusCheck = "status_check"
    case technicalExplanation = "technical_explanation"
    case technicalDecision = "technical_decision"
    case deadlineOrEstimate = "deadline_or_estimate"
    case ownership
    case riskAssessment = "risk_assessment"
    case productScope = "product_scope"
    case businessContext = "business_context"
    case clarification
    case approvalRequest = "approval_request"
    case actionRequest = "action_request"
    case opinionRequest = "opinion_request"
    case followUp = "follow_up"
    case generalQuestion = "general_question"
    case unknown

    var id: String { rawValue }
}

enum AnswerStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case concise
    case technical
    case diplomatic
    case executive
    case cautious
    case askForClarification = "ask_for_clarification"

    var id: String { rawValue }
}

struct SuggestedAnswer: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let questionId: UUID
    let answerText: String
    let shortAnswer: String
    let confidence: Double
    let riskLevel: AnswerRiskLevel
    let usedSources: [AnswerSource]
    let assumptions: [String]
    let caveats: [String]
    let generatedAt: Date
    let latencyMs: Int
    var expandedAnswer: String?
    var suggestedTone: AnswerStyle
    var shouldAskClarification: Bool
    var clarifyingQuestion: String?
    var language: String?
    var provider: EngineName?
    var usedCloud: Bool
    var usedRAG: Bool
    var answerFormat: CopilotAnswerFormat?
    var richAnswer: RichAnswerPayload?

    init(
        id: UUID = UUID(),
        questionId: UUID,
        answerText: String,
        shortAnswer: String,
        confidence: Double,
        riskLevel: AnswerRiskLevel,
        usedSources: [AnswerSource],
        assumptions: [String],
        caveats: [String],
        generatedAt: Date = Date(),
        latencyMs: Int,
        expandedAnswer: String? = nil,
        suggestedTone: AnswerStyle = .concise,
        shouldAskClarification: Bool = false,
        clarifyingQuestion: String? = nil,
        language: String? = nil,
        provider: EngineName? = nil,
        usedCloud: Bool = false,
        usedRAG: Bool = false,
        answerFormat: CopilotAnswerFormat? = nil,
        richAnswer: RichAnswerPayload? = nil
    ) {
        self.id = id
        self.questionId = questionId
        self.answerText = answerText
        self.shortAnswer = shortAnswer
        self.confidence = confidence
        self.riskLevel = riskLevel
        self.usedSources = usedSources
        self.assumptions = assumptions
        self.caveats = caveats
        self.generatedAt = generatedAt
        self.latencyMs = latencyMs
        self.expandedAnswer = expandedAnswer
        self.suggestedTone = suggestedTone
        self.shouldAskClarification = shouldAskClarification
        self.clarifyingQuestion = clarifyingQuestion
        self.language = language
        self.provider = provider
        self.usedCloud = usedCloud
        self.usedRAG = usedRAG
        self.answerFormat = answerFormat
        self.richAnswer = richAnswer
    }
}

enum AnswerRiskLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case safe
    case moderate
    case high
    case requiresApproval = "requires_approval"

    var id: String { rawValue }
}

struct AnswerSource: Codable, Hashable, Sendable {
    let type: AnswerSourceType
    let title: String
    let snippet: String?
    let reference: String?
}

enum CopilotRuntimeKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case meeting
    case ambient

    var id: String { rawValue }
}

enum CopilotRuntimeSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case microphone
    case typed
    case shortcut

    var id: String { rawValue }
}

struct CopilotRuntimeContext: Codable, Hashable, Sendable {
    var kind: CopilotRuntimeKind
    var source: CopilotRuntimeSource
    var transcriptContext: TranscriptContext
    var languageCode: String?
    var startedAt: Date
    var confidence: Double?
}

enum CopilotIntentKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case answerableQuestion = "answerable_question"
    case actionRequest = "action_request"
    case webSearch = "web_search"
    case newsSearch = "news_search"
    case calculation
    case conversion
    case reminder
    case memoryLookup = "memory_lookup"
    case statement
    case smallTalk = "small_talk"
    case ambientNoise = "ambient_noise"
    case ambiguous

    var id: String { rawValue }
}

enum CopilotToolKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case answerSynthesis = "answer_synthesis"
    case calculator
    case reminder
    case localMemory = "local_memory"
    case webSearch = "web_search"
    case unavailable

    var id: String { rawValue }
}

enum CopilotRuntimeState: String, Codable, CaseIterable, Identifiable, Sendable {
    case idle
    case listening
    case intentDetected = "intent_detected"
    case classifying
    case routing
    case calculating
    case searching
    case synthesizing
    case ready
    case failedRecoverable = "failed_recoverable"
    case permissionBlocked = "permission_blocked"
    case paused

    var id: String { rawValue }

    var isInProgress: Bool {
        switch self {
        case .intentDetected, .classifying, .routing, .calculating, .searching, .synthesizing:
            true
        case .idle, .listening, .ready, .failedRecoverable, .permissionBlocked, .paused:
            false
        }
    }

    var answerStage: AnswerGenerationStage {
        switch self {
        case .intentDetected, .classifying:
            .classifying
        case .routing, .searching:
            .retrievingContext
        case .calculating, .synthesizing:
            .drafting
        case .ready:
            .ready
        case .failedRecoverable, .permissionBlocked:
            .failed
        case .idle, .listening, .paused:
            .idle
        }
    }

    var displayText: String {
        switch self {
        case .idle: "Notchly ready"
        case .listening: "Listening"
        case .intentDetected: "Understanding"
        case .classifying: "Understanding"
        case .routing: "Routing"
        case .calculating: "Calculating"
        case .searching: "Searching"
        case .synthesizing: "Preparing"
        case .ready: "Ready"
        case .failedRecoverable: "Needs attention"
        case .permissionBlocked: "Permission required"
        case .paused: "Paused"
        }
    }
}

enum CopilotFailureKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case microphonePermissionMissing = "microphone_permission_missing"
    case webProviderUnavailable = "web_provider_unavailable"
    case networkUnavailable = "network_unavailable"
    case notificationPermissionDenied = "notification_permission_denied"
    case modelUnavailable = "model_unavailable"
    case contextInsufficient = "context_insufficient"
    case privacyBlocked = "privacy_blocked"
    case emptyResponse = "empty_response"
    case answerTimedOut = "answer_timed_out"
    case invalidReminder = "invalid_reminder"
    case unknown

    var id: String { rawValue }

    var isRecoverable: Bool {
        switch self {
        case .microphonePermissionMissing, .notificationPermissionDenied, .webProviderUnavailable, .networkUnavailable, .modelUnavailable, .contextInsufficient, .answerTimedOut, .invalidReminder:
            true
        case .privacyBlocked, .emptyResponse, .unknown:
            false
        }
    }

    var userMessage: String {
        switch self {
        case .microphonePermissionMissing:
            return "Permissao de microfone necessaria para manter o Notchly ouvindo."
        case .webProviderUnavailable:
            return "Busca web indisponivel. Conecte OpenAI/Perplexity ou configure Brave Search."
        case .networkUnavailable:
            return "Rede indisponivel para concluir a busca agora."
        case .notificationPermissionDenied:
            return "Permissao de notificacao necessaria para criar este lembrete."
        case .modelUnavailable:
            return "Modelo local ou provedor de resposta indisponivel agora."
        case .contextInsufficient:
            return "Contexto insuficiente para responder com confianca."
        case .privacyBlocked:
            return "Resposta bloqueada por privacidade."
        case .emptyResponse:
            return "A resposta veio vazia. Tente reformular o pedido."
        case .answerTimedOut:
            return "Nao consegui concluir a resposta a tempo. Tente novamente em instantes."
        case .invalidReminder:
            return "Nao consegui identificar data e horario do lembrete."
        case .unknown:
            return "Nao consegui concluir esta acao agora."
        }
    }
}

struct CopilotFailure: Error, Codable, Hashable, Sendable {
    var kind: CopilotFailureKind
    var detail: String?

    init(_ kind: CopilotFailureKind, detail: String? = nil) {
        self.kind = kind
        self.detail = detail
    }

    var userMessage: String {
        detail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? detail! : kind.userMessage
    }
}

enum CopilotAnswerFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case plainShort = "plain_short"
    case paragraph
    case steps
    case bullets
    case calculation
    case newsWithSources = "news_with_sources"
    case reminderConfirmation = "reminder_confirmation"
    case memoryResults = "memory_results"
    case code
    case errorState = "error_state"

    var id: String { rawValue }

    var allowsCodeBlocks: Bool {
        self == .code
    }

    var prefersCompactLayout: Bool {
        switch self {
        case .plainShort, .calculation, .reminderConfirmation, .errorState:
            true
        case .paragraph, .steps, .bullets, .newsWithSources, .memoryResults, .code:
            false
        }
    }
}

struct CopilotAnswerPresentation: Codable, Hashable, Sendable {
    var text: String
    var shortText: String
    var format: CopilotAnswerFormat
    var caveats: [String]
    var sources: [AnswerSource]
    var richAnswer: RichAnswerPayload?
}

enum CopilotQualityStage: String, Codable, CaseIterable, Identifiable, Sendable {
    case intent
    case routing
    case tool
    case render
    case total

    var id: String { rawValue }
}

struct CopilotQualityEvent: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var stage: CopilotQualityStage
    var accepted: Bool
    var tool: CopilotToolKind?
    var intent: CopilotIntentKind?
    var runtimeState: CopilotRuntimeState
    var languageCode: String?
    var source: CopilotRuntimeSource
    var latencyMs: Double
    var reason: String
    var failureKind: CopilotFailureKind?
    var createdAt = Date()
}

struct CopilotQualitySnapshot: Codable, Hashable, Sendable {
    var acceptedCount: Int = 0
    var ignoredCount: Int = 0
    var failureCount: Int = 0
    var latestReason: String?
    var latestFailureKind: CopilotFailureKind?
    var p50LatencyMs: Double = 0
    var p95LatencyMs: Double = 0
    var p99LatencyMs: Double = 0
    var lastEvents: [CopilotQualityEvent] = []

    static let empty = CopilotQualitySnapshot()
}

enum CopilotHealthState: String, Codable, CaseIterable, Identifiable, Sendable {
    case ready
    case micPermissionBlocked = "mic_permission_blocked"
    case micNoAudio = "mic_no_audio"
    case asrStarting = "asr_starting"
    case asrNoSegments = "asr_no_segments"
    case asrUnstable = "asr_unstable"
    case llmProviderMissing = "llm_provider_missing"
    case llmProviderInvalid = "llm_provider_invalid"
    case llmDecisionTimeout = "llm_decision_timeout"
    case meetingModePaused = "meeting_mode_paused"

    var id: String { rawValue }

    var isReady: Bool {
        self == .ready
    }

    var showsMicroState: Bool {
        self != .ready && self != .meetingModePaused
    }

    var displayText: String {
        switch self {
        case .ready:
            return "Ready"
        case .micPermissionBlocked:
            return "Microphone blocked"
        case .micNoAudio:
            return "No mic audio"
        case .asrStarting:
            return "Starting speech"
        case .asrNoSegments:
            return "Listening without transcript"
        case .asrUnstable:
            return "Reconnecting speech"
        case .llmProviderMissing:
            return "AI provider required"
        case .llmProviderInvalid:
            return "AI provider invalid"
        case .llmDecisionTimeout:
            return "AI decision timeout"
        case .meetingModePaused:
            return "Paused during meeting"
        }
    }

    var tooltip: String {
        switch self {
        case .ready:
            return "Notchly is ready."
        case .micPermissionBlocked:
            return "Allow microphone access to enable always-on Notchly."
        case .micNoAudio:
            return "Microphone is active, but no speech-level audio has been received yet."
        case .asrStarting:
            return "Starting speech recognition."
        case .asrNoSegments:
            return "Audio is arriving, but speech recognition has not emitted text yet."
        case .asrUnstable:
            return "Speech recognition is being restarted."
        case .llmProviderMissing:
            return "Connect a cloud AI provider to enable Notchly activation."
        case .llmProviderInvalid:
            return "The configured AI provider did not pass the Notchly readiness check."
        case .llmDecisionTimeout:
            return "The AI provider did not decide in time."
        case .meetingModePaused:
            return "Ambient Notchly is paused while a meeting is active."
        }
    }

    var systemImageName: String {
        switch self {
        case .ready:
            return "sparkles"
        case .micPermissionBlocked:
            return "mic.slash"
        case .micNoAudio:
            return "mic"
        case .asrStarting, .asrNoSegments, .asrUnstable:
            return "waveform"
        case .llmProviderMissing, .llmProviderInvalid:
            return "exclamationmark.triangle"
        case .llmDecisionTimeout:
            return "timer"
        case .meetingModePaused:
            return "pause.fill"
        }
    }

    var usesSpinner: Bool {
        switch self {
        case .asrStarting, .asrUnstable, .llmDecisionTimeout:
            return true
        case .ready, .micPermissionBlocked, .micNoAudio, .asrNoSegments, .llmProviderMissing, .llmProviderInvalid, .meetingModePaused:
            return false
        }
    }
}

struct CopilotHealthSnapshot: Codable, Hashable, Sendable {
    var state: CopilotHealthState = .ready
    var lastAudioAt: Date?
    var lastPartialAt: Date?
    var lastFinalSegmentAt: Date?
    var lastASRError: String?
    var activeASRBackend: String = "Apple Speech"
    var updatedAt: Date = Date()

    static let empty = CopilotHealthSnapshot()
}

struct CopilotActivationTrace: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var createdAt = Date()
    var source: CopilotRuntimeSource
    var audioReceived: Bool
    var partialReceived: Bool
    var finalReceived: Bool
    var candidateCount: Int
    var selectedCandidatePreview: String?
    var selectedCandidateHash: String?
    var decisionShouldRespond: Bool?
    var confidence: Double?
    var ignoredReason: String?
    var failureKind: CopilotFailureKind?
    var healthState: CopilotHealthState
    var latencyMs: Double

    static func sanitizedPreview(_ text: String, privacyGuard: PrivacyGuard = PrivacyGuard()) -> String? {
        let redacted = privacyGuard.redact(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !redacted.isEmpty else { return nil }
        if redacted.count <= 96 { return redacted }
        return String(redacted.prefix(96)) + "..."
    }

    static func stableHash(for text: String) -> String? {
        let normalized = QuestionDetectionService.normalize(text)
        guard !normalized.isEmpty else { return nil }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in normalized.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

@MainActor
final class CopilotActivationTraceStore {
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let rootURL = (try? FileStorageService.applicationSupportDirectory())
                ?? FileManager.default.temporaryDirectory.appendingPathComponent(FileStorageService.applicationSupportDirectoryName, isDirectory: true)
            self.fileURL = rootURL
                .appendingPathComponent("copilot_activation_traces.jsonl", isDirectory: false)
        }
    }

    func append(_ trace: CopilotActivationTrace) {
        do {
            let directoryURL = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(trace)
            var line = Data()
            line.append(data)
            line.append(0x0A)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try handle.close()
            } else {
                try line.write(to: fileURL, options: [.atomic])
            }
        } catch {
            AppLog.ai.debug("Could not persist Notchly activation trace: \(error.localizedDescription, privacy: .public)")
        }
    }
}

enum TranscriptionFailoverAction: Equatable, Sendable {
    case none
    case restartASR(reason: String, allowHybridRecognition: Bool)
}

struct TranscriptionFailoverCoordinator: Sendable {
    private(set) var snapshot = CopilotHealthSnapshot.empty
    private var startedAt = Date.distantPast
    private var lastRestartAt = Date.distantPast
    private var lastAudioPublishAt = Date.distantPast
    private var restartCount = 0
    private let speechAudioThreshold: Float = 0.006
    private let noSegmentAfterAudioTimeout: TimeInterval = 4
    private let noFinalAfterAudioTimeout: TimeInterval = 10
    private let restartCooldown: TimeInterval = 8

    mutating func markPipelineStarted(backend: String, now: Date = Date()) -> CopilotHealthSnapshot {
        startedAt = now
        snapshot = CopilotHealthSnapshot(
            state: .asrStarting,
            lastAudioAt: nil,
            lastPartialAt: nil,
            lastFinalSegmentAt: nil,
            lastASRError: nil,
            activeASRBackend: backend,
            updatedAt: now
        )
        return snapshot
    }

    mutating func markStopped(state: CopilotHealthState, backend: String? = nil, now: Date = Date()) -> CopilotHealthSnapshot {
        snapshot.state = state
        if let backend {
            snapshot.activeASRBackend = backend
        }
        snapshot.updatedAt = now
        return snapshot
    }

    mutating func markAudio(_ buffer: AudioBuffer, now: Date = Date()) -> CopilotHealthSnapshot? {
        guard buffer.rms > speechAudioThreshold else { return nil }
        snapshot.lastAudioAt = now
        let previousState = snapshot.state
        if snapshot.state == .micNoAudio || snapshot.state == .asrStarting {
            snapshot.state = .ready
        }
        snapshot.updatedAt = now
        guard previousState != snapshot.state || now.timeIntervalSince(lastAudioPublishAt) >= 1.2 else {
            return nil
        }
        lastAudioPublishAt = now
        return snapshot
    }

    mutating func markSegment(_ segment: TranscriptSegment, now: Date = Date()) -> CopilotHealthSnapshot {
        if segment.isFinal {
            snapshot.lastFinalSegmentAt = now
        } else {
            snapshot.lastPartialAt = now
        }
        snapshot.state = .ready
        snapshot.updatedAt = now
        return snapshot
    }

    mutating func markError(_ error: Error, now: Date = Date()) -> CopilotHealthSnapshot {
        snapshot.lastASRError = error.localizedDescription
        snapshot.state = .asrUnstable
        snapshot.updatedAt = now
        return snapshot
    }

    mutating func poll(now: Date = Date()) -> (CopilotHealthSnapshot, TranscriptionFailoverAction) {
        if snapshot.lastAudioAt == nil, now.timeIntervalSince(startedAt) > noSegmentAfterAudioTimeout {
            snapshot.state = .micNoAudio
            snapshot.updatedAt = now
            return (snapshot, .none)
        }

        guard let lastAudioAt = snapshot.lastAudioAt else {
            return (snapshot, .none)
        }

        let hasAnySegment = snapshot.lastPartialAt != nil || snapshot.lastFinalSegmentAt != nil
        if !hasAnySegment, now.timeIntervalSince(lastAudioAt) >= noSegmentAfterAudioTimeout {
            snapshot.state = .asrNoSegments
            snapshot.updatedAt = now
            return (snapshot, restartAction(now: now, reason: "audio_without_transcript"))
        }

        let lastFinalOrStart = snapshot.lastFinalSegmentAt ?? startedAt
        if now.timeIntervalSince(lastAudioAt) <= noFinalAfterAudioTimeout,
           snapshot.lastPartialAt != nil,
           snapshot.lastFinalSegmentAt == nil {
            snapshot.state = .ready
            snapshot.updatedAt = now
            return (snapshot, .none)
        }

        if now.timeIntervalSince(lastFinalOrStart) >= noFinalAfterAudioTimeout,
           now.timeIntervalSince(lastAudioAt) < 1.5 {
            snapshot.state = .asrUnstable
            snapshot.updatedAt = now
            return (snapshot, restartAction(now: now, reason: "audio_without_final_segment"))
        }

        snapshot.state = .ready
        snapshot.updatedAt = now
        return (snapshot, .none)
    }

    private mutating func restartAction(now: Date, reason: String) -> TranscriptionFailoverAction {
        guard now.timeIntervalSince(lastRestartAt) >= restartCooldown else {
            return .none
        }
        lastRestartAt = now
        restartCount += 1
        return .restartASR(reason: reason, allowHybridRecognition: restartCount >= 2)
    }
}

@MainActor
final class CopilotQualityTelemetry {
    private var events: [CopilotQualityEvent] = []
    private let limit: Int

    init(limit: Int = 240) {
        self.limit = max(20, limit)
    }

    func record(_ event: CopilotQualityEvent) -> CopilotQualitySnapshot {
        events.append(event)
        if events.count > limit {
            events.removeFirst(events.count - limit)
        }
        return snapshot()
    }

    func snapshot() -> CopilotQualitySnapshot {
        let accepted = events.filter(\.accepted).count
        let ignored = events.filter { !$0.accepted && $0.failureKind == nil }.count
        let failures = events.filter { $0.failureKind != nil }.count
        let latencies = events.map(\.latencyMs).sorted()
        return CopilotQualitySnapshot(
            acceptedCount: accepted,
            ignoredCount: ignored,
            failureCount: failures,
            latestReason: events.last?.reason,
            latestFailureKind: events.last?.failureKind,
            p50LatencyMs: Self.percentile(latencies, 0.50),
            p95LatencyMs: Self.percentile(latencies, 0.95),
            p99LatencyMs: Self.percentile(latencies, 0.99),
            lastEvents: Array(events.suffix(12).reversed())
        )
    }

    private static func percentile(_ values: [Double], _ percentile: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let index = min(values.count - 1, max(0, Int(Double(values.count - 1) * percentile)))
        return values[index]
    }
}

struct CopilotStateMachine: Hashable, Sendable {
    private(set) var state: CopilotRuntimeState = .idle

    mutating func transition(to next: CopilotRuntimeState) -> Bool {
        guard canTransition(from: state, to: next) else { return false }
        state = next
        return true
    }

    private func canTransition(from current: CopilotRuntimeState, to next: CopilotRuntimeState) -> Bool {
        if current == next { return true }
        switch current {
        case .idle:
            return [.listening, .paused, .permissionBlocked, .failedRecoverable, .intentDetected].contains(next)
        case .listening:
            return [.intentDetected, .paused, .permissionBlocked, .idle].contains(next)
        case .intentDetected:
            return [.classifying, .routing, .failedRecoverable, .listening, .paused].contains(next)
        case .classifying:
            return [.routing, .failedRecoverable, .listening, .paused].contains(next)
        case .routing:
            return [.calculating, .searching, .synthesizing, .failedRecoverable, .paused].contains(next)
        case .calculating, .searching, .synthesizing:
            return [.ready, .failedRecoverable, .paused].contains(next)
        case .ready:
            return [.listening, .intentDetected, .idle, .paused].contains(next)
        case .failedRecoverable:
            return [.listening, .intentDetected, .paused, .idle].contains(next)
        case .permissionBlocked:
            return [.listening, .paused, .idle].contains(next)
        case .paused:
            return [.listening, .idle, .permissionBlocked].contains(next)
        }
    }
}

enum SpeechCandidateSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case best
    case alternative
    case repair
    case languageFanout = "language_fanout"

    var id: String { rawValue }
}

struct SpeechCandidateFrame: Identifiable, Hashable, Sendable {
    var id = UUID()
    var sourceSegmentId: UUID
    var text: String
    var source: SpeechCandidateSource
    var languageCode: String?
    var asrConfidence: Double
    var languageConfidence: Double?
    var stability: Double
    var wordConfidences: [Double]
    var startTime: TimeInterval
    var endTime: TimeInterval
    var isPartial: Bool
    var isFinal: Bool
    var repairReason: String?
    var clarificationMessage: String?

    var combinedConfidence: Double {
        let languageScore = languageConfidence ?? 0.70
        return min(max((asrConfidence * 0.64) + (languageScore * 0.16) + (stability * 0.20), 0), 1)
    }
}

struct CopilotSpeechRepairRule: Codable, Hashable, Sendable {
    var match: String
    var replacement: String
    var languages: [String]?
    var confidence: Double
    var reason: String
}

struct CopilotSpeechClarificationRule: Codable, Hashable, Sendable {
    var containsAll: [String]
    var requiresAny: [String]
    var message: String
}

struct CopilotSpeechPolicy: Codable, Hashable, Sendable {
    var version: Int
    var alternativeLimit: Int
    var repairLimit: Int
    var lowConfidenceRepairThreshold: Double
    var repairConfidenceFloor: Double
    var sourceWeights: [String: Double]
    var repairRules: [CopilotSpeechRepairRule]
    var clarificationRules: [CopilotSpeechClarificationRule]

    func sourceWeight(_ source: SpeechCandidateSource) -> Double {
        sourceWeights[source.rawValue] ?? 1.0
    }
}

enum CopilotSpeechPolicyStore {
    static let current: CopilotSpeechPolicy = load()

    private static func load() -> CopilotSpeechPolicy {
        let decoder = JSONDecoder()
        for url in candidateURLs() {
            guard let data = try? Data(contentsOf: url),
                  let policy = try? decoder.decode(CopilotSpeechPolicy.self, from: data) else {
                continue
            }
            return policy
        }
        return fallbackPolicy()
    }

    private static func candidateURLs() -> [URL] {
        var urls: [URL] = []
        let bundles = [Bundle.main, Bundle(for: CopilotIntentPolicyBundleMarker.self)]
        for bundle in bundles {
            if let url = bundle.url(forResource: "default", withExtension: "json", subdirectory: "CopilotSpeechPolicy") {
                urls.append(url)
            }
            if let url = bundle.url(forResource: "speech-default", withExtension: "json") {
                urls.append(url)
            }
        }
        urls.append(
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/CopilotSpeechPolicy/default.json")
        )
        return urls
    }

    private static func fallbackPolicy() -> CopilotSpeechPolicy {
        CopilotSpeechPolicy(
            version: 0,
            alternativeLimit: 6,
            repairLimit: 4,
            lowConfidenceRepairThreshold: 0.86,
            repairConfidenceFloor: 0.58,
            sourceWeights: ["best": 1.0, "alternative": 0.94, "repair": 0.86, "language_fanout": 0.92],
            repairRules: [],
            clarificationRules: []
        )
    }
}

struct CopilotASRRepairEngine {
    var policy: CopilotSpeechPolicy = CopilotSpeechPolicyStore.current
    private let languageDetector = AppleLanguageDetectionService()

    func repairCandidates(for segment: TranscriptSegment, baseText: String? = nil) -> [SpeechCandidateFrame] {
        let sourceText = (baseText ?? segment.text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceText.isEmpty else { return [] }
        let normalized = QuestionDetectionService.normalize(sourceText)
        let segmentConfidence = segment.engineConfidence ?? segment.confidence
        let shouldRepair = segmentConfidence <= policy.lowConfidenceRepairThreshold
            || segment.languageConfidence ?? 1 < 0.72
            || !lowConfidenceWords(in: segment).isEmpty
        guard shouldRepair else { return [] }

        var frames: [SpeechCandidateFrame] = []
        for rule in policy.repairRules {
            let match = QuestionDetectionService.normalize(rule.match)
            guard !match.isEmpty, normalized.contains(match) else { continue }
            let repaired = normalized.replacingOccurrences(of: match, with: QuestionDetectionService.normalize(rule.replacement))
            guard repaired != normalized else { continue }
            frames.append(frame(
                text: repaired,
                segment: segment,
                source: .repair,
                confidence: min(max(rule.confidence, policy.repairConfidenceFloor), 0.92),
                reason: rule.reason
            ))
        }

        return frames.deduplicatedSpeechCandidates(limit: policy.repairLimit)
    }

    private func frame(
        text: String,
        segment: TranscriptSegment,
        source: SpeechCandidateSource,
        confidence: Double,
        reason: String?
    ) -> SpeechCandidateFrame {
        let detectedLanguage = languageDetector.detectedLanguage(for: text, minimumConfidence: 0.30)
        let clarification = clarificationMessage(for: text)
        return SpeechCandidateFrame(
            sourceSegmentId: segment.id,
            text: text,
            source: source,
            languageCode: detectedLanguage?.languageCode ?? segment.originalLanguage,
            asrConfidence: confidence,
            languageConfidence: detectedLanguage?.confidence ?? segment.languageConfidence,
            stability: segment.isFinal ? 1.0 : 0.68,
            wordConfidences: segment.wordTimestamps.compactMap(\.confidence),
            startTime: segment.startTime,
            endTime: segment.endTime,
            isPartial: !segment.isFinal,
            isFinal: segment.isFinal,
            repairReason: reason,
            clarificationMessage: clarification
        )
    }

    private func lowConfidenceWords(in segment: TranscriptSegment) -> [TranscriptWordTimestamp] {
        segment.wordTimestamps.filter { ($0.confidence ?? 1.0) < 0.78 }
    }

    func clarificationMessage(for text: String) -> String? {
        let normalized = QuestionDetectionService.normalize(text)
        for rule in policy.clarificationRules {
            let containsAll = rule.containsAll
                .map(QuestionDetectionService.normalize)
                .allSatisfy { normalized.contains($0) }
            guard containsAll else { continue }
            let hasRequiredDetail = rule.requiresAny
                .map(QuestionDetectionService.normalize)
                .contains { normalized.contains($0) }
            if !hasRequiredDetail {
                return rule.message
            }
        }
        return nil
    }
}

struct CopilotSpeechUnderstandingPipeline {
    var policy: CopilotSpeechPolicy = CopilotSpeechPolicyStore.current
    var repairEngine: CopilotASRRepairEngine = CopilotASRRepairEngine()
    private let languageDetector = AppleLanguageDetectionService()

    func candidateFrames(from segment: TranscriptSegment, context: TranscriptContext?) -> [SpeechCandidateFrame] {
        let primary = frame(
            text: segment.text,
            source: .best,
            segment: segment,
            confidence: segment.engineConfidence ?? segment.confidence,
            repairReason: nil
        )
        var frames = [primary]

        let alternatives = segment.alternatives
            .prefix(policy.alternativeLimit)
            .map { alternative in
                frame(
                    text: alternative.text,
                    source: candidateSource(for: alternative, segment: segment),
                    segment: segment,
                    confidence: alternative.confidence ?? (segment.engineConfidence ?? segment.confidence) * 0.94,
                    languageCode: alternative.languageCode,
                    repairReason: alternative.source.rawValue
                )
            }
        frames.append(contentsOf: alternatives)
        frames.append(contentsOf: repairEngine.repairCandidates(for: segment))
        for alternative in segment.alternatives.prefix(policy.alternativeLimit) {
            frames.append(contentsOf: repairEngine.repairCandidates(for: segment, baseText: alternative.text))
        }

        return frames
            .map { candidate in
                var adjusted = candidate
                adjusted.asrConfidence = min(max(candidate.asrConfidence * policy.sourceWeight(candidate.source), 0), 1)
                adjusted = boostIfDomainVocabularyPresent(adjusted)
                return adjusted
            }
            .deduplicatedSpeechCandidates(limit: max(3, 1 + policy.alternativeLimit + policy.repairLimit))
    }

    private func candidateSource(for alternative: TranscriptAlternative, segment: TranscriptSegment) -> SpeechCandidateSource {
        if alternative.source == .repair { return .repair }
        guard let alternativeLanguage = alternative.languageCode,
              let segmentLanguage = segment.originalLanguage,
              SupportedLanguage.normalizedCode(alternativeLanguage) != SupportedLanguage.normalizedCode(segmentLanguage) else {
            return .alternative
        }
        return .languageFanout
    }

    private func boostIfDomainVocabularyPresent(_ frame: SpeechCandidateFrame) -> SpeechCandidateFrame {
        let normalized = QuestionDetectionService.normalize(frame.text)
        let domainTerms = [
            "swiftui", "openai", "chatgpt", "api", "deploy", "deployment", "pr", "branch",
            "bug", "latency", "roadmap", "notchly", "rag", "pull request", "screen capture kit"
        ]
        guard domainTerms.contains(where: { normalized.contains($0) }) else { return frame }
        var boosted = frame
        boosted.asrConfidence = min(1, boosted.asrConfidence + 0.045)
        boosted.languageConfidence = min(1, (boosted.languageConfidence ?? 0.7) + 0.035)
        return boosted
    }

    private func frame(
        text rawText: String,
        source: SpeechCandidateSource,
        segment: TranscriptSegment,
        confidence: Double,
        languageCode: String? = nil,
        repairReason: String?
    ) -> SpeechCandidateFrame {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let detectedLanguage = languageCode == nil ? languageDetector.detectedLanguage(for: text, minimumConfidence: 0.30) : nil
        return SpeechCandidateFrame(
            sourceSegmentId: segment.id,
            text: text,
            source: source,
            languageCode: languageCode ?? detectedLanguage?.languageCode ?? segment.originalLanguage,
            asrConfidence: min(max(confidence, 0), 1),
            languageConfidence: detectedLanguage?.confidence ?? segment.languageConfidence,
            stability: segment.isFinal ? 1.0 : partialStability(for: segment, text: text),
            wordConfidences: segment.wordTimestamps.compactMap(\.confidence),
            startTime: segment.startTime,
            endTime: segment.endTime,
            isPartial: !segment.isFinal,
            isFinal: segment.isFinal,
            repairReason: repairReason,
            clarificationMessage: repairEngine.clarificationMessage(for: text)
        )
    }

    private func partialStability(for segment: TranscriptSegment, text: String) -> Double {
        if segment.isFinal { return 1.0 }
        let wordCount = text.split(separator: " ").count
        return min(0.88, 0.42 + Double(min(wordCount, 8)) * 0.055 + min(Double(segment.revisionNumber) * 0.06, 0.18))
    }
}

enum CopilotSpeechFrameSelector {
    static func bestFrame(
        in frames: [SpeechCandidateFrame],
        context: TranscriptContext? = nil,
        preferences: AppPreferences? = nil
    ) -> SpeechCandidateFrame? {
        frames.max { lhs, rhs in
            score(lhs, context: context, preferences: preferences) < score(rhs, context: context, preferences: preferences)
        }
    }

    static func score(
        _ frame: SpeechCandidateFrame,
        context: TranscriptContext? = nil,
        preferences: AppPreferences? = nil
    ) -> Double {
        let text = frame.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return -.infinity }

        var score = frame.combinedConfidence
        switch frame.source {
        case .best:
            score += 0.035
        case .alternative:
            score += 0.015
        case .languageFanout:
            score += 0.025
        case .repair:
            score -= 0.025
        }

        if frame.isFinal && !frame.isPartial {
            score += 0.14
        } else {
            score -= (preferences?.copilotASRCommitPolicy == .accurate) ? 0.24 : 0.12
        }

        let normalized = QuestionDetectionService.normalize(text)
        let tokenCount = normalized.split(separator: " ").count
        if normalized.count < 10 || tokenCount <= 1 {
            score -= 0.16
        } else if normalized.count < 18 {
            score -= 0.06
        }

        let lowConfidenceWords = frame.wordConfidences.filter { $0 < 0.68 }.count
        if lowConfidenceWords > 0 {
            score -= min(0.20, Double(lowConfidenceWords) * 0.045)
        }
        if (frame.languageConfidence ?? 0.7) < 0.42 {
            score -= 0.10
        }
        if frame.stability < 0.55 {
            score -= 0.10
        }
        if looksTruncated(normalized) {
            score -= 0.07
        }
        if let dominantLanguage = context?.dominantLanguage,
           let frameLanguage = frame.languageCode,
           SupportedLanguage.normalizedCode(dominantLanguage) == SupportedLanguage.normalizedCode(frameLanguage) {
            score += 0.025
        }
        score += contextOverlapBonus(text: normalized, context: context)
        return min(max(score, 0), 1.2)
    }

    private static func looksTruncated(_ normalized: String) -> Bool {
        let trailingFragments = [
            "de", "do", "da", "dos", "das", "para", "pra", "por", "com", "sobre",
            "of", "for", "to", "with", "about", "the", "a", "an"
        ]
        guard let last = normalized.split(separator: " ").last.map(String.init) else { return false }
        return trailingFragments.contains(last)
    }

    private static func contextOverlapBonus(text: String, context: TranscriptContext?) -> Double {
        guard let context else { return 0 }
        let recent = QuestionDetectionService.normalize(context.recentTranscript + " " + context.mediumTranscript)
        guard !recent.isEmpty else { return 0 }
        let tokens = text
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 5 }
            .filter { !["sobre", "qual", "quais", "como", "porque", "quando", "where", "what", "which", "about"].contains($0) }
        guard !tokens.isEmpty else { return 0 }
        let matches = tokens.filter { recent.contains($0) }.count
        return min(0.05, Double(matches) * 0.012)
    }
}

struct CopilotIntentCandidateDecision: Hashable, Sendable {
    var frame: SpeechCandidateFrame
    var classification: CopilotIntentClassification
    var score: Double

    var shouldClarify: Bool {
        frame.clarificationMessage != nil
            && frame.combinedConfidence >= 0.52
            && !classification.negativeSignals.contains("operational_check")
            && !classification.negativeSignals.contains("small_talk")
    }
}

struct CopilotIntentCandidateSet: Hashable, Sendable {
    var decisions: [CopilotIntentCandidateDecision]

    var best: CopilotIntentCandidateDecision? {
        let bestDecision = decisions.max { lhs, rhs in
            if lhs.classification.shouldSurface != rhs.classification.shouldSurface {
                return !lhs.classification.shouldSurface && rhs.classification.shouldSurface
            }
            return lhs.score < rhs.score
        }
        if let clarification,
           let bestDecision,
           clarification.score >= bestDecision.score - 0.18 {
            return clarification
        }
        return bestDecision
    }

    var clarification: CopilotIntentCandidateDecision? {
        decisions
            .filter(\.shouldClarify)
            .max { $0.score < $1.score }
    }

    static func score(frame: SpeechCandidateFrame, classification: CopilotIntentClassification) -> Double {
        var score = classification.confidence * 0.64 + frame.combinedConfidence * 0.28
        if classification.preferredTool != .unavailable { score += 0.05 }
        if classification.shouldSurface { score += 0.08 }
        if frame.source == .repair { score -= 0.04 }
        if classification.negativeSignals.contains("missing_question_structure") {
            score -= 0.10
        }
        return min(max(score, 0), 1)
    }
}

@MainActor
final class CopilotInteractionStore {
    private let repository: MeetingRepository
    private let retentionDays: Int
    private let privacyGuard: PrivacyGuard

    init(repository: MeetingRepository, retentionDays: Int, privacyGuard: PrivacyGuard = PrivacyGuard()) {
        self.repository = repository
        self.retentionDays = max(1, retentionDays)
        self.privacyGuard = privacyGuard
    }

    func load(now: Date = Date()) -> (interactions: [CopilotInteraction], reminders: [CopilotReminder]) {
        try? repository.purgeExpiredCopilotData(now: now)
        return (
            (try? repository.copilotInteractions(now: now)) ?? [],
            (try? repository.copilotReminders(now: now)) ?? []
        )
    }

    func clearHistory(now: Date = Date()) throws {
        try repository.deleteCopilotHistory(now: now)
    }

    func saveInteraction(_ interaction: CopilotInteraction) throws {
        try repository.purgeExpiredCopilotData()
        try repository.saveCopilotInteraction(interaction)
    }

    func saveMemory(prompt: String, answer: String, languageCode: String?, interactionId: UUID?) throws {
        try repository.saveCopilotMemoryEntry(CopilotMemoryEntry(
            id: UUID(),
            text: privacyGuard.redact("\(prompt)\n\(answer)"),
            languageCode: languageCode,
            sourceInteractionId: interactionId,
            createdAt: Date(),
            expiresAt: expiry()
        ))
    }

    func saveReminder(_ reminder: CopilotReminder) throws {
        try repository.saveCopilotReminder(reminder)
    }

    func expiry(from date: Date = Date()) -> Date {
        Calendar.current.date(byAdding: .day, value: retentionDays, to: date) ?? date.addingTimeInterval(Double(retentionDays) * 24 * 60 * 60)
    }
}

struct CopilotAnswerPresenter {
    var privacyGuard = PrivacyGuard()

    func present(
        text rawText: String,
        candidate: QuestionCandidate,
        classification: QuestionClassification,
        tool: CopilotToolKind,
        intent: CopilotIntentKind,
        sources: [AnswerSource],
        preferredFormat: CopilotAnswerFormat? = nil,
        richAnswer: RichAnswerPayload? = nil
    ) throws -> CopilotAnswerPresentation {
        let format = answerFormat(for: rawText, tool: tool, intent: intent, question: candidate.rawText, preferredFormat: preferredFormat)
        let cleaned = try validatedText(rawText, format: format)
        let compacted = compact(cleaned, format: format)
        let sourceCleaned = sources.isEmpty ? compacted : RichAnswerTextSanitizer.removingRenderedSourceURLs(from: compacted, sources: sources)
        let redacted = privacyGuard.redact(sourceCleaned)
        let sourceCaveat = sourceCaveatIfNeeded(format: format, sources: sources)
        let text = sourceCaveat.map { "\(redacted)\n\n\($0)" } ?? redacted
        let fallbackRichAnswer = RichAnswerFallbackBuilder.payload(
            text: text,
            format: format,
            sources: sources,
            confidence: classification.confidence,
            riskLevel: .safe,
            tone: classification.expectedAnswerStyle,
            caveats: sourceCaveat.map { [$0] } ?? []
        )
        let validatedRichAnswer = RichAnswerValidator().validated(richAnswer, sources: sources) ?? fallbackRichAnswer
        return CopilotAnswerPresentation(
            text: text,
            shortText: AnswerPresentationFormatter.shortAnswer(from: text),
            format: format,
            caveats: sourceCaveat.map { [$0] } ?? [],
            sources: sources,
            richAnswer: validatedRichAnswer
        )
    }

    func failure(_ failure: CopilotFailure) -> CopilotAnswerPresentation {
        CopilotAnswerPresentation(
            text: failure.userMessage,
            shortText: failure.userMessage,
            format: .errorState,
            caveats: failure.detail.map { [$0] } ?? [],
            sources: [],
            richAnswer: RichAnswerFallbackBuilder.payload(text: failure.userMessage, format: .errorState, sources: [], riskLevel: .moderate)
        )
    }

    private func answerFormat(for text: String, tool: CopilotToolKind, intent: CopilotIntentKind, question: String, preferredFormat: CopilotAnswerFormat?) -> CopilotAnswerFormat {
        if preferredFormat == .code || containsExecutableCodeBlock(text) {
            return .code
        }
        if let preferredFormat, preferredFormat != .errorState, preferredFormat != .code {
            return preferredFormat
        }
        switch tool {
        case .calculator:
            return .calculation
        case .reminder:
            return .reminderConfirmation
        case .localMemory:
            return .memoryResults
        case .webSearch:
            return intent == .newsSearch ? .newsWithSources : .bullets
        case .answerSynthesis:
            let proseCandidate = stripCodeFences(from: text)
            let normalized = QuestionDetectionService.normalize(proseCandidate)
            if normalized.count <= 90 && !proseCandidate.contains("\n\n") {
                return .plainShort
            }
            return text.contains("\n- ") || text.contains("\n* ") || text.contains("\n1.") ? .bullets : .paragraph
        case .unavailable:
            return .errorState
        }
    }

    private func validatedText(_ text: String, format: CopilotAnswerFormat) throws -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CopilotFailure(.emptyResponse)
        }
        if !format.allowsCodeBlocks {
            trimmed = stripCodeFences(from: trimmed)
        }
        guard !trimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CopilotFailure(.emptyResponse)
        }
        return trimmed
    }

    private func stripCodeFences(from text: String) -> String {
        guard containsCodeBlock(text) else { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") == true,
              lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") == true else {
            return text
        }
        return lines.dropFirst().dropLast().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func compact(_ text: String, format: CopilotAnswerFormat) -> String {
        guard format != .code, text.count > 1_600 else { return text }
        let prefix = String(text.prefix(1_240))
        if let sentenceEnd = prefix.lastIndex(where: { ".!?\n".contains($0) }) {
            return String(prefix[...sentenceEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private func sourceCaveatIfNeeded(format: CopilotAnswerFormat, sources: [AnswerSource]) -> String? {
        guard format == .newsWithSources else { return nil }
        let hasValidURL = sources.contains { source in
            guard let reference = source.reference else { return false }
            return URL(string: reference)?.scheme?.hasPrefix("http") == true
        }
        return hasValidURL ? nil : "Fontes web indisponiveis ou incompletas nesta resposta."
    }

    private func containsCodeBlock(_ text: String) -> Bool {
        text.contains("```")
    }

    private func containsExecutableCodeBlock(_ text: String) -> Bool {
        guard containsCodeBlock(text) else { return false }
        let lowercased = text.lowercased()
        let codeLanguages = ["```swift", "```python", "```js", "```javascript", "```ts", "```typescript", "```json", "```yaml", "```bash", "```sh", "```sql", "```xml", "```diff"]
        if codeLanguages.contains(where: lowercased.contains) {
            return true
        }
        return ["func ", "let ", "var ", "def ", "class ", "import ", "const ", "=>", "{", "}", "</", "$ "].contains { lowercased.contains($0) }
    }

    private func explicitlyRequestsCode(_ text: String) -> Bool {
        let normalized = QuestionDetectionService.normalize(text)
        return ["codigo", "código", "code", "swift", "python", "json", "yaml", "terminal", "comando", "command"].contains { normalized.contains($0) }
    }
}

struct CopilotIntentClassification: Codable, Hashable, Sendable {
    var kind: CopilotIntentKind
    var responseNeeded: Bool
    var confidence: Double
    var strongSignals: Set<String>
    var negativeSignals: [String]
    var reason: String
    var extractedQuery: String
    var requiresWeb: Bool
    var preferredTool: CopilotToolKind
    var languageCode: String?

    var shouldSurface: Bool {
        responseNeeded && negativeSignals.isEmpty
    }
}

struct CopilotInteraction: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var contextKind: CopilotRuntimeKind
    var source: CopilotRuntimeSource
    var questionId: UUID?
    var prompt: String
    var response: String
    var tool: CopilotToolKind
    var intent: CopilotIntentKind
    var languageCode: String?
    var confidence: Double
    var latencyMs: Int
    var sources: [AnswerSource]
    var richAnswer: RichAnswerPayload?
    var feedbackEvents: [QuestionAnswerFeedbackEvent]
    var createdAt: Date
    var expiresAt: Date

    init(
        id: UUID = UUID(),
        contextKind: CopilotRuntimeKind,
        source: CopilotRuntimeSource,
        questionId: UUID? = nil,
        prompt: String,
        response: String,
        tool: CopilotToolKind,
        intent: CopilotIntentKind,
        languageCode: String? = nil,
        confidence: Double,
        latencyMs: Int,
        sources: [AnswerSource] = [],
        richAnswer: RichAnswerPayload? = nil,
        feedbackEvents: [QuestionAnswerFeedbackEvent] = [],
        createdAt: Date = Date(),
        expiresAt: Date
    ) {
        self.id = id
        self.contextKind = contextKind
        self.source = source
        self.questionId = questionId
        self.prompt = prompt
        self.response = response
        self.tool = tool
        self.intent = intent
        self.languageCode = languageCode
        self.confidence = confidence
        self.latencyMs = latencyMs
        self.sources = sources
        self.richAnswer = richAnswer
        self.feedbackEvents = feedbackEvents
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

struct CopilotMemoryEntry: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var text: String
    var languageCode: String?
    var sourceInteractionId: UUID?
    var createdAt: Date
    var expiresAt: Date
}

enum CopilotReminderStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case scheduled
    case completed
    case cancelled
    case failed

    var id: String { rawValue }
}

struct CopilotReminder: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var title: String
    var scheduledAt: Date
    var notificationId: String
    var status: CopilotReminderStatus
    var createdAt: Date
    var expiresAt: Date
}

struct CopilotIntentPolicyThresholds: Codable, Hashable, Sendable {
    var activation: Double
    var directedActivation: Double
    var wakeWordActivation: Double
    var partialActivation: Double
    var negativeBlock: Double
    var minimumSignals: Int
    var partialMinimumTokens: Int
}

struct CopilotIntentPolicyWeights: Codable, Hashable, Sendable {
    var semantic: Double
    var syntax: Double
    var tool: Double
    var direction: Double
    var finality: Double
    var asrConfidence: Double
    var negative: Double
    var meaningfulContent: Double
}

struct CopilotIntentPolicySignals: Codable, Hashable, Sendable {
    var acceptedIntent: String
    var directedToCopilot: String
    var shortcut: String
    var typed: String
    var semanticIntent: String
    var questionSyntax: String
    var questionPunctuation: String
    var meaningfulContent: String
    var toolIntent: String
    var semanticPrefixCue: String
    var wakeWord: String
    var finalUtterance: String
}

struct CopilotIntentLabelPolicy: Codable, Hashable, Sendable {
    var label: String
    var kind: CopilotIntentKind
    var tool: CopilotToolKind
    var confidence: Double
    var weight: Double
    var requiresWeb: Bool?
    var cues: [String]
    var prefixCues: [String]?
    var signals: [String]
}

struct CopilotIntentPolicy: Codable, Hashable, Sendable {
    var version: Int
    var minimumInputCharacters: Int
    var thresholds: [String: CopilotIntentPolicyThresholds]
    var weights: CopilotIntentPolicyWeights
    var signals: CopilotIntentPolicySignals
    var wakeWords: [String]
    var surfaceNegativeSignals: [String]
    var semanticOverrideSurfaceNegativeSignals: [String]
    var partialIncompleteCues: [String]
    var stopWords: [String]
    var lowInformationWords: [String]
    var numberWords: [String]
    var operatorWords: [String]
    var semanticLabels: [CopilotIntentLabelPolicy]
    var toolLabels: [CopilotIntentLabelPolicy]
    var negativeLabels: [CopilotIntentLabelPolicy]

    func thresholds(for mode: QAPrecisionMode) -> CopilotIntentPolicyThresholds {
        thresholds[mode.rawValue] ?? thresholds["highPrecision"] ?? CopilotIntentPolicyThresholds(
            activation: 0.80,
            directedActivation: 0.70,
            wakeWordActivation: 0.70,
            partialActivation: 0.90,
            negativeBlock: 0.62,
            minimumSignals: 2,
            partialMinimumTokens: 4
        )
    }
}

enum CopilotIntentPolicyStore {
    static let current: CopilotIntentPolicy = load()

    private static func load() -> CopilotIntentPolicy {
        let decoder = JSONDecoder()
        for url in candidateURLs() {
            guard let data = try? Data(contentsOf: url),
                  let policy = try? decoder.decode(CopilotIntentPolicy.self, from: data) else {
                continue
            }
            return policy
        }
        return fallbackPolicy()
    }

    private static func candidateURLs() -> [URL] {
        var urls: [URL] = []
        let bundles = [Bundle.main, Bundle(for: CopilotIntentPolicyBundleMarker.self)]
        for bundle in bundles {
            if let url = bundle.url(forResource: "default", withExtension: "json", subdirectory: "CopilotIntentPolicy") {
                urls.append(url)
            }
            if let url = bundle.url(forResource: "default", withExtension: "json") {
                urls.append(url)
            }
        }
        urls.append(
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/CopilotIntentPolicy/default.json")
        )
        return urls
    }

    private static func fallbackPolicy() -> CopilotIntentPolicy {
        CopilotIntentPolicy(
            version: 0,
            minimumInputCharacters: 3,
            thresholds: [
                "highPrecision": CopilotIntentPolicyThresholds(
                    activation: 0.80,
                    directedActivation: 0.70,
                    wakeWordActivation: 0.70,
                    partialActivation: 0.90,
                    negativeBlock: 0.62,
                    minimumSignals: 2,
                    partialMinimumTokens: 4
                )
            ],
            weights: CopilotIntentPolicyWeights(
                semantic: 0.52,
                syntax: 0.22,
                tool: 0.18,
                direction: 0.10,
                finality: 0.05,
                asrConfidence: 0.06,
                negative: 0.40,
                meaningfulContent: 0.08
            ),
            signals: CopilotIntentPolicySignals(
                acceptedIntent: "accepted_intent",
                directedToCopilot: "directed_to_copilot",
                shortcut: "shortcut",
                typed: "typed",
                semanticIntent: "semantic_intent",
                questionSyntax: "question_syntax",
                questionPunctuation: "question_punctuation",
                meaningfulContent: "meaningful_content",
                toolIntent: "tool_intent",
                semanticPrefixCue: "semantic_prefix_cue",
                wakeWord: "wake_word",
                finalUtterance: "final_utterance"
            ),
            wakeWords: [],
            surfaceNegativeSignals: [],
            semanticOverrideSurfaceNegativeSignals: [],
            partialIncompleteCues: [],
            stopWords: [],
            lowInformationWords: [],
            numberWords: [],
            operatorWords: [],
            semanticLabels: [],
            toolLabels: [],
            negativeLabels: []
        )
    }
}

private final class CopilotIntentPolicyBundleMarker {}

struct CopilotIntentFrame: Hashable, Sendable {
    var rawText: String
    var normalizedText: String
    var cleanedText: String
    var languageCode: String?
    var source: CopilotRuntimeSource
    var context: TranscriptContext?
    var profile: UserMeetingProfile?
    var surface: QuestionSurfaceAnalysis
    var isFinal: Bool
    var asrConfidence: Double?
    var wakeWordDetected: Bool
}

struct CopilotSemanticIntentPrediction: Hashable, Sendable {
    var kind: CopilotIntentKind
    var tool: CopilotToolKind
    var confidence: Double
    var requiresWeb: Bool
    var signals: Set<String>
    var negativeSignals: [String]
    var reason: String
}

protocol CopilotSemanticIntentProvider {
    func prediction(for frame: CopilotIntentFrame, policy: CopilotIntentPolicy) -> CopilotSemanticIntentPrediction?
}

struct CoreMLCopilotIntentProvider: CopilotSemanticIntentProvider {
    var modelResourceName: String

    func prediction(for frame: CopilotIntentFrame, policy: CopilotIntentPolicy) -> CopilotSemanticIntentPrediction? {
        let bundles = [Bundle.main, Bundle(for: CopilotIntentPolicyBundleMarker.self)]
        guard let modelURL = bundles.compactMap({ $0.url(forResource: modelResourceName, withExtension: "mlmodelc") }).first else {
            return nil
        }
        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            let model = try MLModel(contentsOf: modelURL, configuration: configuration)
            guard let inputName = textInputName(for: model) else { return nil }
            let input = try MLDictionaryFeatureProvider(dictionary: [inputName: frame.cleanedText])
            let output = try model.prediction(from: input)
            guard let label = predictedLabel(from: output),
                  let mapped = mappedPrediction(label: label, policy: policy) else { return nil }
            let confidence = predictedConfidence(label: label, output: output) ?? mapped.confidence
            return CopilotSemanticIntentPrediction(
                kind: mapped.kind,
                tool: mapped.tool,
                confidence: min(max(confidence, 0.05), 0.98),
                requiresWeb: mapped.requiresWeb ?? (mapped.tool == .webSearch),
                signals: Set(mapped.signals).union([policy.signals.semanticIntent]),
                negativeSignals: negativeSignals(for: mapped, policy: policy),
                reason: "coreml:\(label)"
            )
        } catch {
            return nil
        }
    }

    private func textInputName(for model: MLModel) -> String? {
        let inputs = model.modelDescription.inputDescriptionsByName
        if let text = inputs.first(where: { $0.value.type == .string && ["text", "input", "query", "utterance"].contains($0.key) }) {
            return text.key
        }
        return inputs.first(where: { $0.value.type == .string })?.key
    }

    private func predictedLabel(from output: MLFeatureProvider) -> String? {
        for name in ["classLabel", "label", "intent", "class"] {
            if let value = output.featureValue(for: name)?.stringValue, !value.isEmpty {
                return value
            }
        }
        for name in output.featureNames {
            if let value = output.featureValue(for: name), value.type == .string, !value.stringValue.isEmpty {
                return value.stringValue
            }
        }
        return nil
    }

    private func predictedConfidence(label: String, output: MLFeatureProvider) -> Double? {
        for name in ["classLabelProbs", "labelProbabilities", "probabilities", "scores"] {
            guard let dictionary = output.featureValue(for: name)?.dictionaryValue else { continue }
            if let value = dictionary[AnyHashable(label)] {
                return value.doubleValue
            }
            if let value = dictionary[AnyHashable(NSString(string: label))] {
                return value.doubleValue
            }
        }
        return nil
    }

    private func mappedPrediction(label rawLabel: String, policy: CopilotIntentPolicy) -> CopilotIntentLabelPolicy? {
        let label = QuestionDetectionService.normalize(rawLabel).replacingOccurrences(of: " ", with: "_")
        if let policyLabel = (policy.semanticLabels + policy.toolLabels + policy.negativeLabels).first(where: { $0.label == label || $0.kind.rawValue == label }) {
            return policyLabel
        }
        let tool: CopilotToolKind
        let kind: CopilotIntentKind
        let confidence: Double
        let requiresWeb: Bool
        switch label {
        case "answerable_question", "question":
            kind = .answerableQuestion
            tool = .answerSynthesis
            confidence = 0.88
            requiresWeb = false
        case "action_request", "request":
            kind = .actionRequest
            tool = .answerSynthesis
            confidence = 0.88
            requiresWeb = false
        case "calculation", "math", "date_math":
            kind = .calculation
            tool = .answerSynthesis
            confidence = 0.91
            requiresWeb = false
        case "conversion":
            kind = .conversion
            tool = .answerSynthesis
            confidence = 0.88
            requiresWeb = false
        case "web_search":
            kind = .webSearch
            tool = .webSearch
            confidence = 0.90
            requiresWeb = true
        case "news", "news_search":
            kind = .newsSearch
            tool = .webSearch
            confidence = 0.90
            requiresWeb = true
        case "reminder":
            kind = .reminder
            tool = .reminder
            confidence = 0.90
            requiresWeb = false
        case "memory_lookup":
            kind = .memoryLookup
            tool = .localMemory
            confidence = 0.86
            requiresWeb = false
        case "statement":
            kind = .statement
            tool = .unavailable
            confidence = 0.84
            requiresWeb = false
        case "noise", "ambient_noise":
            kind = .ambientNoise
            tool = .unavailable
            confidence = 0.84
            requiresWeb = false
        case "ambiguous":
            kind = .ambiguous
            tool = .unavailable
            confidence = 0.62
            requiresWeb = false
        default:
            return nil
        }
        return CopilotIntentLabelPolicy(
            label: label,
            kind: kind,
            tool: tool,
            confidence: confidence,
            weight: 1.0,
            requiresWeb: requiresWeb,
            cues: [],
            prefixCues: [],
            signals: [policy.signals.semanticIntent]
        )
    }

    private func negativeSignals(for label: CopilotIntentLabelPolicy, policy: CopilotIntentPolicy) -> [String] {
        switch label.kind {
        case .statement, .ambientNoise, .smallTalk, .ambiguous:
            return label.signals.isEmpty ? ["coreml_negative"] : label.signals
        default:
            return []
        }
    }
}

struct PolicyDrivenCopilotSemanticIntentProvider: CopilotSemanticIntentProvider {
    func prediction(for frame: CopilotIntentFrame, policy: CopilotIntentPolicy) -> CopilotSemanticIntentPrediction? {
        let syntaxScore = questionSyntaxScore(frame: frame)
        let contentScore = meaningfulContentScore(in: frame.cleanedText)
        let numericScore = numericExpressionScore(in: frame.cleanedText)
        let negativeSignals = frame.surface.negativeSignals

        if numericScore >= 0.92 {
            return CopilotSemanticIntentPrediction(
                kind: .calculation,
                tool: .answerSynthesis,
                confidence: min(0.90, 0.70 + numericScore * 0.12 + syntaxScore * 0.08),
                requiresWeb: false,
                signals: [policy.signals.semanticIntent, policy.signals.toolIntent, policy.signals.questionSyntax],
                negativeSignals: negativeSignals,
                reason: "structural_numeric_expression"
            )
        }

        if frame.surface.strongSignals.contains(.actionRequestFrame), contentScore >= 0.35 {
            return CopilotSemanticIntentPrediction(
                kind: .actionRequest,
                tool: .answerSynthesis,
                confidence: min(0.88, 0.66 + syntaxScore * 0.12 + contentScore * 0.10),
                requiresWeb: false,
                signals: [policy.signals.semanticIntent, policy.signals.questionSyntax, policy.signals.meaningfulContent],
                negativeSignals: negativeSignals,
                reason: "structural_action_request"
            )
        }

        if syntaxScore >= 0.52, contentScore >= 0.40 {
            return CopilotSemanticIntentPrediction(
                kind: .answerableQuestion,
                tool: .answerSynthesis,
                confidence: min(0.87, 0.64 + syntaxScore * 0.14 + contentScore * 0.08),
                requiresWeb: false,
                signals: [policy.signals.semanticIntent, policy.signals.questionSyntax, policy.signals.meaningfulContent],
                negativeSignals: negativeSignals,
                reason: "structural_question"
            )
        }

        if frame.surface.negativeSignals.isEmpty == false, syntaxScore < 0.40 {
            return CopilotSemanticIntentPrediction(
                kind: .statement,
                tool: .unavailable,
                confidence: 0.74,
                requiresWeb: false,
                signals: [],
                negativeSignals: negativeSignals,
                reason: "structural_negative"
            )
        }

        return nil
    }

    private func questionSyntaxScore(frame: CopilotIntentFrame) -> Double {
        var score = 0.0
        if frame.surface.hasQuestionPunctuation { score += 0.34 }
        if frame.surface.strongSignals.contains(.interrogativeStarter) { score += 0.28 }
        if frame.surface.strongSignals.contains(.modalQuestionFrame) { score += 0.26 }
        if frame.surface.strongSignals.contains(.indirectQuestionFrame) { score += 0.24 }
        if frame.surface.strongSignals.contains(.actionRequestFrame) { score += 0.22 }
        if frame.surface.strongSignals.contains(.concreteObject) { score += 0.10 }
        if frame.surface.strongSignals.contains(.contextualCarryover) { score += 0.06 }
        if QuestionDetectionService.containsCJK(frame.cleanedText), frame.cleanedText.count >= 5 { score += 0.28 }
        return min(score, 1.0)
    }

    private func numericExpressionScore(in text: String) -> Double {
        let decimalText = text.replacingOccurrences(of: ",", with: ".")
        if decimalText.range(of: #"\d+(?:\.\d+)?\s*(?:%|\+|\-|\*|/|×|÷)\s*\d+"#, options: .regularExpression) != nil {
            return 1.0
        }
        if decimalText.range(of: #"\d+(?:\.\d+)?\s*%[^\d]{0,16}\d+(?:\.\d+)?"#, options: .regularExpression) != nil {
            return 0.96
        }
        if decimalText.range(of: #"\d+(?:\.\d+)?\s*(?:%|percent).*?\s+\d+(?:\.\d+)?"#, options: .regularExpression) != nil {
            return 0.94
        }
        return 0
    }

    private func meaningfulContentScore(in text: String) -> Double {
        let tokenCount = text
            .split(separator: " ")
            .filter { token in
                token.count >= 3 && token.unicodeScalars.contains { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
            }
            .count
        return min(Double(tokenCount) / 5.0, 1.0)
    }
}

struct CompositeCopilotSemanticIntentProvider: CopilotSemanticIntentProvider {
    var providers: [any CopilotSemanticIntentProvider]

    func prediction(for frame: CopilotIntentFrame, policy: CopilotIntentPolicy) -> CopilotSemanticIntentPrediction? {
        for provider in providers {
            if let prediction = provider.prediction(for: frame, policy: policy) {
                return prediction
            }
        }
        return nil
    }
}

struct CopilotIntentEngine {
    var policy: CopilotIntentPolicy = CopilotIntentPolicyStore.current
    var rulePack: QuestionIntentRulePack = .default
    var languageDetector = AppleLanguageDetectionService()
    var semanticProvider: (any CopilotSemanticIntentProvider)?

    func classify(
        text rawText: String,
        context: TranscriptContext? = nil,
        source: CopilotRuntimeSource = .microphone,
        preferences: AppPreferences = AppPreferences(),
        profile: UserMeetingProfile? = nil,
        isPartial: Bool = false,
        asrConfidence: Double? = nil
    ) -> CopilotIntentClassification {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let language = languageDetector.dominantLanguage(for: trimmed)
        guard trimmed.count >= policy.minimumInputCharacters else {
            return ignored(.ambientNoise, text: trimmed, reason: "too_short", language: language)
        }

        let normalized = QuestionDetectionService.normalize(trimmed)
        let wakeWord = wakeWordDetected(in: normalized)
        let cleaned = removeWakeWord(from: normalized)
        let analyzer = QuestionSurfaceAnalyzer(rulePack: rulePack)
        let surface = analyzer.analyze(
            text: trimmed,
            normalized: normalized,
            context: context,
            profile: profile,
            isPartial: isPartial,
            isFinal: !isPartial
        )
        let frame = CopilotIntentFrame(
            rawText: trimmed,
            normalizedText: normalized,
            cleanedText: cleaned,
            languageCode: language,
            source: source,
            context: context,
            profile: profile,
            surface: surface,
            isFinal: !isPartial,
            asrConfidence: asrConfidence,
            wakeWordDetected: wakeWord
        )
        let provider = semanticProvider ?? CompositeCopilotSemanticIntentProvider(
            providers: [
                CoreMLCopilotIntentProvider(modelResourceName: preferences.localQuestionModelProfile.bundledCoreMLResourceName),
                PolicyDrivenCopilotSemanticIntentProvider()
            ]
        )
        let prediction = provider.prediction(for: frame, policy: policy)
        return decision(
            frame: frame,
            prediction: prediction,
            preferences: preferences,
            source: source,
            wakeWord: wakeWord
        )
    }

    func isPartialReadyForIntent(_ text: String, preferences: AppPreferences = AppPreferences()) -> Bool {
        let normalized = QuestionDetectionService.normalize(text)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard normalized.count >= policy.minimumInputCharacters else { return false }
        if policy.partialIncompleteCues.contains(where: { normalized == QuestionDetectionService.normalize($0) }) {
            return false
        }
        return normalized.split(separator: " ").count >= policy.thresholds(for: preferences.qaPrecisionMode).partialMinimumTokens
    }

    private func decision(
        frame: CopilotIntentFrame,
        prediction: CopilotSemanticIntentPrediction?,
        preferences: AppPreferences,
        source: CopilotRuntimeSource,
        wakeWord: Bool
    ) -> CopilotIntentClassification {
        let thresholds = policy.thresholds(for: preferences.qaPrecisionMode)
        let baseSignals = Set(frame.surface.strongSignals.map(\.rawValue))
        let surfaceNegatives = frame.surface.negativeSignals.filter { policy.surfaceNegativeSignals.contains($0) }
        guard let prediction else {
            return CopilotIntentClassification(
                kind: .statement,
                responseNeeded: false,
                confidence: frame.surface.isRejected ? 0.12 : 0.32,
                strongSignals: baseSignals,
                negativeSignals: surfaceNegatives.isEmpty ? ["no_clear_intent"] : surfaceNegatives,
                reason: surfaceNegatives.isEmpty ? "no_clear_intent" : surfaceNegatives.joined(separator: ","),
                extractedQuery: frame.rawText,
                requiresWeb: false,
                preferredTool: .unavailable,
                languageCode: frame.languageCode
            )
        }

        var signals = baseSignals.union(prediction.signals)
        var negativeSignals = Array(Set(surfaceNegatives + prediction.negativeSignals)).sorted()
        var confidence = calibratedConfidence(frame: frame, prediction: prediction, preferences: preferences)
        if shouldTrustSemanticIntentOverSoftSurfaceNegative(
            frame: frame,
            prediction: prediction,
            confidence: confidence,
            thresholds: thresholds
        ) {
            let softSurfaceNegatives = Set(policy.semanticOverrideSurfaceNegativeSignals)
            negativeSignals.removeAll { softSurfaceNegatives.contains($0) }
        }
        if wakeWord {
            signals.insert(policy.signals.wakeWord)
            signals.insert(policy.signals.directedToCopilot)
        }
        if source == .shortcut {
            signals.insert(policy.signals.shortcut)
        }
        if source == .typed {
            signals.insert(policy.signals.typed)
        }
        if frame.surface.hasQuestionPunctuation {
            signals.insert(policy.signals.questionPunctuation)
        }
        if !frame.surface.meaningfulTokens.isEmpty {
            signals.insert(policy.signals.meaningfulContent)
        }
        if frame.isFinal {
            signals.insert(policy.signals.finalUtterance)
        }

        let explicitDirection = wakeWord || source == .shortcut || source == .typed
        let activationThreshold = explicitDirection ? thresholds.directedActivation : thresholds.activation
        let trustedToolIntent = prediction.tool != .unavailable
            && prediction.tool != .answerSynthesis
            && prediction.confidence >= thresholds.activation
        let wakeWordRequired = preferences.copilotActivationPolicy == .wakeWord
            && !explicitDirection
            && !trustedToolIntent
            && !isHighConfidenceDirectQuestion(frame: frame, confidence: confidence, thresholds: thresholds)
        if wakeWordRequired {
            return rejected(
                kind: .ambientNoise,
                frame: frame,
                confidence: min(confidence, 0.42),
                signals: signals,
                reason: "wake_word_required"
            )
        }

        if requiresQuestionStructure(
            frame: frame,
            prediction: prediction,
            explicitDirection: explicitDirection
        ) {
            return rejected(
                kind: .ambiguous,
                frame: frame,
                confidence: min(confidence, 0.52),
                signals: signals,
                reason: "missing_question_structure"
            )
        }

        let hasBlockingNegative = !negativeSignals.isEmpty && !trustedToolIntent
        let minimumSignals = max(1, thresholds.minimumSignals)
        let accepted = !hasBlockingNegative
            && prediction.kind != .statement
            && prediction.kind != .ambientNoise
            && prediction.kind != .smallTalk
            && confidence >= (frame.isFinal ? activationThreshold : thresholds.partialActivation)
            && signals.count >= minimumSignals

        if accepted {
            signals.insert(policy.signals.acceptedIntent)
            negativeSignals.removeAll()
            confidence = max(confidence, activationThreshold)
        }

        return CopilotIntentClassification(
            kind: accepted ? prediction.kind : rejectedKind(for: prediction),
            responseNeeded: accepted,
            confidence: accepted ? confidence : min(confidence, 0.58),
            strongSignals: signals,
            negativeSignals: accepted ? [] : (negativeSignals.isEmpty ? ["below_clear_intent_threshold"] : negativeSignals),
            reason: accepted ? prediction.reason : (negativeSignals.first ?? "below_clear_intent_threshold"),
            extractedQuery: frame.rawText,
            requiresWeb: accepted && webRequired(for: prediction, text: frame.cleanedText, preferences: preferences),
            preferredTool: accepted ? prediction.tool : .unavailable,
            languageCode: frame.languageCode
        )
    }

    private func calibratedConfidence(
        frame: CopilotIntentFrame,
        prediction: CopilotSemanticIntentPrediction,
        preferences: AppPreferences
    ) -> Double {
        let analyzer = QuestionSurfaceAnalyzer(rulePack: rulePack)
        let surfaceConfidence = analyzer.confidence(
            for: frame.surface,
            isPartial: !frame.isFinal,
            precisionMode: preferences.qaPrecisionMode
        )
        var confidence = prediction.confidence * policy.weights.semantic
            + surfaceConfidence * policy.weights.syntax
            + (prediction.tool == .unavailable ? 0 : policy.weights.tool)
        if frame.wakeWordDetected || frame.source != .microphone {
            confidence += policy.weights.direction
        }
        if frame.isFinal {
            confidence += policy.weights.finality
        }
        if let asrConfidence = frame.asrConfidence {
            confidence += min(max(asrConfidence, 0), 1) * policy.weights.asrConfidence
        }
        if !frame.surface.meaningfulTokens.isEmpty {
            confidence += policy.weights.meaningfulContent
        }
        if !prediction.negativeSignals.isEmpty {
            confidence -= policy.weights.negative
        }
        return min(max(confidence, 0.05), 0.98)
    }

    private func webRequired(
        for prediction: CopilotSemanticIntentPrediction,
        text: String,
        preferences: AppPreferences
    ) -> Bool {
        switch preferences.copilotWebMode {
        case .always:
            return prediction.tool == .webSearch || prediction.kind == .answerableQuestion
        case .confirmBeforeCloud:
            return false
        case .onDemand:
            return prediction.requiresWeb
        }
    }

    private func rejectedKind(for prediction: CopilotSemanticIntentPrediction) -> CopilotIntentKind {
        switch prediction.kind {
        case .smallTalk, .ambientNoise, .statement:
            return prediction.kind
        default:
            return .ambiguous
        }
    }

    private func isHighConfidenceDirectQuestion(
        frame: CopilotIntentFrame,
        confidence: Double,
        thresholds: CopilotIntentPolicyThresholds
    ) -> Bool {
        guard frame.surface.negativeSignals.isEmpty, confidence >= thresholds.activation else { return false }
        let hasQuestionFrame = frame.surface.hasQuestionPunctuation
            || frame.surface.strongSignals.contains(.interrogativeStarter)
            || frame.surface.strongSignals.contains(.modalQuestionFrame)
            || frame.surface.strongSignals.contains(.indirectQuestionFrame)
            || frame.surface.strongSignals.contains(.actionRequestFrame)
        let hasObject = frame.surface.strongSignals.contains(.concreteObject)
            || frame.surface.strongSignals.contains(.domainObject)
            || !frame.surface.meaningfulTokens.isEmpty
        return hasQuestionFrame && hasObject
    }

    private func requiresQuestionStructure(
        frame: CopilotIntentFrame,
        prediction: CopilotSemanticIntentPrediction,
        explicitDirection: Bool
    ) -> Bool {
        guard prediction.kind == .answerableQuestion,
              prediction.tool == .answerSynthesis,
              !explicitDirection,
              !prediction.signals.contains(policy.signals.semanticPrefixCue) else {
            return false
        }
        return !hasQuestionStructure(frame: frame)
    }

    private func hasQuestionStructure(frame: CopilotIntentFrame) -> Bool {
        frame.surface.hasQuestionPunctuation
            || frame.surface.strongSignals.contains(.interrogativeStarter)
            || frame.surface.strongSignals.contains(.modalQuestionFrame)
            || frame.surface.strongSignals.contains(.indirectQuestionFrame)
            || frame.surface.strongSignals.contains(.actionRequestFrame)
    }

    private func shouldTrustSemanticIntentOverSoftSurfaceNegative(
        frame: CopilotIntentFrame,
        prediction: CopilotSemanticIntentPrediction,
        confidence: Double,
        thresholds: CopilotIntentPolicyThresholds
    ) -> Bool {
        guard confidence >= thresholds.activation,
              prediction.kind != .statement,
              prediction.kind != .ambientNoise,
              prediction.kind != .smallTalk,
              prediction.signals.contains(policy.signals.semanticIntent),
              !policy.semanticOverrideSurfaceNegativeSignals.isEmpty else {
            return false
        }
        return !frame.surface.meaningfulTokens.isEmpty
    }

    private func rejected(
        kind: CopilotIntentKind,
        frame: CopilotIntentFrame,
        confidence: Double,
        signals: Set<String>,
        reason: String
    ) -> CopilotIntentClassification {
        CopilotIntentClassification(
            kind: kind,
            responseNeeded: false,
            confidence: confidence,
            strongSignals: signals,
            negativeSignals: [reason],
            reason: reason,
            extractedQuery: frame.rawText,
            requiresWeb: false,
            preferredTool: .unavailable,
            languageCode: frame.languageCode
        )
    }

    private func ignored(_ kind: CopilotIntentKind, text: String, reason: String, language: String?) -> CopilotIntentClassification {
        CopilotIntentClassification(
            kind: kind,
            responseNeeded: false,
            confidence: 0.08,
            strongSignals: [],
            negativeSignals: [reason],
            reason: reason,
            extractedQuery: text,
            requiresWeb: false,
            preferredTool: .unavailable,
            languageCode: language
        )
    }

    private func wakeWordDetected(in text: String) -> Bool {
        policy.wakeWords.contains { marker in
            let normalizedMarker = QuestionDetectionService.normalize(marker)
            return hasWakeBoundary(text, marker: normalizedMarker) || text.contains(" \(normalizedMarker) ")
        }
    }

    private func removeWakeWord(from text: String) -> String {
        var result = text
        for marker in policy.wakeWords.map(QuestionDetectionService.normalize).sorted(by: { $0.count > $1.count }) {
            if hasWakeBoundary(result, marker: marker) {
                result = result
                    .removingPrefix(marker)
                    .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            }
        }
        return result
    }

    private func hasWakeBoundary(_ text: String, marker: String) -> Bool {
        guard !marker.isEmpty, text == marker || text.hasPrefix(marker) else { return false }
        guard text.count > marker.count else { return true }
        let boundary = text[text.index(text.startIndex, offsetBy: marker.count)]
        return boundary.isWhitespace || boundary.isPunctuation
    }
}

struct CopilotIntentClassifier {
    var engine = CopilotIntentEngine()

    func classify(
        text rawText: String,
        context: TranscriptContext? = nil,
        source: CopilotRuntimeSource = .microphone,
        preferences: AppPreferences = AppPreferences(),
        profile: UserMeetingProfile? = nil,
        isPartial: Bool = false,
        asrConfidence: Double? = nil
    ) -> CopilotIntentClassification {
        engine.classify(
            text: rawText,
            context: context,
            source: source,
            preferences: preferences,
            profile: profile,
            isPartial: isPartial,
            asrConfidence: asrConfidence
        )
    }

    func isPartialReadyForIntent(_ text: String, preferences: AppPreferences = AppPreferences()) -> Bool {
        engine.isPartialReadyForIntent(text, preferences: preferences)
    }
}

private extension QuestionSurfaceAnalysis {
    var confidenceCeiling: Double {
        isRejected ? 0.20 : 0.45
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String {
        guard hasPrefix(prefix) else { return self }
        return String(dropFirst(prefix.count))
    }
}

private extension Array where Element == SpeechCandidateFrame {
    func deduplicatedSpeechCandidates(limit: Int) -> [SpeechCandidateFrame] {
        var seen = Set<String>()
        var result: [SpeechCandidateFrame] = []
        for candidate in sorted(by: { $0.combinedConfidence > $1.combinedConfidence }) {
            let key = QuestionDetectionService.normalize(candidate.text)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(candidate)
            if result.count >= limit { break }
        }
        return result
    }
}

enum AnswerSourceType: String, Codable, CaseIterable, Identifiable, Sendable {
    case transcript
    case rag
    case web
    case calendar
    case jira
    case github
    case manualContext = "manual_context"
    case unknown

    var id: String { rawValue }
}

enum AnswerGenerationStage: String, Codable, CaseIterable, Identifiable, Sendable {
    case idle
    case classifying
    case retrievingContext = "retrieving_context"
    case drafting
    case finalizing
    case ready
    case cancelled
    case failed

    var id: String { rawValue }

    var isInProgress: Bool {
        switch self {
        case .classifying, .retrievingContext, .drafting, .finalizing:
            true
        case .idle, .ready, .cancelled, .failed:
            false
        }
    }

    var displayName: String {
        switch self {
        case .idle: "Listening"
        case .classifying: "Understanding"
        case .retrievingContext: "Retrieving Context"
        case .drafting: "Drafting"
        case .finalizing: "Finalizing"
        case .ready: "Ready"
        case .cancelled: "Cancelled"
        case .failed: "Failed"
        }
    }
}

struct UserMeetingProfile: Codable, Hashable, Sendable {
    var userName: String
    var userAliases: [String]
    var userRole: String
    var preferredStyle: AnswerStyle
    var preferredLanguages: [String]
    var meetingType: MeetingType
}

struct TranscriptContext: Codable, Hashable, Sendable {
    var recentTranscript: String
    var mediumTranscript: String
    var completeTranscript: String = ""
    var dominantLanguage: String?
    var currentSegment: TranscriptSegment?
}

struct MeetingShortTermMemory: Codable, Hashable, Sendable {
    var currentTopic: String?
    var recentDecisions: [String] = []
    var mentionedPeople: [String] = []
    var mentionedProjects: [String] = []
    var openQuestions: [String] = []
    var actionItems: [String] = []
    var conversationMood: String?
    var dominantLanguage: String?
}

struct MeetingContext: Codable, Hashable, Sendable {
    var meeting: MeetingSession
    var transcriptContext: TranscriptContext
    var shortTermMemory: MeetingShortTermMemory
    var preferences: AppPreferences
}

struct AnswerGenerationOptions: Codable, Hashable, Sendable {
    var maxSentences: Int = 3
    var allowCommitments: Bool = false
    var enableWebSearch: Bool = false
    var enableRAG: Bool = true
    var localOnlyMode: Bool = true
}

struct PartialAnswer: Codable, Hashable, Sendable {
    var textDelta: String
    var isFinal: Bool
    var suggestedAnswer: SuggestedAnswer?
}

struct QuestionAnswerQueueItem: Identifiable, Codable, Hashable, Sendable {
    var id: UUID { candidate.id }
    var candidate: QuestionCandidate
    var classification: QuestionClassification?
    var stage: AnswerGenerationStage
    var streamingText: String
    var answer: SuggestedAnswer?
    var decision: String
    var surfacedAt: Date
    var updatedAt: Date

    init(
        candidate: QuestionCandidate,
        classification: QuestionClassification? = nil,
        stage: AnswerGenerationStage = .classifying,
        streamingText: String = "",
        answer: SuggestedAnswer? = nil,
        decision: String = "detected",
        surfacedAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.candidate = candidate
        self.classification = classification
        self.stage = stage
        self.streamingText = streamingText
        self.answer = answer
        self.decision = decision
        self.surfacedAt = surfacedAt
        self.updatedAt = updatedAt
    }
}

struct QuestionAnswerRecord: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var meetingId: UUID
    var question: QuestionCandidate
    var classification: QuestionClassification
    var answer: SuggestedAnswer?
    var contextSummary: String
    var sources: [AnswerSource]
    var decision: String
    var feedbackEvents: [QuestionAnswerFeedbackEvent]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        meetingId: UUID,
        question: QuestionCandidate,
        classification: QuestionClassification,
        answer: SuggestedAnswer? = nil,
        contextSummary: String,
        sources: [AnswerSource] = [],
        decision: String,
        feedbackEvents: [QuestionAnswerFeedbackEvent] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.meetingId = meetingId
        self.question = question
        self.classification = classification
        self.answer = answer
        self.contextSummary = contextSummary
        self.sources = sources
        self.decision = decision
        self.feedbackEvents = feedbackEvents
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct QuestionAnswerFeedbackEvent: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var kind: QuestionAnswerFeedbackKind
    var note: String?
    var createdAt: Date = Date()
}

enum QuestionAnswerFeedbackKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case copied
    case edited
    case dismissed
    case markedUseful = "marked_useful"
    case markedWrong = "marked_wrong"
    case regenerated
    case usedInMeeting = "used_in_meeting"

    var id: String { rawValue }
}

enum AnswerRefinementStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case shorter
    case diplomatic
    case technical

    var id: String { rawValue }

    var statusText: String {
        switch self {
        case .shorter:
            "Making it shorter..."
        case .diplomatic:
            "Making it more diplomatic..."
        case .technical:
            "Making it more technical..."
        }
    }

    var promptInstruction: String {
        switch self {
        case .shorter:
            "Rewrite the suggested response so it is shorter, sharper, and still safe to say in the meeting. Keep it to 1-2 concise sentences."
        case .diplomatic:
            "Rewrite the suggested response with a calmer, more diplomatic tone while preserving the same facts, uncertainty, and safety caveats."
        case .technical:
            "Rewrite the suggested response with a more technical framing. Keep it concise, concrete, and grounded in the provided context."
        }
    }
}

struct QuestionAnsweringAdaptiveProfile: Codable, Hashable, Sendable {
    var promotedPhrases: [String: Int] = [:]
    var suppressedPhrases: [String: Int] = [:]
    var promotedTerms: [String: Int] = [:]
    var suppressedTerms: [String: Int] = [:]

    var strictnessAdjustment: Double {
        let negative = suppressedPhrases.values.reduce(0, +) + suppressedTerms.values.reduce(0, +)
        let positive = promotedPhrases.values.reduce(0, +) + promotedTerms.values.reduce(0, +)
        return min(max(Double(negative - positive) * 0.015, -0.18), 0.24)
    }

    func isPromoted(_ plainText: String) -> Bool {
        promotedPhrases[plainText, default: 0] >= 2
            || learnedTerms(in: plainText, source: promotedTerms, minimumCount: 3)
    }

    func isSuppressed(_ plainText: String) -> Bool {
        suppressedPhrases[plainText, default: 0] >= 2
            || learnedTerms(in: plainText, source: suppressedTerms, minimumCount: 3)
    }

    mutating func record(feedback kind: QuestionAnswerFeedbackKind, rawText: String) {
        let plain = QuestionIntentGate.plainQuestionText(QuestionDetectionService.normalize(rawText))
        guard !plain.isEmpty else { return }
        switch kind {
        case .copied, .markedUseful, .usedInMeeting:
            promotedPhrases[plain, default: 0] += 1
            recordTerms(from: plain, into: &promotedTerms)
        case .dismissed, .markedWrong:
            suppressedPhrases[plain, default: 0] += 1
            recordTerms(from: plain, into: &suppressedTerms)
        case .edited, .regenerated:
            break
        }
        prune()
    }

    mutating func prune(limit: Int = 96) {
        promotedPhrases = Self.topEntries(promotedPhrases, limit: limit)
        suppressedPhrases = Self.topEntries(suppressedPhrases, limit: limit)
        promotedTerms = Self.topEntries(promotedTerms, limit: limit)
        suppressedTerms = Self.topEntries(suppressedTerms, limit: limit)
    }

    private func learnedTerms(in plainText: String, source: [String: Int], minimumCount: Int) -> Bool {
        let terms = Set(Self.meaningfulTerms(from: plainText))
        guard !terms.isEmpty else { return false }
        return terms.contains { source[$0, default: 0] >= minimumCount }
    }

    private func recordTerms(from plainText: String, into target: inout [String: Int]) {
        for term in Self.meaningfulTerms(from: plainText) {
            target[term, default: 0] += 1
        }
    }

    private static func meaningfulTerms(from plainText: String) -> [String] {
        plainText
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 4 && !QuestionIntentRulePack.default.stopWords.contains($0) }
    }

    private static func topEntries(_ source: [String: Int], limit: Int) -> [String: Int] {
        let sortedEntries = source.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }
        let limitedEntries = sortedEntries.prefix(limit).map { ($0.key, $0.value) }
        return Dictionary(uniqueKeysWithValues: limitedEntries)
    }
}
