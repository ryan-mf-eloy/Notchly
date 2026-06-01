import CryptoKit
import Foundation
import NaturalLanguage

#if canImport(CoreML)
import CoreML
#endif

@MainActor
struct LocalEmbeddingProvider: EmbeddingProvider {
    var tier: LocalEmbeddingTier
    var requestedRuntime: LocalEmbeddingRuntimeKind
    var allowModelDownloads: Bool
    var allowMetalAcceleration: Bool
    var serverConfiguration: LocalEmbeddingServerConfiguration
    var modelManager: LocalEmbeddingModelManager
    var urlSession: URLSession

    init(
        tier: LocalEmbeddingTier = .fast,
        runtime: LocalEmbeddingRuntimeKind = .automatic,
        allowModelDownloads: Bool = false,
        allowMetalAcceleration: Bool = true,
        serverConfiguration: LocalEmbeddingServerConfiguration = LocalEmbeddingServerConfiguration(),
        modelManager: LocalEmbeddingModelManager = LocalEmbeddingModelManager(),
        urlSession: URLSession = .shared
    ) {
        self.tier = tier
        self.requestedRuntime = runtime
        self.allowModelDownloads = allowModelDownloads
        self.allowMetalAcceleration = allowMetalAcceleration
        self.serverConfiguration = serverConfiguration.normalized(defaultDimensions: tier.dimensions)
        self.modelManager = modelManager
        self.urlSession = urlSession
    }

    var activeRuntime: LocalEmbeddingRuntimeKind {
        if requestedRuntime == .localServer {
            return .localServer
        }
        if requestedRuntime == .automatic,
           tier == .advanced,
           serverConfiguration.isUsable {
            return .localServer
        }
        return modelManager.resolvedRuntime(
            tier: tier,
            requested: requestedRuntime,
            allowDownloads: allowModelDownloads,
            allowMetalAcceleration: allowMetalAcceleration
        )
    }

