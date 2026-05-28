import AVFoundation
import Foundation

@MainActor
protocol TranscriptionService: AnyObject {
    var segments: AsyncStream<TranscriptSegment> { get }
    func startTranscription(audioStream: AsyncStream<AudioBuffer>, config: TranscriptionConfig) async throws
    func stop() async
}

enum TranscriptionError: LocalizedError {
    case recognizerUnavailable
    case speechPermissionDenied
    case cloudProviderUnavailable(String)
    case cloudTranscriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            "Apple Speech is unavailable for the selected language."
        case .speechPermissionDenied:
            "Speech Recognition permission was denied."
        case .cloudProviderUnavailable(let message), .cloudTranscriptionFailed(let message):
            message
        }
    }
}

@MainActor
final class UnavailableTranscriptionService: TranscriptionService {
    private let error: TranscriptionError

    init(error: TranscriptionError = .recognizerUnavailable) {
        self.error = error
    }

    var segments: AsyncStream<TranscriptSegment> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func startTranscription(audioStream: AsyncStream<AudioBuffer>, config: TranscriptionConfig) async throws {
        throw error
    }

    func stop() async {}
}

enum CloudPCM16AudioEncoder {
    static let elevenLabsSampleRate = 16_000

    static func pcm16Chunks(
        from buffer: AudioBuffer,
        targetSampleRate: Double = Double(elevenLabsSampleRate),
        maxBytes: Int = 15_000
    ) throws -> [Data] {
        guard let pcmBuffer = buffer.pcmBuffer else { return [] }
        let data = try pcm16Data(from: pcmBuffer, targetSampleRate: targetSampleRate)
        guard !data.isEmpty else { return [] }
        return data.chunked(maxBytes: maxBytes)
    }

    private static func pcm16Data(from buffer: AVAudioPCMBuffer, targetSampleRate: Double) throws -> Data {
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw TranscriptionError.cloudTranscriptionFailed("Could not create PCM16 encoder.")
        }

        let sourceFormat = buffer.format
        let frameCapacity = AVAudioFrameCount(
            max(1, ceil(Double(buffer.frameLength) * targetSampleRate / max(sourceFormat.sampleRate, 1)) + 512)
        )
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw TranscriptionError.cloudTranscriptionFailed("Could not prepare realtime audio conversion.")
        }

        var didProvideInput = false
        var conversionError: NSError?
        converter.convert(to: outputBuffer, error: &conversionError) { _, status in
            if didProvideInput {
                status.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            status.pointee = .haveData
            return buffer
        }
        if let conversionError {
            throw TranscriptionError.cloudTranscriptionFailed("Could not encode audio for realtime transcription: \(conversionError.localizedDescription)")
        }

        let audioBuffers = UnsafeMutableAudioBufferListPointer(outputBuffer.mutableAudioBufferList)
        guard let firstBuffer = audioBuffers.first,
              let bytes = firstBuffer.mData,
              firstBuffer.mDataByteSize > 0 else {
            return Data()
        }
        return Data(bytes: bytes, count: Int(firstBuffer.mDataByteSize))
    }
}

private extension Data {
    func chunked(maxBytes: Int) -> [Data] {
        guard maxBytes > 0, count > maxBytes else { return [self] }
        var chunks: [Data] = []
        var offset = 0
        while offset < count {
            let end = Swift.min(offset + maxBytes, count)
            chunks.append(subdata(in: offset..<end))
            offset = end
        }
        return chunks
    }
}

struct ElevenLabsRealtimeTranscriptEvent: Equatable {
    enum Kind: Equatable {
        case sessionStarted
        case partial
        case committed
        case error(String)
        case ignored
    }

    var kind: Kind
    var text: String?
    var languageCode: String?
    var words: [TranscriptWordTimestamp]

