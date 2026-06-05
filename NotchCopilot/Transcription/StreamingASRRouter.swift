import Foundation

@MainActor
final class StreamingASRRouter: TranscriptionService {
    typealias Source = MultiSourceAutoLanguageTranscriptionService.Source
    typealias ServiceFactory = @MainActor (Source) -> any TranscriptionService

    private let sources: [Source]
    private let serviceFactory: ServiceFactory
    private let conditioningTarget: AudioConditioningTarget
    private var services: [any TranscriptionService] = []
    private var forwardingTasks: [Task<Void, Never>] = []
    private var refinementTasks: [Task<Void, Never>] = []
    private var continuation: AsyncStream<TranscriptSegment>.Continuation?
    private var pendingSegments: [TranscriptSegment] = []
    private var smoothers: [TranscriptAudioSource: ASRStabilitySmoother] = [:]
    private var audioWindows: [TranscriptAudioSource: RecentAudioWindowStore] = [:]
    private let refiner: any LocalASRRefining
    private let maxPendingSegments = 96

    init(
        sources: [Source],
        conditioningTarget: AudioConditioningTarget = .nativeSpeech,
        refiner: (any LocalASRRefining)? = nil,
        serviceFactory: ServiceFactory? = nil
    ) {
        self.sources = sources
        self.conditioningTarget = conditioningTarget
        self.refiner = refiner ?? LocalASRRefinementService()
        self.serviceFactory = serviceFactory ?? { _ in
            AppleNativeTranscriptionService(allowsAutomaticLanguageSwitching: true)
        }
    }

