import Foundation

enum RealtimeQuestionEvent: Sendable, Hashable {
    case questionDetected(QuestionCandidate, QuestionClassification)
    case answerGenerating(UUID, AnswerGenerationStage)
    case answerFailed(UUID, String)
    case partialAnswerUpdated(UUID, String)
    case suggestedAnswerReady(QuestionCandidate, SuggestedAnswer)
    case questionIgnored(QuestionCandidate, String)
    case questionMerged(source: QuestionCandidate, target: QuestionCandidate)
}

final class RealtimeQuestionEventBus {
    private var continuation: AsyncStream<RealtimeQuestionEvent>.Continuation?
    private var pendingEvents: [RealtimeQuestionEvent] = []

    var events: AsyncStream<RealtimeQuestionEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
            for event in pendingEvents {
                continuation.yield(event)
            }
            pendingEvents = []
        }
    }

    func send(_ event: RealtimeQuestionEvent) {
        if let continuation {
            continuation.yield(event)
        } else {
            pendingEvents.append(event)
        }
    }

    func finish() {
        continuation?.finish()
        continuation = nil
    }
}
