import AVFoundation
import CoreMedia
import Foundation
import Speech

@MainActor
final class AppleNativeTranscriptionService: TranscriptionService {
    private let allowsAutomaticLanguageSwitching: Bool
    private var activeService: (any TranscriptionService)?
    private var forwardingTask: Task<Void, Never>?
    private var continuation: AsyncStream<TranscriptSegment>.Continuation?

    init(allowsAutomaticLanguageSwitching: Bool = true) {
        self.allowsAutomaticLanguageSwitching = allowsAutomaticLanguageSwitching
    }

    var segments: AsyncStream<TranscriptSegment> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func startTranscription(audioStream: AsyncStream<AudioBuffer>, config: TranscriptionConfig) async throws {
        await resetActiveService()
        if #available(macOS 26.0, *) {
            let analyzerService = SpeechAnalyzerTranscriptionService(allowsAutomaticLanguageSwitching: allowsAutomaticLanguageSwitching)
            activeService = analyzerService
            forwardSegments(from: analyzerService)
            do {
                try await analyzerService.startTranscription(audioStream: audioStream, config: config)
                return
            } catch {
                AppLog.audio.info("SpeechAnalyzer unavailable, falling back to SFSpeechRecognizer: \(error.localizedDescription, privacy: .public)")
                await resetActiveService()
            }
        }

        let service = AppleSpeechTranscriptionService(allowsAutomaticLanguageSwitching: allowsAutomaticLanguageSwitching)
        activeService = service
        forwardSegments(from: service)
        try await service.startTranscription(audioStream: audioStream, config: config)
    }

    func stop() async {
        await resetActiveService()
        continuation?.finish()
        continuation = nil
    }

    private func resetActiveService() async {
        forwardingTask?.cancel()
        forwardingTask = nil
        await activeService?.stop()
        activeService = nil
    }

    private func forwardSegments(from service: any TranscriptionService) {
        let stream = service.segments
        forwardingTask = Task { @MainActor [weak self] in
            for await segment in stream {
                self?.continuation?.yield(segment)
            }
        }
    }
}

@available(macOS 26.0, *)
enum AppleSpeechAssetPreparer {
    static func prepare(languageCode: String?) async -> SpeechAssetStatus {
        let locale = Locale(identifier: SupportedLanguage.normalizedCode(languageCode))
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return .unsupportedLanguage }
        let transcriber = SpeechTranscriber(locale: supportedLocale, preset: .progressiveTranscription)
        let detector = SpeechDetector(detectionOptions: .init(sensitivityLevel: .medium), reportResults: true)
        let modules: [any SpeechModule] = [detector, transcriber]
        do {
            _ = try await AssetInventory.reserve(locale: supportedLocale)
            if await AssetInventory.status(forModules: modules) < .installed,
               let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                try await request.downloadAndInstall()
            }
            let analyzer = SpeechAnalyzer(modules: modules)
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules)
            try await analyzer.prepareToAnalyze(in: format, withProgressReadyHandler: { progress in
                AppLog.audio.info("SpeechAnalyzer asset preparation progress \(progress.fractionCompleted, privacy: .public)")
            })
            return .ready
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

@available(macOS 26.0, *)
@MainActor
final class SpeechAnalyzerTranscriptionService: TranscriptionService {
    private let allowsAutomaticLanguageSwitching: Bool
    private var continuation: AsyncStream<TranscriptSegment>.Continuation?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var dictationTranscriber: DictationTranscriber?
    private var speechDetector: SpeechDetector?
    private var audioPump: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var speechDetectorTask: Task<Void, Never>?
    private var analyzerTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var fallbackActivationTask: Task<Void, Never>?
    private var fallbackForwardingTask: Task<Void, Never>?
    private var converter: SpeechAnalyzerBufferConverter?
    private var fallbackService: AppleSpeechTranscriptionService?
    private var fallbackAudioContinuation: AsyncStream<AudioBuffer>.Continuation?
    private var activeConfig: TranscriptionConfig?
    private var activeBackend: AppleNativeSpeechBackend = .speechAnalyzer
    private var activeLocaleIdentifier = SupportedLanguage.englishUS.rawValue
    private var activeSpeechContext: SpeechRecognitionContext?
    private var analysisStartedAt = Date()
    private var timelineClock = SpeechAudioTimelineClock()
    private let activityPolicy = SpeechActivityPolicy()
    private var fallbackPreRollBuffer = SpeechPreRollBuffer(duration: 1.4)
    private var lastSignificantAudioAt = Date.distantPast
    private var lastSegmentEmittedAt = Date.distantPast
    private var lastWatchdogNudgeAt = Date.distantPast
    private var rangeReconciler = SpeechAnalyzerRangeReconciler()
    private var speechDetectionTimeline = SpeechDetectionTimeline()
    private var qualityMonitor = SpeechAudioQualityMonitor(source: .unknown)
    private var isStopping = false
    private let languageDetector = AppleLanguageDetectionService()
    private let watchdogPolicy = SpeechRecognitionWatchdogPolicy()

    init(allowsAutomaticLanguageSwitching: Bool = true) {
        self.allowsAutomaticLanguageSwitching = allowsAutomaticLanguageSwitching
    }

    var segments: AsyncStream<TranscriptSegment> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func startTranscription(audioStream: AsyncStream<AudioBuffer>, config: TranscriptionConfig) async throws {
        guard await requestSpeechPermission() else { throw TranscriptionError.speechPermissionDenied }
        try await reset(shouldFinishContinuation: false)

        isStopping = false
        activeConfig = config
        activeSpeechContext = config.speechContext ?? SpeechRecognitionContext(
            locale: config.languageCode,
            terms: config.contextualStrings.map {
                SpeechContextTerm(text: $0, locale: nil, category: .custom, weight: 1, pronunciationXSAMPA: nil, source: "legacy")
            },
            customLanguageModelEnabled: config.requiresOnDeviceRecognition,
            status: "Using contextual hints only"
        )
        analysisStartedAt = Date()
        timelineClock.reset()
        fallbackPreRollBuffer.removeAll()
        lastSignificantAudioAt = .distantPast
        lastSegmentEmittedAt = .distantPast
        lastWatchdogNudgeAt = .distantPast
        rangeReconciler.reset()
        speechDetectionTimeline.reset()
        qualityMonitor = SpeechAudioQualityMonitor(source: config.audioSource)

        let setup = try await makeModule(config: config)
        activeBackend = setup.backend
        activeLocaleIdentifier = setup.locale.identifier
        analyzer = setup.analyzer
        transcriber = setup.transcriber
        dictationTranscriber = setup.dictationTranscriber
        speechDetector = setup.speechDetector
        converter = SpeechAnalyzerBufferConverter(outputFormat: setup.audioFormat)

        let inputStream = AsyncStream<AnalyzerInput> { continuation in
            self.inputContinuation = continuation
        }

        observeResults(backend: setup.backend)
        analyzerTask = Task { [weak self, analyzer = setup.analyzer, inputStream] in
            do {
                try await analyzer.start(inputSequence: inputStream)
            } catch {
                await MainActor.run {
                    self?.handleAnalyzerError(error)
                }
            }
        }

        audioPump = Task { @MainActor [weak self] in
            guard let self else { return }
            for await buffer in audioStream {
                guard !Task.isCancelled else { return }
                self.ingest(buffer)
            }
            self.inputContinuation?.finish()
            try? await self.analyzer?.finalizeAndFinishThroughEndOfInput()
        }
        startWatchdog()
        AppLog.audio.info("SpeechAnalyzer transcription started backend=\(setup.backend.displayName, privacy: .public) locale=\(setup.locale.identifier, privacy: .public)")
    }

    func stop() async {
        try? await reset(shouldFinishContinuation: true)
    }