    var modelIdentifier: String {
        if activeRuntime == .localServer {
            let modelKey = serverConfiguration.trimmedModel
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: ":", with: "_")
            return "notchly-local-server-\(modelKey)-\(dimensions)d"
        }
        return "\(tier.modelIdentifier)-\(activeRuntime.storageSuffix)"
    }

    var dimensions: Int {
        if activeRuntime == .localServer, let dimensions = serverConfiguration.normalizedDimensions {
            return dimensions
        }
        return tier.dimensions
    }

    var executionScope: EmbeddingProviderExecutionScope {
        activeRuntime == .localServer ? .localLoopback : .localDevice
    }

    func embed(_ texts: [String]) async throws -> [[Double]] {
        let runtime = activeRuntime
        if runtime == .localServer {
            return try await embedWithLocalServerAndCache(texts, runtime: runtime)
        }
        if runtime == .coreML,
           let package = modelManager.coreMLPackage(tier: tier) {
            return try await embedWithCoreMLAndCache(texts, package: package)
        }
        if runtime == .mlx,
           let descriptor = modelManager.descriptor(tier: tier, runtime: runtime) {
            return try await embedWithMLXAndCache(texts, descriptor: descriptor, runtime: runtime)
        }

        return texts.map { text in
            let cacheKey = Self.cacheKey(for: text, modelIdentifier: modelIdentifier)
            if let cached = Self.embeddingCache[cacheKey] {
                return cached
            }
            let vector = embedOne(text, runtime: runtime)
            Self.storeCachedEmbedding(vector, for: cacheKey)
            return vector
        }
    }

    func prewarm() async {
        _ = try? await embed("notchly local embedding warmup")
    }

    static func executableRuntime(for tier: LocalEmbeddingTier, requested: LocalEmbeddingRuntimeKind) -> LocalEmbeddingRuntimeKind {
        LocalEmbeddingModelManager().resolvedRuntime(tier: tier, requested: requested, allowDownloads: false)
    }

    private func embedWithLocalServerAndCache(
        _ texts: [String],
        runtime: LocalEmbeddingRuntimeKind
    ) async throws -> [[Double]] {
        var output = Array<[Double]?>(repeating: nil, count: texts.count)
        var missingTexts: [String] = []
        var missingIndexes: [Int] = []

        for (index, text) in texts.enumerated() {
            let cacheKey = Self.cacheKey(for: text, modelIdentifier: modelIdentifier)
            if let cached = Self.embeddingCache[cacheKey] {
                output[index] = cached
            } else {
                missingTexts.append(text)
                missingIndexes.append(index)
            }
        }

        if !missingTexts.isEmpty {
            let vectors = try await LocalEmbeddingServerClient(
                configuration: serverConfiguration,
                targetDimensions: dimensions,
                urlSession: urlSession
            ).embed(missingTexts)
            guard vectors.count == missingTexts.count else { throw LocalEmbeddingServerError.invalidResponse }
            for (offset, vector) in vectors.enumerated() {
                let normalized = Self.project(vector: vector, dimensions: dimensions)
                let index = missingIndexes[offset]
                Self.storeCachedEmbedding(normalized, for: Self.cacheKey(for: texts[index], modelIdentifier: modelIdentifier))
                output[index] = normalized
            }
        }

        return output.map { $0 ?? Array(repeating: 0, count: dimensions) }
    }

    private func embedWithCoreML(_ texts: [String], package: LocalCoreMLEmbeddingPackage) async throws -> [[Double]] {
        #if canImport(CoreML)
        return try await LocalCoreMLEmbeddingRuntime.shared.embed(texts: texts, package: package)
        #else
        throw CocoaError(.featureUnsupported)
        #endif
    }

    private func embedWithCoreMLAndCache(
        _ texts: [String],
        package: LocalCoreMLEmbeddingPackage
    ) async throws -> [[Double]] {
        var output = Array<[Double]?>(repeating: nil, count: texts.count)
        var missingTexts: [String] = []
        var missingIndexes: [Int] = []

        for (index, text) in texts.enumerated() {
            let cacheKey = Self.cacheKey(for: text, modelIdentifier: modelIdentifier)
            if let cached = Self.embeddingCache[cacheKey] {
                output[index] = cached
            } else {
                missingTexts.append(text)
                missingIndexes.append(index)
            }
        }

        if !missingTexts.isEmpty {
            let vectors = try await embedWithCoreML(missingTexts, package: package)
            guard vectors.count == missingTexts.count else { throw AIProviderError.invalidResponse }
            for (offset, vector) in vectors.enumerated() {
                let normalized = Self.project(vector: vector, dimensions: dimensions)
                let index = missingIndexes[offset]
                Self.storeCachedEmbedding(normalized, for: Self.cacheKey(for: texts[index], modelIdentifier: modelIdentifier))
                output[index] = normalized
            }
        }

        return output.map { $0 ?? Array(repeating: 0, count: dimensions) }
    }

    private func embedWithMLX(_ texts: [String], descriptor: LocalEmbeddingModelDescriptor) async throws -> [[Double]] {
        #if canImport(MLXEmbedders) && canImport(MLXHuggingFace) && canImport(MLXLMCommon) && canImport(MLX) && canImport(Tokenizers)
        return try await LocalMLXEmbeddingRuntime.shared.embed(
            texts: texts,
            descriptor: descriptor,
            localDirectory: modelManager.availableLocalDirectory(for: descriptor),
            allowDownloads: allowModelDownloads
        )
        #else
        throw CocoaError(.featureUnsupported)
        #endif
    }

    private func embedWithMLXAndCache(
        _ texts: [String],
        descriptor: LocalEmbeddingModelDescriptor,
        runtime: LocalEmbeddingRuntimeKind
    ) async throws -> [[Double]] {
        var output = Array<[Double]?>(repeating: nil, count: texts.count)
        var missingTexts: [String] = []
        var missingIndexes: [Int] = []

        for (index, text) in texts.enumerated() {
            let cacheKey = Self.cacheKey(for: text, modelIdentifier: modelIdentifier)
            if let cached = Self.embeddingCache[cacheKey] {
                output[index] = cached
            } else {
                missingTexts.append(text)
                missingIndexes.append(index)
            }
        }

        if !missingTexts.isEmpty {
            let vectors = try await embedWithMLX(missingTexts, descriptor: descriptor)
            guard vectors.count == missingTexts.count else { throw AIProviderError.invalidResponse }
            for (offset, vector) in vectors.enumerated() {
                let normalized = Self.project(vector: vector, dimensions: dimensions)
                let index = missingIndexes[offset]
                Self.storeCachedEmbedding(normalized, for: Self.cacheKey(for: texts[index], modelIdentifier: modelIdentifier))
                output[index] = normalized
            }
        }

        return output.map { $0 ?? Array(repeating: 0, count: dimensions) }
    }

    private func embedOne(_ text: String, runtime: LocalEmbeddingRuntimeKind) -> [Double] {
        let normalized = Self.normalized(text)
        let tokens = Self.tokens(from: normalized)
        guard !tokens.isEmpty else { return Array(repeating: 0, count: dimensions) }

        var vector = Array(repeating: 0.0, count: dimensions)
        addDocumentTypeSignals(normalized, into: &vector)
        addTokenSignals(tokens, into: &vector)
        addPhraseSignals(tokens, into: &vector)
        if runtime == .naturalLanguageHybrid {
            addNaturalLanguageSignals(normalized, tokens: tokens, into: &vector)
            addCharacterNGrams(tokens, into: &vector)
            addSemanticConcepts(tokens, into: &vector)
        } else {
            addSemanticConcepts(tokens, into: &vector, weight: 1.4)
        }
        if tier == .advanced {
            addLongRangeWindows(tokens, into: &vector)
        }
        return Self.l2Normalized(vector)
    }

    private func addDocumentTypeSignals(_ text: String, into vector: inout [Double]) {
        let typeWeight = 0.8
        if text.contains("meeting transcript") || text.contains("speaker") {
            add("doctype:meeting", weight: typeWeight, into: &vector)
        }
        if text.contains("decision:") {
            add("doctype:decision", weight: typeWeight, into: &vector)
        }
        if text.contains("action:") || text.contains("owner") {
            add("doctype:action", weight: typeWeight, into: &vector)
        }
        if text.contains("obsidian") || text.contains("[[") {
            add("doctype:obsidian", weight: typeWeight, into: &vector)
        }
    }

    private func addTokenSignals(_ tokens: [String], into vector: inout [Double]) {
        for token in tokens {
            add("tok:\(token)", weight: 1.0, into: &vector)
            if token.count > 5 {
                add("stem:\(String(token.prefix(max(4, token.count - 2))))", weight: 0.35, into: &vector)
            }
        }
    }

    private func addPhraseSignals(_ tokens: [String], into vector: inout [Double]) {
        guard tokens.count > 1 else { return }
        for index in 0..<(tokens.count - 1) {
            add("bi:\(tokens[index])_\(tokens[index + 1])", weight: 0.75, into: &vector)
        }
        guard tokens.count > 2 else { return }
        for index in 0..<(tokens.count - 2) {
            add("tri:\(tokens[index])_\(tokens[index + 1])_\(tokens[index + 2])", weight: 0.45, into: &vector)
        }
    }

    private func addCharacterNGrams(_ tokens: [String], into vector: inout [Double]) {
        for token in tokens where token.count >= 4 {
            let chars = Array(token)
            for size in 3...min(5, chars.count) {
                guard chars.count >= size else { continue }
                for index in 0...(chars.count - size) {
                    add("ng:\(String(chars[index..<(index + size)]))", weight: 0.18, into: &vector)
                }
            }
        }
    }

    private func addSemanticConcepts(_ tokens: [String], into vector: inout [Double], weight: Double = 1.8) {
        let tokenSet = Set(tokens)
        for concept in Self.concepts where !concept.tokens.isDisjoint(with: tokenSet) {
            add("concept:\(concept.id)", weight: weight, into: &vector)
            for related in concept.tokens where tokenSet.contains(related) {
                add("concept-token:\(concept.id):\(related)", weight: weight * 0.35, into: &vector)
            }
        }
    }

    private func addLongRangeWindows(_ tokens: [String], into vector: inout [Double]) {
        guard tokens.count > 4 else { return }
        for index in stride(from: 0, to: tokens.count, by: 4) {
            let window = tokens[index..<min(tokens.count, index + 6)].joined(separator: "_")
            add("win:\(window)", weight: 0.32, into: &vector)
        }
    }

    private func addNaturalLanguageSignals(_ text: String, tokens: [String], into vector: inout [Double]) {
        let language = Self.embeddingLanguage(for: text)
        let embeddings = Self.embeddings(for: language)
        if let sentenceVector = embeddings.sentence?.vector(for: String(text.prefix(1_500))) {
            addDenseVector(sentenceVector, namespace: "nl:sentence:\(language.rawValue)", weight: tier == .advanced ? 4.8 : 4.2, into: &vector)
        }
        if let wordVector = Self.wordCentroid(tokens: tokens, embedding: embeddings.word) {
            addDenseVector(wordVector, namespace: "nl:word:\(language.rawValue)", weight: tier == .advanced ? 2.6 : 2.1, into: &vector)
        }
    }

    private func addDenseVector(_ values: [Double], namespace: String, weight: Double, into vector: inout [Double]) {
        for (sourceIndex, value) in values.enumerated() where value.isFinite && value != 0 {
            let hash = Self.hash64("\(namespace):\(sourceIndex)")
            let index = Int(hash % UInt64(dimensions))
            let sign = ((hash >> 63) == 0) ? 1.0 : -1.0
            vector[index] += value * weight * sign
        }
    }

    private func add(_ feature: String, weight: Double, into vector: inout [Double]) {
        let hash = Self.hash64(feature)
        let index = Int(hash % UInt64(dimensions))
        let sign = ((hash >> 63) == 0) ? 1.0 : -1.0
        vector[index] += weight * sign
    }

    private static func normalized(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private static func tokens(from text: String) -> [String] {
        text
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 1 }
    }

    nonisolated private static func l2Normalized(_ vector: [Double]) -> [Double] {
        let magnitude = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard magnitude > 0 else { return vector }
        return vector.map { $0 / magnitude }
    }

    nonisolated fileprivate static func project(vector: [Double], dimensions: Int) -> [Double] {
        guard vector.count != dimensions else { return l2Normalized(vector) }
        var projected = Array(repeating: 0.0, count: dimensions)
        for (index, value) in vector.enumerated() where value.isFinite && value != 0 {
            projected[index % dimensions] += value
        }
        return l2Normalized(projected)
    }

    private static func hash64(_ value: String) -> UInt64 {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(8).reduce(UInt64(0)) { partial, byte in
            (partial << 8) | UInt64(byte)
        }
    }

    private static func embeddingLanguage(for text: String) -> NLLanguage {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(1_500)))
        switch recognizer.dominantLanguage {
        case .some(.portuguese):
            return .portuguese
        default:
            return .english
        }
    }

    private static func embeddings(for language: NLLanguage) -> (sentence: NLEmbedding?, word: NLEmbedding?) {
        switch language {
        case .portuguese:
            return portugueseEmbeddings
        default:
            return englishEmbeddings
        }
    }

    private static let englishEmbeddings: (sentence: NLEmbedding?, word: NLEmbedding?) = (
        NLEmbedding.sentenceEmbedding(for: .english),
        NLEmbedding.wordEmbedding(for: .english)
    )

    private static let portugueseEmbeddings: (sentence: NLEmbedding?, word: NLEmbedding?) = (
        NLEmbedding.sentenceEmbedding(for: .portuguese) ?? englishEmbeddings.sentence,
        NLEmbedding.wordEmbedding(for: .portuguese) ?? englishEmbeddings.word
    )

    private static var embeddingCache: [String: [Double]] = [:]
    private static var embeddingCacheOrder: [String] = []
    private static let maxCachedEmbeddings = 2_048

    private static func cacheKey(for text: String, modelIdentifier: String) -> String {
        "\(modelIdentifier)|\(text.count)|\(String(hash64(normalized(text)), radix: 16))"
    }

    private static func storeCachedEmbedding(_ vector: [Double], for cacheKey: String) {
        guard embeddingCache[cacheKey] == nil else { return }
        embeddingCache[cacheKey] = vector
        embeddingCacheOrder.append(cacheKey)
        while embeddingCacheOrder.count > maxCachedEmbeddings {
            let evicted = embeddingCacheOrder.removeFirst()
            embeddingCache.removeValue(forKey: evicted)
        }
    }

    private static func wordCentroid(tokens: [String], embedding: NLEmbedding?) -> [Double]? {
        guard let embedding else { return nil }
        var centroid = Array(repeating: 0.0, count: embedding.dimension)
        var count = 0
        for token in Array(Set(tokens)).prefix(80) {
            guard let vector = embedding.vector(for: token), vector.count == centroid.count else { continue }
            for index in vector.indices {
                centroid[index] += vector[index]
            }
            count += 1
        }
        guard count > 0 else { return nil }
        return centroid.map { $0 / Double(count) }
    }

    private struct Concept {
        var id: String
        var tokens: Set<String>
    }

    private static let concepts: [Concept] = [
        Concept(id: "rollback", tokens: ["rollback", "revert", "fallback", "contingency", "contingencia", "plano", "recuperacao", "mitigation", "mitigacao"]),
        Concept(id: "owner", tokens: ["owner", "responsavel", "responsible", "dono", "lider", "lead", "assignee", "assigned"]),
        Concept(id: "deadline", tokens: ["deadline", "prazo", "data", "due", "vencimento", "entrega", "ship", "launch", "lancamento"]),
        Concept(id: "pricing", tokens: ["pricing", "preco", "precificacao", "price", "proposal", "proposta", "renewal", "renovacao"]),
        Concept(id: "risk", tokens: ["risk", "risco", "issue", "blocker", "bloqueio", "problem", "problema", "concern"]),
        Concept(id: "decision", tokens: ["decision", "decisao", "decided", "aprovado", "approved", "choice", "escolha"]),
        Concept(id: "action", tokens: ["action", "acao", "task", "tarefa", "todo", "followup", "follow", "next"]),
        Concept(id: "customer", tokens: ["customer", "cliente", "account", "conta", "stakeholder", "user", "usuario"]),
        Concept(id: "security", tokens: ["security", "seguranca", "token", "secret", "privacy", "privacidade", "auth", "authentication"]),
        Concept(id: "architecture", tokens: ["architecture", "arquitetura", "infra", "database", "db", "api", "service", "servico", "pipeline"]),
        Concept(id: "meeting", tokens: ["meeting", "reuniao", "call", "transcript", "transcricao", "summary", "resumo"]),
        Concept(id: "rag", tokens: ["rag", "retrieval", "embedding", "chunk", "source", "fonte", "citation", "citacao"])
    ]
}

