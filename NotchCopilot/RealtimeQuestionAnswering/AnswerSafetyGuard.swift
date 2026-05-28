import Foundation

struct AnswerSafetyGuard {
    func riskLevel(for classification: QuestionClassification, answerText: String, sources: [AnswerSource]) -> AnswerRiskLevel {
        if [.approvalRequest, .deadlineOrEstimate].contains(classification.questionType) {
            return .requiresApproval
        }
        if classification.questionType == .riskAssessment || answerText.localizedCaseInsensitiveContains("production") || answerText.localizedCaseInsensitiveContains("security") {
            return .moderate
        }
        if sources.isEmpty && [.statusCheck, .technicalDecision].contains(classification.questionType) {
            return .moderate
        }
        return .safe
    }

    func sanitized(_ answer: SuggestedAnswer, classification: QuestionClassification) -> SuggestedAnswer {
        var caveats = answer.caveats
        if [.deadlineOrEstimate, .approvalRequest, .productScope].contains(classification.questionType),
           caveats.isEmpty {
            caveats.append("Confirm before committing to timeline, scope, or approval.")
        }
        return SuggestedAnswer(
            id: answer.id,
            questionId: answer.questionId,
            answerText: answer.answerText,
            shortAnswer: answer.shortAnswer,
            confidence: min(answer.confidence, classification.confidence),
            riskLevel: riskLevel(for: classification, answerText: answer.answerText, sources: answer.usedSources),
            usedSources: answer.usedSources,
            assumptions: answer.assumptions,
            caveats: caveats,
            generatedAt: answer.generatedAt,
            latencyMs: answer.latencyMs,
            expandedAnswer: answer.expandedAnswer,
            suggestedTone: answer.suggestedTone,
            shouldAskClarification: answer.shouldAskClarification,
            clarifyingQuestion: answer.clarifyingQuestion,
            language: answer.language,
            provider: answer.provider,
            usedCloud: answer.usedCloud,
            usedRAG: answer.usedRAG,
            answerFormat: answer.answerFormat,
            richAnswer: answer.richAnswer
        )
    }
}
