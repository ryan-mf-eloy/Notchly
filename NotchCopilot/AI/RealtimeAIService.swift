import Foundation

struct RealtimeAIConfiguration: Sendable, Hashable {
    var model: String
    var endpoint: URL
    var supportsTextInput: Bool
    var supportsToolCalls: Bool
}

final class RealtimeAIService {
    func isEnabled(preferences: AppPreferences) -> Bool {
        preferences.realtimeSuggestionsEnabled && !preferences.localOnlyMode
    }

    func configuration(preferences: AppPreferences) -> RealtimeAIConfiguration? {
        guard isEnabled(preferences: preferences),
              preferences.aiConfig.cloudProcessingEnabled,
              preferences.aiConfig.provider == .openAI,
              preferences.aiConfig.authMode == .openAIAccountOAuth ||
              (preferences.aiConfig.authMode == .apiKeyLegacy && preferences.aiConfig.legacyAPIKeyAccessEnabled) else { return nil }
        let model = preferences.aiConfig.realtimeModel ?? "gpt-realtime"
        guard let endpoint = URL(string: "wss://api.openai.com/v1/realtime?model=\(model)") else { return nil }
        return RealtimeAIConfiguration(
            model: model,
            endpoint: endpoint,
            supportsTextInput: true,
            supportsToolCalls: true
        )
    }

    func shouldUseRealtimeForQuestionAnswering(preferences: AppPreferences) -> Bool {
        configuration(preferences: preferences) != nil
    }
}