#if canImport(CoreML)
actor LocalCoreMLEmbeddingRuntime {
    static let shared = LocalCoreMLEmbeddingRuntime()

    private var cachedModelKey: String?
    private var cachedModel: MLModel?

    func embed(texts: [String], package: LocalCoreMLEmbeddingPackage) async throws -> [[Double]] {
        let model = try model(for: package)
        return try texts.map { text in
            try predict(text: text, model: model, package: package)
        }
    }

    private func model(for package: LocalCoreMLEmbeddingPackage) throws -> MLModel {
        let key = package.modelURL.path
        if let cachedModel, cachedModelKey == key {
            return cachedModel
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let model = try MLModel(contentsOf: package.modelURL, configuration: configuration)
        cachedModelKey = key
        cachedModel = model
        return model
    }

    private func predict(
        text: String,
        model: MLModel,
        package: LocalCoreMLEmbeddingPackage
    ) throws -> [Double] {
        let manifest = package.manifest
        let clipped = String(text.prefix(max(1, manifest.maxCharacters)))
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            manifest.inputName: MLFeatureValue(string: clipped)
        ])
        let prediction = try model.prediction(from: provider)
        guard let value = prediction.featureValue(for: manifest.outputName),
              let multiArray = value.multiArrayValue else {
            throw AIProviderError.invalidResponse
        }
        var vector: [Double] = []
        vector.reserveCapacity(multiArray.count)
        for index in 0..<multiArray.count {
            vector.append(multiArray[index].doubleValue)
        }
        let projected = LocalEmbeddingProvider.project(vector: vector, dimensions: manifest.dimensions)
        return manifest.normalizeOutput ? projected : vector
    }
}
#endif

