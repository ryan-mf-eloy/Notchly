import Foundation
#if canImport(HuggingFace)
import HuggingFace
#endif
#if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(MLXHuggingFace)
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers
#endif

struct AppleLocalAIProvider: AIProvider {
    var name: EngineName { .appleFoundationModels }

    func generateAnswer(context: AnswerContext, question: String, options: AnswerOptions) async throws -> GeneratedAnswer {
        if #available(macOS 26.0, *) {
            return try await AppleFoundationModelProvider().generateAnswer(context: context, question: question, options: options)
        }
        throw AIProviderError.providerUnavailable("Apple on-device AI is unavailable on this Mac.")
    }

    func generateRaw(request: LLMRawRequest) async throws -> LLMRawResponse {
        if #available(macOS 26.0, *) {
            return try await AppleFoundationModelProvider().generateRaw(request: request)
        }
        throw AIProviderError.providerUnavailable("Apple on-device AI is unavailable on this Mac.")
    }

    func summarizeMeeting(meeting: MeetingSession, transcript: [TranscriptSegment], type: MeetingType) async throws -> MeetingSummary {
        if #available(macOS 26.0, *) {
            return try await AppleFoundationModelProvider().summarizeMeeting(meeting: meeting, transcript: transcript, type: type)
        }
        throw AIProviderError.providerUnavailable("Apple on-device AI is unavailable on this Mac.")
    }

    func translateSegment(_ segment: TranscriptSegment, targetLanguage: String) async throws -> String {
        if #available(macOS 26.0, *) {
            return try await AppleFoundationModelProvider().translateSegment(segment, targetLanguage: targetLanguage)
        }
        throw AIProviderError.invalidResponse
    }

    func extractActionItems(transcript: [TranscriptSegment]) async throws -> [ActionItem] {
        throw AIProviderError.providerUnavailable("Apple on-device AI action item extraction is unavailable.")
    }

    func generateInsights(transcriptWindow: [TranscriptSegment]) async throws -> [Insight] {
        throw AIProviderError.providerUnavailable("Apple on-device AI insights are unavailable.")
    }

    func embed(texts: [String]) async throws -> [[Double]] {
        throw AIProviderError.providerUnavailable("Apple on-device embeddings are unavailable.")
    }
}

struct LocalLLMModelDescriptor: Codable, Hashable, Sendable {
    var id: String
    var displayName: String
    var modelIdentifier: String
    var directoryName: String
    var minimumBytes: Int64

    static let qwen3FourB = LocalLLMModelDescriptor(
        id: "qwen3-4b-mlx-4bit",
        displayName: "Qwen3 4B MLX 4-bit",
        modelIdentifier: "Qwen/Qwen3-4B-MLX-4bit",
        directoryName: "qwen3-4b-mlx-4bit",
        minimumBytes: 1_500 * 1024 * 1024
    )

    static let qwen3OnePointSevenB = LocalLLMModelDescriptor(
        id: "qwen3-1.7b-mlx-4bit",
        displayName: "Qwen3 1.7B MLX 4-bit",
        modelIdentifier: "Qwen/Qwen3-1.7B-MLX-4bit",
        directoryName: "qwen3-1.7b-mlx-4bit",
        minimumBytes: 650 * 1024 * 1024
    )
}

struct LocalLLMModelManager {
    var fileManager: FileManager = .default

    var descriptors: [LocalLLMModelDescriptor] {
        [.qwen3FourB, .qwen3OnePointSevenB]
    }

    func availableDescriptor() -> LocalLLMModelDescriptor? {
        descriptors.first { descriptor in
            hasModelFiles(for: descriptor)
        }
    }

    func statusText() -> String {
        if let descriptor = availableDescriptor() {
            return "\(descriptor.displayName) ready"
        }
        return "Local LLM model not downloaded"
    }

    private func modelDirectory(for descriptor: LocalLLMModelDescriptor) throws -> URL {
        try modelsRoot().appendingPathComponent(descriptor.directoryName, isDirectory: true)
    }

    private func hasModelFiles(for descriptor: LocalLLMModelDescriptor) -> Bool {
        if let url = try? modelDirectory(for: descriptor),
           let size = directorySize(url),
           size >= descriptor.minimumBytes {
            return true
        }

        #if canImport(HuggingFace)
        if let repo = Repo.ID(rawValue: descriptor.modelIdentifier) {
            let cacheDirectory = HubCache.default.repoDirectory(repo: repo, kind: .model)
            if let size = directorySize(cacheDirectory), size >= descriptor.minimumBytes {
                return true
            }
        }
        #endif

        return false
    }

    private func modelsRoot() throws -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base
            .appendingPathComponent("Notch Copilot", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("mlx", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func directorySize(_ url: URL) -> Int64? {
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return nil
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            total += size
        }
        return total
    }
}

struct LocalLLMAIProvider: AIProvider {
    var name: EngineName { .mlxLocalLLM }
    var modelManager = LocalLLMModelManager()
    var allowModelDownloads: Bool = true
    var preferredDescriptor: LocalLLMModelDescriptor = .qwen3FourB

