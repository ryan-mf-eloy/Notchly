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
    var privacyGuard = PrivacyGuard()
    var webBuilder = WebSearchQuestionContextBuilder()

    func retrieveContext(
        question: QuestionCandidate,
        classification: QuestionClassification,
        meetingContext: MeetingContext
    ) async throws -> AnswerContext {
        let preferences = meetingContext.preferences
        let ragQuery = RAGQuestionContextBuilder().query(for: question, classification: classification)
        let ragResults = preferences.aiConfig.ragEnabled ? ((try? knowledgeStore?.keywordSearch(query: ragQuery, limit: 4, workspaceId: preferences.workspaceId)) ?? []) : []
        let ragSources = ragResults.map {
            AnswerSource(type: .rag, title: $0.documentName, snippet: privacyGuard.redact($0.snippet), reference: nil)
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

        let ragContext = ragSources.map { "[\($0.title)] \($0.snippet ?? "")" }.joined(separator: "\n")
        let webContext = webSources.map { "[\($0.title)] \($0.snippet ?? "")" }.joined(separator: "\n")
        let mergedContext = [ragContext, webContext].filter { !$0.isEmpty }.joined(separator: "\n")

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