enum LocalEmbeddingServerError: LocalizedError, Equatable {
    case disabled
    case invalidEndpoint
    case nonLocalEndpoint
    case missingModel
    case serverStatus(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .disabled:
            "Local embedding server is disabled"
        case .invalidEndpoint:
            "Local embedding server endpoint is invalid"
        case .nonLocalEndpoint:
            "Embedding server must be localhost, 127.0.0.1, or ::1"
        case .missingModel:
            "Local embedding server model is empty"
        case let .serverStatus(status):
            "Local embedding server returned HTTP \(status)"
        case .invalidResponse:
            "Local embedding server returned an invalid embedding response"
        }
    }
}

struct LocalEmbeddingServerClient {
    var configuration: LocalEmbeddingServerConfiguration
    var targetDimensions: Int
    var urlSession: URLSession

    func embed(_ texts: [String]) async throws -> [[Double]] {
        guard configuration.isEnabled else { throw LocalEmbeddingServerError.disabled }
        let model = configuration.trimmedModel
        guard !model.isEmpty else { throw LocalEmbeddingServerError.missingModel }
        let endpoint = try Self.validateLocalEndpoint(configuration.trimmedEndpoint)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(EmbeddingRequest(model: model, input: texts))

        let (data, response) = try await urlSession.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw LocalEmbeddingServerError.serverStatus(httpResponse.statusCode)
        }