    private func requestSpeechPermission() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            break
        @unknown default:
            return false
        }

        return await SpeechAuthorizationHelper.requestAuthorization() == .authorized
    }

    private struct ModuleSetup {
        var backend: AppleNativeSpeechBackend
        var locale: Locale
        var modules: [any SpeechModule]
        var analyzer: SpeechAnalyzer
        var transcriber: SpeechTranscriber?
        var dictationTranscriber: DictationTranscriber?
        var speechDetector: SpeechDetector?
        var audioFormat: AVAudioFormat?
    }

    private func makeModule(config: TranscriptionConfig) async throws -> ModuleSetup {
        let requestedLocale = Locale(identifier: SupportedLanguage.normalizedCode(config.languageCode))
        if SpeechTranscriber.isAvailable,
           let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) {
            let transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults, .alternativeTranscriptions],
                attributeOptions: [.audioTimeRange, .transcriptionConfidence]
            )
            let detector = Self.speechDetectorIfEnabled(config: config)
            var modules: [any SpeechModule] = []
            if let detector {
                modules.append(detector)
            }
            modules.append(transcriber)
            return try await preparedSetup(
                backend: .speechAnalyzer,
                locale: locale,
                modules: modules,
                transcriber: transcriber,
                dictationTranscriber: nil,
                speechDetector: detector,
                config: config
            )
        }

        if let locale = await DictationTranscriber.supportedLocale(equivalentTo: requestedLocale) {
            var contentHints: Set<DictationTranscriber.ContentHint> = [.farField]
            if let context = activeSpeechContext,
               let customLanguageModel = await AppleCustomLanguageModelManager.shared.configuration(for: context, languageCode: locale.identifier) {
                contentHints.insert(.customizedLanguage(modelConfiguration: customLanguageModel))
            }
            let preset = DictationTranscriber.Preset(
                contentHints: contentHints,
                transcriptionOptions: [.punctuation],
                reportingOptions: [.volatileResults, .frequentFinalization, .alternativeTranscriptions],
                attributeOptions: [.audioTimeRange, .transcriptionConfidence]
            )
            let dictation = DictationTranscriber(locale: locale, preset: preset)
            let detector = Self.speechDetectorIfEnabled(config: config)
            var modules: [any SpeechModule] = []
            if let detector {
                modules.append(detector)
            }
            modules.append(dictation)
            return try await preparedSetup(
                backend: .dictationTranscriber,
                locale: locale,
                modules: modules,
                transcriber: nil,
                dictationTranscriber: dictation,
                speechDetector: detector,
                config: config
            )
        }

        throw TranscriptionError.recognizerUnavailable
    }

    private static func speechDetectorIfEnabled(config: TranscriptionConfig) -> SpeechDetector? {
        guard config.featureFlags.vadGatingEnabled else { return nil }
        return SpeechDetector(detectionOptions: .init(sensitivityLevel: .medium), reportResults: true)
    }

    private func preparedSetup(
        backend: AppleNativeSpeechBackend,
        locale: Locale,
        modules: [any SpeechModule],
        transcriber: SpeechTranscriber?,
        dictationTranscriber: DictationTranscriber?,
        speechDetector: SpeechDetector?,
        config: TranscriptionConfig
    ) async throws -> ModuleSetup {
        _ = try await AssetInventory.reserve(locale: locale)
        let status = await AssetInventory.status(forModules: modules)
        guard status != .unsupported else { throw TranscriptionError.recognizerUnavailable }
        if status < .installed {
            AppLog.audio.info("SpeechAnalyzer assets downloading locale=\(locale.identifier, privacy: .public)")
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                try await request.downloadAndInstall()
            }
        }

        let context = AnalysisContext()
        let contextualStrings = config.speechContext?.contextualStrings ?? SpeechContextRanker().rank(config.contextualStrings)
        if !contextualStrings.isEmpty {
            context.contextualStrings[.general] = contextualStrings
        }

        let analyzer = SpeechAnalyzer(
            modules: modules,
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering)
        )
        let audioFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules)
        try await analyzer.setContext(context)
        try await analyzer.prepareToAnalyze(in: audioFormat, withProgressReadyHandler: { progress in
            AppLog.audio.info("SpeechAnalyzer preparing \(backend.displayName, privacy: .public) progress=\(progress.fractionCompleted, privacy: .public)")
        })
        return ModuleSetup(
            backend: backend,
            locale: locale,
            modules: modules,
            analyzer: analyzer,
            transcriber: transcriber,
            dictationTranscriber: dictationTranscriber,
            speechDetector: speechDetector,
            audioFormat: audioFormat
        )
    }

    private func observeResults(backend: AppleNativeSpeechBackend) {
        observeSpeechDetectionResults()
        if let transcriber {
            resultsTask = Task { @MainActor [weak self, transcriber] in
                do {
                    for try await result in transcriber.results {
                        self?.emit(
                            attributedText: result.text,
                            alternatives: result.alternatives,
                            range: result.range,
                            finalizationTime: result.resultsFinalizationTime,
                            isFinal: result.isFinal,
                            backend: backend
                        )
                    }
                } catch {
                    self?.handleAnalyzerError(error)
                }
            }
        } else if let dictationTranscriber {
            resultsTask = Task { @MainActor [weak self, dictationTranscriber] in
                do {
                    for try await result in dictationTranscriber.results {
                        self?.emit(
                            attributedText: result.text,
                            alternatives: result.alternatives,
                            range: result.range,
                            finalizationTime: result.resultsFinalizationTime,
                            isFinal: result.isFinal,
                            backend: backend
                        )
                    }
                } catch {
                    self?.handleAnalyzerError(error)
                }
            }
        }
    }

    private func observeSpeechDetectionResults() {
        guard let speechDetector else { return }
        speechDetectorTask = Task { @MainActor [weak self, speechDetector] in
            do {
                for try await result in speechDetector.results {
                    guard let self else { return }
                    self.speechDetectionTimeline.record(range: result.range, speechDetected: result.speechDetected)
                    if let activeConfig = self.activeConfig,
                       activeConfig.featureFlags.transcriptionMetricsEnabled {
                        let source = activeConfig.audioSource == .mixed ? TranscriptAudioSource.unknown : activeConfig.audioSource
                        Task {
                            await TranscriptionMetrics.shared.recordNativeSpeechDetectorObservation(
                                source: source,
                                speechDetected: result.speechDetected
                            )
                        }
                    }
                }
            } catch {
                AppLog.audio.info("SpeechDetector result stream ended: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func ingest(_ buffer: AudioBuffer) {
        let snapshot = qualityMonitor.ingest(buffer)
        if snapshot.isClipping {
            AppLog.audio.info("Speech audio clipping detected source=\(snapshot.source.displayName, privacy: .public)")
        }
        fallbackPreRollBuffer.append(buffer)
        fallbackAudioContinuation?.yield(buffer)
        let activity = activityPolicy.classify(snapshot)
        if activity.isSignificant {
            lastSignificantAudioAt = buffer.createdAt
        }
        guard fallbackService == nil else { return }
        guard let pcmBuffer = buffer.pcmBuffer else { return }
        let converted = converter?.convert(pcmBuffer) ?? pcmBuffer
        let bufferStartTime = timelineClock.nextStartTime(for: buffer, convertedBuffer: converted)
        inputContinuation?.yield(AnalyzerInput(buffer: converted, bufferStartTime: bufferStartTime))
    }

    private func emit(
        attributedText: AttributedString,
        alternatives: [AttributedString] = [],
        range: CMTimeRange,
        finalizationTime: CMTime,
        isFinal: Bool,
        backend: AppleNativeSpeechBackend
    ) {
        guard let activeConfig else { return }
        let text = String(attributedText.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let audioSource = activeConfig.audioSource == .mixed ? .unknown : activeConfig.audioSource
        if speechDetectionTimeline.coverage(for: range) == .nonSpeech {
            AppLog.audio.info("SpeechAnalyzer dropped non-speech transcript candidate source=\(audioSource.displayName, privacy: .public) chars=\(text.count, privacy: .public)")
            if activeConfig.featureFlags.transcriptionMetricsEnabled {
                Task {
                    await TranscriptionMetrics.shared.recordNativeSpeechDetectorDrop()
                }
            }
            return
        }
        let segmentId = rangeReconciler.segmentID(for: range, audioSource: audioSource, isFinal: isFinal)

        let startTime = range.start.safeSeconds
        let endTime = max(startTime, CMTimeRangeGetEnd(range).safeSeconds)
        let confidence = attributedText.speechConfidenceAverage ?? 0.72
        let detectedLanguage = languageDetector.detectedLanguage(for: text, minimumConfidence: 0.58)
        let phase: TranscriptionPhase = isFinal ? .final : .draft
        let engine = backend.transcriptionEngineName
        let nowOffset = Date().timeIntervalSince(analysisStartedAt)
        let finalizedThrough = max(endTime, finalizationTime.safeSeconds)
        let segment = TranscriptSegment(
            id: segmentId,
            meetingId: activeConfig.meetingId,
            speakerLabel: audioSource == .microphone ? "You" : "System",
            audioSource: audioSource,
            text: text,
            originalLanguage: detectedLanguage?.languageCode ?? activeLocaleIdentifier,
            transcriptionPhase: phase,
            transcriptionEngine: engine,
            engineConfidence: confidence,
            languageConfidence: detectedLanguage?.confidence,
            languageEvidenceSource: detectedLanguage == nil ? "requested-locale" : "text-language-detection",
            languageDetectionWindowMs: max(20, (endTime - startTime) * 1_000),
            languageSpanCodes: [detectedLanguage?.languageCode ?? activeLocaleIdentifier].compactMap { $0 },
            finalizedBy: isFinal ? engine : nil,
            latencyMs: max(0, nowOffset - finalizedThrough) * 1_000,
            sourceFrameRange: SpeechFrameRangeEstimator.range(startTime: startTime, endTime: endTime),
            wordTimestamps: attributedText.wordTimestamps(fallbackRange: range),
            alternatives: speechAnalyzerAlternatives(
                from: alternatives,
                primaryText: text,
                languageCode: detectedLanguage?.languageCode ?? activeLocaleIdentifier
            ),
            startTime: startTime,
            endTime: endTime,
            confidence: confidence,
            isFinal: isFinal
        )
        lastSegmentEmittedAt = Date()
        continuation?.yield(segment)
        AppLog.audio.info("SpeechAnalyzer emitted \(phase.rawValue, privacy: .public) segment backend=\(backend.displayName, privacy: .public) chars=\(text.count, privacy: .public)")
    }

    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                let now = Date()
                if self.watchdogPolicy.shouldRestart(
                    now: now,
                    lastSignificantAudioAt: self.lastSignificantAudioAt,
                    lastSegmentAt: self.lastSegmentEmittedAt,
                    lastRestartAt: self.lastWatchdogNudgeAt
                ) {
                    self.lastWatchdogNudgeAt = now
                    AppLog.audio.info("SpeechAnalyzer watchdog activating SFSpeech fallback after audio without transcript")
                    try? await self.analyzer?.finalize(through: nil)
                    self.activateSFSpeechFallback(reason: "audio without SpeechAnalyzer transcript")
                }
            }
        }
    }

    private func activateSFSpeechFallback(reason: String) {
        guard fallbackService == nil, fallbackActivationTask == nil, let activeConfig else { return }

        let fallbackService = AppleSpeechTranscriptionService(allowsAutomaticLanguageSwitching: allowsAutomaticLanguageSwitching)
        let fallbackSegments = fallbackService.segments
        var streamContinuation: AsyncStream<AudioBuffer>.Continuation?
        let fallbackStream = AsyncStream<AudioBuffer> { continuation in
            streamContinuation = continuation
        }
        let replayBuffers = fallbackPreRollBuffer.buffers

        self.fallbackService = fallbackService
        fallbackForwardingTask = Task { @MainActor [weak self] in
            for await segment in fallbackSegments {
                self?.lastSegmentEmittedAt = Date()
                self?.continuation?.yield(segment)
            }
        }

        fallbackActivationTask = Task { @MainActor [weak self, fallbackService, fallbackStream, activeConfig, replayBuffers] in
            guard let self else { return }
            do {
                try await fallbackService.startTranscription(audioStream: fallbackStream, config: activeConfig)
                for buffer in replayBuffers {
                    streamContinuation?.yield(buffer)
                }
                self.fallbackAudioContinuation = streamContinuation
                self.inputContinuation?.finish()
                self.inputContinuation = nil
                self.resultsTask?.cancel()
                self.resultsTask = nil
                self.analyzerTask?.cancel()
                self.analyzerTask = nil
                await self.analyzer?.cancelAndFinishNow()
                self.analyzer = nil
                self.transcriber = nil
                self.dictationTranscriber = nil
                AppLog.audio.info("SpeechAnalyzer switched to SFSpeech fallback: \(reason, privacy: .public)")
            } catch {
                AppLog.audio.error("SpeechAnalyzer SFSpeech fallback failed: \(error.localizedDescription, privacy: .public)")
                self.fallbackAudioContinuation?.finish()
                self.fallbackAudioContinuation = nil
                self.fallbackForwardingTask?.cancel()
                self.fallbackForwardingTask = nil
                self.fallbackService = nil
            }
            self.fallbackActivationTask = nil
        }
    }

    private func handleAnalyzerError(_ error: Error) {
        AppLog.audio.error("SpeechAnalyzer transcription failed: \(error.localizedDescription, privacy: .public)")
        guard !isStopping else { return }
        activateSFSpeechFallback(reason: error.localizedDescription)
    }

    private func reset(shouldFinishContinuation: Bool) async throws {
        isStopping = true
        watchdogTask?.cancel()
        watchdogTask = nil
        fallbackActivationTask?.cancel()
        fallbackActivationTask = nil
        fallbackForwardingTask?.cancel()
        fallbackForwardingTask = nil
        fallbackAudioContinuation?.finish()
        fallbackAudioContinuation = nil
        await fallbackService?.stop()
        fallbackService = nil
        fallbackPreRollBuffer.removeAll()
        audioPump?.cancel()
        audioPump = nil
        resultsTask?.cancel()
        resultsTask = nil
        speechDetectorTask?.cancel()
        speechDetectorTask = nil
        analyzerTask?.cancel()
        analyzerTask = nil
        inputContinuation?.finish()
        inputContinuation = nil
        await analyzer?.cancelAndFinishNow()
        analyzer = nil
        transcriber = nil
        dictationTranscriber = nil
        speechDetector = nil
        converter = nil
        activeConfig = nil
        activeSpeechContext = nil
        speechDetectionTimeline.reset()
        if shouldFinishContinuation {
            continuation?.finish()
            continuation = nil
        }
    }
}

