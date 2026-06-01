import Foundation

enum KnowledgeSourceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case file
    case directory
    case obsidian
    case meeting
    case legacy

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .file: "Files"
        case .directory: "Directory"
        case .obsidian: "Obsidian"
        case .meeting: "Meetings"
        case .legacy: "Imported"
        }
    }

    var systemImage: String {
        switch self {
        case .file: "doc.text"
        case .directory: "folder"
        case .obsidian: "hexagon"
        case .meeting: "waveform.and.mic"
        case .legacy: "archivebox"
        }
    }
}

enum KnowledgeSourceStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case connected
    case indexing
    case paused
    case failed
    case empty

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .connected: "Connected"
        case .indexing: "Indexing"
        case .paused: "Paused"
        case .failed: "Needs attention"
        case .empty: "Empty"
        }
    }
}

enum KnowledgeDocumentKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case text
    case markdown
    case pdf
    case transcript
    case summary
    case unknown

    var id: String { rawValue }
}

enum KnowledgeCopilotScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case allSources = "all_sources"
    case currentMeeting = "current_meeting"
    case selectedSource = "selected_source"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .allSources: "All sources"
        case .currentMeeting: "Current meeting"
        case .selectedSource: "Selected source"
        }
    }
}

enum LocalEmbeddingTier: String, Codable, CaseIterable, Identifiable, Sendable {
    case fast
    case balanced
    case advanced

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fast: "Fast"
        case .balanced: "Balanced"
        case .advanced: "Advanced"
        }
    }

    var modelIdentifier: String {
        modelProfile.storageModelId
    }

    var dimensions: Int {
        modelProfile.dimensions
    }

    var defaultBatchSize: Int {
        switch self {
        case .fast: 128
        case .balanced: 96
        case .advanced: 64
        }
    }

    var systemImage: String {
        switch self {
        case .fast: "bolt"
        case .balanced: "dial.medium"
        case .advanced: "memorychip"
        }
    }

    var modelProfile: LocalEmbeddingModelProfile {
        switch self {
        case .fast:
            LocalEmbeddingModelProfile(
                tier: self,
                targetModelId: "Qwen/Qwen3-Embedding-0.6B",
                storageModelId: "notchly-qwen3-embedding-0_6b-v1",
                displayName: "Qwen3 0.6B",
                dimensions: 1024,
                contextTokens: 32_000,
                defaultQuantization: "int8/fp16",
                preferredRuntime: .coreML,
                minimumMemoryGB: 8,
                supportsSparseSignals: false,
                supportsLateInteraction: false
            )
        case .balanced:
            LocalEmbeddingModelProfile(
                tier: self,
                targetModelId: "BAAI/bge-m3",
                storageModelId: "notchly-bge-m3-v1",
                displayName: "BGE-M3",
                dimensions: 1024,
                contextTokens: 8_192,
                defaultQuantization: "fp16/int8",
                preferredRuntime: .coreML,
                minimumMemoryGB: 12,
                supportsSparseSignals: true,
                supportsLateInteraction: true
            )
        case .advanced:
            LocalEmbeddingModelProfile(
                tier: self,
                targetModelId: "Qwen/Qwen3-Embedding-4B",
                storageModelId: "notchly-qwen3-embedding-4b-v1",
                displayName: "Qwen3 4B",
                dimensions: 2560,
                contextTokens: 32_000,
                defaultQuantization: "fp16/int8",
                preferredRuntime: .mlx,
                minimumMemoryGB: 24,
                supportsSparseSignals: false,
                supportsLateInteraction: true
            )
        }
    }
}

enum LocalEmbeddingRuntimeKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case coreML
    case mlx
    case localServer = "local_server"
    case naturalLanguageHybrid
    case featureHash

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .coreML: "Core ML"
        case .mlx: "MLX"
        case .localServer: "Local Server"
        case .naturalLanguageHybrid: "NL Hybrid"
        case .featureHash: "Feature Hash"
        }
    }

    var storageSuffix: String {
        switch self {
        case .automatic: "auto"
        case .coreML: "coreml"
        case .mlx: "mlx"
        case .localServer: "local-server"
        case .naturalLanguageHybrid: "nl-hybrid"
        case .featureHash: "feature-hash"
        }
    }

    var systemImage: String {
        switch self {
        case .automatic: "wand.and.stars"
        case .coreML: "cpu"
        case .mlx: "memorychip"
        case .localServer: "server.rack"
        case .naturalLanguageHybrid: "text.magnifyingglass"
        case .featureHash: "number"
        }
    }
}

struct LocalEmbeddingServerConfiguration: Codable, Hashable, Sendable {
    var isEnabled: Bool
    var endpoint: String
    var model: String
    var dimensions: Int?

    init(
        isEnabled: Bool = false,
        endpoint: String = Self.defaultEndpoint,
        model: String = Self.defaultModel,
        dimensions: Int? = nil
    ) {
        self.isEnabled = isEnabled
        self.endpoint = endpoint
        self.model = model
        self.dimensions = dimensions
    }

