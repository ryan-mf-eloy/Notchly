import AVFoundation
import CryptoKit
import Speech
import XCTest
@testable import NotchCopilot

private enum CaptureHarnessOptIn {
    enum Harness {
        case microphone
        case systemAudio
        case whisperKitRefiner
        case appleSpeechASR

        var environmentKey: String {
            switch self {
            case .microphone: "RUN_MICROPHONE_CAPTURE_HARNESS"
            case .systemAudio: "RUN_SYSTEM_AUDIO_CAPTURE_HARNESS"
            case .whisperKitRefiner: "RUN_WHISPERKIT_REFINER_HARNESS"
            case .appleSpeechASR: "RUN_APPLE_SPEECH_ASR_HARNESS"
            }
        }

        var markerPath: String {
            switch self {
            case .microphone: "/private/tmp/notchly-run-microphone-capture-harness"
            case .systemAudio: "/private/tmp/notchly-run-system-audio-capture-harness"
            case .whisperKitRefiner: "/private/tmp/notchly-run-whisperkit-refiner-harness"
            case .appleSpeechASR: "/private/tmp/notchly-run-apple-speech-asr-harness"
            }
        }
    }

    static func isEnabled(_ harness: Harness) -> Bool {
        let environmentValue = ProcessInfo.processInfo.environment[harness.environmentKey]?.lowercased()
        return environmentValue == "1" ||
            environmentValue == "true" ||
            FileManager.default.fileExists(atPath: harness.markerPath)
    }

    static func skipMessage(for harness: Harness) -> String {
        "Set \(harness.environmentKey)=1 in the test scheme or create \(harness.markerPath) before running this real capture harness."
    }
}

private struct GeneratedSpeechASRBenchmarkSpec {
    var id: String
    var locale: String
    var voice: String
    var reference: String
    var baselineHypothesis: String
    var vocabulary: [String]
    var namedEntities: [String]
    var tags: [TranscriptionEvaluationTag]
}

private struct GeneratedSpeechASRBenchmarkAttempt: Codable, Hashable {
    var id: String
    var locale: String
    var voice: String
    var accepted: Bool
    var reason: String
    var hypothesis: String?
}

private struct GeneratedSpeechASRBenchmarkReport: Codable, Hashable {
    var runID: String
    var model: String
    var generatedAt: String
    var attempts: [GeneratedSpeechASRBenchmarkAttempt]
    var baselineCases: [TranscriptionBenchmarkCase]
    var refinedCases: [TranscriptionBenchmarkCase]
    var baselineSummary: TranscriptionBenchmarkSummary
    var refinedSummary: TranscriptionBenchmarkSummary
}

@MainActor
private final class ScriptedReplayTranscriptionService: TranscriptionService {
    private let plannedSegments: [TranscriptSegment]
    private var continuation: AsyncStream<TranscriptSegment>.Continuation?
    private var emissionTask: Task<Void, Never>?
    private(set) var consumedBufferCount = 0

    init(plannedSegments: [TranscriptSegment]) {
        self.plannedSegments = plannedSegments
    }

    var segments: AsyncStream<TranscriptSegment> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func startTranscription(audioStream: AsyncStream<NotchCopilot.AudioBuffer>, config: TranscriptionConfig) async throws {
        emissionTask?.cancel()
        emissionTask = Task { @MainActor in
            var sawAudio = false
            for await _ in audioStream {
                if Task.isCancelled { break }
                sawAudio = true
                consumedBufferCount += 1
            }
            guard sawAudio, !Task.isCancelled else {
                continuation?.finish()
                return
            }
            for segment in plannedSegments {
                if Task.isCancelled { break }
                var emitted = segment
                emitted.meetingId = config.meetingId
                emitted.audioSource = config.audioSource
                emitted.originalLanguage = emitted.originalLanguage ?? config.languageCode
                emitted.sourceLanguage = emitted.sourceLanguage ?? config.languageCode
                emitted.createdAt = Date()
                continuation?.yield(emitted)
            }
            continuation?.finish()
        }
    }

    func stop() async {
        emissionTask?.cancel()
        emissionTask = nil
        continuation?.finish()
    }
}

@MainActor
final class TranscriptionPipelineTests: XCTestCase {
    func testMicrophoneCaptureHarnessProducesSourceTaggedBuffersWhenOptedIn() async throws {
        guard CaptureHarnessOptIn.isEnabled(.microphone) else {
            throw XCTSkip(CaptureHarnessOptIn.skipMessage(for: .microphone))
        }

        let service = AppleMicrophoneCaptureService()
        guard await service.requestPermission() else {
            throw XCTSkip("Microphone permission is required for RUN_MICROPHONE_CAPTURE_HARNESS=1.")
        }
        let stream = try await service.startCapture()
        defer { service.stopCapture() }

        let buffers = await Self.collectBuffers(from: stream, minimumCount: 3, timeoutNanoseconds: 3_000_000_000)
        XCTAssertGreaterThanOrEqual(buffers.count, 3)
        XCTAssertTrue(buffers.allSatisfy { $0.audioSource == .microphone })
        XCTAssertTrue(buffers.allSatisfy { ($0.pcmBuffer?.frameLength ?? 0) > 0 })
        XCTAssertTrue(buffers.allSatisfy { ($0.pcmBuffer?.format.sampleRate ?? 0) > 0 })
        XCTAssertTrue(buffers.allSatisfy { $0.rms >= 0 && $0.peak >= 0 })
    }

    func testSystemAudioCaptureHarnessProducesSourceTaggedBuffersWhenOptedIn() async throws {
        guard CaptureHarnessOptIn.isEnabled(.systemAudio) else {
            throw XCTSkip(CaptureHarnessOptIn.skipMessage(for: .systemAudio))
        }

        let service = AppleSystemAudioCaptureService()
        guard service.hasPermission() else {
            throw XCTSkip("Screen Recording permission is required for RUN_SYSTEM_AUDIO_CAPTURE_HARNESS=1.")
        }
        let stream = try await service.startCapture()

        let buffers = await Self.collectBuffers(from: stream, minimumCount: 3, timeoutNanoseconds: 4_000_000_000)
        await service.stopCapture()
        XCTAssertGreaterThanOrEqual(buffers.count, 3)
        XCTAssertTrue(buffers.allSatisfy { $0.audioSource == .system })
        XCTAssertTrue(buffers.allSatisfy { ($0.pcmBuffer?.frameLength ?? 0) > 0 })
        XCTAssertTrue(buffers.allSatisfy { ($0.pcmBuffer?.format.sampleRate ?? 0) > 0 })
        XCTAssertTrue(buffers.allSatisfy { $0.mediaTime != nil })
    }

    func testWhisperKitRefinerHarnessTranscribesGeneratedSpeechWhenOptedIn() async throws {
        guard CaptureHarnessOptIn.isEnabled(.whisperKitRefiner) else {
            throw XCTSkip(CaptureHarnessOptIn.skipMessage(for: .whisperKitRefiner))
        }
        guard FileManager.default.fileExists(atPath: "/usr/bin/say") else {
            throw XCTSkip("The WhisperKit refiner harness needs /usr/bin/say to generate deterministic local speech audio.")
        }

        let spokenText = "Notchly uses SpeechAnalyzer and Core ML for local transcription"
        let buffers = try Self.generatedSpeechBuffers(text: spokenText, source: .microphone)
        XCTAssertGreaterThan(buffers.count, 2)

        var original = segment(
            text: "Notchly uses speech analyzer and core mail for local transcription",
            isFinal: true,
            start: 0,
            end: buffers.last?.mediaTime?.seconds ?? 4
        )
        original.engineConfidence = 0.34

        let model = ProcessInfo.processInfo.environment["WHISPERKIT_REFINER_MODEL"] ?? "tiny"
        let service = LocalASRRefinementService()
        let outcome = await service.refine(
            segment: original,
            audioBuffers: buffers,
            config: Self.makeConfig(
                featureFlags: TranscriptionFeatureFlags(localASRRefinerEnabled: true),
                localASRRefinerModel: model,
                allowLocalASRModelDownload: true
            )
        )

        guard let outcome else {
            return XCTFail("WhisperKit returned no refinement outcome for generated speech. Check model availability/download for \(model).")
        }
        XCTAssertTrue(outcome.accepted, outcome.reason)
        XCTAssertEqual(outcome.segment.transcriptionEngine, .whisperKit)
        XCTAssertTrue(
            outcome.segment.text.localizedCaseInsensitiveContains("Notchly") ||
                outcome.segment.text.localizedCaseInsensitiveContains("Core ML"),
            "Refined text should preserve meeting vocabulary: \(outcome.segment.text)"
        )
    }

    func testAppleSpeechHarnessTranscribesGeneratedSpeechWhenOptedIn() async throws {
        guard CaptureHarnessOptIn.isEnabled(.appleSpeechASR) else {
            throw XCTSkip(CaptureHarnessOptIn.skipMessage(for: .appleSpeechASR))
        }
        guard FileManager.default.fileExists(atPath: "/usr/bin/say") else {
            throw XCTSkip("The Apple Speech ASR harness needs /usr/bin/say to generate deterministic local speech audio.")
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw XCTSkip("Speech Recognition permission is required for RUN_APPLE_SPEECH_ASR_HARNESS=1.")
        }
        let locale = Locale(identifier: "en-US")
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw XCTSkip("Apple Speech recognizer for en-US is unavailable on this machine.")
        }

        let spokenText = "Notchly uses SpeechAnalyzer and Core ML for local transcription"
        let buffers = try Self.generatedSpeechBuffers(text: spokenText, source: .microphone)
        XCTAssertGreaterThan(buffers.count, 2)

        let service = AppleSpeechTranscriptionService(allowsAutomaticLanguageSwitching: false)
        let collector = SegmentCollector()
        let startedAt = Date()
        let collectTask = Task {
            for await segment in service.segments {
                await collector.append(segment)
            }
        }
        defer { collectTask.cancel() }

        let config = TranscriptionConfig(
            languageCode: "en-US",
            requiresOnDeviceRecognition: recognizer.supportsOnDeviceRecognition,
            meetingId: UUID(),
            contextualStrings: ["Notchly", "SpeechAnalyzer", "Core ML"],
            speechContext: SpeechRecognitionContext(
                locale: "en-US",
                terms: [
                    SpeechContextTerm(text: "Notchly", locale: "en-US", category: .product, weight: 3, pronunciationXSAMPA: nil, source: "apple-speech-harness"),
                    SpeechContextTerm(text: "SpeechAnalyzer", locale: "en-US", category: .technicalTerm, weight: 3, pronunciationXSAMPA: nil, source: "apple-speech-harness"),
                    SpeechContextTerm(text: "Core ML", locale: "en-US", category: .technicalTerm, weight: 3, pronunciationXSAMPA: nil, source: "apple-speech-harness")
                ]
            ),
            audioSource: .microphone,
            accuracyMode: .highAccuracy,
            commitPolicy: .accurate,
            featureFlags: TranscriptionFeatureFlags(
                advancedAudioConditioningEnabled: true,
                vadGatingEnabled: true,
                transcriptionMetricsEnabled: true
            )
        )

        try await service.startTranscription(audioStream: Self.timedStream(buffers, nanosecondsBetweenBuffers: 80_000_000), config: config)
        let segments = await Self.collectSegments(
            from: collector,
            minimumCount: 1,
            timeoutNanoseconds: 8_000_000_000,
            isSatisfied: { segments in
                let normalizedText = SpeechVocabularyTerm.normalizedKey(
                    segments
                        .map(\.text)
                        .joined(separator: " ")
                )
                return normalizedText.contains("notchly") ||
                    normalizedText.contains("core ml") ||
                    normalizedText.contains("speechanalyzer")
            }
        )
        await service.stop()

