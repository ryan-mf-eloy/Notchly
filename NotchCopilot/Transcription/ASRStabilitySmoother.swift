import Foundation

struct ASRStabilitySmoother: Sendable {
    private struct SegmentKey: Hashable, Sendable {
        var id: UUID
        var source: TranscriptAudioSource
    }

    private var latestDraftByKey: [SegmentKey: TranscriptSegment] = [:]
    private var latestFinalByKey: [SegmentKey: TranscriptSegment] = [:]

    mutating func reset() {
        latestDraftByKey.removeAll()
        latestFinalByKey.removeAll()
    }

    mutating func observe(_ incoming: TranscriptSegment) -> [TranscriptSegment] {
        var segment = incoming
        let key = SegmentKey(id: segment.id, source: segment.audioSource)
        let normalizedText = normalized(segment.text)
        guard !normalizedText.isEmpty else { return [] }

        if isLikelyHallucinatedLoop(normalizedText) {
            segment.retentionReason = .hallucinationRejected
            return []
        }

        if segment.isFinal {
            if let previousDraft = latestDraftByKey[key],
               shouldPromote(previousDraft: previousDraft, overShortFinal: segment) {
                segment = promotedFinal(previousDraft: previousDraft, shortFinal: segment)
            }
            segment.transcriptionPhase = segment.transcriptionPhase ?? .final
            segment.finalizedBy = segment.finalizedBy ?? segment.transcriptionEngine ?? .appleSpeech
            segment.retentionReason = segment.retentionReason ?? .appleFinalRetained
            latestFinalByKey[key] = segment
            latestDraftByKey.removeValue(forKey: key)
            return [segment]
        }

        if let final = latestFinalByKey[key],
           normalized(final.text).contains(normalizedText) {
            return []
        }

        if let previousDraft = latestDraftByKey[key] {
            let previousText = normalized(previousDraft.text)
            if previousText.hasPrefix(normalizedText), previousText.count > normalizedText.count + 8 {
                return []
            }
            if normalizedText == previousText {
                return []
            }
        }

        segment.transcriptionPhase = segment.transcriptionPhase ?? .draft
        segment.retentionReason = segment.retentionReason ?? .appleDraftRetained
        latestDraftByKey[key] = segment
        return [segment]
    }

    private func shouldPromote(previousDraft: TranscriptSegment, overShortFinal final: TranscriptSegment) -> Bool {
        let draftText = normalized(previousDraft.text)
        let finalText = normalized(final.text)
        guard !draftText.isEmpty,
              !finalText.isEmpty,
              draftText.count > finalText.count + 8 else {
            return false
        }
        return draftText.hasPrefix(finalText)
    }

    private func promotedFinal(previousDraft: TranscriptSegment, shortFinal: TranscriptSegment) -> TranscriptSegment {
        var promoted = previousDraft
        promoted.isFinal = true
        promoted.transcriptionPhase = .final
        promoted.finalizedBy = shortFinal.finalizedBy ?? shortFinal.transcriptionEngine ?? previousDraft.transcriptionEngine
        promoted.engineConfidence = max(previousDraft.engineConfidence ?? 0, shortFinal.engineConfidence ?? 0)
        promoted.confidence = max(previousDraft.confidence, shortFinal.confidence)
        promoted.originalLanguage = previousDraft.originalLanguage ?? shortFinal.originalLanguage
        promoted.languageConfidence = maxOptional(previousDraft.languageConfidence, shortFinal.languageConfidence)
        promoted.languageEvidenceSource = shortFinal.languageEvidenceSource ?? previousDraft.languageEvidenceSource
        promoted.languageDetectionWindowMs = maxOptional(previousDraft.languageDetectionWindowMs, shortFinal.languageDetectionWindowMs)
        promoted.languageSpanCodes = Array(NSOrderedSet(array: previousDraft.languageSpanCodes + shortFinal.languageSpanCodes)) as? [String] ?? previousDraft.languageSpanCodes
        promoted.endTime = max(previousDraft.endTime, shortFinal.endTime)
        promoted.sourceFrameRange = mergedRange(previousDraft.sourceFrameRange, shortFinal.sourceFrameRange)
        promoted.revisionNumber = max(previousDraft.revisionNumber, shortFinal.revisionNumber) + 1
        promoted.retentionReason = .appleDraftPromoted
        if promoted.wordTimestamps.isEmpty {
            promoted.wordTimestamps = shortFinal.wordTimestamps
        }
        if !shortFinal.alternatives.isEmpty {
            promoted.alternatives = shortFinal.alternatives
        }
        return promoted
    }

    private func maxOptional(_ lhs: Double?, _ rhs: Double?) -> Double? {
        switch (lhs, rhs) {
        case let (.some(lhs), .some(rhs)):
            return max(lhs, rhs)
        case let (.some(value), .none), let (.none, .some(value)):
            return value
        case (.none, .none):
            return nil
        }
    }

    private func mergedRange(_ lhs: AudioSourceFrameRange?, _ rhs: AudioSourceFrameRange?) -> AudioSourceFrameRange? {
        switch (lhs, rhs) {
        case let (.some(lhs), .some(rhs)):
            return AudioSourceFrameRange(start: min(lhs.start, rhs.start), end: max(lhs.end, rhs.end))
        case let (.some(range), .none), let (.none, .some(range)):
            return range
        case (.none, .none):
            return nil
        }
    }

    private func isLikelyHallucinatedLoop(_ normalizedText: String) -> Bool {
        let tokens = normalizedText.split(separator: " ").map(String.init)
        guard tokens.count >= 8 else { return false }
        let uniqueRatio = Double(Set(tokens).count) / Double(tokens.count)
        if uniqueRatio < 0.28 { return true }

        let joined = tokens.joined(separator: " ")
        let commonLoops = [
            "thank you thank you thank you",
            "obrigado obrigado obrigado",
            "gracias gracias gracias",
            "ご視聴ありがとうございました"
        ]
        return commonLoops.contains { joined.contains($0) }
    }

    private func normalized(_ text: String) -> String {
        text
            .lowercased()
            .folding(options: [.diacriticInsensitive], locale: .current)
            .split(separator: " ")
            .joined(separator: " ")
    }
}
