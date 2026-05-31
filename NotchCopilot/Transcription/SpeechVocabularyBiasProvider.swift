import Foundation

@MainActor
struct SpeechVocabularyBiasProvider {
    func context(
        for session: MeetingSession,
        preferences: AppPreferences,
        store: SpeechVocabularyStore?,
        extraSystemTerms: [String] = []
    ) -> SpeechRecognitionContext {
        let systemTerms = defaultSystemTerms(for: session, preferences: preferences) + extraSystemTerms
        if let store {
            var context = store.speechContext(for: session, preferences: preferences)
            let existing = Set(context.terms.map(\.normalizedText))
            let locale = SupportedLanguage.normalizedCode(session.primaryLanguage ?? preferences.defaultLanguage)
            let injected = systemTerms
                .map { SpeechVocabularyTerm.cleaned($0) }
                .filter { !$0.isEmpty }
                .filter { !existing.contains(SpeechVocabularyTerm.normalizedKey($0, locale: locale)) }
                .map {
                    SpeechContextTerm(
                        text: $0,
                        locale: nil,
                        category: .custom,
                        weight: 1.2,
                        pronunciationXSAMPA: nil,
                        source: "system_context"
                    )
                }
            context.terms.append(contentsOf: injected)
            return context
        }

        let locale = SupportedLanguage.normalizedCode(session.primaryLanguage ?? preferences.defaultLanguage)
        let terms = systemTerms
            .map { SpeechVocabularyTerm.cleaned($0) }
            .filter { !$0.isEmpty }
            .deduplicatedCaseAndDiacriticInsensitive()
            .map {
                SpeechContextTerm(
                    text: $0,
                    locale: nil,
                    category: .custom,
                    weight: 1.1,
                    pronunciationXSAMPA: nil,
                    source: "system_context"
                )
            }
        return SpeechRecognitionContext(
            locale: locale,
            terms: terms,
            customLanguageModelEnabled: preferences.localOnlyMode,
            status: terms.isEmpty ? "Apple Speech ready" : "Vocabulary bias active"
        )
    }

    nonisolated func whisperPrompt(for context: SpeechRecognitionContext, maxTerms: Int = 80) -> String {
        let ranked = SpeechContextRanker().rank(context.terms, limit: maxTerms, locale: context.locale)
        guard !ranked.isEmpty else { return "" }
        return "Prefer these proper nouns, technical terms, and meeting vocabulary when acoustically plausible: " +
            ranked.joined(separator: ", ")
    }

    private func defaultSystemTerms(for session: MeetingSession, preferences: AppPreferences) -> [String] {
        let names = ([preferences.userDisplayName] + preferences.userNicknames.split(separator: ",").map(String.init))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let appTerms = preferences.knownMeetingApps.flatMap { [$0.displayName] + $0.nameKeywords }
        let technicalTerms = [
            "Notchly", "Dynamic Island", "Local Only", "OpenAI", "ChatGPT", "Realtime API",
            "Swift", "SwiftUI", "AppKit", "AVFoundation", "ScreenCaptureKit", "Speech framework",
            "SpeechAnalyzer", "SpeechDetector", "WhisperKit", "Core ML", "MLX", "Keychain",
            "RAG", "Knowledge", "transcript", "transcription", "transcrição", "resumo",
            "decisão", "action item", "follow-up", "bloqueio", "risco", "deadline", "roadmap"
        ]
        let titleTerms = [session.title] + session.title.split(separator: " ").map(String.init).filter { $0.count >= 3 }
        return names + appTerms + technicalTerms + titleTerms
    }
}

private extension Array where Element == String {
    func deduplicatedCaseAndDiacriticInsensitive() -> [String] {
        var seen = Set<String>()
        return filter { value in
            seen.insert(SpeechVocabularyTerm.normalizedKey(value)).inserted
        }
    }
}