        let joined = segments
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(joined.isEmpty, "Apple Speech should emit transcript text for generated speech.")
        XCTAssertTrue(
            SpeechVocabularyTerm.normalizedKey(joined).contains("notchly") ||
                SpeechVocabularyTerm.normalizedKey(joined).contains("core ml") ||
                SpeechVocabularyTerm.normalizedKey(joined).contains("speechanalyzer"),
            "Apple Speech text should preserve at least one contextual meeting term. Got: \(joined)"
        )
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 9.0)
    }

    func testWhisperKitRefinerHarnessMeasuresGeneratedSpeechBenchmarkWhenOptedIn() async throws {
        guard CaptureHarnessOptIn.isEnabled(.whisperKitRefiner) else {
            throw XCTSkip(CaptureHarnessOptIn.skipMessage(for: .whisperKitRefiner))
        }
        guard FileManager.default.fileExists(atPath: "/usr/bin/say") else {
            throw XCTSkip("The WhisperKit benchmark harness needs /usr/bin/say to generate deterministic local speech audio.")
        }

        let model = ProcessInfo.processInfo.environment["WHISPERKIT_REFINER_MODEL"] ?? "tiny"
        let runID = "generated-speech-\(UUID().uuidString)"
        let reportURL = URL(fileURLWithPath: "/private/tmp/notchly-whisperkit-generated-speech-benchmark.json")
        let service = LocalASRRefinementService()
        var attempts: [GeneratedSpeechASRBenchmarkAttempt] = []
        var baselineCases: [TranscriptionBenchmarkCase] = []
        var refinedCases: [TranscriptionBenchmarkCase] = []
        let availableVoices = Self.availableSayVoiceNames()

        for spec in Self.generatedSpeechBenchmarkSpecs() {
            guard availableVoices.contains(spec.voice) else {
                attempts.append(GeneratedSpeechASRBenchmarkAttempt(
                    id: spec.id,
                    locale: spec.locale,
                    voice: spec.voice,
                    accepted: false,
                    reason: "say_voice_unavailable",
                    hypothesis: nil
                ))
                continue
            }

            let buffers = try Self.generatedSpeechBuffers(text: spec.reference, voice: spec.voice, source: .microphone)
            let durationMs = max(1, (buffers.last?.mediaTime?.seconds ?? 0) * 1_000)
            let caseID = "generated-\(spec.id)"
            var original = segment(
                text: spec.baselineHypothesis,
                isFinal: true,
                start: 0,
                end: durationMs / 1_000
            )
            original.originalLanguage = spec.locale
            original.sourceLanguage = spec.locale
            original.engineConfidence = 0.32
            original.languageConfidence = 0.88

            baselineCases.append(TranscriptionBenchmarkCase(
                id: caseID,
                reference: spec.reference,
                hypothesis: spec.baselineHypothesis,
                locale: spec.locale,
                activeVocabulary: spec.vocabulary,
                namedEntities: spec.namedEntities,
                corpus: .internalCritical,
                evaluationTags: spec.tags,
                evidenceKind: .generatedFixture,
                hypothesisSource: .deterministicFixture,
                hypothesisEngineIdentifier: "notchly-generated-baseline",
                hypothesisRunID: runID,
                audioDurationMs: durationMs
            ))

            let startedAt = Date()
            let outcome = await service.refine(
                segment: original,
                audioBuffers: buffers,
                config: Self.makeConfig(
                    languageCode: spec.locale,
                    contextualStrings: spec.vocabulary,
                    featureFlags: TranscriptionFeatureFlags(localASRRefinerEnabled: true),
                    localASRRefinerModel: model,
                    allowLocalASRModelDownload: true
                )
            )
            let processingMs = Date().timeIntervalSince(startedAt) * 1_000

            guard let outcome else {
                attempts.append(GeneratedSpeechASRBenchmarkAttempt(
                    id: spec.id,
                    locale: spec.locale,
                    voice: spec.voice,
                    accepted: false,
                    reason: "no_refinement_outcome",
                    hypothesis: nil
                ))
                continue
            }
            attempts.append(GeneratedSpeechASRBenchmarkAttempt(
                id: spec.id,
                locale: spec.locale,
                voice: spec.voice,
                accepted: outcome.accepted,
                reason: outcome.reason,
                hypothesis: outcome.candidateText ?? outcome.segment.text
            ))

            refinedCases.append(TranscriptionBenchmarkCase(
                id: caseID,
                reference: spec.reference,
                hypothesis: outcome.candidateText ?? outcome.segment.text,
                locale: spec.locale,
                activeVocabulary: spec.vocabulary,
                namedEntities: spec.namedEntities,
                corpus: .internalCritical,
                evaluationTags: spec.tags,
                evidenceKind: .generatedFixture,
                hypothesisSource: .whisperKit,
                hypothesisEngineIdentifier: "WhisperKit/\(model)",
                hypothesisRunID: runID,
                finalLatencyMs: processingMs,
                audioDurationMs: durationMs,
                processingDurationMs: processingMs
            ))
        }

        guard !refinedCases.isEmpty else {
            let report = GeneratedSpeechASRBenchmarkReport(
                runID: runID,
                model: model,
                generatedAt: "2026-05-29T00:00:00Z",
                attempts: attempts,
                baselineCases: baselineCases,
                refinedCases: [],
                baselineSummary: TranscriptionBenchmarkSuite().summary(for: baselineCases),
                refinedSummary: TranscriptionBenchmarkSuite().summary(for: [])
            )
            try Self.writeGeneratedSpeechBenchmarkReport(report, to: reportURL)
            throw XCTSkip("WhisperKit generated-speech benchmark produced no candidate transcripts. See \(reportURL.path).")
        }

        let acceptedIDs = Set(refinedCases.map(\.id))
        let acceptedBaselineCases = baselineCases.filter { acceptedIDs.contains($0.id) }
        let suite = TranscriptionBenchmarkSuite()
        let baselineSummary = suite.summary(for: acceptedBaselineCases)
        let refinedSummary = suite.summary(for: refinedCases)

        let report = GeneratedSpeechASRBenchmarkReport(
            runID: runID,
            model: model,
            generatedAt: "2026-05-29T00:00:00Z",
            attempts: attempts,
            baselineCases: acceptedBaselineCases,
            refinedCases: refinedCases,
            baselineSummary: baselineSummary,
            refinedSummary: refinedSummary
        )
        try Self.writeGeneratedSpeechBenchmarkReport(report, to: reportURL)

        let acceptedCount = attempts.filter(\.accepted).count
        if acceptedCount == 0 || refinedSummary.averageWordErrorRate >= baselineSummary.averageWordErrorRate {
            throw XCTSkip("WhisperKit generated-speech benchmark completed without measurable improvement for model \(model). See \(reportURL.path).")
        }

        XCTAssertLessThan(
            refinedSummary.averageWordErrorRate,
            baselineSummary.averageWordErrorRate,
            "WhisperKit refinement should improve WER over the intentionally flawed baseline."
        )
        XCTAssertGreaterThanOrEqual(
            refinedSummary.averageVocabularyRecognitionRate,
            baselineSummary.averageVocabularyRecognitionRate,
            "WhisperKit refinement should preserve or improve jargon recall."
        )
    }

    func testTranscriptionCorpusReplayHarnessRunsManifestWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let manifestPath = environment["NOTCHLY_TRANSCRIPTION_REPLAY_MANIFEST"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !manifestPath.isEmpty else {
            throw XCTSkip("Set NOTCHLY_TRANSCRIPTION_REPLAY_MANIFEST=/path/to/transcription-eval.json to run the real corpus ASR replay harness.")
        }
        let manifestURL = URL(fileURLWithPath: manifestPath)
        let configuredRunID = environment["NOTCHLY_TRANSCRIPTION_REPLAY_RUN_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let runID = configuredRunID.isEmpty ? "manual-corpus-replay-\(UUID().uuidString)" : configuredRunID
        let configuredOutputDirectory = environment["NOTCHLY_TRANSCRIPTION_REPLAY_OUTPUT_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let outputDirectory = URL(fileURLWithPath: configuredOutputDirectory.isEmpty ?
            FileManager.default.temporaryDirectory.appendingPathComponent("notchly-transcription-replay-\(runID)", isDirectory: true).path :
            configuredOutputDirectory)
        let replayInRealTime = ["1", "true", "yes"].contains(environment["NOTCHLY_TRANSCRIPTION_REPLAY_REALTIME"]?.lowercased() ?? "")
        let allowModelDownload = ["1", "true", "yes"].contains(environment["NOTCHLY_TRANSCRIPTION_REPLAY_ALLOW_MODEL_DOWNLOAD"]?.lowercased() ?? "")
        let localRefinerEnabled = ["1", "true", "yes"].contains(environment["NOTCHLY_TRANSCRIPTION_REPLAY_LOCAL_REFINER"]?.lowercased() ?? "")
        let configuredModel = environment["NOTCHLY_TRANSCRIPTION_REPLAY_REFINER_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = configuredModel.isEmpty ? "distil-large-v3" : configuredModel

        let report = try await TranscriptionEvaluationReplayRunner().replay(
            manifestAt: manifestURL,
            outputDirectory: outputDirectory,
            baseConfig: Self.makeConfig(
                featureFlags: TranscriptionFeatureFlags(
                    advancedAudioConditioningEnabled: true,
                    vadGatingEnabled: true,
                    languageContinuityV2Enabled: true,
                    localASRRefinerEnabled: localRefinerEnabled,
                    transcriptionMetricsEnabled: true,
                    cloudFallbackEnabled: false
                ),
                localASRRefinerModel: model,
                allowLocalASRModelDownload: allowModelDownload
            ),
            policy: .topTierRelease,
            configuration: TranscriptionEvaluationReplayConfiguration(
                runID: runID,
                chunkDurationMs: 120,
                postAudioDrainMs: replayInRealTime ? 1_500 : 900,
                replayInRealTime: replayInRealTime,
                audioSource: .system,
                hypothesisSource: nil,
                engineIdentifier: "notchly-apple-native-corpus-replay",
                generatedAt: ISO8601DateFormatter().string(from: Date())
            )
        )
        let reportURL = outputDirectory.appendingPathComponent("transcription-replay-report-\(runID).json")
        try Self.writeReplayReport(report, to: reportURL)

        XCTAssertTrue(
            report.passed,
            "Corpus replay failed top-tier gate. Report: \(reportURL.path). Failures: \((report.evaluationReport.releaseGateReport.failures + report.evaluationReport.improvementGateFailures).joined(separator: ", "))"
        )
    }

    func testVoiceActivityDetectorRejectsSilenceClicksMusicAndAllowsSpeech() {
        var detector = VoiceActivityDetector()

        let silence = TranscriptionAudioFixtureGenerator.buffers(profile: TranscriptionAudioFixtureProfile.silence, chunks: 1).first!
        let silenceDecision = detector.analyze(silence)
        XCTAssertFalse(silenceDecision.shouldForwardToASR)
        XCTAssertEqual(silenceDecision.state, .silence)
        XCTAssertEqual(silenceDecision.detectionEngine, .heuristicEnergy)

        let click = TranscriptionAudioFixtureGenerator.buffers(profile: TranscriptionAudioFixtureProfile.clicks, chunks: 1).first!
        let clickDecision = detector.analyze(click)
        XCTAssertFalse(clickDecision.shouldForwardToASR)
        XCTAssertEqual(clickDecision.reason, "impulse_click")

        let music = TranscriptionAudioFixtureGenerator.buffers(profile: TranscriptionAudioFixtureProfile.music, chunks: 1).first!
        let musicDecision = detector.analyze(music)
        XCTAssertFalse(musicDecision.shouldForwardToASR)
        XCTAssertEqual(musicDecision.reason, "sustained_tonal_non_speech")
        XCTAssertLessThan(musicDecision.envelopeVariation, 0.045)

        let breathing = TranscriptionAudioFixtureGenerator.buffers(profile: TranscriptionAudioFixtureProfile.breathing, chunks: 1).first!
        let breathingDecision = detector.analyze(breathing)
        XCTAssertFalse(breathingDecision.shouldForwardToASR)
        XCTAssertEqual(breathingDecision.reason, "sustained_broadband_non_speech")
        XCTAssertGreaterThanOrEqual(breathingDecision.zeroCrossingRate, 0.42)

        let speech = TranscriptionAudioFixtureGenerator.speechLikeBuffer(offset: 2)
        let speechDecision = detector.analyze(speech)
        XCTAssertTrue(speechDecision.shouldForwardToASR)
        XCTAssertTrue(speechDecision.speechProbability > 0.5)
        XCTAssertGreaterThan(speechDecision.envelopeVariation, 0.045)
        XCTAssertEqual(speechDecision.detectionEngine, .heuristicEnergy)
    }

    func testVoiceActivityDetectorForwardsLowVolumeMicrophoneAndSystemSpeech() {
        var microphoneDetector = VoiceActivityDetector()
        let quietMicrophoneSpeech = TranscriptionAudioFixtureGenerator.speechLikeBuffer(
            amplitude: 0.0025,
            source: .microphone,
            offset: 5
        )
        let microphoneDecision = microphoneDetector.analyze(quietMicrophoneSpeech)
        XCTAssertTrue(microphoneDecision.shouldForwardToASR)
        XCTAssertTrue(microphoneDecision.state == .speechLikely || microphoneDecision.state == .speechActive)
        XCTAssertGreaterThan(microphoneDecision.speechProbability, 0.5)

        var systemDetector = VoiceActivityDetector()
        let quietSystemSpeech = TranscriptionAudioFixtureGenerator.speechLikeBuffer(
            amplitude: 0.0019,
            source: .system,
            offset: 6
        )
        let systemDecision = systemDetector.analyze(quietSystemSpeech)
        XCTAssertTrue(systemDecision.shouldForwardToASR)
        XCTAssertTrue(systemDecision.state == .speechLikely || systemDecision.state == .speechActive)
        XCTAssertGreaterThan(systemDecision.speechProbability, 0.5)

        var subtleMicrophoneDetector = VoiceActivityDetector()
        let subtleMicrophoneSpeech = TranscriptionAudioFixtureGenerator.speechLikeBuffer(
            amplitude: 0.00052,
            source: .microphone,
            offset: 7
        )
        let subtleMicrophoneDecision = subtleMicrophoneDetector.analyze(subtleMicrophoneSpeech)
        XCTAssertTrue(subtleMicrophoneDecision.shouldForwardToASR)
        XCTAssertEqual(subtleMicrophoneDecision.state, .speechLikely)

        var subtleSystemDetector = VoiceActivityDetector()
        let subtleSystemSpeech = TranscriptionAudioFixtureGenerator.speechLikeBuffer(
            amplitude: 0.00044,
            source: .system,
            offset: 8
        )
        let subtleSystemDecision = subtleSystemDetector.analyze(subtleSystemSpeech)
        XCTAssertTrue(subtleSystemDecision.shouldForwardToASR)
        XCTAssertEqual(subtleSystemDecision.state, .speechLikely)
    }

    func testVoiceActivityDetectorKeepsLowAudioSpeechContinuationAfterActiveSpeech() {
        let cases: [(source: TranscriptAudioSource, firstTailAmplitude: Float, secondTailAmplitude: Float)] = [
            (.microphone, 0.00015, 0.000085),
            (.system, 0.00011, 0.000070)
        ]

        for testCase in cases {
            var detector = VoiceActivityDetector()
            let start = Date()
            let activeSpeech = TranscriptionAudioFixtureGenerator.speechLikeBuffer(
                amplitude: 0.004,
                source: testCase.source,
                offset: 0
            )
            XCTAssertTrue(detector.analyze(activeSpeech, now: start).shouldForwardToASR)

            let firstWeakTail = TranscriptionAudioFixtureGenerator.speechLikeBuffer(
                amplitude: testCase.firstTailAmplitude,
                source: testCase.source,
                offset: 1
            )
            let firstTailDecision = detector.analyze(firstWeakTail, now: start.addingTimeInterval(0.52))
            XCTAssertTrue(firstTailDecision.shouldForwardToASR, "\(testCase.source.displayName): \(firstTailDecision)")
            XCTAssertTrue(
                firstTailDecision.state == .lowAudio || firstTailDecision.state == .speechLikely,
                "\(testCase.source.displayName) should keep the first weak tail connected: \(firstTailDecision)"
            )
            XCTAssertTrue(
                firstTailDecision.reason == "low_audio_speech_continuation" || firstTailDecision.reason == "low_energy_speech_onset",
                "\(testCase.source.displayName) should preserve speech-shaped weak tail: \(firstTailDecision)"
            )

            let secondWeakTail = TranscriptionAudioFixtureGenerator.speechLikeBuffer(
                amplitude: testCase.secondTailAmplitude,
                source: testCase.source,
                offset: 2
            )
            let secondTailDecision = detector.analyze(secondWeakTail, now: start.addingTimeInterval(1.04))
            XCTAssertTrue(secondTailDecision.shouldForwardToASR, "\(testCase.source.displayName): \(secondTailDecision)")
            XCTAssertTrue(
                secondTailDecision.state == .lowAudio || secondTailDecision.state == .speechLikely,
                "\(testCase.source.displayName) should keep the second weak tail connected: \(secondTailDecision)"
            )
            XCTAssertTrue(
                secondTailDecision.reason == "low_audio_speech_continuation" || secondTailDecision.reason == "low_energy_speech_onset",
                "\(testCase.source.displayName) should preserve speech-shaped weak tail: \(secondTailDecision)"
            )

            var lateTailDetector = VoiceActivityDetector()
            XCTAssertTrue(lateTailDetector.analyze(activeSpeech, now: start).shouldForwardToASR)
            let lateWeakTail = TranscriptionAudioFixtureGenerator.speechLikeBuffer(
                amplitude: testCase.secondTailAmplitude,
                source: testCase.source,
                offset: 3
            )
            let lateOffset = testCase.source == .system ? 2.68 : 2.43
            let lateTailDecision = lateTailDetector.analyze(lateWeakTail, now: start.addingTimeInterval(lateOffset))
            XCTAssertTrue(lateTailDecision.shouldForwardToASR, "\(testCase.source.displayName) late low-energy tail should remain connected: \(lateTailDecision)")
            XCTAssertTrue(
                lateTailDecision.reason == "low_audio_speech_continuation" || lateTailDecision.reason == "low_energy_speech_onset",
                "\(testCase.source.displayName) late low-energy tail should remain speech-shaped: \(lateTailDecision)"
            )

            var expiredTailDetector = VoiceActivityDetector()
            XCTAssertTrue(expiredTailDetector.analyze(activeSpeech, now: start).shouldForwardToASR)
            let expiredFlatAudio = TranscriptionAudioFixtureGenerator.buffer(
                samples: Array(repeating: testCase.secondTailAmplitude, count: 1_600),
                source: testCase.source,
                offset: 4
            )
            let expiredOffset = testCase.source == .system ? 2.98 : 2.72
            let expiredFlatDecision = expiredTailDetector.analyze(expiredFlatAudio, now: start.addingTimeInterval(expiredOffset))
            XCTAssertFalse(expiredFlatDecision.shouldForwardToASR, "\(testCase.source.displayName) flat weak audio after continuation window should not reopen ASR: \(expiredFlatDecision)")

            var isolatedDetector = VoiceActivityDetector()
            let isolatedDecision = isolatedDetector.analyze(secondWeakTail)
            XCTAssertTrue(isolatedDecision.shouldForwardToASR, "Isolated weak speech-shaped audio should now open ASR instead of cutting the start of a quiet speaker: \(isolatedDecision)")
        }
    }

    func testVoiceActivityDetectorRejectsBreathingDuringSpeechHangover() {
        var detector = VoiceActivityDetector()
        let speech = TranscriptionAudioFixtureGenerator.speechLikeBuffer(offset: 0)
        let speechDecision = detector.analyze(speech)
        XCTAssertTrue(speechDecision.shouldForwardToASR)

        let breathing = TranscriptionAudioFixtureGenerator.buffers(profile: .breathing, chunks: 1).first!
        let breathingDecision = detector.analyze(breathing)
        XCTAssertFalse(breathingDecision.shouldForwardToASR)
        XCTAssertEqual(breathingDecision.state, .noise)
        XCTAssertEqual(breathingDecision.reason, "sustained_broadband_non_speech")
    }

    func testAudioConditioningServiceGatesSilenceAndReplaysPreRoll() {
        let service = AudioConditioningService(source: .microphone, preRollDuration: 0.4)
        let config = AudioConditioningConfig(accuracyMode: .highAccuracy, target: .nativeSpeech, audioSource: .microphone)
        let flags = TranscriptionFeatureFlags(vadGatingEnabled: true)

        let silence = TranscriptionAudioFixtureGenerator.buffers(profile: TranscriptionAudioFixtureProfile.silence, chunks: 1).first!
        XCTAssertTrue(service.condition(silence, config: config, featureFlags: flags).isEmpty)

        let speech = TranscriptionAudioFixtureGenerator.speechLikeBuffer(offset: 1)
        let frames = service.condition(speech, config: config, featureFlags: flags)
        XCTAssertGreaterThanOrEqual(frames.count, 1)
        XCTAssertTrue(frames.contains { $0.buffer.rms > 0.001 })
    }

    func testAudioConditioningServiceKeepsQuietLeadInPreRollBeforeSpeech() {
        let service = AudioConditioningService(source: .microphone, preRollDuration: 0.95)
        let config = AudioConditioningConfig(accuracyMode: .highAccuracy, target: .nativeSpeech, audioSource: .microphone)
        let flags = TranscriptionFeatureFlags(vadGatingEnabled: true)

        let quietLead = TranscriptionAudioFixtureGenerator.speechLikeBuffer(amplitude: 0.00000035, source: .microphone, offset: 0)
        let leadTrace = service.conditionWithTrace(quietLead, config: config, featureFlags: flags)
        XCTAssertFalse(leadTrace.vadDecision.shouldForwardToASR)
        XCTAssertTrue(leadTrace.frames.isEmpty)

        let speech = TranscriptionAudioFixtureGenerator.speechLikeBuffer(amplitude: 0.004, source: .microphone, offset: 1)
        let speechTrace = service.conditionWithTrace(speech, config: config, featureFlags: flags)
        XCTAssertTrue(speechTrace.vadDecision.shouldForwardToASR)
        XCTAssertTrue(speechTrace.frames.contains { $0.isPreRollReplay })
        XCTAssertTrue(speechTrace.frames.contains { !$0.isPreRollReplay })
    }

    func testAudioConditioningServiceNormalizesVeryLowMicrophoneSpeechWithoutForwardingSilence() {
        let service = AudioConditioningService(source: .microphone, preRollDuration: 0.4)
        let config = AudioConditioningConfig(accuracyMode: .highAccuracy, target: .nativeSpeech, audioSource: .microphone)
        let flags = TranscriptionFeatureFlags(vadGatingEnabled: true)

        let silence = TranscriptionAudioFixtureGenerator.buffers(profile: .silence, source: .microphone, chunks: 1).first!
        let silenceTrace = service.conditionWithTrace(silence, config: config, featureFlags: flags)
        XCTAssertFalse(silenceTrace.vadDecision.shouldForwardToASR)
        XCTAssertTrue(silenceTrace.frames.isEmpty)

        let quietMicrophoneSpeech = TranscriptionAudioFixtureGenerator.speechLikeBuffer(amplitude: 0.00010, source: .microphone, offset: 1)
        let speechTrace = service.conditionWithTrace(quietMicrophoneSpeech, config: config, featureFlags: flags)
        XCTAssertGreaterThan(speechTrace.conditionedBuffer.rms, quietMicrophoneSpeech.rms * 5.0)
        XCTAssertTrue(speechTrace.vadDecision.shouldForwardToASR, "\(speechTrace.vadDecision)")
        XCTAssertFalse(speechTrace.frames.isEmpty, "\(speechTrace.vadDecision)")
    }

    func testAudioConditioningServiceStartsVeryLowSpeechWithHighAccuracyGainWithoutForwardingNonSpeech() {
        let flags = TranscriptionFeatureFlags(vadGatingEnabled: true)

        for testCase in [
            (source: TranscriptAudioSource.microphone, speechAmplitude: Float(0.000007), noiseAmplitude: Float(0.000050)),
            (source: TranscriptAudioSource.system, speechAmplitude: Float(0.000006), noiseAmplitude: Float(0.000045))
        ] {
            let config = AudioConditioningConfig(accuracyMode: .highAccuracy, target: .nativeSpeech, audioSource: testCase.source)
            let service = AudioConditioningService(source: testCase.source, preRollDuration: 0.4)

            let silence = TranscriptionAudioFixtureGenerator.buffers(profile: .silence, source: testCase.source, chunks: 1).first!
            let silenceTrace = service.conditionWithTrace(silence, config: config, featureFlags: flags)
            XCTAssertFalse(silenceTrace.vadDecision.shouldForwardToASR)
            XCTAssertTrue(silenceTrace.frames.isEmpty)

            var speechTraces: [AudioConditioningTrace] = []
            for offset in 1...5 {
                let weakSpeech = TranscriptionAudioFixtureGenerator.speechLikeBuffer(
                    amplitude: testCase.speechAmplitude,
                    source: testCase.source,
                    offset: offset
                )
                speechTraces.append(service.conditionWithTrace(weakSpeech, config: config, featureFlags: flags))
            }

            XCTAssertTrue(
                speechTraces.contains { $0.vadDecision.shouldForwardToASR && !$0.frames.isEmpty },
                "\(testCase.source.displayName) should start ASR for very low speech within the first few chunks: \(speechTraces.map(\.vadDecision))"
            )
            XCTAssertTrue(
                speechTraces.contains { $0.conditionedBuffer.rms > $0.inputBuffer.rms * 12.0 },
                "\(testCase.source.displayName) should apply enough native gain to expose very low speech"
            )

            let musicService = AudioConditioningService(source: testCase.source, preRollDuration: 0.4)
            let quietMusic = TranscriptionAudioFixtureGenerator.tonalMusicBuffer(
                amplitude: testCase.noiseAmplitude,
                source: testCase.source,
                offset: 6
            )
            let quietMusicTrace = musicService.conditionWithTrace(quietMusic, config: config, featureFlags: flags)
            XCTAssertFalse(quietMusicTrace.vadDecision.shouldForwardToASR, "\(testCase.source.displayName) quiet music should stay gated: \(quietMusicTrace.vadDecision)")
            XCTAssertTrue(quietMusicTrace.frames.isEmpty)

            let breathingService = AudioConditioningService(source: testCase.source, preRollDuration: 0.4)
            let quietBreathing = TranscriptionAudioFixtureGenerator.breathingNoiseBuffer(
                amplitude: testCase.noiseAmplitude,
                source: testCase.source,
                offset: 7
            )
            let quietBreathingTrace = breathingService.conditionWithTrace(quietBreathing, config: config, featureFlags: flags)
            XCTAssertFalse(quietBreathingTrace.vadDecision.shouldForwardToASR, "\(testCase.source.displayName) quiet breathing should stay gated: \(quietBreathingTrace.vadDecision)")
            XCTAssertTrue(quietBreathingTrace.frames.isEmpty)
        }
    }

    func testAudioConditioningServiceBridgesShortWeakGapsInsideSpeech() {
        let flags = TranscriptionFeatureFlags(vadGatingEnabled: true)

        for testCase in [
            (source: TranscriptAudioSource.microphone, bridgedOffsets: 1...30, blockedOffset: 31),
            (source: TranscriptAudioSource.system, bridgedOffsets: 1...33, blockedOffset: 34)
        ] {
            let isolatedService = AudioConditioningService(source: testCase.source, preRollDuration: 0.4)
            let config = AudioConditioningConfig(accuracyMode: .highAccuracy, target: .nativeSpeech, audioSource: testCase.source)
            let isolatedSilence = TranscriptionAudioFixtureGenerator.buffer(
                samples: Array(repeating: 0, count: 1_600),
                source: testCase.source,
                offset: 0
            )
            let isolatedTrace = isolatedService.conditionWithTrace(isolatedSilence, config: config, featureFlags: flags)
            XCTAssertFalse(isolatedTrace.vadDecision.shouldForwardToASR)
            XCTAssertTrue(isolatedTrace.frames.isEmpty, "\(testCase.source.displayName) isolated silence must stay gated")

            let service = AudioConditioningService(source: testCase.source, preRollDuration: 0.4)
            let firstSpeech = TranscriptionAudioFixtureGenerator.speechLikeBuffer(amplitude: 0.004, source: testCase.source, offset: 0)
            let firstTrace = service.conditionWithTrace(firstSpeech, config: config, featureFlags: flags)
            XCTAssertTrue(firstTrace.vadDecision.shouldForwardToASR)
            XCTAssertEqual(firstTrace.frames.filter { !$0.isPreRollReplay }.count, 1)

            for offset in testCase.bridgedOffsets {
                let pauseTrace = service.conditionWithTrace(
                    TranscriptionAudioFixtureGenerator.buffer(
                        samples: Array(repeating: 0, count: 1_600),
                        source: testCase.source,
                        offset: offset
                    ),
                    config: config,
                    featureFlags: flags
                )
                XCTAssertFalse(pauseTrace.vadDecision.shouldForwardToASR)
                XCTAssertEqual(pauseTrace.frames.count, 1, "\(testCase.source.displayName) should bridge natural pause chunk \(offset)")
                XCTAssertFalse(pauseTrace.frames[0].isPreRollReplay)
            }

            let longGap = TranscriptionAudioFixtureGenerator.buffer(
                samples: Array(repeating: 0, count: 1_600),
                source: testCase.source,
                offset: testCase.blockedOffset
            )
            let longGapTrace = service.conditionWithTrace(longGap, config: config, featureFlags: flags)
            XCTAssertFalse(longGapTrace.vadDecision.shouldForwardToASR)
            XCTAssertTrue(longGapTrace.frames.isEmpty, "\(testCase.source.displayName) should stop bridging after a real pause")
        }
    }

    func testAudioConditioningServiceRenewsBridgeForVeryWeakSpeechShapedAudioOnly() {
        let flags = TranscriptionFeatureFlags(
            advancedAudioConditioningEnabled: false,
            vadGatingEnabled: true
        )

        for testCase in [
            (source: TranscriptAudioSource.microphone, amplitude: Float(0.000014), lateOffset: 33),
            (source: TranscriptAudioSource.system, amplitude: Float(0.000012), lateOffset: 36)
        ] {
            let config = AudioConditioningConfig(accuracyMode: .highAccuracy, target: .nativeSpeech, audioSource: testCase.source)
            let service = AudioConditioningService(source: testCase.source, preRollDuration: 0.4)
            let firstSpeech = TranscriptionAudioFixtureGenerator.speechLikeBuffer(amplitude: 0.004, source: testCase.source, offset: 0)
            let firstTrace = service.conditionWithTrace(firstSpeech, config: config, featureFlags: flags)
            XCTAssertTrue(firstTrace.vadDecision.shouldForwardToASR)

            var bridgedWeakSpeechCount = 0
            for offset in 1...testCase.lateOffset {
                let weakSpeech = TranscriptionAudioFixtureGenerator.speechLikeBuffer(
                    amplitude: testCase.amplitude,
                    source: testCase.source,
                    offset: offset
                )
                let trace = service.conditionWithTrace(weakSpeech, config: config, featureFlags: flags)
                if !trace.vadDecision.shouldForwardToASR {
                    bridgedWeakSpeechCount += 1
                }
                XCTAssertFalse(trace.frames.isEmpty, "\(testCase.source.displayName) should keep very weak speech-shaped audio connected at offset \(offset): \(trace.vadDecision)")
            }
            XCTAssertGreaterThan(bridgedWeakSpeechCount, 0, "\(testCase.source.displayName) test must exercise bridge renewal, not only direct VAD forwarding")

            let silenceService = AudioConditioningService(source: testCase.source, preRollDuration: 0.4)
            XCTAssertFalse(silenceService.conditionWithTrace(firstSpeech, config: config, featureFlags: flags).frames.isEmpty)
            let blockedOffset = testCase.source == .system ? 34 : 31
            for offset in 1...blockedOffset {
                let silence = TranscriptionAudioFixtureGenerator.buffer(
                    samples: Array(repeating: 0, count: 1_600),
                    source: testCase.source,
                    offset: offset
                )
                let trace = silenceService.conditionWithTrace(silence, config: config, featureFlags: flags)
                if offset == blockedOffset {
                    XCTAssertTrue(trace.frames.isEmpty, "\(testCase.source.displayName) pure silence should still expire instead of renewing bridge")
                }
            }

            let quietMusicService = AudioConditioningService(source: testCase.source, preRollDuration: 0.4)
            XCTAssertFalse(quietMusicService.conditionWithTrace(firstSpeech, config: config, featureFlags: flags).frames.isEmpty)
            for offset in 1...blockedOffset {
                let quietMusic = TranscriptionAudioFixtureGenerator.tonalMusicBuffer(
                    amplitude: 0.00005,
                    source: testCase.source,
                    offset: offset
                )
                let trace = quietMusicService.conditionWithTrace(quietMusic, config: config, featureFlags: flags)
                if offset == blockedOffset {
                    XCTAssertTrue(trace.frames.isEmpty, "\(testCase.source.displayName) quiet music should not renew speech bridge")
                }
            }

            let quietBreathingService = AudioConditioningService(source: testCase.source, preRollDuration: 0.4)
            XCTAssertFalse(quietBreathingService.conditionWithTrace(firstSpeech, config: config, featureFlags: flags).frames.isEmpty)
            for offset in 1...blockedOffset {
                let quietBreathing = TranscriptionAudioFixtureGenerator.breathingNoiseBuffer(
                    amplitude: 0.00005,
                    source: testCase.source,
                    offset: offset
                )
                let trace = quietBreathingService.conditionWithTrace(quietBreathing, config: config, featureFlags: flags)
                if offset == blockedOffset {
                    XCTAssertTrue(trace.frames.isEmpty, "\(testCase.source.displayName) quiet breathing should not renew speech bridge")
                }
            }
        }
    }

    func testAudioConditioningServiceNormalizesLowSystemSpeechWithoutForwardingSilence() {
        let service = AudioConditioningService(source: .system, preRollDuration: 0.4)
        let config = AudioConditioningConfig(accuracyMode: .highAccuracy, target: .nativeSpeech, audioSource: .system)
        let flags = TranscriptionFeatureFlags(vadGatingEnabled: true)

        let silence = TranscriptionAudioFixtureGenerator.buffers(profile: .silence, source: .system, chunks: 1).first!
        let silenceTrace = service.conditionWithTrace(silence, config: config, featureFlags: flags)
        XCTAssertFalse(silenceTrace.vadDecision.shouldForwardToASR)
        XCTAssertTrue(silenceTrace.frames.isEmpty)

        let quietSystemSpeech = TranscriptionAudioFixtureGenerator.speechLikeBuffer(amplitude: 0.000085, source: .system, offset: 1)
        let speechTrace = service.conditionWithTrace(quietSystemSpeech, config: config, featureFlags: flags)
        XCTAssertGreaterThan(speechTrace.conditionedBuffer.rms, quietSystemSpeech.rms * 5.0)
        XCTAssertTrue(speechTrace.vadDecision.shouldForwardToASR, "\(speechTrace.vadDecision)")
        XCTAssertFalse(speechTrace.frames.isEmpty, "\(speechTrace.vadDecision)")
    }

    func testAudioConditioningServiceStartsUltraLowSpeechWithoutOpeningFlatSignal() {
        let flags = TranscriptionFeatureFlags(vadGatingEnabled: true)

        for testCase in [
            (source: TranscriptAudioSource.microphone, speechAmplitude: Float(0.0000028), flatAmplitude: Float(0.0000028)),
            (source: TranscriptAudioSource.system, speechAmplitude: Float(0.0000024), flatAmplitude: Float(0.0000024))
        ] {
            let config = AudioConditioningConfig(accuracyMode: .highAccuracy, target: .nativeSpeech, audioSource: testCase.source)
            let speechService = AudioConditioningService(source: testCase.source, preRollDuration: 0.4)

            var speechTraces: [AudioConditioningTrace] = []
            for offset in 0...4 {
                speechTraces.append(speechService.conditionWithTrace(
                    TranscriptionAudioFixtureGenerator.speechLikeBuffer(
                        amplitude: testCase.speechAmplitude,
                        source: testCase.source,
                        offset: offset
                    ),
                    config: config,
                    featureFlags: flags
                ))
            }

            XCTAssertTrue(
                speechTraces.prefix(2).contains { $0.vadDecision.shouldForwardToASR && !$0.frames.isEmpty },
                "\(testCase.source.displayName) should open ASR for ultra-low speech-shaped audio within the first two chunks: \(speechTraces.map(\.vadDecision))"
            )
            XCTAssertTrue(
                speechTraces.contains { $0.conditionedBuffer.rms > $0.inputBuffer.rms * 28.0 },
                "\(testCase.source.displayName) should apply stronger local gain before native ASR"
            )
            XCTAssertGreaterThanOrEqual(
                speechTraces.filter { !$0.frames.isEmpty }.count,
                4,
                "\(testCase.source.displayName) should keep ultra-low continuous speech connected instead of cutting words: \(speechTraces.map(\.vadDecision))"
            )

            let flatService = AudioConditioningService(source: testCase.source, preRollDuration: 0.4)
            let flatTrace = flatService.conditionWithTrace(
                TranscriptionAudioFixtureGenerator.buffer(
                    samples: Array(repeating: testCase.flatAmplitude, count: 1_600),
                    source: testCase.source,
                    offset: 8
                ),
                config: config,
                featureFlags: flags
            )
            XCTAssertFalse(flatTrace.vadDecision.shouldForwardToASR, "\(testCase.source.displayName) flat low-level signal must stay gated: \(flatTrace.vadDecision)")
            XCTAssertTrue(flatTrace.frames.isEmpty)
        }
    }

    func testAudioConditioningServiceMaintainsUltraLowPhraseAcrossSpeechDips() {
        let flags = TranscriptionFeatureFlags(vadGatingEnabled: true)

        for testCase in [
            (
                source: TranscriptAudioSource.microphone,
                amplitudes: [Float(0.0000030), 0.0000010, 0.0000027, 0.0000008, 0.0000029, 0.0000011],
                flatAmplitude: Float(0.0000030)
            ),
            (
                source: TranscriptAudioSource.system,
                amplitudes: [Float(0.0000026), 0.0000009, 0.0000023, 0.0000007, 0.0000024, 0.0000010],
                flatAmplitude: Float(0.0000026)
            )
        ] {
            let config = AudioConditioningConfig(accuracyMode: .highAccuracy, target: .nativeSpeech, audioSource: testCase.source)
            let speechService = AudioConditioningService(source: testCase.source, preRollDuration: 0.4)
            var speechTraces: [AudioConditioningTrace] = []

            for (offset, amplitude) in testCase.amplitudes.enumerated() {
                let buffer = TranscriptionAudioFixtureGenerator.speechLikeBuffer(
                    amplitude: amplitude,
                    source: testCase.source,
                    offset: offset
                )
                speechTraces.append(speechService.conditionWithTrace(buffer, config: config, featureFlags: flags))
            }

            XCTAssertTrue(
                speechTraces.prefix(2).contains { !$0.frames.isEmpty },
                "\(testCase.source.displayName) should start ASR before quiet phrase words are lost: \(speechTraces.map(\.vadDecision))"
            )
            XCTAssertEqual(
                speechTraces.filter { !$0.frames.isEmpty }.count,
                testCase.amplitudes.count,
                "\(testCase.source.displayName) should keep every quiet phrase chunk connected through short speech-shaped dips: \(speechTraces.map(\.vadDecision))"
            )

            let flatService = AudioConditioningService(source: testCase.source, preRollDuration: 0.4)
            let flatTraces = (0..<testCase.amplitudes.count).map { offset in
                flatService.conditionWithTrace(
                    TranscriptionAudioFixtureGenerator.buffer(
                        samples: Array(repeating: testCase.flatAmplitude, count: 1_600),
                        source: testCase.source,
                        offset: offset
                    ),
                    config: config,
                    featureFlags: flags
                )
            }
            XCTAssertTrue(
                flatTraces.allSatisfy { !$0.vadDecision.shouldForwardToASR && $0.frames.isEmpty },
                "\(testCase.source.displayName) flat low-level signal should stay gated even at speech-sensitive thresholds: \(flatTraces.map(\.vadDecision))"
            )
        }
    }

    func testLanguageContinuityResolverKeepsTechnicalCodeSwitchFromChangingGlobalSourceLanguage() {
        var resolver = LanguageContinuityResolver()
        let first = resolver.resolve(
            text: "vamos validar a transcricao agora",
            audioSource: .microphone,
            incomingLanguage: "pt-BR",
            existingLanguage: nil,
            meetingLanguage: "pt-BR",
            defaultLanguage: "pt-BR",
            isFinal: true
        )
        XCTAssertEqual(first.language, .portugueseBR)

        let technicalIsland = resolver.resolve(
            text: "SFSpeech CoreML p95 AVFoundation SpeechAnalyzer Notchly",
            audioSource: .microphone,
            incomingLanguage: "en-US",
            existingLanguage: first.language.rawValue,
            meetingLanguage: "pt-BR",
            defaultLanguage: "pt-BR",
            isFinal: true
        )
        XCTAssertEqual(technicalIsland.language, .portugueseBR)
        XCTAssertFalse(technicalIsland.isTextDetected)

        let spokenEnglishUtterance = resolver.resolve(
            text: "SFSpeech CoreML p95 AVFoundation SpeechAnalyzer Notchly rollout risk",
            audioSource: .microphone,
            incomingLanguage: nil,
            existingLanguage: technicalIsland.language.rawValue,
            meetingLanguage: "pt-BR",
            defaultLanguage: "pt-BR",
            isFinal: true,
            supplementalSignals: [LanguageContinuitySignal(languageCode: "en-US", confidence: 0.84, source: "whisperKit-auto-language")]
        )
        XCTAssertEqual(spokenEnglishUtterance.language, .englishUS)
        XCTAssertTrue(spokenEnglishUtterance.isTextDetected)
    }

    func testLanguageContinuityResolverRequiresRepeatedPartialEvidenceBeforeSwitching() {
        var resolver = LanguageContinuityResolver()
        let portuguese = resolver.resolve(
            text: "vamos revisar o escopo antes da demo",
            audioSource: .system,
            incomingLanguage: "pt-BR",
            existingLanguage: nil,
            meetingLanguage: "pt-BR",
            defaultLanguage: "pt-BR",
            isFinal: true
        )
        XCTAssertEqual(portuguese.language, .portugueseBR)

        let firstEnglishPartial = resolver.resolve(
            text: "we should review rollout risk before shipping",
            audioSource: .system,
            incomingLanguage: nil,
            existingLanguage: portuguese.language.rawValue,
            meetingLanguage: "pt-BR",
            defaultLanguage: "pt-BR",
            isFinal: false,
            supplementalSignals: [LanguageContinuitySignal(languageCode: "en-US", confidence: 0.91, source: "spoken-lid-test")]
        )
        XCTAssertEqual(firstEnglishPartial.language, .portugueseBR)
        XCTAssertFalse(firstEnglishPartial.isTextDetected)

        let secondEnglishPartial = resolver.resolve(
            text: "we should review rollout risk before shipping",
            audioSource: .system,
            incomingLanguage: nil,
            existingLanguage: firstEnglishPartial.language.rawValue,
            meetingLanguage: "pt-BR",
            defaultLanguage: "pt-BR",
            isFinal: false,
            supplementalSignals: [LanguageContinuitySignal(languageCode: "en-US", confidence: 0.91, source: "spoken-lid-test")]
        )
        XCTAssertEqual(secondEnglishPartial.language, .englishUS)
        XCTAssertTrue(secondEnglishPartial.isTextDetected)
    }

    func testLanguageContinuityResolverPrefersSpokenSignalOverConflictingTextDetection() {
        var resolver = LanguageContinuityResolver()
        let english = resolver.resolve(
            text: "we are discussing the rollout plan",
            audioSource: .microphone,
            incomingLanguage: "en-US",
            existingLanguage: nil,
            meetingLanguage: "en-US",
            defaultLanguage: "en-US",
            isFinal: true
        )
        XCTAssertEqual(english.language, .englishUS)

        let conflictingText = resolver.resolve(
            text: "vamos revisar o escopo antes da demo",
            audioSource: .microphone,
            incomingLanguage: nil,
            existingLanguage: english.language.rawValue,
            meetingLanguage: "en-US",
            defaultLanguage: "en-US",
            isFinal: true,
            supplementalSignals: [LanguageContinuitySignal(languageCode: "en-US", confidence: 0.86, source: "spoken-lid-test")]
        )
        XCTAssertEqual(conflictingText.language, .englishUS)
        XCTAssertGreaterThanOrEqual(conflictingText.confidence, 0.86)
    }

    func testSpeechDetectionTimelineSuppressesConfirmedNonSpeechButLetsSpeechWin() {
        var timeline = SpeechDetectionTimeline()
        let oneSecond = CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 1_000))
        timeline.record(range: oneSecond, speechDetected: false)
        XCTAssertEqual(timeline.coverage(for: oneSecond), .nonSpeech)

        let speechIsland = CMTimeRange(start: CMTime(seconds: 0.25, preferredTimescale: 1_000), duration: CMTime(seconds: 0.25, preferredTimescale: 1_000))
        timeline.record(range: speechIsland, speechDetected: true)
        XCTAssertEqual(timeline.coverage(for: oneSecond), .speech)
    }

    func testASRStabilitySmootherRejectsShorterDraftRegressionAndLoops() {
        var smoother = ASRStabilitySmoother()
        let draft = segment(text: "hello world this is the stable partial", isFinal: false, start: 0, end: 2.8)
        XCTAssertEqual(smoother.observe(draft).count, 1)

        let regression = segment(id: draft.id, text: "hello world", isFinal: false)
        XCTAssertTrue(smoother.observe(regression).isEmpty)

        let shortFinal = segment(id: draft.id, text: "hello world this", isFinal: true, start: 0, end: 1.2)
        let promoted = smoother.observe(shortFinal)
        XCTAssertEqual(promoted.count, 1)
        XCTAssertEqual(promoted.first?.text, draft.text)
        XCTAssertTrue(promoted.first?.isFinal == true)
        XCTAssertEqual(promoted.first?.retentionReason, .appleDraftPromoted)
        XCTAssertEqual(promoted.first?.endTime, draft.endTime)

        let loop = segment(text: "thank you thank you thank you thank you thank you", isFinal: true)
        XCTAssertTrue(smoother.observe(loop).isEmpty)
    }

    func testTranscriptSegmentMergerPromotesLongDraftWhenShortFinalWouldEraseTail() {
        let merger = TranscriptSegmentMerger()
        let draft = segment(text: "we should keep the long draft tail", isFinal: false, start: 0, end: 3)
        let final = segment(id: draft.id, text: "we should keep", isFinal: true, start: 0, end: 1.2)

        let decision = merger.decision(for: final, in: [draft])
        guard case let .replace(_, replacement, tail) = decision else {
            return XCTFail("Expected replacement that keeps the fuller utterance in one visible transcript block")
        }
        XCTAssertTrue(replacement.isFinal)
        XCTAssertEqual(replacement.text, draft.text)
        XCTAssertEqual(replacement.retentionReason, .appleDraftPromoted)
        XCTAssertNil(tail)
    }

    func testRecentAudioWindowStoreScopesRefinerAudioToSegmentTimeRange() {
        let store = RecentAudioWindowStore(maxDuration: 9)
        let buffers = TranscriptionAudioFixtureGenerator.buffers(profile: .clean, chunks: 6)
        buffers.forEach(store.append)

        let final = segment(text: "scoped phrase", isFinal: true, start: 0.19, end: 0.31)
        let scoped = store.recentBuffers(overlapping: final, padding: 0.02)
        let sampleTimes = scoped.compactMap { $0.time?.sampleTime }

        XCTAssertEqual(sampleTimes, [1_600, 3_200, 4_800])
        XCTAssertLessThan(scoped.count, buffers.count)

        let expired = segment(text: "expired phrase", isFinal: true, start: 12, end: 13)
        XCTAssertTrue(store.recentBuffers(overlapping: expired, padding: 0.02).isEmpty)
    }

    func testRecentAudioWindowStoreMarksLowSourceAudioAsFirstAudio() {
        let systemStore = RecentAudioWindowStore(maxDuration: 9)
        systemStore.append(TranscriptionAudioFixtureGenerator.buffers(profile: .silence, source: .system, chunks: 1).first!)
        XCTAssertNil(systemStore.firstAudioAt())

        let lowSystemSamples = Array(repeating: Float(0.000080), count: 1_600)
        let lowSystem = TranscriptionAudioFixtureGenerator.buffer(samples: lowSystemSamples, source: .system, offset: 1)
        systemStore.append(lowSystem)
        XCTAssertEqual(systemStore.firstAudioAt(), lowSystem.createdAt)

        let microphoneStore = RecentAudioWindowStore(maxDuration: 9)
        microphoneStore.append(TranscriptionAudioFixtureGenerator.buffers(profile: .silence, source: .microphone, chunks: 1).first!)
        XCTAssertNil(microphoneStore.firstAudioAt())

        let lowMicrophoneSamples = Array(repeating: Float(0.000090), count: 1_600)
        let lowMicrophone = TranscriptionAudioFixtureGenerator.buffer(samples: lowMicrophoneSamples, source: .microphone, offset: 2)
        microphoneStore.append(lowMicrophone)
        XCTAssertEqual(microphoneStore.firstAudioAt(), lowMicrophone.createdAt)
    }

    func testRecentAudioWindowStorePreservesDurationWindowForSmallChunks() {
        let store = RecentAudioWindowStore(maxDuration: 3)

        for offset in 0..<520 {
            let samples = Array(repeating: Float(0.00012), count: 160)
            let buffer = TranscriptionAudioFixtureGenerator.buffer(samples: samples, source: .system, offset: offset)
            store.append(buffer)
        }

        let buffers = store.recentBuffers()
        XCTAssertGreaterThanOrEqual(buffers.count, 295)
        XCTAssertLessThanOrEqual(buffers.count, 324)
        XCTAssertEqual(store.firstAudioAt(), Date(timeIntervalSinceReferenceDate: 0))
    }

    func testSpeechVocabularyBiasProviderBuildsRankedAppleAndWhisperContext() {
        var preferences = AppPreferences()
        preferences.userDisplayName = "Larissa"
        preferences.userNicknames = "Lari"
        let meeting = MeetingSession(
            id: UUID(),
            title: "Notchly SpeechAnalyzer Core ML review",
            source: .manual,
            startedAt: Date(),
            status: .listening,
            primaryLanguage: "pt-BR",
            meetingType: .engineering
        )

        let provider = SpeechVocabularyBiasProvider()
        let context = provider.context(for: meeting, preferences: preferences, store: nil)
        let contextualStrings = context.contextualStrings.joined(separator: " ")
        XCTAssertTrue(contextualStrings.contains("Notchly"))
        XCTAssertTrue(contextualStrings.contains("SpeechAnalyzer"))
        XCTAssertTrue(provider.whisperPrompt(for: context).contains("Notchly"))
    }

    func testTranscriptionMetricsCapturesBenchmarkAndLatencyThresholds() async {
        await TranscriptionMetrics.shared.reset()
        let fixtureCase = TranscriptionBenchmarkCase(
            id: "jargon-recall",
            reference: "Notchly uses SpeechAnalyzer and Core ML",
            hypothesis: "Notchly uses SpeechAnalyzer and Core ML",
            locale: "en-US",
            activeVocabulary: ["Notchly", "SpeechAnalyzer", "Core ML"],
            namedEntities: ["Notchly"],
            firstPartialLatencyMs: 320,
            finalLatencyMs: 980,
            audioDurationMs: 2_000,
            processingDurationMs: 760,
            languageSwitchLatencyMs: 180
        )
        await TranscriptionMetrics.shared.recordBenchmarkCases([fixtureCase])
        var finalSegment = segment(text: fixtureCase.hypothesis, isFinal: true)
        finalSegment.latencyMs = 980
        await TranscriptionMetrics.shared.recordSegment(finalSegment)

        let snapshot = await TranscriptionMetrics.shared.snapshot()
        XCTAssertEqual(snapshot.benchmarkResults.first?.wordErrorRate, 0)
        XCTAssertEqual(snapshot.benchmarkResults.first?.vocabularyRecognitionRate, 1)
        XCTAssertEqual(snapshot.benchmarkResults.first?.namedEntityRecognitionRate, 1)
        XCTAssertTrue(snapshot.benchmarkResults.first?.passedQualityGate ?? false)
        XCTAssertEqual(snapshot.benchmarkSummary.passedCaseCount, 1)
        XCTAssertEqual(snapshot.benchmarkSummary.realTimeFactorP95 ?? -1, 0.38, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(snapshot.finalStabilizationLatency.p95 ?? 9_999, 1_500)
        XCTAssertGreaterThan(snapshot.memoryResidentBytes ?? 0, 0)
        XCTAssertGreaterThanOrEqual(snapshot.cpuUsagePercent ?? -1, 0)
    }

    func testTranscriptionBenchmarkSuiteShowsRefinedJargonImprovesBaseline() {
        let suite = TranscriptionBenchmarkSuite()
        let reference = "Notchly uses SpeechAnalyzer and Core ML for local transcription"
        let baseline = suite.evaluate([
            TranscriptionBenchmarkCase(
                id: "baseline",
                reference: reference,
                hypothesis: "Notchley uses speech analyzer and core mail for local transcription",
                locale: "en-US",
                activeVocabulary: ["Notchly", "SpeechAnalyzer", "Core ML"],
                namedEntities: ["Notchly"],
                firstPartialLatencyMs: 420,
                finalLatencyMs: 1_250,
                audioDurationMs: 2_400,
                processingDurationMs: 1_100
            )
        ]).first!
        let refined = suite.evaluate([
            TranscriptionBenchmarkCase(
                id: "refined",
                reference: reference,
                hypothesis: reference,
                locale: "en-US",
                activeVocabulary: ["Notchly", "SpeechAnalyzer", "Core ML"],
                namedEntities: ["Notchly"],
                firstPartialLatencyMs: 420,
                finalLatencyMs: 1_340,
                audioDurationMs: 2_400,
                processingDurationMs: 1_260
            )
        ]).first!

        XCTAssertGreaterThan(baseline.wordErrorRate, refined.wordErrorRate)
        XCTAssertGreaterThan(baseline.characterErrorRate, refined.characterErrorRate)
        XCTAssertLessThan(baseline.vocabularyRecognitionRate, refined.vocabularyRecognitionRate)
        XCTAssertLessThan(baseline.namedEntityRecognitionRate, refined.namedEntityRecognitionRate)
        XCTAssertFalse(baseline.passedQualityGate)
        XCTAssertTrue(refined.passedQualityGate)
    }

    func testTranscriptionBenchmarkSuiteRejectsImpossibleLatencyAndResourceMetrics() {
        let suite = TranscriptionBenchmarkSuite()
        let invalid = suite.evaluate([
            TranscriptionBenchmarkCase(
                id: "invalid-metrics",
                reference: "metrics must be plausible",
                hypothesis: "metrics must be plausible",
                locale: "en-US",
                firstPartialLatencyMs: 900,
                finalLatencyMs: 120,
                audioDurationMs: 2_000,
                processingDurationMs: 600,
                languageSwitchLatencyMs: -.infinity,
                memoryResidentBytes: 0,
                cpuUsagePercent: .nan
            )
        ]).first!

        XCTAssertFalse(invalid.passedQualityGate)
        XCTAssertTrue(invalid.failedGates.contains("final_latency_before_first_partial"))
        XCTAssertTrue(invalid.failedGates.contains("invalid_language_switch_latency"))
        XCTAssertTrue(invalid.failedGates.contains("invalid_memory_resident_bytes"))
        XCTAssertTrue(invalid.failedGates.contains("invalid_cpu_usage_percent"))
    }

    func testTranscriptionBenchmarkComparatorRequiresMeasurablePrecisionAndJargonLift() throws {
        let reference = "Notchly uses SpeechAnalyzer and Core ML for local transcription"
        let evidenceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchly-comparator-lift-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidenceDirectory) }
        let audioSHA256 = String(repeating: "c", count: 64)
        let baselineHypothesis = "Notchley uses speech analyzer and core mail for local transcription"
        let baselineEvidence = try Self.releaseGateHypothesisEvidence(
            id: "jargon-lift",
            hypothesis: baselineHypothesis,
            source: .speechAnalyzer,
            locale: "en-US",
            engineIdentifier: "notchly-speechanalyzer-baseline",
            runID: "comparator-baseline-run",
            audioSHA256: audioSHA256,
            audioDurationMs: 2_400,
            audioSource: .microphone,
            directory: evidenceDirectory.appendingPathComponent("baseline", isDirectory: true)
        )
        let candidateEvidence = try Self.releaseGateHypothesisEvidence(
            id: "jargon-lift",
            hypothesis: reference,
            source: .whisperKit,
            locale: "en-US",
            engineIdentifier: "WhisperKit/distil-large-v3",
            runID: "comparator-candidate-run",
            audioSHA256: audioSHA256,
            audioDurationMs: 2_400,
            audioSource: .microphone,
            directory: evidenceDirectory.appendingPathComponent("candidate", isDirectory: true)
        )
        let baselineCase = TranscriptionBenchmarkCase(
            id: "jargon-lift",
            audioSource: .microphone,
            reference: reference,
            hypothesis: baselineHypothesis,
            locale: "en-US",
            activeVocabulary: ["Notchly", "SpeechAnalyzer", "Core ML"],
            namedEntities: ["Notchly"],
            audioSHA256: audioSHA256,
            hypothesisSource: baselineEvidence.source,
            hypothesisEngineIdentifier: baselineEvidence.engineIdentifier,
            hypothesisRunID: baselineEvidence.runID,
            hypothesisTranscriptFilePath: baselineEvidence.path,
            hypothesisTranscriptSHA256: baselineEvidence.sha256,
            firstPartialLatencyMs: 420,
            finalLatencyMs: 1_250,
            audioDurationMs: 2_400,
            processingDurationMs: 1_100
        )
        let candidateCase = TranscriptionBenchmarkCase(
            id: "jargon-lift",
            audioSource: .microphone,
            reference: reference,
            hypothesis: reference,
            locale: "en-US",
            activeVocabulary: ["Notchly", "SpeechAnalyzer", "Core ML"],
            namedEntities: ["Notchly"],
            audioSHA256: audioSHA256,
            hypothesisSource: candidateEvidence.source,
            hypothesisEngineIdentifier: candidateEvidence.engineIdentifier,
            hypothesisRunID: candidateEvidence.runID,
            hypothesisTranscriptFilePath: candidateEvidence.path,
            hypothesisTranscriptSHA256: candidateEvidence.sha256,
            firstPartialLatencyMs: 410,
            finalLatencyMs: 1_280,
            audioDurationMs: 2_400,
            processingDurationMs: 1_140
        )

        let report = TranscriptionBenchmarkComparator().compare(
            baseline: [baselineCase],
            candidate: [candidateCase]
        )

        XCTAssertTrue(report.passed, report.failures.joined(separator: ", "))
        XCTAssertGreaterThan(report.comparisonSummary.averageWordErrorRateReduction, 0)
        XCTAssertGreaterThan(report.comparisonSummary.averageCharacterErrorRateReduction, 0)
        XCTAssertGreaterThan(report.comparisonSummary.averageVocabularyRecallDelta, 0)
        XCTAssertGreaterThan(report.comparisonSummary.averageNamedEntityRecallDelta, 0)
        XCTAssertEqual(report.comparisonSummary.improvedWordErrorRateCaseCount, 1)
        XCTAssertEqual(report.comparisonSummary.improvedVocabularyRecallCaseCount, 1)
    }

    func testTranscriptionBenchmarkComparatorRejectsNoMeasurableImprovementAgainstBaseline() {
        let reference = "Notchly uses SpeechAnalyzer and Core ML for local transcription"
        let unchanged = TranscriptionBenchmarkCase(
            id: "unchanged-jargon",
            reference: reference,
            hypothesis: "Notchley uses speech analyzer and core mail for local transcription",
            locale: "en-US",
            activeVocabulary: ["Notchly", "SpeechAnalyzer", "Core ML"],
            namedEntities: ["Notchly"],
            firstPartialLatencyMs: 420,
            finalLatencyMs: 1_250,
            audioDurationMs: 2_400,
            processingDurationMs: 1_100
        )

        let report = TranscriptionBenchmarkComparator().compare(
            baseline: [unchanged],
            candidate: [unchanged]
        )

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.failures.contains { $0.hasPrefix("insufficient_average_word_error_rate_reduction:") })
        XCTAssertTrue(report.failures.contains { $0.hasPrefix("insufficient_average_character_error_rate_reduction:") })
        XCTAssertTrue(report.failures.contains { $0.hasPrefix("insufficient_average_vocabulary_recall_improvement:") })
        XCTAssertTrue(report.failures.contains { $0.hasPrefix("insufficient_average_named_entity_recall_improvement:") })
    }

    func testTranscriptionBenchmarkComparatorRejectsMismatchedCaseIdentity() {
        let baselineCase = TranscriptionBenchmarkCase(
            id: "identity-case",
            audioSource: .system,
            reference: "ship Notchly Core ML",
            hypothesis: "ship Notchly Core ML",
            locale: "en-US",
            activeVocabulary: ["Core ML"],
            namedEntities: ["Notchly"],
            corpus: .ami,
            evaluationTags: [.meeting],
            audioSHA256: String(repeating: "a", count: 64),
            audioDurationMs: 1_000,
            processingDurationMs: 500
        )
        let candidateCase = TranscriptionBenchmarkCase(
            id: "identity-case",
            audioSource: .microphone,
            reference: "publique Notchly Metal",
            hypothesis: "publique Notchly Metal",
            locale: "pt-BR",
            activeVocabulary: ["Metal"],
            namedEntities: ["Metal"],
            corpus: .fleurs,
            evaluationTags: [.multilingual],
            audioSHA256: String(repeating: "b", count: 64),
            audioDurationMs: 2_000,
            processingDurationMs: 500
        )

        let report = TranscriptionBenchmarkComparator().compare(
            baseline: [baselineCase],
            candidate: [candidateCase]
        )

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.failures.contains("reference_mismatch:identity-case"))
        XCTAssertTrue(report.failures.contains("locale_mismatch:identity-case"))
        XCTAssertTrue(report.failures.contains("corpus_mismatch:identity-case"))
        XCTAssertTrue(report.failures.contains("evaluation_tags_mismatch:identity-case"))
        XCTAssertTrue(report.failures.contains("active_vocabulary_mismatch:identity-case"))
        XCTAssertTrue(report.failures.contains("named_entities_mismatch:identity-case"))
        XCTAssertTrue(report.failures.contains("audio_source_mismatch:identity-case"))
        XCTAssertTrue(report.failures.contains("audio_checksum_mismatch:identity-case"))
        XCTAssertTrue(report.failures.contains("audio_duration_mismatch:identity-case"))
    }

    func testTranscriptionBenchmarkComparatorRequiresSymmetricAudioIdentityEvidenceForTopTierLift() {
        let reference = "Notchly preserves SpeechAnalyzer jargon"
        let baselineCase = TranscriptionBenchmarkCase(
            id: "missing-audio-identity",
            reference: reference,
            hypothesis: "Notchley preserves speech analyzer jargon",
            locale: "en-US",
            activeVocabulary: ["Notchly", "SpeechAnalyzer"],
            namedEntities: ["Notchly"],
            audioDurationMs: 1_800,
            processingDurationMs: 900
        )
        let candidateCase = TranscriptionBenchmarkCase(
            id: "missing-audio-identity",
            audioSource: .mixed,
            reference: reference,
            hypothesis: reference,
            locale: "en-US",
            activeVocabulary: ["Notchly", "SpeechAnalyzer"],
            namedEntities: ["Notchly"],
            audioSHA256: String(repeating: "d", count: 64),
            processingDurationMs: 900
        )

        let report = TranscriptionBenchmarkComparator().compare(
            baseline: [baselineCase],
            candidate: [candidateCase]
        )

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.failures.contains("missing_baseline_audio_source:missing-audio-identity"))
        XCTAssertTrue(report.failures.contains("invalid_candidate_audio_source:missing-audio-identity"))
        XCTAssertTrue(report.failures.contains("missing_baseline_audio_checksum:missing-audio-identity"))
        XCTAssertTrue(report.failures.contains("missing_candidate_audio_duration:missing-audio-identity"))
        XCTAssertGreaterThan(report.comparisonSummary.averageWordErrorRateReduction, 0)
    }

    func testTranscriptionBenchmarkComparatorRequiresSymmetricHypothesisEvidenceForTopTierLift() throws {
        let reference = "Notchly keeps Core ML and SpeechAnalyzer terms"
        let evidenceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchly-comparator-hypothesis-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidenceDirectory) }
        let audioSHA256 = String(repeating: "e", count: 64)
        let candidateEvidence = try Self.releaseGateHypothesisEvidence(
            id: "missing-hypothesis-evidence",
            hypothesis: reference,
            source: .manual,
            locale: "en-US",
            engineIdentifier: "manual-entry",
            runID: "manual-candidate-run",
            audioSHA256: audioSHA256,
            audioDurationMs: 2_100,
            audioSource: .system,
            directory: evidenceDirectory.appendingPathComponent("candidate", isDirectory: true)
        )
        let baselineCase = TranscriptionBenchmarkCase(
            id: "missing-hypothesis-evidence",
            audioSource: .system,
            reference: reference,
            hypothesis: "Notchley keeps core mail and speech analyzer terms",
            locale: "en-US",
            activeVocabulary: ["Notchly", "Core ML", "SpeechAnalyzer"],
            namedEntities: ["Notchly"],
            audioSHA256: audioSHA256,
            audioDurationMs: 2_100,
            processingDurationMs: 900
        )
        let candidateCase = TranscriptionBenchmarkCase(
            id: "missing-hypothesis-evidence",
            audioSource: .system,
            reference: reference,
            hypothesis: reference,
            locale: "en-US",
            activeVocabulary: ["Notchly", "Core ML", "SpeechAnalyzer"],
            namedEntities: ["Notchly"],
            audioSHA256: audioSHA256,
            hypothesisSource: candidateEvidence.source,
            hypothesisEngineIdentifier: candidateEvidence.engineIdentifier,
            hypothesisRunID: candidateEvidence.runID,
            hypothesisTranscriptFilePath: candidateEvidence.path,
            hypothesisTranscriptSHA256: candidateEvidence.sha256,
            audioDurationMs: 2_100,
            processingDurationMs: 900
        )

        let report = TranscriptionBenchmarkComparator().compare(
            baseline: [baselineCase],
            candidate: [candidateCase]
        )

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.failures.contains("missing_baseline_hypothesis_source:missing-hypothesis-evidence"))
        XCTAssertTrue(report.failures.contains("missing_baseline_hypothesis_engine:missing-hypothesis-evidence"))
        XCTAssertTrue(report.failures.contains("missing_baseline_hypothesis_run_id:missing-hypothesis-evidence"))
        XCTAssertTrue(report.failures.contains("missing_baseline_hypothesis_transcript_file:missing-hypothesis-evidence"))
        XCTAssertTrue(report.failures.contains("missing_baseline_hypothesis_transcript_checksum:missing-hypothesis-evidence"))
        XCTAssertTrue(report.failures.contains("unsupported_candidate_hypothesis_source:manual:missing-hypothesis-evidence"))
        XCTAssertGreaterThan(report.comparisonSummary.averageWordErrorRateReduction, 0)
    }

    func testTranscriptionBenchmarkComparatorRejectsEvaluationReplayBaselineForExternalCorpusLift() throws {
        let reference = "AMI evaluation should prove source-separated meeting speech"
        let evidenceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchly-comparator-external-baseline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidenceDirectory) }
        let audioSHA256 = String(repeating: "f", count: 64)
        let provenance = Self.publicCorpusProvenance(.ami, sampleID: "external-baseline-replay")
        let baselineHypothesis = "AMI evaluation should prove meeting speech"
        let baselineEvidence = try Self.releaseGateHypothesisEvidence(
            id: "external-baseline-replay",
            hypothesis: baselineHypothesis,
            source: .evaluationReplay,
            locale: "en-US",
            engineIdentifier: "notchly-evaluation-replay",
            runID: "external-baseline-replay-run",
            audioSHA256: audioSHA256,
            audioDurationMs: 3_200,
            audioSource: .system,
            corpusProvenance: provenance,
            directory: evidenceDirectory.appendingPathComponent("baseline", isDirectory: true)
        )
        let candidateEvidence = try Self.releaseGateHypothesisEvidence(
            id: "external-baseline-replay",
            hypothesis: reference,
            source: .speechAnalyzer,
            locale: "en-US",
            engineIdentifier: "notchly-speechanalyzer-candidate",
            runID: "external-candidate-run",
            audioSHA256: audioSHA256,
            audioDurationMs: 3_200,
            audioSource: .system,
            corpusProvenance: provenance,
            directory: evidenceDirectory.appendingPathComponent("candidate", isDirectory: true)
        )
        let baselineCase = TranscriptionBenchmarkCase(
            id: "external-baseline-replay",
            audioSource: .system,
            reference: reference,
            hypothesis: baselineHypothesis,
            locale: "en-US",
            activeVocabulary: ["source-separated"],
            corpus: .ami,
            evaluationTags: [.meeting, .farField],
            evidenceKind: .publicCorpus,
            audioSHA256: audioSHA256,
            corpusProvenance: provenance,
            hypothesisSource: baselineEvidence.source,
            hypothesisEngineIdentifier: baselineEvidence.engineIdentifier,
            hypothesisRunID: baselineEvidence.runID,
            hypothesisTranscriptFilePath: baselineEvidence.path,
            hypothesisTranscriptSHA256: baselineEvidence.sha256,
            firstPartialLatencyMs: 430,
            finalLatencyMs: 1_300,
            audioDurationMs: 3_200,
            processingDurationMs: 1_100
        )
        let candidateCase = TranscriptionBenchmarkCase(
            id: "external-baseline-replay",
            audioSource: .system,
            reference: reference,
            hypothesis: reference,
            locale: "en-US",
            activeVocabulary: ["source-separated"],
            corpus: .ami,
            evaluationTags: [.meeting, .farField],
            evidenceKind: .publicCorpus,
            audioSHA256: audioSHA256,
            corpusProvenance: provenance,
            hypothesisSource: candidateEvidence.source,
            hypothesisEngineIdentifier: candidateEvidence.engineIdentifier,
            hypothesisRunID: candidateEvidence.runID,
            hypothesisTranscriptFilePath: candidateEvidence.path,
            hypothesisTranscriptSHA256: candidateEvidence.sha256,
            firstPartialLatencyMs: 390,
            finalLatencyMs: 1_150,
            audioDurationMs: 3_200,
            processingDurationMs: 1_000
        )

        let report = TranscriptionBenchmarkComparator().compare(
            baseline: [baselineCase],
            candidate: [candidateCase]
        )

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.failures.contains("unsupported_baseline_hypothesis_source:evaluation-replay:external-baseline-replay"))
        XCTAssertGreaterThan(report.comparisonSummary.averageWordErrorRateReduction, 0)
    }

    func testTranscriptionBenchmarkComparatorRequiresExternalCorpusProvenanceForTopTierLift() throws {
        let reference = "AMI provenance must bind the baseline transcript"
        let evidenceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchly-comparator-external-provenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidenceDirectory) }
        let audioSHA256 = String(repeating: "1", count: 64)
        let candidateProvenance = Self.publicCorpusProvenance(.ami, sampleID: "ami-provenance-candidate")
        let baselineHypothesis = "AMI provenance must bind transcript"
        let baselineEvidence = try Self.releaseGateHypothesisEvidence(
            id: "external-provenance",
            hypothesis: baselineHypothesis,
            source: .speechAnalyzer,
            locale: "en-US",
            engineIdentifier: "notchly-speechanalyzer-baseline",
            runID: "missing-provenance-baseline-run",
            audioSHA256: audioSHA256,
            audioDurationMs: 3_200,
            audioSource: .system,
            directory: evidenceDirectory.appendingPathComponent("baseline", isDirectory: true)
        )
        let candidateEvidence = try Self.releaseGateHypothesisEvidence(
            id: "external-provenance",
            hypothesis: reference,
            source: .speechAnalyzer,
            locale: "en-US",
            engineIdentifier: "notchly-speechanalyzer-candidate",
            runID: "provenance-candidate-run",
            audioSHA256: audioSHA256,
            audioDurationMs: 3_200,
            audioSource: .system,
            corpusProvenance: candidateProvenance,
            directory: evidenceDirectory.appendingPathComponent("candidate", isDirectory: true)
        )
        let baselineCase = TranscriptionBenchmarkCase(
            id: "external-provenance",
            audioSource: .system,
            reference: reference,
            hypothesis: baselineHypothesis,
            locale: "en-US",
            activeVocabulary: ["AMI"],
            corpus: .ami,
            evaluationTags: [.meeting, .farField],
            evidenceKind: .publicCorpus,
            audioSHA256: audioSHA256,
            hypothesisSource: baselineEvidence.source,
            hypothesisEngineIdentifier: baselineEvidence.engineIdentifier,
            hypothesisRunID: baselineEvidence.runID,
            hypothesisTranscriptFilePath: baselineEvidence.path,
            hypothesisTranscriptSHA256: baselineEvidence.sha256,
            firstPartialLatencyMs: 430,
            finalLatencyMs: 1_300,
            audioDurationMs: 3_200,
            processingDurationMs: 1_100
        )
        let candidateCase = TranscriptionBenchmarkCase(
            id: "external-provenance",
            audioSource: .system,
            reference: reference,
            hypothesis: reference,
            locale: "en-US",
            activeVocabulary: ["AMI"],
            corpus: .ami,
            evaluationTags: [.meeting, .farField],
            evidenceKind: .publicCorpus,
            audioSHA256: audioSHA256,
            corpusProvenance: candidateProvenance,
            hypothesisSource: candidateEvidence.source,
            hypothesisEngineIdentifier: candidateEvidence.engineIdentifier,
            hypothesisRunID: candidateEvidence.runID,
            hypothesisTranscriptFilePath: candidateEvidence.path,
            hypothesisTranscriptSHA256: candidateEvidence.sha256,
            firstPartialLatencyMs: 390,
            finalLatencyMs: 1_150,
            audioDurationMs: 3_200,
            processingDurationMs: 1_000
        )

        let report = TranscriptionBenchmarkComparator().compare(
            baseline: [baselineCase],
            candidate: [candidateCase]
        )

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.failures.contains("missing_baseline_corpus_provenance:external-provenance"))
        XCTAssertTrue(report.failures.contains("missing_baseline_hypothesis_corpus_provenance_reference:external-provenance"))
        XCTAssertGreaterThan(report.comparisonSummary.averageWordErrorRateReduction, 0)
    }

    func testTranscriptionBenchmarkComparatorRejectsPerCaseRegressionEvenWhenAggregateCouldHideIt() {
        let strongCase = TranscriptionBenchmarkCase(
            id: "regressed-case",
            reference: "ship the Notchly Core ML transcript",
            hypothesis: "ship the Notchly Core ML transcript",
            locale: "en-US",
            activeVocabulary: ["Notchly", "Core ML"],
            namedEntities: ["Notchly"],
            firstPartialLatencyMs: 390,
            finalLatencyMs: 1_100,
            audioDurationMs: 2_000,
            processingDurationMs: 900
        )
        let regressedCase = TranscriptionBenchmarkCase(
            id: "regressed-case",
            reference: "ship the Notchly Core ML transcript",
            hypothesis: "ship the notch lee core mail transcript",
            locale: "en-US",
            activeVocabulary: ["Notchly", "Core ML"],
            namedEntities: ["Notchly"],
            firstPartialLatencyMs: 390,
            finalLatencyMs: 1_100,
            audioDurationMs: 2_000,
            processingDurationMs: 900
        )

        let report = TranscriptionBenchmarkComparator().compare(
            baseline: [strongCase],
            candidate: [regressedCase]
        )

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.failures.contains("word_error_rate_regression:regressed-case"))
        XCTAssertTrue(report.failures.contains("character_error_rate_regression:regressed-case"))
        XCTAssertTrue(report.failures.contains("vocabulary_recall_regression:regressed-case"))
        XCTAssertTrue(report.failures.contains("named_entity_recall_regression:regressed-case"))
    }

    func testTranscriptionReleaseGateRequiresExternalCorporaBeforeTopTierClaim() {
        let report = TranscriptionReleaseGate().evaluate(cases: [
            TranscriptionBenchmarkCase(
                id: "critical-silence",
                reference: "",
                hypothesis: "phantom words",
                locale: "en-US",
                corpus: .internalCritical,
                evaluationTags: [.criticalNonSpeech, .silence]
            )
        ])

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.failures.contains("missing_corpus:ami"))
        XCTAssertTrue(report.failures.contains("missing_corpus:fleurs"))
        XCTAssertTrue(report.failures.contains("missing_corpus:voxlingua107"))
        XCTAssertTrue(report.failures.contains("missing_corpus:earnings21"))
        XCTAssertTrue(report.failures.contains("missing_corpus:conec"))
        XCTAssertTrue(report.failures.contains("missing_locale:pt-BR"))
        XCTAssertTrue(report.failures.contains("critical_non_speech_false_text:critical-silence"))
        XCTAssertTrue(report.failures.contains("unsupported_evidence_kind:critical-silence:synthetic"))
        XCTAssertTrue(report.failures.contains("missing_audio_file:critical-silence"))
        XCTAssertTrue(report.failures.contains("missing_audio_checksum:critical-silence"))
    }

    func testTranscriptionReleaseGateRejectsMissingCriticalNonSpeechProfiles() throws {
        let evidenceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchly-critical-profile-coverage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidenceDirectory) }
        let audioEvidence = try Self.releaseGateAudioFixtureEvidence(
            id: "internal-critical-silence-only",
            profile: .silence,
            kind: .generatedFixture,
            directory: evidenceDirectory,
            durationMs: 1_000
        )
        let transcriptEvidence = try Self.releaseGateHypothesisEvidence(
            id: "internal-critical-silence-only",
            hypothesis: "",
            source: .evaluationReplay,
            locale: "en-US",
            engineIdentifier: "notchly-evaluation-replay",
            runID: "critical-coverage-run",
            audioSHA256: audioEvidence.sha256,
            audioDurationMs: 1_000,
            directory: evidenceDirectory
        )

        var policy = TranscriptionReleaseGatePolicy.topTierRelease
        policy.requiredCorpora = [.internalCritical]
        policy.requiredLocales = ["en-US"]
        policy.requiredTags = [.criticalNonSpeech, .silence, .clicks, .music, .breathing, .noise]

        let report = TranscriptionReleaseGate().evaluate(
            cases: [
                TranscriptionBenchmarkCase(
                    id: "internal-critical-silence-only",
                    audioFilePath: audioEvidence.path,
                    reference: "",
                    hypothesis: "",
                    locale: "en-US",
                    corpus: .internalCritical,
                    evaluationTags: [.criticalNonSpeech, .silence],
                    evidenceKind: audioEvidence.kind,
                    audioSHA256: audioEvidence.sha256,
                    hypothesisSource: transcriptEvidence.source,
                    hypothesisEngineIdentifier: transcriptEvidence.engineIdentifier,
                    hypothesisRunID: transcriptEvidence.runID,
                    hypothesisTranscriptFilePath: transcriptEvidence.path,
                    hypothesisTranscriptSHA256: transcriptEvidence.sha256,
                    audioDurationMs: 1_000
                )
            ],
            policy: policy
        )

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.failures.contains("missing_tag:clicks"))
        XCTAssertTrue(report.failures.contains("missing_tag:music"))
        XCTAssertTrue(report.failures.contains("missing_tag:breathing"))
        XCTAssertTrue(report.failures.contains("missing_tag:noise"))
    }

    func testTranscriptionReleaseGateRejectsMissingHardSpeechProfiles() throws {
        let evidenceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchly-hard-speech-profile-coverage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidenceDirectory) }
        let audioEvidence = try Self.releaseGateAudioFixtureEvidence(
            id: "private-code-switch-no-profile-tags",
            profile: .clean,
            kind: .privateCorpus,
            directory: evidenceDirectory,
            durationMs: 2_000
        )
        let transcriptEvidence = try Self.releaseGateHypothesisEvidence(
            id: "private-code-switch-no-profile-tags",
            hypothesis: "vamos validar SpeechAnalyzer com Core ML",
            source: .importedASR,
            locale: "pt-BR",
            engineIdentifier: "notchly-imported-asr-evaluation",
            runID: "hard-speech-coverage-run",
            audioSHA256: audioEvidence.sha256,
            audioDurationMs: 2_000,
            directory: evidenceDirectory
        )

        var policy = TranscriptionReleaseGatePolicy.topTierRelease
        policy.requiredCorpora = [.privateMeetingPack]
        policy.requiredLocales = ["pt-BR"]
        policy.requiredTags = [.meeting, .multilingual, .codeSwitching, .jargon, .noise, .lowVolume, .reverb, .clipping]

        let report = TranscriptionReleaseGate().evaluate(
            cases: [
                TranscriptionBenchmarkCase(
                    id: "private-code-switch-no-profile-tags",
                    audioFilePath: audioEvidence.path,
                    reference: "vamos validar SpeechAnalyzer com Core ML",
                    hypothesis: "vamos validar SpeechAnalyzer com Core ML",
                    locale: "pt-BR",
                    activeVocabulary: ["SpeechAnalyzer", "Core ML"],
                    namedEntities: ["SpeechAnalyzer"],
                    corpus: .privateMeetingPack,
                    evaluationTags: [.meeting, .multilingual, .codeSwitching, .jargon],
                    evidenceKind: audioEvidence.kind,
                    audioSHA256: audioEvidence.sha256,
                    hypothesisSource: transcriptEvidence.source,
                    hypothesisEngineIdentifier: transcriptEvidence.engineIdentifier,
                    hypothesisRunID: transcriptEvidence.runID,
                    hypothesisTranscriptFilePath: transcriptEvidence.path,
                    hypothesisTranscriptSHA256: transcriptEvidence.sha256,
                    firstPartialLatencyMs: 320,
                    finalLatencyMs: 1_000,
                    audioDurationMs: 2_000,
                    processingDurationMs: 700,
                    languageSwitchLatencyMs: 250
                )
            ],
            policy: policy
        )

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.failures.contains("missing_tag:noise"))
        XCTAssertTrue(report.failures.contains("missing_tag:low-volume"))
        XCTAssertTrue(report.failures.contains("missing_tag:reverb"))
        XCTAssertTrue(report.failures.contains("missing_tag:clipping"))
    }

    func testTranscriptionReleaseGateRejectsInsufficientCorpusCaseCount() {
        var policy = TranscriptionReleaseGatePolicy.topTierRelease
        policy.requiredCorpora = [.ami]
        policy.requiredLocales = ["en-US"]
        policy.requiredTags = [.meeting]
        policy.minimumCaseCountsByCorpus = [.ami: 2]
        policy.requiredLocalesByCorpus = [:]
        policy.requiredTagsByCorpus = [:]
        policy.requireAudioEvidenceForRequiredCorpora = false
        policy.requireASRHypothesisEvidenceForRequiredCorpora = false
        policy.requireCorpusProvenanceForExternalCorpora = false

        let report = TranscriptionReleaseGate().evaluate(
            cases: [
                TranscriptionBenchmarkCase(
                    id: "ami-single-sample",
                    reference: "one sample is not enough to certify a corpus",
                    hypothesis: "one sample is not enough to certify a corpus",
                    locale: "en-US",
                    corpus: .ami,
                    evaluationTags: [.meeting],
                    firstPartialLatencyMs: 410,
                    finalLatencyMs: 1_200,
                    audioDurationMs: 3_000,
                    processingDurationMs: 1_000
                )
            ],
            policy: policy
        )

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.failures.contains("missing_corpus:ami"))
        XCTAssertTrue(report.failures.contains("insufficient_corpus_case_count:ami:1/2"))
    }

    func testTranscriptionReleaseGateRejectsDuplicateSamplesAndInsufficientCorpusDuration() {
        var policy = TranscriptionReleaseGatePolicy.topTierRelease
        policy.requiredCorpora = [.ami]
        policy.requiredLocales = ["en-US"]
        policy.requiredTags = [.meeting]
        policy.minimumCaseCountsByCorpus = [.ami: 2]
        policy.minimumUniqueSampleCountsByCorpus = [.ami: 2]
        policy.minimumUniqueAudioChecksumCountsByCorpus = [.ami: 2]
        policy.minimumTotalAudioDurationMsByCorpus = [.ami: 10_000]
        policy.requiredLocalesByCorpus = [:]
        policy.requiredTagsByCorpus = [:]
        policy.requireAudioEvidenceForRequiredCorpora = false
        policy.requireASRHypothesisEvidenceForRequiredCorpora = false
        policy.requireCorpusProvenanceForExternalCorpora = false

        let repeatedChecksum = String(repeating: "a", count: 64)
        let repeatedProvenance = Self.publicCorpusProvenance(.ami, sampleID: "ami-duplicate-sample")
        let cases = [
            TranscriptionBenchmarkCase(
                id: "ami-duplicate-sample-a",
                reference: "this duplicated sample should not certify release quality",
                hypothesis: "this duplicated sample should not certify release quality",
                locale: "en-US",
                corpus: .ami,
                evaluationTags: [.meeting],
                audioSHA256: repeatedChecksum,
                corpusProvenance: repeatedProvenance,
                firstPartialLatencyMs: 410,
                finalLatencyMs: 1_200,
                audioDurationMs: 2_500,
                processingDurationMs: 900
            ),
            TranscriptionBenchmarkCase(
                id: "ami-duplicate-sample-b",
                reference: "this duplicated sample should not certify release quality either",
                hypothesis: "this duplicated sample should not certify release quality either",
                locale: "en-US",
                corpus: .ami,
                evaluationTags: [.meeting],
                audioSHA256: repeatedChecksum,
                corpusProvenance: repeatedProvenance,
                firstPartialLatencyMs: 420,
                finalLatencyMs: 1_250,
                audioDurationMs: 2_500,
                processingDurationMs: 950
            )
        ]

        let report = TranscriptionReleaseGate().evaluate(cases: cases, policy: policy)

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.failures.contains("insufficient_corpus_unique_sample_count:ami:1/2"))
        XCTAssertTrue(report.failures.contains("insufficient_corpus_unique_audio_checksum_count:ami:1/2"))
        XCTAssertTrue(report.failures.contains("insufficient_corpus_audio_duration:ami:5000/10000"))
        XCTAssertEqual(report.coverage.first?.uniqueSampleCount, 1)
        XCTAssertEqual(report.coverage.first?.uniqueAudioChecksumCount, 1)
        XCTAssertEqual(report.coverage.first?.totalAudioDurationMs, 5_000)
    }

    func testTranscriptionReleaseGateRejectsCorpusSpecificLocaleAndTagGaps() {
        var policy = TranscriptionReleaseGatePolicy.topTierRelease
        policy.requiredCorpora = [.fleurs]
        policy.requiredLocales = ["en-US", "es-ES"]
        policy.requiredTags = [.meeting, .multilingual]
        policy.minimumCaseCountsByCorpus = [:]
        policy.requiredLocalesByCorpus = [.fleurs: ["en-US", "es-ES"]]
        policy.requiredTagsByCorpus = [.fleurs: [.meeting, .multilingual]]
        policy.requireAudioEvidenceForRequiredCorpora = false
        policy.requireASRHypothesisEvidenceForRequiredCorpora = false
        policy.requireCorpusProvenanceForExternalCorpora = false

        let report = TranscriptionReleaseGate().evaluate(
            cases: [
                TranscriptionBenchmarkCase(
                    id: "fleurs-english-only",
                    reference: "the fleurs corpus must prove multilingual coverage itself",
                    hypothesis: "the fleurs corpus must prove multilingual coverage itself",
                    locale: "en-US",
                    corpus: .fleurs,
                    evaluationTags: [.meeting],
                    firstPartialLatencyMs: 390,
                    finalLatencyMs: 1_100,
                    audioDurationMs: 2_500,
                    processingDurationMs: 900
                ),
                TranscriptionBenchmarkCase(
                    id: "unrequired-spanish-case",
                    reference: "validemos cobertura global",
                    hypothesis: "validemos cobertura global",
                    locale: "es-ES",
                    corpus: .ami,
                    evaluationTags: [.multilingual],
                    firstPartialLatencyMs: 390,
                    finalLatencyMs: 1_100,
                    audioDurationMs: 2_500,
                    processingDurationMs: 900
                )
            ],
            policy: policy
        )

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.failures.contains("missing_corpus_locale:fleurs:es-ES"))
        XCTAssertTrue(report.failures.contains("missing_corpus_tag:fleurs:multilingual"))
        XCTAssertFalse(report.failures.contains("missing_locale:es-ES"))
        XCTAssertFalse(report.failures.contains("missing_tag:multilingual"))
    }

    func testTranscriptionReleaseGateRejectsSyntheticCorpusLabelsWithoutAudioEvidence() {
        var policy = TranscriptionReleaseGatePolicy.topTierRelease
        policy.requiredCorpora = [.ami]
        policy.requiredLocales = ["en-US"]
        policy.requiredTags = [.meeting]

        let report = TranscriptionReleaseGate().evaluate(
            cases: [
                TranscriptionBenchmarkCase(
                    id: "ami-synthetic-label",
                    reference: "we need a real meeting corpus sample",
                    hypothesis: "we need a real meeting corpus sample",
                    locale: "en-US",
                    corpus: .ami,
                    evaluationTags: [.meeting],
                    firstPartialLatencyMs: 420,
                    finalLatencyMs: 1_200,
                    audioDurationMs: 3_000,
                    processingDurationMs: 1_100
                )
            ],
            policy: policy
        )

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.failures.contains("unsupported_evidence_kind:ami-synthetic-label:synthetic"))
        XCTAssertTrue(report.failures.contains("missing_audio_file:ami-synthetic-label"))
        XCTAssertTrue(report.failures.contains("missing_audio_checksum:ami-synthetic-label"))
    }

    func testTranscriptionReleaseGateRejectsExternalCorpusAudioWithoutProvenance() throws {
        let evidenceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchly-corpus-provenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidenceDirectory) }
        let audioEvidence = try Self.releaseGateAudioEvidence(
            id: "ami-missing-provenance",
            kind: .publicCorpus,
            directory: evidenceDirectory,
            durationMs: 3_000
        )
        let transcriptEvidence = try Self.releaseGateHypothesisEvidence(
            id: "ami-missing-provenance",
            hypothesis: "corpus evidence needs sample provenance",
            source: .importedASR,
            locale: "en-US",
            engineIdentifier: "notchly-imported-asr-evaluation",
            runID: "missing-provenance-run",
            audioSHA256: audioEvidence.sha256,
            audioDurationMs: 3_000,
            directory: evidenceDirectory
        )

        var policy = TranscriptionReleaseGatePolicy.topTierRelease
        policy.requiredCorpora = [.ami]
        policy.requiredLocales = ["en-US"]
        policy.requiredTags = [.meeting]

        let report = TranscriptionReleaseGate().evaluate(
            cases: [
                TranscriptionBenchmarkCase(
                    id: "ami-missing-provenance",
                    audioFilePath: audioEvidence.path,
                    reference: "corpus evidence needs sample provenance",
                    hypothesis: "corpus evidence needs sample provenance",
                    locale: "en-US",
                    corpus: .ami,
                    evaluationTags: [.meeting],
                    evidenceKind: audioEvidence.kind,
                    audioSHA256: audioEvidence.sha256,
                    hypothesisSource: transcriptEvidence.source,
                    hypothesisEngineIdentifier: transcriptEvidence.engineIdentifier,
                    hypothesisRunID: transcriptEvidence.runID,
                    hypothesisTranscriptFilePath: transcriptEvidence.path,
                    hypothesisTranscriptSHA256: transcriptEvidence.sha256,
                    firstPartialLatencyMs: 410,
                    finalLatencyMs: 1_200,
                    audioDurationMs: 3_000,
                    processingDurationMs: 1_000
                )
            ],
            policy: policy
        )

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.failures.contains("missing_corpus_provenance:ami-missing-provenance"))
    }

    func testTranscriptionReleaseGateRequiresSpokenLanguageIDEvidenceForSpokenLIDCases() throws {
        let evidenceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchly-spoken-lid-evidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidenceDirectory) }
        let audioEvidence = try Self.releaseGateAudioEvidence(
            id: "vox-lid-text-only",
            kind: .publicCorpus,
            directory: evidenceDirectory,
            durationMs: 3_000
        )
        let provenance = Self.publicCorpusProvenance(.voxLingua107, sampleID: "vox-lid-text-only")
        let transcriptEvidence = try Self.releaseGateHypothesisEvidence(
            id: "vox-lid-text-only",
            hypothesis: "モデルの言語判定を確認します",
            source: .speechAnalyzer,
            locale: "ja-JP",
            engineIdentifier: "notchly-speechanalyzer-evaluation",
            runID: "text-only-lid-run",
            audioSHA256: audioEvidence.sha256,
            audioDurationMs: 3_000,
            latencyMeasurementMode: .realtimeReplay,
            replayChunkDurationMs: 100,
            languageEvidenceSource: "text-language-detection",
            languageDetectionWindowMs: 700,
            languageSpanCodes: ["ja-JP"],
            corpusProvenance: provenance,
            directory: evidenceDirectory
        )

        var policy = TranscriptionReleaseGatePolicy.topTierRelease
        policy.requiredCorpora = [.voxLingua107]
        policy.requiredLocales = ["ja-JP"]
        policy.requiredTags = [.spokenLanguageID, .multilingual]
        policy.minimumCaseCountsByCorpus = [.voxLingua107: 1]
        policy.minimumUniqueSampleCountsByCorpus = [.voxLingua107: 1]
        policy.minimumUniqueAudioChecksumCountsByCorpus = [.voxLingua107: 1]
        policy.minimumTotalAudioDurationMsByCorpus = [.voxLingua107: 0]
        policy.requiredLocalesByCorpus = [.voxLingua107: ["ja-JP"]]
        policy.requiredTagsByCorpus = [.voxLingua107: [.spokenLanguageID, .multilingual]]
        policy.requireNonTemporaryAudioEvidenceForExternalCorpora = false

        let report = TranscriptionReleaseGate().evaluate(
            cases: [
                TranscriptionBenchmarkCase(
                    id: "vox-lid-text-only",
                    audioFilePath: audioEvidence.path,
                    reference: "モデルの言語判定を確認します",
                    hypothesis: "モデルの言語判定を確認します",
                    locale: "ja-JP",
                    corpus: .voxLingua107,
                    evaluationTags: [.spokenLanguageID, .multilingual],
                    evidenceKind: audioEvidence.kind,
                    audioSHA256: audioEvidence.sha256,
                    corpusProvenance: provenance,
                    hypothesisSource: transcriptEvidence.source,
                    hypothesisEngineIdentifier: transcriptEvidence.engineIdentifier,
                    hypothesisRunID: transcriptEvidence.runID,
                    hypothesisTranscriptFilePath: transcriptEvidence.path,
                    hypothesisTranscriptSHA256: transcriptEvidence.sha256,
                    firstPartialLatencyMs: 420,
                    finalLatencyMs: 1_250,
                    audioDurationMs: 3_000,
                    processingDurationMs: 1_100,
                    languageSwitchLatencyMs: 300,
                    latencyMeasurementMode: .realtimeReplay,
                    replayChunkDurationMs: 100,
                    memoryResidentBytes: 384_000_000,
                    cpuUsagePercent: 24
                )
            ],
            policy: policy
        )

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.failures.contains("missing_spoken_language_id_evidence:vox-lid-text-only"))
    }

    func testTranscriptionReleaseGateRequiresLanguageSpanEvidenceForCodeSwitching() throws {
        let evidenceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchly-code-switch-span-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidenceDirectory) }
        let audioEvidence = try Self.releaseGateAudioEvidence(
            id: "private-code-switch-single-language",
            kind: .privateCorpus,
            directory: evidenceDirectory,
            durationMs: 3_000
        )
        let provenance = Self.privateCorpusProvenance(sampleID: "private-code-switch-single-language")
        let transcriptEvidence = try Self.releaseGateHypothesisEvidence(
            id: "private-code-switch-single-language",
            hypothesis: "vamos validar o SpeechAnalyzer com Core ML",
            source: .whisperKit,
            locale: "pt-BR",
            engineIdentifier: "WhisperKit/distil-large-v3",
            runID: "single-language-code-switch-run",
            audioSHA256: audioEvidence.sha256,
            audioDurationMs: 3_000,
            latencyMeasurementMode: .realtimeReplay,
            replayChunkDurationMs: 100,
            retentionReason: .localRefinerAccepted,
            languageEvidenceSource: "whisperkit-auto-language",
            languageDetectionWindowMs: 800,
            languageSpanCodes: ["pt-BR"],
            corpusProvenance: provenance,
            directory: evidenceDirectory
        )

        var policy = TranscriptionReleaseGatePolicy.topTierRelease
        policy.requiredCorpora = [.privateMeetingPack]
        policy.requiredLocales = ["pt-BR"]
        policy.requiredTags = [.meeting, .multilingual, .codeSwitching, .jargon]
        policy.minimumCaseCountsByCorpus = [.privateMeetingPack: 1]
        policy.minimumUniqueSampleCountsByCorpus = [.privateMeetingPack: 1]
        policy.minimumUniqueAudioChecksumCountsByCorpus = [.privateMeetingPack: 1]
        policy.minimumTotalAudioDurationMsByCorpus = [.privateMeetingPack: 0]
        policy.requiredLocalesByCorpus = [.privateMeetingPack: ["pt-BR"]]
        policy.requiredTagsByCorpus = [.privateMeetingPack: [.meeting, .multilingual, .codeSwitching, .jargon]]
        policy.requiredAudioSourcesByCorpus = [:]

        let report = TranscriptionReleaseGate().evaluate(
            cases: [
                TranscriptionBenchmarkCase(
                    id: "private-code-switch-single-language",
                    audioFilePath: audioEvidence.path,
                    reference: "vamos validar o SpeechAnalyzer com Core ML",
                    hypothesis: "vamos validar o SpeechAnalyzer com Core ML",
                    locale: "pt-BR",
                    activeVocabulary: ["SpeechAnalyzer", "Core ML"],
                    namedEntities: ["SpeechAnalyzer"],
                    corpus: .privateMeetingPack,
                    evaluationTags: [.meeting, .multilingual, .codeSwitching, .jargon],
                    evidenceKind: audioEvidence.kind,
                    audioSHA256: audioEvidence.sha256,
                    corpusProvenance: provenance,
                    hypothesisSource: transcriptEvidence.source,
                    hypothesisEngineIdentifier: transcriptEvidence.engineIdentifier,
                    hypothesisRunID: transcriptEvidence.runID,
                    hypothesisTranscriptFilePath: transcriptEvidence.path,
                    hypothesisTranscriptSHA256: transcriptEvidence.sha256,
                    firstPartialLatencyMs: 320,
                    finalLatencyMs: 1_080,
                    audioDurationMs: 3_000,
                    processingDurationMs: 1_000,
                    languageSwitchLatencyMs: 240,
                    latencyMeasurementMode: .realtimeReplay,
                    replayChunkDurationMs: 100,
                    memoryResidentBytes: 384_000_000,
                    cpuUsagePercent: 24
                )
            ],
            policy: policy
        )

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.failures.contains("missing_code_switch_language_span_evidence:private-code-switch-single-language"))
    }

    func testTranscriptionReleaseGateRejectsGenericPublicCorpusSourceURI() throws {
        let evidenceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchly-corpus-source-uri-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidenceDirectory) }
        let audioEvidence = try Self.releaseGateAudioEvidence(
            id: "ami-generic-source-uri",
            kind: .publicCorpus,
            directory: evidenceDirectory,
            durationMs: 3_000
        )
        let provenance = Self.publicCorpusProvenance(
            .ami,
            sampleID: "ami-generic-source-uri",
            sourceURI: "https://example.com/ami/generic-source-uri"
        )
        let transcriptEvidence = try Self.releaseGateHypothesisEvidence(
            id: "ami-generic-source-uri",
            hypothesis: "public corpus evidence needs an approved corpus source",
            source: .importedASR,
            locale: "en-US",
            engineIdentifier: "notchly-imported-asr-evaluation",
            runID: "generic-source-uri-run",
            audioSHA256: audioEvidence.sha256,
            audioDurationMs: 3_000,
            corpusProvenance: provenance,
            directory: evidenceDirectory
        )

        var policy = TranscriptionReleaseGatePolicy.topTierRelease
        policy.requiredCorpora = [.ami]
        policy.requiredLocales = ["en-US"]
        policy.requiredTags = [.meeting]

        let report = TranscriptionReleaseGate().evaluate(
            cases: [
                TranscriptionBenchmarkCase(
                    id: "ami-generic-source-uri",
                    audioFilePath: audioEvidence.path,
                    reference: "public corpus evidence needs an approved corpus source",
                    hypothesis: "public corpus evidence needs an approved corpus source",
                    locale: "en-US",
                    corpus: .ami,
                    evaluationTags: [.meeting],
                    evidenceKind: audioEvidence.kind,
                    audioSHA256: audioEvidence.sha256,
                    corpusProvenance: provenance,
                    hypothesisSource: transcriptEvidence.source,
                    hypothesisEngineIdentifier: transcriptEvidence.engineIdentifier,
                    hypothesisRunID: transcriptEvidence.runID,
                    hypothesisTranscriptFilePath: transcriptEvidence.path,
                    hypothesisTranscriptSHA256: transcriptEvidence.sha256,
                    firstPartialLatencyMs: 410,
                    finalLatencyMs: 1_200,
                    audioDurationMs: 3_000,
                    processingDurationMs: 1_000
                )
            ],
            policy: policy
        )

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.failures.contains("public_corpus_source_not_approved:ami-generic-source-uri:ami"))
    }

    func testTranscriptionReleaseGateRejectsTemporaryAudioForExternalCorpusEvidence() throws {
        let evidenceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchly-temporary-corpus-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidenceDirectory) }
        let audioEvidence = try Self.releaseGateAudioEvidence(
            id: "ami-temporary-audio",
            kind: .publicCorpus,
            directory: evidenceDirectory,
            durationMs: 3_000
        )
        let provenance = Self.publicCorpusProvenance(.ami, sampleID: "ami-temporary-audio")
        let transcriptEvidence = try Self.releaseGateHypothesisEvidence(
            id: "ami-temporary-audio",
            hypothesis: "temporary generated audio should not certify public corpus quality",
            source: .importedASR,
            locale: "en-US",
            engineIdentifier: "notchly-imported-asr-evaluation",
            runID: "temporary-audio-run",
            audioSHA256: audioEvidence.sha256,
            audioDurationMs: 3_000,
            corpusProvenance: provenance,
            directory: evidenceDirectory
        )

        var policy = TranscriptionReleaseGatePolicy.topTierRelease
        policy.requiredCorpora = [.ami]
        policy.requiredLocales = ["en-US"]
        policy.requiredTags = [.meeting]

        let report = TranscriptionReleaseGate().evaluate(
            cases: [
                TranscriptionBenchmarkCase(
                    id: "ami-temporary-audio",
                    audioFilePath: audioEvidence.path,
                    reference: "temporary generated audio should not certify public corpus quality",
                    hypothesis: "temporary generated audio should not certify public corpus quality",
                    locale: "en-US",
                    corpus: .ami,
                    evaluationTags: [.meeting],
                    evidenceKind: audioEvidence.kind,
                    audioSHA256: audioEvidence.sha256,
                    corpusProvenance: provenance,
                    hypothesisSource: transcriptEvidence.source,
                    hypothesisEngineIdentifier: transcriptEvidence.engineIdentifier,
                    hypothesisRunID: transcriptEvidence.runID,
                    hypothesisTranscriptFilePath: transcriptEvidence.path,
                    hypothesisTranscriptSHA256: transcriptEvidence.sha256,
                    firstPartialLatencyMs: 410,
                    finalLatencyMs: 1_200,
                    audioDurationMs: 3_000,
                    processingDurationMs: 1_000
                )
            ],
            policy: policy
        )

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.failures.contains("temporary_external_corpus_audio:ami-temporary-audio"))
    }

    func testTranscriptionReleaseGateRejectsPrivateCorpusWithoutConsentProvenance() throws {
        let evidenceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchly-private-consent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidenceDirectory) }
        let audioEvidence = try Self.releaseGateAudioEvidence(
            id: "private-no-consent",
            kind: .privateCorpus,
            directory: evidenceDirectory,
            durationMs: 2_000
        )
        let provenance = TranscriptionCorpusProvenance(
            corpus: .privateMeetingPack,
            sampleID: "private-no-consent",
            sourceURI: "private://notchly/private-meeting-pack/no-consent",
            datasetVersion: "test-private-pack",
            license: nil,
            origin: .privateMeetingRecording,
            speakerCount: 2,
            consentVerified: false
        )
        let transcriptEvidence = try Self.releaseGateHypothesisEvidence(
            id: "private-no-consent",
            hypothesis: "vamos validar consentimento privado",
            source: .importedASR,
            locale: "pt-BR",
            engineIdentifier: "notchly-imported-asr-evaluation",
            runID: "private-no-consent-run",
            audioSHA256: audioEvidence.sha256,
            audioDurationMs: 2_000,
            corpusProvenance: provenance,
            directory: evidenceDirectory
        )

        var policy = TranscriptionReleaseGatePolicy.topTierRelease
        policy.requiredCorpora = [.privateMeetingPack]
        policy.requiredLocales = ["pt-BR"]
        policy.requiredTags = [.meeting]

        let report = TranscriptionReleaseGate().evaluate(
            cases: [
                TranscriptionBenchmarkCase(
                    id: "private-no-consent",
                    audioFilePath: audioEvidence.path,
                    reference: "vamos validar consentimento privado",
                    hypothesis: "vamos validar consentimento privado",
                    locale: "pt-BR",
                    corpus: .privateMeetingPack,
                    evaluationTags: [.meeting],
                    evidenceKind: audioEvidence.kind,
                    audioSHA256: audioEvidence.sha256,
                    corpusProvenance: provenance,
                    hypothesisSource: transcriptEvidence.source,
                    hypothesisEngineIdentifier: transcriptEvidence.engineIdentifier,
                    hypothesisRunID: transcriptEvidence.runID,
                    hypothesisTranscriptFilePath: transcriptEvidence.path,
                    hypothesisTranscriptSHA256: transcriptEvidence.sha256,
                    firstPartialLatencyMs: 410,
                    finalLatencyMs: 1_200,
                    audioDurationMs: 2_000,
                    processingDurationMs: 800
                )
            ],
            policy: policy
        )

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.failures.contains("private_corpus_consent_not_verified:private-no-consent"))
    }

    func testTranscriptionReleaseGateRequiresLocalRefinerEvidenceForAccuracyCorpora() throws {
        let evidenceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchly-local-refiner-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidenceDirectory) }

        let audioEvidence = try Self.releaseGateAudioEvidence(
            id: "private-refiner-required",
            kind: .privateCorpus,
            directory: evidenceDirectory,
            durationMs: 2_000
        )
        let provenance = Self.privateCorpusProvenance(sampleID: "private-refiner-required")
        let appleOnlyTranscript = try Self.releaseGateHypothesisEvidence(
            id: "private-refiner-required",
            hypothesis: "Notchly preserved Core ML in noisy speech",
            source: .speechAnalyzer,
            locale: "en-US",
            engineIdentifier: "notchly-speechanalyzer-evaluation",
            runID: "local-refiner-required",
            audioSHA256: audioEvidence.sha256,
            audioDurationMs: 2_000,
            latencyMeasurementMode: .realtimeReplay,
            replayChunkDurationMs: 100,
            corpusProvenance: provenance,
            directory: evidenceDirectory
        )

        var benchmarkCase = TranscriptionBenchmarkCase(
            id: "private-refiner-required",
            audioFilePath: audioEvidence.path,
            reference: "Notchly preserved Core ML in noisy speech",
            hypothesis: "Notchly preserved Core ML in noisy speech",
            locale: "en-US",
            activeVocabulary: ["Notchly", "Core ML"],
            namedEntities: ["Notchly"],
            corpus: .privateMeetingPack,
            evaluationTags: [.meeting, .jargon],
            evidenceKind: .privateCorpus,
            audioSHA256: audioEvidence.sha256,
            corpusProvenance: provenance,
            hypothesisSource: appleOnlyTranscript.source,
            hypothesisEngineIdentifier: appleOnlyTranscript.engineIdentifier,
            hypothesisRunID: appleOnlyTranscript.runID,
            hypothesisTranscriptFilePath: appleOnlyTranscript.path,
            hypothesisTranscriptSHA256: appleOnlyTranscript.sha256,
            firstPartialLatencyMs: 320,
            finalLatencyMs: 1_100,
            audioDurationMs: 2_000,
            processingDurationMs: 900,
            latencyMeasurementMode: .realtimeReplay,
            replayChunkDurationMs: 100,
            memoryResidentBytes: 384_000_000,
            cpuUsagePercent: 22
        )

        var policy = TranscriptionReleaseGatePolicy.topTierRelease
        policy.requiredCorpora = [.privateMeetingPack]
        policy.requiredLocales = ["en-US"]
        policy.requiredTags = [.meeting, .jargon]
        policy.minimumCaseCountPerCorpus = 1
        policy.minimumCaseCountsByCorpus = [.privateMeetingPack: 1]
        policy.minimumUniqueSampleCountsByCorpus = [.privateMeetingPack: 1]
        policy.minimumUniqueAudioChecksumCountsByCorpus = [.privateMeetingPack: 1]
        policy.minimumTotalAudioDurationMsByCorpus = [.privateMeetingPack: 1_500]
        policy.requiredLocalesByCorpus = [.privateMeetingPack: ["en-US"]]
        policy.requiredTagsByCorpus = [.privateMeetingPack: [.meeting, .jargon]]
        policy.requiredAudioSourcesByCorpus = [:]
        policy.requireNonTemporaryAudioEvidenceForExternalCorpora = false

        let appleOnlyReport = TranscriptionReleaseGate().evaluate(cases: [benchmarkCase], policy: policy)
        XCTAssertFalse(appleOnlyReport.passed)
        XCTAssertTrue(appleOnlyReport.failures.contains("missing_local_refiner_evidence:private-meeting-pack"))
        XCTAssertTrue(appleOnlyReport.failures.contains("missing_local_refiner_accepted_evidence:private-meeting-pack"))

        let refinerDecisionTranscript = try Self.releaseGateHypothesisEvidence(
            id: "private-refiner-required",
            hypothesis: "Notchly preserved Core ML in noisy speech",
            source: .speechAnalyzer,
            locale: "en-US",
            engineIdentifier: "notchly-speechanalyzer-evaluation",
            runID: "local-refiner-required",
            audioSHA256: audioEvidence.sha256,
            audioDurationMs: 2_000,
            latencyMeasurementMode: .realtimeReplay,
            replayChunkDurationMs: 100,
            retentionReason: .localRefinerRejected,
            corpusProvenance: provenance,
            directory: evidenceDirectory
        )
        benchmarkCase.hypothesisTranscriptFilePath = refinerDecisionTranscript.path
        benchmarkCase.hypothesisTranscriptSHA256 = refinerDecisionTranscript.sha256

        let refinerDecisionReport = TranscriptionReleaseGate().evaluate(cases: [benchmarkCase], policy: policy)
        XCTAssertFalse(refinerDecisionReport.failures.contains("missing_local_refiner_evidence:private-meeting-pack"))
        XCTAssertTrue(refinerDecisionReport.failures.contains("missing_local_refiner_accepted_evidence:private-meeting-pack"))
        XCTAssertEqual(refinerDecisionReport.coverage.first?.localRefinerDecisionCount, 1)
        XCTAssertEqual(refinerDecisionReport.coverage.first?.localRefinerRejectedCount, 1)

        let acceptedRefinerTranscript = try Self.releaseGateHypothesisEvidence(
            id: "private-refiner-required",
            hypothesis: "Notchly preserved Core ML in noisy speech",
            source: .whisperKit,
            locale: "en-US",
            engineIdentifier: "WhisperKit/distil-large-v3",
            runID: "local-refiner-required",
            audioSHA256: audioEvidence.sha256,
            audioDurationMs: 2_000,
            latencyMeasurementMode: .realtimeReplay,
            replayChunkDurationMs: 100,
            retentionReason: .localRefinerAccepted,
            corpusProvenance: provenance,
            directory: evidenceDirectory
        )
        benchmarkCase.hypothesisSource = acceptedRefinerTranscript.source
        benchmarkCase.hypothesisEngineIdentifier = acceptedRefinerTranscript.engineIdentifier
        benchmarkCase.hypothesisTranscriptFilePath = acceptedRefinerTranscript.path
        benchmarkCase.hypothesisTranscriptSHA256 = acceptedRefinerTranscript.sha256

        let acceptedRefinerReport = TranscriptionReleaseGate().evaluate(cases: [benchmarkCase], policy: policy)
        XCTAssertFalse(acceptedRefinerReport.failures.contains("missing_local_refiner_evidence:private-meeting-pack"))
        XCTAssertFalse(acceptedRefinerReport.failures.contains("missing_local_refiner_accepted_evidence:private-meeting-pack"))
        XCTAssertEqual(acceptedRefinerReport.coverage.first?.localRefinerDecisionCount, 1)
        XCTAssertEqual(acceptedRefinerReport.coverage.first?.localRefinerAcceptedCount, 1)
    }

    func testTranscriptionReleaseGateRejectsForgedLocalRefinerEvidenceWithoutRevisionProvenance() throws {
        let evidenceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchly-forged-refiner-evidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidenceDirectory) }

        let id = "private-forged-local-refiner"
        let hypothesis = "Notchly preserved Core ML"
        let audioEvidence = try Self.releaseGateAudioFixtureEvidence(
            id: id,
            profile: .clean,
            kind: .privateCorpus,
            directory: evidenceDirectory,
            durationMs: 2_000
        )
        let provenance = Self.privateCorpusProvenance(sampleID: id)
        let transcriptURL = evidenceDirectory.appendingPathComponent("\(id).transcript.json")
        let transcript = TranscriptionHypothesisTranscriptEvidence(
            caseID: id,
            hypothesis: hypothesis,
            source: .speechAnalyzer,
            engineIdentifier: "notchly-speechanalyzer-evaluation",
            runID: "forged-refiner-run",
            locale: "en-US",
            segmentCount: 1,
            segments: [
                TranscriptionHypothesisTranscriptEvidence.SegmentEvidence(
                    text: hypothesis,
                    audioSource: .microphone,
                    speakerLabel: "You",
                    startTime: 0,
                    endTime: 2,
                    isFinal: true,
                    transcriptionPhase: .final,
                    transcriptionEngine: .speechAnalyzer,
                    finalizedBy: .speechAnalyzer,
                    confidence: 0.96,
                    engineConfidence: 0.96,
                    languageCode: "en-US",
                    languageConfidence: 0.92,
                    revisionOfSegmentId: nil,
                    revisionNumber: 0,
                    retentionReason: .localRefinerRejected,
                    sourceFrameRange: AudioSourceFrameRange(start: 0, end: 32_000),
                    wordTimestampCount: 4
                )
            ],
            audioSHA256: audioEvidence.sha256,
            audioDurationMs: 2_000,
            audioConditioning: Self.releaseGateAudioConditioningEvidence(
                hypothesis: hypothesis,
                audioDurationMs: 2_000,
                audioSource: .microphone
            ),
            latencyMeasurementMode: .realtimeReplay,
            replayChunkDurationMs: 100,
            generatedAt: "2026-05-29T00:00:00Z",
            corpusProvenance: provenance
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let transcriptData = try encoder.encode(transcript)
        try transcriptData.write(to: transcriptURL, options: Data.WritingOptions.atomic)
        let transcriptSHA = SHA256.hash(data: transcriptData).map { String(format: "%02x", $0) }.joined()

        var policy = TranscriptionReleaseGatePolicy.topTierRelease
        policy.requiredCorpora = [.privateMeetingPack]
        policy.requiredLocales = ["en-US"]
        policy.requiredTags = [.meeting, .jargon]
        policy.minimumCaseCountPerCorpus = 1
        policy.minimumCaseCountsByCorpus = [.privateMeetingPack: 1]
        policy.minimumUniqueSampleCountsByCorpus = [.privateMeetingPack: 1]
        policy.minimumUniqueAudioChecksumCountsByCorpus = [.privateMeetingPack: 1]
        policy.minimumTotalAudioDurationMsByCorpus = [.privateMeetingPack: 1_500]
        policy.requiredLocalesByCorpus = [.privateMeetingPack: ["en-US"]]
        policy.requiredTagsByCorpus = [.privateMeetingPack: [.meeting, .jargon]]
        policy.requiredAudioSourcesByCorpus = [.privateMeetingPack: [.microphone]]
        policy.requireNonTemporaryAudioEvidenceForExternalCorpora = false

        let report = TranscriptionReleaseGate().evaluate(
            cases: [
                TranscriptionBenchmarkCase(
                    id: id,
                    audioFilePath: audioEvidence.path,
                    audioSource: .microphone,
                    reference: hypothesis,
                    hypothesis: hypothesis,
                    locale: "en-US",
                    activeVocabulary: ["Core ML"],
                    corpus: .privateMeetingPack,
                    evaluationTags: [.meeting, .jargon],
                    evidenceKind: .privateCorpus,
                    audioSHA256: audioEvidence.sha256,
                    corpusProvenance: provenance,
                    hypothesisSource: .speechAnalyzer,
                    hypothesisEngineIdentifier: "notchly-speechanalyzer-evaluation",
                    hypothesisRunID: "forged-refiner-run",
                    hypothesisTranscriptFilePath: transcriptURL.path,
                    hypothesisTranscriptSHA256: transcriptSHA,
                    firstPartialLatencyMs: 300,
                    finalLatencyMs: 1_000,
                    audioDurationMs: 2_000,
                    processingDurationMs: 900,
                    latencyMeasurementMode: .realtimeReplay,
                    replayChunkDurationMs: 100,
                    memoryResidentBytes: 384_000_000,
                    cpuUsagePercent: 22
                )
            ],
            policy: policy
        )

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.failures.contains("missing_local_refiner_evidence:private-meeting-pack"))
        XCTAssertTrue(report.failures.contains("missing_local_refiner_accepted_evidence:private-meeting-pack"))
        XCTAssertTrue(report.failures.contains("hypothesis_segment_local_refiner_missing_revision_root:private-forged-local-refiner:0"))
        XCTAssertTrue(report.failures.contains("hypothesis_segment_local_refiner_invalid_revision_number:private-forged-local-refiner:0"))
        XCTAssertEqual(report.coverage.first?.localRefinerDecisionCount, 0)
    }

    func testTranscriptionReleaseGateSchemaPassesWithFixtureCoverageWhenExternalAudioPolicyIsRelaxed() throws {
        let evidenceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchly-release-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidenceDirectory) }
        let internalSilenceEvidence = try Self.releaseGateAudioFixtureEvidence(id: "internal-critical-silence", profile: .silence, kind: .generatedFixture, directory: evidenceDirectory, durationMs: 1_000)
        let internalClicksEvidence = try Self.releaseGateAudioFixtureEvidence(id: "internal-critical-clicks", profile: .clicks, kind: .generatedFixture, directory: evidenceDirectory, durationMs: 1_000)
        let internalMusicEvidence = try Self.releaseGateAudioFixtureEvidence(id: "internal-critical-music", profile: .music, kind: .generatedFixture, directory: evidenceDirectory, durationMs: 1_000)
        let internalBreathingEvidence = try Self.releaseGateAudioFixtureEvidence(id: "internal-critical-breathing", profile: .breathing, kind: .generatedFixture, directory: evidenceDirectory, durationMs: 1_000)
        let privateEvidence = try Self.releaseGateAudioFixtureEvidence(id: "private-pt-code-switch", profile: .noisy, kind: .privateCorpus, directory: evidenceDirectory, durationMs: 2_600)
        let privateMicEvidence = try Self.releaseGateAudioFixtureEvidence(id: "private-mic-jargon", profile: .clean, kind: .privateCorpus, directory: evidenceDirectory, durationMs: 2_200)
        let amiEvidence = try Self.releaseGateAudioFixtureEvidence(id: "ami-overlap-far-field", profile: .overlap, kind: .publicCorpus, directory: evidenceDirectory, durationMs: 4_000)
        let fleursEvidence = try Self.releaseGateAudioFixtureEvidence(id: "fleurs-spanish", profile: .lowVolume, kind: .publicCorpus, directory: evidenceDirectory, durationMs: 2_400)
        let voxEvidence = try Self.releaseGateAudioFixtureEvidence(id: "voxlingua-japanese-lid", profile: .reverb, kind: .publicCorpus, directory: evidenceDirectory, durationMs: 2_800)
        let earningsEvidence = try Self.releaseGateAudioFixtureEvidence(id: "earnings-entity-dense", profile: .clipping, kind: .publicCorpus, directory: evidenceDirectory, durationMs: 3_100)
        let conecEvidence = try Self.releaseGateAudioFixtureEvidence(id: "conec-contextual-bias", profile: .clean, kind: .publicCorpus, directory: evidenceDirectory, durationMs: 2_900)
        let privateProvenance = Self.privateCorpusProvenance(sampleID: "private-pt-code-switch")
        let amiProvenance = Self.publicCorpusProvenance(.ami, sampleID: "ami-overlap-far-field", speakerCount: 4)
        let fleursProvenance = Self.publicCorpusProvenance(.fleurs, sampleID: "fleurs-spanish")
        let voxProvenance = Self.publicCorpusProvenance(.voxLingua107, sampleID: "voxlingua-japanese-lid")
        let earningsProvenance = Self.publicCorpusProvenance(.earnings21, sampleID: "earnings-entity-dense")
        let conecProvenance = Self.publicCorpusProvenance(.conec, sampleID: "conec-contextual-bias")
        let privateMicProvenance = Self.privateCorpusProvenance(sampleID: "private-mic-jargon")
        let runID = "release-gate-\(UUID().uuidString)"
        let internalEngine = "notchly-evaluation-replay"
        let pipelineEngine = "notchly-speechanalyzer-evaluation"
        let localRefinerEngine = "WhisperKit/distil-large-v3"
        let internalSilenceTranscript = try Self.releaseGateHypothesisEvidence(
            id: "internal-critical-silence",
            hypothesis: "",
            source: .evaluationReplay,
            locale: "en-US",
            engineIdentifier: internalEngine,
            runID: runID,
            audioSHA256: internalSilenceEvidence.sha256,
            audioDurationMs: 1_000,
            directory: evidenceDirectory
        )
        let internalClicksTranscript = try Self.releaseGateHypothesisEvidence(
            id: "internal-critical-clicks",
            hypothesis: "",
            source: .evaluationReplay,
            locale: "en-US",
            engineIdentifier: internalEngine,
            runID: runID,
            audioSHA256: internalClicksEvidence.sha256,
            audioDurationMs: 1_000,
            directory: evidenceDirectory
        )
        let internalMusicTranscript = try Self.releaseGateHypothesisEvidence(
            id: "internal-critical-music",
            hypothesis: "",
            source: .evaluationReplay,
            locale: "en-US",
            engineIdentifier: internalEngine,
            runID: runID,
            audioSHA256: internalMusicEvidence.sha256,
            audioDurationMs: 1_000,
            directory: evidenceDirectory
        )
        let internalBreathingTranscript = try Self.releaseGateHypothesisEvidence(
            id: "internal-critical-breathing",
            hypothesis: "",
            source: .evaluationReplay,
            locale: "en-US",
            engineIdentifier: internalEngine,
            runID: runID,
            audioSHA256: internalBreathingEvidence.sha256,
            audioDurationMs: 1_000,
            audioSource: .microphone,
            directory: evidenceDirectory
        )
        let privateTranscript = try Self.releaseGateHypothesisEvidence(
            id: "private-pt-code-switch",
            hypothesis: "vamos validar o SpeechAnalyzer com Core ML",
            source: .whisperKit,
            locale: "pt-BR",
            engineIdentifier: localRefinerEngine,
            runID: runID,
            audioSHA256: privateEvidence.sha256,
            audioDurationMs: 2_600,
            latencyMeasurementMode: .realtimeReplay,
            replayChunkDurationMs: 100,
            retentionReason: .localRefinerAccepted,
            languageEvidenceSource: "whisperkit-auto-language",
            languageDetectionWindowMs: 900,
            languageSpanCodes: ["pt-BR", "en-US"],
            corpusProvenance: privateProvenance,
            directory: evidenceDirectory
        )
        let privateMicTranscript = try Self.releaseGateHypothesisEvidence(
            id: "private-mic-jargon",
            hypothesis: "I can confirm the Notchly microphone side keeps Core ML",
            source: .speechAnalyzer,
            locale: "en-US",
            engineIdentifier: pipelineEngine,
            runID: runID,
            audioSHA256: privateMicEvidence.sha256,
            audioDurationMs: 2_200,
            audioSource: .microphone,
            latencyMeasurementMode: .realtimeReplay,
            replayChunkDurationMs: 100,
            corpusProvenance: privateMicProvenance,
            directory: evidenceDirectory
        )
        let amiTranscript = try Self.releaseGateHypothesisEvidence(
            id: "ami-overlap-far-field",
            hypothesis: "we need to resolve the deployment risk before the meeting ends",
            source: .speechAnalyzer,
            locale: "en-US",
            engineIdentifier: pipelineEngine,
            runID: runID,
            audioSHA256: amiEvidence.sha256,
            audioDurationMs: 4_000,
            latencyMeasurementMode: .realtimeReplay,
            replayChunkDurationMs: 100,
            corpusProvenance: amiProvenance,
            directory: evidenceDirectory
        )
        let fleursTranscript = try Self.releaseGateHypothesisEvidence(
            id: "fleurs-spanish",
            hypothesis: "validemos el cambio de idioma antes de publicar",
            source: .speechAnalyzer,
            locale: "es-ES",
            engineIdentifier: pipelineEngine,
            runID: runID,
            audioSHA256: fleursEvidence.sha256,
            audioDurationMs: 2_400,
            latencyMeasurementMode: .realtimeReplay,
            replayChunkDurationMs: 100,
            corpusProvenance: fleursProvenance,
            directory: evidenceDirectory
        )
        let voxTranscript = try Self.releaseGateHypothesisEvidence(
            id: "voxlingua-japanese-lid",
            hypothesis: "モデルの言語判定を確認します",
            source: .speechAnalyzer,
            locale: "ja-JP",
            engineIdentifier: pipelineEngine,
            runID: runID,
            audioSHA256: voxEvidence.sha256,
            audioDurationMs: 2_800,
            latencyMeasurementMode: .realtimeReplay,
            replayChunkDurationMs: 100,
            languageEvidenceSource: "voxlingua107-spoken-lid",
            languageDetectionWindowMs: 700,
            languageSpanCodes: ["ja-JP"],
            corpusProvenance: voxProvenance,
            directory: evidenceDirectory
        )
        let earningsTranscript = try Self.releaseGateHypothesisEvidence(
            id: "earnings-entity-dense",
            hypothesis: "Net revenue reached ARR and EBITDA targets for Notchly",
            source: .whisperKit,
            locale: "en-US",
            engineIdentifier: localRefinerEngine,
            runID: runID,
            audioSHA256: earningsEvidence.sha256,
            audioDurationMs: 3_100,
            latencyMeasurementMode: .realtimeReplay,
            replayChunkDurationMs: 100,
            retentionReason: .localRefinerAccepted,
            corpusProvenance: earningsProvenance,
            directory: evidenceDirectory
        )
        let conecTranscript = try Self.releaseGateHypothesisEvidence(
            id: "conec-contextual-bias",
            hypothesis: "Ichimoku and retrieval augmented generation were corrected",
            source: .whisperKit,
            locale: "en-US",
            engineIdentifier: localRefinerEngine,
            runID: runID,
            audioSHA256: conecEvidence.sha256,
            audioDurationMs: 2_900,
            latencyMeasurementMode: .realtimeReplay,
            replayChunkDurationMs: 100,
            retentionReason: .localRefinerAccepted,
            corpusProvenance: conecProvenance,
            directory: evidenceDirectory
        )

        let rawCases = [
            TranscriptionBenchmarkCase(
                id: "internal-critical-silence",
                audioFilePath: internalSilenceEvidence.path,
                reference: "",
                hypothesis: "",
                locale: "en-US",
                corpus: .internalCritical,
                evaluationTags: [.criticalNonSpeech, .silence],
                evidenceKind: internalSilenceEvidence.kind,
                audioSHA256: internalSilenceEvidence.sha256,
                hypothesisSource: internalSilenceTranscript.source,
                hypothesisEngineIdentifier: internalSilenceTranscript.engineIdentifier,
                hypothesisRunID: internalSilenceTranscript.runID,
                hypothesisTranscriptFilePath: internalSilenceTranscript.path,
                hypothesisTranscriptSHA256: internalSilenceTranscript.sha256,
                audioDurationMs: 1_000
            ),
            TranscriptionBenchmarkCase(
                id: "internal-critical-clicks",
                audioFilePath: internalClicksEvidence.path,
                reference: "",
                hypothesis: "",
                locale: "en-US",
                corpus: .internalCritical,
                evaluationTags: [.criticalNonSpeech, .clicks, .noise],
                evidenceKind: internalClicksEvidence.kind,
                audioSHA256: internalClicksEvidence.sha256,
                hypothesisSource: internalClicksTranscript.source,
                hypothesisEngineIdentifier: internalClicksTranscript.engineIdentifier,
                hypothesisRunID: internalClicksTranscript.runID,
                hypothesisTranscriptFilePath: internalClicksTranscript.path,
                hypothesisTranscriptSHA256: internalClicksTranscript.sha256,
                audioDurationMs: 1_000
            ),
            TranscriptionBenchmarkCase(
                id: "internal-critical-music",
                audioFilePath: internalMusicEvidence.path,
                reference: "",
                hypothesis: "",
                locale: "en-US",
                corpus: .internalCritical,
                evaluationTags: [.criticalNonSpeech, .music, .noise],
                evidenceKind: internalMusicEvidence.kind,
                audioSHA256: internalMusicEvidence.sha256,
                hypothesisSource: internalMusicTranscript.source,
                hypothesisEngineIdentifier: internalMusicTranscript.engineIdentifier,
                hypothesisRunID: internalMusicTranscript.runID,
                hypothesisTranscriptFilePath: internalMusicTranscript.path,
                hypothesisTranscriptSHA256: internalMusicTranscript.sha256,
                audioDurationMs: 1_000
            ),
            TranscriptionBenchmarkCase(
                id: "internal-critical-breathing",
                audioFilePath: internalBreathingEvidence.path,
                reference: "",
                hypothesis: "",
                locale: "en-US",
                corpus: .internalCritical,
                evaluationTags: [.criticalNonSpeech, .breathing, .noise],
                evidenceKind: internalBreathingEvidence.kind,
                audioSHA256: internalBreathingEvidence.sha256,
                hypothesisSource: internalBreathingTranscript.source,
                hypothesisEngineIdentifier: internalBreathingTranscript.engineIdentifier,
                hypothesisRunID: internalBreathingTranscript.runID,
                hypothesisTranscriptFilePath: internalBreathingTranscript.path,
                hypothesisTranscriptSHA256: internalBreathingTranscript.sha256,
                audioDurationMs: 1_000
            ),
            TranscriptionBenchmarkCase(
                id: "private-pt-code-switch",
                audioFilePath: privateEvidence.path,
                reference: "vamos validar o SpeechAnalyzer com Core ML",
                hypothesis: "vamos validar o SpeechAnalyzer com Core ML",
                locale: "pt-BR",
                activeVocabulary: ["SpeechAnalyzer", "Core ML"],
                namedEntities: ["SpeechAnalyzer"],
                corpus: .privateMeetingPack,
                evaluationTags: [.meeting, .multilingual, .codeSwitching, .jargon, .noise],
                evidenceKind: privateEvidence.kind,
                audioSHA256: privateEvidence.sha256,
                corpusProvenance: privateProvenance,
                hypothesisSource: privateTranscript.source,
                hypothesisEngineIdentifier: privateTranscript.engineIdentifier,
                hypothesisRunID: privateTranscript.runID,
                hypothesisTranscriptFilePath: privateTranscript.path,
                hypothesisTranscriptSHA256: privateTranscript.sha256,
                firstPartialLatencyMs: 320,
                finalLatencyMs: 1_080,
                audioDurationMs: 2_600,
                processingDurationMs: 980,
                languageSwitchLatencyMs: 240
            ),
            TranscriptionBenchmarkCase(
                id: "private-mic-jargon",
                audioFilePath: privateMicEvidence.path,
                reference: "I can confirm the Notchly microphone side keeps Core ML",
                hypothesis: "I can confirm the Notchly microphone side keeps Core ML",
                locale: "en-US",
                activeVocabulary: ["Notchly", "Core ML"],
                namedEntities: ["Notchly"],
                corpus: .privateMeetingPack,
                evaluationTags: [.meeting, .jargon],
                evidenceKind: privateMicEvidence.kind,
                audioSHA256: privateMicEvidence.sha256,
                corpusProvenance: privateMicProvenance,
                hypothesisSource: privateMicTranscript.source,
                hypothesisEngineIdentifier: privateMicTranscript.engineIdentifier,
                hypothesisRunID: privateMicTranscript.runID,
                hypothesisTranscriptFilePath: privateMicTranscript.path,
                hypothesisTranscriptSHA256: privateMicTranscript.sha256,
                firstPartialLatencyMs: 310,
                finalLatencyMs: 1_050,
                audioDurationMs: 2_200,
                processingDurationMs: 820
            ),
            TranscriptionBenchmarkCase(
                id: "ami-overlap-far-field",
                audioFilePath: amiEvidence.path,
                reference: "we need to resolve the deployment risk before the meeting ends",
                hypothesis: "we need to resolve the deployment risk before the meeting ends",
                locale: "en-US",
                namedEntities: ["deployment"],
                corpus: .ami,
                evaluationTags: [.meeting, .farField, .overlap, .reverb],
                evidenceKind: amiEvidence.kind,
                audioSHA256: amiEvidence.sha256,
                corpusProvenance: amiProvenance,
                hypothesisSource: amiTranscript.source,
                hypothesisEngineIdentifier: amiTranscript.engineIdentifier,
                hypothesisRunID: amiTranscript.runID,
                hypothesisTranscriptFilePath: amiTranscript.path,
                hypothesisTranscriptSHA256: amiTranscript.sha256,
                firstPartialLatencyMs: 410,
                finalLatencyMs: 1_320,
                audioDurationMs: 4_000,
                processingDurationMs: 1_900
            ),
            TranscriptionBenchmarkCase(
                id: "fleurs-spanish",
                audioFilePath: fleursEvidence.path,
                reference: "validemos el cambio de idioma antes de publicar",
                hypothesis: "validemos el cambio de idioma antes de publicar",
                locale: "es-ES",
                corpus: .fleurs,
                evaluationTags: [.multilingual, .lowVolume],
                evidenceKind: fleursEvidence.kind,
                audioSHA256: fleursEvidence.sha256,
                corpusProvenance: fleursProvenance,
                hypothesisSource: fleursTranscript.source,
                hypothesisEngineIdentifier: fleursTranscript.engineIdentifier,
                hypothesisRunID: fleursTranscript.runID,
                hypothesisTranscriptFilePath: fleursTranscript.path,
                hypothesisTranscriptSHA256: fleursTranscript.sha256,
                firstPartialLatencyMs: 360,
                finalLatencyMs: 1_100,
                audioDurationMs: 2_400,
                processingDurationMs: 900
            ),
            TranscriptionBenchmarkCase(
                id: "voxlingua-japanese-lid",
                audioFilePath: voxEvidence.path,
                reference: "モデルの言語判定を確認します",
                hypothesis: "モデルの言語判定を確認します",
                locale: "ja-JP",
                corpus: .voxLingua107,
                evaluationTags: [.spokenLanguageID, .multilingual],
                evidenceKind: voxEvidence.kind,
                audioSHA256: voxEvidence.sha256,
                corpusProvenance: voxProvenance,
                hypothesisSource: voxTranscript.source,
                hypothesisEngineIdentifier: voxTranscript.engineIdentifier,
                hypothesisRunID: voxTranscript.runID,
                hypothesisTranscriptFilePath: voxTranscript.path,
                hypothesisTranscriptSHA256: voxTranscript.sha256,
                firstPartialLatencyMs: 420,
                finalLatencyMs: 1_250,
                audioDurationMs: 2_800,
                processingDurationMs: 1_200,
                languageSwitchLatencyMs: 310
            ),
            TranscriptionBenchmarkCase(
                id: "earnings-entity-dense",
                audioFilePath: earningsEvidence.path,
                reference: "Net revenue reached ARR and EBITDA targets for Notchly",
                hypothesis: "Net revenue reached ARR and EBITDA targets for Notchly",
                locale: "en-US",
                activeVocabulary: ["ARR", "EBITDA", "Notchly"],
                namedEntities: ["ARR", "EBITDA", "Notchly"],
                corpus: .earnings21,
                evaluationTags: [.entityDense, .jargon, .clipping],
                evidenceKind: earningsEvidence.kind,
                audioSHA256: earningsEvidence.sha256,
                corpusProvenance: earningsProvenance,
                hypothesisSource: earningsTranscript.source,
                hypothesisEngineIdentifier: earningsTranscript.engineIdentifier,
                hypothesisRunID: earningsTranscript.runID,
                hypothesisTranscriptFilePath: earningsTranscript.path,
                hypothesisTranscriptSHA256: earningsTranscript.sha256,
                firstPartialLatencyMs: 390,
                finalLatencyMs: 1_220,
                audioDurationMs: 3_100,
                processingDurationMs: 1_100
            ),
            TranscriptionBenchmarkCase(
                id: "conec-contextual-bias",
                audioFilePath: conecEvidence.path,
                reference: "Ichimoku and retrieval augmented generation were corrected",
                hypothesis: "Ichimoku and retrieval augmented generation were corrected",
                locale: "en-US",
                activeVocabulary: ["Ichimoku", "retrieval augmented generation"],
                namedEntities: ["Ichimoku"],
                corpus: .conec,
                evaluationTags: [.contextualBias, .jargon],
                evidenceKind: conecEvidence.kind,
                audioSHA256: conecEvidence.sha256,
                corpusProvenance: conecProvenance,
                hypothesisSource: conecTranscript.source,
                hypothesisEngineIdentifier: conecTranscript.engineIdentifier,
                hypothesisRunID: conecTranscript.runID,
                hypothesisTranscriptFilePath: conecTranscript.path,
                hypothesisTranscriptSHA256: conecTranscript.sha256,
                firstPartialLatencyMs: 340,
                finalLatencyMs: 1_180,
                audioDurationMs: 2_900,
                processingDurationMs: 1_000
            )
        ]
        let cases = rawCases.map { testCase in
            var measured = testCase
            measured.memoryResidentBytes = measured.memoryResidentBytes ?? 384_000_000
            measured.cpuUsagePercent = measured.cpuUsagePercent ?? 24
            if measured.firstPartialLatencyMs != nil || measured.finalLatencyMs != nil {
                measured.latencyMeasurementMode = measured.latencyMeasurementMode ?? .realtimeReplay
                measured.replayChunkDurationMs = measured.replayChunkDurationMs ?? 100
            }
            return measured
        }

        var policy = TranscriptionReleaseGatePolicy.topTierRelease
        policy.requireNonTemporaryAudioEvidenceForExternalCorpora = false
        policy.minimumCaseCountsByCorpus = [:]
        policy.minimumUniqueSampleCountsByCorpus = [:]
        policy.minimumUniqueAudioChecksumCountsByCorpus = [:]
        policy.minimumTotalAudioDurationMsByCorpus = [:]
        policy.requiredLocalesByCorpus = [:]
        policy.requiredTagsByCorpus = [:]

        let report = TranscriptionReleaseGate().evaluate(cases: cases, policy: policy)

        XCTAssertTrue(report.passed, report.failures.joined(separator: ", "))
        XCTAssertTrue(report.failedCaseIDs.isEmpty)
        XCTAssertEqual(report.benchmarkSummary.passedCaseCount, cases.count)
        XCTAssertEqual(Set(report.coverage.map(\.corpus)), Set(policy.requiredCorpora))
        XCTAssertGreaterThan(report.coverage.first { $0.corpus == .privateMeetingPack }?.localRefinerDecisionCount ?? 0, 0)
        XCTAssertGreaterThan(report.coverage.first { $0.corpus == .earnings21 }?.localRefinerDecisionCount ?? 0, 0)
        XCTAssertGreaterThan(report.coverage.first { $0.corpus == .conec }?.localRefinerDecisionCount ?? 0, 0)
        XCTAssertGreaterThan(report.coverage.first { $0.corpus == .privateMeetingPack }?.localRefinerAcceptedCount ?? 0, 0)
        XCTAssertGreaterThan(report.coverage.first { $0.corpus == .earnings21 }?.localRefinerAcceptedCount ?? 0, 0)
        XCTAssertGreaterThan(report.coverage.first { $0.corpus == .conec }?.localRefinerAcceptedCount ?? 0, 0)
        XCTAssertLessThanOrEqual(report.benchmarkSummary.firstPartialP95Ms ?? 9_999, 500)
        XCTAssertLessThanOrEqual(report.benchmarkSummary.finalLatencyP95Ms ?? 9_999, 1_500)
    }

    func testTranscriptionEvaluationRunnerResolvesManifestRelativeAudioPaths() throws {
        let manifestDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchly-manifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: manifestDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: manifestDirectory) }
        let evidence = try Self.releaseGateAudioEvidence(
            id: "ami-relative-audio",
            kind: .publicCorpus,
            directory: manifestDirectory.appendingPathComponent("audio", isDirectory: true)
        )
        let provenance = Self.publicCorpusProvenance(.ami, sampleID: "ami-relative-audio")
        let transcriptEvidence = try Self.releaseGateHypothesisEvidence(
            id: "ami-relative-audio",
            hypothesis: "we should validate real manifest audio",
            source: .speechAnalyzer,
            locale: "en-US",
            engineIdentifier: "notchly-speechanalyzer-evaluation",
            runID: "manifest-relative-run",
            audioSHA256: evidence.sha256,
            audioDurationMs: 3_000,
            latencyMeasurementMode: .realtimeReplay,
            replayChunkDurationMs: 120,
            corpusProvenance: provenance,
            directory: manifestDirectory.appendingPathComponent("transcripts", isDirectory: true)
        )
        let baselineTranscriptEvidence = try Self.releaseGateHypothesisEvidence(
            id: "ami-relative-audio",
            hypothesis: "we should validate manifest audio",
            source: .speechAnalyzer,
            locale: "en-US",
            engineIdentifier: "notchly-speechanalyzer-baseline",
            runID: "manifest-relative-baseline-run",
            audioSHA256: evidence.sha256,
            audioDurationMs: 3_000,
            audioSource: .system,
            corpusProvenance: provenance,
            directory: manifestDirectory.appendingPathComponent("baseline-transcripts", isDirectory: true)
        )
        let relativeAudioPath = "audio/ami-relative-audio.wav"
        let relativeTranscriptPath = "transcripts/ami-relative-audio.transcript.json"
        let relativeBaselineTranscriptPath = "baseline-transcripts/ami-relative-audio.transcript.json"
        let manifest = TranscriptionEvaluationManifest(
            suiteName: "manifest-relative-path-smoke",
            cases: [
                TranscriptionBenchmarkCase(
                    id: "ami-relative-audio",
                    audioFilePath: relativeAudioPath,
                    audioSource: .system,
                    reference: "we should validate real manifest audio",
                    hypothesis: "we should validate real manifest audio",
                    locale: "en-US",
                    corpus: .ami,
                    evaluationTags: [.meeting],
                    evidenceKind: evidence.kind,
                    audioSHA256: evidence.sha256,
                    corpusProvenance: provenance,
                    hypothesisSource: transcriptEvidence.source,
                    hypothesisEngineIdentifier: transcriptEvidence.engineIdentifier,
                    hypothesisRunID: transcriptEvidence.runID,
                    hypothesisTranscriptFilePath: relativeTranscriptPath,
                    hypothesisTranscriptSHA256: transcriptEvidence.sha256,
                    firstPartialLatencyMs: 420,
                    finalLatencyMs: 1_200,
                    audioDurationMs: 3_000,
                    processingDurationMs: 1_100,
                    latencyMeasurementMode: .realtimeReplay,
                    replayChunkDurationMs: 120,
                    memoryResidentBytes: 384_000_000,
                    cpuUsagePercent: 18
                )
            ],
            baselineCases: [
                TranscriptionBenchmarkCase(
                    id: "ami-relative-audio",
                    audioSource: .system,
                    reference: "we should validate real manifest audio",
                    hypothesis: "we should validate manifest audio",
                    locale: "en-US",
                    corpus: .ami,
                    evaluationTags: [.meeting],
                    evidenceKind: evidence.kind,
                    audioSHA256: evidence.sha256,
                    corpusProvenance: provenance,
                    hypothesisSource: baselineTranscriptEvidence.source,
                    hypothesisEngineIdentifier: baselineTranscriptEvidence.engineIdentifier,
                    hypothesisRunID: baselineTranscriptEvidence.runID,
                    hypothesisTranscriptFilePath: relativeBaselineTranscriptPath,
                    hypothesisTranscriptSHA256: baselineTranscriptEvidence.sha256,
                    audioDurationMs: 3_000,
                    processingDurationMs: 1_400
                )
            ]
        )
        let manifestURL = manifestDirectory.appendingPathComponent("transcription-eval.json")
        try Self.writeManifest(manifest, to: manifestURL)

        var policy = TranscriptionReleaseGatePolicy.topTierRelease
        policy.requiredCorpora = [.ami]
        policy.requiredLocales = ["en-US"]
        policy.requiredTags = [.meeting]
        policy.requireNonTemporaryAudioEvidenceForExternalCorpora = false
        policy.minimumCaseCountsByCorpus = [:]
        policy.minimumUniqueSampleCountsByCorpus = [:]
        policy.minimumUniqueAudioChecksumCountsByCorpus = [:]
        policy.minimumTotalAudioDurationMsByCorpus = [:]
        policy.requiredLocalesByCorpus = [:]
        policy.requiredTagsByCorpus = [:]

        let report = try TranscriptionEvaluationRunner().evaluate(manifestAt: manifestURL, policy: policy)

        XCTAssertTrue(report.passed, (report.releaseGateReport.failures + report.improvementGateFailures).joined(separator: ", "))
        XCTAssertEqual(report.suiteName, "manifest-relative-path-smoke")
        XCTAssertEqual(report.manifestCaseCount, 1)
        XCTAssertEqual(report.baselineCaseCount, 1)
        XCTAssertTrue(report.improvementGateFailures.isEmpty)
        XCTAssertEqual(report.improvementComparisonReport?.comparisonSummary.comparableCaseCount, 1)
        XCTAssertEqual(report.audioEvidenceCaseCount, 1)
        XCTAssertEqual(report.hypothesisEvidenceCaseCount, 1)
    }

    func testTranscriptionEvaluationRunnerRejectsMissingBaselineComparison() {
        let manifest = TranscriptionEvaluationManifest(
            suiteName: "missing-baseline-comparison",
            cases: [
                TranscriptionBenchmarkCase(
                    id: "candidate-only",
                    reference: "candidate evidence alone is not enough for top tier",
                    hypothesis: "candidate evidence alone is not enough for top tier",
                    locale: "en-US",
                    corpus: .internalCritical,
                    firstPartialLatencyMs: 300,
                    finalLatencyMs: 900,
                    audioDurationMs: 3_000,
                    processingDurationMs: 1_000,
                    latencyMeasurementMode: .liveCapture,
                    memoryResidentBytes: 320_000_000,
                    cpuUsagePercent: 12
                )
            ]
        )
        var policy = TranscriptionReleaseGatePolicy.topTierRelease
        policy.requiredCorpora = [.internalCritical]
        policy.requiredLocales = ["en-US"]
        policy.requiredTags = []
        policy.minimumCaseCountsByCorpus = [.internalCritical: 1]
        policy.minimumUniqueSampleCountsByCorpus = [:]
        policy.minimumUniqueAudioChecksumCountsByCorpus = [:]
        policy.minimumTotalAudioDurationMsByCorpus = [:]
        policy.requiredLocalesByCorpus = [:]
        policy.requiredTagsByCorpus = [:]
        policy.requireAudioEvidenceForRequiredCorpora = false
        policy.requireASRHypothesisEvidenceForRequiredCorpora = false

        let report = TranscriptionEvaluationRunner().evaluate(manifest: manifest, policy: policy)

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.releaseGateReport.passed, report.releaseGateReport.failures.joined(separator: ", "))
        XCTAssertEqual(report.baselineCaseCount, 0)
        XCTAssertTrue(report.improvementGateFailures.contains("missing_baseline_comparison_cases"))
    }

    func testTranscriptionEvaluationReplayRunnerGeneratesASRHypothesisEvidenceFromAudio() async throws {
        let manifestDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchly-asr-replay-\(UUID().uuidString)", isDirectory: true)
        let audioDirectory = manifestDirectory.appendingPathComponent("audio", isDirectory: true)
        let outputDirectory = manifestDirectory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: manifestDirectory) }

        let audioURL = audioDirectory.appendingPathComponent("internal-replay-speech.wav")
        try Self.writeReleaseGateWaveFile(
            to: audioURL,
            buffers: TranscriptionAudioFixtureGenerator.buffers(profile: .clean, source: .system, chunks: 10)
        )
        let baselineAudioSHA256 = try Self.sha256HexDigest(of: audioURL)
        let reference = "SpeechAnalyzer preserves Notchly and Core ML jargon"
        let baselineTranscriptEvidence = try Self.releaseGateHypothesisEvidence(
            id: "internal-replay-speech",
            hypothesis: "Speech analyzer preserves jargon",
            source: .speechAnalyzer,
            locale: "en-US",
            engineIdentifier: "notchly-speechanalyzer-baseline",
            runID: "unit-asr-baseline-replay",
            audioSHA256: baselineAudioSHA256,
            audioDurationMs: 1_000,
            audioSource: .system,
            directory: manifestDirectory.appendingPathComponent("baseline-transcripts", isDirectory: true)
        )
        let manifest = TranscriptionEvaluationManifest(
            suiteName: "asr-replay-evidence-smoke",
            cases: [
                TranscriptionBenchmarkCase(
                    id: "internal-replay-speech",
                    audioFilePath: "audio/internal-replay-speech.wav",
                    reference: reference,
                    hypothesis: "",
                    locale: "en-US",
                    activeVocabulary: ["SpeechAnalyzer", "Core ML"],
                    namedEntities: ["Notchly"],
                    corpus: .internalCritical,
                    evaluationTags: [.meeting, .jargon, .contextualBias],
                    evidenceKind: .generatedFixture
                )
            ],
            baselineCases: [
                TranscriptionBenchmarkCase(
                    id: "internal-replay-speech",
                    audioSource: .system,
                    reference: reference,
                    hypothesis: "Speech analyzer preserves jargon",
                    locale: "en-US",
                    activeVocabulary: ["SpeechAnalyzer", "Core ML"],
                    namedEntities: ["Notchly"],
                    corpus: .internalCritical,
                    evaluationTags: [.meeting, .jargon, .contextualBias],
                    evidenceKind: .generatedFixture,
                    audioSHA256: baselineAudioSHA256,
                    hypothesisSource: baselineTranscriptEvidence.source,
                    hypothesisEngineIdentifier: baselineTranscriptEvidence.engineIdentifier,
                    hypothesisRunID: baselineTranscriptEvidence.runID,
                    hypothesisTranscriptFilePath: baselineTranscriptEvidence.path,
                    hypothesisTranscriptSHA256: baselineTranscriptEvidence.sha256,
                    firstPartialLatencyMs: 480,
                    finalLatencyMs: 1_400,
                    audioDurationMs: 1_000,
                    processingDurationMs: 1_000
                )
            ]
        )

        let plannedSegments = [
            TranscriptSegment(
                meetingId: UUID(),
                audioSource: .system,
                text: "SpeechAnalyzer preserves",
                originalLanguage: "en-US",
                transcriptionPhase: .draft,
                transcriptionEngine: .speechAnalyzer,
                startTime: 0,
                endTime: 0.35,
                confidence: 0.72,
                isFinal: false
            ),
            TranscriptSegment(
                meetingId: UUID(),
                audioSource: .system,
                text: reference,
                originalLanguage: "en-US",
                transcriptionPhase: .final,
                transcriptionEngine: .speechAnalyzer,
                finalizedBy: .speechAnalyzer,
                startTime: 0,
                endTime: 1.0,
                confidence: 0.95,
                isFinal: true
            )
        ]
        let service = ScriptedReplayTranscriptionService(plannedSegments: plannedSegments)
        let runner = TranscriptionEvaluationReplayRunner(serviceFactory: { audioStream, source in
            StreamingASRRouter(
                sources: [
                    StreamingASRRouter.Source(
                        speakerLabel: "System",
                        audioSource: source,
                        audioStream: audioStream
                    )
                ],
                serviceFactory: { _ in service }
            )
        })

        var policy = TranscriptionReleaseGatePolicy.topTierRelease
        policy.requiredCorpora = [.internalCritical]
        policy.requiredLocales = ["en-US"]
        policy.requiredTags = [.meeting, .jargon, .contextualBias]
        policy.minimumCaseCountsByCorpus = [.internalCritical: 1]
        policy.minimumUniqueSampleCountsByCorpus = [:]
        policy.minimumUniqueAudioChecksumCountsByCorpus = [.internalCritical: 1]
        policy.minimumTotalAudioDurationMsByCorpus = [.internalCritical: 900]
        policy.requiredLocalesByCorpus = [:]
        policy.requiredTagsByCorpus = [:]
        policy.requiredAudioSourcesByCorpus = [.internalCritical: [.system]]
        policy.thresholds.maxFirstPartialLatencyMs = 1_500
        policy.thresholds.maxRealTimeFactor = 2.0

        let report = try await runner.replay(
            manifest: manifest,
            baseURL: manifestDirectory,
            outputDirectory: outputDirectory,
            baseConfig: Self.makeConfig(featureFlags: TranscriptionFeatureFlags(transcriptionMetricsEnabled: true)),
            policy: policy,
            configuration: TranscriptionEvaluationReplayConfiguration(
                runID: "unit-asr-replay",
                chunkDurationMs: 100,
                postAudioDrainMs: 25,
                replayInRealTime: true,
                audioSource: .system,
                hypothesisSource: .speechAnalyzer,
                engineIdentifier: "notchly-speechanalyzer-replay-unit",
                generatedAt: "2026-05-29T00:00:00Z"
            )
        )

        XCTAssertTrue(report.passed, (report.evaluationReport.releaseGateReport.failures + report.evaluationReport.improvementGateFailures).joined(separator: ", "))
        XCTAssertEqual(report.manifest.baselineCases?.count, 1)
        XCTAssertEqual(report.evaluationReport.improvementComparisonReport?.comparisonSummary.comparableCaseCount, 1)
        XCTAssertGreaterThan(service.consumedBufferCount, 0)
        XCTAssertEqual(report.manifest.cases.first?.hypothesis, reference)
        XCTAssertEqual(report.manifest.cases.first?.hypothesisSource, .speechAnalyzer)
        XCTAssertEqual(report.manifest.cases.first?.hypothesisEngineIdentifier, "notchly-speechanalyzer-replay-unit")
        XCTAssertEqual(report.manifest.cases.first?.hypothesisRunID, "unit-asr-replay")
        XCTAssertNotNil(report.manifest.cases.first?.firstPartialLatencyMs)
        XCTAssertNotNil(report.manifest.cases.first?.finalLatencyMs)
        XCTAssertEqual(report.manifest.cases.first?.latencyMeasurementMode, .realtimeReplay)
        XCTAssertEqual(report.manifest.cases.first?.replayChunkDurationMs, 100)
        XCTAssertGreaterThan(report.manifest.cases.first?.memoryResidentBytes ?? 0, 0)
        XCTAssertGreaterThanOrEqual(report.manifest.cases.first?.cpuUsagePercent ?? -1, 0)
        XCTAssertEqual(report.caseReports.first?.latencyMeasurementMode, .realtimeReplay)
        XCTAssertEqual(report.caseReports.first?.replayChunkDurationMs, 100)
        XCTAssertEqual(report.caseReports.first?.memoryResidentBytes, report.manifest.cases.first?.memoryResidentBytes)
        XCTAssertEqual(report.caseReports.first?.cpuUsagePercent, report.manifest.cases.first?.cpuUsagePercent)
        XCTAssertEqual(report.caseReports.first?.segmentCount, 1)

        guard let transcriptPath = report.manifest.cases.first?.hypothesisTranscriptFilePath else {
            return XCTFail("Replay runner should write hypothesis transcript evidence")
        }
        let transcriptData = try Data(contentsOf: URL(fileURLWithPath: transcriptPath))
        let transcriptEvidence = try JSONDecoder().decode(TranscriptionHypothesisTranscriptEvidence.self, from: transcriptData)
        XCTAssertEqual(transcriptEvidence.caseID, "internal-replay-speech")
        XCTAssertEqual(transcriptEvidence.hypothesis, reference)
        XCTAssertEqual(transcriptEvidence.source, .speechAnalyzer)
        XCTAssertEqual(transcriptEvidence.segmentCount, 1)
        XCTAssertEqual(transcriptEvidence.segments?.count, 1)
        XCTAssertEqual(transcriptEvidence.segments?.first?.audioSource, .system)
        XCTAssertEqual(transcriptEvidence.segments?.first?.transcriptionPhase, .final)
        XCTAssertEqual(transcriptEvidence.segments?.first?.transcriptionEngine, .speechAnalyzer)
        XCTAssertEqual(transcriptEvidence.audioSHA256, report.manifest.cases.first?.audioSHA256)
        XCTAssertEqual(transcriptEvidence.audioConditioning?.audioSource, .system)
        XCTAssertEqual(transcriptEvidence.audioConditioning?.vadGatingEnabled, true)
        XCTAssertGreaterThan(transcriptEvidence.audioConditioning?.inputBufferCount ?? 0, 0)
        XCTAssertGreaterThan(transcriptEvidence.audioConditioning?.forwardedDecisionCount ?? 0, 0)
        XCTAssertGreaterThan(transcriptEvidence.audioConditioning?.speechDecisionCount ?? 0, 0)
        XCTAssertEqual(service.consumedBufferCount, transcriptEvidence.audioConditioning?.emittedBufferCount)
        XCTAssertEqual(transcriptEvidence.latencyMeasurementMode, .realtimeReplay)
        XCTAssertEqual(transcriptEvidence.replayChunkDurationMs, 100)
    }

    func testTranscriptionEvaluationReplayRunnerHonorsPerCaseAudioSourcesForSourceSeparatedCertification() async throws {
        let manifestDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchly-asr-replay-sources-\(UUID().uuidString)", isDirectory: true)
        let audioDirectory = manifestDirectory.appendingPathComponent("audio", isDirectory: true)
        let outputDirectory = manifestDirectory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: manifestDirectory) }

        let systemAudioURL = audioDirectory.appendingPathComponent("internal-system.wav")
        try Self.writeReleaseGateWaveFile(
            to: systemAudioURL,
            buffers: TranscriptionAudioFixtureGenerator.buffers(profile: .clean, source: .system, chunks: 10)
        )
        let systemAudioSHA256 = try Self.sha256HexDigest(of: systemAudioURL)
        let microphoneAudioURL = audioDirectory.appendingPathComponent("internal-microphone.wav")
        try Self.writeReleaseGateWaveFile(
            to: microphoneAudioURL,
            buffers: TranscriptionAudioFixtureGenerator.buffers(profile: .noisy, source: .microphone, chunks: 10)
        )
        let microphoneAudioSHA256 = try Self.sha256HexDigest(of: microphoneAudioURL)

        let reference = "heard Core ML"
        let systemBaselineTranscriptEvidence = try Self.releaseGateHypothesisEvidence(
            id: "internal-system-speech",
            hypothesis: "heard mail",
            source: .speechAnalyzer,
            locale: "en-US",
            engineIdentifier: "notchly-speechanalyzer-baseline",
            runID: "unit-asr-source-baseline-system",
            audioSHA256: systemAudioSHA256,
            audioDurationMs: 1_000,
            audioSource: .system,
            directory: manifestDirectory.appendingPathComponent("baseline-transcripts", isDirectory: true)
        )
        let microphoneBaselineTranscriptEvidence = try Self.releaseGateHypothesisEvidence(
            id: "internal-microphone-speech",
            hypothesis: "heard mail",
            source: .speechAnalyzer,
            locale: "en-US",
            engineIdentifier: "notchly-speechanalyzer-baseline",
            runID: "unit-asr-source-baseline-microphone",
            audioSHA256: microphoneAudioSHA256,
            audioDurationMs: 1_000,
            audioSource: .microphone,
            directory: manifestDirectory.appendingPathComponent("baseline-transcripts", isDirectory: true)
        )
        let manifest = TranscriptionEvaluationManifest(
            suiteName: "asr-replay-source-separated-smoke",
            cases: [
                TranscriptionBenchmarkCase(
                    id: "internal-system-speech",
                    audioFilePath: "audio/internal-system.wav",
                    audioSource: .system,
                    reference: reference,
                    hypothesis: "",
                    locale: "en-US",
                    activeVocabulary: ["Core ML"],
                    corpus: .internalCritical,
                    evaluationTags: [.meeting, .jargon],
                    evidenceKind: .generatedFixture
                ),
                TranscriptionBenchmarkCase(
                    id: "internal-microphone-speech",
                    audioFilePath: "audio/internal-microphone.wav",
                    audioSource: .microphone,
                    reference: reference,
                    hypothesis: "",
                    locale: "en-US",
                    activeVocabulary: ["Core ML"],
                    corpus: .internalCritical,
                    evaluationTags: [.meeting, .jargon],
                    evidenceKind: .generatedFixture
                )
            ],
            baselineCases: [
                TranscriptionBenchmarkCase(
                    id: "internal-system-speech",
                    audioSource: .system,
                    reference: reference,
                    hypothesis: "heard mail",
                    locale: "en-US",
                    activeVocabulary: ["Core ML"],
                    corpus: .internalCritical,
                    evaluationTags: [.meeting, .jargon],
                    evidenceKind: .generatedFixture,
                    audioSHA256: systemAudioSHA256,
                    hypothesisSource: systemBaselineTranscriptEvidence.source,
                    hypothesisEngineIdentifier: systemBaselineTranscriptEvidence.engineIdentifier,
                    hypothesisRunID: systemBaselineTranscriptEvidence.runID,
                    hypothesisTranscriptFilePath: systemBaselineTranscriptEvidence.path,
                    hypothesisTranscriptSHA256: systemBaselineTranscriptEvidence.sha256,
                    firstPartialLatencyMs: 480,
                    finalLatencyMs: 1_400,
                    audioDurationMs: 1_000,
                    processingDurationMs: 1_000
                ),
                TranscriptionBenchmarkCase(
                    id: "internal-microphone-speech",
                    audioSource: .microphone,
                    reference: reference,
                    hypothesis: "heard mail",
                    locale: "en-US",
                    activeVocabulary: ["Core ML"],
                    corpus: .internalCritical,
                    evaluationTags: [.meeting, .jargon],
                    evidenceKind: .generatedFixture,
                    audioSHA256: microphoneAudioSHA256,
                    hypothesisSource: microphoneBaselineTranscriptEvidence.source,
                    hypothesisEngineIdentifier: microphoneBaselineTranscriptEvidence.engineIdentifier,
                    hypothesisRunID: microphoneBaselineTranscriptEvidence.runID,
                    hypothesisTranscriptFilePath: microphoneBaselineTranscriptEvidence.path,
                    hypothesisTranscriptSHA256: microphoneBaselineTranscriptEvidence.sha256,
                    firstPartialLatencyMs: 480,
                    finalLatencyMs: 1_400,
                    audioDurationMs: 1_000,
                    processingDurationMs: 1_000
                )
            ]
        )

        let runner = TranscriptionEvaluationReplayRunner(serviceFactory: { audioStream, source in
            StreamingASRRouter(
                sources: [
                    StreamingASRRouter.Source(
                        speakerLabel: source == .microphone ? "You" : "System",
                        audioSource: source,
                        audioStream: audioStream
                    )
                ],
                serviceFactory: { _ in EchoOnAudioTranscriptionService() }
            )
        })
        var policy = TranscriptionReleaseGatePolicy.topTierRelease
        policy.requiredCorpora = [.internalCritical]
        policy.requiredLocales = ["en-US"]
        policy.requiredTags = [.meeting, .jargon]
        policy.minimumCaseCountsByCorpus = [.internalCritical: 2]
        policy.minimumUniqueSampleCountsByCorpus = [:]
        policy.minimumUniqueAudioChecksumCountsByCorpus = [.internalCritical: 2]
        policy.minimumTotalAudioDurationMsByCorpus = [.internalCritical: 1_800]
        policy.requiredLocalesByCorpus = [:]
        policy.requiredTagsByCorpus = [:]
        policy.requiredAudioSourcesByCorpus = [.internalCritical: [.microphone, .system]]
        policy.thresholds.maxFirstPartialLatencyMs = 1_500
        policy.thresholds.maxFinalLatencyMs = 1_500
        policy.thresholds.maxRealTimeFactor = 2.0

        let report = try await runner.replay(
            manifest: manifest,
            baseURL: manifestDirectory,
            outputDirectory: outputDirectory,
            baseConfig: Self.makeConfig(featureFlags: TranscriptionFeatureFlags(transcriptionMetricsEnabled: true)),
            policy: policy,
            configuration: TranscriptionEvaluationReplayConfiguration(
                runID: "unit-asr-replay-source-separated",
                chunkDurationMs: 100,
                postAudioDrainMs: 25,
                replayInRealTime: true,
                audioSource: .system,
                hypothesisSource: .speechAnalyzer,
                engineIdentifier: "notchly-source-separated-replay-unit",
                generatedAt: "2026-05-29T00:00:00Z"
            )
        )

        XCTAssertTrue(report.passed, (report.evaluationReport.releaseGateReport.failures + report.evaluationReport.improvementGateFailures).joined(separator: ", "))
        XCTAssertEqual(report.evaluationReport.releaseGateReport.coverage.first?.audioSources, [.microphone, .system])
        XCTAssertEqual(report.caseReports.compactMap(\.audioSource), [.system, .microphone])
        XCTAssertEqual(report.manifest.cases.compactMap(\.audioSource), [.system, .microphone])
        XCTAssertEqual(report.manifest.cases.map(\.hypothesis), [reference, reference])

        for replayedCase in report.manifest.cases {
            guard let transcriptPath = replayedCase.hypothesisTranscriptFilePath else {
                return XCTFail("Replay runner should write source-tagged transcript evidence for \(replayedCase.id)")
            }
            let transcriptData = try Data(contentsOf: URL(fileURLWithPath: transcriptPath))
            let evidence = try JSONDecoder().decode(TranscriptionHypothesisTranscriptEvidence.self, from: transcriptData)
            XCTAssertEqual(evidence.segments?.first?.audioSource, replayedCase.audioSource)
            XCTAssertEqual(evidence.audioConditioning?.audioSource, replayedCase.audioSource)
        }
    }

    func testTranscriptionEvaluationReplayRunnerPersistsRejectedLocalRefinerDecisionEvidence() async throws {
        let manifestDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchly-asr-replay-refiner-rejected-\(UUID().uuidString)", isDirectory: true)
        let audioDirectory = manifestDirectory.appendingPathComponent("audio", isDirectory: true)
        let outputDirectory = manifestDirectory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: manifestDirectory) }

        let audioURL = audioDirectory.appendingPathComponent("private-refiner-rejected.wav")
        try Self.writeReleaseGateWaveFile(
            to: audioURL,
            buffers: TranscriptionAudioFixtureGenerator.buffers(profile: .clean, source: .microphone, chunks: 10)
        )
        let baselineAudioSHA256 = try Self.sha256HexDigest(of: audioURL)
        let provenance = Self.privateCorpusProvenance(sampleID: "private-refiner-rejected")
        let reference = "heard Core ML"
        let baselineTranscriptEvidence = try Self.releaseGateHypothesisEvidence(
            id: "private-refiner-rejected",
            hypothesis: "heard mail",
            source: .speechAnalyzer,
            locale: "en-US",
            engineIdentifier: "notchly-speechanalyzer-baseline",
            runID: "unit-asr-refiner-baseline",
            audioSHA256: baselineAudioSHA256,
            audioDurationMs: 1_000,
            audioSource: .microphone,
            corpusProvenance: provenance,
            directory: manifestDirectory.appendingPathComponent("baseline-transcripts", isDirectory: true)
        )
        let manifest = TranscriptionEvaluationManifest(
            suiteName: "asr-replay-refiner-rejection-evidence",
            cases: [
                TranscriptionBenchmarkCase(
                    id: "private-refiner-rejected",
                    audioFilePath: "audio/private-refiner-rejected.wav",
                    audioSource: .microphone,
                    reference: reference,
                    hypothesis: "",
                    locale: "en-US",
                    activeVocabulary: ["Core ML"],
                    corpus: .privateMeetingPack,
                    evaluationTags: [.meeting, .jargon],
                    evidenceKind: .privateCorpus,
                    corpusProvenance: provenance
                )
            ],
            baselineCases: [
                TranscriptionBenchmarkCase(
                    id: "private-refiner-rejected",
                    audioSource: .microphone,
                    reference: reference,
                    hypothesis: "heard mail",
                    locale: "en-US",
                    activeVocabulary: ["Core ML"],
                    corpus: .privateMeetingPack,
                    evaluationTags: [.meeting, .jargon],
                    evidenceKind: .privateCorpus,
                    audioSHA256: baselineAudioSHA256,
                    corpusProvenance: provenance,
                    hypothesisSource: baselineTranscriptEvidence.source,
                    hypothesisEngineIdentifier: baselineTranscriptEvidence.engineIdentifier,
                    hypothesisRunID: baselineTranscriptEvidence.runID,
                    hypothesisTranscriptFilePath: baselineTranscriptEvidence.path,
                    hypothesisTranscriptSHA256: baselineTranscriptEvidence.sha256,
                    firstPartialLatencyMs: 480,
                    finalLatencyMs: 1_400,
                    audioDurationMs: 1_000,
                    processingDurationMs: 1_000
                )
            ]
        )
        let runner = TranscriptionEvaluationReplayRunner(serviceFactory: { audioStream, source in
            StreamingASRRouter(
                sources: [
                    StreamingASRRouter.Source(
                        speakerLabel: "You",
                        audioSource: source,
                        audioStream: audioStream
                    )
                ],
                refiner: RejectingLocalASRRefiner(),
                serviceFactory: { _ in EchoOnAudioTranscriptionService() }
            )
        })
        var policy = TranscriptionReleaseGatePolicy.topTierRelease
        policy.requiredCorpora = [.privateMeetingPack]
        policy.requiredLocales = ["en-US"]
        policy.requiredTags = [.meeting, .jargon]
        policy.minimumCaseCountsByCorpus = [.privateMeetingPack: 1]
        policy.minimumUniqueSampleCountsByCorpus = [.privateMeetingPack: 1]
        policy.minimumUniqueAudioChecksumCountsByCorpus = [.privateMeetingPack: 1]
        policy.minimumTotalAudioDurationMsByCorpus = [.privateMeetingPack: 900]
        policy.requiredLocalesByCorpus = [.privateMeetingPack: ["en-US"]]
        policy.requiredTagsByCorpus = [.privateMeetingPack: [.meeting, .jargon]]
        policy.requiredAudioSourcesByCorpus = [.privateMeetingPack: [.microphone]]
        policy.requiredLocalRefinerAcceptedEvidenceCorpora = []
        policy.requireNonTemporaryAudioEvidenceForExternalCorpora = false
        policy.thresholds.maxRealTimeFactor = 2.0

        let report = try await runner.replay(
            manifest: manifest,
            baseURL: manifestDirectory,
            outputDirectory: outputDirectory,
            baseConfig: Self.makeConfig(featureFlags: TranscriptionFeatureFlags(
                localASRRefinerEnabled: true,
                transcriptionMetricsEnabled: true
            )),
            policy: policy,
            configuration: TranscriptionEvaluationReplayConfiguration(
                runID: "unit-asr-replay-refiner-rejected",
                chunkDurationMs: 100,
                postAudioDrainMs: 25,
                replayInRealTime: true,
                audioSource: .microphone,
                engineIdentifier: "notchly-refiner-rejection-replay-unit",
                generatedAt: "2026-05-29T00:00:00Z"
            )
        )

        XCTAssertTrue(report.passed, (report.evaluationReport.releaseGateReport.failures + report.evaluationReport.improvementGateFailures).joined(separator: ", "))
        XCTAssertEqual(report.evaluationReport.releaseGateReport.coverage.first?.localRefinerDecisionCount, 1)
        XCTAssertEqual(report.manifest.cases.first?.hypothesis, reference)

        let transcriptPath = try XCTUnwrap(report.manifest.cases.first?.hypothesisTranscriptFilePath)
        let transcriptData = try Data(contentsOf: URL(fileURLWithPath: transcriptPath))
        let transcriptEvidence = try JSONDecoder().decode(TranscriptionHypothesisTranscriptEvidence.self, from: transcriptData)
        let segmentEvidence = try XCTUnwrap(transcriptEvidence.segments?.first)
        XCTAssertEqual(segmentEvidence.retentionReason, .localRefinerRejected)
        XCTAssertEqual(segmentEvidence.revisionNumber, 1)
        XCTAssertEqual(segmentEvidence.audioSource, .microphone)
    }

    func testTranscriptionEvaluationReplayRunnerCertifiesCriticalSilenceWithoutInventedSegments() async throws {
        let manifestDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchly-asr-replay-silence-\(UUID().uuidString)", isDirectory: true)
        let audioDirectory = manifestDirectory.appendingPathComponent("audio", isDirectory: true)
        let outputDirectory = manifestDirectory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: manifestDirectory) }

        let audioURL = audioDirectory.appendingPathComponent("internal-critical-silence.wav")
        try Self.writeReleaseGateWaveFile(to: audioURL, durationMs: 1_000, amplitude: 0)
        let baselineAudioSHA256 = try Self.sha256HexDigest(of: audioURL)
        let baselineTranscriptEvidence = try Self.releaseGateHypothesisEvidence(
            id: "internal-critical-silence",
            hypothesis: "phantom speech from silence",
            source: .speechAnalyzer,
            locale: "en-US",
            engineIdentifier: "notchly-speechanalyzer-baseline",
            runID: "unit-asr-silence-baseline",
            audioSHA256: baselineAudioSHA256,
            audioDurationMs: 1_000,
            audioSource: .system,
            directory: manifestDirectory.appendingPathComponent("baseline-transcripts", isDirectory: true)
        )
        let manifest = TranscriptionEvaluationManifest(
            suiteName: "asr-replay-critical-silence",
            cases: [
                TranscriptionBenchmarkCase(
                    id: "internal-critical-silence",
                    audioFilePath: "audio/internal-critical-silence.wav",
                    reference: "",
                    hypothesis: "stale placeholder should be replaced by replay",
                    locale: "en-US",
                    corpus: .internalCritical,
                    evaluationTags: [.criticalNonSpeech, .silence],
                    evidenceKind: .generatedFixture
                )
            ],
            baselineCases: [
                TranscriptionBenchmarkCase(
                    id: "internal-critical-silence",
                    audioSource: .system,
                    reference: "",
                    hypothesis: "phantom speech from silence",
                    locale: "en-US",
                    corpus: .internalCritical,
                    evaluationTags: [.criticalNonSpeech, .silence],
                    evidenceKind: .generatedFixture,
                    audioSHA256: baselineAudioSHA256,
                    hypothesisSource: baselineTranscriptEvidence.source,
                    hypothesisEngineIdentifier: baselineTranscriptEvidence.engineIdentifier,
                    hypothesisRunID: baselineTranscriptEvidence.runID,
                    hypothesisTranscriptFilePath: baselineTranscriptEvidence.path,
                    hypothesisTranscriptSHA256: baselineTranscriptEvidence.sha256,
                    audioDurationMs: 1_000,
                    processingDurationMs: 1_000
                )
            ]
        )

        let runner = TranscriptionEvaluationReplayRunner(serviceFactory: { audioStream, source in
            StreamingASRRouter(
                sources: [
                    StreamingASRRouter.Source(
                        speakerLabel: "System",
                        audioSource: source,
                        audioStream: audioStream
                    )
                ],
                serviceFactory: { _ in EchoOnAudioTranscriptionService() }
            )
        })
        var policy = TranscriptionReleaseGatePolicy.topTierRelease
        policy.requiredCorpora = [.internalCritical]
        policy.requiredLocales = ["en-US"]
        policy.requiredTags = [.criticalNonSpeech, .silence]
        policy.minimumCaseCountsByCorpus = [.internalCritical: 1]
        policy.minimumUniqueSampleCountsByCorpus = [:]
        policy.minimumUniqueAudioChecksumCountsByCorpus = [.internalCritical: 1]
        policy.minimumTotalAudioDurationMsByCorpus = [.internalCritical: 900]
        policy.requiredLocalesByCorpus = [:]
        policy.requiredTagsByCorpus = [:]
        policy.requiredAudioSourcesByCorpus = [.internalCritical: [.system]]

        let report = try await runner.replay(
            manifest: manifest,
            baseURL: manifestDirectory,
            outputDirectory: outputDirectory,
            baseConfig: Self.makeConfig(featureFlags: TranscriptionFeatureFlags(vadGatingEnabled: true)),
            policy: policy,
            configuration: TranscriptionEvaluationReplayConfiguration(
                runID: "unit-asr-replay-silence",
                chunkDurationMs: 100,
                postAudioDrainMs: 25,
                audioSource: .system,
                hypothesisSource: .speechAnalyzer,
                engineIdentifier: "notchly-speechanalyzer-replay-unit",
                generatedAt: "2026-05-29T00:00:00Z"
            )
        )

        XCTAssertTrue(report.passed, (report.evaluationReport.releaseGateReport.failures + report.evaluationReport.improvementGateFailures).joined(separator: ", "))
        XCTAssertEqual(report.manifest.cases.first?.hypothesis, "")
        XCTAssertEqual(report.caseReports.first?.segmentCount, 0)
        XCTAssertNil(report.manifest.cases.first?.firstPartialLatencyMs)
        guard let transcriptPath = report.manifest.cases.first?.hypothesisTranscriptFilePath else {
            return XCTFail("Replay runner should still write non-speech hypothesis evidence")
        }
        let transcriptData = try Data(contentsOf: URL(fileURLWithPath: transcriptPath))
        let transcriptEvidence = try JSONDecoder().decode(TranscriptionHypothesisTranscriptEvidence.self, from: transcriptData)
        XCTAssertEqual(transcriptEvidence.hypothesis, "")
        XCTAssertEqual(transcriptEvidence.segmentCount, 0)
        XCTAssertEqual(transcriptEvidence.segments, [])
        XCTAssertEqual(transcriptEvidence.audioConditioning?.audioSource, .system)
        XCTAssertEqual(transcriptEvidence.audioConditioning?.forwardedDecisionCount, 0)
        XCTAssertEqual(transcriptEvidence.audioConditioning?.emittedBufferCount, 0)
        XCTAssertGreaterThan(transcriptEvidence.audioConditioning?.droppedDecisionCount ?? 0, 0)
        XCTAssertGreaterThan(transcriptEvidence.audioConditioning?.nonSpeechDecisionCount ?? 0, 0)
    }

    func testTranscriptionEvaluationRunnerRejectsManifestChecksumMismatch() throws {
        let manifestDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchly-manifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: manifestDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: manifestDirectory) }
        _ = try Self.releaseGateAudioEvidence(
            id: "ami-bad-checksum",
            kind: .publicCorpus,
            directory: manifestDirectory.appendingPathComponent("audio", isDirectory: true)
        )
        let manifest = TranscriptionEvaluationManifest(
            suiteName: "manifest-checksum-negative",
            cases: [
                TranscriptionBenchmarkCase(
                    id: "ami-bad-checksum",
                    audioFilePath: "audio/ami-bad-checksum.wav",
                    reference: "we should reject mismatched evidence",
                    hypothesis: "we should reject mismatched evidence",
                    locale: "en-US",
                    corpus: .ami,
                    evaluationTags: [.meeting],
                    evidenceKind: .publicCorpus,
                    audioSHA256: String(repeating: "0", count: 64),
                    firstPartialLatencyMs: 420,
                    finalLatencyMs: 1_200,
                    audioDurationMs: 3_000,
                    processingDurationMs: 1_100
                )
            ]
        )
        let manifestURL = manifestDirectory.appendingPathComponent("transcription-eval.json")
        try Self.writeManifest(manifest, to: manifestURL)

        var policy = TranscriptionReleaseGatePolicy.topTierRelease
        policy.requiredCorpora = [.ami]
        policy.requiredLocales = ["en-US"]
        policy.requiredTags = [.meeting]

        let report = try TranscriptionEvaluationRunner().evaluate(manifestAt: manifestURL, policy: policy)

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.releaseGateReport.failures.contains("audio_checksum_mismatch:ami-bad-checksum"))
    }

    func testTranscriptionReleaseGateRejectsNonDecodableAudioEvidence() throws {
        let evidenceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchly-bad-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidenceDirectory) }
        let url = evidenceDirectory.appendingPathComponent("ami-not-audio.wav")
        let data = Data("this is not decodable audio".utf8)
        try data.write(to: url, options: .atomic)
        let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        var policy = TranscriptionReleaseGatePolicy.topTierRelease
        policy.requiredCorpora = [.ami]
        policy.requiredLocales = ["en-US"]
        policy.requiredTags = [.meeting]

        let report = TranscriptionReleaseGate().evaluate(
            cases: [
                TranscriptionBenchmarkCase(
                    id: "ami-not-audio",
                    audioFilePath: url.path,
                    reference: "we should reject fake audio bytes",
                    hypothesis: "we should reject fake audio bytes",
                    locale: "en-US",
                    corpus: .ami,
                    evaluationTags: [.meeting],
                    evidenceKind: .publicCorpus,
                    audioSHA256: checksum,
                    firstPartialLatencyMs: 410,
                    finalLatencyMs: 1_200,
                    audioDurationMs: 3_000,
                    processingDurationMs: 1_000
                )
            ],
            policy: policy
        )

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.failures.contains("audio_file_not_decodable:ami-not-audio"))
    }

    func testTranscriptionReleaseGateRejectsAudioDurationMismatch() throws {
        let evidenceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchly-duration-mismatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidenceDirectory) }
        let evidence = try Self.releaseGateAudioEvidence(
            id: "ami-short-audio",
            kind: .publicCorpus,
            directory: evidenceDirectory,
            durationMs: 1_000
        )

        var policy = TranscriptionReleaseGatePolicy.topTierRelease
        policy.requiredCorpora = [.ami]
        policy.requiredLocales = ["en-US"]
        policy.requiredTags = [.meeting]

        let report = TranscriptionReleaseGate().evaluate(
            cases: [
                TranscriptionBenchmarkCase(
                    id: "ami-short-audio",
                    audioFilePath: evidence.path,
                    reference: "duration metrics must match the evidence",
                    hypothesis: "duration metrics must match the evidence",
                    locale: "en-US",
                    corpus: .ami,
                    evaluationTags: [.meeting],
                    evidenceKind: evidence.kind,
                    audioSHA256: evidence.sha256,
                    firstPartialLatencyMs: 410,
                    finalLatencyMs: 1_200,
                    audioDurationMs: 3_000,
                    processingDurationMs: 1_000
                )
            ],
            policy: policy
        )

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.failures.contains("audio_duration_mismatch:ami-short-audio"))
    }

    func testTranscriptionReleaseGateRejectsMissingResourceMeasurements() {
        var policy = TranscriptionReleaseGatePolicy.topTierRelease
        policy.requiredCorpora = [.internalCritical]
        policy.requiredLocales = ["en-US"]
        policy.requiredTags = []
        policy.minimumCaseCountsByCorpus = [.internalCritical: 1]
        policy.minimumUniqueSampleCountsByCorpus = [:]
        policy.minimumUniqueAudioChecksumCountsByCorpus = [:]
        policy.minimumTotalAudioDurationMsByCorpus = [:]
        policy.requireAudioEvidenceForRequiredCorpora = false
        policy.requireASRHypothesisEvidenceForRequiredCorpora = false

        let report = TranscriptionReleaseGate().evaluate(
            cases: [
                TranscriptionBenchmarkCase(
                    id: "resource-missing",
                    reference: "resource measurements must accompany release evidence",
                    hypothesis: "resource measurements must accompany release evidence",
                    locale: "en-US",
                    corpus: .internalCritical,
                    firstPartialLatencyMs: 300,
                    finalLatencyMs: 900,
                    audioDurationMs: 3_000,
                    processingDurationMs: 1_000,
                    latencyMeasurementMode: .realtimeReplay,
                    replayChunkDurationMs: 100
                )
            ],
            policy: policy
        )

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.failures.contains("missing_memory_resident_bytes:resource-missing"))
        XCTAssertTrue(report.failures.contains("missing_cpu_usage_percent:resource-missing"))
    }

    func testTranscriptionReleaseGateRejectsInvalidResourceMeasurements() {
        var policy = TranscriptionReleaseGatePolicy.topTierRelease
        policy.requiredCorpora = [.internalCritical]
        policy.requiredLocales = ["en-US"]
        policy.requiredTags = []
        policy.minimumCaseCountsByCorpus = [.internalCritical: 1]
        policy.minimumUniqueSampleCountsByCorpus = [:]
        policy.minimumUniqueAudioChecksumCountsByCorpus = [:]
        policy.minimumTotalAudioDurationMsByCorpus = [:]
        policy.requireAudioEvidenceForRequiredCorpora = false
        policy.requireASRHypothesisEvidenceForRequiredCorpora = false

        let report = TranscriptionReleaseGate().evaluate(
            cases: [
                TranscriptionBenchmarkCase(
                    id: "resource-invalid",
                    reference: "resource measurements must be physically plausible",
                    hypothesis: "resource measurements must be physically plausible",
                    locale: "en-US",
                    corpus: .internalCritical,
                    firstPartialLatencyMs: 300,
                    finalLatencyMs: 900,
                    audioDurationMs: 3_000,
                    processingDurationMs: 1_000,
                    latencyMeasurementMode: .realtimeReplay,
                    replayChunkDurationMs: 100,
                    memoryResidentBytes: 0,
                    cpuUsagePercent: -0.01
                )
            ],
            policy: policy
        )

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.failures.contains("invalid_memory_resident_bytes:resource-invalid"))
        XCTAssertTrue(report.failures.contains("invalid_cpu_usage_percent:resource-invalid"))
    }

    func testTranscriptionReleaseGateRejectsInvalidLatencyMeasurements() {
        var policy = TranscriptionReleaseGatePolicy.topTierRelease
        policy.requiredCorpora = [.internalCritical]
        policy.requiredLocales = ["en-US"]
        policy.requiredTags = []
        policy.minimumCaseCountsByCorpus = [.internalCritical: 3]
        policy.minimumUniqueSampleCountsByCorpus = [:]
        policy.minimumUniqueAudioChecksumCountsByCorpus = [:]
        policy.minimumTotalAudioDurationMsByCorpus = [:]
        policy.requiredLocalesByCorpus = [:]
        policy.requiredTagsByCorpus = [:]
        policy.requiredAudioSourcesByCorpus = [:]
        policy.requireAudioEvidenceForRequiredCorpora = false
        policy.requireASRHypothesisEvidenceForRequiredCorpora = false
        policy.requireResourceMeasurementsForRequiredCorpora = false

        let report = TranscriptionReleaseGate().evaluate(
            cases: [
                TranscriptionBenchmarkCase(
                    id: "latency-negative",
                    reference: "latency values must be plausible",
                    hypothesis: "latency values must be plausible",
                    locale: "en-US",
                    corpus: .internalCritical,
                    firstPartialLatencyMs: -1,
                    finalLatencyMs: 900,
                    audioDurationMs: 3_000,
                    processingDurationMs: 1_000,
                    latencyMeasurementMode: .realtimeReplay,
                    replayChunkDurationMs: -100
                ),
                TranscriptionBenchmarkCase(
                    id: "latency-regressive",
                    reference: "final text cannot stabilize before first visible text",
                    hypothesis: "final text cannot stabilize before first visible text",
                    locale: "en-US",
                    corpus: .internalCritical,
                    firstPartialLatencyMs: 900,
                    finalLatencyMs: 100,
                    audioDurationMs: 3_000,
                    processingDurationMs: 1_000,
                    latencyMeasurementMode: .realtimeReplay,
                    replayChunkDurationMs: 100
                ),
                TranscriptionBenchmarkCase(
                    id: "language-switch-invalid",
                    reference: "language switch latency must be plausible",
                    hypothesis: "language switch latency must be plausible",
                    locale: "pt-BR",
                    corpus: .internalCritical,
                    evaluationTags: [.codeSwitching],
                    firstPartialLatencyMs: 300,
                    finalLatencyMs: 900,
                    audioDurationMs: 3_000,
                    processingDurationMs: 1_000,
                    languageSwitchLatencyMs: .infinity,
                    latencyMeasurementMode: .realtimeReplay,
                    replayChunkDurationMs: 100
                )
            ],
            policy: policy
        )

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.failures.contains("invalid_first_partial_latency:latency-negative"))
        XCTAssertTrue(report.failures.contains("invalid_replay_chunk_duration:latency-negative"))
        XCTAssertTrue(report.failures.contains("final_latency_before_first_partial:latency-regressive"))
        XCTAssertTrue(report.failures.contains("invalid_language_switch_latency:language-switch-invalid"))
    }

    func testTranscriptionReleaseGateRejectsOfflineReplayLatencyEvidence() {
        var policy = TranscriptionReleaseGatePolicy.topTierRelease
        policy.requiredCorpora = [.internalCritical]
        policy.requiredLocales = ["en-US"]
        policy.requiredTags = []
        policy.minimumCaseCountsByCorpus = [.internalCritical: 1]
        policy.minimumUniqueSampleCountsByCorpus = [:]
        policy.minimumUniqueAudioChecksumCountsByCorpus = [:]
        policy.minimumTotalAudioDurationMsByCorpus = [:]
        policy.requiredLocalesByCorpus = [:]
        policy.requiredTagsByCorpus = [:]
        policy.requireAudioEvidenceForRequiredCorpora = false
        policy.requireASRHypothesisEvidenceForRequiredCorpora = false
        policy.requireResourceMeasurementsForRequiredCorpora = false

        let offlineReport = TranscriptionReleaseGate().evaluate(
            cases: [
                TranscriptionBenchmarkCase(
                    id: "offline-latency",
                    reference: "latency evidence must come from realtime playback",
                    hypothesis: "latency evidence must come from realtime playback",
                    locale: "en-US",
                    corpus: .internalCritical,
                    firstPartialLatencyMs: 180,
                    finalLatencyMs: 820,
                    audioDurationMs: 2_000,
                    processingDurationMs: 600,
                    latencyMeasurementMode: .offlineReplay,
                    replayChunkDurationMs: 80
                )
            ],
            policy: policy
        )

        XCTAssertFalse(offlineReport.passed)
        XCTAssertTrue(offlineReport.failures.contains("non_realtime_latency_measurement:offline-latency:offline-replay"))

        let liveReport = TranscriptionReleaseGate().evaluate(
            cases: [
                TranscriptionBenchmarkCase(
                    id: "live-latency",
                    reference: "latency evidence must come from realtime playback",
                    hypothesis: "latency evidence must come from realtime playback",
                    locale: "en-US",
                    corpus: .internalCritical,
                    firstPartialLatencyMs: 180,
                    finalLatencyMs: 820,
                    audioDurationMs: 2_000,
                    processingDurationMs: 600,
                    latencyMeasurementMode: .liveCapture
                )
            ],
            policy: policy
        )

        XCTAssertTrue(liveReport.passed, liveReport.failures.joined(separator: ", "))
    }

    func testTranscriptionReleaseGateRejectsManualHypothesisForRequiredCorpus() throws {
        let evidenceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchly-manual-hypothesis-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidenceDirectory) }
        let audioEvidence = try Self.releaseGateAudioEvidence(
            id: "ami-manual-hypothesis",
            kind: .publicCorpus,
            directory: evidenceDirectory,
            durationMs: 3_000
        )
        let transcriptEvidence = try Self.releaseGateHypothesisEvidence(
            id: "ami-manual-hypothesis",
            hypothesis: "manual text should not certify top tier transcription",
            source: .manual,
            locale: "en-US",
            engineIdentifier: "manual-entry",
            runID: "manual-run",
            audioSHA256: audioEvidence.sha256,
            audioDurationMs: 3_000,
            directory: evidenceDirectory
        )

        var policy = TranscriptionReleaseGatePolicy.topTierRelease
        policy.requiredCorpora = [.ami]
        policy.requiredLocales = ["en-US"]
        policy.requiredTags = [.meeting]

        let report = TranscriptionReleaseGate().evaluate(
            cases: [
                TranscriptionBenchmarkCase(
                    id: "ami-manual-hypothesis",
                    audioFilePath: audioEvidence.path,
                    reference: "manual text should not certify top tier transcription",
                    hypothesis: "manual text should not certify top tier transcription",
                    locale: "en-US",
                    corpus: .ami,
                    evaluationTags: [.meeting],
                    evidenceKind: audioEvidence.kind,
                    audioSHA256: audioEvidence.sha256,
                    hypothesisSource: transcriptEvidence.source,
                    hypothesisEngineIdentifier: transcriptEvidence.engineIdentifier,
                    hypothesisRunID: transcriptEvidence.runID,
                    hypothesisTranscriptFilePath: transcriptEvidence.path,
                    hypothesisTranscriptSHA256: transcriptEvidence.sha256,
                    firstPartialLatencyMs: 410,
                    finalLatencyMs: 1_200,
                    audioDurationMs: 3_000,
                    processingDurationMs: 1_000
                )
            ],
            policy: policy
        )

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.failures.contains("unsupported_hypothesis_source:ami-manual-hypothesis:manual"))
    }

    func testTranscriptionReleaseGateRejectsImportedASRForRequiredCorpusCertification() throws {
        let evidenceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchly-imported-asr-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidenceDirectory) }
        let audioEvidence = try Self.releaseGateAudioEvidence(
            id: "ami-imported-asr",
            kind: .publicCorpus,
            directory: evidenceDirectory,
            durationMs: 3_000
        )
        let provenance = Self.publicCorpusProvenance(.ami, sampleID: "ami-imported-asr")
        let transcriptEvidence = try Self.releaseGateHypothesisEvidence(
            id: "ami-imported-asr",
            hypothesis: "imported ASR should not certify the Notchly release gate",
            source: .importedASR,
            locale: "en-US",
            engineIdentifier: "third-party-imported-asr",
            runID: "imported-asr-run",
            audioSHA256: audioEvidence.sha256,
            audioDurationMs: 3_000,
            corpusProvenance: provenance,
            directory: evidenceDirectory
        )

        var policy = TranscriptionReleaseGatePolicy.topTierRelease
        policy.requiredCorpora = [.ami]
        policy.requiredLocales = ["en-US"]
        policy.requiredTags = [.meeting]
        policy.requireNonTemporaryAudioEvidenceForExternalCorpora = false

        let report = TranscriptionReleaseGate().evaluate(
            cases: [
                TranscriptionBenchmarkCase(
                    id: "ami-imported-asr",
                    audioFilePath: audioEvidence.path,
                    reference: "imported ASR should not certify the Notchly release gate",
                    hypothesis: "imported ASR should not certify the Notchly release gate",
                    locale: "en-US",
                    corpus: .ami,
                    evaluationTags: [.meeting],
                    evidenceKind: audioEvidence.kind,
                    audioSHA256: audioEvidence.sha256,
                    corpusProvenance: provenance,
                    hypothesisSource: transcriptEvidence.source,
                    hypothesisEngineIdentifier: transcriptEvidence.engineIdentifier,
                    hypothesisRunID: transcriptEvidence.runID,
                    hypothesisTranscriptFilePath: transcriptEvidence.path,
                    hypothesisTranscriptSHA256: transcriptEvidence.sha256,
                    firstPartialLatencyMs: 410,
                    finalLatencyMs: 1_200,
                    audioDurationMs: 3_000,
                    processingDurationMs: 1_000
                )
            ],
            policy: policy
        )

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.failures.contains("unsupported_hypothesis_source:ami-imported-asr:imported-asr"))
    }

    func testTranscriptionReleaseGateRejectsTinyWhisperKitAsReleaseEvidence() throws {
        let evidenceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchly-disallowed-engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidenceDirectory) }
        let audioEvidence = try Self.releaseGateAudioFixtureEvidence(
            id: "internal-whisperkit-tiny",
            profile: .clean,
            kind: .generatedFixture,
            directory: evidenceDirectory,
            durationMs: 2_000
        )
        let transcriptEvidence = try Self.releaseGateHypothesisEvidence(
            id: "internal-whisperkit-tiny",
            hypothesis: "Notchly should not certify the tiny refiner for release",
            source: .whisperKit,
            locale: "en-US",
            engineIdentifier: "WhisperKit/tiny",
            runID: "tiny-release-evidence-run",
            audioSHA256: audioEvidence.sha256,
            audioDurationMs: 2_000,
            directory: evidenceDirectory
        )

        var policy = TranscriptionReleaseGatePolicy.topTierRelease
        policy.requiredCorpora = [.internalCritical]
        policy.requiredLocales = ["en-US"]
        policy.requiredTags = [.meeting]

        let report = TranscriptionReleaseGate().evaluate(
            cases: [
                TranscriptionBenchmarkCase(
                    id: "internal-whisperkit-tiny",
                    audioFilePath: audioEvidence.path,
                    reference: "Notchly should not certify the tiny refiner for release",
                    hypothesis: "Notchly should not certify the tiny refiner for release",
                    locale: "en-US",
                    corpus: .internalCritical,
                    evaluationTags: [.meeting],
                    evidenceKind: audioEvidence.kind,
                    audioSHA256: audioEvidence.sha256,
                    hypothesisSource: transcriptEvidence.source,
                    hypothesisEngineIdentifier: transcriptEvidence.engineIdentifier,
                    hypothesisRunID: transcriptEvidence.runID,
                    hypothesisTranscriptFilePath: transcriptEvidence.path,
                    hypothesisTranscriptSHA256: transcriptEvidence.sha256,
                    firstPartialLatencyMs: 410,
                    finalLatencyMs: 1_200,
                    audioDurationMs: 2_000,
                    processingDurationMs: 900
                )
            ],
            policy: policy
        )

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.failures.contains("disallowed_hypothesis_engine:internal-whisperkit-tiny:WhisperKit/tiny"))
    }

    func testTranscriptionReleaseGateRejectsEvaluationReplayForExternalCorpora() throws {
        let evidenceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchly-replay-hypothesis-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidenceDirectory) }
        let audioEvidence = try Self.releaseGateAudioEvidence(
            id: "ami-replay-hypothesis",
            kind: .publicCorpus,
            directory: evidenceDirectory,
            durationMs: 3_000
        )
        let transcriptEvidence = try Self.releaseGateHypothesisEvidence(
            id: "ami-replay-hypothesis",
            hypothesis: "replay text should not certify public corpus transcription",
            source: .evaluationReplay,
            locale: "en-US",
            engineIdentifier: "notchly-evaluation-replay",
            runID: "replay-run",
            audioSHA256: audioEvidence.sha256,
            audioDurationMs: 3_000,
            directory: evidenceDirectory
        )

        var policy = TranscriptionReleaseGatePolicy.topTierRelease
        policy.requiredCorpora = [.ami]
        policy.requiredLocales = ["en-US"]
        policy.requiredTags = [.meeting]

        let report = TranscriptionReleaseGate().evaluate(
            cases: [
                TranscriptionBenchmarkCase(
                    id: "ami-replay-hypothesis",
                    audioFilePath: audioEvidence.path,
                    reference: "replay text should not certify public corpus transcription",
                    hypothesis: "replay text should not certify public corpus transcription",
                    locale: "en-US",
                    corpus: .ami,
                    evaluationTags: [.meeting],
                    evidenceKind: audioEvidence.kind,
                    audioSHA256: audioEvidence.sha256,
                    hypothesisSource: transcriptEvidence.source,
                    hypothesisEngineIdentifier: transcriptEvidence.engineIdentifier,
                    hypothesisRunID: transcriptEvidence.runID,
                    hypothesisTranscriptFilePath: transcriptEvidence.path,
                    hypothesisTranscriptSHA256: transcriptEvidence.sha256,
                    firstPartialLatencyMs: 410,
                    finalLatencyMs: 1_200,
                    audioDurationMs: 3_000,
                    processingDurationMs: 1_000
                )
            ],
            policy: policy
        )

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.failures.contains("unsupported_hypothesis_source:ami-replay-hypothesis:evaluation-replay"))
    }

    func testTranscriptionReleaseGateRejectsTranscriptArtifactThatDoesNotMatchHypothesis() throws {
        let evidenceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchly-transcript-mismatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidenceDirectory) }
        let audioEvidence = try Self.releaseGateAudioEvidence(
            id: "ami-transcript-mismatch",
            kind: .publicCorpus,
            directory: evidenceDirectory,
            durationMs: 3_000
        )
        let transcriptEvidence = try Self.releaseGateHypothesisEvidence(
            id: "ami-transcript-mismatch",
            hypothesis: "the transcript artifact contains another sentence",
            source: .importedASR,
            locale: "en-US",
            engineIdentifier: "notchly-imported-asr-evaluation",
            runID: "mismatch-run",
            audioSHA256: audioEvidence.sha256,
            audioDurationMs: 3_000,
            directory: evidenceDirectory
        )

        var policy = TranscriptionReleaseGatePolicy.topTierRelease
        policy.requiredCorpora = [.ami]
        policy.requiredLocales = ["en-US"]
        policy.requiredTags = [.meeting]

        let report = TranscriptionReleaseGate().evaluate(
            cases: [
                TranscriptionBenchmarkCase(
                    id: "ami-transcript-mismatch",
                    audioFilePath: audioEvidence.path,
                    reference: "the transcript artifact must match this sentence",
                    hypothesis: "the transcript artifact must match this sentence",
                    locale: "en-US",
                    corpus: .ami,
                    evaluationTags: [.meeting],
                    evidenceKind: audioEvidence.kind,
                    audioSHA256: audioEvidence.sha256,
                    hypothesisSource: transcriptEvidence.source,
                    hypothesisEngineIdentifier: transcriptEvidence.engineIdentifier,
                    hypothesisRunID: transcriptEvidence.runID,
                    hypothesisTranscriptFilePath: transcriptEvidence.path,
                    hypothesisTranscriptSHA256: transcriptEvidence.sha256,
                    firstPartialLatencyMs: 410,
                    finalLatencyMs: 1_200,
                    audioDurationMs: 3_000,
                    processingDurationMs: 1_000
                )
            ],
            policy: policy
        )

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.failures.contains("hypothesis_transcript_text_mismatch:ami-transcript-mismatch"))
    }

    func testTranscriptionReleaseGateRejectsMissingSegmentEvidence() throws {
        let evidenceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchly-segment-evidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidenceDirectory) }
        let audioEvidence = try Self.releaseGateAudioFixtureEvidence(
            id: "internal-missing-segments",
            profile: .clean,
            kind: .generatedFixture,
            directory: evidenceDirectory,
            durationMs: 2_000
        )
        let transcriptURL = evidenceDirectory.appendingPathComponent("internal-missing-segments.transcript.json")
        let transcript = TranscriptionHypothesisTranscriptEvidence(
            caseID: "internal-missing-segments",
            hypothesis: "segment evidence must include source tagged committed spans",
            source: .speechAnalyzer,
            engineIdentifier: "notchly-speechanalyzer-evaluation",
            runID: "missing-segments-run",
            locale: "en-US",
            segmentCount: 1,
            segments: nil,
            audioSHA256: audioEvidence.sha256,
            audioDurationMs: 2_000,
            latencyMeasurementMode: .realtimeReplay,
            replayChunkDurationMs: 100,
            generatedAt: "2026-05-29T00:00:00Z"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let transcriptData = try encoder.encode(transcript)
        try transcriptData.write(to: transcriptURL, options: Data.WritingOptions.atomic)
        let transcriptSHA = SHA256.hash(data: transcriptData).map { String(format: "%02x", $0) }.joined()

        var policy = TranscriptionReleaseGatePolicy.topTierRelease
        policy.requiredCorpora = [.internalCritical]
        policy.requiredLocales = ["en-US"]
        policy.requiredTags = [.meeting]
        policy.minimumCaseCountsByCorpus = [.internalCritical: 1]
        policy.minimumUniqueSampleCountsByCorpus = [:]
        policy.minimumUniqueAudioChecksumCountsByCorpus = [.internalCritical: 1]
        policy.minimumTotalAudioDurationMsByCorpus = [.internalCritical: 1_900]
        policy.requiredLocalesByCorpus = [:]
        policy.requiredTagsByCorpus = [:]

        let report = TranscriptionReleaseGate().evaluate(
            cases: [
                TranscriptionBenchmarkCase(
                    id: "internal-missing-segments",
                    audioFilePath: audioEvidence.path,
                    reference: "segment evidence must include source tagged committed spans",
                    hypothesis: "segment evidence must include source tagged committed spans",
                    locale: "en-US",
                    corpus: .internalCritical,
                    evaluationTags: [.meeting],
                    evidenceKind: audioEvidence.kind,
                    audioSHA256: audioEvidence.sha256,
                    hypothesisSource: .speechAnalyzer,
                    hypothesisEngineIdentifier: "notchly-speechanalyzer-evaluation",
                    hypothesisRunID: "missing-segments-run",
                    hypothesisTranscriptFilePath: transcriptURL.path,
                    hypothesisTranscriptSHA256: transcriptSHA,
                    firstPartialLatencyMs: 240,
                    finalLatencyMs: 900,
                    audioDurationMs: 2_000,
                    processingDurationMs: 700,
                    latencyMeasurementMode: .realtimeReplay,
                    replayChunkDurationMs: 100,
                    memoryResidentBytes: 320_000_000,
                    cpuUsagePercent: 18
                )
            ],
            policy: policy
        )

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.failures.contains("missing_hypothesis_segments:internal-missing-segments"))
    }

    func testTranscriptionReleaseGateRejectsInvalidSegmentMeasurements() throws {
        let evidenceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchly-invalid-segment-evidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidenceDirectory) }
        let audioEvidence = try Self.releaseGateAudioFixtureEvidence(
            id: "internal-invalid-segment",
            profile: .clean,
            kind: .generatedFixture,
            directory: evidenceDirectory,
            durationMs: 2_000
        )
        let hypothesis = "segment evidence must contain plausible ASR metadata"
        let invalidSegment = TranscriptionHypothesisTranscriptEvidence.SegmentEvidence(
            text: hypothesis,
            audioSource: .system,
            speakerLabel: "System",
            startTime: 0,
            endTime: 3.0,
            isFinal: true,
            transcriptionPhase: .final,
            transcriptionEngine: .speechAnalyzer,
            finalizedBy: .speechAnalyzer,
            confidence: 1.2,
            engineConfidence: 1.4,
            languageCode: " ",
            languageConfidence: -0.1,
            revisionNumber: -1,
            sourceFrameRange: AudioSourceFrameRange(start: 32_000, end: 16_000),
            wordTimestampCount: -2
        )
        let transcriptEvidence = try Self.releaseGateHypothesisEvidence(
            id: "internal-invalid-segment",
            hypothesis: hypothesis,
            source: .speechAnalyzer,
            locale: "en-US",
            engineIdentifier: "notchly-speechanalyzer-evaluation",
            runID: "invalid-segment-run",
            audioSHA256: audioEvidence.sha256,
            audioDurationMs: 2_000,
            segments: [invalidSegment],
            latencyMeasurementMode: .realtimeReplay,
            replayChunkDurationMs: 100,
            directory: evidenceDirectory
        )

        var policy = TranscriptionReleaseGatePolicy.topTierRelease
        policy.requiredCorpora = [.internalCritical]
        policy.requiredLocales = ["en-US"]
        policy.requiredTags = [.meeting]
        policy.minimumCaseCountsByCorpus = [.internalCritical: 1]
        policy.minimumUniqueSampleCountsByCorpus = [:]
        policy.minimumUniqueAudioChecksumCountsByCorpus = [.internalCritical: 1]
        policy.minimumTotalAudioDurationMsByCorpus = [.internalCritical: 1_900]
        policy.requiredLocalesByCorpus = [:]
        policy.requiredTagsByCorpus = [:]
        policy.requiredAudioSourcesByCorpus = [:]

        let report = TranscriptionReleaseGate().evaluate(
            cases: [
                TranscriptionBenchmarkCase(
                    id: "internal-invalid-segment",
                    audioFilePath: audioEvidence.path,
                    reference: hypothesis,
                    hypothesis: hypothesis,
                    locale: "en-US",
                    corpus: .internalCritical,
                    evaluationTags: [.meeting],
                    evidenceKind: audioEvidence.kind,
                    audioSHA256: audioEvidence.sha256,
                    hypothesisSource: .speechAnalyzer,
                    hypothesisEngineIdentifier: "notchly-speechanalyzer-evaluation",
                    hypothesisRunID: "invalid-segment-run",
                    hypothesisTranscriptFilePath: transcriptEvidence.path,
                    hypothesisTranscriptSHA256: transcriptEvidence.sha256,
                    firstPartialLatencyMs: 240,
                    finalLatencyMs: 900,
                    audioDurationMs: 2_000,
                    processingDurationMs: 700,
                    latencyMeasurementMode: .realtimeReplay,
                    replayChunkDurationMs: 100,
                    memoryResidentBytes: 320_000_000,
                    cpuUsagePercent: 18
                )
            ],
            policy: policy
        )

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.failures.contains("hypothesis_segment_invalid_confidence:internal-invalid-segment:0"))
        XCTAssertTrue(report.failures.contains("hypothesis_segment_invalid_engine_confidence:internal-invalid-segment:0"))
        XCTAssertTrue(report.failures.contains("hypothesis_segment_invalid_language_confidence:internal-invalid-segment:0"))
        XCTAssertTrue(report.failures.contains("hypothesis_segment_missing_language_code:internal-invalid-segment:0"))
        XCTAssertTrue(report.failures.contains("hypothesis_segment_invalid_revision_number:internal-invalid-segment:0"))
        XCTAssertTrue(report.failures.contains("hypothesis_segment_invalid_word_timestamp_count:internal-invalid-segment:0"))
        XCTAssertTrue(report.failures.contains("hypothesis_segment_invalid_source_frame_range:internal-invalid-segment:0"))
        XCTAssertTrue(report.failures.contains("hypothesis_segment_exceeds_audio_duration:internal-invalid-segment:0"))
    }

    func testTranscriptionReleaseGateRejectsSegmentSourceMismatchAndFrameRegression() throws {
        let evidenceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchly-source-regression-segment-evidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidenceDirectory) }
        let audioEvidence = try Self.releaseGateAudioFixtureEvidence(
            id: "internal-source-regression-segment",
            profile: .clean,
            kind: .generatedFixture,
            directory: evidenceDirectory,
            durationMs: 2_000
        )
        let hypothesis = "source tagged segments stay ordered"
        let transcriptEvidence = try Self.releaseGateHypothesisEvidence(
            id: "internal-source-regression-segment",
            hypothesis: hypothesis,
            source: .speechAnalyzer,
            locale: "en-US",
            engineIdentifier: "notchly-speechanalyzer-evaluation",
            runID: "source-regression-run",
            audioSHA256: audioEvidence.sha256,
            audioDurationMs: 2_000,
            segments: [
                TranscriptionHypothesisTranscriptEvidence.SegmentEvidence(
                    text: "source tagged",
                    audioSource: .system,
                    speakerLabel: "System",
                    startTime: 0,
                    endTime: 0.8,
                    isFinal: true,
                    transcriptionPhase: .final,
                    transcriptionEngine: .speechAnalyzer,
                    finalizedBy: .speechAnalyzer,
                    confidence: 0.96,
                    engineConfidence: 0.96,
                    languageCode: "en-US",
                    languageConfidence: 0.94,
                    sourceFrameRange: AudioSourceFrameRange(start: 16_000, end: 32_000),
                    wordTimestampCount: 2
                ),
                TranscriptionHypothesisTranscriptEvidence.SegmentEvidence(
                    text: "segments stay ordered",
                    audioSource: .system,
                    speakerLabel: "System",
                    startTime: 0.8,
                    endTime: 1.5,
                    isFinal: true,
                    transcriptionPhase: .final,
                    transcriptionEngine: .speechAnalyzer,
                    finalizedBy: .speechAnalyzer,
                    confidence: 0.95,
                    engineConfidence: 0.95,
                    languageCode: "en-US",
                    languageConfidence: 0.93,
                    sourceFrameRange: AudioSourceFrameRange(start: 30_000, end: 48_000),
                    wordTimestampCount: 3
                )
            ],
            audioConditioning: Self.releaseGateAudioConditioningEvidence(
                hypothesis: hypothesis,
                audioDurationMs: 2_000,
                audioSource: .system
            ),
            latencyMeasurementMode: .realtimeReplay,
            replayChunkDurationMs: 100,
            directory: evidenceDirectory
        )

        var policy = TranscriptionReleaseGatePolicy.topTierRelease
        policy.requiredCorpora = [.internalCritical]
        policy.requiredLocales = ["en-US"]
        policy.requiredTags = [.meeting]
        policy.minimumCaseCountsByCorpus = [.internalCritical: 1]
        policy.minimumUniqueSampleCountsByCorpus = [:]
        policy.minimumUniqueAudioChecksumCountsByCorpus = [.internalCritical: 1]
        policy.minimumTotalAudioDurationMsByCorpus = [.internalCritical: 1_900]
        policy.requiredLocalesByCorpus = [:]
        policy.requiredTagsByCorpus = [:]
        policy.requiredAudioSourcesByCorpus = [:]

        let report = TranscriptionReleaseGate().evaluate(
            cases: [
                TranscriptionBenchmarkCase(
                    id: "internal-source-regression-segment",
                    audioFilePath: audioEvidence.path,
                    audioSource: .microphone,
                    reference: hypothesis,
                    hypothesis: hypothesis,
                    locale: "en-US",
                    corpus: .internalCritical,
                    evaluationTags: [.meeting],
                    evidenceKind: audioEvidence.kind,
                    audioSHA256: audioEvidence.sha256,
                    hypothesisSource: .speechAnalyzer,
                    hypothesisEngineIdentifier: "notchly-speechanalyzer-evaluation",
                    hypothesisRunID: "source-regression-run",
                    hypothesisTranscriptFilePath: transcriptEvidence.path,
                    hypothesisTranscriptSHA256: transcriptEvidence.sha256,
                    firstPartialLatencyMs: 240,
                    finalLatencyMs: 900,
                    audioDurationMs: 2_000,
                    processingDurationMs: 700,
                    latencyMeasurementMode: .realtimeReplay,
                    replayChunkDurationMs: 100,
                    memoryResidentBytes: 320_000_000,
                    cpuUsagePercent: 18
                )
            ],
            policy: policy
        )

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.failures.contains("audio_conditioning_source_mismatch:internal-source-regression-segment"))
        XCTAssertTrue(report.failures.contains("hypothesis_segment_source_mismatch:internal-source-regression-segment:0"))
        XCTAssertTrue(report.failures.contains("hypothesis_segment_source_mismatch:internal-source-regression-segment:1"))
        XCTAssertTrue(report.failures.contains("hypothesis_segment_source_frame_regression:internal-source-regression-segment:1"))
    }

    func testTranscriptionReleaseGateRejectsMissingAudioConditioningEvidence() throws {
        let evidenceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchly-conditioning-evidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidenceDirectory) }
        let audioEvidence = try Self.releaseGateAudioFixtureEvidence(
            id: "internal-missing-conditioning",
            profile: .clean,
            kind: .generatedFixture,
            directory: evidenceDirectory,
            durationMs: 2_000
        )
        let transcriptURL = evidenceDirectory.appendingPathComponent("internal-missing-conditioning.transcript.json")
        let hypothesis = "audio conditioning evidence must prove VAD gating"
        let transcript = TranscriptionHypothesisTranscriptEvidence(
            caseID: "internal-missing-conditioning",
            hypothesis: hypothesis,
            source: .speechAnalyzer,
            engineIdentifier: "notchly-speechanalyzer-evaluation",
            runID: "missing-conditioning-run",
            locale: "en-US",
            segmentCount: 1,
            segments: Self.releaseGateSegmentEvidence(
                hypothesis: hypothesis,
                source: .speechAnalyzer,
                locale: "en-US",
                audioDurationMs: 2_000
            ),
            audioSHA256: audioEvidence.sha256,
            audioDurationMs: 2_000,
            audioConditioning: nil,
            latencyMeasurementMode: .realtimeReplay,
            replayChunkDurationMs: 100,
            generatedAt: "2026-05-29T00:00:00Z"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let transcriptData = try encoder.encode(transcript)
        try transcriptData.write(to: transcriptURL, options: Data.WritingOptions.atomic)
        let transcriptSHA = SHA256.hash(data: transcriptData).map { String(format: "%02x", $0) }.joined()

        var policy = TranscriptionReleaseGatePolicy.topTierRelease
        policy.requiredCorpora = [.internalCritical]
        policy.requiredLocales = ["en-US"]
        policy.requiredTags = [.meeting]
        policy.minimumCaseCountsByCorpus = [.internalCritical: 1]
        policy.minimumUniqueSampleCountsByCorpus = [:]
        policy.minimumUniqueAudioChecksumCountsByCorpus = [.internalCritical: 1]
        policy.minimumTotalAudioDurationMsByCorpus = [.internalCritical: 1_900]
        policy.requiredLocalesByCorpus = [:]
        policy.requiredTagsByCorpus = [:]

        let report = TranscriptionReleaseGate().evaluate(
            cases: [
                TranscriptionBenchmarkCase(
                    id: "internal-missing-conditioning",
                    audioFilePath: audioEvidence.path,
                    reference: hypothesis,
                    hypothesis: hypothesis,
                    locale: "en-US",
                    corpus: .internalCritical,
                    evaluationTags: [.meeting],
                    evidenceKind: audioEvidence.kind,
                    audioSHA256: audioEvidence.sha256,
                    hypothesisSource: .speechAnalyzer,
                    hypothesisEngineIdentifier: "notchly-speechanalyzer-evaluation",
                    hypothesisRunID: "missing-conditioning-run",
                    hypothesisTranscriptFilePath: transcriptURL.path,
                    hypothesisTranscriptSHA256: transcriptSHA,
                    firstPartialLatencyMs: 240,
                    finalLatencyMs: 900,
                    audioDurationMs: 2_000,
                    processingDurationMs: 700,
                    latencyMeasurementMode: .realtimeReplay,
                    replayChunkDurationMs: 100,
                    memoryResidentBytes: 320_000_000,
                    cpuUsagePercent: 18
                )
            ],
            policy: policy
        )

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.failures.contains("missing_audio_conditioning_evidence:internal-missing-conditioning"))
    }

    func testTranscriptionReleaseGateRejectsInvalidAudioConditioningMeasurements() throws {
        let evidenceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchly-invalid-conditioning-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidenceDirectory) }
        let audioEvidence = try Self.releaseGateAudioFixtureEvidence(
            id: "internal-invalid-conditioning",
            profile: .clean,
            kind: .generatedFixture,
            directory: evidenceDirectory,
            durationMs: 2_000
        )
        let invalidConditioning = TranscriptionAudioConditioningEvidence(
            audioSource: .system,
            conditioningTarget: " ",
            advancedConditioningEnabled: true,
            vadGatingEnabled: true,
            inputBufferCount: 2,
            emittedBufferCount: 4,
            forwardedDecisionCount: 1,
            droppedDecisionCount: 1,
            speechDecisionCount: 3,
            nonSpeechDecisionCount: 0,
            clippingDecisionCount: 3,
            lowEnergyDropCount: 3,
            preRollReplayBufferCount: 0,
            vadEngineCounts: [VoiceActivityDetectionEngine.heuristicEnergy.rawValue: 0],
            inputSampleRates: [0],
            inputChannelCounts: [0],
            averageRMS: -0.01,
            peakMax: -0.02,
            snrP50Db: 30,
            snrP95Db: 10
        )
        let transcriptEvidence = try Self.releaseGateHypothesisEvidence(
            id: "internal-invalid-conditioning",
            hypothesis: "audio conditioning evidence must contain plausible acoustic metrics",
            source: .speechAnalyzer,
            locale: "en-US",
            engineIdentifier: "notchly-speechanalyzer-evaluation",
            runID: "invalid-conditioning-run",
            audioSHA256: audioEvidence.sha256,
            audioDurationMs: 2_000,
            audioConditioning: invalidConditioning,
            latencyMeasurementMode: .realtimeReplay,
            replayChunkDurationMs: 100,
            directory: evidenceDirectory
        )

        var policy = TranscriptionReleaseGatePolicy.topTierRelease
        policy.requiredCorpora = [.internalCritical]
        policy.requiredLocales = ["en-US"]
        policy.requiredTags = [.meeting]
        policy.minimumCaseCountsByCorpus = [.internalCritical: 1]
        policy.minimumUniqueSampleCountsByCorpus = [:]
        policy.minimumUniqueAudioChecksumCountsByCorpus = [.internalCritical: 1]
        policy.minimumTotalAudioDurationMsByCorpus = [.internalCritical: 1_900]
        policy.requiredLocalesByCorpus = [:]
        policy.requiredTagsByCorpus = [:]
        policy.requiredAudioSourcesByCorpus = [:]

        let report = TranscriptionReleaseGate().evaluate(
            cases: [
                TranscriptionBenchmarkCase(
                    id: "internal-invalid-conditioning",
                    audioFilePath: audioEvidence.path,
                    reference: "audio conditioning evidence must contain plausible acoustic metrics",
                    hypothesis: "audio conditioning evidence must contain plausible acoustic metrics",
                    locale: "en-US",
                    corpus: .internalCritical,
                    evaluationTags: [.meeting],
                    evidenceKind: audioEvidence.kind,
                    audioSHA256: audioEvidence.sha256,
                    hypothesisSource: .speechAnalyzer,
                    hypothesisEngineIdentifier: "notchly-speechanalyzer-evaluation",
                    hypothesisRunID: "invalid-conditioning-run",
                    hypothesisTranscriptFilePath: transcriptEvidence.path,
                    hypothesisTranscriptSHA256: transcriptEvidence.sha256,
                    firstPartialLatencyMs: 240,
                    finalLatencyMs: 900,
                    audioDurationMs: 2_000,
                    processingDurationMs: 700,
                    latencyMeasurementMode: .realtimeReplay,
                    replayChunkDurationMs: 100,
                    memoryResidentBytes: 320_000_000,
                    cpuUsagePercent: 18
                )
            ],
            policy: policy
        )

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.failures.contains("audio_conditioning_missing_target:internal-invalid-conditioning"))
        XCTAssertTrue(report.failures.contains("audio_conditioning_emitted_count_exceeds_source:internal-invalid-conditioning"))
        XCTAssertTrue(report.failures.contains("audio_conditioning_decision_subcount_exceeds_input:internal-invalid-conditioning"))
        XCTAssertTrue(report.failures.contains("audio_conditioning_invalid_vad_engine_count:internal-invalid-conditioning"))
        XCTAssertTrue(report.failures.contains("audio_conditioning_invalid_sample_rate:internal-invalid-conditioning"))
        XCTAssertTrue(report.failures.contains("audio_conditioning_invalid_channel_count:internal-invalid-conditioning"))
        XCTAssertTrue(report.failures.contains("audio_conditioning_invalid_energy:internal-invalid-conditioning"))
        XCTAssertTrue(report.failures.contains("audio_conditioning_snr_percentile_order:internal-invalid-conditioning"))
    }

    func testTranscriptionReleaseGateRejectsMissingSourceSeparatedCoverage() throws {
        let evidenceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchly-source-coverage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidenceDirectory) }
        let audioEvidence = try Self.releaseGateAudioFixtureEvidence(
            id: "internal-system-only",
            profile: .clean,
            kind: .generatedFixture,
            directory: evidenceDirectory,
            durationMs: 2_000
        )
        let transcriptEvidence = try Self.releaseGateHypothesisEvidence(
            id: "internal-system-only",
            hypothesis: "source separated coverage must include the microphone path",
            source: .speechAnalyzer,
            locale: "en-US",
            engineIdentifier: "notchly-speechanalyzer-evaluation",
            runID: "source-coverage-run",
            audioSHA256: audioEvidence.sha256,
            audioDurationMs: 2_000,
            audioSource: .system,
            latencyMeasurementMode: .realtimeReplay,
            replayChunkDurationMs: 100,
            directory: evidenceDirectory
        )

        var policy = TranscriptionReleaseGatePolicy.topTierRelease
        policy.requiredCorpora = [.internalCritical]
        policy.requiredLocales = ["en-US"]
        policy.requiredTags = [.meeting]
        policy.minimumCaseCountsByCorpus = [.internalCritical: 1]
        policy.minimumUniqueSampleCountsByCorpus = [:]
        policy.minimumUniqueAudioChecksumCountsByCorpus = [.internalCritical: 1]
        policy.minimumTotalAudioDurationMsByCorpus = [.internalCritical: 1_900]
        policy.requiredLocalesByCorpus = [:]
        policy.requiredTagsByCorpus = [:]

        let report = TranscriptionReleaseGate().evaluate(
            cases: [
                TranscriptionBenchmarkCase(
                    id: "internal-system-only",
                    audioFilePath: audioEvidence.path,
                    reference: "source separated coverage must include the microphone path",
                    hypothesis: "source separated coverage must include the microphone path",
                    locale: "en-US",
                    corpus: .internalCritical,
                    evaluationTags: [.meeting],
                    evidenceKind: audioEvidence.kind,
                    audioSHA256: audioEvidence.sha256,
                    hypothesisSource: transcriptEvidence.source,
                    hypothesisEngineIdentifier: transcriptEvidence.engineIdentifier,
                    hypothesisRunID: transcriptEvidence.runID,
                    hypothesisTranscriptFilePath: transcriptEvidence.path,
                    hypothesisTranscriptSHA256: transcriptEvidence.sha256,
                    firstPartialLatencyMs: 240,
                    finalLatencyMs: 900,
                    audioDurationMs: 2_000,
                    processingDurationMs: 700,
                    latencyMeasurementMode: .realtimeReplay,
                    replayChunkDurationMs: 100,
                    memoryResidentBytes: 320_000_000,
                    cpuUsagePercent: 18
                )
            ],
            policy: policy
        )

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.failures.contains("missing_corpus_audio_source:internal-critical:microphone"))
        XCTAssertFalse(report.failures.contains("missing_corpus_audio_source:internal-critical:system"))
        XCTAssertEqual(report.coverage.first?.audioSources, [.system])
    }

    func testTranscriptionReleaseGateRejectsTranscriptEvidenceForDifferentAudio() throws {
        let evidenceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchly-transcript-audio-mismatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidenceDirectory) }
        let audioEvidence = try Self.releaseGateAudioEvidence(
            id: "ami-transcript-audio-mismatch",
            kind: .publicCorpus,
            directory: evidenceDirectory,
            durationMs: 3_000
        )
        let transcriptEvidence = try Self.releaseGateHypothesisEvidence(
            id: "ami-transcript-audio-mismatch",
            hypothesis: "transcript evidence must be tied to this exact audio",
            source: .importedASR,
            locale: "en-US",
            engineIdentifier: "notchly-imported-asr-evaluation",
            runID: "audio-mismatch-run",
            audioSHA256: String(repeating: "0", count: 64),
            audioDurationMs: 1_000,
            directory: evidenceDirectory
        )

        var policy = TranscriptionReleaseGatePolicy.topTierRelease
        policy.requiredCorpora = [.ami]
        policy.requiredLocales = ["en-US"]
        policy.requiredTags = [.meeting]

        let report = TranscriptionReleaseGate().evaluate(
            cases: [
                TranscriptionBenchmarkCase(
                    id: "ami-transcript-audio-mismatch",
                    audioFilePath: audioEvidence.path,
                    reference: "transcript evidence must be tied to this exact audio",
                    hypothesis: "transcript evidence must be tied to this exact audio",
                    locale: "en-US",
                    corpus: .ami,
                    evaluationTags: [.meeting],
                    evidenceKind: audioEvidence.kind,
                    audioSHA256: audioEvidence.sha256,
                    hypothesisSource: transcriptEvidence.source,
                    hypothesisEngineIdentifier: transcriptEvidence.engineIdentifier,
                    hypothesisRunID: transcriptEvidence.runID,
                    hypothesisTranscriptFilePath: transcriptEvidence.path,
                    hypothesisTranscriptSHA256: transcriptEvidence.sha256,
                    firstPartialLatencyMs: 410,
                    finalLatencyMs: 1_200,
                    audioDurationMs: 3_000,
                    processingDurationMs: 1_000
                )
            ],
            policy: policy
        )

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.failures.contains("hypothesis_audio_checksum_mismatch:ami-transcript-audio-mismatch"))
        XCTAssertTrue(report.failures.contains("hypothesis_audio_duration_mismatch:ami-transcript-audio-mismatch"))
    }

    func testLocalASRRefinementCandidateSelectorPrefersAutoLanguageVocabularyRepair() {
        var original = segment(text: "Notchley uses speech analyzer and core mail", isFinal: true)
        original.engineConfidence = 0.48
        original.languageConfidence = 0.44
        let context = SpeechRecognitionContext(
            locale: "en-US",
            terms: [
                SpeechContextTerm(text: "Notchly", locale: "en-US", category: .product, weight: 2.0, pronunciationXSAMPA: nil, source: "test"),
                SpeechContextTerm(text: "SpeechAnalyzer", locale: "en-US", category: .technicalTerm, weight: 2.0, pronunciationXSAMPA: nil, source: "test"),
                SpeechContextTerm(text: "Core ML", locale: "en-US", category: .technicalTerm, weight: 2.0, pronunciationXSAMPA: nil, source: "test")
            ]
        )

        let selection = LocalASRRefinementCandidateSelector().select(
            candidates: [
                LocalASRRefinementCandidate(
                    id: "forced",
                    text: "Notchly uses speech analyzer and core mail",
                    languageCode: "en",
                    confidence: 0.54,
                    source: .forcedLanguage
                ),
                LocalASRRefinementCandidate(
                    id: "auto",
                    text: "Notchly uses SpeechAnalyzer and Core ML",
                    languageCode: "en",
                    confidence: 0.51,
                    source: .autoLanguage
                )
            ],
            original: original,
            context: context
        )

        XCTAssertEqual(selection?.candidate.id, "auto")
        XCTAssertEqual(selection?.reason, "vocabulary_recall_improved")
    }

    func testLocalASRRefinementCandidateSelectorAllowsSpokenLanguageMetadataRepair() {
        var original = segment(text: "vamos revisar o Core ML rollout", isFinal: true)
        original.originalLanguage = "en-US"
        original.engineConfidence = 0.52
        original.languageConfidence = 0.31

        let selection = LocalASRRefinementCandidateSelector().select(
            candidates: [
                LocalASRRefinementCandidate(
                    id: "forced",
                    text: "vamos revisar o Core ML rollout",
                    languageCode: "en",
                    confidence: 0.78,
                    source: .forcedLanguage
                ),
                LocalASRRefinementCandidate(
                    id: "auto",
                    text: "vamos revisar o Core ML rollout",
                    languageCode: "pt",
                    confidence: 0.53,
                    source: .autoLanguage
                )
            ],
            original: original,
            context: nil
        )

        XCTAssertEqual(selection?.candidate.id, "auto")
        XCTAssertEqual(selection?.reason, "spoken_language_repair")
    }

    func testLocalASRRefinementLanguageConfidenceDoesNotInheritWrongOriginalLanguage() {
        var original = segment(text: "vamos revisar o Core ML rollout", isFinal: true)
        original.originalLanguage = "pt-BR"
        original.languageConfidence = 0.96
        let autoLanguageCandidate = LocalASRRefinementCandidate(
            id: "auto",
            text: "we should review the Core ML rollout",
            languageCode: "en",
            confidence: 0.74,
            source: .autoLanguage
        )

        let changedConfidence = LocalASRRefinementCandidateSelector.languageConfidence(
            candidate: autoLanguageCandidate,
            resultLanguageCode: autoLanguageCandidate.languageCode,
            refinedConfidence: 0.74,
            original: original
        )
        XCTAssertEqual(changedConfidence, 0.74, accuracy: 0.0001)

        let sameLanguageConfidence = LocalASRRefinementCandidateSelector.languageConfidence(
            candidate: LocalASRRefinementCandidate(
                id: "same",
                text: original.text,
                languageCode: "pt",
                confidence: 0.62,
                source: .forcedLanguage
            ),
            resultLanguageCode: "pt",
            refinedConfidence: 0.62,
            original: original
        )
        XCTAssertEqual(sameLanguageConfidence, 0.96, accuracy: 0.0001)
    }

    func testTranscriptionMetricsFalseSpeechRateCountsOnlyForwardedNonSpeech() async {
        await TranscriptionMetrics.shared.reset()
        await TranscriptionMetrics.shared.recordAudioDecision(vadDecision(state: .silence, shouldForward: false, reason: "below_floor"))
        await TranscriptionMetrics.shared.recordAudioDecision(vadDecision(state: .noise, shouldForward: false, reason: "impulse_click"))

        var snapshot = await TranscriptionMetrics.shared.snapshot()
        XCTAssertEqual(snapshot.falseSpeechRate, 0)

        await TranscriptionMetrics.shared.recordAudioDecision(vadDecision(state: .noise, shouldForward: true, reason: "hangover_misfire"))
        snapshot = await TranscriptionMetrics.shared.snapshot()
        XCTAssertEqual(snapshot.falseSpeechRate, 1.0 / 3.0, accuracy: 0.0001)
    }

    func testTranscriptionMetricsTracksVoiceActivityDetectionEngineProvenance() async {
        await TranscriptionMetrics.shared.reset()
        await TranscriptionMetrics.shared.recordAudioDecision(vadDecision(
            state: .silence,
            shouldForward: false,
            reason: "below_floor",
            detectionEngine: .heuristicEnergy
        ))
        await TranscriptionMetrics.shared.recordAudioDecision(vadDecision(
            state: .speechActive,
            shouldForward: true,
            reason: "vad_disabled",
            detectionEngine: .vadDisabledPassthrough
        ))
        await TranscriptionMetrics.shared.recordAudioDecision(vadDecision(
            state: .noise,
            shouldForward: false,
            reason: "speech_detector_drop",
            detectionEngine: .appleSpeechDetector
        ))

        let snapshot = await TranscriptionMetrics.shared.snapshot()
        XCTAssertEqual(snapshot.voiceActivityDetectionEngineCounts["heuristic_energy"], 1)
        XCTAssertEqual(snapshot.voiceActivityDetectionEngineCounts["vad_disabled_passthrough"], 1)
        XCTAssertEqual(snapshot.voiceActivityDetectionEngineCounts["apple_speech_detector"], 1)
        XCTAssertNil(snapshot.voiceActivityDetectionEngineCounts["evaluation_replay"])
    }

    func testTranscriptionMetricsRecordsNativeSpeechDetectorObservationsAsVADProvenance() async {
        await TranscriptionMetrics.shared.reset()
        await TranscriptionMetrics.shared.recordNativeSpeechDetectorObservation(source: .system, speechDetected: false)
        await TranscriptionMetrics.shared.recordNativeSpeechDetectorObservation(source: .system, speechDetected: true)

        let snapshot = await TranscriptionMetrics.shared.snapshot()
        XCTAssertEqual(snapshot.voiceActivityDetectionEngineCounts["apple_speech_detector"], 2)
        XCTAssertEqual(snapshot.falseSpeechRate, 0)
        XCTAssertEqual(snapshot.rejectedLowEnergyCount, 0)
    }

    func testAudioFixtureManifestCoversCriticalLocalesAndSilence() throws {
        let manifest = try TranscriptionAudioFixtureGenerator.manifest()
        XCTAssertTrue(Set(manifest.map(\.locale)).isSuperset(of: ["pt-BR", "en-US", "es-ES", "ja-JP"]))
        XCTAssertTrue(Set(manifest.map(\.profile)).isSuperset(of: [
            .clean, .noisy, .reverb, .overlap, .lowVolume, .clipping, .silence, .clicks, .music, .breathing, .codeSwitching
        ]))
        XCTAssertTrue(manifest.contains { $0.profile == .silence && $0.reference.isEmpty })
        XCTAssertTrue(manifest.contains { $0.profile == .clicks && $0.reference.isEmpty })
        XCTAssertTrue(manifest.contains { $0.profile == .music && $0.reference.isEmpty })
        XCTAssertTrue(manifest.contains { $0.profile == .breathing && $0.reference.isEmpty })
    }

    func testStreamingASRRouterDoesNotSendCriticalNonSpeechToASR() async throws {
        for profile in [
            TranscriptionAudioFixtureProfile.silence,
            .clicks,
            .music,
            .breathing
        ] {
            let buffers = TranscriptionAudioFixtureGenerator.buffers(profile: profile, chunks: 3)
            let router = StreamingASRRouter(
                sources: [StreamingASRRouter.Source(speakerLabel: "You", audioSource: .microphone, audioStream: Self.stream(buffers))],
                serviceFactory: { _ in EchoOnAudioTranscriptionService() }
            )
            let collector = SegmentCollector()
            let collectTask = Task {
                for await segment in router.segments {
                    await collector.append(segment)
                }
            }
            try await router.startTranscription(audioStream: Self.emptyStream(), config: Self.makeConfig(featureFlags: TranscriptionFeatureFlags()))
            try? await Task.sleep(nanoseconds: 200_000_000)
            await router.stop()
            collectTask.cancel()

            let segments = await collector.values
            XCTAssertTrue(segments.isEmpty, "Profile \(profile.rawValue) should not reach ASR")
        }
    }

    func testStreamingASRRouterLetsSpeechReachASRWithSourceTag() async throws {
        let buffers = TranscriptionAudioFixtureGenerator.buffers(profile: TranscriptionAudioFixtureProfile.clean, chunks: 2)
        let router = StreamingASRRouter(
            sources: [StreamingASRRouter.Source(speakerLabel: "You", audioSource: .microphone, audioStream: Self.stream(buffers))],
            serviceFactory: { _ in EchoOnAudioTranscriptionService() }
        )
        let collector = SegmentCollector()
        let collectTask = Task {
            for await segment in router.segments {
                await collector.append(segment)
            }
        }
        try await router.startTranscription(audioStream: Self.emptyStream(), config: Self.makeConfig(featureFlags: TranscriptionFeatureFlags()))
        try? await Task.sleep(nanoseconds: 250_000_000)
        await router.stop()
        collectTask.cancel()

        let segments = await collector.values
        XCTAssertEqual(segments.first?.audioSource, .microphone)
        XCTAssertEqual(segments.first?.speakerLabel, "You")
        XCTAssertEqual(segments.first?.text, "heard Core ML")
    }

    func testStreamingASRRouterLetsVeryLowMicrophoneAndSystemSpeechReachASR() async throws {
        let cases: [(source: TranscriptAudioSource, amplitude: Float, speaker: String)] = [
            (.microphone, 0.00010, "You"),
            (.system, 0.000085, "System")
        ]

        for testCase in cases {
            let buffers = (0..<3).map {
                TranscriptionAudioFixtureGenerator.speechLikeBuffer(
                    amplitude: testCase.amplitude,
                    source: testCase.source,
                    offset: $0
                )
            }
            let router = StreamingASRRouter(
                sources: [StreamingASRRouter.Source(speakerLabel: testCase.speaker, audioSource: testCase.source, audioStream: Self.stream(buffers))],
                serviceFactory: { _ in EchoOnAudioTranscriptionService() }
            )
            let collector = SegmentCollector()
            let collectTask = Task {
                for await segment in router.segments {
                    await collector.append(segment)
                }
            }

            try await router.startTranscription(audioStream: Self.emptyStream(), config: Self.makeConfig(featureFlags: TranscriptionFeatureFlags()))
            try? await Task.sleep(nanoseconds: 300_000_000)
            await router.stop()
            collectTask.cancel()

            let values = await collector.values
            let segment = try XCTUnwrap(
                values.first,
                "Very low \(testCase.source.displayName) speech should be normalized and forwarded into ASR."
            )
            XCTAssertEqual(segment.audioSource, testCase.source)
            XCTAssertEqual(segment.speakerLabel, testCase.speaker)
            XCTAssertEqual(segment.text, "heard Core ML")
            XCTAssertGreaterThan(segment.audioEnergy ?? 0, 0.00025)
        }
    }

    func testStreamingASRRouterKeepsUltraLowVariablePhraseChunksTogether() async throws {
        let cases: [(source: TranscriptAudioSource, amplitudes: [Float], speaker: String)] = [
            (
                .microphone,
                [0.0000012, 0.0000030, 0.0000006, 0.0000027, 0.0000005, 0.0000024, 0.0000010, 0.0000028],
                "You"
            ),
            (
                .system,
                [0.0000010, 0.0000026, 0.0000005, 0.0000023, 0.00000045, 0.0000021, 0.0000009, 0.0000024],
                "System"
            )
        ]

        for testCase in cases {
            let buffers = testCase.amplitudes.enumerated().map { offset, amplitude in
                TranscriptionAudioFixtureGenerator.speechLikeBuffer(
                    amplitude: amplitude,
                    source: testCase.source,
                    offset: offset
                )
            }
            let router = StreamingASRRouter(
                sources: [StreamingASRRouter.Source(speakerLabel: testCase.speaker, audioSource: testCase.source, audioStream: Self.stream(buffers))],
                serviceFactory: { _ in CountingForwardedBufferTranscriptionService() }
            )
            let collector = SegmentCollector()
            let collectTask = Task {
                for await segment in router.segments {
                    await collector.append(segment)
                }
            }

            try await router.startTranscription(audioStream: Self.emptyStream(), config: Self.makeConfig(featureFlags: TranscriptionFeatureFlags()))
            try? await Task.sleep(nanoseconds: 450_000_000)
            await router.stop()
            collectTask.cancel()

            let values = await collector.values
            let segment = try XCTUnwrap(
                values.first,
                "\(testCase.source.displayName) should deliver a counted final segment after variable ultra-low speech."
            )
            XCTAssertEqual(segment.audioSource, testCase.source)
            XCTAssertEqual(segment.speakerLabel, testCase.speaker)
            XCTAssertEqual(segment.text, "received \(testCase.amplitudes.count) conditioned buffers")
            XCTAssertGreaterThan(segment.audioEnergy ?? 0, 0.00001)
        }
    }

    func testStreamingASRRouterReplaysEarlySegmentsForLateSubscriber() async throws {
        let buffers = TranscriptionAudioFixtureGenerator.buffers(profile: TranscriptionAudioFixtureProfile.clean, chunks: 2)
        let router = StreamingASRRouter(
            sources: [StreamingASRRouter.Source(speakerLabel: "You", audioSource: .microphone, audioStream: Self.stream(buffers))],
            serviceFactory: { _ in EchoOnAudioTranscriptionService() }
        )
        try await router.startTranscription(audioStream: Self.emptyStream(), config: Self.makeConfig(featureFlags: TranscriptionFeatureFlags()))
        try? await Task.sleep(nanoseconds: 200_000_000)

        let collector = SegmentCollector()
        let collectTask = Task {
            for await segment in router.segments {
                await collector.append(segment)
                break
            }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        await router.stop()
        collectTask.cancel()

        let segments = await collector.values
        XCTAssertEqual(segments.first?.text, "heard Core ML")
        XCTAssertEqual(segments.first?.audioSource, .microphone)
    }

    func testStreamingASRRouterEmitsRejectedLocalRefinerDecisionForEvidence() async throws {
        let buffers = TranscriptionAudioFixtureGenerator.buffers(profile: TranscriptionAudioFixtureProfile.clean, chunks: 4)
        let router = StreamingASRRouter(
            sources: [StreamingASRRouter.Source(speakerLabel: "You", audioSource: .microphone, audioStream: Self.stream(buffers))],
            refiner: RejectingLocalASRRefiner(),
            serviceFactory: { _ in EchoOnAudioTranscriptionService() }
        )
        let collector = SegmentCollector()
        let collectTask = Task {
            for await segment in router.segments {
                await collector.append(segment)
            }
        }
        let config = Self.makeConfig(featureFlags: TranscriptionFeatureFlags(localASRRefinerEnabled: true))
        try await router.startTranscription(audioStream: Self.emptyStream(), config: config)
        try? await Task.sleep(nanoseconds: 500_000_000)
        await router.stop()
        collectTask.cancel()

        let segments = await collector.values
        let original = try XCTUnwrap(segments.first { $0.retentionReason != .localRefinerRejected })
        let rejected = try XCTUnwrap(segments.first { $0.retentionReason == .localRefinerRejected })
        XCTAssertEqual(rejected.text, original.text)
        XCTAssertEqual(rejected.revisionOfSegmentId, original.id)
        XCTAssertEqual(rejected.revisionNumber, original.revisionNumber + 1)
        XCTAssertEqual(rejected.audioSource, .microphone)
        XCTAssertEqual(rejected.speakerLabel, "You")
    }

    func testStreamingASRRouterDoesNotDropConditionedSpeechWhenRecognizerStartsSlowly() async throws {
        let buffers = (0..<96).map { TranscriptionAudioFixtureGenerator.speechLikeBuffer(source: .microphone, offset: $0) }
        let router = StreamingASRRouter(
            sources: [StreamingASRRouter.Source(speakerLabel: "You", audioSource: .microphone, audioStream: Self.stream(buffers))],
            serviceFactory: { _ in DelayedCountingTranscriptionService(startDelayNanoseconds: 140_000_000) }
        )
        let collector = SegmentCollector()
        let collectTask = Task {
            for await segment in router.segments {
                await collector.append(segment)
            }
        }
        try await router.startTranscription(audioStream: Self.emptyStream(), config: Self.makeConfig(featureFlags: TranscriptionFeatureFlags()))
        try? await Task.sleep(nanoseconds: 450_000_000)
        await router.stop()
        collectTask.cancel()

        let segments = await collector.values
        XCTAssertEqual(segments.first?.text, "received 96 speech buffers")
    }

    func testAudioMixerPreservesSourceTagsAndMonotonicMediaOrderWithoutDroppingBuffers() async {
        let mixer = AudioMixerService()
        let microphone = Self.stream([
            Self.timedBuffer(source: .unknown, mediaSeconds: 0.20),
            Self.timedBuffer(source: .unknown, mediaSeconds: 0.40)
        ])
        let system = Self.stream([
            Self.timedBuffer(source: .unknown, mediaSeconds: 0.10),
            Self.timedBuffer(source: .unknown, mediaSeconds: 0.30)
        ])

        var merged: [NotchCopilot.AudioBuffer] = []
        for await buffer in mixer.merge([
            AudioMixerInput(source: .microphone, stream: microphone),
            AudioMixerInput(source: .system, stream: system)
        ]) {
            merged.append(buffer)
        }

        XCTAssertEqual(merged.count, 4)
        XCTAssertEqual(merged.map { $0.audioSource }, [TranscriptAudioSource.system, .microphone, .system, .microphone])
        let times = merged.compactMap { $0.mediaTime?.seconds }
        XCTAssertEqual(times, times.sorted())
    }

    func testAudioMixerRepairsLateRegressiveTimestamps() async {
        let mixer = AudioMixerService()
        let regressive = Self.delayedStream([
            (Self.timedBuffer(source: .unknown, mediaSeconds: 0.40), 0),
            (Self.timedBuffer(source: .unknown, mediaSeconds: 0.20), 140_000_000)
        ])

        var merged: [NotchCopilot.AudioBuffer] = []
        for await buffer in mixer.merge([AudioMixerInput(source: .microphone, stream: regressive)]) {
            merged.append(buffer)
        }

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.map(\.audioSource), [.microphone, .microphone])
        let times = merged.compactMap { $0.mediaTime?.seconds }
        XCTAssertEqual(times, times.sorted())
        XCTAssertGreaterThan(times.last ?? 0, times.first ?? 0)
    }

    private static func releaseGateAudioEvidence(
        id: String,
        kind: TranscriptionBenchmarkEvidenceKind,
        directory: URL,
        durationMs: Double = 3_000,
        amplitude: Float = 0.035
    ) throws -> (path: String, sha256: String, kind: TranscriptionBenchmarkEvidenceKind) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(id).wav")
        try Self.writeReleaseGateWaveFile(to: url, durationMs: durationMs, amplitude: amplitude)
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (url.path, digest, kind)
    }

    private static func sha256HexDigest(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func releaseGateAudioFixtureEvidence(
        id: String,
        profile: TranscriptionAudioFixtureProfile,
        kind: TranscriptionBenchmarkEvidenceKind,
        directory: URL,
        durationMs: Double
    ) throws -> (path: String, sha256: String, kind: TranscriptionBenchmarkEvidenceKind) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(id).wav")
        let chunks = max(1, Int((durationMs / 100).rounded(.toNearestOrAwayFromZero)))
        let buffers = TranscriptionAudioFixtureGenerator.buffers(profile: profile, chunks: chunks)
        try Self.writeReleaseGateWaveFile(to: url, buffers: buffers)
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (url.path, digest, kind)
    }

    private static func releaseGateHypothesisEvidence(
        id: String,
        hypothesis: String,
        source: TranscriptionHypothesisSource = .evaluationReplay,
        locale: String,
        engineIdentifier: String,
        runID: String,
        audioSHA256: String,
        audioDurationMs: Double,
        audioSource: TranscriptAudioSource = .system,
        segments: [TranscriptionHypothesisTranscriptEvidence.SegmentEvidence]? = nil,
        audioConditioning: TranscriptionAudioConditioningEvidence? = nil,
        latencyMeasurementMode: TranscriptionLatencyMeasurementMode? = nil,
        replayChunkDurationMs: Double? = nil,
        postAudioDrainMs: Double? = nil,
        retentionReason: TranscriptionRetentionReason? = nil,
        languageEvidenceSource: String? = nil,
        languageDetectionWindowMs: Double? = nil,
        languageSpanCodes: [String]? = nil,
        corpusProvenance: TranscriptionCorpusProvenance? = nil,
        directory: URL
    ) throws -> (
        path: String,
        sha256: String,
        source: TranscriptionHypothesisSource,
        engineIdentifier: String,
        runID: String
    ) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(id).transcript.json")
        let evidence = TranscriptionHypothesisTranscriptEvidence(
            caseID: id,
            hypothesis: hypothesis,
            source: source,
            engineIdentifier: engineIdentifier,
            runID: runID,
            locale: locale,
            segmentCount: segments?.count ?? (hypothesis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1),
            segments: segments ?? Self.releaseGateSegmentEvidence(
                hypothesis: hypothesis,
                source: source,
                locale: locale,
                audioDurationMs: audioDurationMs,
                audioSource: audioSource,
                retentionReason: retentionReason,
                languageEvidenceSource: languageEvidenceSource,
                languageDetectionWindowMs: languageDetectionWindowMs,
                languageSpanCodes: languageSpanCodes
            ),
            audioSHA256: audioSHA256,
            audioDurationMs: audioDurationMs,
            audioConditioning: audioConditioning ?? Self.releaseGateAudioConditioningEvidence(
                hypothesis: hypothesis,
                audioDurationMs: audioDurationMs,
                audioSource: audioSource
            ),
            latencyMeasurementMode: latencyMeasurementMode,
            replayChunkDurationMs: replayChunkDurationMs,
            postAudioDrainMs: postAudioDrainMs,
            generatedAt: "2026-05-29T00:00:00Z",
            corpusProvenance: corpusProvenance
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(evidence)
        try data.write(to: url, options: .atomic)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (url.path, digest, source, engineIdentifier, runID)
    }

    private static func releaseGateAudioConditioningEvidence(
        hypothesis: String,
        audioDurationMs: Double,
        audioSource: TranscriptAudioSource = .system
    ) -> TranscriptionAudioConditioningEvidence {
        let hasSpeech = !hypothesis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let inputBuffers = max(1, Int((audioDurationMs / 100).rounded(.toNearestOrAwayFromZero)))
        return TranscriptionAudioConditioningEvidence(
            audioSource: audioSource,
            conditioningTarget: "native-speech",
            advancedConditioningEnabled: true,
            vadGatingEnabled: true,
            inputBufferCount: inputBuffers,
            emittedBufferCount: hasSpeech ? inputBuffers : 0,
            forwardedDecisionCount: hasSpeech ? inputBuffers : 0,
            droppedDecisionCount: hasSpeech ? 0 : inputBuffers,
            speechDecisionCount: hasSpeech ? inputBuffers : 0,
            nonSpeechDecisionCount: hasSpeech ? 0 : inputBuffers,
            clippingDecisionCount: 0,
            lowEnergyDropCount: hasSpeech ? 0 : inputBuffers,
            preRollReplayBufferCount: 0,
            vadEngineCounts: [VoiceActivityDetectionEngine.heuristicEnergy.rawValue: inputBuffers],
            inputSampleRates: [16_000],
            inputChannelCounts: [1],
            averageRMS: hasSpeech ? 0.025 : 0,
            peakMax: hasSpeech ? 0.060 : 0,
            snrP50Db: hasSpeech ? 18 : 0,
            snrP95Db: hasSpeech ? 22 : 0
        )
    }

    private static func releaseGateSegmentEvidence(
        hypothesis: String,
        source: TranscriptionHypothesisSource,
        locale: String,
        audioDurationMs: Double,
        audioSource: TranscriptAudioSource = .system,
        retentionReason: TranscriptionRetentionReason? = nil,
        languageEvidenceSource: String? = nil,
        languageDetectionWindowMs: Double? = nil,
        languageSpanCodes: [String]? = nil
    ) -> [TranscriptionHypothesisTranscriptEvidence.SegmentEvidence] {
        let trimmed = hypothesis.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let resolvedRetentionReason = retentionReason ?? (source == .whisperKit ? .localRefinerAccepted : nil)
        let isLocalRefinerDecision = resolvedRetentionReason == .localRefinerAccepted || resolvedRetentionReason == .localRefinerRejected || source == .whisperKit
        let revisionRoot = isLocalRefinerDecision ? UUID() : nil
        let resolvedLanguageEvidenceSource = languageEvidenceSource ?? (source == .whisperKit ? "whisperkit-auto-language" : "text-language-detection")
        let resolvedLanguageDetectionWindowMs = languageDetectionWindowMs ?? min(max(20, audioDurationMs), 1_500)
        let resolvedLanguageSpanCodes = languageSpanCodes ?? [locale]
        return [
            TranscriptionHypothesisTranscriptEvidence.SegmentEvidence(
                text: trimmed,
                audioSource: audioSource,
                speakerLabel: audioSource == .microphone ? "You" : "System",
                startTime: 0,
                endTime: max(0.02, audioDurationMs / 1_000),
                isFinal: true,
                transcriptionPhase: source == .whisperKit ? .refined : .final,
                transcriptionEngine: releaseGateTranscriptionEngine(for: source),
                finalizedBy: releaseGateTranscriptionEngine(for: source),
                confidence: 0.96,
                engineConfidence: 0.96,
                languageCode: locale,
                languageConfidence: 0.92,
                languageEvidenceSource: resolvedLanguageEvidenceSource,
                languageDetectionWindowMs: resolvedLanguageDetectionWindowMs,
                languageSpanCodes: resolvedLanguageSpanCodes,
                revisionOfSegmentId: revisionRoot,
                revisionNumber: isLocalRefinerDecision ? 1 : 0,
                retentionReason: resolvedRetentionReason,
                sourceFrameRange: AudioSourceFrameRange(start: 0, end: Int64(max(1, audioDurationMs * 16))),
                wordTimestampCount: trimmed.split(separator: " ").count
            )
        ]
    }

    private static func releaseGateTranscriptionEngine(for source: TranscriptionHypothesisSource) -> TranscriptionEngineName {
        switch source {
        case .appleSpeech, .sfSpeech:
            return .appleSpeech
        case .speechAnalyzer:
            return .speechAnalyzer
        case .whisperKit:
            return .whisperKit
        case .cloudFallback:
            return .elevenLabs
        case .manual, .deterministicFixture, .evaluationReplay, .importedASR:
            return .unavailable
        }
    }

    private static func publicCorpusProvenance(
        _ corpus: TranscriptionEvaluationCorpus,
        sampleID: String,
        sourceURI: String? = nil,
        datasetVersion: String = "test-release-gate-schema",
        license: String = "test-fixture-license",
        speakerCount: Int = 1
    ) -> TranscriptionCorpusProvenance {
        TranscriptionCorpusProvenance(
            corpus: corpus,
            sampleID: sampleID,
            sourceURI: sourceURI ?? defaultPublicCorpusSourceURI(corpus, sampleID: sampleID),
            datasetVersion: datasetVersion,
            license: license,
            origin: .publicCorpusSample,
            speakerCount: speakerCount,
            consentVerified: nil
        )
    }

    private static func defaultPublicCorpusSourceURI(
        _ corpus: TranscriptionEvaluationCorpus,
        sampleID: String
    ) -> String {
        switch corpus {
        case .ami:
            return "https://groups.inf.ed.ac.uk/ami/corpus/\(sampleID)"
        case .fleurs:
            return "https://huggingface.co/datasets/google/fleurs/tree/main/\(sampleID)"
        case .voxLingua107:
            return "https://bark.phon.ioc.ee/voxlingua107/\(sampleID)"
        case .earnings21:
            return "https://github.com/revdotcom/speech-datasets/tree/main/earnings21/\(sampleID)"
        case .conec:
            return "https://github.com/huangruizhe/ConEC/tree/main/\(sampleID)"
        case .internalCritical, .privateMeetingPack:
            return "https://groups.inf.ed.ac.uk/ami/corpus/\(sampleID)"
        }
    }

    private static func privateCorpusProvenance(
        sampleID: String,
        sourceURI: String = "private://notchly/private-meeting-pack/test-fixture",
        speakerCount: Int = 2
    ) -> TranscriptionCorpusProvenance {
        TranscriptionCorpusProvenance(
            corpus: .privateMeetingPack,
            sampleID: sampleID,
            sourceURI: sourceURI,
            datasetVersion: "test-private-pack",
            license: nil,
            origin: .privateMeetingRecording,
            speakerCount: speakerCount,
            consentVerified: true
        )
    }

    private static func writeReleaseGateWaveFile(to url: URL, durationMs: Double, amplitude: Float) throws {
        let sampleRate = 16_000.0
        let frameCount = max(1, AVAudioFrameCount((durationMs / 1_000) * sampleRate))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let channel = buffer.floatChannelData![0]
        for frame in 0..<Int(frameCount) {
            let tone = sin(2.0 * Double.pi * 440.0 * Double(frame) / sampleRate)
            channel[frame] = amplitude * Float(tone)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private static func writeReleaseGateWaveFile(to url: URL, buffers: [NotchCopilot.AudioBuffer]) throws {
        guard let firstPCMBuffer = buffers.first?.pcmBuffer else {
            throw NSError(domain: "NotchlyTranscriptionTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing fixture buffers"])
        }
        let file = try AVAudioFile(forWriting: url, settings: firstPCMBuffer.format.settings)
        for buffer in buffers {
            guard let pcmBuffer = buffer.pcmBuffer else {
                throw NSError(domain: "NotchlyTranscriptionTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Fixture buffer has no PCM payload"])
            }
            try file.write(from: pcmBuffer)
        }
    }

    private static func writeManifest(_ manifest: TranscriptionEvaluationManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: .atomic)
    }

    private static func writeGeneratedSpeechBenchmarkReport(_ report: GeneratedSpeechASRBenchmarkReport, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try data.write(to: url, options: .atomic)
    }

    private static func writeReplayReport(_ report: TranscriptionEvaluationReplayRunReport, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try data.write(to: url, options: .atomic)
    }

    private static func makeConfig(
        languageCode: String = "en-US",
        contextualStrings: [String] = ["Core ML", "Notchly"],
        featureFlags: TranscriptionFeatureFlags,
        localASRRefinerModel: String = "distil-large-v3",
        allowLocalASRModelDownload: Bool = false
    ) -> TranscriptionConfig {
        TranscriptionConfig(
            languageCode: languageCode,
            requiresOnDeviceRecognition: true,
            meetingId: UUID(),
            contextualStrings: contextualStrings,
            speechContext: SpeechRecognitionContext(
                locale: languageCode,
                terms: contextualStrings.map {
                    SpeechContextTerm(text: $0, locale: languageCode, category: .technicalTerm, weight: 2, pronunciationXSAMPA: nil, source: "test")
                }
            ),
            audioSource: .microphone,
            featureFlags: featureFlags,
            localASRRefinerModel: localASRRefinerModel,
            allowLocalASRModelDownload: allowLocalASRModelDownload
        )
    }

    private static func stream(_ buffers: [NotchCopilot.AudioBuffer]) -> AsyncStream<NotchCopilot.AudioBuffer> {
        AsyncStream { continuation in
            Task {
                for buffer in buffers {
                    continuation.yield(buffer)
                }
                continuation.finish()
            }
        }
    }

    private static func delayedStream(
        _ buffers: [(NotchCopilot.AudioBuffer, UInt64)]
    ) -> AsyncStream<NotchCopilot.AudioBuffer> {
        AsyncStream { continuation in
            let task = Task {
                for (buffer, delay) in buffers {
                    if delay > 0 {
                        try? await Task.sleep(nanoseconds: delay)
                    }
                    if Task.isCancelled { break }
                    continuation.yield(buffer)
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private static func timedStream(
        _ buffers: [NotchCopilot.AudioBuffer],
        nanosecondsBetweenBuffers: UInt64
    ) -> AsyncStream<NotchCopilot.AudioBuffer> {
        AsyncStream { continuation in
            let task = Task {
                for buffer in buffers {
                    if Task.isCancelled { break }
                    continuation.yield(buffer)
                    if nanosecondsBetweenBuffers > 0 {
                        try? await Task.sleep(nanoseconds: nanosecondsBetweenBuffers)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private static func emptyStream() -> AsyncStream<NotchCopilot.AudioBuffer> {
        AsyncStream { $0.finish() }
    }

    private static func collectSegments(
        from collector: SegmentCollector,
        minimumCount: Int,
        timeoutNanoseconds: UInt64,
        isSatisfied: (([TranscriptSegment]) -> Bool)? = nil
    ) async -> [TranscriptSegment] {
        let pollInterval: UInt64 = 50_000_000
        var waited: UInt64 = 0
        while waited < timeoutNanoseconds {
            let values = await collector.values
            if values.count >= minimumCount {
                if isSatisfied?(values) ?? true {
                    break
                }
            }
            try? await Task.sleep(nanoseconds: pollInterval)
            waited += pollInterval
        }
        return await collector.values
    }

    private static func collectBuffers(
        from stream: AsyncStream<NotchCopilot.AudioBuffer>,
        minimumCount: Int,
        timeoutNanoseconds: UInt64
    ) async -> [NotchCopilot.AudioBuffer] {
        let collector = AudioBufferCollector()
        let task = Task {
            for await buffer in stream {
                await collector.append(buffer)
                if await collector.count >= minimumCount {
                    break
                }
            }
        }
        try? await Task.sleep(nanoseconds: timeoutNanoseconds)
        task.cancel()
        return await collector.values
    }

    private static func timedBuffer(source: TranscriptAudioSource, mediaSeconds: TimeInterval) -> NotchCopilot.AudioBuffer {
        var buffer = TranscriptionAudioFixtureGenerator.speechLikeBuffer(source: source)
        buffer.mediaTime = CMTime(seconds: mediaSeconds, preferredTimescale: 1_000_000)
        return buffer
    }

    private static func generatedSpeechBuffers(
        text: String,
        voice: String = "Samantha",
        source: TranscriptAudioSource
    ) throws -> [NotchCopilot.AudioBuffer] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let audioURL = directory.appendingPathComponent("whisperkit-refiner-harness.aiff")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", voice, "-o", audioURL.path, text]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XCTSkip("/usr/bin/say could not generate local speech audio for the WhisperKit harness.")
        }

        let file = try AVAudioFile(forReading: audioURL)
        let analyzer = AppleAccelerateAudioAnalyzer()
        let framesPerChunk = AVAudioFrameCount(max(1, Int(file.processingFormat.sampleRate * 0.32)))
        var buffers: [NotchCopilot.AudioBuffer] = []
        while file.framePosition < file.length {
            let remaining = AVAudioFrameCount(file.length - file.framePosition)
            guard let pcmBuffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: min(framesPerChunk, remaining)
            ) else {
                break
            }
            try file.read(into: pcmBuffer, frameCount: min(framesPerChunk, remaining))
            guard pcmBuffer.frameLength > 0 else { continue }
            let result = analyzer.analyze(pcmBuffer)
            let endSeconds = Double(file.framePosition) / max(file.processingFormat.sampleRate, 1)
            buffers.append(NotchCopilot.AudioBuffer(
                pcmBuffer: pcmBuffer.copiedForAsyncUse(),
                time: nil,
                mediaTime: CMTime(seconds: endSeconds, preferredTimescale: 1_000_000),
                rms: result.rms,
                peak: result.peak,
                createdAt: Date(),
                audioSource: source
            ))
        }
        return buffers
    }

    private static func availableSayVoiceNames() -> Set<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", "?"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else {
            return []
        }
        return Set(output
            .components(separatedBy: .newlines)
            .compactMap { line -> String? in
                guard let range = line.range(of: #" [a-z]{2}_[A-Z]{2} "#, options: .regularExpression) else {
                    return nil
                }
                let name = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                return name.isEmpty ? nil : name
            })
    }

    private static func generatedSpeechBenchmarkSpecs() -> [GeneratedSpeechASRBenchmarkSpec] {
        [
            GeneratedSpeechASRBenchmarkSpec(
                id: "english-jargon",
                locale: "en-US",
                voice: "Samantha",
                reference: "Notchly uses SpeechAnalyzer and Core ML for local transcription",
                baselineHypothesis: "Notchley uses speech analyzer and core mail for local transcription",
                vocabulary: ["Notchly", "SpeechAnalyzer", "Core ML"],
                namedEntities: ["Notchly"],
                tags: [.meeting, .jargon, .contextualBias]
            ),
            GeneratedSpeechASRBenchmarkSpec(
                id: "portuguese-code-switch",
                locale: "pt-BR",
                voice: "Eddy (Portuguese (Brazil))",
                reference: "vamos validar SpeechAnalyzer com Core ML no Notchly",
                baselineHypothesis: "vamos validar speech analyzer com core mail no notch lee",
                vocabulary: ["SpeechAnalyzer", "Core ML", "Notchly"],
                namedEntities: ["Notchly"],
                tags: [.meeting, .multilingual, .codeSwitching, .jargon]
            ),
            GeneratedSpeechASRBenchmarkSpec(
                id: "spanish-router",
                locale: "es-ES",
                voice: "Eddy (Spanish (Spain))",
                reference: "validemos WhisperKit y el router de idioma",
                baselineHypothesis: "validemos whisper kid y el rotor de idioma",
                vocabulary: ["WhisperKit", "router"],
                namedEntities: ["WhisperKit"],
                tags: [.meeting, .multilingual, .jargon]
            ),
            GeneratedSpeechASRBenchmarkSpec(
                id: "japanese-lid",
                locale: "ja-JP",
                voice: "Eddy (Japanese (Japan))",
                reference: "Notchly の SpeechAnalyzer を確認します",
                baselineHypothesis: "Notchly no speech analyzer を確認します",
                vocabulary: ["Notchly", "SpeechAnalyzer"],
                namedEntities: ["Notchly"],
                tags: [.meeting, .multilingual, .spokenLanguageID, .jargon]
            )
        ]
    }

    private func vadDecision(
        state: VoiceActivityState,
        shouldForward: Bool,
        reason: String,
        detectionEngine: VoiceActivityDetectionEngine = .heuristicEnergy
    ) -> VoiceActivityDecision {
        VoiceActivityDecision(
            source: .microphone,
            detectionEngine: detectionEngine,
            state: state,
            shouldForwardToASR: shouldForward,
            speechProbability: shouldForward ? 0.6 : 0,
            rms: shouldForward ? 0.004 : 0.0001,
            peak: shouldForward ? 0.04 : 0.0002,
            noiseFloor: 0.0002,
            snrDb: shouldForward ? 18 : 0,
            zeroCrossingRate: 0.12,
            dynamicRange: 0.02,
            envelopeVariation: shouldForward ? 0.12 : 0,
            isClipping: false,
            reason: reason
        )
    }

    private func segment(
        id: UUID = UUID(),
        text: String,
        isFinal: Bool,
        start: TimeInterval = 0,
        end: TimeInterval = 1
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            meetingId: UUID(),
            speakerLabel: "You",
            audioSource: .microphone,
            text: text,
            originalLanguage: "en-US",
            transcriptionPhase: isFinal ? .final : .draft,
            transcriptionEngine: .appleSpeech,
            startTime: start,
            endTime: end,
            confidence: 0.8,
            isFinal: isFinal
        )
    }
}

private actor SegmentCollector {
    private var collected: [TranscriptSegment] = []

    var values: [TranscriptSegment] {
        collected
    }

    var count: Int {
        collected.count
    }

    func append(_ segment: TranscriptSegment) {
        collected.append(segment)
    }
}

private actor AudioBufferCollector {
    private var collected: [NotchCopilot.AudioBuffer] = []

    var values: [NotchCopilot.AudioBuffer] {
        collected
    }

    var count: Int {
        collected.count
    }

    func append(_ buffer: NotchCopilot.AudioBuffer) {
        collected.append(buffer)
    }
}

private struct RejectingLocalASRRefiner: LocalASRRefining {
    func refine(
        segment: TranscriptSegment,
        audioBuffers: [NotchCopilot.AudioBuffer],
        config: TranscriptionConfig
    ) async -> LocalASRRefinementOutcome? {
        guard !audioBuffers.isEmpty else { return nil }
        var rejected = segment
        rejected.retentionReason = .localRefinerRejected
        rejected.revisionOfSegmentId = segment.revisionOfSegmentId ?? segment.id
        rejected.revisionNumber = segment.revisionNumber + 1
        rejected.createdAt = Date()
        return LocalASRRefinementOutcome(
            segment: rejected,
            accepted: false,
            reason: "unit_refiner_rejected_no_quality_gain",
            candidateText: segment.text,
            candidateConfidence: segment.confidence
        )
    }
}

@MainActor
private final class EchoOnAudioTranscriptionService: TranscriptionService {
    private var continuation: AsyncStream<TranscriptSegment>.Continuation?
    private var task: Task<Void, Never>?

    var segments: AsyncStream<TranscriptSegment> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func startTranscription(audioStream: AsyncStream<NotchCopilot.AudioBuffer>, config: TranscriptionConfig) async throws {
        task = Task { @MainActor [weak self] in
            for await buffer in audioStream {
                guard buffer.rms > 0.00025 else { continue }
                self?.continuation?.yield(TranscriptSegment(
                    meetingId: config.meetingId,
                    speakerLabel: "Echo",
                    audioSource: buffer.audioSource,
                    text: "heard Core ML",
                    originalLanguage: config.languageCode,
                    transcriptionPhase: .final,
                    transcriptionEngine: .appleSpeech,
                    audioEnergy: Double(buffer.rms),
                    startTime: 0,
                    endTime: 1,
                    confidence: 0.82,
                    isFinal: true
                ))
                break
            }
            self?.continuation?.finish()
        }
    }

    func stop() async {
        task?.cancel()
        task = nil
        continuation?.finish()
        continuation = nil
    }
}

@MainActor
private final class CountingForwardedBufferTranscriptionService: TranscriptionService {
    private var continuation: AsyncStream<TranscriptSegment>.Continuation?
    private var task: Task<Void, Never>?

    var segments: AsyncStream<TranscriptSegment> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func startTranscription(audioStream: AsyncStream<NotchCopilot.AudioBuffer>, config: TranscriptionConfig) async throws {
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            var count = 0
            var maxRMS: Float = 0
            for await buffer in audioStream where buffer.rms > 0 {
                count += 1
                maxRMS = max(maxRMS, buffer.rms)
            }
            self.continuation?.yield(TranscriptSegment(
                meetingId: config.meetingId,
                speakerLabel: "Counter",
                audioSource: config.audioSource,
                text: "received \(count) conditioned buffers",
                originalLanguage: config.languageCode,
                transcriptionPhase: .final,
                transcriptionEngine: .appleSpeech,
                audioEnergy: Double(maxRMS),
                startTime: 0,
                endTime: 1,
                confidence: 0.80,
                isFinal: true
            ))
            self.continuation?.finish()
        }
    }

    func stop() async {
        task?.cancel()
        task = nil
        continuation?.finish()
        continuation = nil
    }
}

@MainActor
private final class DelayedCountingTranscriptionService: TranscriptionService {
    private let startDelayNanoseconds: UInt64
    private var continuation: AsyncStream<TranscriptSegment>.Continuation?
    private var task: Task<Void, Never>?

    init(startDelayNanoseconds: UInt64) {
        self.startDelayNanoseconds = startDelayNanoseconds
    }

    var segments: AsyncStream<TranscriptSegment> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func startTranscription(audioStream: AsyncStream<NotchCopilot.AudioBuffer>, config: TranscriptionConfig) async throws {
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: startDelayNanoseconds)
            var count = 0
            for await buffer in audioStream where buffer.rms > 0.001 {
                count += 1
            }
            self.continuation?.yield(TranscriptSegment(
                meetingId: config.meetingId,
                speakerLabel: "Counter",
                audioSource: config.audioSource,
                text: "received \(count) speech buffers",
                originalLanguage: config.languageCode,
                transcriptionPhase: .final,
                transcriptionEngine: .appleSpeech,
                audioEnergy: 0.02,
                startTime: 0,
                endTime: 2,
                confidence: 0.9,
                isFinal: true
            ))
            self.continuation?.finish()
        }
    }

    func stop() async {
        task?.cancel()
        task = nil
        continuation?.finish()
        continuation = nil
    }
}