    static let defaultEndpoint = "http://127.0.0.1:11434/v1/embeddings"
    static let defaultModel = "Qwen/Qwen3-Embedding-4B"

    var trimmedEndpoint: String {
        endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedModel: String {
        model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedDimensions: Int? {
        guard let dimensions, dimensions > 0 else { return nil }
        return dimensions
    }

    var isUsable: Bool {
        isEnabled &&
            !trimmedEndpoint.isEmpty &&
            !trimmedModel.isEmpty &&
            (try? LocalEmbeddingServerClient.validateLocalEndpoint(trimmedEndpoint)) != nil
    }

    func normalized(defaultDimensions: Int) -> LocalEmbeddingServerConfiguration {
        var copy = self
        copy.endpoint = trimmedEndpoint.isEmpty ? Self.defaultEndpoint : trimmedEndpoint
        copy.model = trimmedModel.isEmpty ? Self.defaultModel : trimmedModel
        if let dimensions {
            copy.dimensions = min(max(dimensions, 128), 8_192)
        } else {
            copy.dimensions = defaultDimensions
        }
        return copy
    }
}

struct LocalEmbeddingModelProfile: Codable, Hashable, Sendable {
    var tier: LocalEmbeddingTier
    var targetModelId: String
    var storageModelId: String
    var displayName: String
    var dimensions: Int
    var contextTokens: Int
    var defaultQuantization: String
    var preferredRuntime: LocalEmbeddingRuntimeKind
    var minimumMemoryGB: Int
    var supportsSparseSignals: Bool
    var supportsLateInteraction: Bool
}

struct LocalEmbeddingRuntimeCandidateBenchmark: Codable, Hashable, Sendable {
    var runtime: LocalEmbeddingRuntimeKind
    var p50Ms: Double
    var p95Ms: Double
    var batchMs: Double
    var vectorsPerSecond: Double
    var qualityRank: Int
    var dimensions: Int
    var executable: Bool
    var semanticProbeScore: Double?
    var semanticProbeWins: Int?
    var semanticProbeCount: Int?
}

struct LocalEmbeddingRuntimeBenchmarkResult: Codable, Hashable, Sendable {
    var tier: LocalEmbeddingTier
    var targetModelId: String
    var selectedRuntime: LocalEmbeddingRuntimeKind
    var targetLatencyMs: Int
    var machineFingerprint: String
    var measuredAt: Date
    var candidates: [LocalEmbeddingRuntimeCandidateBenchmark]

    var selectedCandidate: LocalEmbeddingRuntimeCandidateBenchmark? {
        candidates.first { $0.runtime == selectedRuntime }
    }

    var summary: String {
        guard let selectedCandidate else { return "\(selectedRuntime.displayName) selected" }
        let quality = selectedCandidate.semanticProbeScore.map { " q\(Int(($0 * 100).rounded()))" } ?? ""
        return "\(selectedRuntime.displayName) p95 \(Int(selectedCandidate.p95Ms.rounded()))ms\(quality)"
    }
}

struct KnowledgeSource: Identifiable, Sendable, Hashable {
    var id: UUID
    var kind: KnowledgeSourceKind
    var displayName: String
    var rootPath: String?
    var bookmarkData: Data?
    var workspaceId: String
    var status: KnowledgeSourceStatus
    var isEnabled: Bool
    var lastIndexedAt: Date?
    var lastError: String?
    var documentCount: Int
    var chunkCount: Int
    var createdAt: Date
    var updatedAt: Date
}

struct KnowledgeDocumentRecord: Identifiable, Sendable, Hashable {
    var id: UUID
    var sourceId: UUID
    var displayName: String
    var filePath: String?
    var contentHash: String
    var fileSize: Int
    var modifiedAt: Date?
    var workspaceId: String
    var kind: KnowledgeDocumentKind
    var metadata: [String: String]
    var createdAt: Date
    var updatedAt: Date
}

struct KnowledgeChunkRecord: Identifiable, Sendable, Hashable {
    var id: UUID
    var documentId: UUID
    var sourceId: UUID
    var sequence: Int
    var heading: String?
    var content: String
    var tokenEstimate: Int
    var locationLabel: String?
    var contentHash: String
    var workspaceId: String
    var createdAt: Date
    var updatedAt: Date
}

struct KnowledgeEmbeddingRecord: Identifiable, Sendable, Hashable {
    var id: UUID
    var chunkId: UUID
    var model: String
    var contentHash: String
    var dimensions: Int
    var vector: [Double]
    var createdAt: Date
}

struct KnowledgeRetrievalOptions: Sendable, Hashable {
    var workspaceId: String
    var limit: Int = 8
    var candidateLimit: Int = 24
    var selectedSourceId: UUID?
    var allowedKinds: Set<KnowledgeSourceKind> = Set(KnowledgeSourceKind.allCases)
    var minScore: Double = 0.02
    var contextCharacterBudget: Int = 6_000
}

struct KnowledgeRetrievalResult: Sendable, Hashable {
    var query: String
    var results: [KnowledgeSearchResult]
    var context: String
    var latencyMs: Int
    var stageLatencies: KnowledgeRetrievalStageLatencies = .zero
    var grounding: KnowledgeRetrievalGrounding = .none
    var evidenceScore: Double = 0
}

struct KnowledgeRetrievalStageLatencies: Codable, Sendable, Hashable {
    var queryEmbeddingMs: Int
    var hybridSearchMs: Int
    var rerankMs: Int
    var contextAssemblyMs: Int

    static let zero = KnowledgeRetrievalStageLatencies(
        queryEmbeddingMs: 0,
        hybridSearchMs: 0,
        rerankMs: 0,
        contextAssemblyMs: 0
    )
}

struct LocalRAGEvaluationCase: Sendable, Hashable {
    var id: String
    var query: String
    var expectedDocuments: Set<String>
    var forbiddenDocuments: Set<String>
    var minimumGrounding: KnowledgeRetrievalGrounding

    init(
        id: String,
        query: String,
        expectedDocuments: Set<String>,
        forbiddenDocuments: Set<String> = [],
        minimumGrounding: KnowledgeRetrievalGrounding = .moderate
    ) {
        self.id = id
        self.query = query
        self.expectedDocuments = expectedDocuments
        self.forbiddenDocuments = forbiddenDocuments
        self.minimumGrounding = minimumGrounding
    }
}

struct LocalRAGEvaluationReport: Sendable, Hashable {
    var caseCount: Int
    var recallAtK: Double
    var precisionAtK: Double
    var hardNegativeLeakRate: Double
    var groundednessRate: Double
    var p95LatencyMs: Int?
    var failedCaseIds: [String]

    var passesTopTierGate: Bool {
        caseCount > 0 &&
            recallAtK >= 0.95 &&
            precisionAtK >= 0.60 &&
            hardNegativeLeakRate == 0 &&
            groundednessRate >= 0.90 &&
            (p95LatencyMs ?? 0) <= 250
    }
}

enum KnowledgeRetrievalGrounding: String, Codable, CaseIterable, Identifiable, Sendable {
    case strong
    case moderate
    case weak
    case none

    var id: String { rawValue }

    var contextNotice: String? {
        switch self {
        case .strong:
            return nil
        case .moderate:
            return "Local evidence: partial. Use the retrieved sources, but state uncertainty for details not directly supported."
        case .weak:
            return "Local evidence: weak. Answer cautiously and say the local sources do not strongly support the claim."
        case .none:
            return "Local evidence: none. No reliable local source matched this query; do not invent facts."
        }
    }
}

struct SourceConnectionViewModel: Identifiable, Sendable, Hashable {
    var id: UUID
    var title: String
    var subtitle: String
    var kind: KnowledgeSourceKind
    var status: KnowledgeSourceStatus
    var documentCount: Int
    var chunkCount: Int
    var lastIndexedAt: Date?
    var isEnabled: Bool
    var lastError: String?
}

struct RetrievalStatusViewModel: Sendable, Hashable {
    var title: String
    var detail: String
    var quality: String
    var isIndexing: Bool
}

struct KnowledgeIndexHealthReport: Sendable, Hashable {
    var workspaceId: String
    var sourceCount: Int
    var failedSourceCount: Int
    var documentCount: Int
    var chunkCount: Int
    var embeddedChunkCount: Int
    var staleChunkCount: Int
    var embeddingCoverage: Double
    var recentTraceCount: Int
    var weakTraceCount: Int
    var uncitedTraceCount: Int
    var hybridTraceCount: Int
    var slowTraceP95Ms: Int?
    var queryEmbeddingP95Ms: Int?
    var hybridSearchP95Ms: Int?
    var rerankP95Ms: Int?
    var contextAssemblyP95Ms: Int?
    var recommendations: [String]

    var isReadyForRealtime: Bool {
        failedSourceCount == 0 &&
            chunkCount > 0 &&
            embeddingCoverage >= 0.98 &&
            staleChunkCount == 0 &&
            uncitedTraceCount == 0 &&
            weakTraceCount <= max(1, recentTraceCount / 4)
    }
}

struct KnowledgeRetrievalWarmupReport: Sendable, Hashable {
    var workspaceId: String
    var sourceCount: Int
    var chunkCount: Int
    var embeddedVectorCount: Int
    var bm25Ready: Bool
    var annReady: Bool
    var warmedAt: Date

    var isReadyForRealtime: Bool {
        bm25Ready && chunkCount > 0 && embeddedVectorCount > 0
    }
}

struct KnowledgeEmbeddingMaintenanceReport: Sendable, Hashable {
    var workspaceId: String
    var model: String
    var activeChunkCount: Int
    var validEmbeddingCount: Int
    var missingEmbeddingCount: Int
    var deletedStaleEmbeddingCount: Int
    var deletedOrphanEmbeddingCount: Int
    var deletedDuplicateEmbeddingCount: Int
    var rebuiltVectorShard: Bool
    var maintainedAt: Date

    var isReadyForRealtime: Bool {
        activeChunkCount > 0 && missingEmbeddingCount == 0
    }
}
