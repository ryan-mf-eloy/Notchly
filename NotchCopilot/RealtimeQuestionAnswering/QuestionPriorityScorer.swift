import Foundation

struct QuestionPriorityScorer {
    func priority(
        for candidate: QuestionCandidate,
        type: QuestionType,
        directedToUser: Bool,
        directedToGroup: Bool,
        actionable: Bool,
        responseNeeded: Bool
    ) -> QuestionPriority {
        guard responseNeeded else { return .low }
        let text = candidate.normalizedText
        let urgentTerms = ["blocked", "blocker", "bloqueado", "production", "producao", "produção", "security", "seguranca", "incident", "cliente", "customer"]
        if directedToUser && urgentTerms.contains(where: { text.contains($0) }) {
            return .urgent
        }
        if directedToUser && [.deadlineOrEstimate, .technicalDecision, .riskAssessment, .approvalRequest, .actionRequest].contains(type) {
            return .high
        }
        if [.deadlineOrEstimate, .technicalDecision, .riskAssessment, .approvalRequest].contains(type) {
            return .high
        }
        if directedToUser {
            return .high
        }
        if directedToGroup || actionable || [.statusCheck, .technicalExplanation, .clarification, .generalQuestion].contains(type) {
            return .medium
        }
        return .low
    }
}
