import Foundation

@MainActor
struct QuestionMultiQTCandidateRescuer {
    var trainedModelRunner: any QuestionTrainedMultimodalModelRunning
    var intentGate: QuestionIntentGate = QuestionIntentGate()
    var minimumResponseMargin: Double = 0.05
    var minimumCandidateScore: Double = 0.55

    func rescueCandidates(
        from rejectedFrames: [QuestionRejectedFrame],
        context: TranscriptContext,
        mode: QAMultimodalMode,
        shadowLogger: QuestionShadowLogger? = nil
    ) async -> [QuestionCandidate] {
        guard mode != .off, !rejectedFrames.isEmpty else { return [] }
        var rescued: [QuestionCandidate] = []

        for rejectedFrame in rejectedFrames {
            guard shouldConsider(rejectedFrame, context: context) else {
                shadowLogger?.record(rejectedFrame: rejectedFrame, prediction: nil, decision: "rescue_hard_suppressed")
                continue
            }

            let candidate = candidate(from: rejectedFrame, source: mode == .shadow ? .shadowRescue : .multiqtRescue)
            let prediction = await trainedModelRunner.prediction(
                for: candidate,
                signal: rejectedFrame.frame.multimodalSignal
            )
            shadowLogger?.record(
                rejectedFrame: rejectedFrame,
                prediction: prediction,
                decision: mode == .shadow ? "shadow_rescue_scored" : "enforced_rescue_scored"
            )

            guard mode == .enforced,
                  let prediction,
                  shouldPromote(prediction: prediction)
            else { continue }

            var promoted = candidate
            promoted.discovery = candidate.discovery.withTrainedPrediction(prediction)
            rescued.append(promoted)
        }

        return rescued
    }

    private func shouldConsider(_ rejectedFrame: QuestionRejectedFrame, context: TranscriptContext) -> Bool {
        guard !rejectedFrame.hasHardSuppression else { return false }
        let frame = rejectedFrame.frame
        if frame.isPartial {
            guard let signal = frame.multimodalSignal,
                  signal.partialStability >= 0.82,
                  signal.partialRevisionCount >= 1
            else { return false }
        }
        if frame.rawText.trimmingCharacters(in: .whitespacesAndNewlines).count < 4 {
            return false
        }
        let hardSuppressionCandidate = candidate(from: rejectedFrame, source: .shadowRescue)
        return intentGate.hardSuppression(candidate: hardSuppressionCandidate, context: context) == nil
    }

    private func shouldPromote(prediction: QuestionTrainedMultimodalPrediction) -> Bool {
        let candidateScore = prediction.candidateScore ?? prediction.responseScore
        return prediction.shouldAllow
            && prediction.isPositiveLabel
            && prediction.responseScore >= prediction.threshold + minimumResponseMargin
            && candidateScore >= minimumCandidateScore
    }

    private func candidate(
        from rejectedFrame: QuestionRejectedFrame,
        source: QuestionCandidateDiscoverySource
    ) -> QuestionCandidate {
        let frame = rejectedFrame.frame
        return QuestionCandidate(
            id: frame.id,
            meetingId: frame.meetingId,
            rawText: frame.rawText,
            normalizedText: frame.normalizedText,
            language: frame.language ?? frame.multimodalSignal?.language,
            speakerId: frame.speakerId,
            speakerLabel: frame.speakerLabel,
            startTime: frame.startTime,
            endTime: frame.endTime,
            sourceSegmentIds: [frame.sourceSegmentId],
            isPartial: frame.isPartial,
            multimodalSignal: frame.multimodalSignal,
            discovery: QuestionCandidateDiscovery(
                source: source,
                surfaceSignals: rejectedFrame.surfaceSignals,
                surfaceSuppressionSignals: rejectedFrame.suppressionSignals
            )
        )
    }
}
