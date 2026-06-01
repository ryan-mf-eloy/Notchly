import Foundation

@MainActor
protocol ContextRetrievalProvider {
    func retrieveContext(
        question: QuestionCandidate,
        classification: QuestionClassification,
        meetingContext: MeetingContext
    ) async throws -> AnswerContext
}

@MainActor
struct MeetingContextRetriever: ContextRetrievalProvider {
    var knowledgeStore: LocalKnowledgeStore?
    var embeddingProvider: (any EmbeddingProvider)?
    var privacyGuard = PrivacyGuard()
    var webBuilder = WebSearchQuestionContextBuilder()

    func retrieveContext(
        question: QuestionCandidate,
        classification: QuestionClassification,
        meetingContext: MeetingContext
    ) async throws -> AnswerContext {
        let preferences = meetingContext.preferences
        let ragQuery = RAGQuestionContextBuilder().query(
            for: question,
            classification: classification,
            context: meetingContext.transcriptContext
        )
        let ragResults: [KnowledgeSearchResult]
        let retrievedRAGContext: String
        let ragGrounding: KnowledgeRetrievalGrounding?
        if preferences.aiConfig.ragEnabled,
           preferences.knowledgeSourcesEnabled,
           let knowledgeStore {
            let selectedSourceId = preferences.copilotKnowledgeScope == .selectedSource ? preferences.selectedKnowledgeSourceId : nil
            let allowedKinds: Set<KnowledgeSourceKind> = preferences.copilotKnowledgeScope == .currentMeeting ? [.meeting] : Set(KnowledgeSourceKind.allCases)
            let retrieval = await KnowledgeRetrievalService(store: knowledgeStore, embeddingProvider: embeddingProvider)
                .retrieve(
                    query: ragQuery,
                    preferences: preferences,
                    limit: min(max(preferences.ragDefaultResultLimit, 4), 8),
                    selectedSourceId: selectedSourceId,
                    allowedKinds: allowedKinds
                )
            ragResults = retrieval.results
            retrievedRAGContext = retrieval.context
            ragGrounding = retrieval.grounding
        } else {
            ragResults = []
            retrievedRAGContext = ""
            ragGrounding = nil
        }
        var ragSources = ragResults.map { $0.answerSource(redacting: privacyGuard) }
        if let contextNotice = ragGrounding?.contextNotice {
            ragSources.insert(
                AnswerSource(
                    type: .rag,
                    title: "Local evidence status",
                    snippet: contextNotice,
                    reference: nil
                ),
                at: 0
            )
        }
        let webSources = await webBuilder.webSources(for: question, classification: classification, preferences: preferences)
        let transcriptSources = [
            AnswerSource(
                type: .transcript,
                title: "Recent transcript",
                snippet: privacyGuard.redact(bounded(meetingContext.transcriptContext.recentTranscript, limit: 520)),
                reference: nil
            ),
            AnswerSource(
                type: .transcript,
                title: "Complete meeting transcript",
                snippet: privacyGuard.redact(bounded(meetingContext.transcriptContext.completeTranscript, limit: 900)),
                reference: nil
            )
        ].filter { ($0.snippet ?? "").isEmpty == false }

        let webContext = webSources.map { "[\($0.title)] \($0.snippet ?? "")" }.joined(separator: "\n")
        let mergedContext = [retrievedRAGContext, webContext].filter { !$0.isEmpty }.joined(separator: "\n")

        return AnswerContext(
            meetingTitle: meetingContext.meeting.title,
            transcriptWindow: privacyGuard.redact(meetingContext.transcriptContext.recentTranscript),
            completeTranscript: privacyGuard.redact(bounded(meetingContext.transcriptContext.completeTranscript, limit: 2_000)),
            ragContext: privacyGuard.redact(mergedContext),
            userRole: preferences.userRole,
            responseStyle: ResponseStyle(answerStyle: classification.expectedAnswerStyle),
            languageCode: question.language ?? meetingContext.transcriptContext.dominantLanguage ?? meetingContext.meeting.primaryLanguage,
            retrievedSources: transcriptSources + ragSources + webSources,
            shortTermMemory: meetingContext.shortTermMemory
        )
    }

    private func bounded(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.suffix(limit))
    }
}

private extension ResponseStyle {
    init(answerStyle: AnswerStyle) {
        switch answerStyle {
        case .technical:
            self = .technical
        case .diplomatic, .cautious:
            self = .diplomatic
        case .executive:
            self = .executive
        case .concise, .askForClarification:
            self = .concise
        }
    }
}
