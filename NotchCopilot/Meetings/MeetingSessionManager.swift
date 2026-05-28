import AVFoundation
import Foundation
import UserNotifications

private struct TranslationJobKey: Hashable {
    var segmentId: UUID
    var text: String
    var sourceLanguage: SupportedLanguage
    var targetLanguage: SupportedLanguage
    var phase: TranslationPhase
    var coverageRevision: Int
}

struct SpeechContextRanker: Sendable, Hashable {
    func rank(_ terms: [String], limit: Int = 100) -> [String] {
        rank(
            terms.map { SpeechContextTerm(text: $0, locale: nil, category: .custom, weight: 1, pronunciationXSAMPA: nil, source: "legacy") },
            limit: limit,
            locale: nil
        )
    }

    func rank(_ terms: [SpeechContextTerm], limit: Int = 100, locale: String? = nil) -> [String] {
        var scored: [(term: String, score: Double)] = []
        var seen = Set<String>()
        for contextTerm in terms {
            if let locale, let termLocale = contextTerm.locale,
               SupportedLanguage.normalizedCode(locale) != SupportedLanguage.normalizedCode(termLocale) {
                continue
            }
            let rawTerm = contextTerm.text
            let normalized = rawTerm
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "_", with: " ")
                .split(separator: " ")
                .joined(separator: " ")
            guard !normalized.isEmpty else { continue }
            let words = normalized.split(separator: " ").count
            guard words <= 4, normalized.count <= 42 else { continue }
            let key = normalized.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seen.insert(key).inserted else { continue }
            let compactness = words <= 2 ? 3.0 : 1.0
            let categoryBoost: Double
            switch contextTerm.category {
            case .person, .product, .company, .acronym:
                categoryBoost = 0.7
            case .technicalTerm, .place:
                categoryBoost = 0.45
            case .shortPhrase:
                categoryBoost = 0.25
            case .custom:
                categoryBoost = 0.35
            }
            let score = compactness + (normalized == rawTerm ? 0.35 : 0) + categoryBoost + contextTerm.weight
            scored.append((normalized, score))
        }
        return scored
            .sorted {
                if $0.score == $1.score { return $0.term.localizedCaseInsensitiveCompare($1.term) == .orderedAscending }
                return $0.score > $1.score
            }
            .prefix(max(0, limit))
            .map(\.term)
    }
}

struct MeetingTranscriptLedger: Sendable, Hashable {
    enum Decision: Sendable, Equatable {
        case ignore
        case append(TranscriptSegment)
        case replace(index: Int, segment: TranscriptSegment, tail: TranscriptSegment?)
    }

    func decision(for incoming: TranscriptSegment, in segments: [TranscriptSegment]) -> Decision {
        if let idIndex = segments.firstIndex(where: { $0.id == incoming.id && $0.audioSource == incoming.audioSource }) {
            let existing = segments[idIndex]
            if shouldAppendDespiteSameID(existing: existing, incoming: incoming) {
                return .append(freshSegmentIDIfNeeded(incoming, in: segments))
            }
            return merge(existing: existing, incoming: incoming, at: idIndex)
        }

        if let overlapIndex = segments.indices.reversed().first(where: { isCompatible(existing: segments[$0], incoming: incoming) }) {
            return merge(existing: segments[overlapIndex], incoming: incoming, at: overlapIndex)
        }

        return .append(freshSegmentIDIfNeeded(incoming, in: segments))
    }

    private func merge(existing: TranscriptSegment, incoming: TranscriptSegment, at index: Int) -> Decision {
        if existing.isFinal, !incoming.isFinal {
            if let tail = tailSegment(from: incoming, after: existing, phase: .draft) {
                return .append(tail)
            }
            return .ignore
        }

        if incoming.isFinal, !existing.isFinal {
            if isMeaningfullyShorter(incoming.text, than: existing.text) {
                if let tail = tailSegment(from: existing, after: incoming, phase: .draft) {
                    var committed = incoming
                    committed.id = existing.id
                    committed.revisionNumber = max(existing.revisionNumber, incoming.revisionNumber) + 1
                    return .replace(index: index, segment: committed, tail: tail)
                }
                return .ignore
            }
        }

        if !incoming.isFinal,
           !existing.isFinal,
           isMeaningfullyShorter(incoming.text, than: existing.text),
           normalized(existing.text).hasPrefix(normalized(incoming.text)) {
            return .ignore
        }

        var replacement = incoming
        replacement.id = existing.id
        replacement.revisionNumber = max(existing.revisionNumber, incoming.revisionNumber) + (replacement.text == existing.text ? 0 : 1)
        replacement = preservingTranslationIfEquivalent(existing: existing, replacement: replacement)
        return .replace(index: index, segment: replacement, tail: nil)
    }

    private func isCompatible(existing: TranscriptSegment, incoming: TranscriptSegment) -> Bool {
        guard existing.audioSource == incoming.audioSource else { return false }
        if rangeOverlap(existing.sourceFrameRange, incoming.sourceFrameRange) >= 0.20 {
            return true
        }
        if temporalOverlap(existing: existing, incoming: incoming) >= 0.35 {
            return true
        }
        return false
    }

    private func shouldAppendDespiteSameID(existing: TranscriptSegment, incoming: TranscriptSegment) -> Bool {
        guard existing.isFinal else { return false }
        if let existingRange = existing.sourceFrameRange, let incomingRange = incoming.sourceFrameRange {
            return incomingRange.start >= existingRange.end
        }
        return incoming.startTime >= existing.endTime + 0.05
    }

    private func isMeaningfullyShorter(_ candidate: String, than reference: String) -> Bool {
        normalized(reference).count > normalized(candidate).count + 8
    }

    private func tailSegment(from longer: TranscriptSegment, after prefix: TranscriptSegment, phase: TranscriptionPhase) -> TranscriptSegment? {
        guard let tailText = suffixText(in: longer.text, after: prefix.text), !tailText.isEmpty else { return nil }
        var tail = longer
        tail.id = UUID()
        tail.text = tailText
        tail.isFinal = phase == .final
        tail.transcriptionPhase = phase
        tail.finalizedBy = phase == .final ? longer.finalizedBy : nil
        tail.startTime = max(prefix.endTime, longer.startTime)
        tail.endTime = max(tail.startTime, longer.endTime)
        if let longerRange = longer.sourceFrameRange {
            let start = prefix.sourceFrameRange?.end ?? longerRange.start
            tail.sourceFrameRange = AudioSourceFrameRange(start: min(max(start, longerRange.start), longerRange.end), end: longerRange.end)
        }
        tail.wordTimestamps = longer.wordTimestamps.filter { $0.startTime >= tail.startTime }
        tail.alternatives = []
        tail.revisionNumber = longer.revisionNumber + 1
        tail.draftTranslatedText = nil
        tail.translatedText = nil
        tail.translationState = .none
        tail.translationPhase = nil
        tail.translationConfidence = nil
        tail.preservedTerms = []
        return tail
    }

