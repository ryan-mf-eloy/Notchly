import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

@available(macOS 26.0, *)
struct AppleFoundationModelProvider: AIProvider {
    var name: EngineName { .appleFoundationModels }

    func generateAnswer(context: AnswerContext, question: String, options: AnswerOptions) async throws -> GeneratedAnswer {
        #if canImport(FoundationModels)
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            throw AIProviderError.providerUnavailable("Apple Foundation Models are unavailable on this Mac.")
        }
        let session = LanguageModelSession(model: model, instructions: "You are a concise, privacy-preserving meeting copilot.")
        let response = try await session.respond(to: PromptBuilder().suggestedAnswerPrompt(context: context, question: question, options: options))
        return GeneratedAnswer(text: response.content, provider: .appleFoundationModels, usedCloud: false, usedRAG: !context.ragContext.isEmpty)
        #else
        throw AIProviderError.providerUnavailable("Apple Foundation Models are unavailable on this Mac.")
        #endif
    }

    func generateRaw(request: LLMRawRequest) async throws -> LLMRawResponse {
        #if canImport(FoundationModels)
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            throw AIProviderError.providerUnavailable("Apple Foundation Models are unavailable on this Mac.")
        }
        let instructions = request.responseMode == .jsonObject
            ? "You are a local Notchly runtime. Return exactly one valid JSON object and no surrounding prose."
            : "You are a concise, privacy-preserving local Notchly assistant."
        let session = LanguageModelSession(model: model, instructions: instructions)
        let response = try await session.respond(to: request.prompt)
        return LLMRawResponse(text: response.content, provider: .appleFoundationModels, usedCloud: false)
        #else
        throw AIProviderError.providerUnavailable("Apple Foundation Models are unavailable on this Mac.")
        #endif
    }

    func summarizeMeeting(meeting: MeetingSession, transcript: [TranscriptSegment], type: MeetingType) async throws -> MeetingSummary {
        #if canImport(FoundationModels)
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            throw AIProviderError.providerUnavailable("Apple Foundation Models are unavailable on this Mac.")
        }
        let session = LanguageModelSession(model: model, instructions: "You summarize meetings without inventing facts.")
        let response = try await session.respond(to: PromptBuilder().summaryPrompt(meeting: meeting, transcript: transcript))
        return MeetingSummaryParser.parse(response.content, meetingId: meeting.id) ?? MeetingSummaryParser.fallback(meetingId: meeting.id, text: response.content)
        #else
        throw AIProviderError.providerUnavailable("Apple Foundation Models are unavailable on this Mac.")
        #endif
    }

    func translateSegment(_ segment: TranscriptSegment, targetLanguage: String) async throws -> String {
        #if canImport(FoundationModels)
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            throw AIProviderError.invalidResponse
        }
        let sourceLanguage = segment.sourceLanguage ?? segment.originalLanguage ?? "auto"
        let session = LanguageModelSession(
            model: model,
            instructions: "You refine meeting translation locally. Preserve technical terms, names, acronyms, ticket IDs, APIs, code-like tokens, and product names. Return only the translated text."
        )
        let prompt = """
        Translate this meeting transcript segment from \(sourceLanguage) to \(targetLanguage).
        Keep facts unchanged and preserve technical terminology naturally.

        Segment:
        \(segment.text)
        """
        let response = try await session.respond(to: prompt)
        let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AIProviderError.invalidResponse }
        return text
        #else
        throw AIProviderError.invalidResponse
        #endif
    }

    func extractActionItems(transcript: [TranscriptSegment]) async throws -> [ActionItem] {
        throw AIProviderError.providerUnavailable("Apple Foundation Models action item extraction is unavailable.")
    }

    func generateInsights(transcriptWindow: [TranscriptSegment]) async throws -> [Insight] {
        throw AIProviderError.providerUnavailable("Apple Foundation Models insights are unavailable.")
    }
}