    static func parse(_ message: URLSessionWebSocketTask.Message) throws -> ElevenLabsRealtimeTranscriptEvent? {
        switch message {
        case .string(let string):
            return try parse(Data(string.utf8))
        case .data(let data):
            return try parse(data)
        @unknown default:
            return nil
        }
    }

    static func parse(_ data: Data) throws -> ElevenLabsRealtimeTranscriptEvent? {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else { return nil }
        let rawType = stringValue(
            dictionary["message_type"],
            dictionary["event_type"],
            dictionary["event"],
            dictionary["type"]
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rawType, !rawType.isEmpty else { return nil }

        let text = stringValue(dictionary["text"], dictionary["transcript"])
        let languageCode = stringValue(dictionary["language_code"], dictionary["languageCode"])
        let words = wordTimestamps(from: dictionary["words"])

        switch rawType {
        case "session_started":
            return ElevenLabsRealtimeTranscriptEvent(kind: .sessionStarted, text: nil, languageCode: languageCode, words: [])
        case "partial_transcript":
            return ElevenLabsRealtimeTranscriptEvent(kind: .partial, text: text, languageCode: languageCode, words: words)
        case "committed_transcript", "committed_transcript_with_timestamps", "final_transcript":
            return ElevenLabsRealtimeTranscriptEvent(kind: .committed, text: text, languageCode: languageCode, words: words)
        default:
            if rawType.lowercased().contains("error") {
                return ElevenLabsRealtimeTranscriptEvent(
                    kind: .error(errorMessage(from: dictionary, type: rawType)),
                    text: nil,
                    languageCode: languageCode,
                    words: []
                )
            }
            return ElevenLabsRealtimeTranscriptEvent(kind: .ignored, text: text, languageCode: languageCode, words: words)
        }
    }

    private static func stringValue(_ values: Any?...) -> String? {
        for value in values {
            if let string = value as? String, !string.isEmpty {
                return string
            }
        }
        return nil
    }

    private static func errorMessage(from dictionary: [String: Any], type: String) -> String {
        if let message = stringValue(dictionary["message"], dictionary["error"], dictionary["detail"]) {
            return message
        }
        if let nested = dictionary["error"] as? [String: Any],
           let message = stringValue(nested["message"], nested["detail"]) {
            return message
        }
        return "ElevenLabs realtime transcription failed with event \(type)."
    }

    private static func wordTimestamps(from value: Any?) -> [TranscriptWordTimestamp] {
        guard let words = value as? [[String: Any]] else { return [] }
        return words.compactMap { word in
            let type = (word["type"] as? String) ?? "word"
            guard type == "word",
                  let text = word["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let start = (word["start"] as? Double) ?? 0
            let end = (word["end"] as? Double) ?? start
            let confidence: Double?
            if let logprob = word["logprob"] as? Double {
                confidence = min(max(exp(logprob), 0), 1)
            } else {
                confidence = nil
            }
            return TranscriptWordTimestamp(word: text, startTime: start, endTime: end, confidence: confidence)
        }
    }
}

@MainActor
final class ElevenLabsRealtimeTranscriptionService: TranscriptionService {
    static let modelID = "scribe_v2_realtime"
    static let endpointPath = "/v1/speech-to-text/realtime"

    private struct InputAudioChunk: Encodable {
        let message_type = "input_audio_chunk"
        let audio_base_64: String
        let commit: Bool
        let sample_rate: Int
        let previous_text: String?

        enum CodingKeys: String, CodingKey {
            case message_type
            case audio_base_64
            case commit
            case sample_rate
            case previous_text
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(message_type, forKey: .message_type)
            try container.encode(audio_base_64, forKey: .audio_base_64)
            try container.encode(commit, forKey: .commit)
            try container.encode(sample_rate, forKey: .sample_rate)
            try container.encodeIfPresent(previous_text, forKey: .previous_text)
        }
    }

    private let authProvider: any AuthProvider
    private let urlSession: URLSession
    private let modelID: String
    private var continuation: AsyncStream<TranscriptSegment>.Continuation?
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var audioPumpTask: Task<Void, Never>?
    private var activeConfig: TranscriptionConfig?
    private var transcriptionStartedAt = Date()
    private var activeSegmentStartedAt: Date?
    private var activeSegmentId = UUID()
    private var isStopping = false

    init(
        authProvider: any AuthProvider,
        modelID: String = ElevenLabsRealtimeTranscriptionService.modelID,
        urlSession: URLSession = OpenAIURLSessionFactory.makeSecureSession()
    ) {
        self.authProvider = authProvider
        self.modelID = modelID
        self.urlSession = urlSession
    }

    var segments: AsyncStream<TranscriptSegment> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func startTranscription(audioStream: AsyncStream<AudioBuffer>, config: TranscriptionConfig) async throws {
        guard modelID == Self.modelID else {
            throw TranscriptionError.cloudProviderUnavailable("ElevenLabs realtime supports only \(Self.modelID).")
        }
        let session = try await authProvider.refreshIfNeeded()
        guard !session.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscriptionError.cloudProviderUnavailable("Save an ElevenLabs API key before using realtime transcription.")
        }

        activeConfig = config
        transcriptionStartedAt = Date()
        activeSegmentStartedAt = nil
        activeSegmentId = UUID()
        isStopping = false

        let requestLanguageCode = config.preferredLanguageHints.count > 1 ? nil : config.languageCode
        var request = URLRequest(url: Self.webSocketURL(modelID: modelID, languageCode: requestLanguageCode))
        request.timeoutInterval = 8
        request.setValue(session.accessToken, forHTTPHeaderField: "xi-api-key")
        let task = urlSession.webSocketTask(with: request)
        webSocketTask = task
        task.resume()
        do {
            if let event = try await Self.receiveInitialEvent(from: task) {
                switch event.kind {
                case .error(let message):
                    throw TranscriptionError.cloudProviderUnavailable(Self.zeroRetentionAwareMessage(message))
                case .partial, .committed:
                    handle(event)
                case .sessionStarted, .ignored:
                    break
                }
            }
        } catch {
            task.cancel(with: .goingAway, reason: nil)
            webSocketTask = nil
            throw error
        }

        receiveTask = Task { @MainActor [weak self] in
            await self?.receiveLoop()
        }
        audioPumpTask = Task { @MainActor [weak self] in
            await self?.sendAudio(from: audioStream)
        }
    }

    func stop() async {
        isStopping = true
        audioPumpTask?.cancel()
        audioPumpTask = nil
        try? await sendAudioChunk(audioBase64: "", commit: true, previousText: nil)
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        continuation?.finish()
        continuation = nil
        activeConfig = nil
    }

    static func webSocketURL(modelID: String = ElevenLabsRealtimeTranscriptionService.modelID, languageCode: String?) -> URL {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = "api.elevenlabs.io"
        components.path = endpointPath
        var items = [
            URLQueryItem(name: "model_id", value: modelID),
            URLQueryItem(name: "enable_logging", value: "false"),
            URLQueryItem(name: "commit_strategy", value: "vad"),
            URLQueryItem(name: "audio_format", value: "pcm_16000"),
            URLQueryItem(name: "include_timestamps", value: "true"),
            URLQueryItem(name: "include_language_detection", value: "true"),
            URLQueryItem(name: "no_verbatim", value: "false")
        ]
        if let languageCode = normalizedElevenLabsLanguageCode(languageCode) {
            items.append(URLQueryItem(name: "language_code", value: languageCode))
        }
        components.queryItems = items
        return components.url!
    }

    static func inputAudioChunkPayload(audioBase64: String, commit: Bool, previousText: String? = nil) throws -> String {
        let payload = InputAudioChunk(
            audio_base_64: audioBase64,
            commit: commit,
            sample_rate: CloudPCM16AudioEncoder.elevenLabsSampleRate,
            previous_text: previousText
        )
        let data = try JSONEncoder().encode(payload)
        guard let string = String(data: data, encoding: .utf8) else {
            throw TranscriptionError.cloudTranscriptionFailed("Could not encode ElevenLabs realtime message.")
        }
        return string
    }

    static func validateAPIKey(_ apiKey: String, modelID: String = ElevenLabsRealtimeTranscriptionService.modelID, languageCode: String?) async throws {
        var request = URLRequest(url: webSocketURL(modelID: modelID, languageCode: languageCode))
        request.timeoutInterval = 8
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        let session = OpenAIURLSessionFactory.makeSecureSession()
        let task = session.webSocketTask(with: request)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        guard let event = try await receiveInitialEvent(from: task) else { return }
        switch event.kind {
        case .sessionStarted, .committed, .partial, .ignored:
            return
        case .error(let message):
            throw TranscriptionError.cloudProviderUnavailable(zeroRetentionAwareMessage(message))
        }
    }

    private static func receiveInitialEvent(from task: URLSessionWebSocketTask) async throws -> ElevenLabsRealtimeTranscriptEvent? {
        try await withThrowingTaskGroup(of: ElevenLabsRealtimeTranscriptEvent?.self) { group in
            group.addTask {
                let message = try await task.receive()
                return try ElevenLabsRealtimeTranscriptEvent.parse(message)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 8_000_000_000)
                throw TranscriptionError.cloudTranscriptionFailed("ElevenLabs realtime did not confirm the session before timeout.")
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
    }

    private static func normalizedElevenLabsLanguageCode(_ languageCode: String?) -> String? {
        guard let languageCode = languageCode?.trimmingCharacters(in: .whitespacesAndNewlines),
              !languageCode.isEmpty else { return nil }
        let normalized = SupportedLanguage.normalizedCode(languageCode)
        if normalized.count == 2 || normalized.count == 3 {
            return normalized.lowercased()
        }
        if let prefix = normalized.split(separator: "-").first, prefix.count == 2 || prefix.count == 3 {
            return String(prefix).lowercased()
        }
        return nil
    }

    private static func zeroRetentionAwareMessage(_ message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("zero") || lower.contains("logging") || lower.contains("retention") || lower.contains("enterprise") {
            return "ElevenLabs zero retention is required but this key/account was rejected: \(message)"
        }
        return message
    }

    private func receiveLoop() async {
        while !Task.isCancelled, let webSocketTask {
            do {
                let message = try await webSocketTask.receive()
                guard let event = try ElevenLabsRealtimeTranscriptEvent.parse(message) else { continue }
                handle(event)
            } catch {
                if !isStopping {
                    AppLog.ai.error("ElevenLabs realtime receive failed: \(error.localizedDescription, privacy: .public)")
                }
                break
            }
        }
    }

    private func sendAudio(from stream: AsyncStream<AudioBuffer>) async {
        do {
            for await buffer in stream {
                try Task.checkCancellation()
                let chunks = try CloudPCM16AudioEncoder.pcm16Chunks(from: buffer)
                for chunk in chunks {
                    try Task.checkCancellation()
                    try await sendAudioChunk(audioBase64: chunk.base64EncodedString(), commit: false, previousText: nil)
                }
            }
            try await sendAudioChunk(audioBase64: "", commit: true, previousText: nil)
        } catch is CancellationError {
            return
        } catch {
            if !isStopping {
                AppLog.ai.error("ElevenLabs realtime send failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func sendAudioChunk(audioBase64: String, commit: Bool, previousText: String?) async throws {
        guard let webSocketTask else { return }
        let payload = try Self.inputAudioChunkPayload(audioBase64: audioBase64, commit: commit, previousText: previousText)
        try await webSocketTask.send(.string(payload))
    }

    private func handle(_ event: ElevenLabsRealtimeTranscriptEvent) {
        switch event.kind {
        case .partial:
            emitSegment(event: event, isFinal: false)
        case .committed:
            emitSegment(event: event, isFinal: true)
            activeSegmentStartedAt = nil
            activeSegmentId = UUID()
        case .error(let message):
            AppLog.ai.error("ElevenLabs realtime event failed: \(Self.zeroRetentionAwareMessage(message), privacy: .public)")
        case .sessionStarted, .ignored:
            break
        }
    }

    private func emitSegment(event: ElevenLabsRealtimeTranscriptEvent, isFinal: Bool) {
        guard let config = activeConfig,
              let text = event.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return }
        let now = Date()
        if activeSegmentStartedAt == nil {
            activeSegmentStartedAt = now
        }
        let startTime = activeSegmentStartedAt?.timeIntervalSince(transcriptionStartedAt) ?? 0
        let endTime = max(startTime, now.timeIntervalSince(transcriptionStartedAt))
        let segment = TranscriptSegment(
            id: activeSegmentId,
            meetingId: config.meetingId,
            speakerLabel: speakerLabel(for: config.audioSource),
            audioSource: config.audioSource,
            text: text,
            originalLanguage: event.languageCode ?? config.languageCode,
            transcriptionPhase: isFinal ? .final : .draft,
            transcriptionEngine: .elevenLabs,
            finalizedBy: isFinal ? .elevenLabs : nil,
            wordTimestamps: event.words,
            startTime: startTime,
            endTime: endTime,
            confidence: isFinal ? 0.88 : 0.72,
            isFinal: isFinal,
            createdAt: now
        )
        continuation?.yield(segment)
    }

    private func speakerLabel(for audioSource: TranscriptAudioSource) -> String {
        switch audioSource {
        case .microphone: "You"
        case .system: "System"
        default: "Speaker 1"
        }
    }
}

@MainActor
final class MultiSourceCloudRealtimeTranscriptionService: TranscriptionService {
    struct Source {
        var speakerLabel: String
        var audioSource: TranscriptAudioSource
        var audioStream: AsyncStream<AudioBuffer>
    }

    private let sources: [Source]
    private let serviceFactory: () -> any TranscriptionService
    private var services: [any TranscriptionService] = []
    private var forwardingTasks: [Task<Void, Never>] = []
    private var continuation: AsyncStream<TranscriptSegment>.Continuation?

    init(sources: [Source], serviceFactory: @escaping () -> any TranscriptionService) {
        self.sources = sources
        self.serviceFactory = serviceFactory
    }

    var segments: AsyncStream<TranscriptSegment> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func startTranscription(audioStream: AsyncStream<AudioBuffer>, config: TranscriptionConfig) async throws {
        guard !sources.isEmpty else {
            throw TranscriptionError.cloudProviderUnavailable("No audio source is available for cloud realtime transcription.")
        }
        services = []
        forwardingTasks = []
        do {
            for source in sources {
                let service = serviceFactory()
                let segmentStream = service.segments
                forwardingTasks.append(Task { @MainActor [weak self, speakerLabel = source.speakerLabel, audioSource = source.audioSource] in
                    for await segment in segmentStream {
                        self?.continuation?.yield(Self.relabeled(segment, speakerLabel: speakerLabel, audioSource: audioSource))
                    }
                })
                var sourceConfig = config
                sourceConfig.audioSource = source.audioSource
                try await service.startTranscription(audioStream: source.audioStream, config: sourceConfig)
                services.append(service)
            }
        } catch {
            await stop()
            throw error
        }
    }

    func stop() async {
        for service in services {
            await service.stop()
        }
        services = []
        forwardingTasks.forEach { $0.cancel() }
        forwardingTasks = []
        continuation?.finish()
        continuation = nil
    }

    static func relabeled(_ segment: TranscriptSegment, speakerLabel: String, audioSource: TranscriptAudioSource) -> TranscriptSegment {
        var labeledSegment = segment
        labeledSegment.speakerLabel = speakerLabel
        labeledSegment.audioSource = audioSource
        return labeledSegment
    }
}
