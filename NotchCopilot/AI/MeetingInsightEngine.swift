import Foundation

struct AttentionDetection: Sendable, Hashable {
    var requiresUserAttention: Bool
    var confidence: Double
    var reason: String
    var extractedQuestion: String?
    var suggestedAction: String
}

struct MeetingInsightEngine {
    func detectAttention(in segments: [TranscriptSegment], userNames: [String]) -> AttentionDetection {
        guard let last = segments.last else {
            return AttentionDetection(requiresUserAttention: false, confidence: 0, reason: "No transcript yet.", extractedQuestion: nil, suggestedAction: "Ignore")
        }
        let lowered = Self.searchable(last.text)
        let names = userNames
            .map(Self.searchable)
            .filter { !$0.isEmpty }
        let nameHit = names.contains { lowered.contains($0) }
        let questionPatterns = [
            "?",
            "can you",
            "could you",
            "what do you think",
            "voce pode",
            "pode explicar",
            "consegue",
            "o que voce acha",
            "qual sua opiniao",
            "como voce",
            "por que voce"
        ]
        let questionHit = questionPatterns.contains { lowered.contains($0) }
        let requiresAttention = nameHit && questionHit
        return AttentionDetection(
            requiresUserAttention: requiresAttention,
            confidence: requiresAttention ? 0.86 : 0.35,
            reason: requiresAttention ? "Name and question pattern detected." : "No direct question for the user.",
            extractedQuestion: requiresAttention ? last.text : nil,
            suggestedAction: requiresAttention ? "Draft Answer" : "Ignore"
        )
    }

    private static func searchable(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
