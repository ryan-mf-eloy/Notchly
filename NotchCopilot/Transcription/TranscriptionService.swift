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
    static let openAISampleRate = 24_000
    static let geminiLiveSampleRate = 16_000

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

private func cloudTranscriptionStringValue(_ values: Any?...) -> String? {
    for value in values {
        if let string = value as? String, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return string
        }
    }
    return nil
}

private func cloudTranscriptionDictionaryValue(_ values: Any?...) -> [String: Any]? {
    for value in values {
        if let dictionary = value as? [String: Any] {
            return dictionary
        }
    }
    return nil
}

private func cloudTranscriptionBoolValue(_ values: Any?...) -> Bool? {
    for value in values {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
    }
    return nil
}

private func cloudRealtimeSpeakerLabel(for audioSource: TranscriptAudioSource) -> String {
    switch audioSource {
    case .microphone: "You"
    case .system: "System"
    default: "Speaker 1"
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
            speakerLabel: cloudRealtimeSpeakerLabel(for: config.audioSource),
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

}

struct OpenAIRealtimeTranscriptEvent: Equatable {
    enum Kind: Equatable {
        case sessionReady
        case delta
        case completed
        case error(String)
        case ignored
    }

    var kind: Kind
    var itemID: String?
    var text: String?

    static func parse(_ message: URLSessionWebSocketTask.Message) throws -> OpenAIRealtimeTranscriptEvent? {
        switch message {
        case .string(let string):
            return try parse(Data(string.utf8))
        case .data(let data):
            return try parse(data)
        @unknown default:
            return nil
        }
    }

    static func parse(_ data: Data) throws -> OpenAIRealtimeTranscriptEvent? {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else { return nil }
        let rawType = cloudTranscriptionStringValue(dictionary["type"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rawType, !rawType.isEmpty else { return nil }
        let itemID = cloudTranscriptionStringValue(dictionary["item_id"], dictionary["itemId"])

        switch rawType {
        case "session.created", "session.updated", "transcription_session.created", "transcription_session.updated":
            return OpenAIRealtimeTranscriptEvent(kind: .sessionReady, itemID: itemID, text: nil)
        case "conversation.item.input_audio_transcription.delta":
            return OpenAIRealtimeTranscriptEvent(kind: .delta, itemID: itemID, text: cloudTranscriptionStringValue(dictionary["delta"], dictionary["text"]))
        case "conversation.item.input_audio_transcription.completed":
            return OpenAIRealtimeTranscriptEvent(kind: .completed, itemID: itemID, text: cloudTranscriptionStringValue(dictionary["transcript"], dictionary["text"]))
        default:
            if rawType.lowercased().contains("error") {
                return OpenAIRealtimeTranscriptEvent(kind: .error(errorMessage(from: dictionary, type: rawType)), itemID: itemID, text: nil)
            }
            return OpenAIRealtimeTranscriptEvent(kind: .ignored, itemID: itemID, text: nil)
        }
    }

    private static func errorMessage(from dictionary: [String: Any], type: String) -> String {
        if let nested = dictionary["error"] as? [String: Any],
           let message = cloudTranscriptionStringValue(nested["message"], nested["detail"], nested["code"]) {
            return message
        }
        if let message = cloudTranscriptionStringValue(dictionary["message"], dictionary["detail"]) {
            return message
        }
        return "OpenAI realtime transcription failed with event \(type)."
    }
}

@MainActor
final class OpenAIRealtimeTranscriptionService: TranscriptionService {
    static let modelID = "gpt-realtime-whisper"
    static let endpointPath = "/v1/realtime"
    static let manualCommitMinimumBytes = CloudPCM16AudioEncoder.openAISampleRate * 2
    static let manualCommitMaximumInterval: TimeInterval = 1.0

    private let authProvider: any AuthProvider
    private let urlSession: URLSession
    private let modelID: String
    private let transcriptionDelay: String
    private var continuation: AsyncStream<TranscriptSegment>.Continuation?
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var audioPumpTask: Task<Void, Never>?
    private var activeConfig: TranscriptionConfig?
    private var transcriptionStartedAt = Date()
    private var activeSegmentStartedAtByItemID: [String: Date] = [:]
    private var segmentIDByItemID: [String: UUID] = [:]
    private var textByItemID: [String: String] = [:]
    private var isStopping = false
    private var pendingCommitByteCount = 0
    private var lastManualCommitAt = Date.distantPast

    init(
        authProvider: any AuthProvider,
        modelID: String = OpenAIRealtimeTranscriptionService.modelID,
        transcriptionDelay: String = "low",
        urlSession: URLSession = OpenAIURLSessionFactory.makeSecureSession()
    ) {
        self.authProvider = authProvider
        self.modelID = modelID
        self.transcriptionDelay = transcriptionDelay
        self.urlSession = urlSession
    }

    var segments: AsyncStream<TranscriptSegment> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func startTranscription(audioStream: AsyncStream<AudioBuffer>, config: TranscriptionConfig) async throws {
        let session = try await authProvider.refreshIfNeeded()
        guard !session.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscriptionError.cloudProviderUnavailable("Save an OpenAI API key before using realtime transcription.")
        }

        activeConfig = config
        transcriptionStartedAt = Date()
        activeSegmentStartedAtByItemID = [:]
        segmentIDByItemID = [:]
        textByItemID = [:]
        isStopping = false
        pendingCommitByteCount = 0
        lastManualCommitAt = Date()

        var request = URLRequest(url: Self.webSocketURL(modelID: modelID))
        request.timeoutInterval = 8
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
        let task = urlSession.webSocketTask(with: request)
        webSocketTask = task
        task.resume()
        do {
            try await sendSessionUpdate(on: task, languageCode: config.languageCode)
            if let event = try await Self.receiveInitialEvent(from: task) {
                switch event.kind {
                case .error(let message):
                    throw TranscriptionError.cloudProviderUnavailable(message)
                case .delta, .completed:
                    handle(event)
                case .sessionReady, .ignored:
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
        try? await commitAudioBufferIfNeeded(force: true)
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        continuation?.finish()
        continuation = nil
        activeConfig = nil
        textByItemID = [:]
    }

    static func webSocketURL(modelID: String = OpenAIRealtimeTranscriptionService.modelID) -> URL {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = "api.openai.com"
        components.path = endpointPath
        components.queryItems = [URLQueryItem(name: "model", value: modelID)]
        return components.url!
    }

    static func sessionUpdatePayload(modelID: String = OpenAIRealtimeTranscriptionService.modelID, languageCode: String?, transcriptionDelay: String = "low") throws -> String {
        var transcription: [String: Any] = [
            "model": modelID,
            "delay": transcriptionDelay
        ]
        if let languageCode = normalizedLanguageCode(languageCode) {
            transcription["language"] = languageCode
        }
        let payload: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": CloudPCM16AudioEncoder.openAISampleRate
                        ],
                        "noise_reduction": [
                            "type": "near_field"
                        ],
                        "transcription": transcription,
                        "turn_detection": NSNull()
                    ]
                ],
                "include": [
                    "item.input_audio_transcription.logprobs"
                ]
            ]
        ]
        return try jsonString(from: payload, errorMessage: "Could not encode OpenAI realtime session update.")
    }

    static func appendAudioPayload(audioBase64: String) throws -> String {
        let payload: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": audioBase64
        ]
        return try jsonString(from: payload, errorMessage: "Could not encode OpenAI realtime audio message.")
    }

    static func commitAudioPayload() throws -> String {
        try jsonString(from: ["type": "input_audio_buffer.commit"], errorMessage: "Could not encode OpenAI realtime commit message.")
    }

    static func shouldCommitAudioBuffer(pendingBytes: Int, elapsedSinceLastCommit: TimeInterval) -> Bool {
        guard pendingBytes > 0 else { return false }
        return pendingBytes >= manualCommitMinimumBytes || elapsedSinceLastCommit >= manualCommitMaximumInterval
    }

    static func validateAPIKey(_ apiKey: String, modelID: String = OpenAIRealtimeTranscriptionService.modelID, languageCode: String?) async throws {
        var request = URLRequest(url: webSocketURL(modelID: modelID))
        request.timeoutInterval = 8
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
        let session = OpenAIURLSessionFactory.makeSecureSession()
        let task = session.webSocketTask(with: request)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        try await task.send(.string(sessionUpdatePayload(modelID: modelID, languageCode: languageCode)))
        guard let event = try await receiveInitialEvent(from: task) else { return }
        switch event.kind {
        case .sessionReady, .delta, .completed, .ignored:
            return
        case .error(let message):
            throw TranscriptionError.cloudProviderUnavailable(message)
        }
    }

    private static func receiveInitialEvent(from task: URLSessionWebSocketTask) async throws -> OpenAIRealtimeTranscriptEvent? {
        try await withThrowingTaskGroup(of: OpenAIRealtimeTranscriptEvent?.self) { group in
            group.addTask {
                let message = try await task.receive()
                return try OpenAIRealtimeTranscriptEvent.parse(message)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 8_000_000_000)
                throw TranscriptionError.cloudTranscriptionFailed("OpenAI realtime did not confirm the session before timeout.")
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
    }

    private static func normalizedLanguageCode(_ languageCode: String?) -> String? {
        guard let languageCode = languageCode?.trimmingCharacters(in: .whitespacesAndNewlines),
              !languageCode.isEmpty else { return nil }
        let normalized = SupportedLanguage.normalizedCode(languageCode)
        guard let prefix = normalized.split(separator: "-").first, prefix.count == 2 else { return nil }
        return String(prefix).lowercased()
    }

    private static func jsonString(from object: Any, errorMessage: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        guard let string = String(data: data, encoding: .utf8) else {
            throw TranscriptionError.cloudTranscriptionFailed(errorMessage)
        }
        return string
    }

    private func sendSessionUpdate(on task: URLSessionWebSocketTask, languageCode: String?) async throws {
        try await task.send(.string(Self.sessionUpdatePayload(modelID: modelID, languageCode: languageCode, transcriptionDelay: transcriptionDelay)))
    }

    private func receiveLoop() async {
        while !Task.isCancelled, let webSocketTask {
            do {
                let message = try await webSocketTask.receive()
                guard let event = try OpenAIRealtimeTranscriptEvent.parse(message) else { continue }
                handle(event)
            } catch {
                if !isStopping {
                    AppLog.ai.error("OpenAI realtime receive failed: \(error.localizedDescription, privacy: .public)")
                }
                break
            }
        }
    }

    private func sendAudio(from stream: AsyncStream<AudioBuffer>) async {
        do {
            for await buffer in stream {
                try Task.checkCancellation()
                let chunks = try CloudPCM16AudioEncoder.pcm16Chunks(
                    from: buffer,
                    targetSampleRate: Double(CloudPCM16AudioEncoder.openAISampleRate),
                    maxBytes: 24_000
                )
                for chunk in chunks {
                    try Task.checkCancellation()
                    try await sendAudioChunk(chunk)
                    try await commitAudioBufferIfNeeded(force: false)
                }
            }
            try await commitAudioBufferIfNeeded(force: true)
        } catch is CancellationError {
            return
        } catch {
            if !isStopping {
                AppLog.ai.error("OpenAI realtime send failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func sendAudioChunk(_ chunk: Data) async throws {
        guard let webSocketTask else { return }
        let payload = try Self.appendAudioPayload(audioBase64: chunk.base64EncodedString())
        try await webSocketTask.send(.string(payload))
        pendingCommitByteCount += chunk.count
    }

    private func commitAudioBufferIfNeeded(force: Bool) async throws {
        guard let webSocketTask else { return }
        let elapsed = Date().timeIntervalSince(lastManualCommitAt)
        guard force ? pendingCommitByteCount > 0 : Self.shouldCommitAudioBuffer(pendingBytes: pendingCommitByteCount, elapsedSinceLastCommit: elapsed) else {
            return
        }
        try await webSocketTask.send(.string(try Self.commitAudioPayload()))
        pendingCommitByteCount = 0
        lastManualCommitAt = Date()
    }

    private func handle(_ event: OpenAIRealtimeTranscriptEvent) {
        switch event.kind {
        case .delta:
            emitSegment(event: event, isFinal: false)
        case .completed:
            emitSegment(event: event, isFinal: true)
            let itemID = normalizedItemID(event.itemID)
            activeSegmentStartedAtByItemID[itemID] = nil
            segmentIDByItemID[itemID] = nil
            textByItemID[itemID] = nil
        case .error(let message):
            AppLog.ai.error("OpenAI realtime event failed: \(message, privacy: .public)")
        case .sessionReady, .ignored:
            break
        }
    }

    private func emitSegment(event: OpenAIRealtimeTranscriptEvent, isFinal: Bool) {
        guard let config = activeConfig,
              let text = mergedText(for: event, isFinal: isFinal)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return }
        let itemID = normalizedItemID(event.itemID)
        let now = Date()
        if activeSegmentStartedAtByItemID[itemID] == nil {
            activeSegmentStartedAtByItemID[itemID] = now
        }
        let startTime = activeSegmentStartedAtByItemID[itemID]?.timeIntervalSince(transcriptionStartedAt) ?? 0
        let endTime = max(startTime, now.timeIntervalSince(transcriptionStartedAt))
        let segmentID = segmentIDByItemID[itemID] ?? UUID()
        segmentIDByItemID[itemID] = segmentID
        let segment = TranscriptSegment(
            id: segmentID,
            meetingId: config.meetingId,
            speakerLabel: cloudRealtimeSpeakerLabel(for: config.audioSource),
            audioSource: config.audioSource,
            text: text,
            originalLanguage: config.languageCode,
            transcriptionPhase: isFinal ? .final : .draft,
            transcriptionEngine: .openAIRealtime,
            finalizedBy: isFinal ? .openAIRealtime : nil,
            startTime: startTime,
            endTime: endTime,
            confidence: isFinal ? 0.86 : 0.70,
            isFinal: isFinal,
            createdAt: now
        )
        continuation?.yield(segment)
    }

    private func mergedText(for event: OpenAIRealtimeTranscriptEvent, isFinal: Bool) -> String? {
        guard let text = event.text, !text.isEmpty else { return nil }
        let itemID = normalizedItemID(event.itemID)
        if isFinal {
            textByItemID[itemID] = text
            return text
        }
        let merged = (textByItemID[itemID] ?? "") + text
        textByItemID[itemID] = merged
        return merged
    }

    private func normalizedItemID(_ itemID: String?) -> String {
        itemID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? itemID! : "default"
    }
}

struct GeminiLiveTranscriptEvent: Equatable {
    enum Kind: Equatable {
        case setupComplete
        case inputTranscription
        case error(String)
        case ignored
    }

    var kind: Kind
    var text: String?
    var isFinal: Bool

    static func parse(_ message: URLSessionWebSocketTask.Message) throws -> GeminiLiveTranscriptEvent? {
        switch message {
        case .string(let string):
            return try parse(Data(string.utf8))
        case .data(let data):
            return try parse(data)
        @unknown default:
            return nil
        }
    }

    static func parse(_ data: Data) throws -> GeminiLiveTranscriptEvent? {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else { return nil }

        if dictionary["setupComplete"] != nil || dictionary["setup_complete"] != nil {
            return GeminiLiveTranscriptEvent(kind: .setupComplete, text: nil, isFinal: false)
        }
        if let error = dictionary["error"] as? [String: Any] {
            return GeminiLiveTranscriptEvent(kind: .error(errorMessage(from: error)), text: nil, isFinal: false)
        }
        if let message = cloudTranscriptionStringValue(dictionary["error"], dictionary["message"]) {
            return GeminiLiveTranscriptEvent(kind: .error(message), text: nil, isFinal: false)
        }

        guard let serverContent = cloudTranscriptionDictionaryValue(dictionary["serverContent"], dictionary["server_content"]) else {
            return GeminiLiveTranscriptEvent(kind: .ignored, text: nil, isFinal: false)
        }
        let transcription = cloudTranscriptionDictionaryValue(serverContent["inputTranscription"], serverContent["input_transcription"])
        let text = cloudTranscriptionStringValue(transcription?["text"], transcription?["transcript"])
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let isFinal = cloudTranscriptionBoolValue(
                transcription?["final"],
                transcription?["isFinal"],
                transcription?["is_final"],
                serverContent["turnComplete"],
                serverContent["turn_complete"]
            ) ?? false
            return GeminiLiveTranscriptEvent(kind: .inputTranscription, text: text, isFinal: isFinal)
        }
        return GeminiLiveTranscriptEvent(kind: .ignored, text: nil, isFinal: false)
    }

    private static func errorMessage(from dictionary: [String: Any]) -> String {
        cloudTranscriptionStringValue(dictionary["message"], dictionary["detail"], dictionary["status"], dictionary["code"])
            ?? "Gemini Live transcription failed."
    }
}

@MainActor
final class GeminiLiveRealtimeTranscriptionService: TranscriptionService {
    static let modelID = "gemini-3.1-flash-live-preview"
    static let fallbackModelIDs = ["gemini-2.5-flash-live-preview"]
    static let endpointPath = "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

    enum SetupEnvelope: CaseIterable {
        case setup
        case config
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
        modelID: String = GeminiLiveRealtimeTranscriptionService.modelID,
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
        let session = try await authProvider.refreshIfNeeded()
        guard !session.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscriptionError.cloudProviderUnavailable("Save a Google Gemini API key before using Live transcription.")
        }

        activeConfig = config
        transcriptionStartedAt = Date()
        activeSegmentStartedAt = nil
        activeSegmentId = UUID()
        isStopping = false

        let (task, initialEvent) = try await Self.configuredWebSocketTask(
            apiKey: session.accessToken,
            modelID: modelID,
            languageCode: config.languageCode,
            urlSession: urlSession
        )
        webSocketTask = task
        if let event = initialEvent {
            switch event.kind {
            case .error(let message):
                task.cancel(with: .goingAway, reason: nil)
                webSocketTask = nil
                throw TranscriptionError.cloudProviderUnavailable(message)
            case .inputTranscription:
                handle(event)
            case .setupComplete, .ignored:
                break
            }
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
        try? await sendAudioStreamEnd()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        continuation?.finish()
        continuation = nil
        activeConfig = nil
    }

    static func webSocketURL(apiKey: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = "generativelanguage.googleapis.com"
        components.path = endpointPath
        if let apiKey, !apiKey.isEmpty {
            components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        }
        return components.url!
    }

    static func setupPayload(
        modelID: String = GeminiLiveRealtimeTranscriptionService.modelID,
        languageCode: String?,
        envelope: SetupEnvelope = .setup
    ) throws -> String {
        var setup: [String: Any] = [
            "model": "models/\(modelID)",
            "systemInstruction": [
                "parts": [
                    [
                        "text": "Transcribe the user's audio. Do not answer questions or produce commentary."
                    ]
                ]
            ],
            "inputAudioTranscription": [String: Any]()
        ]
        switch envelope {
        case .setup:
            setup["generationConfig"] = [
                "responseModalities": ["TEXT"]
            ]
        case .config:
            setup["responseModalities"] = ["TEXT"]
        }
        if let languageCode = normalizedLanguageCode(languageCode) {
            setup["realtimeInputConfig"] = [
                "automaticActivityDetection": [:],
                "languageCode": languageCode
            ]
        }
        let rootKey = envelope == .setup ? "setup" : "config"
        return try jsonString(from: [rootKey: setup], errorMessage: "Could not encode Gemini Live setup message.")
    }

    static func audioPayload(audioBase64: String) throws -> String {
        let payload: [String: Any] = [
            "realtimeInput": [
                "audio": [
                    "mimeType": "audio/pcm;rate=\(CloudPCM16AudioEncoder.geminiLiveSampleRate)",
                    "data": audioBase64
                ]
            ]
        ]
        return try jsonString(from: payload, errorMessage: "Could not encode Gemini Live audio message.")
    }

    static func audioStreamEndPayload() throws -> String {
        let payload: [String: Any] = [
            "realtimeInput": [
                "audioStreamEnd": true
            ]
        ]
        return try jsonString(from: payload, errorMessage: "Could not encode Gemini Live audio end message.")
    }

    static func validateAPIKey(_ apiKey: String, modelID: String = GeminiLiveRealtimeTranscriptionService.modelID, languageCode: String?) async throws {
        let session = OpenAIURLSessionFactory.makeSecureSession()
        let (task, event) = try await configuredWebSocketTask(
            apiKey: apiKey,
            modelID: modelID,
            languageCode: languageCode,
            urlSession: session
        )
        defer { task.cancel(with: .goingAway, reason: nil) }

        guard let event else { return }
        switch event.kind {
        case .setupComplete, .inputTranscription, .ignored:
            return
        case .error(let message):
            throw TranscriptionError.cloudProviderUnavailable(message)
        }
    }

    private static func configuredWebSocketTask(
        apiKey: String,
        modelID: String,
        languageCode: String?,
        urlSession: URLSession
    ) async throws -> (URLSessionWebSocketTask, GeminiLiveTranscriptEvent?) {
        var lastError: Error?
        for envelope in SetupEnvelope.allCases {
            var request = URLRequest(url: webSocketURL(apiKey: apiKey))
            request.timeoutInterval = 8
            let task = urlSession.webSocketTask(with: request)
            task.resume()
            do {
                try await task.send(.string(setupPayload(modelID: modelID, languageCode: languageCode, envelope: envelope)))
                let event = try await receiveInitialEvent(from: task)
                if case .error(let message) = event?.kind {
                    lastError = TranscriptionError.cloudProviderUnavailable(message)
                    task.cancel(with: .goingAway, reason: nil)
                    continue
                }
                return (task, event)
            } catch {
                lastError = error
                task.cancel(with: .goingAway, reason: nil)
            }
        }
        throw lastError ?? TranscriptionError.cloudProviderUnavailable("Gemini Live could not be configured.")
    }

    private static func receiveInitialEvent(from task: URLSessionWebSocketTask) async throws -> GeminiLiveTranscriptEvent? {
        try await withThrowingTaskGroup(of: GeminiLiveTranscriptEvent?.self) { group in
            group.addTask {
                let message = try await task.receive()
                return try GeminiLiveTranscriptEvent.parse(message)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 8_000_000_000)
                throw TranscriptionError.cloudTranscriptionFailed("Gemini Live did not confirm the session before timeout.")
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
    }

    private static func normalizedLanguageCode(_ languageCode: String?) -> String? {
        guard let languageCode = languageCode?.trimmingCharacters(in: .whitespacesAndNewlines),
              !languageCode.isEmpty else { return nil }
        return SupportedLanguage.normalizedCode(languageCode)
    }

    private static func jsonString(from object: Any, errorMessage: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        guard let string = String(data: data, encoding: .utf8) else {
            throw TranscriptionError.cloudTranscriptionFailed(errorMessage)
        }
        return string
    }

    private func receiveLoop() async {
        while !Task.isCancelled, let webSocketTask {
            do {
                let message = try await webSocketTask.receive()
                guard let event = try GeminiLiveTranscriptEvent.parse(message) else { continue }
                handle(event)
            } catch {
                if !isStopping {
                    AppLog.ai.error("Gemini Live receive failed: \(error.localizedDescription, privacy: .public)")
                }
                break
            }
        }
    }

    private func sendAudio(from stream: AsyncStream<AudioBuffer>) async {
        do {
            for await buffer in stream {
                try Task.checkCancellation()
                let chunks = try CloudPCM16AudioEncoder.pcm16Chunks(
                    from: buffer,
                    targetSampleRate: Double(CloudPCM16AudioEncoder.geminiLiveSampleRate),
                    maxBytes: 16_000
                )
                for chunk in chunks {
                    try Task.checkCancellation()
                    try await sendAudioChunk(audioBase64: chunk.base64EncodedString())
                }
            }
            try await sendAudioStreamEnd()
        } catch is CancellationError {
            return
        } catch {
            if !isStopping {
                AppLog.ai.error("Gemini Live send failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func sendAudioChunk(audioBase64: String) async throws {
        guard let webSocketTask else { return }
        let payload = try Self.audioPayload(audioBase64: audioBase64)
        try await webSocketTask.send(.string(payload))
    }

    private func sendAudioStreamEnd() async throws {
        guard let webSocketTask else { return }
        try await webSocketTask.send(.string(try Self.audioStreamEndPayload()))
    }

    private func handle(_ event: GeminiLiveTranscriptEvent) {
        switch event.kind {
        case .inputTranscription:
            emitSegment(text: event.text, isFinal: event.isFinal)
            if event.isFinal {
                activeSegmentStartedAt = nil
                activeSegmentId = UUID()
            }
        case .error(let message):
            AppLog.ai.error("Gemini Live event failed: \(message, privacy: .public)")
        case .setupComplete, .ignored:
            break
        }
    }

    private func emitSegment(text: String?, isFinal: Bool) {
        guard let config = activeConfig,
              let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
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
            speakerLabel: cloudRealtimeSpeakerLabel(for: config.audioSource),
            audioSource: config.audioSource,
            text: text,
            originalLanguage: config.languageCode,
            transcriptionPhase: isFinal ? .final : .draft,
            transcriptionEngine: .googleGeminiLive,
            finalizedBy: isFinal ? .googleGeminiLive : nil,
            startTime: startTime,
            endTime: endTime,
            confidence: isFinal ? 0.82 : 0.66,
            isFinal: isFinal,
            createdAt: now
        )
        continuation?.yield(segment)
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
