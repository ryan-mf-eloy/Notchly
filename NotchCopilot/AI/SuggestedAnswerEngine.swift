import Foundation

@MainActor
struct SuggestedAnswerEngine {
    private let provider: any AIProvider
    private let privacyGuard: PrivacyGuard
    private let answerTimeoutSeconds: TimeInterval

    init(provider: any AIProvider, privacyGuard: PrivacyGuard = PrivacyGuard(), answerTimeoutSeconds: TimeInterval = 35) {
        self.provider = provider
        self.privacyGuard = privacyGuard
        self.answerTimeoutSeconds = answerTimeoutSeconds
    }

    func draftAnswer(for question: String, meeting: MeetingSession, preferences: AppPreferences, ragContext: String) async throws -> GeneratedAnswer {
        let context = AnswerContext(
            meetingTitle: meeting.title,
            transcriptWindow: privacyGuard.minimizedContext(from: meeting.transcriptSegments),
            ragContext: privacyGuard.redact(ragContext),
            userRole: preferences.userRole,
            responseStyle: .technical,
            languageCode: meeting.primaryLanguage ?? preferences.defaultLanguage
        )
        return try await runWithTimeout(seconds: answerTimeoutSeconds) {
            try await provider.generateAnswer(
                context: context,
                question: privacyGuard.redact(question),
                options: AnswerOptions()
            )
        }
    }

    private func runWithTimeout(
        seconds: TimeInterval,
        operation: @escaping @MainActor () async throws -> GeneratedAnswer
    ) async throws -> GeneratedAnswer {
        let task = Task { @MainActor in
            try await operation()
        }
        let timeoutTask = Task {
            let timeout = UInt64(max(seconds, 0.1) * 1_000_000_000)
            try await Task.sleep(nanoseconds: timeout)
            task.cancel()
        }
        do {
            let value = try await task.value
            timeoutTask.cancel()
            return value
        } catch {
            timeoutTask.cancel()
            if error is CancellationError {
                throw CopilotFailure(.answerTimedOut)
            }
            throw error
        }
    }
}
