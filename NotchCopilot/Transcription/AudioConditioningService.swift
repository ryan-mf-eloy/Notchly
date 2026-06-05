import Foundation

struct ConditionedAudioFrame: Sendable {
    var buffer: AudioBuffer
    var quality: SpeechAudioQualitySnapshot
    var vadDecision: VoiceActivityDecision
    var isPreRollReplay: Bool
}

struct AudioConditioningTrace: Sendable {
    var inputBuffer: AudioBuffer
    var conditionedBuffer: AudioBuffer
    var frames: [ConditionedAudioFrame]
    var quality: SpeechAudioQualitySnapshot
    var vadDecision: VoiceActivityDecision
}

final class AudioConditioningService: @unchecked Sendable {
    private let lock = NSLock()
    private let processor: AudioConditioningStreamProcessor
    private var vad = VoiceActivityDetector()
    private var preRoll: SpeechPreRollBuffer
    private var wasForwardingSpeech = false
    private var lastForwardedSpeechAt: Date?
    private var bridgedNonSpeechDuration: TimeInterval = 0
    private let nonDestructiveSpeechBridgeDuration: TimeInterval = 0.58

    init(source: TranscriptAudioSource, preRollDuration: TimeInterval = 1.25) {
        self.processor = AudioConditioningStreamProcessor(source: source)
        self.preRoll = SpeechPreRollBuffer(duration: preRollDuration)
    }

    func reset() {
        lock.lock()
        vad.reset()
        preRoll.removeAll()
        wasForwardingSpeech = false
        lastForwardedSpeechAt = nil
        bridgedNonSpeechDuration = 0
        lock.unlock()
    }

    func processStream(
        _ stream: AsyncStream<AudioBuffer>,
        config: AudioConditioningConfig,
        featureFlags: TranscriptionFeatureFlags
    ) -> AsyncStream<AudioBuffer> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                for await buffer in stream {
                    if Task.isCancelled { break }
                    let frames = self.condition(buffer, config: config, featureFlags: featureFlags)
                    for frame in frames {
                        if Task.isCancelled { break }
                        continuation.yield(frame.buffer)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    func condition(
        _ buffer: AudioBuffer,
        config: AudioConditioningConfig,
        featureFlags: TranscriptionFeatureFlags
    ) -> [ConditionedAudioFrame] {
        conditionWithTrace(buffer, config: config, featureFlags: featureFlags).frames
    }

    func conditionWithTrace(
        _ buffer: AudioBuffer,
        config: AudioConditioningConfig,
        featureFlags: TranscriptionFeatureFlags
    ) -> AudioConditioningTrace {
        lock.lock()
        let effectiveConfig = featureFlags.advancedAudioConditioningEnabled
            ? config
            : AudioConditioningConfig(accuracyMode: .standard, target: config.target, audioSource: config.audioSource)
        let result = processor.condition(buffer, config: effectiveConfig)
        let conditioned = result.buffer
        let decision: VoiceActivityDecision
        if featureFlags.vadGatingEnabled {
            decision = vad.analyze(conditioned, quality: result.quality)
        } else {
            decision = VoiceActivityDecision(
                source: conditioned.audioSource,
                detectionEngine: .vadDisabledPassthrough,
                state: .speechActive,
                shouldForwardToASR: true,
                speechProbability: 1,
                rms: conditioned.rms,
                peak: conditioned.peak,
                noiseFloor: result.quality.noiseFloor,
                snrDb: 99,
                zeroCrossingRate: 0,
                dynamicRange: conditioned.peak,
                envelopeVariation: 1,
                isClipping: result.quality.isClipping,
                reason: "vad_disabled"
            )
        }

        if featureFlags.transcriptionMetricsEnabled {
            Task {
                await TranscriptionMetrics.shared.recordAudioDecision(decision)
            }
        }

        let shouldBridgeSpeechGap = shouldBridgeNonSpeechFrame(
            decision,
            buffer: conditioned,
            quality: result.quality
        )
        let shouldForward = decision.shouldForwardToASR || shouldBridgeSpeechGap

        let frames: [ConditionedAudioFrame]
        if shouldForward {
            var emitted = [ConditionedAudioFrame]()
            if !wasForwardingSpeech && decision.shouldForwardToASR {
                emitted.append(contentsOf: preRoll.buffers.map {
                    ConditionedAudioFrame(buffer: $0, quality: result.quality, vadDecision: decision, isPreRollReplay: true)
                })
                preRoll.removeAll()
            }
            emitted.append(ConditionedAudioFrame(buffer: conditioned, quality: result.quality, vadDecision: decision, isPreRollReplay: false))
            wasForwardingSpeech = true
            if decision.shouldForwardToASR {
                lastForwardedSpeechAt = conditioned.createdAt
                bridgedNonSpeechDuration = 0
            } else {
                bridgedNonSpeechDuration += Self.duration(of: conditioned)
            }
            frames = emitted
        } else {
            preRoll.append(conditioned)
            wasForwardingSpeech = false
            bridgedNonSpeechDuration = 0
            frames = []
        }
        lock.unlock()
        return AudioConditioningTrace(
            inputBuffer: buffer,
            conditionedBuffer: conditioned,
            frames: frames,
            quality: result.quality,
            vadDecision: decision
        )
    }

    private func shouldBridgeNonSpeechFrame(
        _ decision: VoiceActivityDecision,
        buffer: AudioBuffer,
        quality: SpeechAudioQualitySnapshot
    ) -> Bool {
        guard wasForwardingSpeech,
              !decision.shouldForwardToASR,
              buffer.pcmBuffer != nil,
              decision.reason != "impulse_click",
              decision.reason != "sustained_tonal_non_speech",
              decision.reason != "sustained_broadband_non_speech",
              bridgedNonSpeechDuration < nonDestructiveSpeechBridgeDuration,
              let lastForwardedSpeechAt,
              buffer.createdAt.timeIntervalSince(lastForwardedSpeechAt) <= nonDestructiveSpeechBridgeDuration + 0.20 else {
            return false
        }

        return !quality.isClipping
    }

    private static func duration(of buffer: AudioBuffer) -> TimeInterval {
        guard let pcmBuffer = buffer.pcmBuffer, pcmBuffer.format.sampleRate > 0 else {
            return 0.10
        }
        return Double(pcmBuffer.frameLength) / pcmBuffer.format.sampleRate
    }
}
