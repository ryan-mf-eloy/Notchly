import Foundation

struct RAGQuestionContextBuilder {
    func query(for question: QuestionCandidate, classification: QuestionClassification) -> String {
        let text = question.normalizedText
        var terms: [String] = []

        switch classification.questionType {
        case .riskAssessment:
            terms += ["risk", "impact", "rollback", "migration", "security", "auth"]
        case .deadlineOrEstimate:
            terms += ["status", "blockers", "tests", "PR", "deadline", "estimate"]
        case .statusCheck:
            terms += ["status", "progress", "tests", "blockers"]
        case .technicalDecision:
            terms += ["architecture", "decision", "tradeoff", "implementation"]
        case .technicalExplanation:
            terms += ["technical", "example", "implementation", "complexity"]
        case .actionRequest:
            terms += ["PR", "review", "owner", "today"]
        default:
            break
        }

        terms += extractEntities(from: text)
        if terms.isEmpty {
            terms = Array(text.split { !$0.isLetter && !$0.isNumber }.prefix(8).map(String.init))
        }
        return Array(NSOrderedSet(array: terms)).compactMap { $0 as? String }.joined(separator: " ")
    }

    private func extractEntities(from text: String) -> [String] {
        let known = [
            "api", "auth", "authentication", "login", "backend", "frontend", "migration",
            "endpoint", "mvp", "production", "producao", "produção", "security", "seguranca",
            "seguridad", "github", "jira", "pr", "tests", "testes", "pruebas", "sexta", "friday",
            "python", "tree", "binary", "hashid", "hash", "algorithm", "algoritmo", "architecture",
            "backend", "migracion", "autenticacion", "認証", "ログイン", "移行", "本番", "セキュリティ", "テスト"
        ]
        return known.filter { text.contains($0) }
    }
}
