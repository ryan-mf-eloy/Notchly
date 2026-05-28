import Foundation

struct QuestionCandidateStore {
    private(set) var candidates: [UUID: QuestionCandidate] = [:]
    private(set) var answers: [UUID: SuggestedAnswer] = [:]

    mutating func upsert(_ candidate: QuestionCandidate) {
        candidates[candidate.id] = candidate
    }

    mutating func mark(_ id: UUID, status: QuestionStatus) {
        guard var candidate = candidates[id] else { return }
        candidate.status = status
        candidates[id] = candidate
    }

    mutating func store(_ answer: SuggestedAnswer) {
        answers[answer.questionId] = answer
        mark(answer.questionId, status: .answered)
    }

    mutating func expire(now: Date = Date()) -> [QuestionCandidate] {
        var expired: [QuestionCandidate] = []
        for candidate in candidates.values {
            guard let priority = candidate.classification?.priority else { continue }
            if candidate.status == .answered || candidate.status == .dismissed || candidate.status == .ignored { continue }
            if now.timeIntervalSince(candidate.detectedAt) > priority.ttl {
                var updated = candidate
                updated.status = .expired
                candidates[candidate.id] = updated
                expired.append(updated)
            }
        }
        return expired
    }
}

