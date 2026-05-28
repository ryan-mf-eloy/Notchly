import Foundation

struct QuestionDeduplicator {
    var similarityThreshold: Double = 0.72

    func duplicate(of candidate: QuestionCandidate, in existing: [QuestionCandidate]) -> QuestionCandidate? {
        existing
            .filter { $0.meetingId == candidate.meetingId && $0.status != .expired && $0.status != .dismissed }
            .filter { abs($0.startTime - candidate.startTime) < 45 || Set($0.sourceSegmentIds).isDisjoint(with: candidate.sourceSegmentIds) == false }
            .max { similarity($0.normalizedText, candidate.normalizedText) < similarity($1.normalizedText, candidate.normalizedText) }
            .flatMap { similarity($0.normalizedText, candidate.normalizedText) >= similarityThreshold ? $0 : nil }
    }

    func merged(_ existing: QuestionCandidate, with candidate: QuestionCandidate) -> QuestionCandidate {
        let preferredText = candidate.rawText.count >= existing.rawText.count ? candidate.rawText : existing.rawText
        let normalized = QuestionDetectionService.normalize(preferredText)
        return QuestionCandidate(
            id: existing.id,
            meetingId: existing.meetingId,
            rawText: preferredText,
            normalizedText: normalized,
            language: candidate.language ?? existing.language,
            speakerId: candidate.speakerId ?? existing.speakerId,
            speakerLabel: candidate.speakerLabel ?? existing.speakerLabel,
            startTime: min(existing.startTime, candidate.startTime),
            endTime: candidate.endTime ?? existing.endTime,
            sourceSegmentIds: Array(Set(existing.sourceSegmentIds + candidate.sourceSegmentIds)),
            isPartial: existing.isPartial && candidate.isPartial,
            detectedAt: existing.detectedAt,
            multimodalSignal: candidate.multimodalSignal ?? existing.multimodalSignal,
            classification: candidate.classification ?? existing.classification,
            status: candidate.isPartial ? existing.status : .confirmed
        )
    }

    func similarity(_ lhs: String, _ rhs: String) -> Double {
        let a = Set(lhs.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let b = Set(rhs.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        guard !a.isEmpty || !b.isEmpty else { return lhs == rhs ? 1 : 0 }
        let intersection = a.intersection(b).count
        let union = a.union(b).count
        let tokenScore = Double(intersection) / Double(max(union, 1))
        let prefixScore = lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs) ? 0.35 : 0
        return min(1, tokenScore + prefixScore)
    }
}