        let decoded = try JSONDecoder().decode(EmbeddingResponse.self, from: data)
        let ordered = decoded.data.enumerated()
            .sorted { lhs, rhs in
                (lhs.element.index ?? lhs.offset) < (rhs.element.index ?? rhs.offset)
            }
            .map(\.element.embedding)
        guard ordered.count == texts.count, ordered.allSatisfy({ !$0.isEmpty }) else {
            throw LocalEmbeddingServerError.invalidResponse
        }
        return ordered.map { LocalEmbeddingProvider.project(vector: $0, dimensions: targetDimensions) }
    }

    static func validateLocalEndpoint(_ value: String) throws -> URL {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(),
              !url.path.isEmpty else {
            throw LocalEmbeddingServerError.invalidEndpoint
        }
        guard host == "localhost" || host == "127.0.0.1" || host == "::1" else {
            throw LocalEmbeddingServerError.nonLocalEndpoint
        }
        return url
    }

    private struct EmbeddingRequest: Encodable {
        var model: String
        var input: [String]
    }

    private struct EmbeddingResponse: Decodable {
        var data: [EmbeddingData]
    }

    private struct EmbeddingData: Decodable {
        var embedding: [Double]
        var index: Int?
    }
}

@MainActor
struct LocalEmbeddingRuntimeSelector {
    var targetLatencyMs: Int
    var allowModelDownloads: Bool
    var allowMetalAcceleration: Bool
    var serverConfiguration: LocalEmbeddingServerConfiguration
    var modelManager: LocalEmbeddingModelManager