enum SpeechDetectionCoverage: Sendable, Equatable {
    case unknown
    case speech
    case nonSpeech
}

struct SpeechDetectionTimeline: Sendable, Equatable {
    private struct Observation: Sendable, Equatable {
        var start: TimeInterval
        var end: TimeInterval
        var speechDetected: Bool
    }

    private var observations: [Observation] = []

    mutating func reset() {
        observations.removeAll()
    }

    mutating func record(range: CMTimeRange, speechDetected: Bool) {
        let start = Self.seconds(range.start)
        let end = Self.seconds(CMTimeRangeGetEnd(range))
        guard end > start else { return }
        observations.append(Observation(start: start, end: end, speechDetected: speechDetected))
        if observations.count > 256 {
            observations.removeFirst(observations.count - 256)
        }
    }

    func coverage(for range: CMTimeRange) -> SpeechDetectionCoverage {
        let start = Self.seconds(range.start)
        let end = Self.seconds(CMTimeRangeGetEnd(range))
        let duration = max(0, end - start)
        guard duration > 0.02 else { return .unknown }

        var speechOverlap: TimeInterval = 0
        var nonSpeechOverlap: TimeInterval = 0
        for observation in observations {
            let overlap = min(end, observation.end) - max(start, observation.start)
            guard overlap > 0 else { continue }
            if observation.speechDetected {
                speechOverlap += overlap
            } else {
                nonSpeechOverlap += overlap
            }
        }

        if speechOverlap >= min(0.08, duration * 0.20) || speechOverlap >= duration * 0.30 {
            return .speech
        }
        let covered = speechOverlap + nonSpeechOverlap
        if covered >= max(0.08, duration * 0.55), nonSpeechOverlap >= covered * 0.80 {
            return .nonSpeech
        }
        return .unknown
    }

    private static func seconds(_ time: CMTime) -> TimeInterval {
        guard time.isValid, !time.isIndefinite, !time.isNegativeInfinity, !time.isPositiveInfinity else { return 0 }
        let value = CMTimeGetSeconds(time)
        return value.isFinite ? max(0, value) : 0
    }
}

@available(macOS 26.0, *)
private extension CMTime {
    var safeSeconds: TimeInterval {
        guard isValid, !isIndefinite, !isNegativeInfinity, !isPositiveInfinity else { return 0 }
        let seconds = CMTimeGetSeconds(self)
        return seconds.isFinite ? max(0, seconds) : 0
    }
}