    nonisolated static var isRuntimeLinked: Bool {
        #if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(MLXHuggingFace)
        true
        #else
        false
        #endif
    }

    func generateAnswer(context: AnswerContext, question: String, options: AnswerOptions) async throws -> GeneratedAnswer {
        let descriptor = modelManager.availableDescriptor() ?? preferredDescriptor
        guard Self.isRuntimeLinked else {
            throw AIProviderError.providerUnavailable("\(descriptor.displayName) is configured, but the MLX Swift runtime is not linked in this build yet.")
        }
        guard modelManager.availableDescriptor() != nil || allowModelDownloads else {
            throw AIProviderError.providerUnavailable("Local LLM model is not installed and model downloads are disabled.")
        }

        #if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(MLXHuggingFace)
        let prompt = Self.prompt(context: context, question: question, options: options)
        let answer = try await LocalMLXRuntime.shared.generate(prompt: prompt, descriptor: descriptor)
        return GeneratedAnswer(
            text: answer,
            provider: name,
            usedCloud: false,
            usedRAG: !context.ragContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            sources: context.retrievedSources
        )
        #else
        throw AIProviderError.providerUnavailable("Local MLX answers are not available in this build.")
        #endif
    }

    func generateRaw(request: LLMRawRequest) async throws -> LLMRawResponse {
        let descriptor = modelManager.availableDescriptor() ?? preferredDescriptor
        guard Self.isRuntimeLinked else {
            throw AIProviderError.providerUnavailable("\(descriptor.displayName) is configured, but the MLX Swift runtime is not linked in this build yet.")
        }
        guard modelManager.availableDescriptor() != nil || allowModelDownloads else {
            throw AIProviderError.providerUnavailable("Local LLM model is not installed and model downloads are disabled.")
        }

        #if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(MLXHuggingFace)
        let prompt = request.responseMode == .jsonObject
            ? "\(request.prompt)\n\nReturn exactly one valid JSON object and no surrounding prose."
            : request.prompt
        let answer = try await LocalMLXRuntime.shared.generate(prompt: prompt, descriptor: descriptor)
        return LLMRawResponse(text: answer, provider: name, usedCloud: false)
        #else
        throw AIProviderError.providerUnavailable("Local MLX answers are not available in this build.")
        #endif
    }

    func summarizeMeeting(meeting: MeetingSession, transcript: [TranscriptSegment], type: MeetingType) async throws -> MeetingSummary {
        throw AIProviderError.providerUnavailable("Local MLX summaries are not available in this build.")
    }

    func translateSegment(_ segment: TranscriptSegment, targetLanguage: String) async throws -> String {
        throw AIProviderError.providerUnavailable("Use Apple Translation for local meeting translation.")
    }

    func extractActionItems(transcript: [TranscriptSegment]) async throws -> [ActionItem] {
        throw AIProviderError.providerUnavailable("Local MLX action item extraction is not available in this build.")
    }

    func generateInsights(transcriptWindow: [TranscriptSegment]) async throws -> [Insight] {
        throw AIProviderError.providerUnavailable("Local MLX insights are not available in this build.")
    }

    func embed(texts: [String]) async throws -> [[Double]] {
        throw AIProviderError.providerUnavailable("Local MLX embeddings are not available in this build.")
    }

    private static func prompt(context: AnswerContext, question: String, options: AnswerOptions) -> String {
        let transcript = String(context.transcriptWindow.suffix(6_000))
        let completeTranscript = String(context.completeTranscript.suffix(8_000))
        let rag = String(context.ragContext.suffix(4_000))
        let language = context.languageCode ?? "meeting language"
        return """
        You are a local meeting copilot. Answer only the user's current question using the meeting context.
        Be exact, concise, and honest. If the context is insufficient, say that briefly.
        Do not invent facts, commitments, owners, dates, or numbers.
        Maximum sentences: \(options.maxSentences).
        Answer language: \(language).
        User role: \(context.userRole).
        Meeting title: \(context.meetingTitle)

        Current question:
        \(question)

        Recent transcript:
        \(transcript)

        Complete transcript excerpt:
        \(completeTranscript)

        Retrieved local context:
        \(rag)
        """
    }
}

#if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(MLXHuggingFace)
private actor LocalMLXRuntime {
    static let shared = LocalMLXRuntime()

    private var cachedModelIdentifier: String?
    private var cachedContainer: ModelContainer?

    func generate(prompt: String, descriptor: LocalLLMModelDescriptor) async throws -> String {
        let container = try await container(for: descriptor)
        let session = ChatSession(container)
        session.instructions = "You are a fast, precise local Notchly assistant."
        return try await session.respond(to: prompt).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func container(for descriptor: LocalLLMModelDescriptor) async throws -> ModelContainer {
        if let cachedContainer, cachedModelIdentifier == descriptor.modelIdentifier {
            return cachedContainer
        }
        let configuration = ModelConfiguration(id: descriptor.modelIdentifier)
        let container = try await #huggingFaceLoadModelContainer(configuration: configuration)
        cachedModelIdentifier = descriptor.modelIdentifier
        cachedContainer = container
        return container
    }
}
#endif