    init(
        targetLatencyMs: Int = 250,
        allowModelDownloads: Bool = false,
        allowMetalAcceleration: Bool = true,
        serverConfiguration: LocalEmbeddingServerConfiguration = LocalEmbeddingServerConfiguration(),
        modelManager: LocalEmbeddingModelManager = LocalEmbeddingModelManager()
    ) {
        self.targetLatencyMs = targetLatencyMs
        self.allowModelDownloads = allowModelDownloads
        self.allowMetalAcceleration = allowMetalAcceleration
        self.serverConfiguration = serverConfiguration
        self.modelManager = modelManager
    }

    func benchmark(tier: LocalEmbeddingTier) async -> LocalEmbeddingRuntimeBenchmarkResult {
        let candidates = candidateRuntimes(for: tier)
        var results: [LocalEmbeddingRuntimeCandidateBenchmark] = []
        for runtime in candidates {
            results.append(await benchmark(runtime: runtime, tier: tier))
        }
        let selected = selectRuntime(from: results, tier: tier)
        return LocalEmbeddingRuntimeBenchmarkResult(
            tier: tier,
            targetModelId: tier.modelProfile.targetModelId,
            selectedRuntime: selected,
            targetLatencyMs: targetLatencyMs,
            machineFingerprint: Self.machineFingerprint(),
            measuredAt: Date(),
            candidates: results
        )
    }

    private func candidateRuntimes(for tier: LocalEmbeddingTier) -> [LocalEmbeddingRuntimeKind] {
        let coreMLCandidate: [LocalEmbeddingRuntimeKind] = modelManager.isUsable(
            tier: tier,
            runtime: .coreML,
            allowDownloads: false
        ) ? [.coreML] : []
        let mlxCandidate: [LocalEmbeddingRuntimeKind] = modelManager.isUsable(
            tier: tier,
            runtime: .mlx,
            allowDownloads: allowModelDownloads,
            allowMetalAcceleration: allowMetalAcceleration
        ) ? [.mlx] : []
        let serverCandidate: [LocalEmbeddingRuntimeKind] = (tier != .fast && serverConfiguration.isUsable) ? [.localServer] : []
        switch tier {
        case .fast:
            return coreMLCandidate + mlxCandidate + [.naturalLanguageHybrid, .featureHash]
        case .balanced, .advanced:
            return serverCandidate + coreMLCandidate + mlxCandidate + [.naturalLanguageHybrid, .featureHash]
        }
    }

