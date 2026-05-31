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

    init(source: TranscriptAudioSource, preRollDuration: TimeInterval = 0.55) {
        self.processor = AudioConditioningStreamProcessor(source: source)
        self.preRoll = SpeechPreRollBuffer(duration: preRollDuration)
    }

    func reset() {
        lock.lock()
        vad.reset()
        preRoll.removeAll()
        wasForwardingSpeech = false
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

        let frames: [ConditionedAudioFrame]
        if decision.shouldForwardToASR {
            var emitted = [ConditionedAudioFrame]()
            if !wasForwardingSpeech {
                emitted.append(contentsOf: preRoll.buffers.map {
                    ConditionedAudioFrame(buffer: $0, quality: result.quality, vadDecision: decision, isPreRollReplay: true)
                })
                preRoll.removeAll()
            }
            emitted.append(ConditionedAudioFrame(buffer: conditioned, quality: result.quality, vadDecision: decision, isPreRollReplay: false))
            wasForwardingSpeech = true
            frames = emitted
        } else {
            preRoll.append(conditioned)
            wasForwardingSpeech = false
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
}
