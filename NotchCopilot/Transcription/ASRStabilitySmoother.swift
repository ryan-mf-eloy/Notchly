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