    private func benchmark(runtime: LocalEmbeddingRuntimeKind, tier: LocalEmbeddingTier) async -> LocalEmbeddingRuntimeCandidateBenchmark {
        let provider = LocalEmbeddingProvider(
            tier: tier,
            runtime: runtime,
            allowModelDownloads: allowModelDownloads,
            allowMetalAcceleration: allowMetalAcceleration,
            serverConfiguration: serverConfiguration,
            modelManager: modelManager
        )
        await provider.prewarm()
        let samples = Self.samples(for: tier)
        var latencies: [Double] = []
        var didSucceed = true
        for sample in samples {
            let startedAt = Date()
            do {
                _ = try await provider.embed(sample)
                latencies.append(Date().timeIntervalSince(startedAt) * 1_000)
            } catch {
                didSucceed = false
                latencies.append(.infinity)
                break
            }
        }
        let batchStartedAt = Date()
        let batchMs: Double
        let vectorsPerSecond: Double
        if didSucceed, (try? await provider.embed(samples)) != nil {
            batchMs = Date().timeIntervalSince(batchStartedAt) * 1_000
            vectorsPerSecond = batchMs > 0 ? Double(samples.count) / (batchMs / 1_000) : Double(samples.count)
        } else {
            batchMs = .infinity
            vectorsPerSecond = 0
        }
        let semanticProbe = didSucceed
            ? await semanticProbe(provider: provider, tier: tier)
            : SemanticProbeResult(score: 0, wins: 0, count: Self.semanticProbes(for: tier).count)
        return LocalEmbeddingRuntimeCandidateBenchmark(
            runtime: runtime,
            p50Ms: percentile(latencies, percentile: 0.50),
            p95Ms: percentile(latencies, percentile: 0.95),
            batchMs: batchMs,
            vectorsPerSecond: vectorsPerSecond,
            qualityRank: qualityRank(runtime: runtime, tier: tier),
            dimensions: provider.dimensions,
            executable: didSucceed && provider.activeRuntime == runtime,
            semanticProbeScore: semanticProbe.score,
            semanticProbeWins: semanticProbe.wins,
            semanticProbeCount: semanticProbe.count
        )
    }

    private func selectRuntime(from results: [LocalEmbeddingRuntimeCandidateBenchmark], tier: LocalEmbeddingTier) -> LocalEmbeddingRuntimeKind {
        let passing = results.filter {
            $0.executable &&
                $0.p95Ms <= Double(targetLatencyMs) &&
                ($0.semanticProbeScore ?? 0) >= minimumSemanticProbeScore(for: tier)
        }
        if let bestQuality = passing.sorted(by: runtimePreference).first {
            return bestQuality.runtime
        }
        return results
            .filter { $0.executable }
            .sorted { lhs, rhs in
                let lhsQuality = measuredQualityScore(lhs)
                let rhsQuality = measuredQualityScore(rhs)
                if lhsQuality != rhsQuality { return lhsQuality > rhsQuality }
                if lhs.p95Ms == rhs.p95Ms { return lhs.qualityRank > rhs.qualityRank }
                return lhs.p95Ms < rhs.p95Ms
            }
            .first?.runtime ?? LocalEmbeddingProvider.executableRuntime(for: tier, requested: .automatic)
    }

    private func runtimePreference(_ lhs: LocalEmbeddingRuntimeCandidateBenchmark, _ rhs: LocalEmbeddingRuntimeCandidateBenchmark) -> Bool {
        let lhsQuality = measuredQualityScore(lhs)
        let rhsQuality = measuredQualityScore(rhs)
        if lhsQuality == rhsQuality { return lhs.p95Ms < rhs.p95Ms }
        return lhsQuality > rhsQuality
    }

    private func measuredQualityScore(_ candidate: LocalEmbeddingRuntimeCandidateBenchmark) -> Double {
        Double(candidate.qualityRank) + (candidate.semanticProbeScore ?? 0)
    }