    private func suffixText(in longer: String, after prefix: String) -> String? {
        let trimmedLonger = longer.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLonger.isEmpty, !trimmedPrefix.isEmpty else { return nil }
        guard trimmedLonger.range(of: trimmedPrefix, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil else {
            return nil
        }
        let suffixStart = trimmedLonger.index(trimmedLonger.startIndex, offsetBy: min(trimmedPrefix.count, trimmedLonger.count))
        return String(trimmedLonger[suffixStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func preservingTranslationIfEquivalent(existing: TranscriptSegment, replacement: TranscriptSegment) -> TranscriptSegment {
        guard normalized(existing.text) == normalized(replacement.text) else { return replacement }
        var replacement = replacement
        replacement.draftTranslatedText = existing.draftTranslatedText
        replacement.translatedText = existing.translatedText
        replacement.translationState = existing.translationState
        replacement.translationPhase = existing.translationPhase
        replacement.translationConfidence = existing.translationConfidence
        replacement.preservedTerms = existing.preservedTerms
        return replacement
    }

    private func freshSegmentIDIfNeeded(_ incoming: TranscriptSegment, in segments: [TranscriptSegment]) -> TranscriptSegment {
        guard segments.contains(where: { $0.id == incoming.id }) else { return incoming }
        var segment = incoming
        segment.id = UUID()
        return segment
    }

    private func normalized(_ text: String) -> String {
        text
            .lowercased()
            .folding(options: [.diacriticInsensitive], locale: .current)
            .split(separator: " ")
            .joined(separator: " ")
    }

    private func temporalOverlap(existing: TranscriptSegment, incoming: TranscriptSegment) -> Double {
        let overlapStart = max(existing.startTime, incoming.startTime)
        let overlapEnd = min(existing.endTime, incoming.endTime)
        let overlap = max(0, overlapEnd - overlapStart)
        let shortest = max(0.001, min(existing.endTime - existing.startTime, incoming.endTime - incoming.startTime))
        return overlap / shortest
    }

    private func rangeOverlap(_ lhs: AudioSourceFrameRange?, _ rhs: AudioSourceFrameRange?) -> Double {
        guard let lhs, let rhs else { return 0 }
        let overlapStart = max(lhs.start, rhs.start)
        let overlapEnd = min(lhs.end, rhs.end)
        let overlap = max(0, overlapEnd - overlapStart)
        let shortest = max(1, min(lhs.end - lhs.start, rhs.end - rhs.start))
        return Double(overlap) / Double(shortest)
    }

    private func mergedRange(_ lhs: AudioSourceFrameRange?, _ rhs: AudioSourceFrameRange?) -> AudioSourceFrameRange? {
        switch (lhs, rhs) {
        case let (.some(lhs), .some(rhs)):
            return AudioSourceFrameRange(start: min(lhs.start, rhs.start), end: max(lhs.end, rhs.end))
        case let (.some(range), .none), let (.none, .some(range)):
            return range
        case (.none, .none):
            return nil
        }
    }
}

@MainActor
final class MeetingSessionManager {
    private unowned let appState: AppState
    private let repository: MeetingRepository
    private let fileStorage: FileStorageService
    private let settingsRepository: SettingsRepository
    private let providerRouter: ProviderRouter
    private let knowledgeStore: LocalKnowledgeStore
    private let localDataCryptor: LocalDataCryptor
    private let microphoneCaptureService: AppleMicrophoneCaptureService
    private let systemAudioCaptureService: AppleSystemAudioCaptureService
    private let audioRecorder: AudioRecorderService
    private let languageDetector = AppleLanguageDetectionService()
    private let audioAnalyzer = AppleAccelerateAudioAnalyzer()
    private var languageContinuityResolver = LanguageContinuityResolver()
    private var realtimeTranslationCoordinator = RealtimeTranslationCoordinator()
    private let translationCompletenessPass = TranslationCompletenessPass()
    private let semanticTranslationRefiner = SemanticTranslationRefiner()
    private var speechQualityMonitors: [TranscriptAudioSource: SpeechAudioQualityMonitor] = [:]
    private let questionAudioLogMelBuffer = QuestionAudioLogMelRingBuffer()
    private let transcriptLedger = MeetingTranscriptLedger()

    private var activeTranscriptionService: (any TranscriptionService)?
    private var realtimeQuestionEngine: RealtimeQuestionAnsweringEngine?
    private var questionEventTask: Task<Void, Never>?
    private var segmentTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var waveformTask: Task<Void, Never>?
    private var translationTasks: [TranslationJobKey: Task<Void, Never>] = [:]
    private var audioDrainTasks: [Task<Void, Never>] = []
    private var openAIPrewarmTask: Task<Void, Never>?
    private var summaryReadyTask: Task<Void, Never>?
    private var lastAudioStatusUpdate = Date.distantPast
    private var activeQuestionRecords: [UUID: QuestionAnswerRecord] = [:]

    init(
        appState: AppState,
        repository: MeetingRepository,
        fileStorage: FileStorageService,
        settingsRepository: SettingsRepository,
        providerRouter: ProviderRouter,
        knowledgeStore: LocalKnowledgeStore,
        localDataCryptor: LocalDataCryptor = .defaultOrCrash(),
        microphoneCaptureService: AppleMicrophoneCaptureService = AppleMicrophoneCaptureService(),
        systemAudioCaptureService: AppleSystemAudioCaptureService = AppleSystemAudioCaptureService(),
        audioRecorder: AudioRecorderService = AudioRecorderService()
    ) {
        self.appState = appState
        self.repository = repository
        self.fileStorage = fileStorage
        self.settingsRepository = settingsRepository
        self.providerRouter = providerRouter
        self.knowledgeStore = knowledgeStore
        self.localDataCryptor = localDataCryptor
        self.microphoneCaptureService = microphoneCaptureService
        self.systemAudioCaptureService = systemAudioCaptureService
        self.audioRecorder = audioRecorder
    }

    func reloadHistory() {
        do {
            appState.history = try repository.fetchMeetings()
            reloadQuestionAnswerHistory()
        } catch {
            appState.statusMessage = "Could not load history"
            AppLog.persistence.error("History load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func reloadQuestionAnswerHistory() {
        appState.questionAnswerRecords = (try? repository.questionAnswerRecords()) ?? []
        appState.copilotInteractions = (try? repository.copilotInteractions()) ?? []
        appState.copilotReminders = (try? repository.copilotReminders()) ?? []
    }

    private func configureRealtimeQuestionEngine(for session: MeetingSession) {
        questionEventTask?.cancel()
        realtimeQuestionEngine?.reset()

        let engine = RealtimeQuestionAnsweringEngine(providerRouter: providerRouter, preferences: appState.preferences, knowledgeStore: knowledgeStore)
        realtimeQuestionEngine = engine
        activeQuestionRecords = [:]
        openAIPrewarmTask?.cancel()
        openAIPrewarmTask = Task { [providerRouter, preferences = appState.preferences] in
            await providerRouter.prewarmRealtimeQuestionAnswering(preferences: preferences)
        }

        questionEventTask = Task { [weak self, eventBus = engine.eventBus] in
            for await event in eventBus.events {
                self?.handleRealtimeQuestionEvent(event, meetingId: session.id)
            }
        }
    }

    private func handleRealtimeQuestionEvent(_ event: RealtimeQuestionEvent, meetingId: UUID) {
        switch event {
        case let .questionDetected(candidate, classification):
            persistQuestion(candidate, classification: classification, answer: nil, decision: classification.responseNeeded ? "detected" : "no_response_needed")
            guard shouldSurfaceQuestion(classification) else { return }
            let shouldKeepTranscriptVisible = appState.shouldPreserveTranscriptForIncomingQuestion
            let shouldSelect = appState.selectedQuestionId == nil || appState.questionAnswerQueue.isEmpty || classification.priority == .urgent
            appState.upsertQuestionInQueue(
                candidate: candidate,
                classification: classification,
                stage: .classifying,
                decision: "detected",
                select: shouldSelect
            )
            appState.showQuestionAnswerPanel(mode: shouldKeepTranscriptVisible ? .transcript : .answer)
            appState.statusMessage = shouldSelect
                ? (classification.priority == .urgent ? "You may need to answer" : "Notchly detected intent")
                : "Question queued"

        case let .answerGenerating(questionId, stage):
            appState.updateQueuedQuestionStage(questionId: questionId, stage: stage)
            guard appState.selectedQuestionId == questionId else { return }
            if stage.isInProgress {
                appState.showQuestionAnswerPanel(mode: appState.questionLoadingPresentationMode)
                appState.statusMessage = stage.displayName
            } else if stage == .failed {
                appState.streamingAnswerText = ""
                appState.suggestedAnswer = nil
                appState.showQuestionAnswerPanel(mode: .answer)
                appState.statusMessage = "Could not generate a local answer"
            } else if stage == .cancelled {
                appState.streamingAnswerText = ""
                appState.showQuestionAnswerPanel(mode: .answer)
                appState.statusMessage = "Question cancelled"
            }

        case let .answerFailed(questionId, message):
            appState.updateQueuedQuestionStage(questionId: questionId, stage: .failed)
            guard appState.selectedQuestionId == questionId else { return }
            appState.streamingAnswerText = ""
            appState.suggestedAnswer = nil
            appState.showQuestionAnswerPanel(mode: .answer)
            appState.statusMessage = message

        case let .partialAnswerUpdated(questionId, text):
            appState.updateQueuedQuestionStreamingText(questionId: questionId, text: text)
            guard appState.selectedQuestionId == questionId else { return }
            appState.showQuestionAnswerPanel(mode: appState.questionLoadingPresentationMode)
            appState.statusMessage = "Drafting live"

        case let .suggestedAnswerReady(candidate, answer):
            appState.updateQueuedQuestionAnswer(candidate: candidate, answer: answer)
            if appState.selectedQuestionId == candidate.id {
                appState.showQuestionAnswerPanel(mode: .answer)
                appState.statusMessage = "Suggested answer"
            } else {
                appState.statusMessage = "Answer queued"
            }
            if let classification = candidate.classification ?? appState.questionClassification {
                persistQuestion(candidate, classification: classification, answer: answer, decision: "suggested_answer_ready")
            }

        case let .questionIgnored(candidate, reason):
            if let classification = candidate.classification {
                persistQuestion(candidate, classification: classification, answer: nil, decision: "ignored: \(reason)")
            }

        case let .questionMerged(source, target):
            appState.mergeQuestionInQueue(source: source, target: target)

        case let .questionCancelled(questionId, reason):
            appState.updateQueuedQuestionStage(questionId: questionId, stage: .cancelled)
            guard appState.selectedQuestionId == questionId else { return }
            appState.streamingAnswerText = ""
            appState.statusMessage = reason
        }
    }

    private func shouldSurfaceQuestion(_ classification: QuestionClassification) -> Bool {
        classification.responseNeeded && classification.priority != .low && !classification.rhetorical && classification.complete
    }

    private func persistQuestion(
        _ candidate: QuestionCandidate,
        classification: QuestionClassification,
        answer: SuggestedAnswer?,
        decision: String
    ) {
        var record = activeQuestionRecords[candidate.id] ?? QuestionAnswerRecord(
            meetingId: candidate.meetingId,
            question: candidate,
            classification: classification,
            answer: nil,
            contextSummary: PrivacyGuard().redact(candidate.rawText),
            sources: [],
            decision: decision
        )
        record.question = candidate
        record.classification = classification
        record.answer = answer ?? record.answer
        record.sources = answer?.usedSources ?? record.sources
        record.decision = decision
        record.updatedAt = Date()
        activeQuestionRecords[candidate.id] = record
        try? repository.saveQuestionAnswerRecord(record)
        reloadQuestionAnswerHistory()
    }

    func hydrateActiveTranscriptForPresentation() {
        guard var currentMeeting = appState.currentMeeting else { return }
        do {
            guard let storedMeeting = try repository.fetchMeetings().first(where: { $0.id == currentMeeting.id }) else { return }
            let mergedSegments = mergedTranscriptSegments(currentMeeting.transcriptSegments, storedMeeting.transcriptSegments)
            guard mergedSegments != currentMeeting.transcriptSegments else { return }
            currentMeeting.transcriptSegments = mergedSegments
            currentMeeting.summary = currentMeeting.summary ?? storedMeeting.summary
            appState.currentMeeting = currentMeeting
        } catch {
            AppLog.persistence.error("Active transcript hydrate failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func startManualMeeting() async {
        await startMeeting(title: "Manual meeting", source: .manual)
    }

    func startDetectedMeeting(_ meeting: MeetingSession) async {
        await startMeeting(title: meeting.title, source: meeting.source, seed: meeting)
    }

    private func startMeeting(title: String, source: MeetingSource, seed: MeetingSession? = nil) async {
        summaryReadyTask?.cancel()
        await stopRunningServices(keepMeeting: false)

        var session = seed ?? MeetingSession(title: title, source: source, status: .listening, meetingType: appState.preferences.defaultMeetingType)
        session.status = .listening
        session.startedAt = Date()
        session.primaryLanguage = SupportedLanguage.normalizedCode(appState.preferences.defaultLanguage)
        if appState.preferences.saveAudioRecordings {
            let url = fileStorage.recordingURL(for: session.id)
            do {
                try audioRecorder.startRecording(to: url)
                session.audioFileURL = url
            } catch {
                appState.statusMessage = "Recording unavailable"
            }
        }
        appState.currentMeeting = session
        appState.speechAudioQualityBySource = [:]
        speechQualityMonitors = [:]
        questionAudioLogMelBuffer.reset()
        appState.selectedMeeting = nil
        appState.elapsed = 0
        appState.resetQuestionAnswerFlow()
        appState.islandMode = .listening
        appState.statusMessage = "Listening"
        appState.meetingTranscriptionStatus = .listening
        appState.activeCaptureLabel = "Preparing"
        configureRealtimeQuestionEngine(for: session)

        startTimer(startedAt: session.startedAt)
        let pipelineStarted = await startRealtimePipeline(for: session)
        if !pipelineStarted {
            session.status = .failed
            appState.currentMeeting = session
            appState.islandMode = .idle
            timerTask?.cancel()
            audioRecorder.stopRecording()
        }
        try? repository.save(session)
        reloadHistory()
    }

    func pauseOrResume() async {
        guard var meeting = appState.currentMeeting else { return }
        if meeting.status == .paused {
            meeting.status = .listening
            appState.statusMessage = "Listening"
            appState.meetingTranscriptionStatus = .listening
            appState.currentMeeting = meeting
            appState.islandMode = .listening
            configureRealtimeQuestionEngine(for: meeting)
            startTimer(startedAt: meeting.startedAt)
            await startRealtimePipeline(for: meeting)
        } else if meeting.status == .listening {
            await stopRunningServices(keepMeeting: true)
            meeting.status = .paused
            appState.statusMessage = "Paused"
            appState.meetingTranscriptionStatus = .idle
            appState.currentMeeting = meeting
        }
        try? repository.save(meeting)
    }

    func draftAnswer(for question: String, refinementStyle: AnswerRefinementStyle? = nil) async {
        guard let meeting = appState.currentMeeting else { return }
        appState.detectedQuestion = question
        appState.streamingAnswerText = ""
        appState.islandMode = .thinking
        appState.answerStage = .drafting
        appState.statusMessage = refinementStyle?.statusText ?? "Thinking..."
        let ragContext = (try? knowledgeStore.buildContext(for: question)) ?? ""
        let provider = providerRouter.aiProvider(preferences: appState.preferences)
        let engine = SuggestedAnswerEngine(provider: provider)
        let providerQuestion = refinedQuestionPrompt(for: question, style: refinementStyle)
        do {
            let generated = try await engine.draftAnswer(for: providerQuestion, meeting: meeting, preferences: appState.preferences, ragContext: ragContext)
            let answer = suggestedAnswer(from: generated, questionText: question, questionId: appState.activeQuestion?.id ?? UUID(), ragContext: ragContext)
            appState.suggestedAnswer = answer
            appState.streamingAnswerText = appState.suggestedAnswer?.shortAnswer ?? ""
            if let activeQuestion = appState.activeQuestion {
                appState.updateQueuedQuestionAnswer(candidate: activeQuestion, answer: answer)
            }
            appState.showQuestionAnswerPanel(mode: .answer)
            appState.answerStage = .ready
            appState.statusMessage = "Suggested answer"
            if let refinementStyle {
                recordAnswerFeedback(.regenerated, note: refinementStyle.rawValue)
            }
        } catch {
            appState.suggestedAnswer = nil
            appState.streamingAnswerText = ""
            appState.answerStage = .failed
            appState.islandMode = appState.activeQuestion == nil ? .listening : .questionDetected
            appState.statusMessage = providerUnavailableMessage(error)
        }
    }

    func replaceActiveSuggestedAnswer(_ answer: SuggestedAnswer, feedbackKind: QuestionAnswerFeedbackKind, note: String? = nil) {
        guard let questionId = appState.activeQuestion?.id,
              var record = activeQuestionRecords[questionId] else { return }
        record.answer = answer
        record.sources = answer.usedSources
        record.decision = feedbackKind == .edited ? "edited_answer" : record.decision
        record.feedbackEvents.append(QuestionAnswerFeedbackEvent(kind: feedbackKind, note: note))
        record.updatedAt = Date()
        activeQuestionRecords[questionId] = record
        try? repository.saveQuestionAnswerRecord(record)
        reloadQuestionAnswerHistory()
    }

    func dismissActiveQuestion() {
        if let questionId = appState.activeQuestion?.id {
            realtimeQuestionEngine?.dismiss(questionId: questionId)
            if var record = activeQuestionRecords[questionId] {
                record.feedbackEvents.append(QuestionAnswerFeedbackEvent(kind: .dismissed))
                record.updatedAt = Date()
                activeQuestionRecords[questionId] = record
                try? repository.saveQuestionAnswerRecord(record)
                appState.preferences.questionAnsweringProfile.record(feedback: .dismissed, rawText: record.question.rawText)
                appState.preferences.normalizeForPersistence()
                settingsRepository.save(appState.preferences)
            }
        }
        _ = appState.removeSelectedQuestionFromQueue()
        if appState.selectedQuestionId == nil {
            appState.islandMode = appState.currentMeeting?.status == .ended ? .summaryReady : .listening
        }
    }

    func recordAnswerFeedback(_ kind: QuestionAnswerFeedbackKind, note: String? = nil) {
        guard let questionId = appState.activeQuestion?.id,
              var record = activeQuestionRecords[questionId] else { return }
        record.feedbackEvents.append(QuestionAnswerFeedbackEvent(kind: kind, note: note))
        record.updatedAt = Date()
        activeQuestionRecords[questionId] = record
        try? repository.saveQuestionAnswerRecord(record)
        appState.preferences.questionAnsweringProfile.record(feedback: kind, rawText: record.question.rawText)
        appState.preferences.normalizeForPersistence()
        settingsRepository.save(appState.preferences)
        reloadQuestionAnswerHistory()
    }

    private func refinedQuestionPrompt(for question: String, style: AnswerRefinementStyle?) -> String {
        guard let style else { return question }
        let currentAnswer = appState.suggestedAnswer?.answerText ?? appState.streamingAnswerText
        guard !currentAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "\(question)\n\nPreference: \(style.promptInstruction)"
        }
        return """
        \(question)

        Current suggested answer:
        \(currentAnswer)

        Preference:
        \(style.promptInstruction)
        """
    }

    private func suggestedAnswer(from generated: GeneratedAnswer, questionText: String, questionId: UUID, ragContext: String) -> SuggestedAnswer {
        SuggestedAnswer(
            questionId: questionId,
            answerText: generated.text,
            shortAnswer: generated.text,
            confidence: 0.72,
            riskLevel: .safe,
            usedSources: ragContext.isEmpty ? [] : [AnswerSource(type: .rag, title: "Local knowledge", snippet: ragContext, reference: nil)],
            assumptions: [],
            caveats: [],
            latencyMs: 0,
            expandedAnswer: generated.text,
            suggestedTone: .technical,
            language: appState.currentMeeting?.primaryLanguage,
            provider: generated.provider,
            usedCloud: generated.usedCloud,
            usedRAG: generated.usedRAG,
            richAnswer: RichAnswerFallbackBuilder.payload(
                text: generated.text,
                format: .paragraph,
                sources: ragContext.isEmpty ? [] : [AnswerSource(type: .rag, title: "Local knowledge", snippet: ragContext, reference: nil)],
                confidence: 0.72,
                riskLevel: .safe,
                tone: .technical
            )
        )
    }

    private func providerUnavailableMessage(_ error: Error) -> String {
        if let failure = error as? CopilotFailure {
            return failure.userMessage
        }
        if let aiError = error as? AIProviderError,
           let description = aiError.errorDescription {
            return description
        }
        return "Connect a real AI provider to generate answers."
    }

    @discardableResult
    func summarizeCurrentMeeting(markEnded: Bool) async -> MeetingSummary? {
        guard var meeting = appState.currentMeeting else { return nil }
        let provider = providerRouter.aiProvider(preferences: appState.preferences)
        let engine = SummaryEngine(provider: provider)
        do {
            let summary = try await engine.summarize(meeting)
            meeting.summary = summary
            if markEnded {
                meeting.status = .ended
                meeting.endedAt = Date()
            }
            appState.currentMeeting = meeting
            try? repository.save(meeting)
            reloadHistory()
            return summary
        } catch {
            appState.statusMessage = providerUnavailableMessage(error)
            if markEnded {
                meeting.status = .ended
                meeting.endedAt = Date()
                appState.currentMeeting = meeting
                try? repository.save(meeting)
                reloadHistory()
            }
            return nil
        }
    }

    func stopMeeting(autoEnded: Bool = false) async {
        guard var meeting = appState.currentMeeting else { return }
        let shouldKeepPanelExpanded = appState.isPanelExpanded
        meeting.status = .summarizing
        meeting.wasAutoEnded = autoEnded
        appState.currentMeeting = meeting
        appState.islandMode = .summarizing
        appState.statusMessage = autoEnded ? "Auto-ending..." : "Summarizing..."
        await stopRunningServices(keepMeeting: true)
        audioRecorder.stopRecording()
        appState.isPanelExpanded = shouldKeepPanelExpanded
        await runTranslationCompletenessPassBeforeSummary()
        _ = await summarizeCurrentMeeting(markEnded: true)
        if let meeting = appState.currentMeeting {
            try? fileStorage.writeTranscript(meeting)
        }
        showTransientSummaryReady(keepExpanded: shouldKeepPanelExpanded)
    }

    func deleteMeeting(_ meeting: MeetingSession) {
        do {
            try repository.delete(meeting)
            reloadHistory()
            if appState.currentMeeting?.id == meeting.id {
                appState.currentMeeting = nil
                appState.islandMode = .idle
            }
        } catch {
            appState.statusMessage = "Delete failed"
        }
    }

    func deleteAllData() {
        do {
            try repository.deleteAll()
            try fileStorage.deleteAllLocalData()
            try localDataCryptor.resetStoredKey()
            appState.history = []
            appState.questionAnswerRecords = []
            appState.copilotInteractions = []
            appState.copilotReminders = []
            appState.currentMeeting = nil
            appState.selectedMeeting = nil
            appState.islandMode = .idle
            appState.statusMessage = "All local data deleted"
        } catch {
            appState.statusMessage = "Delete failed"
        }
    }

    private func observeSegments(from service: any TranscriptionService) {
        segmentTask?.cancel()
        segmentTask = Task { [weak self] in
            for await segment in service.segments {
                await self?.append(segment)
            }
        }
    }

    private func mergedTranscriptSegments(_ current: [TranscriptSegment], _ stored: [TranscriptSegment]) -> [TranscriptSegment] {
        var segmentsByID = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
        for segment in current {
            segmentsByID[segment.id] = segment
        }
        return segmentsByID.values.sorted {
            if $0.startTime == $1.startTime {
                return $0.createdAt < $1.createdAt
            }
            return $0.startTime < $1.startTime
        }
    }

    private func append(_ segment: TranscriptSegment) async {
        guard var meeting = appState.currentMeeting else { return }
        var segment = segment
        let decision = transcriptLedger.decision(for: segment, in: meeting.transcriptSegments)
        let existingIndex: Int?
        let existingSegment: TranscriptSegment?
        let pendingTail: TranscriptSegment?
        switch decision {
        case .ignore:
            return
        case .append(let appendSegment):
            segment = appendSegment
            existingIndex = nil
            existingSegment = nil
            pendingTail = nil
        case .replace(let index, let replacement, let tail):
            segment = replacement
            existingIndex = index
            existingSegment = meeting.transcriptSegments[index]
            pendingTail = tail
        }
        let languageResolution = resolvedLanguage(for: segment, existingSegment: existingSegment, meeting: meeting)
        segment.originalLanguage = languageResolution.language.rawValue
        if meeting.primaryLanguage == nil || (segment.isFinal && languageResolution.isTextDetected) {
            meeting.primaryLanguage = segment.originalLanguage
        }

        let translationPreparation = realtimeTranslationCoordinator.prepare(
            segment: segment,
            existingSegment: existingSegment,
            plan: translationPlan(for: segment),
            preferences: appState.preferences
        )
        segment = translationPreparation.segment

        if let index = existingIndex {
            meeting.transcriptSegments[index] = segment
        } else {
            meeting.transcriptSegments.append(segment)
        }
        meeting.transcriptSegments.sort {
            if $0.startTime == $1.startTime {
                return $0.createdAt < $1.createdAt
            }
            return $0.startTime < $1.startTime
        }
        appState.currentMeeting = meeting

        if appState.preferences.realtimeSuggestionsEnabled {
            await realtimeQuestionEngine?.ingest(
                segment: segment,
                meeting: meeting,
                preferences: appState.preferences,
                multimodalSignal: questionMultimodalSignal(for: segment)
            )
        }

        if appState.islandMode != .questionDetected && appState.islandMode != .suggestedAnswer && appState.islandMode != .thinking {
            appState.islandMode = .listening
        }

        try? repository.save(meeting)
        reloadHistory()

        scheduleTranslation(translationPreparation.job, segment: segment)
        if let pendingTail {
            await append(pendingTail)
        }
    }

    private func questionMultimodalSignal(for segment: TranscriptSegment) -> QuestionMultimodalSignal {
        let source = segment.audioSource == .unknown ? TranscriptAudioSource.mixed : segment.audioSource
        let quality = appState.speechAudioQualityBySource[source] ?? appState.speechAudioQualityBySource[segment.audioSource]
        var signal = QuestionMultimodalSignal(segment: segment, quality: quality)
        signal.audioLogMel = questionAudioLogMelBuffer.feature(
            for: segment,
            targetFrames: QuestionAudioLogMelFeature.trainedModelFrameCount
        )
        return signal
    }

    private func resolvedLanguage(
        for segment: TranscriptSegment,
        existingSegment: TranscriptSegment?,
        meeting: MeetingSession
    ) -> (language: SupportedLanguage, isTextDetected: Bool) {
        let resolution = languageContinuityResolver.resolve(
            text: segment.text,
            audioSource: segment.audioSource,
            incomingLanguage: segment.originalLanguage,
            existingLanguage: existingSegment?.originalLanguage,
            meetingLanguage: meeting.primaryLanguage,
            defaultLanguage: appState.preferences.defaultLanguage,
            isFinal: segment.isFinal
        )
        return (resolution.language, resolution.isTextDetected)
    }

    private func translationResult(for job: RealtimeTranslationJob, segment: TranscriptSegment) async -> TranslationResult {
        let engine = LiveTranslationEngine { [providerRouter] preferences in
            providerRouter.cloudTranslationProvider(preferences: preferences)
        }
        let metadata = TranslationRequestMetadata(
            phase: job.phase,
            confidence: job.confidence,
            preservedTerms: job.preservedTerms,
            isSemanticRefinement: false
        )

        var segment = segment
        segment.text = job.text
        segment.originalLanguage = job.sourceLanguage.rawValue

        let draftResult = await engine.translateText(
            job.text,
            source: job.sourceLanguage,
            target: job.targetLanguage,
            segment: segment,
            preferences: appState.preferences,
            metadata: metadata
        )

        guard job.phase == .refinement,
              case let .translated(text, engineName, sourceLanguage, targetLanguage, _, confidence, preservedTerms, _) = draftResult,
              let refined = await semanticTranslationRefiner.refine(
                  segment: segment,
                  draft: text,
                  targetLanguage: job.targetLanguage,
                  preferences: appState.preferences,
                  provider: providerRouter.semanticTranslationProvider(preferences: appState.preferences)
              ),
              let validated = TranslationOutputValidator.validated(
                  refined,
                  originalText: job.text,
                  source: job.sourceLanguage,
                  target: job.targetLanguage
              )
        else {
            return draftResult
        }

        return .translated(
            text: validated,
            engine: engineName,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            phase: .final,
            confidence: max(confidence, 0.95),
            preservedTerms: preservedTerms,
            isSemanticRefinement: true
        )
    }

    func refreshTranslationsForCurrentMeeting() {
        guard let meeting = appState.currentMeeting else { return }
        for segment in meeting.transcriptSegments.suffix(24) {
            let preparation = realtimeTranslationCoordinator.prepare(
                segment: segment,
                existingSegment: segment,
                plan: translationPlan(for: segment),
                preferences: appState.preferences
            )
            scheduleTranslation(preparation.job, segment: preparation.segment)
        }
    }

    func cancelPendingTranslations() {
        translationTasks.values.forEach { $0.cancel() }
        translationTasks = [:]
    }

    private func runTranslationCompletenessPassBeforeSummary() async {
        guard appState.preferences.liveTranslationEnabled,
              let meeting = appState.currentMeeting else { return }

        let segments = translationCompletenessPass.segmentsNeedingCoverage(
            in: meeting,
            preferences: appState.preferences
        )

        for segment in segments {
            let preparation = realtimeTranslationCoordinator.prepare(
                segment: segment,
                existingSegment: segment,
                plan: translationPlan(for: segment),
                preferences: appState.preferences
            )
            scheduleTranslation(preparation.job, segment: preparation.segment)
        }

        await waitForPendingTranslations(maxDuration: 8)
        markTimedOutTranslationsUnavailable()
    }

    private func waitForPendingTranslations(maxDuration: TimeInterval) async {
        let deadline = Date().addingTimeInterval(maxDuration)
        while !translationTasks.isEmpty, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(80))
        }
    }

    private func markTimedOutTranslationsUnavailable() {
        guard !translationTasks.isEmpty else { return }
        translationTasks.values.forEach { $0.cancel() }
        translationTasks = [:]

        guard appState.preferences.liveTranslationEnabled,
              var meeting = appState.currentMeeting else { return }

        var didChange = false
        for index in meeting.transcriptSegments.indices {
            let segment = meeting.transcriptSegments[index]
            guard TranslationCoverageCoordinator().shouldCover(segment, preferences: appState.preferences),
                  [.pending, .drafting, .refining].contains(segment.translationState) else { continue }
            meeting.transcriptSegments[index].translationState = segment.draftTranslatedText == nil && segment.translatedText == nil
                ? .unavailable
                : .draftTranslated
            didChange = true
        }

        guard didChange else { return }
        appState.currentMeeting = meeting
        try? repository.save(meeting)
        reloadHistory()
    }

    private func scheduleTranslation(_ job: RealtimeTranslationJob?, segment: TranscriptSegment) {
        guard let job, appState.preferences.liveTranslationEnabled, !appState.isPreparingTranslationLanguages else { return }
        let key = translationJobKey(for: job)
        cancelTranslationTasks(for: segment.id, keeping: key)
        guard translationTasks[key] == nil else { return }

        translationTasks[key] = Task { [weak self, segment, job, key] in
            let delay: Duration = .milliseconds(job.delayMilliseconds)
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            let result = await self.translationResult(for: job, segment: segment)
            guard !Task.isCancelled else { return }
            self.applyTranslationResult(result, to: key)
        }
    }

    private func translationJobKey(for job: RealtimeTranslationJob) -> TranslationJobKey {
        TranslationJobKey(
            segmentId: job.segmentId,
            text: job.text,
            sourceLanguage: job.sourceLanguage,
            targetLanguage: job.targetLanguage,
            phase: job.phase,
            coverageRevision: job.coverageRevision
        )
    }

    private func cancelTranslationTasks(for segmentId: UUID, keeping currentKey: TranslationJobKey) {
        let staleKeys = translationTasks.keys.filter { $0.segmentId == segmentId && $0 != currentKey }
        for key in staleKeys {
            translationTasks[key]?.cancel()
            translationTasks[key] = nil
        }
    }

    private func translationPlan(for segment: TranscriptSegment) -> TranslationPlan? {
        let source = SupportedLanguage.language(for: segment.originalLanguage)
            ?? SupportedLanguage.language(for: appState.preferences.defaultLanguage)
        guard let source else { return nil }
        let target = translationTarget(for: source)
        guard source != target else { return nil }
        return TranslationPlan(source: source, target: target)
    }

    private func translationTarget(for source: SupportedLanguage) -> SupportedLanguage {
        if source == .englishUS || source == .portugueseBR {
            return source.pairedTranslationTarget
        }

        let configuredTarget = SupportedLanguage.language(for: appState.preferences.targetLanguage)
        guard let configuredTarget, configuredTarget != source else {
            return source.pairedTranslationTarget
        }
        return configuredTarget
    }

    private func validatedTranslation(
        _ translatedText: String,
        originalText: String,
        source: SupportedLanguage,
        target: SupportedLanguage
    ) -> String? {
        TranslationOutputValidator.validated(
            translatedText,
            originalText: originalText,
            source: source,
            target: target
        )
    }

    private func applyTranslationResult(_ result: TranslationResult, to key: TranslationJobKey) {
        translationTasks[key] = nil
        guard appState.preferences.liveTranslationEnabled,
              var meeting = appState.currentMeeting,
              let index = meeting.transcriptSegments.firstIndex(where: { $0.id == key.segmentId }) else { return }

        let currentSegment = meeting.transcriptSegments[index]
        let currentRevision = TranslationCoverageCoordinator().coverageRevision(for: currentSegment)
        guard translationResultStillMatches(currentText: currentSegment.text, key: key),
              currentSegment.originalLanguage == key.sourceLanguage.rawValue,
              currentRevision == key.coverageRevision else {
            scheduleRepairTranslationIfNeeded(for: currentSegment)
            return
        }

        switch result {
        case let .translated(text, _, sourceLanguage, targetLanguage, phase, confidence, preservedTerms, isSemanticRefinement):
            guard sourceLanguage == key.sourceLanguage,
                  targetLanguage == key.targetLanguage,
                  let validated = validatedTranslation(
                      text,
                      originalText: key.text,
                      source: key.sourceLanguage,
                      target: key.targetLanguage
                  ) else { return }

            let preservedText = realtimeTranslationCoordinator.applyPreservedTerms(
                validated,
                originalText: key.text,
                terms: preservedTerms
            )
            meeting.transcriptSegments[index].sourceLanguage = key.sourceLanguage.rawValue
            meeting.transcriptSegments[index].targetLanguage = key.targetLanguage.rawValue
            meeting.transcriptSegments[index].translatedLanguage = key.targetLanguage.rawValue
            meeting.transcriptSegments[index].translationPhase = isSemanticRefinement ? .final : phase
            meeting.transcriptSegments[index].translationConfidence = confidence
            meeting.transcriptSegments[index].preservedTerms = preservedTerms
            if phase == .draft {
                meeting.transcriptSegments[index].draftTranslatedText = preservedText
                meeting.transcriptSegments[index].translationState = .draftTranslated
            } else {
                meeting.transcriptSegments[index].translatedText = preservedText
                meeting.transcriptSegments[index].translationState = .translated
            }
        case let .preserved(text, sourceLanguage, targetLanguage, confidence, preservedTerms):
            guard sourceLanguage == key.sourceLanguage,
                  targetLanguage == key.targetLanguage else { return }
            meeting.transcriptSegments[index].sourceLanguage = key.sourceLanguage.rawValue
            meeting.transcriptSegments[index].targetLanguage = key.targetLanguage.rawValue
            meeting.transcriptSegments[index].draftTranslatedText = text
            meeting.transcriptSegments[index].translatedText = text
            meeting.transcriptSegments[index].translatedLanguage = key.targetLanguage.rawValue
            meeting.transcriptSegments[index].translationPhase = .preserved
            meeting.transcriptSegments[index].translationConfidence = confidence
            meeting.transcriptSegments[index].preservedTerms = preservedTerms
            meeting.transcriptSegments[index].translationState = .preserved
        case let .unavailable(reason):
            if meeting.transcriptSegments[index].draftTranslatedText == nil,
               meeting.transcriptSegments[index].translatedText == nil {
                meeting.transcriptSegments[index].translationState = .unavailable
            }
            if appState.currentMeeting?.status == .listening {
                appState.statusMessage = reason
            }
        case let .failed(reason):
            if meeting.transcriptSegments[index].draftTranslatedText == nil,
               meeting.transcriptSegments[index].translatedText == nil {
                meeting.transcriptSegments[index].translationState = .failed
            }
            AppLog.ai.error("Live translation failed: \(reason, privacy: .public)")
        }

        appState.currentMeeting = meeting
        try? repository.save(meeting)
        reloadHistory()
    }

    private func scheduleRepairTranslationIfNeeded(for segment: TranscriptSegment) {
        guard TranslationCoverageCoordinator().shouldCover(segment, preferences: appState.preferences) else { return }
        let preparation = realtimeTranslationCoordinator.prepare(
            segment: segment,
            existingSegment: segment,
            plan: translationPlan(for: segment),
            preferences: appState.preferences
        )

        if var meeting = appState.currentMeeting,
           let index = meeting.transcriptSegments.firstIndex(where: { $0.id == segment.id }) {
            meeting.transcriptSegments[index] = preparation.segment
            appState.currentMeeting = meeting
            try? repository.save(meeting)
            reloadHistory()
        }

        scheduleTranslation(preparation.job, segment: preparation.segment)
    }

    private func translationResultStillMatches(currentText: String, key: TranslationJobKey) -> Bool {
        if key.phase == .draft {
            return currentText == key.text || currentText.hasPrefix(key.text)
        }
        return currentText == key.text
    }

    private func startTimer(startedAt: Date) {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                await MainActor.run {
                    self?.appState.elapsed = Date().timeIntervalSince(startedAt)
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func startWaveform() {
        waveformTask?.cancel()
        waveformTask = Task { [weak self] in
            while !Task.isCancelled {
                await MainActor.run {
                    var levels = self?.appState.waveformLevels ?? []
                    if levels.count < 18 { levels = Array(repeating: 0.12, count: 18) }
                    levels.removeFirst()
                    let previous = levels.last ?? 0.12
                    let target = CGFloat.random(in: 0.08...0.92)
                    let eased = previous + (target - previous) * CGFloat.random(in: 0.14...0.30)
                    levels.append(eased)
                    self?.appState.waveformLevels = levels
                }
                try? await Task.sleep(for: .milliseconds(140))
            }
        }
    }

    @discardableResult
    private func startRealtimePipeline(for session: MeetingSession) async -> Bool {
        var micStream: AsyncStream<AudioBuffer>?
        var systemStream: AsyncStream<AudioBuffer>?
        let captureMode = appState.preferences.audioCaptureMode
        let detectedMeetingContext = session.source == .activeApp || session.source == .calendar || session.automationSourceAppName != nil
        let wantsMic = captureMode != .systemOnly
        let wantsSystemAudio = captureMode != .microphoneOnly || appState.preferences.captureSystemAudio || detectedMeetingContext

        if wantsMic {
            do {
                micStream = try await microphoneCaptureService.startCapture()
                appState.activeCaptureLabel = "Mic"
                appState.statusMessage = "Mic only • remote voices may be missed"
            } catch AudioCaptureError.microphonePermissionDenied {
                appState.statusMessage = "Microphone permission required"
            } catch {
                appState.statusMessage = "Microphone unavailable"
            }
        }

        if wantsSystemAudio {
            do {
                systemStream = try await systemAudioCaptureService.startCapture()
                appState.activeCaptureLabel = micStream == nil ? "System audio" : "Mic + system"
                appState.statusMessage = micStream == nil ? "Listening via system audio" : "Listening via mic + system audio"
            } catch AudioCaptureError.systemAudioPermissionDenied {
                appState.statusMessage = micStream == nil ? "Screen/System audio permission required" : "System audio permission required • mic only"
            } catch {
                appState.statusMessage = micStream == nil ? "System audio unavailable" : "System audio unavailable • mic only"
            }
        }

        guard micStream != nil || systemStream != nil else {
            appState.statusMessage = "Grant microphone or system audio"
            return false
        }

        let transcriptionService: any TranscriptionService
        let audioStream: AsyncStream<AudioBuffer>
        let configAudioSource: TranscriptAudioSource
        let sourceCount = [micStream, systemStream].compactMap { $0 }.count
        let conditioningTarget: AudioConditioningTarget = providerRouter.shouldUseCloudRealtimeTranscription(preferences: appState.preferences) ? .cloudRealtime : .nativeSpeech
        var sourceSeparatedSources: [MultiSourceAutoLanguageTranscriptionService.Source] = []

        if let systemStream {
            sourceSeparatedSources.append(.init(
                speakerLabel: "System",
                audioSource: .system,
                audioStream: meteredAudioStream(systemStream, conditioningTarget: conditioningTarget, source: .system)
            ))
        }
        if let micStream {
            sourceSeparatedSources.append(.init(
                speakerLabel: "You",
                audioSource: .microphone,
                audioStream: meteredAudioStream(micStream, conditioningTarget: conditioningTarget, source: .microphone)
            ))
        }
        transcriptionService = providerRouter.meetingTranscriptionService(preferences: appState.preferences, sources: sourceSeparatedSources)
        audioStream = AsyncStream<AudioBuffer> { $0.finish() }
        configAudioSource = sourceCount == 1 ? (sourceSeparatedSources.first?.audioSource ?? .unknown) : .mixed
        let speechContext = transcriptionSpeechContext(for: session)
        let transcriptionConfig = TranscriptionConfig(
            languageCode: SupportedLanguage.normalizedCode(appState.preferences.defaultLanguage),
            requiresOnDeviceRecognition: appState.preferences.localOnlyMode,
            meetingId: session.id,
            contextualStrings: speechContext.contextualStrings,
            speechContext: speechContext,
            audioSource: configAudioSource,
            accuracyMode: appState.preferences.transcriptionAccuracyMode,
            commitPolicy: appState.preferences.copilotASRCommitPolicy,
            preferredLanguageHints: TranscriptionConfig.normalizedLanguageHints(primary: appState.preferences.defaultLanguage, hints: [session.primaryLanguage].compactMap { $0 }),
            sourceSeparationRequired: true
        )
        AppLog.audio.info("Transcription route service=\(String(describing: type(of: transcriptionService)), privacy: .public) mode=\(self.appState.preferences.transcriptionEngineMode.rawValue, privacy: .public) language=\(transcriptionConfig.languageCode ?? "nil", privacy: .public) localOnly=\(self.appState.preferences.localOnlyMode, privacy: .public) sourceSeparated=true sourceCount=\(sourceCount, privacy: .public)")

        activeTranscriptionService = transcriptionService
        observeSegments(from: transcriptionService)

        do {
            try await transcriptionService.startTranscription(audioStream: audioStream, config: transcriptionConfig)
            return true
        } catch {
            if shouldAttemptLocalTranscriptionFallback(after: error) {
                await activeTranscriptionService?.stop()
                let fallbackService = localTranscriptionFallbackService(
                    sources: sourceSeparatedSources,
                    sourceCount: sourceCount
                )
                activeTranscriptionService = fallbackService
                observeSegments(from: fallbackService)
                do {
                    try await fallbackService.startTranscription(audioStream: audioStream, config: transcriptionConfig)
                    appState.statusMessage = "ElevenLabs unavailable • using Apple Speech"
                    return true
                } catch {
                    await activeTranscriptionService?.stop()
                    activeTranscriptionService = nil
                }
            }
            await activeTranscriptionService?.stop()
            activeTranscriptionService = nil
            microphoneCaptureService.stopCapture()
            await systemAudioCaptureService.stopCapture()
            if let transcriptionError = error as? TranscriptionError {
                switch transcriptionError {
                case .speechPermissionDenied:
                    appState.meetingTranscriptionStatus = .permissionRequired
                    appState.statusMessage = "Speech Recognition permission required"
                case .recognizerUnavailable:
                    appState.meetingTranscriptionStatus = .unavailable
                    appState.statusMessage = "Apple Speech unavailable for language"
                case .cloudProviderUnavailable(let message), .cloudTranscriptionFailed(let message):
                    appState.meetingTranscriptionStatus = .unavailable
                    appState.statusMessage = message
                }
            } else {
                appState.meetingTranscriptionStatus = .unavailable
                appState.statusMessage = error.localizedDescription
            }
            return false
        }
    }

    private func shouldAttemptLocalTranscriptionFallback(after error: Error) -> Bool {
        guard appState.preferences.transcriptionEngineMode == .cloudRealtime,
              !appState.preferences.localOnlyMode else { return false }
        guard let transcriptionError = error as? TranscriptionError else { return false }
        switch transcriptionError {
        case .cloudProviderUnavailable, .cloudTranscriptionFailed:
            return true
        case .speechPermissionDenied, .recognizerUnavailable:
            return false
        }
    }

    private func localTranscriptionFallbackService(
        sources: [MultiSourceAutoLanguageTranscriptionService.Source],
        sourceCount: Int
    ) -> any TranscriptionService {
        var fallbackPreferences = appState.preferences
        fallbackPreferences.transcriptionEngineMode = .appleSpeech
        if sourceCount > 0, !sources.isEmpty {
            return providerRouter.meetingTranscriptionService(preferences: fallbackPreferences, sources: sources)
        }
        return UnavailableTranscriptionService(error: .recognizerUnavailable)
    }

    private func transcriptionContext(for session: MeetingSession) -> [String] {
        transcriptionSpeechContext(for: session).contextualStrings
    }

    private func transcriptionSpeechContext(for session: MeetingSession) -> SpeechRecognitionContext {
        if let speechVocabularyStore = appState.speechVocabularyStore {
            return speechVocabularyStore.speechContext(for: session, preferences: appState.preferences)
        }

        let names = ([appState.preferences.userDisplayName] + appState.preferences.userNicknames.split(separator: ",").map { String($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let appTerms = appState.preferences.knownMeetingApps.flatMap { [$0.displayName] + $0.nameKeywords }
        let productTerms = [
            "Notchly", "Dynamic Island", "Local Only", "OpenAI", "ChatGPT", "Realtime API",
            "Swift", "SwiftUI", "AppKit", "AVFoundation", "ScreenCaptureKit", "Speech framework",
            "macOS", "Keychain", "RAG", "transcript", "transcrição", "resumo", "decisão",
            "action item", "follow-up", "bloqueio", "risco", "deadline", "roadmap"
        ]
        let terms = (names + appTerms + productTerms + [session.title]).map {
            SpeechContextTerm(text: $0, locale: nil, category: .custom, weight: 1, pronunciationXSAMPA: nil, source: "legacy")
        }
        return SpeechRecognitionContext(
            locale: SupportedLanguage.normalizedCode(appState.preferences.defaultLanguage),
            terms: terms,
            customLanguageModelEnabled: false,
            status: "Using contextual hints only"
        )
    }

    private func meteredAudioStream(
        _ stream: AsyncStream<AudioBuffer>,
        conditioningTarget: AudioConditioningTarget = .nativeSpeech,
        source: TranscriptAudioSource = .unknown
    ) -> AsyncStream<AudioBuffer> {
        let processor = AudioConditioningStreamProcessor(source: source)
        let config = AudioConditioningConfig(
            accuracyMode: appState.preferences.transcriptionAccuracyMode,
            target: conditioningTarget,
            audioSource: source
        )
        return AsyncStream { continuation in
            Task { [weak self] in
                for await buffer in stream {
                    let conditioned = processor.condition(buffer, config: config).buffer
                    await MainActor.run {
                        self?.pushAudioLevel(conditioned.rms)
                        self?.recordSpeechQuality(conditioned)
                        self?.updateAudioReceivingStatus(for: conditioned)
                        if let pcmBuffer = buffer.pcmBuffer {
                            self?.audioRecorder.append(pcmBuffer)
                        }
                    }
                    continuation.yield(conditioned)
                }
                continuation.finish()
            }
        }
    }

    private func drainAudioStream(_ stream: AsyncStream<AudioBuffer>) {
        audioDrainTasks.append(Task { [weak self] in
            for await buffer in stream {
                await MainActor.run {
                        self?.pushAudioLevel(buffer.rms)
                        self?.recordSpeechQuality(buffer)
                        self?.updateAudioReceivingStatus(for: buffer)
                    if let pcmBuffer = buffer.pcmBuffer {
                        self?.audioRecorder.append(pcmBuffer)
                    }
                }
            }
        })
    }

    private func pushAudioLevel(_ rms: Float) {
        var levels = appState.meetingWaveformLevels
        if levels.count < 18 {
            levels = Array(repeating: 0.08, count: 18)
        }
        levels.removeFirst()
        let normalized = audioAnalyzer.normalizedLevel(from: rms)
        let previous = levels.last ?? normalized
        let smoothed = previous + (normalized - previous) * 0.42
        levels.append(smoothed)
        appState.meetingWaveformLevels = levels
        appState.waveformLevels = levels
    }

    private func recordSpeechQuality(_ buffer: AudioBuffer) {
        let source = buffer.audioSource == .unknown ? .mixed : buffer.audioSource
        var monitor = speechQualityMonitors[source] ?? SpeechAudioQualityMonitor(source: source)
        let snapshot = monitor.ingest(buffer)
        speechQualityMonitors[source] = monitor
        appState.speechAudioQualityBySource[source] = snapshot
        if let meeting = appState.currentMeeting {
            questionAudioLogMelBuffer.append(buffer, meetingStartedAt: meeting.startedAt)
        }
    }

    private func updateAudioReceivingStatus(for buffer: AudioBuffer) {
        guard appState.currentMeeting?.status == .listening else {
            return
        }
        let source = buffer.audioSource == .unknown ? .mixed : buffer.audioSource
        let snapshot = appState.speechAudioQualityBySource[source]
        let activity = snapshot.map { SpeechActivityPolicy().classify($0) } ?? (buffer.rms > 0.0012 ? .speechLikely : .silence)
        guard activity.isSignificant || activity == .lowAudio else { return }
        let now = Date()
        guard now.timeIntervalSince(lastAudioStatusUpdate) > 1.2 else { return }
        lastAudioStatusUpdate = now
        if activity == .lowAudio {
            appState.meetingTranscriptionStatus = source == .system ? .systemAudioActive : .micTooQuiet
            appState.statusMessage = source == .system ? "System audio active" : "Mic too quiet"
            return
        }
        if appState.activeCaptureLabel == "Mic + system" {
            appState.meetingTranscriptionStatus = .hearingMicAndSystem
            appState.statusMessage = "Hearing mic + system audio..."
            return
        }
        switch buffer.audioSource {
        case .microphone:
            appState.meetingTranscriptionStatus = .hearingMic
            appState.statusMessage = "Hearing mic..."
        case .system:
            appState.meetingTranscriptionStatus = .hearingSystem
            appState.statusMessage = "Hearing system audio..."
        default:
            appState.meetingTranscriptionStatus = .listening
            appState.statusMessage = "Hearing audio..."
        }
    }

    private func stopRunningServices(keepMeeting: Bool) async {
        questionEventTask?.cancel()
        questionEventTask = nil
        openAIPrewarmTask?.cancel()
        openAIPrewarmTask = nil
        realtimeQuestionEngine?.reset()
        timerTask?.cancel()
        waveformTask?.cancel()
        microphoneCaptureService.stopCapture()
        await systemAudioCaptureService.stopCapture()
        audioDrainTasks.forEach { $0.cancel() }
        audioDrainTasks = []
        await activeTranscriptionService?.stop()
        segmentTask?.cancel()
        segmentTask = nil
        if !keepMeeting {
            audioRecorder.stopRecording()
            cancelPendingTranslations()
            questionAudioLogMelBuffer.reset()
        }
        activeTranscriptionService = nil
        if !keepMeeting {
            appState.currentMeeting = nil
            appState.activeCaptureLabel = "Mic + system"
            appState.meetingTranscriptionStatus = .idle
        }
    }

    private func showTransientSummaryReady(keepExpanded: Bool = false) {
        guard let meeting = appState.currentMeeting else { return }
        appState.selectedMeeting = meeting
        appState.isPanelExpanded = keepExpanded
        appState.islandMode = .summaryReady
        appState.statusMessage = "Summary ready"
        summaryReadyTask?.cancel()
        summaryReadyTask = Task { [weak self, meetingId = meeting.id] in
            try? await Task.sleep(for: .seconds(3))
            await MainActor.run {
                guard let self,
                      self.appState.currentMeeting?.id == meetingId,
                      self.appState.islandMode == .summaryReady
                else { return }
                self.appState.currentMeeting = nil
                self.appState.isPanelExpanded = false
                self.appState.islandMode = .idle
                self.appState.statusMessage = "Ready"
                self.appState.meetingTranscriptionStatus = .idle
            }
        }
    }
}

typealias AmbientCopilotController = CopilotRuntime

@MainActor
final class CopilotRuntime {
    private unowned let appState: AppState
    private let repository: MeetingRepository
    private let settingsRepository: SettingsRepository
    private let providerRouter: ProviderRouter
    private let knowledgeStore: LocalKnowledgeStore
    private let microphoneCaptureService: AppleMicrophoneCaptureService
    private let languageDetector = AppleLanguageDetectionService()
    private let audioAnalyzer = AppleAccelerateAudioAnalyzer()
    private var activeTranscriptionService: (any TranscriptionService)?
    private var segmentTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var generationTask: Task<Void, Never>?
    private var asrWatchdogTask: Task<Void, Never>?
    private var pendingPartialIntentTasks: [UUID: Task<Void, Never>] = [:]
    private var acceptedAmbientSegmentIds = Set<UUID>()
    private var latestPushToTalkSegment: TranscriptSegment?
    private var pushToTalkStartedAt = Date()
    private var isPushToTalkActive = false
    private var buffer = TranscriptWindowBuffer()
    private var ambientSession = MeetingSession(title: "Notchly", source: .manual, status: .listening, meetingType: .general)
    private var isRunning = false
    private var ambientAllowsHybridSpeechRecognition = false
    private var lastAudioStatusUpdate = Date.distantPast
    private var stateMachine = CopilotStateMachine()
    private let telemetry = CopilotQualityTelemetry()
    private let activationTraceStore = CopilotActivationTraceStore()
    private var failoverCoordinator = TranscriptionFailoverCoordinator()
    private var speechUnderstandingPipeline = CopilotSpeechUnderstandingPipeline()

    init(
        appState: AppState,
        repository: MeetingRepository,
        settingsRepository: SettingsRepository,
        providerRouter: ProviderRouter,
        knowledgeStore: LocalKnowledgeStore,
        microphoneCaptureService: AppleMicrophoneCaptureService = AppleMicrophoneCaptureService()
    ) {
        self.appState = appState
        self.repository = repository
        self.settingsRepository = settingsRepository
        self.providerRouter = providerRouter
        self.knowledgeStore = knowledgeStore
        self.microphoneCaptureService = microphoneCaptureService
    }

    func start() {
        purgeExpiredData()
        reloadHistory()
        evaluateRunningState()
    }

    func evaluateRunningState() {
        guard appState.currentMeeting == nil else {
            appState.copilotASRStatus = .pausedDuringMeeting
            transition(to: .paused, status: "Paused during meeting")
            appState.applyCopilotHealthSnapshot(failoverCoordinator.markStopped(state: .meetingModePaused, now: Date()))
            stop(reason: "Paused during meeting")
            return
        }
        if isRunning || startTask != nil {
            if !isPushToTalkActive {
                stop(reason: "Hotkey ready")
            }
            return
        }
        if generationTask == nil {
            appState.applyCopilotHealthSnapshot(CopilotHealthSnapshot(state: .ready))
            transition(to: .idle, status: "Hotkey ready")
        }
    }

    func stop(reason: String = "Paused") {
        startTask?.cancel()
        startTask = nil
        generationTask?.cancel()
        generationTask = nil
        asrWatchdogTask?.cancel()
        asrWatchdogTask = nil
        cancelPendingPartialIntentTasks()
        segmentTask?.cancel()
        segmentTask = nil
        if let service = activeTranscriptionService {
            Task { await service.stop() }
        }
        activeTranscriptionService = nil
        microphoneCaptureService.stopCapture()
        isRunning = false
        if reason.localizedCaseInsensitiveContains("meeting") {
            appState.copilotASRStatus = .pausedDuringMeeting
        } else if reason.localizedCaseInsensitiveContains("processing") {
            appState.copilotASRStatus = .processing
        } else {
            appState.copilotASRStatus = .idle
        }
        if appState.preferences.copilotHotkeyEnabled {
            let health: CopilotHealthState
            if reason.localizedCaseInsensitiveContains("meeting") {
                health = .meetingModePaused
            } else if reason.localizedCaseInsensitiveContains("permission") {
                health = .micPermissionBlocked
            } else {
                health = .ready
            }
            appState.applyCopilotHealthSnapshot(failoverCoordinator.markStopped(state: health, now: Date()))
        }
        transition(to: reason.localizedCaseInsensitiveContains("permission") ? .permissionBlocked : .paused, status: reason)
        appState.setAmbientCopilotListening(false, status: reason)
        appState.finishCopilotPushToTalk(status: reason)
    }

    func clearHistory() {
        do {
            try interactionStore().clearHistory()
            reloadHistory()
            appState.statusMessage = "Notchly history cleared"
        } catch {
            appState.statusMessage = "Could not clear Notchly history"
        }
    }

    func saveInteraction(_ interaction: CopilotInteraction) {
        try? interactionStore().saveInteraction(interaction)
        reloadHistory()
    }

    func reloadStoredHistory() {
        purgeExpiredData()
        reloadHistory()
    }

    func answerManually(_ text: String, forceWeb: Bool = false) {
        let segment = ambientSegment(text: text, isFinal: true, confidence: 1.0)
        Task { [weak self] in
            await self?.process(segment: segment, forceWeb: forceWeb, source: .typed)
        }
    }

    func beginPushToTalk() {
        guard appState.currentMeeting == nil else {
            appState.copilotASRStatus = .pausedDuringMeeting
            appState.setAmbientCopilotListening(false, status: CopilotASRStatus.pausedDuringMeeting.displayText)
            return
        }
        guard appState.preferences.copilotHotkeyEnabled else {
            appState.finishCopilotPushToTalk(status: "Hotkey disabled", errorMessage: "Enable the Notchly hotkey in Settings.")
            return
        }
        guard !isRunning, startTask == nil else { return }

        appState.isPanelExpanded = false
        appState.isNotchHovered = false
        appState.islandMode = .idle
        appState.isCopilotPushToTalkActive = true
        appState.setCopilotPushToTalkProcessing(false)
        appState.copilotPushToTalkTranscript = ""
        appState.copilotPushToTalkErrorMessage = nil
        appState.setAmbientCopilotListening(true, status: "Listening")
        appState.applyCopilotHealthSnapshot(CopilotHealthSnapshot(state: .asrStarting, activeASRBackend: "Apple Speech"))
        isPushToTalkActive = true
        latestPushToTalkSegment = nil
        pushToTalkStartedAt = Date()
        buffer.reset()
        acceptedAmbientSegmentIds.removeAll()
        transition(to: .listening, status: "Listening")

        startTask = Task { [weak self] in
            await self?.startPushToTalkPipeline()
        }
    }

    func endPushToTalk() {
        guard isPushToTalkActive || isRunning || startTask != nil else { return }
        isPushToTalkActive = false
        appState.isCopilotPushToTalkActive = false
        Task { [weak self] in
            await self?.finishPushToTalk()
        }
    }

    private func startPushToTalkPipeline() async {
        startTask = nil
        var preferences = appState.preferences
        let useCloudRealtimeASRFallback = providerRouter.shouldUseCloudRealtimeTranscription(preferences: preferences)
        preferences.transcriptionEngineMode = useCloudRealtimeASRFallback ? .cloudRealtime : .appleSpeech
        preferences.audioCaptureMode = .microphoneOnly
        preferences.captureSystemAudio = false

        do {
            appState.applyCopilotHealthSnapshot(CopilotHealthSnapshot(
                state: .asrStarting,
                activeASRBackend: useCloudRealtimeASRFallback ? "Cloud realtime ASR" : (ambientAllowsHybridSpeechRecognition ? "Apple Speech hybrid" : "Apple Speech on-device")
            ))
            let micStream = try await microphoneCaptureService.startCapture()
            let service = providerRouter.copilotASRService(preferences: preferences)
            activeTranscriptionService = service
            observePushToTalkSegments(from: service)
            ambientSession = MeetingSession(
                id: UUID(),
                title: "Notchly",
                source: .manual,
                startedAt: Date(),
                status: .listening,
                primaryLanguage: SupportedLanguage.normalizedCode(preferences.defaultLanguage),
                meetingType: .general
            )
            buffer.reset()
            acceptedAmbientSegmentIds.removeAll()
            cancelPendingPartialIntentTasks()
            isRunning = true
            let backend = useCloudRealtimeASRFallback ? "Cloud realtime ASR" : (ambientAllowsHybridSpeechRecognition ? "Apple Speech hybrid" : "Apple Speech on-device")
            appState.applyCopilotHealthSnapshot(failoverCoordinator.markPipelineStarted(backend: backend))
            appState.copilotASRStatus = .listening
            transition(to: .listening, status: "Listening")
            appState.setAmbientCopilotListening(true, status: "Listening")
            let ambientContext = ambientSpeechContext(preferences: preferences)
            let conditioningTarget: AudioConditioningTarget = useCloudRealtimeASRFallback ? .cloudRealtime : .nativeSpeech
            try await service.startTranscription(
                audioStream: meteredAudioStream(micStream, conditioningTarget: conditioningTarget, source: .microphone, preferences: preferences),
                config: TranscriptionConfig(
                    languageCode: SupportedLanguage.normalizedCode(preferences.defaultLanguage),
                    requiresOnDeviceRecognition: !ambientAllowsHybridSpeechRecognition,
                    meetingId: ambientSession.id,
                    contextualStrings: ambientContext.contextualStrings,
                    speechContext: ambientContext,
                    audioSource: .microphone,
                    accuracyMode: preferences.transcriptionAccuracyMode,
                    commitPolicy: preferences.copilotASRCommitPolicy,
                    preferredLanguageHints: TranscriptionConfig.normalizedLanguageHints(primary: preferences.defaultLanguage, hints: []),
                    sourceSeparationRequired: false
                )
            )
        } catch AudioCaptureError.microphonePermissionDenied {
            isRunning = false
            activeTranscriptionService = nil
            isPushToTalkActive = false
            appState.copilotASRStatus = .failed
            appState.applyCopilotHealthSnapshot(failoverCoordinator.markStopped(state: .micPermissionBlocked, now: Date()))
            transition(to: .permissionBlocked, failure: .microphonePermissionMissing, status: CopilotFailureKind.microphonePermissionMissing.userMessage)
            appState.setAmbientCopilotListening(false, status: "Microphone permission required")
            appState.finishCopilotPushToTalk(status: "Microphone permission required", errorMessage: CopilotFailureKind.microphonePermissionMissing.userMessage)
        } catch {
            isRunning = false
            activeTranscriptionService = nil
            isPushToTalkActive = false
            appState.copilotASRStatus = .failed
            appState.applyCopilotHealthSnapshot(failoverCoordinator.markError(error))
            transition(to: .failedRecoverable, failure: .modelUnavailable, status: CopilotFailureKind.modelUnavailable.userMessage)
            appState.setAmbientCopilotListening(false, status: "Notchly unavailable")
            appState.finishCopilotPushToTalk(status: "Notchly unavailable", errorMessage: error.localizedDescription)
            AppLog.audio.error("Ambient Notchly start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func observeSegments(from service: any TranscriptionService) {
        segmentTask?.cancel()
        segmentTask = Task { [weak self] in
            for await segment in service.segments {
                await MainActor.run {
                    if let self {
                        self.appState.applyCopilotHealthSnapshot(self.failoverCoordinator.markSegment(segment))
                    }
                }
                await self?.process(segment: segment)
            }
        }
    }

    private func observePushToTalkSegments(from service: any TranscriptionService) {
        segmentTask?.cancel()
        segmentTask = Task { [weak self] in
            for await segment in service.segments {
                await MainActor.run {
                    guard let self else { return }
                    self.appState.applyCopilotHealthSnapshot(self.failoverCoordinator.markSegment(segment))
                    self.latestPushToTalkSegment = self.preferredPushToTalkSegment(current: self.latestPushToTalkSegment, incoming: segment)
                    self.appState.updateCopilotPushToTalkTranscript(self.latestPushToTalkSegment?.text ?? segment.text)
                }
            }
        }
    }

    private func preferredPushToTalkSegment(current: TranscriptSegment?, incoming: TranscriptSegment) -> TranscriptSegment {
        let incomingText = incoming.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !incomingText.isEmpty else { return current ?? incoming }
        guard let current else { return incoming }
        if incoming.isFinal && !current.isFinal { return incoming }
        if incomingText.count >= current.text.trimmingCharacters(in: .whitespacesAndNewlines).count { return incoming }
        return current
    }

    private func finishPushToTalk() async {
        startTask?.cancel()
        startTask = nil
        asrWatchdogTask?.cancel()
        asrWatchdogTask = nil
        let service = activeTranscriptionService
        activeTranscriptionService = nil
        microphoneCaptureService.stopCapture()
        await service?.stop()
        try? await Task.sleep(for: .milliseconds(180))
        segmentTask?.cancel()
        segmentTask = nil
        isRunning = false
        appState.setAmbientCopilotListening(false, status: "Processing")

        let segment = latestPushToTalkSegment
        guard var segment else {
            appState.applyCopilotHealthSnapshot(CopilotHealthSnapshot(state: .asrNoSegments, activeASRBackend: "Apple Speech"))
            appState.finishCopilotPushToTalk(status: "No speech detected", errorMessage: "Hold the mic button and speak clearly.")
            transition(to: .idle, status: "Hotkey ready")
            return
        }

        let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            appState.applyCopilotHealthSnapshot(CopilotHealthSnapshot(state: .asrNoSegments, activeASRBackend: "Apple Speech"))
            appState.finishCopilotPushToTalk(status: "No speech detected", errorMessage: "Hold the mic button and speak clearly.")
            transition(to: .idle, status: "Hotkey ready")
            return
        }

        segment.text = trimmed
        segment.isFinal = true
        segment.transcriptionPhase = .final
        segment.finalizedBy = segment.finalizedBy ?? segment.transcriptionEngine
        appState.setCopilotPushToTalkProcessing(true, status: "Processing")
        await process(segment: segment, forceWeb: false, source: .shortcut)
    }

    private func process(segment incoming: TranscriptSegment, forceWeb: Bool = false, source: CopilotRuntimeSource = .microphone) async {
        guard appState.currentMeeting == nil else { return }
        var segment = incoming
        segment.originalLanguage = segment.originalLanguage ?? languageDetector.dominantLanguage(for: segment.text)
        buffer.append(segment)

        guard segment.isFinal else {
            schedulePartialIntentCheck(for: segment, forceWeb: forceWeb, source: source)
            return
        }
        pendingPartialIntentTasks[segment.id]?.cancel()
        pendingPartialIntentTasks[segment.id] = nil
        guard !acceptedAmbientSegmentIds.contains(segment.id) else { return }
        await evaluateIntent(segment: segment, forceWeb: forceWeb, source: source)
    }

    private func schedulePartialIntentCheck(for segment: TranscriptSegment, forceWeb: Bool, source: CopilotRuntimeSource) {
        guard source == .microphone else { return }
        pendingPartialIntentTasks[segment.id]?.cancel()
    }

    private func processStablePartial(segment: TranscriptSegment, forceWeb: Bool, source: CopilotRuntimeSource) async {
        pendingPartialIntentTasks[segment.id] = nil
        guard appState.currentMeeting == nil else { return }
        guard !acceptedAmbientSegmentIds.contains(segment.id) else { return }
        var finalLikeSegment = segment
        finalLikeSegment.isFinal = true
        finalLikeSegment.transcriptionPhase = .final
        finalLikeSegment.finalizedBy = segment.finalizedBy ?? segment.transcriptionEngine
        await evaluateIntent(segment: finalLikeSegment, forceWeb: forceWeb, source: source)
    }

    private func evaluateIntent(segment: TranscriptSegment, forceWeb: Bool, source: CopilotRuntimeSource) async {
        let intentStartedAt = Date()
        let context = buffer.transcriptContext(currentSegment: segment)
        let frames = speechUnderstandingPipeline.candidateFrames(from: segment, context: context)
        guard shouldRunLLMDecision(frames: frames, context: context, source: source) else {
            if source == .shortcut {
                appState.finishCopilotPushToTalk(status: "Hotkey ready")
            }
            recordActivationTrace(
                source: source,
                frames: frames,
                decision: nil,
                failureKind: nil,
                ignoredReason: "local_gate_rejected",
                latencyMs: Date().timeIntervalSince(intentStartedAt) * 1_000
            )
            let status = appState.preferences.copilotASRCommitPolicy == .accurate && source == .microphone ? "Ouvindo melhor" : "Listening"
            transition(to: .listening, status: status)
            return
        }

        let provider: any AIProvider
        if source == .typed || source == .shortcut {
            provider = providerRouter.aiProvider(preferences: appState.preferences)
        } else {
            provider = providerRouter.copilotCloudDecisionProvider(preferences: appState.preferences)
                ?? UnavailableAIProvider(reason: "AI provider required")
        }
        let decisionResult: CopilotLLMDecisionResult
        do {
            decisionResult = try await runDecisionWithTimeout(
                service: CopilotLLMDecisionService(provider: provider),
                frames: frames,
                transcriptContext: context,
                meeting: ambientSession,
                preferences: appState.preferences,
                source: source,
                forceWeb: forceWeb
            )
        } catch {
            let failure = copilotFailure(from: error)
            let healthState: CopilotHealthState = failure.kind == .modelUnavailable ? .llmProviderInvalid : .llmDecisionTimeout
            appState.applyCopilotHealthSnapshot(CopilotHealthSnapshot(
                state: healthState,
                lastAudioAt: failoverCoordinator.snapshot.lastAudioAt,
                lastPartialAt: failoverCoordinator.snapshot.lastPartialAt,
                lastFinalSegmentAt: failoverCoordinator.snapshot.lastFinalSegmentAt,
                lastASRError: failoverCoordinator.snapshot.lastASRError,
                activeASRBackend: failoverCoordinator.snapshot.activeASRBackend
            ))
            recordActivationTrace(
                source: source,
                frames: frames,
                decision: nil,
                failureKind: failure.kind,
                ignoredReason: failure.kind.rawValue,
                latencyMs: Date().timeIntervalSince(intentStartedAt) * 1_000
            )
            if source == .typed || source == .shortcut {
                appState.setCopilotPushToTalkProcessing(false)
                await presentDecisionFailure(
                    segment: segment,
                    context: context,
                    source: source,
                    failure: failure,
                    latencyMs: Date().timeIntervalSince(intentStartedAt) * 1_000
                )
            } else {
                recordQuality(
                    stage: .intent,
                    accepted: false,
                    classification: silentClassification(text: segment.text, reason: failure.kind.rawValue, language: segment.originalLanguage),
                    source: source,
                    latencyMs: Date().timeIntervalSince(intentStartedAt) * 1_000,
                    reason: failure.kind.rawValue
                )
                transition(to: .listening, status: "Listening")
            }
            return
        }

        guard decisionResult.shouldPresent else {
            if source == .shortcut {
                appState.finishCopilotPushToTalk(status: "Hotkey ready")
            }
            let classification = CopilotIntentClassification(decision: decisionResult.decision, frame: decisionResult.selectedFrame, responseNeeded: false)
            recordActivationTrace(
                source: source,
                frames: frames,
                selectedFrame: decisionResult.selectedFrame,
                decision: decisionResult.decision,
                failureKind: nil,
                ignoredReason: decisionResult.decision.reason,
                latencyMs: Date().timeIntervalSince(intentStartedAt) * 1_000
            )
            recordQuality(
                stage: .intent,
                accepted: false,
                classification: classification,
                source: source,
                latencyMs: Date().timeIntervalSince(intentStartedAt) * 1_000,
                reason: decisionResult.decision.reason
            )
            transition(to: .listening, status: "Listening")
            return
        }
        let copilotClassification = CopilotIntentClassification(decision: decisionResult.decision, frame: decisionResult.selectedFrame, responseNeeded: true)
        acceptedAmbientSegmentIds.insert(segment.id)
        recordActivationTrace(
            source: source,
            frames: frames,
            selectedFrame: decisionResult.selectedFrame,
            decision: decisionResult.decision,
            failureKind: nil,
            ignoredReason: nil,
            latencyMs: Date().timeIntervalSince(intentStartedAt) * 1_000
        )
        recordQuality(
            stage: .intent,
            accepted: true,
            classification: copilotClassification,
            source: source,
            latencyMs: Date().timeIntervalSince(intentStartedAt) * 1_000,
            reason: copilotClassification.reason
        )
        if decisionResult.decision.needsClarification {
            appState.setCopilotPushToTalkProcessing(false)
            await presentLLMClarification(
                segment: segment,
                frame: decisionResult.selectedFrame,
                decision: decisionResult.decision,
                classification: copilotClassification,
                source: source,
                latencyMs: Date().timeIntervalSince(intentStartedAt) * 1_000,
                provider: decisionResult.raw.provider,
                usedCloud: decisionResult.raw.usedCloud
            )
            return
        }
        transition(to: .classifying, status: "Understanding")

        let candidate = QuestionCandidate(
            meetingId: ambientSession.id,
            rawText: copilotClassification.extractedQuery,
            normalizedText: QuestionDetectionService.normalize(copilotClassification.extractedQuery),
            language: copilotClassification.languageCode,
            speakerLabel: "You",
            startTime: segment.startTime,
            endTime: segment.endTime,
            sourceSegmentIds: [segment.id],
            isPartial: false
        )
        let questionClassification = QuestionClassification(copilot: copilotClassification, candidate: candidate)
        appState.upsertQuestionInQueue(
            candidate: candidate,
            classification: questionClassification,
            stage: .classifying,
            decision: "copilot_detected",
            select: true
        )
        appState.questionAnswerPresentationMode = .answer
        appState.statusMessage = "Notchly"

        generationTask?.cancel()
        generationTask = Task { [weak self] in
            await self?.generateAnswer(
                candidate: candidate,
                questionClassification: questionClassification,
                copilotClassification: copilotClassification,
                decision: decisionResult.decision,
                context: context,
                source: source,
                forceWeb: forceWeb
            )
        }
    }

    private func shouldRunLLMDecision(frames: [SpeechCandidateFrame], context: TranscriptContext, source: CopilotRuntimeSource) -> Bool {
        guard let best = CopilotSpeechFrameSelector.bestFrame(in: frames, context: context, preferences: appState.preferences) else { return false }
        let text = best.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 6 else { return false }
        guard text.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { return false }
        if source == .typed || source == .shortcut { return true }
        guard best.isFinal, !best.isPartial else { return false }
        let threshold: Double
        switch appState.preferences.copilotASRCommitPolicy {
        case .fast:
            threshold = 0.42
        case .balanced:
            threshold = 0.52
        case .accurate:
            threshold = 0.58
        }
        return CopilotSpeechFrameSelector.score(best, context: context, preferences: appState.preferences) >= threshold
    }

    private func runDecisionWithTimeout(
        service: CopilotLLMDecisionService,
        frames: [SpeechCandidateFrame],
        transcriptContext: TranscriptContext,
        meeting: MeetingSession,
        preferences: AppPreferences,
        source: CopilotRuntimeSource,
        forceWeb: Bool
    ) async throws -> CopilotLLMDecisionResult {
        let decisionTask = Task { @MainActor in
            try await service.decide(
                frames: frames,
                transcriptContext: transcriptContext,
                meeting: meeting,
                preferences: preferences,
                source: source,
                forceWeb: forceWeb
            )
        }
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            decisionTask.cancel()
        }
        do {
            let result = try await decisionTask.value
            timeoutTask.cancel()
            return result
        } catch {
            timeoutTask.cancel()
            if error is CancellationError {
                throw AIProviderError.providerUnavailable("AI decision timed out.")
            }
            throw error
        }
    }

    private func silentClassification(text: String, reason: String, language: String?) -> CopilotIntentClassification {
        CopilotIntentClassification(
            kind: .ambientNoise,
            responseNeeded: false,
            confidence: 0,
            strongSignals: [],
            negativeSignals: [reason],
            reason: reason,
            extractedQuery: text,
            requiresWeb: false,
            preferredTool: .unavailable,
            languageCode: language
        )
    }

    private func presentLLMClarification(
        segment: TranscriptSegment,
        frame: SpeechCandidateFrame,
        decision: CopilotLLMIntentAndAnswerResponse,
        classification: CopilotIntentClassification,
        source: CopilotRuntimeSource,
        latencyMs: Double,
        provider: EngineName,
        usedCloud: Bool
    ) async {
        let message = decision.answerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        transition(to: .ready, status: "Ready")

        let candidate = QuestionCandidate(
            meetingId: ambientSession.id,
            rawText: frame.text,
            normalizedText: QuestionDetectionService.normalize(frame.text),
            language: frame.languageCode ?? classification.languageCode,
            speakerLabel: "You",
            startTime: frame.startTime,
            endTime: frame.endTime,
            sourceSegmentIds: [segment.id],
            isPartial: false
        )
        let questionClassification = QuestionClassification(copilot: classification, candidate: candidate)
        let answer = SuggestedAnswer(
            questionId: candidate.id,
            answerText: message,
            shortAnswer: message,
            confidence: classification.confidence,
            riskLevel: .safe,
            usedSources: [],
            assumptions: [],
            caveats: [],
            latencyMs: Int(latencyMs),
            expandedAnswer: message,
            suggestedTone: .askForClarification,
            language: candidate.language,
            provider: provider,
            usedCloud: usedCloud,
            usedRAG: false,
            answerFormat: .plainShort,
            richAnswer: RichAnswerFallbackBuilder.payload(
                text: message,
                format: .plainShort,
                sources: [],
                confidence: classification.confidence,
                riskLevel: .safe,
                tone: .askForClarification
            )
        )
        appState.upsertQuestionInQueue(
            candidate: candidate,
            classification: questionClassification,
            stage: .drafting,
            decision: "copilot_llm_clarification",
            select: true
        )
        appState.updateQueuedQuestionAnswer(candidate: candidate, answer: answer)
        appState.showQuestionAnswerPanel(mode: .answer)
        appState.statusMessage = "Notchly"

        let interaction = CopilotInteraction(
            contextKind: .ambient,
            source: source,
            questionId: candidate.id,
            prompt: PrivacyGuard().redact(segment.text),
            response: PrivacyGuard().redact(message),
            tool: .answerSynthesis,
            intent: .ambiguous,
            languageCode: candidate.language,
            confidence: classification.confidence,
            latencyMs: Int(latencyMs),
            sources: [],
            richAnswer: answer.richAnswer,
            expiresAt: interactionStore().expiry()
        )
        try? interactionStore().saveInteraction(interaction)
        appState.applyCopilotInteraction(interaction)
        reloadHistory()
    }

    private func presentDecisionFailure(
        segment: TranscriptSegment,
        context: TranscriptContext,
        source: CopilotRuntimeSource,
        failure: CopilotFailure,
        latencyMs: Double
    ) async {
        let classification = silentClassification(text: segment.text, reason: failure.kind.rawValue, language: segment.originalLanguage)
        let candidate = QuestionCandidate(
            meetingId: ambientSession.id,
            rawText: segment.text,
            normalizedText: QuestionDetectionService.normalize(segment.text),
            language: segment.originalLanguage ?? context.dominantLanguage,
            speakerLabel: "You",
            startTime: segment.startTime,
            endTime: segment.endTime,
            sourceSegmentIds: [segment.id],
            isPartial: false
        )
        let questionClassification = QuestionClassification(copilot: classification, candidate: candidate)
        let failurePresentation = CopilotAnswerPresenter().failure(failure)
        let answer = SuggestedAnswer(
            questionId: candidate.id,
            answerText: failurePresentation.text,
            shortAnswer: failurePresentation.shortText,
            confidence: 0,
            riskLevel: .moderate,
            usedSources: [],
            assumptions: [],
            caveats: failurePresentation.caveats,
            latencyMs: Int(latencyMs),
            expandedAnswer: failurePresentation.text,
            suggestedTone: .askForClarification,
            language: candidate.language,
            provider: .unavailable,
            usedCloud: false,
            usedRAG: false,
            answerFormat: .errorState,
            richAnswer: failurePresentation.richAnswer
        )
        appState.upsertQuestionInQueue(candidate: candidate, classification: questionClassification, stage: .failed, decision: "copilot_decision_failed", select: true)
        appState.updateQueuedQuestionAnswer(candidate: candidate, answer: answer)
        appState.showQuestionAnswerPanel(mode: .answer)
        transition(to: .failedRecoverable, failure: failure.kind, status: failure.userMessage)
        appState.statusMessage = failure.userMessage
        recordQuality(stage: .intent, accepted: false, classification: classification, source: source, latencyMs: latencyMs, reason: failure.kind.rawValue)
    }

    private func cancelPendingPartialIntentTasks() {
        pendingPartialIntentTasks.values.forEach { $0.cancel() }
        pendingPartialIntentTasks.removeAll()
    }

    private func generateAnswer(
        candidate: QuestionCandidate,
        questionClassification: QuestionClassification,
        copilotClassification: CopilotIntentClassification,
        decision: CopilotLLMIntentAndAnswerResponse,
        context: TranscriptContext,
        source: CopilotRuntimeSource,
        forceWeb: Bool
    ) async {
        let startedAt = Date()
        if source == .shortcut {
            appState.setCopilotPushToTalkProcessing(true, status: statusText(for: copilotClassification, forceWeb: forceWeb))
        }
        transition(to: .routing, status: statusText(for: copilotClassification, forceWeb: forceWeb))
        appState.updateQueuedQuestionStage(questionId: candidate.id, stage: .retrievingContext)
        appState.statusMessage = statusText(for: copilotClassification, forceWeb: forceWeb)
        do {
            let router = CopilotToolRouter(
                repository: repository,
                providerRouter: providerRouter,
                knowledgeStore: knowledgeStore,
                preferences: appState.preferences
            )
            transition(to: runtimeState(for: copilotClassification, forceWeb: forceWeb), status: statusText(for: copilotClassification, forceWeb: forceWeb))
            appState.updateQueuedQuestionStage(questionId: candidate.id, stage: .drafting)
            let result = try await router.answer(
                candidate: candidate,
                questionClassification: questionClassification,
                copilotClassification: copilotClassification,
                decision: decision,
                transcriptContext: context,
                meeting: ambientSession,
                source: source,
                forceWeb: forceWeb
            )
            appState.updateQueuedQuestionAnswer(candidate: candidate, answer: result.answer)
            appState.setCopilotPushToTalkProcessing(false)
            appState.showQuestionAnswerPanel(mode: .answer)
            transition(to: .ready, status: "Ready")
            appState.statusMessage = "Notchly answer"
            let interaction = result.interaction.withLatency(Int(Date().timeIntervalSince(startedAt) * 1000))
            try interactionStore().saveInteraction(interaction)
            try? interactionStore().saveMemory(
                prompt: candidate.rawText,
                answer: result.answer.shortAnswer,
                languageCode: candidate.language,
                interactionId: interaction.id
            )
            appState.applyCopilotInteraction(interaction)
            recordQuality(
                stage: .total,
                accepted: true,
                classification: copilotClassification,
                source: source,
                latencyMs: Date().timeIntervalSince(startedAt) * 1_000,
                reason: "answer_ready"
            )
            reloadHistory()
        } catch {
            let failure = copilotFailure(from: error)
            transition(to: failure.kind == .microphonePermissionMissing ? .permissionBlocked : .failedRecoverable, failure: failure.kind, status: failure.userMessage)
            appState.updateQueuedQuestionStage(questionId: candidate.id, stage: .failed)
            appState.streamingAnswerText = ""
            let failurePresentation = CopilotAnswerPresenter().failure(failure)
            let failureAnswer = SuggestedAnswer(
                questionId: candidate.id,
                answerText: failurePresentation.text,
                shortAnswer: failurePresentation.shortText,
                confidence: questionClassification.confidence,
                riskLevel: .moderate,
                usedSources: [],
                assumptions: [],
                caveats: failurePresentation.caveats,
                latencyMs: Int(Date().timeIntervalSince(startedAt) * 1_000),
                expandedAnswer: failurePresentation.text,
                suggestedTone: .askForClarification,
                language: candidate.language,
                provider: .unavailable,
                usedCloud: false,
                usedRAG: false,
                answerFormat: .errorState,
                richAnswer: failurePresentation.richAnswer
            )
            appState.updateQueuedQuestionAnswer(candidate: candidate, answer: failureAnswer)
            appState.setCopilotPushToTalkProcessing(false)
            appState.showQuestionAnswerPanel(mode: .answer)
            appState.statusMessage = failure.userMessage
            recordQuality(
                stage: .total,
                accepted: false,
                classification: copilotClassification,
                source: source,
                latencyMs: Date().timeIntervalSince(startedAt) * 1_000,
                reason: failure.kind.rawValue,
                failureKind: failure.kind
            )
        }
    }

    private func reloadHistory() {
        let loaded = interactionStore().load()
        appState.copilotInteractions = loaded.interactions
        appState.copilotReminders = loaded.reminders
    }

    private func purgeExpiredData() {
        try? repository.purgeExpiredCopilotData()
    }

    private func interactionStore() -> CopilotInteractionStore {
        CopilotInteractionStore(repository: repository, retentionDays: appState.preferences.copilotRetentionDays)
    }

    private func transition(to state: CopilotRuntimeState, failure: CopilotFailureKind? = nil, status: String? = nil) {
        _ = stateMachine.transition(to: state)
        appState.setCopilotRuntimeState(stateMachine.state, failure: failure, status: status)
    }

    private func recordActivationTrace(
        source: CopilotRuntimeSource,
        frames: [SpeechCandidateFrame],
        selectedFrame: SpeechCandidateFrame? = nil,
        decision: CopilotLLMIntentAndAnswerResponse?,
        failureKind: CopilotFailureKind?,
        ignoredReason: String?,
        latencyMs: Double
    ) {
        let selected = selectedFrame ?? frames.max(by: { $0.combinedConfidence < $1.combinedConfidence })
        let snapshot = failoverCoordinator.snapshot
        let trace = CopilotActivationTrace(
            source: source,
            audioReceived: snapshot.lastAudioAt != nil || source != .microphone,
            partialReceived: snapshot.lastPartialAt != nil || source != .microphone,
            finalReceived: snapshot.lastFinalSegmentAt != nil || source != .microphone,
            candidateCount: frames.count,
            selectedCandidatePreview: selected.map { CopilotActivationTrace.sanitizedPreview($0.text) } ?? nil,
            selectedCandidateHash: selected.map { CopilotActivationTrace.stableHash(for: $0.text) } ?? nil,
            decisionShouldRespond: decision?.shouldRespond,
            confidence: decision?.confidence,
            ignoredReason: ignoredReason,
            failureKind: failureKind,
            healthState: snapshot.state,
            latencyMs: latencyMs
        )
        appState.applyCopilotActivationTrace(trace)
        activationTraceStore.append(trace)
    }

    private func recordQuality(
        stage: CopilotQualityStage,
        accepted: Bool,
        classification: CopilotIntentClassification,
        source: CopilotRuntimeSource,
        latencyMs: Double,
        reason: String,
        failureKind: CopilotFailureKind? = nil
    ) {
        let snapshot = telemetry.record(CopilotQualityEvent(
            stage: stage,
            accepted: accepted,
            tool: classification.preferredTool,
            intent: classification.kind,
            runtimeState: stateMachine.state,
            languageCode: classification.languageCode,
            source: source,
            latencyMs: latencyMs,
            reason: reason,
            failureKind: failureKind
        ))
        appState.applyCopilotQualitySnapshot(snapshot)
    }

    private func runtimeState(for classification: CopilotIntentClassification, forceWeb: Bool) -> CopilotRuntimeState {
        if forceWeb || classification.requiresWeb { return .searching }
        switch classification.preferredTool {
        case .calculator: return .calculating
        case .webSearch: return .searching
        case .reminder, .localMemory, .answerSynthesis, .unavailable: return .synthesizing
        }
    }

    private func copilotFailure(from error: Error) -> CopilotFailure {
        if let failure = error as? CopilotFailure {
            return failure
        }
        if let providerError = error as? AIProviderError {
            switch providerError {
            case let .providerUnavailable(reason):
                return CopilotFailure(.modelUnavailable, detail: reason)
            case .invalidResponse:
                return CopilotFailure(.emptyResponse)
            case .cloudDisabled:
                return CopilotFailure(.privacyBlocked, detail: providerError.localizedDescription)
            }
        }
        return CopilotFailure(.unknown, detail: error.localizedDescription)
    }

    private func statusText(for classification: CopilotIntentClassification, forceWeb: Bool) -> String {
        if forceWeb || classification.requiresWeb { return "Searching" }
        switch classification.preferredTool {
        case .calculator: return "Calculating"
        case .reminder: return "Scheduling"
        case .localMemory: return "Looking in history"
        case .webSearch: return "Searching"
        case .answerSynthesis, .unavailable: return "Preparing"
        }
    }

    private func meteredAudioStream(
        _ stream: AsyncStream<AudioBuffer>,
        conditioningTarget: AudioConditioningTarget = .nativeSpeech,
        source: TranscriptAudioSource = .microphone,
        preferences: AppPreferences? = nil
    ) -> AsyncStream<AudioBuffer> {
        let activePreferences = preferences ?? appState.preferences
        let processor = AudioConditioningStreamProcessor(source: source)
        let config = AudioConditioningConfig(
            accuracyMode: activePreferences.transcriptionAccuracyMode,
            target: conditioningTarget,
            audioSource: source
        )
        return AsyncStream { continuation in
            Task { [weak self] in
                for await buffer in stream {
                    let result = processor.condition(buffer, config: config)
                    let conditioned = result.buffer
                    await MainActor.run {
                        self?.pushAudioLevel(conditioned.rms)
                        self?.updateAmbientAudioStatus(for: conditioned)
                        if let snapshot = self?.failoverCoordinator.markAudio(conditioned) {
                            self?.appState.applyCopilotHealthSnapshot(snapshot)
                        }
                    }
                    continuation.yield(conditioned)
                }
                continuation.finish()
            }
        }
    }

    private func pushAudioLevel(_ rms: Float) {
        var levels = appState.copilotWaveformLevels
        if levels.count < 18 {
            levels = Array(repeating: 0.08, count: 18)
        }
        levels.removeFirst()
        let normalized = audioAnalyzer.normalizedLevel(from: rms)
        let previous = levels.last ?? normalized
        let smoothed = previous + (normalized - previous) * 0.42
        levels.append(smoothed)
        appState.copilotWaveformLevels = levels
        if appState.currentMeeting == nil {
            appState.waveformLevels = levels
        }
    }

    private func updateAmbientAudioStatus(for buffer: AudioBuffer) {
        guard buffer.rms > 0.006 else { return }
        let now = Date()
        guard now.timeIntervalSince(lastAudioStatusUpdate) > 1.6 else { return }
        lastAudioStatusUpdate = now
        if appState.currentMeeting == nil && appState.islandMode == .idle {
            appState.ambientCopilotStatus = "Listening"
        }
    }

    private func startASRWatchdog() {
        asrWatchdogTask?.cancel()
        asrWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.pollASRHealth()
            }
        }
    }

    private func pollASRHealth() async {
        guard isRunning, appState.currentMeeting == nil else { return }
        let (snapshot, action) = failoverCoordinator.poll()
        appState.applyCopilotHealthSnapshot(snapshot)
        switch action {
        case .none:
            break
        case .restartASR(let reason, let allowHybridRecognition):
            await restartAmbientASR(reason: reason, allowHybridRecognition: allowHybridRecognition)
        }
    }

    private func restartAmbientASR(reason: String, allowHybridRecognition: Bool) async {
        guard isPushToTalkActive, appState.currentMeeting == nil else { return }
        ambientAllowsHybridSpeechRecognition = ambientAllowsHybridSpeechRecognition || allowHybridRecognition
        AppLog.audio.info("Restarting ambient Notchly ASR: \(reason, privacy: .public)")
        asrWatchdogTask?.cancel()
        asrWatchdogTask = nil
        segmentTask?.cancel()
        segmentTask = nil
        if let service = activeTranscriptionService {
            await service.stop()
        }
        activeTranscriptionService = nil
        microphoneCaptureService.stopCapture()
        isRunning = false
        appState.applyCopilotHealthSnapshot(failoverCoordinator.markStopped(state: .asrUnstable, now: Date()))
        appState.setAmbientCopilotListening(false, status: CopilotHealthState.asrUnstable.displayText)
        try? await Task.sleep(nanoseconds: 350_000_000)
        evaluateRunningState()
    }

    private func ambientSegment(text: String, isFinal: Bool, confidence: Double) -> TranscriptSegment {
        TranscriptSegment(
            meetingId: ambientSession.id,
            speakerLabel: "You",
            audioSource: .microphone,
            text: text,
            originalLanguage: languageDetector.dominantLanguage(for: text),
            startTime: Date().timeIntervalSince(ambientSession.startedAt),
            endTime: Date().timeIntervalSince(ambientSession.startedAt),
            confidence: confidence,
            isFinal: isFinal
        )
    }

    private func ambientTranscriptionContext(preferences: AppPreferences) -> [String] {
        ambientSpeechContext(preferences: preferences).contextualStrings
    }

    private func ambientSpeechContext(preferences: AppPreferences) -> SpeechRecognitionContext {
        if let speechVocabularyStore = appState.speechVocabularyStore {
            return speechVocabularyStore.ambientSpeechContext(preferences: preferences)
        }
        let fallbackTerms = SpeechContextRanker().rank(
            [preferences.userDisplayName] + preferences.userNicknames.split(separator: ",").map(String.init)
        )
            .map { SpeechContextTerm(text: $0, locale: nil, category: .custom, weight: 1, pronunciationXSAMPA: nil, source: "ambient") }
        return SpeechRecognitionContext(
            locale: SupportedLanguage.normalizedCode(preferences.defaultLanguage),
            terms: fallbackTerms,
            customLanguageModelEnabled: false,
            status: "Using contextual hints only"
        )
    }

    private func userMeetingProfile(preferences: AppPreferences, meeting: MeetingSession) -> UserMeetingProfile {
        UserMeetingProfile(
            userName: preferences.userDisplayName,
            userAliases: ([preferences.userDisplayName] + preferences.userNicknames.split(separator: ",").map { String($0) })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
            userRole: preferences.userRole,
            preferredStyle: .concise,
            preferredLanguages: [preferences.defaultLanguage, meeting.primaryLanguage].compactMap { $0 },
            meetingType: meeting.meetingType
        )
    }
}

struct CopilotLLMIntentAndAnswerResponse: Codable, Hashable, Sendable {
    struct ReminderAction: Codable, Hashable, Sendable {
        var title: String?
        var notificationTitle: String?
        var notificationBody: String?
        var scheduledAtISO8601: String?

        var resolvedTitle: String? {
            let value = notificationTitle ?? title
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }

        var resolvedBody: String? {
            let value = notificationBody ?? notificationTitle ?? title
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    enum CodingKeys: String, CodingKey {
        case shouldRespond
        case intent
        case needsWeb
        case needsReminderAction
        case needsClarification
        case answerFormat
        case answerText
        case richAnswer
        case confidence
        case reason
        case reminderAction
    }

    var shouldRespond: Bool
    var intent: String
    var needsWeb: Bool
    var needsReminderAction: Bool
    var needsClarification: Bool
    var answerFormat: String
    var answerText: String
    var richAnswer: RichAnswerPayload? = nil
    var confidence: Double
    var reason: String
    var reminderAction: ReminderAction?

    init(
        shouldRespond: Bool,
        intent: String,
        needsWeb: Bool,
        needsReminderAction: Bool,
        needsClarification: Bool,
        answerFormat: String,
        answerText: String,
        richAnswer: RichAnswerPayload? = nil,
        confidence: Double,
        reason: String,
        reminderAction: ReminderAction?
    ) {
        self.shouldRespond = shouldRespond
        self.intent = intent
        self.needsWeb = needsWeb
        self.needsReminderAction = needsReminderAction
        self.needsClarification = needsClarification
        self.answerFormat = answerFormat
        self.answerText = answerText
        self.richAnswer = richAnswer
        self.confidence = confidence
        self.reason = reason
        self.reminderAction = reminderAction
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedRichAnswer = try container.decodeIfPresent(RichAnswerPayload.self, forKey: .richAnswer)
        let decodedAnswerText = try container.decodeIfPresent(String.self, forKey: .answerText) ?? ""

        self.richAnswer = decodedRichAnswer
        self.answerText = decodedAnswerText
        self.shouldRespond = try container.decodeIfPresent(Bool.self, forKey: .shouldRespond) ?? (!decodedAnswerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || decodedRichAnswer != nil)
        self.intent = try container.decodeIfPresent(String.self, forKey: .intent) ?? "answerable_question"
        self.needsWeb = try container.decodeIfPresent(Bool.self, forKey: .needsWeb) ?? false
        self.needsReminderAction = try container.decodeIfPresent(Bool.self, forKey: .needsReminderAction) ?? false
        self.needsClarification = try container.decodeIfPresent(Bool.self, forKey: .needsClarification) ?? false
        self.answerFormat = try container.decodeIfPresent(String.self, forKey: .answerFormat) ?? Self.inferredAnswerFormat(from: decodedRichAnswer)
        self.confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0.80
        self.reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? "decoded_with_defaults"
        self.reminderAction = try container.decodeIfPresent(ReminderAction.self, forKey: .reminderAction)
    }

    func resolvedIntent(fallback: CopilotIntentKind) -> CopilotIntentKind {
        CopilotIntentKind(rawValue: intent) ?? fallback
    }

    func resolvedFormat(fallback: CopilotAnswerFormat) -> CopilotAnswerFormat {
        CopilotAnswerFormat(rawValue: answerFormat) ?? fallback
    }

    func resolvedTool(fallback: CopilotToolKind) -> CopilotToolKind {
        switch resolvedIntent(fallback: .ambiguous) {
        case .webSearch, .newsSearch:
            return .webSearch
        case .reminder:
            return .reminder
        case .memoryLookup:
            return .localMemory
        case .calculation, .conversion, .answerableQuestion, .actionRequest, .ambiguous:
            return .answerSynthesis
        case .statement, .smallTalk, .ambientNoise:
            return .unavailable
        }
    }

    func normalizedForPresentation(sources: [AnswerSource]) -> CopilotLLMIntentAndAnswerResponse {
        var copy = self
        if copy.answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.answerText = Self.derivedAnswerText(from: copy.richAnswer, sources: sources)
        }
        if CopilotAnswerFormat(rawValue: copy.answerFormat) == nil {
            copy.answerFormat = Self.inferredAnswerFormat(from: copy.richAnswer)
        }
        return copy
    }

    private static func inferredAnswerFormat(from richAnswer: RichAnswerPayload?) -> String {
        guard let type = richAnswer?.blocks.first?.type,
              let kind = RichAnswerBlockKind(rawValue: type) else {
            return CopilotAnswerFormat.paragraph.rawValue
        }
        switch kind {
        case .steps:
            return CopilotAnswerFormat.steps.rawValue
        case .checklist:
            return CopilotAnswerFormat.bullets.rawValue
        case .metrics:
            return CopilotAnswerFormat.calculation.rawValue
        case .sourceCards:
            return CopilotAnswerFormat.newsWithSources.rawValue
        case .memoryResults:
            return CopilotAnswerFormat.memoryResults.rawValue
        case .code:
            return CopilotAnswerFormat.code.rawValue
        case .warning:
            return CopilotAnswerFormat.errorState.rawValue
        case .lead:
            return CopilotAnswerFormat.plainShort.rawValue
        case .paragraph, .comparison, .timeline, .clarification, .actions:
            return CopilotAnswerFormat.paragraph.rawValue
        }
    }

    private static func derivedAnswerText(from richAnswer: RichAnswerPayload?, sources: [AnswerSource]) -> String {
        guard let payload = RichAnswerValidator().validated(richAnswer, sources: sources) else { return "" }
        let pieces = payload.blocks.compactMap { blockText($0, sources: sources) }
        let text = pieces.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > 2_400 else { return text }
        return String(text.prefix(2_400)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private static func blockText(_ block: RichAnswerBlockPayload, sources: [AnswerSource]) -> String? {
        switch RichAnswerBlockKind(rawValue: block.type) {
        case .lead, .paragraph, .clarification, .warning:
            return titledText(title: block.title, text: block.text)
        case .steps, .timeline:
            return itemListText(title: block.title, items: block.items, numbered: true)
        case .checklist, .comparison, .memoryResults:
            return itemListText(title: block.title, items: block.items, numbered: false)
        case .metrics:
            let metric = [
                block.label,
                block.value,
                block.formula.map { "(\($0))" },
                block.text
            ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            return titledText(title: block.title, text: metric)
        case .code:
            guard let code = block.code?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty else { return nil }
            let language = block.language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return "```\(language)\n\(code)\n```"
        case .sourceCards:
            let titles = block.sourceIndexes.compactMap { index -> String? in
                guard sources.indices.contains(index) else { return nil }
                return sources[index].title.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !titles.isEmpty else { return block.title }
            return titledText(title: block.title ?? "Fontes", text: titles.map { "- \($0)" }.joined(separator: "\n"))
        case .actions, .none:
            return nil
        }
    }

    private static func titledText(title: String?, text: String?) -> String? {
        let cleanedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedText = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (cleanedTitle?.isEmpty == false ? cleanedTitle : nil, cleanedText?.isEmpty == false ? cleanedText : nil) {
        case let (title?, text?):
            return "\(title)\n\(text)"
        case let (title?, nil):
            return title
        case let (nil, text?):
            return text
        case (nil, nil):
            return nil
        }
    }

    private static func itemListText(title: String?, items: [RichAnswerItemPayload], numbered: Bool) -> String? {
        let rows = items.enumerated().compactMap { index, item -> String? in
            let body = [
                item.title,
                item.text.isEmpty ? nil : item.text,
                item.detail
            ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ": ")
            guard !body.isEmpty else { return nil }
            return numbered ? "\(index + 1). \(body)" : "- \(body)"
        }
        guard !rows.isEmpty else { return titledText(title: title, text: nil) }
        return titledText(title: title, text: rows.joined(separator: "\n"))
    }
}

struct CopilotLLMDecisionResult: Sendable, Hashable {
    var decision: CopilotLLMIntentAndAnswerResponse
    var raw: LLMRawResponse
    var selectedFrame: SpeechCandidateFrame

    var shouldPresent: Bool {
        decision.needsClarification || decision.shouldRespond
    }
}

struct ReminderActionResult: Sendable, Hashable {
    var notificationId: String
    var title: String
    var body: String
    var scheduledAt: Date
}

enum CopilotClarificationPolicy {
    static func adjustedDecision(
        _ decision: CopilotLLMIntentAndAnswerResponse,
        frame: SpeechCandidateFrame,
        source: CopilotRuntimeSource
    ) -> CopilotLLMIntentAndAnswerResponse {
        guard decision.needsClarification,
              shouldAnswerWithAssumptions(
                text: frame.text,
                source: source,
                asrConfidence: frame.asrConfidence,
                languageConfidence: frame.languageConfidence,
                stability: frame.stability,
                intent: decision.resolvedIntent(fallback: .ambiguous),
                needsReminderAction: decision.needsReminderAction
              )
        else {
            return decision
        }

        var copy = decision
        copy.shouldRespond = true
        copy.needsClarification = false
        copy.answerText = ""
        if copy.resolvedIntent(fallback: .ambiguous) == .ambiguous {
            copy.intent = inferredIntent(for: frame.text).rawValue
        }
        if CopilotAnswerFormat(rawValue: copy.answerFormat) == nil || copy.answerFormat == CopilotAnswerFormat.plainShort.rawValue {
            copy.answerFormat = inferredFormat(for: frame.text).rawValue
        }
        copy.reason = "answer_with_reasonable_defaults"
        return copy
    }

    static func shouldRetryFinalAnswerWithoutClarification(
        _ response: CopilotLLMIntentAndAnswerResponse,
        candidate: QuestionCandidate,
        decision: CopilotLLMIntentAndAnswerResponse
    ) -> Bool {
        response.needsClarification &&
            shouldAnswerWithAssumptions(
                text: candidate.rawText,
                source: nil,
                asrConfidence: nil,
                languageConfidence: nil,
                stability: nil,
                intent: decision.resolvedIntent(fallback: .answerableQuestion),
                needsReminderAction: decision.needsReminderAction
            )
    }

    static func inferredFormat(for text: String) -> CopilotAnswerFormat {
        let normalized = normalized(text)
        if containsAny(normalized, ["passo a passo", "plano", "roteiro", "etapas", "steps", "plan"]) {
            return .steps
        }
        if containsAny(normalized, ["checklist", "lista de tarefas", "validar", "conferir"]) {
            return .bullets
        }
        if containsAny(normalized, ["compare", "comparar", "versus", "vs", "pros", "contras", "recomende"]) {
            return .bullets
        }
        if containsAny(normalized, ["calcule", "calcular", "quanto", "quantos", "converta", "converter", "%", "por cento"]) {
            return .calculation
        }
        if containsAny(normalized, ["codigo", "script", "swift", "python", "sql", "json", "yaml"]) {
            return .code
        }
        if containsAny(normalized, ["noticias", "fontes", "web", "busque", "procure", "current", "news", "sources", "search"]) {
            return .newsWithSources
        }
        return .paragraph
    }

    private static func shouldAnswerWithAssumptions(
        text: String,
        source: CopilotRuntimeSource?,
        asrConfidence: Double?,
        languageConfidence: Double?,
        stability: Double?,
        intent: CopilotIntentKind,
        needsReminderAction: Bool
    ) -> Bool {
        let normalizedText = normalized(text)
        guard normalizedText.count >= 12 else { return false }
        if intent == .reminder || needsReminderAction { return false }
        if [.statement, .smallTalk, .ambientNoise].contains(intent) { return false }
        if source != .typed && source != .shortcut {
            if (asrConfidence ?? 1) < 0.62 || (languageConfidence ?? 1) < 0.45 || (stability ?? 1) < 0.50 {
                return false
            }
        }
        return hasTaskSignal(normalizedText) || hasQuestionSignal(normalizedText)
    }

    private static func inferredIntent(for text: String) -> CopilotIntentKind {
        let normalizedText = normalized(text)
        if containsAny(normalizedText, ["noticias", "hoje", "atual", "recentes", "news", "current"]) {
            return .newsSearch
        }
        if containsAny(normalizedText, ["busque", "procure", "web", "fontes", "search", "sources"]) {
            return .webSearch
        }
        if containsAny(normalizedText, ["calcule", "calcular", "converta", "converter", "%", "por cento"]) {
            return .calculation
        }
        return .answerableQuestion
    }

    private static func hasTaskSignal(_ text: String) -> Bool {
        containsAny(text, [
            "monte", "crie", "gere", "resuma", "explique", "liste", "compare", "calcule", "converta",
            "organize", "planeje", "escreva", "prepare", "analise", "sugira", "recomende", "busque",
            "procure", "me ajude", "ajude", "make", "create", "generate", "summarize", "explain",
            "list", "compare", "calculate", "convert", "organize", "plan", "write", "prepare",
            "analyze", "suggest", "recommend", "search", "help"
        ])
    }

    private static func hasQuestionSignal(_ text: String) -> Bool {
        text.count >= 18 && containsAny(text, [
            "qual", "quais", "como", "por que", "porque", "quando", "onde", "quanto", "quantos",
            "what", "which", "how", "why", "when", "where"
        ])
    }

    private static func containsAny(_ text: String, _ tokens: [String]) -> Bool {
        tokens.contains { text.contains($0) }
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
struct CopilotLLMDecisionService {
    var provider: any AIProvider
    var privacyGuard = PrivacyGuard()

    func decide(
        frames: [SpeechCandidateFrame],
        transcriptContext: TranscriptContext,
        meeting: MeetingSession,
        preferences: AppPreferences,
        source: CopilotRuntimeSource,
        forceWeb: Bool
    ) async throws -> CopilotLLMDecisionResult {
        guard let selected = CopilotSpeechFrameSelector.bestFrame(in: frames, context: transcriptContext, preferences: preferences) else {
            throw CopilotFailure(.contextInsufficient)
        }
        let prompt = Self.decisionPrompt(
            frames: frames,
            transcriptContext: transcriptContext,
            meeting: meeting,
            preferences: preferences,
            source: source,
            forceWeb: forceWeb,
            privacyGuard: privacyGuard
        )
        let raw = try await CopilotLLMJSONExchange.generate(
            provider: provider,
            prompt: prompt,
            maxOutputTokens: 700,
            enableWebSearch: false,
            privacyGuard: privacyGuard
        )
        let decodedDecision = try CopilotLLMJSONExchange.decode(CopilotLLMIntentAndAnswerResponse.self, from: raw.text)
        let decision = CopilotClarificationPolicy.adjustedDecision(decodedDecision, frame: selected, source: source)
        let threshold = source == .typed || source == .shortcut ? 0.70 : 0.80
        if decision.shouldRespond, !decision.needsClarification, decision.confidence < threshold {
            let rejected = CopilotLLMIntentAndAnswerResponse(
                shouldRespond: false,
                intent: decision.intent,
                needsWeb: false,
                needsReminderAction: false,
                needsClarification: false,
                answerFormat: "plain_short",
                answerText: "",
                confidence: decision.confidence,
                reason: "below_confidence_threshold",
                reminderAction: nil
            )
            return CopilotLLMDecisionResult(decision: rejected, raw: raw, selectedFrame: selected)
        }
        return CopilotLLMDecisionResult(decision: decision, raw: raw, selectedFrame: selected)
    }

    private static func decisionPrompt(
        frames: [SpeechCandidateFrame],
        transcriptContext: TranscriptContext,
        meeting: MeetingSession,
        preferences: AppPreferences,
        source: CopilotRuntimeSource,
        forceWeb: Bool,
        privacyGuard: PrivacyGuard
    ) -> String {
        let now = ISO8601DateFormatter().string(from: Date())
        let rankedFrames = frames.sorted {
            CopilotSpeechFrameSelector.score($0, context: transcriptContext, preferences: preferences) >
                CopilotSpeechFrameSelector.score($1, context: transcriptContext, preferences: preferences)
        }
        let framePayload = CopilotLLMJSONExchange.jsonString(rankedFrames.prefix(6).enumerated().map { index, frame in
            [
                "index": index,
                "text": privacyGuard.redact(frame.text),
                "source": frame.source.rawValue,
                "languageCode": frame.languageCode ?? "",
                "asrConfidence": frame.asrConfidence,
                "languageConfidence": frame.languageConfidence ?? 0,
                "stability": frame.stability,
                "combinedConfidence": frame.combinedConfidence,
                "selectorScore": CopilotSpeechFrameSelector.score(frame, context: transcriptContext, preferences: preferences),
                "preferred": index == 0,
                "isFinal": frame.isFinal,
                "repairReason": frame.repairReason ?? ""
            ] as [String: Any]
        })
        return """
        You are the silent intent gate for a live desktop Copilot. Decide whether the user is asking Copilot to help right now.
        Return exactly one valid JSON object.

        Required JSON:
        {
          "shouldRespond": false,
          "intent": "answerable_question | action_request | web_search | news_search | calculation | conversion | reminder | memory_lookup | ambiguous | statement | small_talk | ambient_noise",
          "needsWeb": false,
          "needsReminderAction": false,
          "needsClarification": false,
          "answerFormat": "plain_short | paragraph | steps | bullets | calculation | news_with_sources | reminder_confirmation | memory_results | code | error_state",
          "answerText": "",
          "confidence": 0.0,
          "reason": "brief reason",
          "reminderAction": {
            "title": null,
            "notificationTitle": null,
            "notificationBody": null,
            "scheduledAtISO8601": null
          }
        }

        Decision policy:
        - Say shouldRespond true only for a clear useful request/question directed at an assistant.
        - Say false for ambient conversation, statements, fragments, small talk, operational checks, and unclear speech.
        - Default to action: if the request is useful but underspecified, set shouldRespond true and let the final answer make reasonable assumptions.
        - Do not ask for preferences, audience, format, examples, scope, or extra specificity when a normal useful answer can be produced.
        - Use needsClarification true only when a required entity/date/time/action target is missing, the request is impossible to identify, or ASR is too uncertain to know what the user asked.
        - For current events, news, prices, or anything requiring fresh information, set needsWeb true.
        - For reminders, set needsReminderAction true only when exact notification title/body and ISO-8601 scheduled time are clear.
        - Do not produce a final factual answer in this decision phase except clarification text.

        Current date/time: \(now)
        Source: \(source.rawValue)
        Force web: \(forceWeb)
        User role: \(preferences.userRole)
        Meeting/session title: \(meeting.title)
        Recent transcript context:
        \(privacyGuard.redact(transcriptContext.recentTranscript))

        Candidate lattice:
        \(framePayload)
        """
    }
}

@MainActor
struct CopilotLLMFinalAnswerService {
    var provider: any AIProvider
    var privacyGuard = PrivacyGuard()
    var finalAnswerTimeoutSeconds: TimeInterval = 35

    func generate(
        candidate: QuestionCandidate,
        decision: CopilotLLMIntentAndAnswerResponse,
        transcriptContext: TranscriptContext,
        meeting: MeetingSession,
        preferences: AppPreferences,
        sources: [AnswerSource],
        reminderResult: ReminderActionResult?,
        enableWebSearch: Bool
    ) async throws -> (response: CopilotLLMIntentAndAnswerResponse, raw: LLMRawResponse) {
        try await runWithTimeout(seconds: finalAnswerTimeoutSeconds) {
            try await generateWithoutTimeout(
                candidate: candidate,
                decision: decision,
                transcriptContext: transcriptContext,
                meeting: meeting,
                preferences: preferences,
                sources: sources,
                reminderResult: reminderResult,
                enableWebSearch: enableWebSearch
            )
        }
    }

    private func generateWithoutTimeout(
        candidate: QuestionCandidate,
        decision: CopilotLLMIntentAndAnswerResponse,
        transcriptContext: TranscriptContext,
        meeting: MeetingSession,
        preferences: AppPreferences,
        sources: [AnswerSource],
        reminderResult: ReminderActionResult?,
        enableWebSearch: Bool
    ) async throws -> (response: CopilotLLMIntentAndAnswerResponse, raw: LLMRawResponse) {
        let prompt = Self.answerPrompt(
            candidate: candidate,
            decision: decision,
            transcriptContext: transcriptContext,
            meeting: meeting,
            preferences: preferences,
            sources: sources,
            reminderResult: reminderResult,
            privacyGuard: privacyGuard
        )
        let raw: LLMRawResponse
        do {
            raw = try await CopilotLLMJSONExchange.generate(
                provider: provider,
                prompt: prompt,
                maxOutputTokens: 2_200,
                enableWebSearch: enableWebSearch,
                privacyGuard: privacyGuard
            )
        } catch {
            if Self.canRecoverWithDeterministicFallback(from: error) {
                return deterministicFallback(
                    candidate: candidate,
                    decision: decision,
                    preferences: preferences,
                    sources: sources,
                    raw: nil,
                    reason: "provider_returned_invalid_final_answer"
                )
            }
            throw error
        }

        var response: CopilotLLMIntentAndAnswerResponse
        do {
            response = try CopilotLLMJSONExchange.decode(CopilotLLMIntentAndAnswerResponse.self, from: raw.text)
                .normalizedForPresentation(sources: sources + raw.sources)
        } catch {
            if let plainText = Self.displayablePlainText(from: raw.text) {
                return plainTextFallback(
                    plainText,
                    candidate: candidate,
                    decision: decision,
                    sources: sources + raw.sources,
                    raw: raw
                )
            }
            return deterministicFallback(
                candidate: candidate,
                decision: decision,
                preferences: preferences,
                sources: sources + raw.sources,
                raw: raw,
                reason: "could_not_decode_final_answer"
            )
        }
        var selectedRaw = raw

        if CopilotClarificationPolicy.shouldRetryFinalAnswerWithoutClarification(response, candidate: candidate, decision: decision),
           let retry = try? await generateAssumptiveRetry(
            provider: provider,
            prompt: prompt,
            maxOutputTokens: 2_200,
            enableWebSearch: enableWebSearch,
            privacyGuard: privacyGuard,
            sources: sources + raw.sources
           ) {
            response = retry.response
            selectedRaw = retry.raw
        }

        guard response.shouldRespond || response.needsClarification else {
            throw CopilotFailure(.contextInsufficient, detail: response.reason)
        }
        guard !response.answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return deterministicFallback(
                candidate: candidate,
                decision: decision,
                preferences: preferences,
                sources: sources + selectedRaw.sources,
                raw: selectedRaw,
                reason: "empty_final_answer"
            )
        }
        return (response, selectedRaw)
    }

    private func runWithTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        let task = Task { @MainActor in
            try await operation()
        }
        let timeoutTask = Task {
            let timeout = UInt64(max(seconds, 0.1) * 1_000_000_000)
            try await Task.sleep(nanoseconds: timeout)
            task.cancel()
        }
        do {
            let value = try await task.value
            timeoutTask.cancel()
            return value
        } catch {
            timeoutTask.cancel()
            if error is CancellationError {
                throw CopilotFailure(.answerTimedOut)
            }
            throw error
        }
    }

    private static func canRecoverWithDeterministicFallback(from error: Error) -> Bool {
        if let providerError = error as? AIProviderError {
            switch providerError {
            case .invalidResponse:
                return true
            case .cloudDisabled, .providerUnavailable:
                return false
            }
        }
        if let failure = error as? CopilotFailure {
            return failure.kind == .emptyResponse
        }
        return false
    }

    private func plainTextFallback(
        _ text: String,
        candidate: QuestionCandidate,
        decision: CopilotLLMIntentAndAnswerResponse,
        sources: [AnswerSource],
        raw: LLMRawResponse
    ) -> (response: CopilotLLMIntentAndAnswerResponse, raw: LLMRawResponse) {
        let format = decision.resolvedFormat(fallback: .paragraph)
        let response = CopilotLLMIntentAndAnswerResponse(
            shouldRespond: true,
            intent: decision.intent,
            needsWeb: false,
            needsReminderAction: false,
            needsClarification: false,
            answerFormat: format.rawValue,
            answerText: text,
            richAnswer: RichAnswerFallbackBuilder.payload(
                text: text,
                format: format,
                sources: sources,
                confidence: max(min(decision.confidence, 1), 0.55),
                riskLevel: .safe
            ),
            confidence: max(min(decision.confidence, 1), 0.55),
            reason: "plain_text_final_answer_recovered",
            reminderAction: nil
        )
        return (response, raw)
    }

    private func deterministicFallback(
        candidate: QuestionCandidate,
        decision: CopilotLLMIntentAndAnswerResponse,
        preferences: AppPreferences,
        sources: [AnswerSource],
        raw: LLMRawResponse?,
        reason: String
    ) -> (response: CopilotLLMIntentAndAnswerResponse, raw: LLMRawResponse) {
        let format = decision.resolvedFormat(fallback: .paragraph)
        let text = Self.deterministicFallbackText(
            candidate: candidate,
            decision: decision,
            format: format
        )
        let response = CopilotLLMIntentAndAnswerResponse(
            shouldRespond: true,
            intent: decision.intent,
            needsWeb: false,
            needsReminderAction: false,
            needsClarification: false,
            answerFormat: format.rawValue,
            answerText: text,
            richAnswer: RichAnswerFallbackBuilder.payload(
                text: text,
                format: format,
                sources: sources,
                confidence: max(min(decision.confidence, 1), 0.55),
                riskLevel: .moderate
            ),
            confidence: max(min(decision.confidence, 1), 0.55),
            reason: reason,
            reminderAction: nil
        )
        let fallbackRaw = LLMRawResponse(
            text: text,
            provider: raw?.provider ?? provider.name,
            usedCloud: raw?.usedCloud ?? !preferences.localOnlyMode,
            sources: raw?.sources ?? []
        )
        return (response, fallbackRaw)
    }

    private static func displayablePlainText(from rawText: String) -> String? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return nil
        }
        let withoutFence = trimmed
            .replacingOccurrences(of: #"^```(?:text|markdown|md)?\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !withoutFence.isEmpty else { return nil }
        guard withoutFence.count > 2_400 else { return withoutFence }
        return String(withoutFence.prefix(2_400)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private static func deterministicFallbackText(
        candidate: QuestionCandidate,
        decision: CopilotLLMIntentAndAnswerResponse,
        format: CopilotAnswerFormat
    ) -> String {
        let rawRequest = candidate.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = rawRequest.isEmpty ? "este pedido" : rawRequest
        let lowerLanguage = (candidate.language ?? "").lowercased()
        let isPortuguese = lowerLanguage.hasPrefix("pt") || QuestionDetectionService.normalize(request).contains("monte")
        let needsFreshData = decision.needsWeb || format == .newsWithSources

        if isPortuguese {
            if needsFreshData {
                return "Nao consegui consolidar uma resposta confiavel do provedor externo agora. Refaca o pedido com busca web ativada para eu tentar novamente com fontes atualizadas."
            }
            switch format {
            case .steps, .bullets:
                return """
                Nao consegui recuperar a resposta estruturada do modelo, mas mantive o fluxo ativo. Para "\(request)", comece assim:
                1. Defina o objetivo principal em uma frase.
                2. Liste os pontos que precisam mudar, decidir ou validar.
                3. Priorize as 3 acoes de maior impacto.
                4. Execute um teste pequeno e registre o resultado.
                5. Revise o que funcionou e ajuste o proximo passo.
                """
            case .calculation:
                return "Nao consegui validar o calculo retornado pelo modelo. Refaca o pedido com os valores principais e eu tento novamente."
            case .code:
                return "Nao consegui recuperar um bloco de codigo confiavel para este pedido. Refaca o pedido ou peca uma versao menor para eu regenerar."
            default:
                return "Nao consegui recuperar a resposta final do modelo, mas o pedido foi entendido: \(request). Tente novamente em instantes para eu regenerar a resposta completa."
            }
        }

        if needsFreshData {
            return "I could not assemble a reliable external-source answer right now. Try the request again with web search enabled so I can regenerate it with fresh sources."
        }
        switch format {
        case .steps, .bullets:
            return """
            I could not recover the model's structured answer, but the request was understood. For "\(request)", start here:
            1. Define the main goal in one sentence.
            2. List what needs to change, be decided, or be validated.
            3. Prioritize the 3 highest-impact actions.
            4. Run a small test and capture the result.
            5. Review what worked and adjust the next step.
            """
        case .calculation:
            return "I could not validate the calculation returned by the model. Try again with the key values and I will regenerate it."
        case .code:
            return "I could not recover a reliable code block for this request. Try again or ask for a smaller version so I can regenerate it."
        default:
            return "I could not recover the model's final answer, but the request was understood: \(request). Try again in a moment and I will regenerate the full response."
        }
    }

    private func generateAssumptiveRetry(
        provider: any AIProvider,
        prompt: String,
        maxOutputTokens: Int,
        enableWebSearch: Bool,
        privacyGuard: PrivacyGuard,
        sources: [AnswerSource]
    ) async throws -> (response: CopilotLLMIntentAndAnswerResponse, raw: LLMRawResponse) {
        let retryPrompt = """
        \(prompt)

        Important correction:
        The previous output asked a clarification. Do not ask a follow-up question for this request.
        Produce the best useful answer now using reasonable everyday assumptions. State the assumption briefly inside answerText when it matters.
        Keep needsClarification false unless the request is impossible or unsafe to answer.
        """
        let retryRaw = try await CopilotLLMJSONExchange.generate(
            provider: provider,
            prompt: retryPrompt,
            maxOutputTokens: maxOutputTokens,
            enableWebSearch: enableWebSearch,
            privacyGuard: privacyGuard
        )
        let retryResponse = try CopilotLLMJSONExchange.decode(CopilotLLMIntentAndAnswerResponse.self, from: retryRaw.text)
            .normalizedForPresentation(sources: sources + retryRaw.sources)
        guard !retryResponse.needsClarification else {
            throw CopilotFailure(.contextInsufficient, detail: retryResponse.reason)
        }
        return (retryResponse, retryRaw)
    }

    private static func answerPrompt(
        candidate: QuestionCandidate,
        decision: CopilotLLMIntentAndAnswerResponse,
        transcriptContext: TranscriptContext,
        meeting: MeetingSession,
        preferences: AppPreferences,
        sources: [AnswerSource],
        reminderResult: ReminderActionResult?,
        privacyGuard: PrivacyGuard
    ) -> String {
        let now = ISO8601DateFormatter().string(from: Date())
        let sourcePayload = CopilotLLMJSONExchange.jsonString(sources.map { source in
            [
                "type": source.type.rawValue,
                "title": source.title,
                "snippet": source.snippet ?? "",
                "url": source.reference ?? ""
            ]
        })
        let reminderPayload: String
        if let reminderResult {
            reminderPayload = CopilotLLMJSONExchange.jsonString([
                "notificationId": reminderResult.notificationId,
                "title": reminderResult.title,
                "body": reminderResult.body,
                "scheduledAtISO8601": ISO8601DateFormatter().string(from: reminderResult.scheduledAt)
            ])
        } else {
            reminderPayload = "null"
        }
        return """
        You are the final answer writer for the live Copilot. Produce the user-visible answer only through JSON.
        Return exactly one valid JSON object.

        Required JSON:
        {
          "shouldRespond": true,
          "intent": "\(decision.intent)",
          "needsWeb": false,
          "needsReminderAction": false,
          "needsClarification": false,
          "answerFormat": "plain_short | paragraph | steps | bullets | calculation | news_with_sources | reminder_confirmation | memory_results | code | error_state",
          "answerText": "final user-visible answer in the user's language",
          "richAnswer": {
            "version": 1,
            "blocks": [
              {
                "type": "lead | paragraph | sourceCards | steps | checklist | comparison | metrics | code | timeline | memoryResults | clarification | warning | actions",
                "title": "optional compact title",
                "subtitle": "optional compact subtitle",
                "text": "optional readable text",
                "label": "optional metric label",
                "value": "optional metric value",
                "formula": "optional formula",
                "language": "optional code language",
                "code": "optional code without fences",
                "severity": "info | caution | error",
                "items": [{"title": "optional", "text": "item text", "detail": "optional", "value": "optional", "isChecked": false, "sourceIndex": 0}],
                "sourceIndexes": [0],
                "actions": [{"kind": "copy | open_sources | regenerate_with_web", "title": "Copy"}]
              }
            ]
          },
          "confidence": 0.0,
          "reason": "brief reason",
          "reminderAction": null
        }

        Rules:
        - Do all reasoning dynamically. Do not rely on prewritten local answers.
        - Default to answering. If the request is underspecified but common, choose sensible everyday defaults and continue.
        - Do not ask for audience, format, scope, examples, preferences, or extra specificity unless the user explicitly asks you to ask.
        - If you assume something, state it briefly and provide the useful answer.
        - Always return a non-empty answerText, even when richAnswer contains the full visual layout.
        - answerText is the compact plain-text fallback for history, accessibility, copy, and invalid rich UI.
        - For each richAnswer block, include only the fields that matter for that block.
        - Math, dates, conversions, and factual answers must be produced by the LLM.
        - Use code format only for actual code, commands, logs, SQL, JSON/YAML/XML, diffs, or explicitly technical code output.
        - If sources are provided, use sourceIndexes in richAnswer instead of pasting raw URLs in answerText.
        - For news/current events, prefer sourceCards plus one short paragraph.
        - For calculations/conversions, prefer metrics.
        - For procedures, prefer steps. For trade-offs, prefer comparison. For local context, prefer memoryResults.
        - Keep richAnswer compact: at most 6 blocks, 6 source cards, 6 items per block.
        - Only reference source indexes that exist in Sources. Do not invent URLs or sources.
        - Use actions only for copy, open_sources, or regenerate_with_web.
        - If reminderResult is present, confirm the scheduled native notification based on that result.
        - Set needsClarification true only when a required concrete value is missing for an irreversible/actionable operation, or the request is impossible/unsafe to answer.

        Current date/time: \(now)
        User request: \(privacyGuard.redact(candidate.rawText))
        Decision JSON: \(CopilotLLMJSONExchange.jsonString([
            "intent": decision.intent,
            "needsWeb": decision.needsWeb,
            "needsReminderAction": decision.needsReminderAction,
            "needsClarification": decision.needsClarification,
            "confidence": decision.confidence,
            "reason": decision.reason
        ]))
        User role: \(preferences.userRole)
        Session title: \(meeting.title)
        Recent transcript:
        \(privacyGuard.redact(transcriptContext.recentTranscript))
        Sources:
        \(sourcePayload)
        Reminder action result:
        \(reminderPayload)
        """
    }
}

@MainActor
enum CopilotLLMJSONExchange {
    static func generate(
        provider: any AIProvider,
        prompt: String,
        maxOutputTokens: Int,
        enableWebSearch: Bool,
        privacyGuard: PrivacyGuard
    ) async throws -> LLMRawResponse {
        let request = LLMRawRequest(
            prompt: prompt,
            maxOutputTokens: maxOutputTokens,
            responseMode: .jsonObject,
            enableWebSearch: enableWebSearch
        )
        let raw = try await provider.generateRaw(request: request)
        do {
            _ = try decode(CopilotLLMIntentAndAnswerResponse.self, from: raw.text)
            return raw
        } catch {
            let repairPrompt = """
            Convert the following model output into exactly one valid JSON object matching the requested Copilot schema.
            Preserve all semantic values. Return JSON only.

            Output:
            \(privacyGuard.redact(raw.text))
            """
            return try await provider.generateRaw(request: LLMRawRequest(
                prompt: repairPrompt,
                maxOutputTokens: maxOutputTokens,
                responseMode: .jsonObject,
                enableWebSearch: false
            ))
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonText: String
        if trimmed.hasPrefix("```") {
            jsonText = trimmed
                .replacingOccurrences(of: #"^```(?:json)?\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
        } else if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start <= end {
            jsonText = String(trimmed[start...end])
        } else {
            jsonText = trimmed
        }
        guard let data = jsonText.data(using: .utf8) else {
            throw AIProviderError.invalidResponse
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw AIProviderError.invalidResponse
        }
    }

    static func jsonString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return string
    }
}

@MainActor
struct CopilotToolRouter {
    var repository: MeetingRepository
    var providerRouter: ProviderRouter
    var knowledgeStore: LocalKnowledgeStore
    var preferences: AppPreferences
    var privacyGuard = PrivacyGuard()
    var urlSession: URLSession = OpenAIURLSessionFactory.makeSecureSession()

    func answer(
        candidate: QuestionCandidate,
        questionClassification: QuestionClassification,
        copilotClassification: CopilotIntentClassification,
        decision: CopilotLLMIntentAndAnswerResponse,
        transcriptContext: TranscriptContext,
        meeting: MeetingSession,
        source: CopilotRuntimeSource,
        forceWeb: Bool = false
    ) async throws -> (answer: SuggestedAnswer, interaction: CopilotInteraction) {
        let startedAt = Date()
        let provider = providerRouter.aiProvider(preferences: preferences)
        let requestedTool = normalizedRequestedTool(forceWeb ? .webSearch : decision.resolvedTool(fallback: copilotClassification.preferredTool))
        let contextSources = try await contextSources(
            for: requestedTool,
            candidate: candidate,
            decision: decision
        )
        let webRequested = decision.needsWeb || forceWeb
        let hasWebSources = contextSources.contains { $0.type == .web }
        let nativeWebProvider = webRequested && !hasWebSources
            ? providerRouter.copilotNativeWebProvider(preferences: preferences, primaryProvider: provider)
            : nil
        if webRequested, !hasWebSources, nativeWebProvider == nil {
            throw CopilotFailure(.webProviderUnavailable)
        }
        let answerProvider = nativeWebProvider ?? provider
        let enableNativeWeb = nativeWebProvider != nil

        let reminderResult: ReminderActionResult?
        if decision.needsReminderAction {
            reminderResult = try await scheduleReminder(from: decision.reminderAction)
        } else {
            reminderResult = nil
        }

        let llm = try await CopilotLLMFinalAnswerService(
            provider: answerProvider,
            privacyGuard: privacyGuard
        )
        .generate(
            candidate: candidate,
            decision: decision,
            transcriptContext: transcriptContext,
            meeting: meeting,
            preferences: preferences,
            sources: contextSources,
            reminderResult: reminderResult,
            enableWebSearch: enableNativeWeb
        )

        let resolvedTool = llm.response.resolvedTool(fallback: requestedTool)
        let resolvedIntent = llm.response.resolvedIntent(fallback: copilotClassification.kind)
        let textSources = webRequested ? webSources(from: llm.response.answerText) : []
        let sources = deduplicatedSources(contextSources + llm.raw.sources + textSources)
        let answer = try suggestedAnswer(
            text: llm.response.answerText,
            candidate: candidate,
            classification: questionClassification,
            toolSources: sources,
            provider: llm.raw.provider,
            usedCloud: llm.raw.usedCloud,
            tool: resolvedTool,
            intent: resolvedIntent,
            preferredFormat: llm.response.resolvedFormat(fallback: CopilotAnswerFormat.paragraph),
            richAnswer: llm.response.richAnswer
        )
        let latency = Int(Date().timeIntervalSince(startedAt) * 1000)
        let expiry = Calendar.current.date(byAdding: .day, value: preferences.copilotRetentionDays, to: Date()) ?? Date().addingTimeInterval(7 * 24 * 60 * 60)
        let interaction = CopilotInteraction(
            contextKind: .ambient,
            source: source,
            questionId: candidate.id,
            prompt: privacyGuard.redact(candidate.rawText),
            response: privacyGuard.redact(answer.answerText),
            tool: resolvedTool,
            intent: resolvedIntent,
            languageCode: candidate.language,
            confidence: min(max(llm.response.confidence, 0), 1),
            latencyMs: latency,
            sources: answer.usedSources,
            richAnswer: answer.richAnswer,
            expiresAt: expiry
        )
        return (answer, interaction)
    }

    private func normalizedRequestedTool(_ tool: CopilotToolKind) -> CopilotToolKind {
        tool == .calculator ? .answerSynthesis : tool
    }

    private func scheduleReminder(from action: CopilotLLMIntentAndAnswerResponse.ReminderAction?) async throws -> ReminderActionResult {
        guard let title = action?.resolvedTitle,
              let rawDate = action?.scheduledAtISO8601,
              let scheduledAt = ISO8601DateFormatter().date(from: rawDate)
        else {
            throw CopilotFailure(.invalidReminder)
        }
        let body = action?.resolvedBody ?? title
        let notificationId = "copilot-reminder-\(UUID().uuidString)"
        let center = UNUserNotificationCenter.current()
        let granted = await withCheckedContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
        guard granted else {
            throw CopilotFailure(.notificationPermissionDenied)
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: scheduledAt)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let notification = UNNotificationRequest(identifier: notificationId, content: content, trigger: trigger)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(notification) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        let expiry = Calendar.current.date(byAdding: .day, value: preferences.copilotRetentionDays, to: Date()) ?? Date().addingTimeInterval(7 * 24 * 60 * 60)
        try repository.saveCopilotReminder(CopilotReminder(
            id: UUID(),
            title: title,
            scheduledAt: scheduledAt,
            notificationId: notificationId,
            status: .scheduled,
            createdAt: Date(),
            expiresAt: expiry
        ))
        return ReminderActionResult(notificationId: notificationId, title: title, body: body, scheduledAt: scheduledAt)
    }

    private func contextSources(
        for requestedTool: CopilotToolKind,
        candidate: QuestionCandidate,
        decision: CopilotLLMIntentAndAnswerResponse
    ) async throws -> [AnswerSource] {
        var sources: [AnswerSource] = []
        if requestedTool == .localMemory {
            let memory = try repository.copilotMemoryEntries(query: candidate.rawText, limit: 5)
            sources += memory.map {
                AnswerSource(type: .manualContext, title: "Notchly memory", snippet: privacyGuard.redact($0.text), reference: nil)
            }
        }
        if requestedTool == .webSearch || decision.needsWeb {
            let isNews = decision.resolvedIntent(fallback: .answerableQuestion) == .newsSearch
            if let webSources = try await BraveSearchCopilotProvider(urlSession: urlSession).search(query: candidate.rawText, isNews: isNews) {
                sources += webSources
            }
        }
        let knowledgeLimit = requestedTool == .localMemory ? 5 : 4
        let knowledge = (try? knowledgeStore.keywordSearch(query: candidate.rawText, limit: knowledgeLimit, workspaceId: preferences.workspaceId)) ?? []
        sources += knowledge.map {
            AnswerSource(type: .rag, title: $0.documentName, snippet: privacyGuard.redact($0.snippet), reference: nil)
        }
        return deduplicatedSources(sources)
    }

    private func deduplicatedSources(_ sources: [AnswerSource]) -> [AnswerSource] {
        var seen = Set<String>()
        return sources.filter { source in
            let key = "\(source.type.rawValue)|\(source.title)|\(source.reference ?? "")|\(source.snippet ?? "")"
            return seen.insert(key).inserted
        }
    }

    private func webSources(from text: String) -> [AnswerSource] {
        var sources: [AnswerSource] = []
        let nsText = text as NSString
        let markdownPattern = #"\[([^\]\n]{1,140})\]\((https?://[^\s\)]+)\)"#
        if let regex = try? NSRegularExpression(pattern: markdownPattern, options: [.caseInsensitive]) {
            for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) where match.numberOfRanges > 2 {
                let title = nsText.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                let url = cleanedURL(nsText.substring(with: match.range(at: 2)))
                guard let url else { continue }
                sources.append(AnswerSource(
                    type: .web,
                    title: title.isEmpty ? hostTitle(for: url) : title,
                    snippet: nil,
                    reference: url.absoluteString
                ))
            }
        }

        let rawPattern = #"https?://[^\s\)\]\}\"'>]+"#
        if let regex = try? NSRegularExpression(pattern: rawPattern, options: [.caseInsensitive]) {
            for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
                let raw = nsText.substring(with: match.range)
                guard let url = cleanedURL(raw) else { continue }
                sources.append(AnswerSource(
                    type: .web,
                    title: hostTitle(for: url),
                    snippet: nil,
                    reference: url.absoluteString
                ))
            }
        }
        return deduplicatedSources(sources)
    }

    private func cleanedURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t\r.,;:)]}\"'"))
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }

    private func hostTitle(for url: URL) -> String {
        url.host(percentEncoded: false) ?? url.host ?? url.absoluteString
    }

    private func suggestedAnswer(
        text: String,
        candidate: QuestionCandidate,
        classification: QuestionClassification,
        toolSources: [AnswerSource],
        provider: EngineName,
        usedCloud: Bool,
        tool: CopilotToolKind,
        intent: CopilotIntentKind,
        preferredFormat: CopilotAnswerFormat? = nil,
        richAnswer: RichAnswerPayload? = nil
    ) throws -> SuggestedAnswer {
        let generated = AnswerPresentationFormatter.normalizedGeneratedText(text, question: candidate, classification: classification)
        let presentation = try CopilotAnswerPresenter().present(
            text: generated,
            candidate: candidate,
            classification: classification,
            tool: tool,
            intent: intent,
            sources: toolSources,
            preferredFormat: preferredFormat,
            richAnswer: richAnswer
        )
        return SuggestedAnswer(
            questionId: candidate.id,
            answerText: presentation.text,
            shortAnswer: presentation.shortText,
            confidence: classification.confidence,
            riskLevel: .safe,
            usedSources: presentation.sources,
            assumptions: [],
            caveats: presentation.caveats,
            latencyMs: 0,
            expandedAnswer: presentation.text,
            suggestedTone: classification.expectedAnswerStyle,
            language: candidate.language,
            provider: provider,
            usedCloud: usedCloud,
            usedRAG: toolSources.contains { $0.type == .rag || $0.type == .manualContext },
            answerFormat: presentation.format,
            richAnswer: presentation.richAnswer
        )
    }
}

struct BraveSearchCopilotProvider {
    var urlSession: URLSession

    func search(query: String, isNews: Bool) async throws -> [AnswerSource]? {
        guard let apiKey = ProcessInfo.processInfo.environment["BRAVE_SEARCH_API_KEY"], !apiKey.isEmpty else {
            return nil
        }
        var components = URLComponents(string: "https://api.search.brave.com/res/v1/\(isNews ? "news" : "web")/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: "5"),
            URLQueryItem(name: "country", value: "us"),
            URLQueryItem(name: "search_lang", value: "en"),
            URLQueryItem(name: "spellcheck", value: "1")
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.addValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        request.addValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { return nil }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let root: [[String: Any]]
        if isNews {
            root = object["results"] as? [[String: Any]] ?? []
        } else {
            let web = object["web"] as? [String: Any]
            root = web?["results"] as? [[String: Any]] ?? []
        }
        let sources = root.prefix(5).compactMap { item -> AnswerSource? in
            guard let title = item["title"] as? String else { return nil }
            let url = item["url"] as? String
            let snippet = (item["description"] as? String) ?? (item["snippet"] as? String)
            return AnswerSource(type: .web, title: title, snippet: snippet, reference: url)
        }
        return sources.isEmpty ? nil : sources
    }
}

private extension CopilotIntentClassification {
    init(decision: CopilotLLMIntentAndAnswerResponse, frame: SpeechCandidateFrame, responseNeeded: Bool) {
        let intent = decision.resolvedIntent(fallback: .ambiguous)
        self.init(
            kind: intent,
            responseNeeded: responseNeeded,
            confidence: min(max(decision.confidence, 0), 1),
            strongSignals: responseNeeded ? ["llm_decision"] : [],
            negativeSignals: responseNeeded ? [] : [decision.reason],
            reason: decision.reason,
            extractedQuery: frame.text,
            requiresWeb: decision.needsWeb,
            preferredTool: decision.resolvedTool(fallback: .answerSynthesis),
            languageCode: frame.languageCode
        )
    }
}

private extension QuestionClassification {
    init(copilot: CopilotIntentClassification, candidate: QuestionCandidate) {
        self.init(
            isQuestion: true,
            rhetorical: false,
            complete: true,
            actionable: copilot.kind == .actionRequest || copilot.kind == .reminder,
            responseNeeded: copilot.responseNeeded,
            userAttentionNeeded: true,
            directedToUser: copilot.strongSignals.contains("directed_to_copilot") || copilot.strongSignals.contains("shortcut"),
            directedToGroup: false,
            questionType: Self.questionType(for: copilot.kind),
            priority: copilot.kind == .reminder ? .high : .medium,
            confidence: copilot.confidence,
            reason: copilot.reason,
            extractedQuestion: copilot.extractedQuery,
            expectedAnswerStyle: Self.answerStyle(for: copilot.kind)
        )
    }

    private static func questionType(for kind: CopilotIntentKind) -> QuestionType {
        switch kind {
        case .reminder, .actionRequest:
            return .actionRequest
        case .webSearch, .newsSearch, .memoryLookup:
            return .generalQuestion
        case .calculation, .conversion:
            return .clarification
        case .answerableQuestion:
            return .generalQuestion
        case .statement, .smallTalk, .ambientNoise, .ambiguous:
            return .unknown
        }
    }

    private static func answerStyle(for kind: CopilotIntentKind) -> AnswerStyle {
        switch kind {
        case .calculation, .conversion, .reminder:
            return .concise
        case .webSearch, .newsSearch, .memoryLookup:
            return .executive
        case .actionRequest:
            return .technical
        case .answerableQuestion:
            return .concise
        case .statement, .smallTalk, .ambientNoise, .ambiguous:
            return .askForClarification
        }
    }
}

private extension CopilotInteraction {
    func withLatency(_ latencyMs: Int) -> CopilotInteraction {
        var copy = self
        copy.latencyMs = latencyMs
        return copy
    }
}
