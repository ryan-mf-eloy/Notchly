import AVFoundation
import Foundation

#if canImport(WhisperKit)
@preconcurrency import WhisperKit
#endif

struct LocalASRRefinementOutcome: Sendable {
    var segment: TranscriptSegment
    var accepted: Bool
    var reason: String
    var candidateText: String?
    var candidateConfidence: Double?
}

protocol LocalASRRefining: Sendable {
    func refine(
        segment: TranscriptSegment,
        audioBuffers: [AudioBuffer],
        config: TranscriptionConfig
    ) async -> LocalASRRefinementOutcome?
}

actor LocalASRRefinementService: LocalASRRefining {
    #if canImport(WhisperKit)
    private var whisper: WhisperKit?
    private var loadedModel: String?
    #endif

    func refine(
        segment: TranscriptSegment,
        audioBuffers: [AudioBuffer],
        config: TranscriptionConfig
    ) async -> LocalASRRefinementOutcome? {
        guard config.featureFlags.localASRRefinerEnabled,
              segment.isFinal,
              !audioBuffers.isEmpty,
              let samples = try? Self.floatSamples16kMono(from: audioBuffers),
              samples.count >= 4_000 else {
            return nil
        }

        #if canImport(WhisperKit)
        do {
            let kit = try await whisperKit(
                preferredModels: Self.preferredModels(for: config.localASRRefinerModel),
                allowDownload: config.allowLocalASRModelDownload
            )
            let languageCode = SupportedLanguage.language(for: segment.originalLanguage ?? config.languageCode)?.whisperLanguageCode
            let promptTokens = await Self.promptTokens(for: config.speechContext, kit: kit)
            let transcription = try await Self.transcribeWithFallbacks(
                kit: kit,
                samples: samples,
                languageCode: languageCode,
                promptTokens: promptTokens,
                original: segment,
                config: config
            )
            guard let best = transcription.result else {
                return Self.rejectedOutcome(
                    original: segment,
                    reason: "no_transcription_result \(Self.sampleSummary(samples)) \(transcription.diagnostic)"
                )
            }
            return await refinedOutcome(
                from: best,
                selectedCandidate: transcription.candidate,
                original: segment,
                config: config,
                selectionReason: transcription.reason
            )
        } catch {
            let reason = Self.rejectionReason(prefix: "whisperkit_error", error: error)
            AppLog.audio.info("WhisperKit refinement skipped: \(reason, privacy: .public)")
            return nil
        }
        #else
        return nil
        #endif
    }

    private static func rejectedOutcome(
        original: TranscriptSegment,
        reason: String,
        candidateText: String? = nil,
        candidateConfidence: Double? = nil
    ) -> LocalASRRefinementOutcome {
        var rejected = original
        rejected.retentionReason = .localRefinerRejected
        rejected.revisionOfSegmentId = original.revisionOfSegmentId ?? original.id
        rejected.revisionNumber = original.revisionNumber + 1
        rejected.createdAt = Date()
        if let candidateText = candidateText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !candidateText.isEmpty,
           SpeechVocabularyTerm.normalizedKey(candidateText, locale: original.originalLanguage) != SpeechVocabularyTerm.normalizedKey(original.text, locale: original.originalLanguage) {
            rejected.alternatives = ([TranscriptAlternative(
                text: candidateText,
                confidence: candidateConfidence,
                languageCode: original.originalLanguage,
                source: .localRefiner
            )] + original.alternatives).uniquedByText()
        }
        return LocalASRRefinementOutcome(
            segment: rejected,
            accepted: false,
            reason: reason,
            candidateText: candidateText,
            candidateConfidence: candidateConfidence
        )
    }

    #if canImport(WhisperKit)
    private static func preferredModels(for configuredModel: String) -> [String] {
        let model = configuredModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            return ["distil-large-v3", "large-v3-v20240930", "small"]
        }
        guard model == "distil-large-v3" else {
            return [model]
        }
        return [model, "large-v3-v20240930", "small"]
    }

    private func whisperKit(preferredModels: [String], allowDownload: Bool) async throws -> WhisperKit {
        var lastError: Error?
        var seen = Set<String>()
        for model in preferredModels where !model.isEmpty && seen.insert(model).inserted {
            do {
                return try await whisperKit(model: model, allowDownload: allowDownload)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? TranscriptionError.recognizerUnavailable
    }

    private func whisperKit(model: String, allowDownload: Bool) async throws -> WhisperKit {
        if let whisper, loadedModel == model {
            return whisper
        }
        let config = WhisperKitConfig(
            model: model,
            verbose: false,
            logLevel: .none,
            prewarm: false,
            load: true,
            download: allowDownload
        )
        let kit = try await WhisperKit(config)
        whisper = kit
        loadedModel = model
        return kit
    }

    private static func bestResult(_ results: [TranscriptionResult]) -> TranscriptionResult? {
        results
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .max { lhs, rhs in
                confidence(for: lhs) < confidence(for: rhs)
            }
    }

    private static func transcribeWithFallbacks(
        kit: WhisperKit,
        samples: [Float],
        languageCode: String?,
        promptTokens: [Int]?,
        original: TranscriptSegment,
        config: TranscriptionConfig
    ) async throws -> (result: TranscriptionResult?, candidate: LocalASRRefinementCandidate?, diagnostic: String, reason: String) {
        struct WhisperCandidate {
            var result: TranscriptionResult
            var candidate: LocalASRRefinementCandidate
        }

        var candidates: [WhisperCandidate] = []
        var emptyAttempts: [String] = []
        for attempt in Self.decodingAttempts(
            languageCode: languageCode,
            promptTokens: promptTokens,
            shouldRunAutoLanguageDecode: Self.shouldRunAutoLanguageDecode(original: original, config: config, languageCode: languageCode)
        ) {
            let results = try await kit.transcribe(audioArray: samples, decodeOptions: attempt.options)
            if let result = Self.bestResult(results) {
                let confidence = Self.confidence(for: result)
                candidates.append(WhisperCandidate(
                    result: result,
                    candidate: LocalASRRefinementCandidate(
                        id: attempt.id,
                        text: result.text,
                        languageCode: result.language,
                        confidence: confidence,
                        source: attempt.source
                    )
                ))
            } else {
                emptyAttempts.append("\(attempt.id):results=\(results.count)")
            }
        }
        let selection = LocalASRRefinementCandidateSelector().select(
            candidates: candidates.map(\.candidate),
            original: original,
            context: config.speechContext
        )
        guard let selected = selection,
              let match = candidates.first(where: { $0.candidate.id == selected.candidate.id })
        else {
            let diagnostics = emptyAttempts.isEmpty ? "candidates=\(candidates.count)" : emptyAttempts.joined(separator: ",")
            return (candidates.first?.result, candidates.first?.candidate, diagnostics, selection?.reason ?? "no_quality_gain")
        }
        let diagnostics = ([selected.candidate.id] + emptyAttempts).joined(separator: ",")
        return (match.result, selected.candidate, diagnostics, selected.reason)
    }

    private static func shouldRunAutoLanguageDecode(original: TranscriptSegment, config: TranscriptionConfig, languageCode: String?) -> Bool {
        guard languageCode != nil else { return false }
        if (original.languageConfidence ?? 0) < 0.72 {
            return true
        }
        if config.featureFlags.languageContinuityV2Enabled && looksLikeMixedLanguageOrTechnicalIsland(original.text) {
            return true
        }
        return false
    }

    private struct DecodingAttempt {
        var id: String
        var source: LocalASRRefinementCandidate.Source
        var options: DecodingOptions
    }

    private static func decodingAttempts(
        languageCode: String?,
        promptTokens: [Int]?,
        shouldRunAutoLanguageDecode: Bool
    ) -> [DecodingAttempt] {
        var attempts = [
            DecodingAttempt(id: "forced_precise", source: languageCode == nil ? .autoLanguage : .forcedLanguage, options: DecodingOptions(
                verbose: false,
                language: languageCode,
                temperatureFallbackCount: 3,
                usePrefillPrompt: true,
                detectLanguage: languageCode == nil,
                skipSpecialTokens: true,
                wordTimestamps: true,
                promptTokens: promptTokens,
                noSpeechThreshold: 0.65,
                concurrentWorkerCount: 2
            )),
            DecodingAttempt(id: "forced_relaxed", source: languageCode == nil ? .autoLanguage : .forcedLanguage, options: DecodingOptions(
                verbose: false,
                language: languageCode,
                temperatureFallbackCount: 3,
                usePrefillPrompt: true,
                detectLanguage: languageCode == nil,
                skipSpecialTokens: true,
                withoutTimestamps: true,
                wordTimestamps: false,
                promptTokens: promptTokens,
                compressionRatioThreshold: nil,
                logProbThreshold: nil,
                firstTokenLogProbThreshold: nil,
                noSpeechThreshold: nil,
                concurrentWorkerCount: 2
            ))
        ]
        if languageCode == nil || shouldRunAutoLanguageDecode {
            attempts.append(DecodingAttempt(id: "auto_language", source: .autoLanguage, options: DecodingOptions(
                verbose: false,
                language: nil,
                temperatureFallbackCount: 3,
                usePrefillPrompt: false,
                detectLanguage: true,
                skipSpecialTokens: true,
                withoutTimestamps: true,
                wordTimestamps: false,
                promptTokens: promptTokens,
                compressionRatioThreshold: nil,
                logProbThreshold: nil,
                firstTokenLogProbThreshold: nil,
                noSpeechThreshold: nil,
                concurrentWorkerCount: 2
            )))
        }
        return attempts
    }

    private static func sampleSummary(_ samples: [Float]) -> String {
        guard !samples.isEmpty else { return "samples=0" }
        var sumSquares: Double = 0
        var peak: Float = 0
        for sample in samples {
            let magnitude = abs(sample)
            peak = max(peak, magnitude)
            sumSquares += Double(sample * sample)
        }
        let rms = sqrt(sumSquares / Double(samples.count))
        let seconds = Double(samples.count) / 16_000
        return String(format: "samples=%d seconds=%.2f rms=%.5f peak=%.5f", samples.count, seconds, rms, peak)
    }

    private static func promptTokens(for context: SpeechRecognitionContext?, kit: WhisperKit) async -> [Int]? {
        guard let context else { return nil }
        let prompt = SpeechVocabularyBiasProvider().whisperPrompt(for: context, maxTerms: 64)
        guard !prompt.isEmpty else { return nil }
        do {
            try await kit.loadTokenizerIfNeeded()
            guard let tokenizer = kit.tokenizer else { return nil }
            return Array(tokenizer.encode(text: prompt).suffix(224))
        } catch {
            AppLog.audio.info("WhisperKit prompt bias skipped: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func refinedOutcome(
        from result: TranscriptionResult,
        selectedCandidate: LocalASRRefinementCandidate?,
        original: TranscriptSegment,
        config: TranscriptionConfig,
        selectionReason: String
    ) async -> LocalASRRefinementOutcome? {
        let refinedText = result.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard !refinedText.isEmpty else { return nil }

        let refinedConfidence = Self.confidence(for: result)
        let acceptance = LocalASRRefinementCandidateSelector.acceptance(
            candidate: selectedCandidate ?? LocalASRRefinementCandidate(
                id: "selected",
                text: refinedText,
                languageCode: result.language,
                confidence: refinedConfidence,
                source: .forcedLanguage
            ),
            original: original,
            context: config.speechContext
        )

        guard acceptance.accepted else {
            return Self.rejectedOutcome(
                original: original,
                reason: acceptance.reason,
                candidateText: refinedText,
                candidateConfidence: refinedConfidence
            )
        }

        var refined = original
        refined.text = refinedText
        refined.transcriptionPhase = .refined
        refined.transcriptionEngine = .whisperKit
        refined.finalizedBy = .whisperKit
        refined.engineConfidence = refinedConfidence
        refined.confidence = max(original.confidence, refinedConfidence)
        refined.revisionOfSegmentId = original.id
        refined.revisionNumber = original.revisionNumber + 1
        refined.retentionReason = .localRefinerAccepted
        refined.alternatives = ([TranscriptAlternative(
            text: original.text,
            confidence: original.engineConfidence ?? original.confidence,
            languageCode: original.originalLanguage,
            source: .transcription
        )] + original.alternatives).uniquedByText()
        if let language = SupportedLanguage.language(for: result.language) {
            refined.originalLanguage = language.rawValue
            refined.sourceLanguage = language.rawValue
            refined.languageConfidence = LocalASRRefinementCandidateSelector.languageConfidence(
                candidate: selectedCandidate,
                resultLanguageCode: result.language,
                refinedConfidence: refinedConfidence,
                original: original
            )
            refined.languageEvidenceSource = selectedCandidate?.source == .autoLanguage
                ? "whisperkit-auto-language"
                : "whisperkit-forced-language"
            refined.languageDetectionWindowMs = max(20, (original.endTime - original.startTime) * 1_000)
            refined.languageSpanCodes = Self.languageSpanCodes(original: original, refined: language.rawValue)
        }
        refined.wordTimestamps = Self.wordTimestamps(from: result, segmentStart: original.startTime, segmentEnd: original.endTime)
        return LocalASRRefinementOutcome(
            segment: refined,
            accepted: true,
            reason: "\(acceptance.reason);\(selectionReason)",
            candidateText: refinedText,
            candidateConfidence: refinedConfidence
        )
    }

    private static func confidence(for result: TranscriptionResult) -> Double {
        let segments = result.segments
        guard !segments.isEmpty else { return 0.5 }
        let values = segments.map { segment in
            let acoustic = min(max(Double(exp(segment.avgLogprob)), 0), 1)
            let speech = 1.0 - min(max(Double(segment.noSpeechProb), 0), 1)
            return acoustic * speech
        }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func languageSpanCodes(original: TranscriptSegment, refined: String) -> [String] {
        var codes: [String] = []
        for code in original.languageSpanCodes + [original.originalLanguage, original.sourceLanguage, refined].compactMap({ $0 }) {
            guard let language = SupportedLanguage.language(for: code) else { continue }
            if !codes.contains(language.rawValue) {
                codes.append(language.rawValue)
            }
        }
        return codes
    }

    private static func wordTimestamps(
        from result: TranscriptionResult,
        segmentStart: TimeInterval,
        segmentEnd: TimeInterval
    ) -> [TranscriptWordTimestamp] {
        result.allWords.map { word in
            let start = min(max(segmentStart + Double(word.start), segmentStart), max(segmentEnd, segmentStart))
            let end = min(max(segmentStart + Double(word.end), start), max(segmentEnd, start))
            return TranscriptWordTimestamp(
                word: word.word,
                startTime: start,
                endTime: end,
                confidence: Double(word.probability)
            )
        }
    }
    #endif

    private static func rejectionReason(prefix: String, error: Error) -> String {
        let message = error.localizedDescription
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .prefix(160)
        return "\(prefix):\(message)"
    }

    private static func looksLikeMixedLanguageOrTechnicalIsland(_ text: String) -> Bool {
        LocalASRRefinementCandidateSelector.looksLikeMixedLanguageOrTechnicalIsland(text)
    }

    private static func floatSamples16kMono(from buffers: [AudioBuffer]) throws -> [Float] {
        var samples: [Float] = []
        for buffer in buffers {
            guard let pcmBuffer = buffer.pcmBuffer else { continue }
            guard let converted = convertTo16kMonoFloat(pcmBuffer),
                  let channel = converted.floatChannelData?.pointee else { continue }
            let count = Int(converted.frameLength)
            samples.reserveCapacity(samples.count + count)
            for index in 0..<count {
                samples.append(channel[index])
            }
        }
        return samples
    }

    private static func convertTo16kMonoFloat(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            return nil
        }
        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else { return nil }
        let ratio = targetFormat.sampleRate / max(buffer.format.sampleRate, 1)
        let capacity = AVAudioFrameCount(max(1, Int(ceil(Double(buffer.frameLength) * ratio)) + 32))
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
        let state = AudioConditioningConverterInputStateForRefiner(buffer: buffer)
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if state.didProvideInput {
                status.pointee = .noDataNow
                return nil
            }
            state.didProvideInput = true
            status.pointee = .haveData
            return state.buffer
        }
        return error == nil ? output : nil
    }
}

private final class AudioConditioningConverterInputStateForRefiner: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var didProvideInput = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

private extension SupportedLanguage {
    var whisperLanguageCode: String {
        switch self {
        case .portugueseBR: "pt"
        case .englishUS: "en"
        case .spanishES: "es"
        case .japaneseJP: "ja"
        }
    }
}

struct LocalASRRefinementCandidate: Sendable, Hashable {
    enum Source: String, Sendable, Hashable {
        case forcedLanguage
        case autoLanguage
    }

    var id: String
    var text: String
    var languageCode: String?
    var confidence: Double
    var source: Source
}

struct LocalASRRefinementCandidateSelection: Sendable, Hashable {
    var candidate: LocalASRRefinementCandidate
    var reason: String
    var score: Double
}

struct LocalASRRefinementCandidateSelector: Sendable {
    func select(
        candidates: [LocalASRRefinementCandidate],
        original: TranscriptSegment,
        context: SpeechRecognitionContext?
    ) -> LocalASRRefinementCandidateSelection? {
        candidates.compactMap { candidate -> LocalASRRefinementCandidateSelection? in
            let acceptance = Self.acceptance(candidate: candidate, original: original, context: context)
            guard acceptance.accepted else { return nil }
            return LocalASRRefinementCandidateSelection(
                candidate: candidate,
                reason: acceptance.reason,
                score: acceptance.score
            )
        }
        .max { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.candidate.confidence < rhs.candidate.confidence
            }
            return lhs.score < rhs.score
        }
    }

    static func acceptance(
        candidate: LocalASRRefinementCandidate,
        original: TranscriptSegment,
        context: SpeechRecognitionContext?
    ) -> (accepted: Bool, reason: String, score: Double) {
        let refinedText = candidate.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let normalizedOriginal = SpeechVocabularyTerm.normalizedKey(original.text, locale: original.originalLanguage)
        let normalizedRefined = SpeechVocabularyTerm.normalizedKey(refinedText, locale: candidate.languageCode ?? original.originalLanguage)
        let originalLanguage = SupportedLanguage.language(for: original.originalLanguage)
        let candidateLanguage = SupportedLanguage.language(for: candidate.languageCode)
        let isLanguageRepair = candidate.source == .autoLanguage &&
            candidateLanguage != nil &&
            candidateLanguage != originalLanguage &&
            (original.languageConfidence ?? 0) < 0.70

        guard normalizedOriginal != normalizedRefined || isLanguageRepair else {
            return (false, "same_text", 0)
        }
        guard normalizedRefined.count >= 3 else {
            return (false, "too_short", 0)
        }
        let ratio = Double(normalizedRefined.count) / Double(max(normalizedOriginal.count, 1))
        guard ratio >= 0.45 && ratio <= 2.35 else {
            return (false, "length_ratio_guard", 0)
        }
        guard !looksLikeHallucination(normalizedRefined) else {
            return (false, "hallucination_guard", 0)
        }

        let originalConfidence = original.engineConfidence ?? original.confidence
        let vocabularyDelta = vocabularyRecall(text: refinedText, context: context, locale: candidate.languageCode ?? original.originalLanguage) -
            vocabularyRecall(text: original.text, context: context, locale: original.originalLanguage)
        if vocabularyDelta > 0.001 && candidate.confidence >= max(0.42, originalConfidence - 0.18) {
            return (true, "vocabulary_recall_improved", 30 + vocabularyDelta * 10 + candidate.confidence)
        }
        if candidate.confidence >= max(0.58, originalConfidence + 0.06) {
            return (true, "confidence_improved", 20 + candidate.confidence)
        }
        if isLanguageRepair && candidate.confidence >= max(0.50, originalConfidence - 0.05) {
            return (true, "spoken_language_repair", 15 + candidate.confidence)
        }
        if originalConfidence < 0.50 && candidate.confidence >= 0.50 {
            return (true, "low_confidence_repair", 10 + candidate.confidence)
        }
        return (false, "no_quality_gain", 0)
    }

    static func languageConfidence(
        candidate: LocalASRRefinementCandidate?,
        resultLanguageCode: String?,
        refinedConfidence: Double,
        original: TranscriptSegment
    ) -> Double {
        let candidateConfidence = min(max(candidate?.confidence ?? refinedConfidence, 0), 1)
        guard let refinedLanguage = SupportedLanguage.language(for: resultLanguageCode) else {
            return candidateConfidence
        }
        let originalLanguage = SupportedLanguage.language(for: original.originalLanguage)
        if originalLanguage == nil || originalLanguage == refinedLanguage {
            return max(original.languageConfidence ?? 0, candidateConfidence)
        }
        switch candidate?.source {
        case .autoLanguage:
            return max(candidateConfidence, 0.72)
        case .forcedLanguage, nil:
            return max(candidateConfidence, 0.60)
        }
    }

    static func looksLikeMixedLanguageOrTechnicalIsland(_ text: String) -> Bool {
        let tokens = text.components(separatedBy: CharacterSet.whitespacesAndNewlines).filter { !$0.isEmpty }
        guard tokens.count >= 3 else { return false }
        let technical = tokens.filter { token in
            token.contains { $0.isNumber } ||
                token.contains(where: { "_/-#.".contains($0) }) ||
                token.dropFirst().contains { $0.isUppercase } ||
                token.allSatisfy { !$0.isLetter || $0.isUppercase }
        }
        let asciiTokens = tokens.filter { $0.unicodeScalars.allSatisfy(\.isASCII) }
        return Double(technical.count) / Double(tokens.count) >= 0.28 ||
            (asciiTokens.count > 0 && asciiTokens.count < tokens.count)
    }

    private static func vocabularyRecall(text: String, context: SpeechRecognitionContext?, locale: String?) -> Double {
        guard let context else { return 1 }
        return TranscriptionBenchmarkSuite.vocabularyRecognitionRate(
            terms: context.activeTermsForLanguageModel.map(\.text),
            hypothesis: text,
            locale: locale
        )
    }

    private static func looksLikeHallucination(_ text: String) -> Bool {
        let tokens = text.split(separator: " ").map(String.init)
        guard tokens.count >= 8 else { return false }
        return Double(Set(tokens).count) / Double(tokens.count) < 0.25
    }
}

private extension Array where Element == TranscriptAlternative {
    func uniquedByText() -> [TranscriptAlternative] {
        var seen = Set<String>()
        return filter { alternative in
            let key = SpeechVocabularyTerm.normalizedKey(alternative.text, locale: alternative.languageCode)
            return !key.isEmpty && seen.insert(key).inserted
        }
    }
}
