import Foundation

struct QuestionShadowDecisionRecord: Codable, Hashable, Sendable {
    var candidateId: UUID
    var meetingId: UUID
    var rawText: String
    var language: String?
    var decision: String
    var reason: String
    var confidence: Double
    var responseNeeded: Bool
    var priority: QuestionPriority
    var textualConfidence: Double?
    var multimodalConfidence: Double?
    var decisionScore: Double?
    var decisionSignals: [String]?
    var suppressionSignals: [String]?
    var createdAt: Date = Date()
}

struct QuestionShadowLogger {
    var fileManager: FileManager = .default

    func record(candidate: QuestionCandidate, classification: QuestionClassification, decision: String) {
        let record = QuestionShadowDecisionRecord(
            candidateId: candidate.id,
            meetingId: candidate.meetingId,
            rawText: PrivacyGuard().redact(candidate.rawText),
            language: candidate.language,
            decision: decision,
            reason: classification.reason,
            confidence: classification.confidence,
            responseNeeded: classification.responseNeeded,
            priority: classification.priority,
            textualConfidence: classification.textualConfidence,
            multimodalConfidence: classification.multimodalConfidence,
            decisionScore: classification.decisionScore,
            decisionSignals: classification.decisionSignals,
            suppressionSignals: classification.suppressionSignals
        )
        guard let data = try? JSONEncoder().encode(record),
              let line = String(data: data, encoding: .utf8)
        else { return }
        do {
            let url = try logURL()
            if !fileManager.fileExists(atPath: url.path) {
                fileManager.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            if let lineData = (line + "\n").data(using: .utf8) {
                handle.write(lineData)
            }
            try handle.close()
        } catch {
            AppLog.ai.debug("Notchly shadow logging skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func logURL() throws -> URL {
        let directory = try FileStorageService.applicationSupportDirectory()
            .appendingPathComponent("qa-shadow", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("qa_decisions.jsonl")
    }
}

struct QuestionPartialStability: Hashable, Sendable {
    var score: Double
    var revisionCount: Int
    var isStable: Bool
}

struct QuestionPartialStabilityTracker {
    private struct State {
        var normalizedText: String
        var stableCount: Int
    }

    private var states: [String: State] = [:]

    mutating func reset() {
        states = [:]
    }

    mutating func observe(segment: TranscriptSegment) -> QuestionPartialStability {
        let normalized = QuestionDetectionService.normalize(segment.text)
        guard !normalized.isEmpty else {
            return QuestionPartialStability(score: 0, revisionCount: 0, isStable: false)
        }
        guard !segment.isFinal else {
            states[key(for: segment)] = State(normalizedText: normalized, stableCount: 2)
            return QuestionPartialStability(score: 1, revisionCount: max(segment.revisionNumber, 1), isStable: true)
        }

        let key = key(for: segment)
        let previous = states[key]
        let similarity = previous.map { textSimilarity($0.normalizedText, normalized) } ?? 0
        let stableCount = similarity >= 0.72 ? (previous?.stableCount ?? 0) + 1 : 1
        states[key] = State(normalizedText: normalized, stableCount: stableCount)

        let tokenCount = normalized.split(separator: " ").count
        let score = min(1, max(similarity, stableCount >= 2 ? 0.84 : 0.32))
        let isStable = stableCount >= 2 && tokenCount >= 4
        return QuestionPartialStability(score: score, revisionCount: max(stableCount - 1, segment.revisionNumber), isStable: isStable)
    }

    private func key(for segment: TranscriptSegment) -> String {
        [
            segment.meetingId.uuidString,
            segment.speakerId?.uuidString ?? segment.speakerLabel,
            segment.audioSource.rawValue
        ].joined(separator: "|")
    }

    private func textSimilarity(_ lhs: String, _ rhs: String) -> Double {
        if lhs == rhs { return 1 }
        if lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs) {
            let shorter = Double(min(lhs.count, rhs.count))
            let longer = Double(max(lhs.count, rhs.count))
            return max(0.72, shorter / max(longer, 1))
        }
        let leftTokens = Set(lhs.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let rightTokens = Set(rhs.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        guard !leftTokens.isEmpty || !rightTokens.isEmpty else { return 0 }
        return Double(leftTokens.intersection(rightTokens).count) / Double(max(leftTokens.union(rightTokens).count, 1))
    }
}

@MainActor
class RealtimeQuestionAnsweringEngine {
    let eventBus: RealtimeQuestionEventBus

    private var buffer = TranscriptWindowBuffer()
    private var candidateStore = QuestionCandidateStore()
    private var partialStabilityTracker = QuestionPartialStabilityTracker()
    private var pendingDetectionTasks: [UUID: Task<Void, Never>] = [:]
    private var generationTasks: [UUID: Task<Void, Never>] = [:]

    private let detectionService: QuestionDetectionService
    private let classifierProvider: any QuestionClassifierProvider
    private let contextRetriever: any ContextRetrievalProvider
    private let answerProvider: any MeetingAnswerProvider
    private let deduplicator: QuestionDeduplicator
    private let intentGate: QuestionIntentGate
    private let shadowLogger: QuestionShadowLogger?

    init(
        eventBus: RealtimeQuestionEventBus = RealtimeQuestionEventBus(),
        detectionService: QuestionDetectionService = QuestionDetectionService(),
        classifierProvider: any QuestionClassifierProvider,
        contextRetriever: any ContextRetrievalProvider,
        answerProvider: any MeetingAnswerProvider,
        deduplicator: QuestionDeduplicator = QuestionDeduplicator(),
        intentGate: QuestionIntentGate = QuestionIntentGate(),
        shadowLogger: QuestionShadowLogger? = nil
    ) {
        self.eventBus = eventBus
        self.detectionService = detectionService
        self.classifierProvider = classifierProvider
        self.contextRetriever = contextRetriever
        self.answerProvider = answerProvider
        self.deduplicator = deduplicator
        self.intentGate = intentGate
        self.shadowLogger = shadowLogger
    }

    func reset() {
        pendingDetectionTasks.values.forEach { $0.cancel() }
        generationTasks.values.forEach { $0.cancel() }
        pendingDetectionTasks = [:]
        generationTasks = [:]
        buffer.reset()
        partialStabilityTracker.reset()
        candidateStore = QuestionCandidateStore()
    }

    func stop() {
        reset()
        eventBus.finish()
    }

    func ingest(
        segment: TranscriptSegment,
        meeting: MeetingSession,
        preferences: AppPreferences,
        multimodalSignal incomingSignal: QuestionMultimodalSignal? = nil
    ) async {
        buffer.append(segment)
        let context = buffer.transcriptContext(currentSegment: segment)
        let stability = partialStabilityTracker.observe(segment: segment)
        let signal = (incomingSignal ?? QuestionMultimodalSignal(segment: segment))
            .withPartialStability(stability.score, revisionCount: stability.revisionCount)

        if !segment.isFinal, !stability.isStable {
            detectAnsweredQuestions(segment: segment)
            return
        }

        let candidates = detectionService.detectCandidates(from: segment, context: context, signal: signal)
        guard !candidates.isEmpty else {
            detectAnsweredQuestions(segment: segment)
            return
        }

        for candidate in candidates {
            if segment.isFinal {
                pendingDetectionTasks[segment.id]?.cancel()
                pendingDetectionTasks[segment.id] = nil
                await process(candidate: candidate, meeting: meeting, preferences: preferences)
            } else {
                pendingDetectionTasks[segment.id]?.cancel()
                pendingDetectionTasks[segment.id] = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(750))
                    guard !Task.isCancelled else { return }
                    await self?.process(candidate: candidate, meeting: meeting, preferences: preferences)
                }
            }
        }
    }

    func dismiss(questionId: UUID) {
        generationTasks[questionId]?.cancel()
        generationTasks[questionId] = nil
        candidateStore.mark(questionId, status: .dismissed)
        eventBus.send(.questionCancelled(questionId, "Question dismissed."))
    }

    func candidate(for id: UUID) -> QuestionCandidate? {
        candidateStore.candidates[id]
    }

    private func process(candidate incoming: QuestionCandidate, meeting: MeetingSession, preferences: AppPreferences) async {
        let profile = UserMeetingProfile(preferences: preferences, meeting: meeting)
        let transcriptContext = buffer.transcriptContext(currentSegment: nil)

        var candidate = incoming
        if let duplicate = deduplicator.duplicate(of: incoming, in: Array(candidateStore.candidates.values)) {
            candidate = deduplicator.merged(duplicate, with: incoming)
            eventBus.send(.questionMerged(source: incoming, target: candidate))
        }

        let intent = intentGate.evaluate(candidate: candidate, context: transcriptContext)
        guard intent.isAnswerableQuestion else {
            let classification = QuestionClassification(ignoredBy: intent, candidate: candidate)
            candidate.classification = classification
            candidate.status = .ignored
            candidateStore.upsert(candidate)
            shadowLogger?.record(candidate: candidate, classification: classification, decision: "ignored_intent_gate")
            eventBus.send(.questionIgnored(candidate, classification.reason))
            return
        }

        do {
            let classification = try await classifierProvider.classifyQuestion(
                candidate: candidate,
                context: transcriptContext,
                userProfile: profile
            )
            candidate.classification = classification
            candidate.status = classification.isQuestion && classification.complete && !classification.rhetorical ? .confirmed : .ignored
            candidateStore.upsert(candidate)
            shadowLogger?.record(
                candidate: candidate,
                classification: classification,
                decision: classification.responseNeeded ? "accepted" : "ignored_classifier"
            )

            guard classification.isQuestion else {
                eventBus.send(.questionIgnored(candidate, classification.reason))
                return
            }

            eventBus.send(.questionDetected(candidate, classification))

            guard shouldGenerateAnswer(for: classification) else { return }
            startAnswerGeneration(for: candidate, classification: classification, meeting: meeting, preferences: preferences)
        } catch {
            eventBus.send(.questionIgnored(candidate, error.localizedDescription))
        }
    }

    private func shouldGenerateAnswer(for classification: QuestionClassification) -> Bool {
        classification.responseNeeded
            && classification.complete
            && !classification.rhetorical
            && classification.priority != .low
    }

    private func startAnswerGeneration(
        for candidate: QuestionCandidate,
        classification: QuestionClassification,
        meeting: MeetingSession,
        preferences: AppPreferences
    ) {
        if classification.priority == .urgent {
            for (questionId, task) in generationTasks where questionId != candidate.id {
                task.cancel()
                generationTasks[questionId] = nil
                eventBus.send(.questionCancelled(questionId, "Superseded by urgent question."))
            }
        }

        generationTasks[candidate.id]?.cancel()
        generationTasks[candidate.id] = Task { [weak self] in
            guard let self else { return }
            await self.generateAnswer(for: candidate, classification: classification, meeting: meeting, preferences: preferences)
        }
    }

    private func generateAnswer(
        for candidate: QuestionCandidate,
        classification: QuestionClassification,
        meeting: MeetingSession,
        preferences: AppPreferences
    ) async {
        do {
            eventBus.send(.answerGenerating(candidate.id, .classifying))
            let transcriptContext = buffer.transcriptContext(currentSegment: nil)
            let meetingContext = MeetingContext(
                meeting: meeting,
                transcriptContext: transcriptContext,
                shortTermMemory: buffer.shortTermMemory,
                preferences: preferences
            )
            eventBus.send(.answerGenerating(candidate.id, .retrievingContext))
            let answerContext = try await contextRetriever.retrieveContext(
                question: candidate,
                classification: classification,
                meetingContext: meetingContext
            )
            eventBus.send(.answerGenerating(candidate.id, .drafting))
            let stream = try await answerProvider.generateAnswer(
                question: candidate,
                classification: classification,
                context: answerContext,
                options: AnswerGenerationOptions(
                    maxSentences: 3,
                    allowCommitments: false,
                    enableWebSearch: preferences.aiConfig.webSearchEnabled,
                    enableRAG: preferences.aiConfig.ragEnabled,
                    localOnlyMode: preferences.localOnlyMode
                )
            )
            var streamedText = ""
            for try await partial in stream {
                guard !Task.isCancelled else {
                    eventBus.send(.answerGenerating(candidate.id, .cancelled))
                    return
                }
                if !partial.textDelta.isEmpty {
                    streamedText = partial.isFinal ? partial.textDelta : streamedText + partial.textDelta
                    eventBus.send(.partialAnswerUpdated(candidate.id, streamedText))
                }
                if partial.isFinal, let answer = partial.suggestedAnswer {
                    eventBus.send(.answerGenerating(candidate.id, .finalizing))
                    candidateStore.store(answer)
                    eventBus.send(.suggestedAnswerReady(candidate, answer))
                    eventBus.send(.answerGenerating(candidate.id, .ready))
                }
            }
        } catch is CancellationError {
            eventBus.send(.answerGenerating(candidate.id, .cancelled))
        } catch {
            eventBus.send(.answerFailed(candidate.id, Self.failureMessage(for: error)))
        }
    }

    private static func failureMessage(for error: Error) -> String {
        if let aiError = error as? AIProviderError,
           let description = aiError.errorDescription {
            if case .cloudDisabled = aiError {
                return "Local-only mode is on and cloud answers are disabled."
            }
            return description
        }
        return "Could not generate a local answer for this question."
    }

    private func detectAnsweredQuestions(segment: TranscriptSegment) {
        let text = QuestionDetectionService.normalize(segment.text)
        let answerMarkers = ["yes", "no", "sim", "nao", "não", "done", "feito", "ja foi", "já foi", "i can", "consigo"]
        guard answerMarkers.contains(where: { text.contains($0) }) else { return }
        for candidate in candidateStore.candidates.values where candidate.status == .confirmed {
            guard Date().timeIntervalSince(candidate.detectedAt) < 20 else { continue }
            if candidate.speakerId == segment.speakerId || candidate.speakerLabel == segment.speakerLabel {
                generationTasks[candidate.id]?.cancel()
                candidateStore.mark(candidate.id, status: .answered)
                eventBus.send(.questionCancelled(candidate.id, "Speaker answered their own question."))
            }
        }
    }
}

extension RealtimeQuestionAnsweringEngine {
    convenience init(
        providerRouter: ProviderRouter,
        preferences: AppPreferences,
        knowledgeStore: LocalKnowledgeStore?
    ) {
        let classifier = providerRouter.questionClassifierProvider(preferences: preferences)
        let answerProvider = providerRouter.meetingAnswerProvider(preferences: preferences)
        let contextRetriever = MeetingContextRetriever(knowledgeStore: knowledgeStore)
        self.init(
            detectionService: QuestionDetectionService(
                adaptiveProfile: preferences.questionAnsweringProfile,
                precisionMode: preferences.qaPrecisionMode
            ),
            classifierProvider: classifier,
            contextRetriever: contextRetriever,
            answerProvider: answerProvider,
            intentGate: QuestionIntentGate(adaptiveProfile: preferences.questionAnsweringProfile),
            shadowLogger: preferences.qaShadowMode ? QuestionShadowLogger() : nil
        )
    }
}

private extension UserMeetingProfile {
    init(preferences: AppPreferences, meeting: MeetingSession) {
        self.init(
            userName: preferences.userDisplayName,
            userAliases: ([preferences.userDisplayName] + preferences.userNicknames.split(separator: ",").map { String($0) })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
            userRole: preferences.userRole,
            preferredStyle: .technical,
            preferredLanguages: [preferences.defaultLanguage, meeting.primaryLanguage].compactMap { $0 },
            meetingType: meeting.meetingType
        )
    }
}
