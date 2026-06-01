import Foundation
@testable import NotchCopilot

@MainActor
struct TestAIProvider: AIProvider {
    var name: EngineName { .openAI }

    func generateAnswer(context: AnswerContext, question: String, options: AnswerOptions) async throws -> GeneratedAnswer {
        GeneratedAnswer(
            text: Self.answer(for: question),
            provider: .openAI,
            usedCloud: false,
            usedRAG: !context.ragContext.isEmpty,
            sources: context.retrievedSources
        )
    }

    func summarizeMeeting(meeting: MeetingSession, transcript: [TranscriptSegment], type: MeetingType) async throws -> MeetingSummary {
        MeetingSummary(
            meetingId: meeting.id,
            executiveSummary: "The meeting covered the requested engineering topic.",
            keyDecisions: ["Keep answers grounded in available context."],
            actionItems: [ActionItem(title: "Validate provider configuration.", owner: "Ryan", priority: .medium)],
            risks: ["AI output requires human review."],
            openQuestions: ["Which provider should be used in production?"],
            strategicInsights: ["Fast answers depend on real provider availability."],
            followUps: ["Run an end-to-end provider check."]
        )
    }

    func translateSegment(_ segment: TranscriptSegment, targetLanguage: String) async throws -> String {
        if segment.text.localizedCaseInsensitiveContains("transcript inteiro") {
            return "Ryan, can you explain the risk if we send the whole transcript to a provider?"
        }
        return segment.text
    }

    func extractActionItems(transcript: [TranscriptSegment]) async throws -> [ActionItem] {
        [ActionItem(title: "Validate provider configuration.", owner: "Ryan", priority: .medium)]
    }

    func generateInsights(transcriptWindow: [TranscriptSegment]) async throws -> [Insight] {
        [Insight(title: "Provider ready", detail: "A real provider is required before drafting.", confidence: 0.9)]
    }

    static func answer(for question: String) -> String {
        let lower = question.lowercased()
        if lower.contains("capital") && (lower.contains("frança") || lower.contains("france")) {
            return "Paris is the capital of France."
        }
        if lower.contains("binary") || lower.contains("binária") || lower.contains("binaria") {
            return """
            ```python
            def invert_tree(root):
                if root is None:
                    return None
                root.left, root.right = invert_tree(root.right), invert_tree(root.left)
                return root
            ```
            """
        }
        if lower.contains("hashid") {
            return "Um HashID é um identificador ofuscado, usado para expor IDs estáveis sem revelar chaves sequenciais do banco."
        }
        if lower.contains("transcript inteiro") || lower.contains("transcript completo") {
            return "O risco principal é expor contexto sensível desnecessário; eu enviaria apenas trechos mínimos do transcript completo com consentimento e redação."
        }
        if lower.contains("scale") || lower.contains("altamente disponível") || lower.contains("highly available") {
            return "Use multiple availability zones, load balancers, stateless services, health checks, replication, and automated failover."
        }
        if lower.contains("friday") || lower.contains("sexta") {
            return "I would not promise Friday without checking PR status, tests, and blockers first."
        }
        if lower.contains("migration") || lower.contains("migração") {
            return "The main risk is data inconsistency around the migration path, so I would validate compatibility and rollback first."
        }
        return "I can answer, but I would keep it grounded in the available context and avoid overcommitting."
    }
}

@MainActor
struct TestMeetingAnswerProvider: MeetingAnswerProvider {
    func generateAnswer(
        question: QuestionCandidate,
        classification: QuestionClassification,
        context: AnswerContext,
        options: AnswerGenerationOptions
    ) async throws -> AsyncThrowingStream<PartialAnswer, Error> {
        AsyncThrowingStream { continuation in
            let text = TestAIProvider.answer(for: question.rawText)
            let risk: AnswerRiskLevel = classification.questionType == .deadlineOrEstimate ? .requiresApproval : .safe
            let answer = SuggestedAnswer(
                questionId: question.id,
                answerText: text,
                shortAnswer: text,
                confidence: classification.confidence,
                riskLevel: risk,
                usedSources: context.retrievedSources,
                assumptions: [],
                caveats: classification.questionType == .deadlineOrEstimate ? ["Confirm before committing."] : [],
                latencyMs: 1,
                expandedAnswer: text,
                suggestedTone: classification.expectedAnswerStyle,
                language: question.language ?? context.languageCode,
                provider: .openAI,
                usedCloud: false,
                usedRAG: !context.ragContext.isEmpty
            )
            continuation.yield(PartialAnswer(textDelta: text, isFinal: true, suggestedAnswer: answer))
            continuation.finish()
        }
    }
}

@MainActor
final class TestRealtimeQuestionAnsweringEngine: RealtimeQuestionAnsweringEngine {
    init(knowledgeStore: LocalKnowledgeStore? = nil) {
        super.init(
            classifierProvider: QuestionClassifier(),
            contextRetriever: MeetingContextRetriever(knowledgeStore: knowledgeStore),
            answerProvider: TestMeetingAnswerProvider()
        )
    }
}

final class FakeAudioDeviceProvider: AudioDeviceProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var storedSnapshot: AudioDeviceSnapshot
    private var changeHandler: (@Sendable () -> Void)?

    init(snapshot: AudioDeviceSnapshot) {
        self.storedSnapshot = snapshot
    }

    func snapshot() -> AudioDeviceSnapshot {
        lock.lock()
        let snapshot = storedSnapshot
        lock.unlock()
        return snapshot
    }

    func startMonitoring(onChange: @escaping @Sendable () -> Void) {
        lock.lock()
        changeHandler = onChange
        lock.unlock()
    }

    func stopMonitoring() {
        lock.lock()
        changeHandler = nil
        lock.unlock()
    }

    func update(to snapshot: AudioDeviceSnapshot) {
        lock.lock()
        storedSnapshot = snapshot
        let changeHandler = changeHandler
        lock.unlock()
        changeHandler?()
    }
}