@available(macOS 26.0, *)
private extension AttributedString {
    var speechConfidenceAverage: Double? {
        let values = runs.compactMap(\.transcriptionConfidence)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    func wordTimestamps(fallbackRange: CMTimeRange) -> [TranscriptWordTimestamp] {
        runs.compactMap { run in
            let text = String(self[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let audioRange = run.audioTimeRange ?? fallbackRange
            let start = audioRange.start.safeSeconds
            let end = max(start, CMTimeRangeGetEnd(audioRange).safeSeconds)
            return TranscriptWordTimestamp(
                word: text,
                startTime: start,
                endTime: end,
                confidence: run.transcriptionConfidence
            )
        }
    }
}

@available(macOS 26.0, *)
private func speechAnalyzerAlternatives(
    from alternatives: [AttributedString],
    primaryText: String,
    languageCode: String?
) -> [TranscriptAlternative] {
    alternatives
        .compactMap { attributedText -> TranscriptAlternative? in
            let text = String(attributedText.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.caseInsensitiveCompare(primaryText) != .orderedSame else { return nil }
            return TranscriptAlternative(
                text: text,
                confidence: attributedText.speechConfidenceAverage,
                languageCode: languageCode,
                source: .speechAnalyzer
            )
        }
        .deduplicatedAlternatives(limit: 8)
}

@MainActor
final class AppleSpeechTranscriptionService: NSObject, TranscriptionService {
    private var continuation: AsyncStream<TranscriptSegment>.Continuation?
    private let requestBox = SpeechRequestBox()
    private let allowsAutomaticLanguageSwitching: Bool
    private var task: SFSpeechRecognitionTask?
    private var audioPump: Task<Void, Never>?
    private var windowRotationTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var languageSwitchTask: Task<Void, Never>?
    private var customModelPreparationTask: Task<Void, Never>?
    private var recognizer: SFSpeechRecognizer?
    private var activeConfig: TranscriptionConfig?
    private var activeSpeechContext: SpeechRecognitionContext?
    private var customLanguageModelConfiguration: SFSpeechLanguageModel.Configuration?
    private var activeLocaleIdentifier = SupportedLanguage.englishUS.rawValue
    private var pendingLocaleIdentifier: String?
    private var recognitionStartedAt = Date()
    private var activeWindowStartedAt = Date()
    private var activeWindowId = UUID()
    private var activeWindowOffset: TimeInterval = 0
    private var windowController = AppleSpeechWindowController()
    private var isStopping = false
    private var lastText = ""
    private var activeSegmentId = UUID()
    private var lastSegmentSnapshot: TranscriptSegment?
    private let recognitionWindowDuration: TimeInterval = 52
    private var latestAudioSource: TranscriptAudioSource = .unknown
    private var receivedAudioBuffers = 0
    private var recentMicLevel: Float = 0
    private var recentSystemLevel: Float = 0
    private var lastMicActivity = Date.distantPast
    private var lastSystemActivity = Date.distantPast
    private var lastSignificantAudioAt = Date.distantPast
    private var lastSegmentEmittedAt = Date.distantPast
    private var lastRestartAt = Date.distantPast
    private var recognitionParkedUntil = Date.distantPast
    private var noSpeechWithAudioCount = 0
    private var lastNoSpeechLanguageSwitchAt = Date.distantPast
    private let languageDetector = AppleLanguageDetectionService()
    private let restartPolicy = SpeechRestartPolicy()
    private let watchdogPolicy = SpeechRecognitionWatchdogPolicy()
    private let activityPolicy = SpeechActivityPolicy()
    private var preRollBuffer = SpeechPreRollBuffer(duration: 1.2)
    private var qualityMonitor = SpeechAudioQualityMonitor(source: .unknown)
    private var segmentAssembler = AppleSpeechSegmentAssembler()

    init(allowsAutomaticLanguageSwitching: Bool = true) {
        self.allowsAutomaticLanguageSwitching = allowsAutomaticLanguageSwitching
        super.init()
    }

    var segments: AsyncStream<TranscriptSegment> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func requestSpeechPermission() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            break
        @unknown default:
            return false
        }

        return await SpeechAuthorizationHelper.requestAuthorization() == .authorized
    }

    func startTranscription(audioStream: AsyncStream<AudioBuffer>, config: TranscriptionConfig) async throws {
        guard await requestSpeechPermission() else { throw TranscriptionError.speechPermissionDenied }

        guard let resolvedRecognizer = Self.availableRecognizer(preferredLanguage: config.languageCode) else {
            throw TranscriptionError.recognizerUnavailable
        }
        let locale = resolvedRecognizer.locale
        let recognizer = resolvedRecognizer.recognizer
        if config.requiresOnDeviceRecognition, !recognizer.supportsOnDeviceRecognition {
            throw TranscriptionError.recognizerUnavailable
        }

        stopRecognitionWindow(finalizePartial: false, clearRequest: true)
        self.recognizer = recognizer
        self.activeConfig = config
        self.activeLocaleIdentifier = locale.identifier
        self.recognitionStartedAt = Date()
        self.isStopping = false
        self.latestAudioSource = config.audioSource == .mixed ? .unknown : config.audioSource
        self.receivedAudioBuffers = 0
        self.recentMicLevel = 0
        self.recentSystemLevel = 0
        self.lastMicActivity = .distantPast
        self.lastSystemActivity = .distantPast
        self.lastSignificantAudioAt = .distantPast
        self.lastSegmentEmittedAt = .distantPast
        self.lastRestartAt = .distantPast
        self.activeWindowStartedAt = .distantPast
        self.windowController.reset()
        self.recognitionParkedUntil = .distantPast
        self.noSpeechWithAudioCount = 0
        self.lastNoSpeechLanguageSwitchAt = .distantPast
        self.pendingLocaleIdentifier = nil
        self.qualityMonitor = SpeechAudioQualityMonitor(source: config.audioSource)
        self.activeSpeechContext = config.speechContext ?? SpeechRecognitionContext(
            locale: config.languageCode,
            terms: config.contextualStrings.map {
                SpeechContextTerm(text: $0, locale: nil, category: .custom, weight: 1, pronunciationXSAMPA: nil, source: "legacy")
            },
            customLanguageModelEnabled: config.requiresOnDeviceRecognition,
            status: "Using contextual hints only"
        )
        self.customLanguageModelConfiguration = nil
        self.preRollBuffer.removeAll()
        self.segmentAssembler.reset()
        self.languageSwitchTask?.cancel()
        self.customModelPreparationTask?.cancel()
        AppLog.audio.info("Apple Speech armed locale=\(locale.identifier, privacy: .public) onDevice=\(config.requiresOnDeviceRecognition && recognizer.supportsOnDeviceRecognition, privacy: .public) source=\(config.audioSource.displayName, privacy: .public)")

        prepareCustomLanguageModelIfAvailable(languageCode: locale.identifier, supportsOnDeviceRecognition: recognizer.supportsOnDeviceRecognition)
        startRecognitionWindow(reason: .initial)

        let speechRequest = requestBox
        audioPump = Task {
            for await buffer in audioStream {
                guard !Task.isCancelled else { return }
                self.trackIncomingAudio(buffer)
                if let pcmBuffer = buffer.pcmBuffer {
                    speechRequest.append(pcmBuffer)
                }
                self.preRollBuffer.append(buffer)
            }
            speechRequest.endAudio()
        }
    }

    func stop() async {
        isStopping = true
        audioPump?.cancel()
        windowRotationTask?.cancel()
        restartTask?.cancel()
        languageSwitchTask?.cancel()
        customModelPreparationTask?.cancel()
        stopRecognitionWindow(finalizePartial: false, clearRequest: true)
        continuation?.finish()
        continuation = nil
        audioPump = nil
        languageSwitchTask = nil
        recognizer = nil
        activeConfig = nil
        activeSpeechContext = nil
        customLanguageModelConfiguration = nil
        pendingLocaleIdentifier = nil
    }

    static func supportsLanguage(_ language: SupportedLanguage) -> Bool {
        availableRecognizer(preferredLanguage: language.rawValue) != nil
    }

    fileprivate static func availableRecognizer(preferredLanguage: String?) -> (locale: Locale, recognizer: SFSpeechRecognizer)? {
        var identifiers = [SupportedLanguage.normalizedCode(preferredLanguage)]
        identifiers.append(SupportedLanguage.portugueseBR.rawValue)
        identifiers.append(SupportedLanguage.englishUS.rawValue)
        identifiers = Array(NSOrderedSet(array: identifiers)) as? [String] ?? identifiers

        for identifier in identifiers {
            let locale = Locale(identifier: identifier)
            if let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable {
                return (locale, recognizer)
            }
        }
        return nil
    }

    private func trackIncomingAudio(_ buffer: AudioBuffer) {
        receivedAudioBuffers += 1
        let now = Date()
        let qualitySnapshot = qualityMonitor.ingest(buffer)
        if qualitySnapshot.isClipping {
            AppLog.audio.info("Apple Speech audio clipping detected source=\(qualitySnapshot.source.displayName, privacy: .public)")
        }
        let speechActivity = activityPolicy.classify(qualitySnapshot).isSignificant
        if speechActivity {
            lastSignificantAudioAt = now
            if task == nil, recognizer != nil, activeConfig != nil, !isStopping {
                startRecognitionWindowFromAudioIfAllowed(now: now)
            } else if task != nil,
                      watchdogPolicy.shouldRestart(
                          now: now,
                          lastSignificantAudioAt: lastSignificantAudioAt,
                          lastSegmentAt: lastSegmentEmittedAt,
                          lastRestartAt: lastRestartAt
                      ) {
                AppLog.audio.info("Apple Speech watchdog restarting recognition window after audio without transcript")
                scheduleRestart(delay: .milliseconds(0), reason: .watchdogRestart)
            }
        }
        switch buffer.audioSource {
        case .microphone:
            recentMicLevel = max(buffer.rms, recentMicLevel * 0.86)
            if speechActivity {
                lastMicActivity = now
                latestAudioSource = .microphone
            }
        case .system:
            recentSystemLevel = max(buffer.rms, recentSystemLevel * 0.86)
            if speechActivity {
                lastSystemActivity = now
                latestAudioSource = .system
            }
        default:
            if speechActivity, buffer.audioSource != .unknown {
                latestAudioSource = buffer.audioSource
            }
        }
        if receivedAudioBuffers == 1 || receivedAudioBuffers == 60 {
            AppLog.audio.info("Apple Speech receiving audio buffers source=\(buffer.audioSource.displayName, privacy: .public) rms=\(buffer.rms, privacy: .public)")
        }
    }

    private func startRecognitionWindow(reason: AppleSpeechWindowStartReason) {
        guard let recognizer, let activeConfig else { return }
        let hasActiveDraft = lastSegmentSnapshot?.isFinal == false
        let windowStart = windowController.begin(
            reason: reason,
            now: Date(),
            preservesSegment: hasActiveDraft && reason != .languageSwitch
        )
        let request = AppleSpeechRequestFactory.make(
            config: activeConfig,
            supportsOnDeviceRecognition: recognizer.supportsOnDeviceRecognition,
            customLanguageModel: customLanguageModelConfiguration
        )
        let previousTask = task
        requestBox.replace(with: request)?.endAudio()
        previousTask?.cancel()

        let windowId = windowStart.id
        activeWindowId = windowId
        activeWindowStartedAt = windowStart.startedAt
        recognitionParkedUntil = .distantPast
        let replayStart = preRollBuffer.oldestCreatedAt ?? windowStart.startedAt
        activeWindowOffset = max(0, replayStart.timeIntervalSince(recognitionStartedAt))
        if !windowStart.preservesSegment {
            activeSegmentId = UUID()
            lastText = ""
            lastSegmentSnapshot = nil
            segmentAssembler.reset()
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                self?.handleRecognition(result: result, error: error, windowId: windowId)
            }
        }
        AppLog.audio.info("Apple Speech recognition window started locale=\(self.activeLocaleIdentifier, privacy: .public) reason=\(reason.rawValue, privacy: .public) preservesSegment=\(windowStart.preservesSegment, privacy: .public)")
        replayPreRoll(into: request)
        scheduleWindowRotation(windowId: windowId)
    }

    private func startRecognitionWindowFromAudioIfAllowed(now: Date) {
        guard windowController.canStartFromAudio(now: now), now >= recognitionParkedUntil else { return }
        startRecognitionWindow(reason: .audioActivity)
    }

    private func handleRecognition(result: SFSpeechRecognitionResult?, error: Error?, windowId: UUID) {
        guard windowId == activeWindowId else { return }
        if let result {
            noSpeechWithAudioCount = 0
            emit(result: result)
        }
        if let error, !isStopping {
            let description = error.localizedDescription
            let now = Date()
            let decision = restartPolicy.decision(
                errorDescription: description,
                now: now,
                lastSignificantAudioAt: lastSignificantAudioAt,
                lastRestartAt: lastRestartAt
            )
            if decision.shouldLogAsError {
                AppLog.audio.error("Apple Speech recognition error for \(self.activeConfig?.audioSource.displayName ?? "Audio", privacy: .public): \(description, privacy: .public)")
            } else {
                AppLog.audio.info("Apple Speech recognition event for \(self.activeConfig?.audioSource.displayName ?? "Audio", privacy: .public): \(description, privacy: .public)")
            }

            if description.localizedCaseInsensitiveContains("no speech") {
                scheduleLanguageFallbackIfNeeded(for: description, now: now)
            }

            if decision.shouldRestart {
                scheduleRestart(delay: .milliseconds(decision.delayMilliseconds), reason: .watchdogRestart)
            } else if decision.shouldParkUntilAudio {
                parkRecognitionUntilSignificantAudio()
            }
        }
    }

    private func emit(result: SFSpeechRecognitionResult) {
        let rawText = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = activeSpeechContext.map {
            AppleSpeechAlternativeRescorer().rescore(
                formattedString: rawText,
                segments: result.bestTranscription.segments,
                context: $0
            )
        } ?? rawText
        guard let activeConfig, !text.isEmpty, text != lastText else { return }
        lastText = text
        lastSegmentEmittedAt = Date()
        let first = result.bestTranscription.segments.first
        let last = result.bestTranscription.segments.last
        let audioSource = resolvedAudioSource(for: activeConfig)
        let detectedLanguage = languageDetector.detectedLanguage(for: text, minimumConfidence: 0.58)
        let startTime = activeWindowOffset + (first?.timestamp ?? 0)
        let endTime = activeWindowOffset + (last?.timestamp ?? 0) + (last?.duration ?? 0)
        let phase: TranscriptionPhase = result.isFinal ? .final : .draft
        let finalizedBy: TranscriptionEngineName? = result.isFinal ? .appleSpeech : nil
        let confidence = Double(last?.confidence ?? 0.7)
        let wordTimestamps = result.bestTranscription.segments.map { segment in
            TranscriptWordTimestamp(
                word: segment.substring,
                startTime: activeWindowOffset + segment.timestamp,
                endTime: activeWindowOffset + segment.timestamp + segment.duration,
                confidence: Double(segment.confidence)
            )
        }
        let alternatives = transcriptAlternatives(
            from: result,
            primaryText: text,
            languageCode: detectedLanguage?.languageCode
        )
        let segment = TranscriptSegment(
            id: activeSegmentId,
            meetingId: activeConfig.meetingId,
            speakerLabel: audioSource == .microphone ? "You" : "System",
            audioSource: audioSource,
            text: text,
            originalLanguage: detectedLanguage?.languageCode,
            transcriptionPhase: phase,
            transcriptionEngine: .appleSpeech,
            engineConfidence: confidence,
            languageConfidence: detectedLanguage?.confidence,
            languageEvidenceSource: detectedLanguage == nil ? "requested-locale" : "text-language-detection",
            languageDetectionWindowMs: max(20, (endTime - startTime) * 1_000),
            languageSpanCodes: [detectedLanguage?.languageCode ?? activeLocaleIdentifier].compactMap { $0 },
            finalizedBy: finalizedBy,
            sourceFrameRange: SpeechFrameRangeEstimator.range(startTime: startTime, endTime: endTime),
            wordTimestamps: wordTimestamps,
            alternatives: alternatives,
            startTime: startTime,
            endTime: endTime,
            confidence: confidence,
            isFinal: result.isFinal
        )
        guard let assembled = segmentAssembler.assemble(segment) else { return }
        lastSegmentSnapshot = assembled
        continuation?.yield(assembled)
        AppLog.audio.info("Apple Speech emitted \(phase.rawValue, privacy: .public) segment source=\(audioSource.displayName, privacy: .public) chars=\(text.count, privacy: .public) locale=\(self.activeLocaleIdentifier, privacy: .public)")
        if allowsAutomaticLanguageSwitching, let detectedLanguage {
            scheduleLanguageSwitchIfNeeded(detectedLanguage, text: text, isFinal: result.isFinal)
        }
        if result.isFinal {
            activeSegmentId = UUID()
            lastText = ""
            lastSegmentSnapshot = nil
            segmentAssembler.reset()
        }
    }

    private func transcriptAlternatives(
        from result: SFSpeechRecognitionResult,
        primaryText: String,
        languageCode: String?
    ) -> [TranscriptAlternative] {
        var alternatives: [TranscriptAlternative] = result.transcriptions
            .dropFirst()
            .compactMap { transcription in
                let text = transcription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, text.caseInsensitiveCompare(primaryText) != .orderedSame else { return nil }
                return TranscriptAlternative(
                    text: text,
                    confidence: Self.averageConfidence(in: transcription.segments),
                    languageCode: languageCode,
                    source: .transcription
                )
            }

        let mutablePrimary = NSMutableString(string: primaryText)
        for segment in result.bestTranscription.segments where segment.confidence < 0.88 {
            let range = segment.substringRange
            guard range.location != NSNotFound,
                  range.location >= 0,
                  range.location + range.length <= mutablePrimary.length else { continue }
            for alternative in segment.alternativeSubstrings.prefix(3) {
                let trimmedAlternative = alternative.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedAlternative.isEmpty,
                      trimmedAlternative.caseInsensitiveCompare(segment.substring) != .orderedSame else { continue }
                let candidate = mutablePrimary.mutableCopy() as? NSMutableString ?? NSMutableString(string: primaryText)
                candidate.replaceCharacters(in: range, with: trimmedAlternative)
                let text = String(candidate).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, text.caseInsensitiveCompare(primaryText) != .orderedSame else { continue }
                alternatives.append(TranscriptAlternative(
                    text: text,
                    confidence: max(0.05, Double(segment.confidence) - 0.08),
                    languageCode: languageCode,
                    source: .wordAlternative
                ))
            }
        }

        return alternatives.deduplicatedAlternatives(limit: 8)
    }

    private static func averageConfidence(in segments: [SFTranscriptionSegment]) -> Double? {
        guard !segments.isEmpty else { return nil }
        let total = segments.reduce(0.0) { partial, segment in partial + Double(segment.confidence) }
        return min(max(total / Double(segments.count), 0), 1)
    }

    private func scheduleLanguageSwitchIfNeeded(_ detection: LanguageDetectionResult, text: String, isFinal: Bool) {
        let targetIdentifier = detection.languageCode
        let minimumSwitchLength = activeConfig?.commitPolicy == .accurate ? 24 : 18
        guard targetIdentifier != SupportedLanguage.normalizedCode(activeLocaleIdentifier),
              detection.confidence >= 0.68,
              isFinal || text.count >= minimumSwitchLength,
              Self.availableRecognizer(preferredLanguage: targetIdentifier) != nil,
              pendingLocaleIdentifier != targetIdentifier else { return }

        pendingLocaleIdentifier = targetIdentifier
        languageSwitchTask?.cancel()
        let delay: Duration = isFinal ? .milliseconds(220) : .milliseconds(1400)
        languageSwitchTask = Task { [weak self, targetIdentifier, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.switchRecognitionLanguage(to: targetIdentifier)
        }
    }

    private func scheduleLanguageFallbackIfNeeded(for errorDescription: String, now: Date) {
        guard allowsAutomaticLanguageSwitching else { return }
        guard errorDescription.localizedCaseInsensitiveContains("no speech") else { return }
        guard now.timeIntervalSince(lastSignificantAudioAt) <= 1.4 else {
            noSpeechWithAudioCount = 0
            return
        }
        noSpeechWithAudioCount += 1
        guard noSpeechWithAudioCount >= 3,
              now.timeIntervalSince(lastNoSpeechLanguageSwitchAt) >= 4,
              let alternateIdentifier = alternateRecognitionLanguageIdentifier() else { return }

        lastNoSpeechLanguageSwitchAt = now
        noSpeechWithAudioCount = 0
        pendingLocaleIdentifier = alternateIdentifier
        languageSwitchTask?.cancel()
        languageSwitchTask = Task { [weak self, alternateIdentifier] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            self?.switchRecognitionLanguage(to: alternateIdentifier, startImmediately: false)
        }
    }

    private func alternateRecognitionLanguageIdentifier() -> String? {
        let current = SupportedLanguage.normalizedCode(activeLocaleIdentifier)
        if let hinted = activeConfig?.preferredLanguageHints.first(where: { identifier in
            let normalized = SupportedLanguage.normalizedCode(identifier)
            return normalized != current && Self.availableRecognizer(preferredLanguage: normalized) != nil
        }) {
            return SupportedLanguage.normalizedCode(hinted)
        }

        let candidates: [SupportedLanguage]
        switch SupportedLanguage.language(for: current) {
        case .portugueseBR:
            candidates = [.englishUS, .spanishES, .japaneseJP]
        case .englishUS:
            candidates = [.portugueseBR, .spanishES, .japaneseJP]
        case .spanishES:
            candidates = [.portugueseBR, .englishUS, .japaneseJP]
        case .japaneseJP:
            candidates = [.englishUS, .portugueseBR, .spanishES]
        case .none:
            candidates = [.portugueseBR, .englishUS, .spanishES, .japaneseJP]
        }
        return candidates
            .map(\.rawValue)
            .first { identifier in
                identifier != current && Self.availableRecognizer(preferredLanguage: identifier) != nil
            }
    }

    private func switchRecognitionLanguage(to identifier: String, startImmediately: Bool = true) {
        pendingLocaleIdentifier = nil
        guard let resolvedRecognizer = Self.availableRecognizer(preferredLanguage: identifier) else { return }
        let newIdentifier = SupportedLanguage.normalizedCode(resolvedRecognizer.locale.identifier)
        guard newIdentifier != SupportedLanguage.normalizedCode(activeLocaleIdentifier) else { return }
        if activeConfig?.requiresOnDeviceRecognition == true,
           !resolvedRecognizer.recognizer.supportsOnDeviceRecognition {
            return
        }

        AppLog.audio.info("Switching Apple Speech recognizer to \(newIdentifier, privacy: .public)")
        recognizer = resolvedRecognizer.recognizer
        activeLocaleIdentifier = resolvedRecognizer.locale.identifier
        activeConfig?.languageCode = newIdentifier
        activeSpeechContext?.locale = newIdentifier
        customLanguageModelConfiguration = nil
        prepareCustomLanguageModelIfAvailable(
            languageCode: newIdentifier,
            supportsOnDeviceRecognition: resolvedRecognizer.recognizer.supportsOnDeviceRecognition
        )
        noSpeechWithAudioCount = 0
        if startImmediately {
            startRecognitionWindow(reason: .languageSwitch)
        } else {
            task?.cancel()
            requestBox.clear()?.endAudio()
            task = nil
            activeWindowStartedAt = .distantPast
            recognitionParkedUntil = Date().addingTimeInterval(0.2)
        }
    }

    private func resolvedAudioSource(for config: TranscriptionConfig) -> TranscriptAudioSource {
        guard config.audioSource == .mixed else { return config.audioSource }
        let now = Date()
        let systemIsRecent = now.timeIntervalSince(lastSystemActivity) < 1.4
        let micIsRecent = now.timeIntervalSince(lastMicActivity) < 1.4
        if systemIsRecent, (!micIsRecent || recentSystemLevel >= recentMicLevel * 0.18 || recentSystemLevel > 0.012) {
            return .system
        }
        if micIsRecent {
            return .microphone
        }
        if latestAudioSource == .microphone || latestAudioSource == .system {
            return latestAudioSource
        }
        return .mixed
    }

    private func finalizeActiveSegment() {
        guard var segment = lastSegmentSnapshot, !segment.isFinal else { return }
        segment.isFinal = true
        segment.transcriptionPhase = .final
        segment.finalizedBy = .appleSpeech
        continuation?.yield(segment)
        activeSegmentId = UUID()
        lastText = ""
        lastSegmentSnapshot = nil
    }

    private func scheduleWindowRotation(windowId: UUID) {
        windowRotationTask?.cancel()
        windowRotationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.recognitionWindowDuration ?? 52))
            await MainActor.run {
                guard let self, !self.isStopping, self.activeWindowId == windowId else { return }
                self.startRecognitionWindow(reason: .scheduledRotation)
            }
        }
    }

    private func scheduleRestart(delay: Duration, reason: AppleSpeechWindowStartReason) {
        let now = Date()
        guard now.timeIntervalSince(lastRestartAt) > 0.9 else { return }
        lastRestartAt = now
        restartTask?.cancel()
        restartTask = Task { [weak self, delay, reason] in
            try? await Task.sleep(for: delay)
            await MainActor.run {
                guard let self, !self.isStopping else { return }
                self.startRecognitionWindow(reason: reason)
            }
        }
    }

    private func parkRecognitionUntilSignificantAudio() {
        windowRotationTask?.cancel()
        restartTask?.cancel()
        task?.cancel()
        requestBox.clear()?.endAudio()
        task = nil
        let until = Date().addingTimeInterval(windowController.startCooldown)
        recognitionParkedUntil = until
        windowController.park(until: until)
    }

    private func stopRecognitionWindow(finalizePartial: Bool, clearRequest: Bool) {
        if finalizePartial {
            finalizeActiveSegment()
        }
        windowRotationTask?.cancel()
        restartTask?.cancel()
        task?.cancel()
        if clearRequest {
            requestBox.clear()?.endAudio()
        } else {
            requestBox.current()?.endAudio()
        }
        task = nil
    }

    private func replayPreRoll(into request: SFSpeechAudioBufferRecognitionRequest) {
        let appender = SpeechAudioBufferRequestAppender(request: request)
        for buffer in preRollBuffer.buffers {
            guard let pcmBuffer = buffer.pcmBuffer else { continue }
            appender.append(pcmBuffer)
        }
    }

    private func prepareCustomLanguageModelIfAvailable(languageCode: String, supportsOnDeviceRecognition: Bool) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        guard supportsOnDeviceRecognition, let activeSpeechContext, activeSpeechContext.customLanguageModelEnabled else { return }
        let context = activeSpeechContext
        customModelPreparationTask?.cancel()
        customModelPreparationTask = Task { @MainActor [weak self, context, languageCode] in
            guard let self else { return }
            let configuration = await AppleCustomLanguageModelManager.shared.configuration(
                for: context,
                languageCode: languageCode
            )
            guard !Task.isCancelled else { return }
            self.customLanguageModelConfiguration = configuration
            if configuration != nil {
                AppLog.audio.info("Apple Speech custom vocabulary model active locale=\(languageCode, privacy: .public) terms=\(context.activeTermsForLanguageModel.count, privacy: .public)")
            }
        }
    }
}

