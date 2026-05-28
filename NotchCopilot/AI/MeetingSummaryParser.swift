import Foundation

enum MeetingSummaryParser {
    static func parse(_ text: String, meetingId: UUID) -> MeetingSummary? {
        guard let json = extractJSONObject(from: text),
              let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else {
            return nil
        }
        return MeetingSummary(
            meetingId: meetingId,
            executiveSummary: payload.executiveSummary,
            keyDecisions: payload.keyDecisions,
            actionItems: payload.actionItems.map { $0.actionItem },
            risks: payload.risks,
            openQuestions: payload.openQuestions,
            strategicInsights: payload.strategicInsights,
            followUps: payload.followUps
        )
    }

    static func fallback(meetingId: UUID, text: String) -> MeetingSummary {
        MeetingSummary(meetingId: meetingId, executiveSummary: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func extractJSONObject(from text: String) -> String? {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = cleaned
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```JSON", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let start = cleaned.firstIndex(of: "{"),
              let end = cleaned.lastIndex(of: "}"),
              start <= end
        else { return nil }
        return String(cleaned[start...end])
    }

    private struct Payload: Decodable {
        var executiveSummary: String
        var keyDecisions: [String]
        var actionItems: [ActionPayload]
        var risks: [String]
        var openQuestions: [String]
        var strategicInsights: [String]
        var followUps: [String]

        enum CodingKeys: String, CodingKey {
            case executiveSummary
            case keyDecisions
            case actionItems
            case risks
            case openQuestions
            case strategicInsights
            case followUps
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            executiveSummary = try container.decodeIfPresent(String.self, forKey: .executiveSummary) ?? ""
            keyDecisions = try container.decodeIfPresent([String].self, forKey: .keyDecisions) ?? []
            actionItems = try container.decodeIfPresent([ActionPayload].self, forKey: .actionItems) ?? []
            risks = try container.decodeIfPresent([String].self, forKey: .risks) ?? []
            openQuestions = try container.decodeIfPresent([String].self, forKey: .openQuestions) ?? []
            strategicInsights = try container.decodeIfPresent([String].self, forKey: .strategicInsights) ?? []
            followUps = try container.decodeIfPresent([String].self, forKey: .followUps) ?? []
        }
    }

    private struct ActionPayload: Decodable {
        var title: String
        var owner: String?
        var dueDate: String?
        var priority: String?
        var sourceQuote: String?

        var actionItem: ActionItem {
            ActionItem(
                title: title,
                owner: owner,
                dueDate: dueDate.flatMap(Self.parseDate),
                priority: priority.flatMap(ActionPriority.init(rawValue:)) ?? .medium,
                sourceQuote: sourceQuote
            )
        }

        private static func parseDate(_ value: String) -> Date? {
            ISO8601DateFormatter().date(from: value)
        }
    }
}