    var segments: AsyncStream<TranscriptSegment> {
        AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            self.continuation = continuation
            for segment in self.pendingSegments {
                continuation.yield(segment)
            }
            self.pendingSegments.removeAll()
        }
    }

    func startTranscription(audioStream: AsyncStream<AudioBuffer>, config: TranscriptionConfig) async throws {
        guard !sources.isEmpty else { throw TranscriptionError.recognizerUnavailable }
        services = []
        forwardingTasks = []
        refinementTasks = []
        pendingSegments = []
        smoothers = [:]
        audioWindows = Dictionary(uniqueKeysWithValues: sources.map { ($0.audioSource, RecentAudioWindowStore(maxDuration: 9.0)) })

        do {
            for source in sources {
                let service = serviceFactory(source)
                let window = audioWindows[source.audioSource] ?? RecentAudioWindowStore(maxDuration: 9.0)
                audioWindows[source.audioSource] = window
                let conditionedStream = conditionedAudioStream(for: source, baseConfig: config, window: window)
                forwardSegments(from: service, source: source, config: config, window: window)

                var sourceConfig = config
                sourceConfig.audioSource = source.audioSource
                try await service.startTranscription(audioStream: conditionedStream, config: sourceConfig)
                services.append(service)
            }
        } catch {
            await stop()
            throw error
        }
    }

    func stop() async {
        for service in services {
            await service.stop()
        }
        services = []
        forwardingTasks.forEach { $0.cancel() }
        forwardingTasks = []
        refinementTasks.forEach { $0.cancel() }
        refinementTasks = []
        continuation?.finish()
        continuation = nil
    }

    private func conditionedAudioStream(
        for source: Source,
        baseConfig: TranscriptionConfig,
        window: RecentAudioWindowStore
    ) -> AsyncStream<AudioBuffer> {
        let conditioner = AudioConditioningService(source: source.audioSource)
        let conditioningConfig = AudioConditioningConfig(
            accuracyMode: baseConfig.accuracyMode,
            target: conditioningTarget,
            audioSource: source.audioSource
        )
        return AsyncStream { continuation in
            let task = Task {
                for await buffer in source.audioStream {
                    if Task.isCancelled { break }
                    let frames = conditioner.condition(buffer, config: conditioningConfig, featureFlags: baseConfig.featureFlags)
                    for frame in frames {
                        if Task.isCancelled { break }
                        window.append(frame.buffer)
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

    private func forwardSegments(
        from service: any TranscriptionService,
        source: Source,
        config: TranscriptionConfig,
        window: RecentAudioWindowStore
    ) {
        let stream = service.segments
        forwardingTasks.append(Task { @MainActor [weak self] in
            guard let self else { return }
            for await segment in stream {
                var labeled = MultiSourceAutoLanguageTranscriptionService.relabeled(
                    segment,
                    speakerLabel: source.speakerLabel,
                    audioSource: source.audioSource
                )
                labeled.audioEnergy = labeled.audioEnergy ?? Double(window.lastRMS())
                let firstAudioAt = window.firstAudioAt()
                var smoother = self.smoothers[source.audioSource] ?? ASRStabilitySmoother()
                let stableSegments = smoother.observe(labeled)
                self.smoothers[source.audioSource] = smoother
                for stable in stableSegments {
                    self.emit(stable)
                    if config.featureFlags.transcriptionMetricsEnabled {
                        Task {
                            await TranscriptionMetrics.shared.recordSegment(stable, firstAudioAt: firstAudioAt)
                        }
                    }
                    self.scheduleRefinementIfNeeded(stable, config: config, window: window)
                }
            }
        })
    }

    private func scheduleRefinementIfNeeded(
        _ segment: TranscriptSegment,
        config: TranscriptionConfig,
        window: RecentAudioWindowStore
    ) {
        guard config.featureFlags.localASRRefinerEnabled, segment.isFinal else { return }
        let audioBuffers = window.recentBuffers(overlapping: segment)
        guard !audioBuffers.isEmpty else { return }
        refinementTasks.append(Task { [weak self] in
            guard let self else { return }
            guard let outcome = await self.refiner.refine(segment: segment, audioBuffers: audioBuffers, config: config) else { return }
            await MainActor.run {
                self.emit(outcome.segment)
            }
            if config.featureFlags.transcriptionMetricsEnabled {
                await TranscriptionMetrics.shared.recordSegment(outcome.segment, firstAudioAt: window.firstAudioAt())
            }
        })
    }

    private func emit(_ segment: TranscriptSegment) {
        guard let continuation else {
            pendingSegments.append(segment)
            if pendingSegments.count > maxPendingSegments {
                pendingSegments.removeFirst(pendingSegments.count - maxPendingSegments)
            }
            return
        }
        continuation.yield(segment)
    }
}

final class RecentAudioWindowStore: @unchecked Sendable {
    private struct StoredBuffer {
        var buffer: AudioBuffer
        var startTime: TimeInterval
        var endTime: TimeInterval
    }

    private let lock = NSLock()
    private let maxDuration: TimeInterval
    private var buffers: [StoredBuffer] = []
    private var totalDuration: TimeInterval = 0
    private var nextStartTime: TimeInterval = 0
    private var firstAudioDate: Date?
    private var lastRMSValue: Float = 0

    init(maxDuration: TimeInterval) {
        self.maxDuration = maxDuration
    }

    func append(_ buffer: AudioBuffer) {
        lock.lock()
        if firstAudioDate == nil, buffer.rms > Self.firstAudioRMSFloor(for: buffer.audioSource) {
            firstAudioDate = buffer.createdAt
        }
        lastRMSValue = buffer.rms
        let duration = Self.duration(of: buffer)
        let storedBuffer = AudioBuffer(
            pcmBuffer: buffer.pcmBuffer?.copiedForAsyncUse(),
            time: buffer.time,
            mediaTime: buffer.mediaTime,
            rms: buffer.rms,
            peak: buffer.peak,
            createdAt: buffer.createdAt,
            audioSource: buffer.audioSource
        )
        let start = nextStartTime
        let end = start + duration
        buffers.append(StoredBuffer(buffer: storedBuffer, startTime: start, endTime: end))
        nextStartTime = max(end, nextStartTime + 0.000001)
        totalDuration += duration
        trim()
        lock.unlock()
    }

    func recentBuffers(overlapping segment: TranscriptSegment? = nil, padding: TimeInterval = 0.35) -> [AudioBuffer] {
        lock.lock()
        let copy: [AudioBuffer]
        if let segment, segment.endTime > segment.startTime {
            let start = max(0, segment.startTime - padding)
            let end = segment.endTime + padding
            let scoped = buffers.filter { stored in
                stored.endTime >= start && stored.startTime <= end
            }
            copy = scoped.map(\.buffer)
        } else {
            copy = buffers.map(\.buffer)
        }
        lock.unlock()
        return copy
    }

    func firstAudioAt() -> Date? {
        lock.lock()
        let value = firstAudioDate
        lock.unlock()
        return value
    }

    func lastRMS() -> Float {
        lock.lock()
        let value = lastRMSValue
        lock.unlock()
        return value
    }

    private func trim() {
        while totalDuration > maxDuration, !buffers.isEmpty {
            let removed = buffers.removeFirst()
            totalDuration -= max(0, removed.endTime - removed.startTime)
        }
        if buffers.count > 240 {
            buffers.removeFirst(buffers.count - 240)
            totalDuration = buffers.reduce(0) { $0 + max(0, $1.endTime - $1.startTime) }
        }
    }

    private static func duration(of buffer: AudioBuffer) -> TimeInterval {
        guard let pcmBuffer = buffer.pcmBuffer, pcmBuffer.format.sampleRate > 0 else { return 0.02 }
        return Double(pcmBuffer.frameLength) / pcmBuffer.format.sampleRate
    }

    private static func firstAudioRMSFloor(for source: TranscriptAudioSource) -> Float {
        switch source {
        case .system:
            return 0.000095
        case .microphone:
            return 0.00011
        default:
            return 0.00018
        }
    }
}