enum AppleSpeechRequestFactory {
    static func make(
        config: TranscriptionConfig,
        supportsOnDeviceRecognition: Bool,
        customLanguageModel: SFSpeechLanguageModel.Configuration? = nil
    ) -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.contextualStrings = config.speechContext?.contextualStrings ?? SpeechContextRanker().rank(config.contextualStrings)
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }
        if let customLanguageModel, supportsOnDeviceRecognition {
            request.customizedLanguageModel = customLanguageModel
            request.requiresOnDeviceRecognition = true
        } else if config.requiresOnDeviceRecognition, supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        return request
    }
}

enum SpeechFrameRangeEstimator {
    static let appleSpeechFrameRate = 16_000.0

    static func range(
        startTime: TimeInterval,
        endTime: TimeInterval,
        sampleRate: Double = appleSpeechFrameRate
    ) -> AudioSourceFrameRange? {
        guard startTime.isFinite, endTime.isFinite, sampleRate.isFinite, sampleRate > 0 else { return nil }
        let normalizedStart = max(0, startTime)
        let normalizedEnd = max(normalizedStart, endTime)
        let start = Int64((normalizedStart * sampleRate).rounded(.down))
        let end = max(start + 1, Int64((normalizedEnd * sampleRate).rounded(.up)))
        return AudioSourceFrameRange(start: start, end: end)
    }
}