    private func minimumSemanticProbeScore(for tier: LocalEmbeddingTier) -> Double {
        switch tier {
        case .fast:
            0.50
        case .balanced:
            0.65
        case .advanced:
            0.65
        }
    }

    private func qualityRank(runtime: LocalEmbeddingRuntimeKind, tier: LocalEmbeddingTier) -> Int {
        switch runtime {
        case .coreML, .mlx, .localServer:
            return 4
        case .naturalLanguageHybrid:
            return tier == .fast ? 2 : 3
        case .featureHash:
            return 1
        case .automatic:
            return 0
        }
    }

    private func percentile(_ values: [Double], percentile: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * percentile).rounded(.up))))
        return sorted[index]
    }

    private func semanticProbe(
        provider: LocalEmbeddingProvider,
        tier: LocalEmbeddingTier
    ) async -> SemanticProbeResult {
        let probes = Self.semanticProbes(for: tier)
        guard !probes.isEmpty else {
            return SemanticProbeResult(score: 0, wins: 0, count: 0)
        }
        let vectorSearch = VectorSearchService()
        var wins = 0
        for probe in probes {
            let inputs = [probe.query, probe.positive] + probe.negatives
            guard let vectors = try? await provider.embed(inputs),
                  vectors.count == inputs.count,
                  vectors.allSatisfy({ !$0.isEmpty }) else {
                continue
            }
            let positiveScore = vectorSearch.cosineSimilarity(vectors[0], vectors[1])
            let bestNegative = vectors.dropFirst(2)
                .map { vectorSearch.cosineSimilarity(vectors[0], $0) }
                .max() ?? -Double.infinity
            if positiveScore > bestNegative + probe.margin {
                wins += 1
            }
        }
        return SemanticProbeResult(
            score: Double(wins) / Double(probes.count),
            wins: wins,
            count: probes.count
        )
    }

    static func machineFingerprint() -> String {
        let processInfo = ProcessInfo.processInfo
        let memoryGB = max(1, Int((processInfo.physicalMemory / 1_073_741_824)))
        return "\(processInfo.processorCount)c-\(memoryGB)gb-\(processInfo.operatingSystemVersionString)"
    }

    private static func samples(for tier: LocalEmbeddingTier) -> [String] {
        [
            "Meeting transcript: Ana says Project Atlas renewal fallback is staged rollback with Maya as owner.",
            "Obsidian note #risk [[Atlas]] pricing owner is Maya; fallback plan uses staged rollback.",
            "Decision: ship offline capture before dashboards. Action: Leo validates telemetry.",
            "Spec: RAG pipeline uses local BM25, ANN dense retrieval, MMR rerank, citations and workspace isolation.",
            "Pergunta: quem e responsavel pelo plano de contingencia da renovacao Atlas?",
            "Security action item: rotate customer demo tokens every Friday and document evidence."
        ].map { "\($0) tier:\(tier.rawValue)" }
    }

    private static func semanticProbes(for tier: LocalEmbeddingTier) -> [SemanticProbe] {
        [
            SemanticProbe(
                query: "fallback plan owner",
                positive: "rollback mitigation strategy with Maya accountable",
                negatives: ["bananas and oranges inventory", "dashboard color palette review"],
                margin: tier == .fast ? 0.00 : 0.015
            ),
            SemanticProbe(
                query: "quem e responsavel pelo plano de contingencia",
                positive: "Maya owns the staged rollback contingency",
                negatives: ["o almoco sera servido ao meio dia", "budget spreadsheet column formatting"],
                margin: tier == .fast ? 0.00 : 0.015
            ),
            SemanticProbe(
                query: "customer renewal pricing proposal",
                positive: "commercial proposal for account renewal price",
                negatives: ["database migration checkpoint", "screen recording permission issue"],
                margin: tier == .fast ? 0.00 : 0.015
            ),
            SemanticProbe(
                query: "security token rotation owner",
                positive: "rotate customer demo secrets every Friday",
                negatives: ["meeting room projector cable", "fruit vendor delivery"],
                margin: tier == .fast ? 0.00 : 0.015
            )
        ]
    }

    private struct SemanticProbe {
        var query: String
        var positive: String
        var negatives: [String]
        var margin: Double
    }

    private struct SemanticProbeResult {
        var score: Double
        var wins: Int
        var count: Int
    }
}
