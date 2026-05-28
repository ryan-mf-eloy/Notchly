import Foundation

@MainActor
struct WebSearchQuestionContextBuilder {
    var service: (any WebSearchService)?

    init(service: (any WebSearchService)? = nil) {
        self.service = service
    }

    func webSources(
        for question: QuestionCandidate,
        classification: QuestionClassification,
        preferences: AppPreferences
    ) async -> [AnswerSource] {
        guard preferences.aiConfig.webSearchEnabled,
              preferences.aiConfig.cloudProcessingEnabled,
              !preferences.localOnlyMode,
              let service,
              shouldUseWeb(for: classification)
        else { return [] }

        let query = RAGQuestionContextBuilder().query(for: question, classification: classification)
        let results = (try? await service.search(query: query)) ?? []
        return results.prefix(3).map {
            AnswerSource(type: .web, title: "Web", snippet: $0, reference: query)
        }
    }

    private func shouldUseWeb(for classification: QuestionClassification) -> Bool {
        [.technicalExplanation, .technicalDecision, .riskAssessment, .businessContext].contains(classification.questionType)
    }
}