struct SpeechRestartDecision: Equatable {
    var shouldRestart: Bool
    var delayMilliseconds: Int
    var shouldParkUntilAudio: Bool
    var shouldLogAsError: Bool

    static let ignore = SpeechRestartDecision(shouldRestart: false, delayMilliseconds: 0, shouldParkUntilAudio: false, shouldLogAsError: false)
}

struct SpeechRestartPolicy {
    var recentAudioWindow: TimeInterval = 2.5
    var minimumRestartInterval: TimeInterval = 1.2

    func decision(
        errorDescription: String,
        now: Date,
        lastSignificantAudioAt: Date,
        lastRestartAt: Date
    ) -> SpeechRestartDecision {
        let normalized = errorDescription.lowercased()
        if normalized.contains("canceled") || normalized.contains("cancelled") {
            return .ignore
        }

        let restartAllowed = now.timeIntervalSince(lastRestartAt) >= minimumRestartInterval

        if normalized.contains("no speech") {
            if now.timeIntervalSince(lastSignificantAudioAt) <= recentAudioWindow, restartAllowed {
                return SpeechRestartDecision(
                    shouldRestart: true,
                    delayMilliseconds: 0,
                    shouldParkUntilAudio: false,
                    shouldLogAsError: false
                )
            }
            return SpeechRestartDecision(
                shouldRestart: false,
                delayMilliseconds: 0,
                shouldParkUntilAudio: true,
                shouldLogAsError: false
            )
        }

        guard restartAllowed else {
            return SpeechRestartDecision(
                shouldRestart: false,
                delayMilliseconds: 0,
                shouldParkUntilAudio: false,
                shouldLogAsError: true
            )
        }

        return SpeechRestartDecision(
            shouldRestart: true,
            delayMilliseconds: 750,
            shouldParkUntilAudio: false,
            shouldLogAsError: true
        )
    }
}

@MainActor
final class MultiSourceAppleSpeechTranscriptionService: TranscriptionService {
    struct Source: Sendable {
        var speakerLabel: String
        var audioSource: TranscriptAudioSource
        var audioStream: AsyncStream<AudioBuffer>
    }

    private let sources: [Source]
    private var services: [any TranscriptionService] = []
    private var forwardingTasks: [Task<Void, Never>] = []
    private var continuation: AsyncStream<TranscriptSegment>.Continuation?

    init(sources: [Source]) {
        self.sources = sources
    }

    var segments: AsyncStream<TranscriptSegment> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func startTranscription(audioStream: AsyncStream<AudioBuffer>, config: TranscriptionConfig) async throws {
        guard !sources.isEmpty else { throw TranscriptionError.recognizerUnavailable }
        services = []
        forwardingTasks = []

        do {
            for source in sources {
                let service = AppleNativeTranscriptionService(allowsAutomaticLanguageSwitching: false)
                let segmentStream = service.segments
                forwardingTasks.append(Task { @MainActor [weak self, speakerLabel = source.speakerLabel, audioSource = source.audioSource] in
                    for await segment in segmentStream {
                        self?.continuation?.yield(Self.relabeled(segment, speakerLabel: speakerLabel, audioSource: audioSource))
                    }
                })
                var sourceConfig = config
                sourceConfig.audioSource = source.audioSource
                try await service.startTranscription(audioStream: source.audioStream, config: sourceConfig)
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
        for task in forwardingTasks {
            task.cancel()
        }
        forwardingTasks = []
        continuation?.finish()
        continuation = nil
    }

    static func relabeled(_ segment: TranscriptSegment, speakerLabel: String, audioSource: TranscriptAudioSource) -> TranscriptSegment {
        var labeledSegment = segment
        labeledSegment.speakerLabel = speakerLabel
        labeledSegment.audioSource = audioSource
        return labeledSegment
    }
}

@MainActor
final class MultiSourceAutoLanguageTranscriptionService: TranscriptionService {
    struct Source: Sendable {
        var speakerLabel: String
        var audioSource: TranscriptAudioSource
        var audioStream: AsyncStream<AudioBuffer>
    }

    private let sources: [Source]
    private var services: [any TranscriptionService] = []
    private var forwardingTasks: [Task<Void, Never>] = []
    private var continuation: AsyncStream<TranscriptSegment>.Continuation?

    init(sources: [Source]) {
        self.sources = sources
    }

    var segments: AsyncStream<TranscriptSegment> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func startTranscription(audioStream: AsyncStream<AudioBuffer>, config: TranscriptionConfig) async throws {
        guard !sources.isEmpty else { throw TranscriptionError.recognizerUnavailable }
        services = []
        forwardingTasks = []

        do {
            for source in sources {
                let service = AppleNativeTranscriptionService(allowsAutomaticLanguageSwitching: true)
                let segmentStream = service.segments
                forwardingTasks.append(Task { @MainActor [weak self, speakerLabel = source.speakerLabel, audioSource = source.audioSource] in
                    for await segment in segmentStream {
                        self?.continuation?.yield(Self.relabeled(segment, speakerLabel: speakerLabel, audioSource: audioSource))
                    }
                })
                var sourceConfig = config
                sourceConfig.audioSource = source.audioSource
                try await service.startTranscription(audioStream: source.audioStream, config: sourceConfig)
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
        continuation?.finish()
        continuation = nil
    }

    static func relabeled(_ segment: TranscriptSegment, speakerLabel: String, audioSource: TranscriptAudioSource) -> TranscriptSegment {
        var labeledSegment = segment
        labeledSegment.speakerLabel = speakerLabel
        labeledSegment.audioSource = audioSource
        return labeledSegment
    }
}

@MainActor
final class AutoLanguageAppleSpeechTranscriptionService: TranscriptionService {
    private var continuation: AsyncStream<TranscriptSegment>.Continuation?
    private var services: [SupportedLanguage: AppleSpeechTranscriptionService] = [:]
    private var inputContinuations: [SupportedLanguage: AsyncStream<AudioBuffer>.Continuation] = [:]
    private var forwardingTasks: [Task<Void, Never>] = []
    private var fanoutTask: Task<Void, Never>?
    private var emitTasks: [AutoLanguageTranscriptKey: Task<Void, Never>] = [:]
    private var cleanupTasks: [AutoLanguageTranscriptKey: Task<Void, Never>] = [:]
    private var candidatesByKey: [AutoLanguageTranscriptKey: [SupportedLanguage: AutoLanguageTranscriptCandidate]] = [:]
    private var outputIdsByKey: [AutoLanguageTranscriptKey: UUID] = [:]
    private let selector = AutoLanguageTranscriptSelector()

    var segments: AsyncStream<TranscriptSegment> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func startTranscription(audioStream: AsyncStream<AudioBuffer>, config: TranscriptionConfig) async throws {
        await resetRecognitionState()

        let languages = SupportedLanguage.allCases.filter { AppleSpeechTranscriptionService.supportsLanguage($0) }
        guard !languages.isEmpty else { throw TranscriptionError.recognizerUnavailable }

        do {
            for language in languages {
                let childStream = AsyncStream<AudioBuffer> { childContinuation in
                    inputContinuations[language] = childContinuation
                }
                let service = AppleSpeechTranscriptionService(allowsAutomaticLanguageSwitching: false)
                var languageConfig = config
                languageConfig.languageCode = language.rawValue
                services[language] = service
                observe(service: service, language: language)
                try await service.startTranscription(audioStream: childStream, config: languageConfig)
            }
        } catch {
            await resetRecognitionState()
            throw error
        }

        fanoutTask = Task { [weak self] in
            for await buffer in audioStream {
                guard !Task.isCancelled else { return }
                self?.broadcast(buffer)
            }
            self?.finishInputs()
        }
    }

    func stop() async {
        await resetRecognitionState()
        continuation?.finish()
        continuation = nil
    }

    private func resetRecognitionState() async {
        fanoutTask?.cancel()
        fanoutTask = nil
        emitTasks.values.forEach { $0.cancel() }
        emitTasks = [:]
        cleanupTasks.values.forEach { $0.cancel() }
        cleanupTasks = [:]
        forwardingTasks.forEach { $0.cancel() }
        forwardingTasks = []
        finishInputs()
        inputContinuations = [:]
        for service in services.values {
            await service.stop()
        }
        services = [:]
        candidatesByKey = [:]
        outputIdsByKey = [:]
    }

    private func observe(service: AppleSpeechTranscriptionService, language: SupportedLanguage) {
        let segmentStream = service.segments
        forwardingTasks.append(Task { [weak self, language] in
            for await segment in segmentStream {
                self?.receive(segment, language: language)
            }
        })
    }

    private func broadcast(_ buffer: AudioBuffer) {
        for continuation in inputContinuations.values {
            continuation.yield(buffer.copiedForLanguageFanout())
        }
    }

    private func finishInputs() {
        inputContinuations.values.forEach { $0.finish() }
    }

    private func receive(_ segment: TranscriptSegment, language: SupportedLanguage) {
        guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let key = AutoLanguageTranscriptKey(segment: segment)
        let candidate = AutoLanguageTranscriptCandidate(language: language, segment: segment)
        candidatesByKey[key, default: [:]][language] = candidate
        scheduleEmission(for: key, isFinal: segment.isFinal)
    }

    private func scheduleEmission(for key: AutoLanguageTranscriptKey, isFinal: Bool) {
        emitTasks[key]?.cancel()
        let delay: Duration = isFinal ? .milliseconds(90) : .milliseconds(220)
        emitTasks[key] = Task { [weak self, key, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.emitBestCandidate(for: key)
        }
    }

    private func emitBestCandidate(for key: AutoLanguageTranscriptKey) {
        emitTasks[key] = nil
        guard let candidates = candidatesByKey[key]?.values, let best = selector.bestCandidate(from: Array(candidates)) else { return }
        let outputId = outputIdsByKey[key] ?? UUID()
        outputIdsByKey[key] = outputId

        var segment = best.segment
        segment.id = outputId
        segment.originalLanguage = selector.resolvedLanguage(for: best).rawValue
        segment.translatedText = nil
        continuation?.yield(segment)

        if segment.isFinal {
            scheduleCleanup(for: key)
        }
    }

    private func scheduleCleanup(for key: AutoLanguageTranscriptKey) {
        cleanupTasks[key]?.cancel()
        cleanupTasks[key] = Task { [weak self, key] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.cleanup(key: key)
        }
    }

    private func cleanup(key: AutoLanguageTranscriptKey) {
        cleanupTasks[key] = nil
        candidatesByKey[key] = nil
        outputIdsByKey[key] = nil
    }
}

struct AutoLanguageTranscriptCandidate: Equatable {
    var language: SupportedLanguage
    var segment: TranscriptSegment
}

struct AutoLanguageTranscriptSelector {
    private let detector = AppleLanguageDetectionService()

    func bestCandidate(from candidates: [AutoLanguageTranscriptCandidate]) -> AutoLanguageTranscriptCandidate? {
        candidates.max { score($0) < score($1) }
    }

    func resolvedLanguage(for candidate: AutoLanguageTranscriptCandidate) -> SupportedLanguage {
        if let detection = detector.detectedLanguage(for: candidate.segment.text, minimumConfidence: 0.34),
           let language = SupportedLanguage.language(for: detection.languageCode) {
            return language
        }
        if let language = SupportedLanguage.language(for: candidate.segment.originalLanguage) {
            return language
        }
        return candidate.language
    }

    func score(_ candidate: AutoLanguageTranscriptCandidate) -> Double {
        let text = candidate.segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return -.infinity }

        var score = min(max(candidate.segment.confidence, 0), 1) * 0.52
        score += min(Double(text.count) / 90, 1) * 0.06
        if candidate.segment.isFinal {
            score += 0.04
        }

        if let detection = detector.detectedLanguage(for: text, minimumConfidence: 0.18) {
            if detection.languageCode == candidate.language.rawValue {
                score += 0.38 * detection.confidence
            } else {
                score -= 0.48 * detection.confidence
            }
        } else {
            score -= 0.04
        }

        return score
    }
}

private struct AutoLanguageTranscriptKey: Hashable {
    var audioSource: TranscriptAudioSource
    var bucket: Int

    init(segment: TranscriptSegment) {
        audioSource = segment.audioSource
        bucket = max(0, Int((segment.startTime / 4).rounded(.down)))
    }
}

private extension AudioBuffer {
    func copiedForLanguageFanout() -> AudioBuffer {
        AudioBuffer(
            pcmBuffer: pcmBuffer?.copiedForAsyncUse(),
            time: time,
            mediaTime: mediaTime,
            rms: rms,
            peak: peak,
            createdAt: createdAt,
            audioSource: audioSource
        )
    }
}

private extension Array where Element == TranscriptAlternative {
    func deduplicatedAlternatives(limit: Int) -> [TranscriptAlternative] {
        var seen = Set<String>()
        var result: [TranscriptAlternative] = []
        for alternative in self {
            let key = QuestionDetectionService.normalize(alternative.text)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(alternative)
            if result.count >= limit { break }
        }
        return result
    }
}

struct SpeechPreRollBuffer {
    var duration: TimeInterval
    private(set) var buffers: [AudioBuffer] = []
    var oldestCreatedAt: Date? { buffers.first?.createdAt }

    mutating func append(_ buffer: AudioBuffer) {
        guard buffer.pcmBuffer != nil else { return }
        buffers.append(AudioBuffer(
            pcmBuffer: buffer.pcmBuffer?.copiedForAsyncUse(),
            time: buffer.time,
            mediaTime: buffer.mediaTime,
            rms: buffer.rms,
            peak: buffer.peak,
            createdAt: buffer.createdAt,
            audioSource: buffer.audioSource
        ))
        trim()
    }

    mutating func removeAll() {
        buffers.removeAll()
    }

    private mutating func trim() {
        let referenceDate = buffers.map(\.createdAt).max() ?? Date()
        let cutoff = referenceDate.addingTimeInterval(-duration)
        buffers.removeAll { $0.createdAt < cutoff }
        if buffers.count > 120 {
            buffers.removeFirst(buffers.count - 120)
        }
    }
}

enum SpeechAudioBufferAppender {
    static func append(_ buffer: AVAudioPCMBuffer, to request: SFSpeechAudioBufferRecognitionRequest) {
        SpeechAudioBufferRequestAppender(request: request).append(buffer)
    }

    fileprivate static func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.sampleRate == rhs.sampleRate &&
            lhs.channelCount == rhs.channelCount &&
            lhs.commonFormat == rhs.commonFormat &&
            lhs.isInterleaved == rhs.isInterleaved
    }
}

final class SpeechAudioBufferRequestAppender: @unchecked Sendable {
    private let request: SFSpeechAudioBufferRecognitionRequest
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private let lock = NSLock()

    init(request: SFSpeechAudioBufferRecognitionRequest) {
        self.request = request
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let outputFormat = request.nativeAudioFormat
        let converted = convertLocked(buffer, to: outputFormat)
        lock.unlock()
        request.append(converted ?? buffer)
    }

    private func convertLocked(_ buffer: AVAudioPCMBuffer, to outputFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let inputFormat = buffer.format
        if SpeechAudioBufferAppender.formatsMatch(inputFormat, outputFormat) {
            return buffer
        }

        if converter == nil || converterInputFormat.map({ !SpeechAudioBufferAppender.formatsMatch($0, inputFormat) }) == true {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            converterInputFormat = inputFormat
        }
        guard let converter else { return nil }
        let ratio = outputFormat.sampleRate / max(inputFormat.sampleRate, 1)
        let frameCapacity = AVAudioFrameCount(max(1, Int((Double(buffer.frameLength) * ratio).rounded(.up)) + 8))
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else { return nil }

        let state = SpeechConverterInputState(buffer: buffer)
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, outStatus in
            if state.didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            state.didProvideInput = true
            outStatus.pointee = .haveData
            return state.buffer
        }
        return error == nil ? converted : nil
    }
}

final class SpeechAnalyzerBufferConverter: @unchecked Sendable {
    private let outputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private let lock = NSLock()

    init(outputFormat: AVAudioFormat?) {
        self.outputFormat = outputFormat
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let outputFormat else { return buffer }
        lock.lock()
        let converted = convertLocked(buffer, to: outputFormat)
        lock.unlock()
        return converted ?? buffer
    }

    private func convertLocked(_ buffer: AVAudioPCMBuffer, to outputFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let inputFormat = buffer.format
        if SpeechAudioBufferAppender.formatsMatch(inputFormat, outputFormat) {
            return buffer
        }

        if converter == nil || converterInputFormat.map({ !SpeechAudioBufferAppender.formatsMatch($0, inputFormat) }) == true {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            converterInputFormat = inputFormat
        }
        guard let converter else { return nil }
        let ratio = outputFormat.sampleRate / max(inputFormat.sampleRate, 1)
        let frameCapacity = AVAudioFrameCount(max(1, Int((Double(buffer.frameLength) * ratio).rounded(.up)) + 8))
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else { return nil }

        let state = SpeechConverterInputState(buffer: buffer)
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, outStatus in
            if state.didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            state.didProvideInput = true
            outStatus.pointee = .haveData
            return state.buffer
        }
        return error == nil ? converted : nil
    }
}

private final class SpeechConverterInputState: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var didProvideInput = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

private final class SpeechRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var appender: SpeechAudioBufferRequestAppender?

    init(_ request: SFSpeechAudioBufferRecognitionRequest? = nil) {
        self.request = request
    }

    func replace(with request: SFSpeechAudioBufferRecognitionRequest) -> SFSpeechAudioBufferRecognitionRequest? {
        lock.lock()
        let previous = self.request
        self.request = request
        self.appender = SpeechAudioBufferRequestAppender(request: request)
        lock.unlock()
        return previous
    }

    func current() -> SFSpeechAudioBufferRecognitionRequest? {
        lock.lock()
        let request = request
        lock.unlock()
        return request
    }

    func clear() -> SFSpeechAudioBufferRecognitionRequest? {
        lock.lock()
        let previous = request
        request = nil
        appender = nil
        lock.unlock()
        return previous
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let appender = appender
        lock.unlock()
        appender?.append(buffer)
    }

    func endAudio() {
        current()?.endAudio()
    }
}
