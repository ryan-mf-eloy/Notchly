import CryptoKit
import Foundation
import SwiftData

struct KnowledgeSearchResult: Identifiable, Sendable, Hashable {
    var id = UUID()
    var documentName: String
    var snippet: String
    var contextSnippet: String? = nil
    var score: Double
    var workspaceId: String = "default"
    var sourceId: UUID?
    var documentId: UUID?
    var chunkId: UUID?
    var sourceKind: KnowledgeSourceKind = .legacy
    var locationLabel: String?
    var reference: String?
    var keywordScore: Double = 0
    var semanticScore: Double = 0
    var recencyScore: Double = 0
}

@MainActor
final class LocalKnowledgeStore {
    private let context: ModelContext
    private let workspaceId: String
    private let cryptor: LocalDataCryptor
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var chunkTargetTokens = 700
    private var chunkOverlapTokens = 120
    private var embeddingVectorCache: [String: EmbeddingVectorCacheEntry] = [:]
    private var bm25IndexCache: [String: BM25IndexCacheEntry] = [:]
    private var annIndexCache: [String: ANNIndexCacheEntry] = [:]
    private let vectorBlobStore: LocalVectorBlobStore?

    private struct EmbeddingVectorCacheEntry {
        var recordCount: Int
        var scopeFingerprint: String
        var vectorsByChunkId: [UUID: [Double]]
    }

    private struct ANNIndexCacheEntry {
        var scopeFingerprint: String
        var index: LocalVectorANNIndex
    }

    private struct BM25IndexCacheEntry {
        var scopeFingerprint: String
        var index: LocalBM25Index
    }

    private struct IndexedFileSnapshot {
        var fileSize: Int
        var modifiedAt: Date?
    }

    private struct RetrievalTraceResultSummary: Codable {
        var document: String?
        var source: String?
        var chunkId: String?
        var documentId: String?
        var sourceId: String?
        var score: String?
        var keywordScore: String?
        var semanticScore: String?
    }

    private struct RetrievalTracePayload: Codable {
        var stages: KnowledgeRetrievalStageLatencies?
        var results: [RetrievalTraceResultSummary]
    }

    private struct RetrievalTraceSignal {
        var latencyMs: Int
        var resultCount: Int
        var topScore: Double
        var topKeywordScore: Double
        var topSemanticScore: Double
        var structuredReferenceCount: Int
        var hybridEvidenceCount: Int
        var stageLatencies: KnowledgeRetrievalStageLatencies?

        var isWeakEvidence: Bool {
            if resultCount == 0 { return true }
            if topScore < 0.035 { return true }
            let hasRetrievalSignals = topKeywordScore > 0 || topSemanticScore > 0
            if hasRetrievalSignals {
                return topKeywordScore < 0.18 && topSemanticScore < 0.12 && topScore < 0.08
            }
            return topScore < 0.08
        }
    }

    private struct ContentSemanticProfile {
        var role: String
        var retrievalFocus: String
    }

    init(
        container: ModelContainer,
        workspaceId: String = "default",
        cryptor: LocalDataCryptor = .defaultOrCrash(),
        vectorBlobStore: LocalVectorBlobStore? = nil
    ) {
        self.context = ModelContext(container)
        self.workspaceId = workspaceId
        self.cryptor = cryptor
        self.vectorBlobStore = vectorBlobStore
        encoder.outputFormatting = [.sortedKeys]
    }

    func configure(preferences: AppPreferences) {
        let normalized = preferences.normalizedForPersistence()
        chunkTargetTokens = normalized.ragChunkTargetTokens
        chunkOverlapTokens = normalized.ragChunkOverlapTokens
    }

    func addDocument(name: String, filePath: String? = nil, content: String, workspaceId: String? = nil) throws {
        let targetWorkspaceId = workspaceId ?? self.workspaceId
        context.insert(try StoredKnowledgeDocument(displayName: name, filePath: filePath, content: content, workspaceId: targetWorkspaceId, cryptor: cryptor))
        let source = try fileSource(workspaceId: targetWorkspaceId)
        try upsertDocument(
            source: source,
            displayName: name,
            filePath: filePath,
            content: content,
            kind: filePath.map { DocumentIngestionService().documentKind(for: URL(fileURLWithPath: $0)) } ?? .text,
            modifiedAt: nil,
            metadata: ["origin": "manual"]
        )
        try refreshSourceCounts(sourceId: source.id)
        try context.save()
    }

    func connectDirectory(_ url: URL, kind: KnowledgeSourceKind = .directory, workspaceId: String? = nil) throws -> KnowledgeSource {
        let targetWorkspaceId = workspaceId ?? self.workspaceId
        let displayName = kind == .obsidian ? "\(url.lastPathComponent) Vault" : url.lastPathComponent
        let bookmarkData = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let source = try upsertSource(
            kind: kind,
            displayName: displayName.isEmpty ? kind.displayName : displayName,
            rootPath: url.path,
            bookmarkData: bookmarkData,
            workspaceId: targetWorkspaceId,
            status: .indexing
        )
        try context.save()
        return try indexSource(source.id)
    }

    @discardableResult
    func indexSource(_ sourceId: UUID) throws -> KnowledgeSource {
        var source = try source(id: sourceId)
        guard let rootPath = source.rootPath else { return source }
        source.status = .indexing
        source.lastError = nil
        source.updatedAt = Date()
        try saveSource(source)
        try context.save()

        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        let didAccess = rootURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { rootURL.stopAccessingSecurityScopedResource() }
        }

        do {
            let indexedPaths = try indexFiles(in: rootURL, source: source)
            try deleteDocumentsMissing(from: indexedPaths, sourceId: source.id)
            if source.kind == .obsidian {
                try refreshObsidianGraphMetadata(sourceId: source.id)
            }
            try refreshSourceCounts(sourceId: source.id)
            source = try self.source(id: source.id)
            source.status = source.documentCount == 0 ? .empty : .connected
            source.lastIndexedAt = Date()
            source.updatedAt = Date()
            try saveSource(source)
            try context.save()
            return source
        } catch {
            source.status = .failed
            source.lastError = error.localizedDescription
            source.updatedAt = Date()
            try saveSource(source)
            try context.save()
            return source
        }
    }

    func indexMeeting(_ meeting: MeetingSession, workspaceId: String? = nil) throws {
        let targetWorkspaceId = workspaceId ?? self.workspaceId
        let source = try meetingSource(workspaceId: targetWorkspaceId)
        let orderedSegments = meeting.transcriptSegments.sorted { lhs, rhs in
            if lhs.startTime == rhs.startTime {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.startTime < rhs.startTime
        }
        let transcript = orderedSegments
            .map(Self.meetingTranscriptLine)
            .joined(separator: "\n")
        if !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try upsertDocument(
                source: source,
                displayName: "\(meeting.title) transcript",
                filePath: "notchly://meeting/\(meeting.id.uuidString)/transcript",
                content: transcript,
                kind: .transcript,
                modifiedAt: meeting.endedAt ?? Date(),
                metadata: meetingMetadata(for: meeting, segments: orderedSegments, kind: "transcript")
            )
        }
        if let summary = meeting.summary {
            let summaryText = [
                summary.executiveSummary,
                summary.keyDecisions.map { "Decision: \($0)" }.joined(separator: "\n"),
                summary.actionItems.map(Self.summaryActionLine).joined(separator: "\n"),
                summary.risks.map { "Risk: \($0)" }.joined(separator: "\n"),
                summary.openQuestions.map { "Open question: \($0)" }.joined(separator: "\n"),
                summary.strategicInsights.map { "Insight: \($0)" }.joined(separator: "\n"),
                summary.followUps.map { "Follow-up: \($0)" }.joined(separator: "\n")
            ]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
            try upsertDocument(
                source: source,
                displayName: "\(meeting.title) summary",
                filePath: "notchly://meeting/\(meeting.id.uuidString)/summary",
                content: summaryText,
                kind: .summary,
                modifiedAt: summary.generatedAt,
                metadata: meetingMetadata(for: meeting, segments: orderedSegments, kind: "summary")
            )
        }
        try refreshSourceCounts(sourceId: source.id)
        try context.save()
    }

    func sources(workspaceId: String? = nil) throws -> [KnowledgeSource] {
        let targetWorkspaceId = workspaceId ?? self.workspaceId
        return try storedSources()
            .map { try $0.decrypt(cryptor: cryptor) }
            .filter { $0.workspaceId == targetWorkspaceId }
            .sorted { lhs, rhs in
                if lhs.kind == rhs.kind { return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending }
                return lhs.kind.rawValue < rhs.kind.rawValue
            }
    }

    func sourceConnectionViewModels(workspaceId: String? = nil) throws -> [SourceConnectionViewModel] {
        try sources(workspaceId: workspaceId).map {
            SourceConnectionViewModel(
                id: $0.id,
                title: $0.displayName,
                subtitle: $0.rootPath ?? $0.kind.displayName,
                kind: $0.kind,
                status: $0.status,
                documentCount: $0.documentCount,
                chunkCount: $0.chunkCount,
                lastIndexedAt: $0.lastIndexedAt,
                isEnabled: $0.isEnabled,
                lastError: $0.lastError
            )
        }
    }

    @discardableResult
    func setSourceEnabled(_ sourceId: UUID, isEnabled: Bool) throws -> KnowledgeSource {
        var source = try source(id: sourceId)
        guard source.isEnabled != isEnabled else { return source }
        source.isEnabled = isEnabled
        source.updatedAt = Date()
        try saveSource(source)
        invalidateEmbeddingVectorCache()
        try context.save()
        return source
    }

    func documents() throws -> [KnowledgeDocument] {
        let legacy = try storedDocuments().map { try $0.decrypt(cryptor: cryptor) }
        let legacyKeys = Set(legacy.map { "\($0.workspaceId)|\($0.filePath ?? "")|\($0.displayName)" })
        let chunksByDocument = Dictionary(grouping: try chunkRecords(), by: \.documentId)
        let modern = try documentRecords().compactMap { document -> KnowledgeDocument? in
            let key = "\(document.workspaceId)|\(document.filePath ?? "")|\(document.displayName)"
            guard !legacyKeys.contains(key) else { return nil }
            let content = (chunksByDocument[document.id] ?? [])
                .sorted { $0.sequence < $1.sequence }
                .map(\.content)
                .joined(separator: "\n")
            return KnowledgeDocument(
                id: document.id,
                displayName: document.displayName,
                filePath: document.filePath,
                content: content,
                workspaceId: document.workspaceId,
                createdAt: document.createdAt
            )
        }
        return legacy + modern
    }

    func migrateEncryptedFields() throws {
        for document in try storedDocuments() {
            try document.encryptSensitiveFieldsIfNeeded(cryptor: cryptor)
        }
        for source in try storedSources() {
            try source.encryptSensitiveFieldsIfNeeded(cryptor: cryptor)
        }
        for document in try storedDocumentRecords() {
            try document.encryptSensitiveFieldsIfNeeded(cryptor: cryptor)
        }
        for chunk in try storedChunks() {
            try chunk.encryptSensitiveFieldsIfNeeded(cryptor: cryptor)
        }
        for embedding in try storedEmbeddings() {
            try embedding.encryptSensitiveFieldsIfNeeded(cryptor: cryptor)
        }
        for trace in try context.fetch(FetchDescriptor<StoredRetrievalTrace>()) {
            try trace.encryptSensitiveFieldsIfNeeded(cryptor: cryptor)
        }
        try migrateLegacyDocumentsIfNeeded()
        try context.save()
    }

    func deleteAll() throws {
        for document in try storedDocuments() {
            context.delete(document)
        }
        for source in try storedSources() {
            context.delete(source)
        }
        for document in try storedDocumentRecords() {
            context.delete(document)
        }
        for chunk in try storedChunks() {
            context.delete(chunk)
        }
        for embedding in try storedEmbeddings() {
            deleteVectorBlob(for: embedding)
            context.delete(embedding)
        }
        for trace in try context.fetch(FetchDescriptor<StoredRetrievalTrace>()) {
            context.delete(trace)
        }
        vectorBlobStore?.deleteAllShards()
        invalidateEmbeddingVectorCache()
        try context.save()
    }

    func keywordSearch(query: String, limit: Int = 4, workspaceId: String? = nil) throws -> [KnowledgeSearchResult] {
        let options = KnowledgeRetrievalOptions(workspaceId: workspaceId ?? self.workspaceId, limit: limit, candidateLimit: max(limit * 3, 12))
        let results = try hybridSearch(query: query, options: options, queryEmbedding: nil)
        if !results.isEmpty { return results }
        return try legacyKeywordSearch(query: query, limit: limit, workspaceId: workspaceId)
    }

    func hybridSearch(
        query: String,
        options: KnowledgeRetrievalOptions,
        queryEmbedding: [Double]? = nil,
        embeddingModel: String? = nil
    ) throws -> [KnowledgeSearchResult] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return [] }
        let sourcesById = Dictionary(uniqueKeysWithValues: try sources(workspaceId: options.workspaceId).map { ($0.id, $0) })
        let documentsById = Dictionary(uniqueKeysWithValues: try documentRecords().filter { $0.workspaceId == options.workspaceId }.map { ($0.id, $0) })
        let chunks = try chunkRecords()
            .filter { $0.workspaceId == options.workspaceId }
            .filter { chunk in
                guard let source = sourcesById[chunk.sourceId], source.isEnabled else { return false }
                if let selectedSourceId = options.selectedSourceId, selectedSourceId != source.id { return false }
                return options.allowedKinds.contains(source.kind)
            }
        guard !chunks.isEmpty else { return [] }

        let terms = LocalBM25Index.tokens(from: normalizedQuery)
        let candidateLimit = max(options.candidateLimit, options.limit)
        let keywordRanked = rankedByKeyword(
            chunks: chunks,
            documentsById: documentsById,
            sourcesById: sourcesById,
            terms: terms,
            limit: candidateLimit
        )
        let semanticRanked = try rankedBySemantic(
            chunks: chunks,
            queryEmbedding: queryEmbedding,
            embeddingModel: embeddingModel,
            workspaceId: options.workspaceId,
            documentsById: documentsById,
            sourcesById: sourcesById,
            limit: candidateLimit
        )
        let fused = reciprocalRankFuse(keywordRanked: keywordRanked, semanticRanked: semanticRanked)
        let chunksById = Dictionary(uniqueKeysWithValues: chunks.map { ($0.id, $0) })
        let chunksByDocumentId = Dictionary(grouping: chunks, by: \.documentId)
        return fused
            .compactMap { fusedItem -> KnowledgeSearchResult? in
                guard let chunk = chunksById[fusedItem.chunkId],
                      let document = documentsById[chunk.documentId],
                      let source = sourcesById[chunk.sourceId],
                      fusedItem.score >= options.minScore else { return nil }
                return KnowledgeSearchResult(
                    documentName: document.displayName,
                    snippet: makeSnippet(content: chunk.content, terms: Set(terms)),
                    contextSnippet: makeContextSnippet(
                        for: chunk,
                        document: document,
                        source: source,
                        siblings: chunksByDocumentId[chunk.documentId] ?? [chunk]
                    ),
                    score: fusedItem.score,
                    workspaceId: chunk.workspaceId,
                    sourceId: source.id,
                    documentId: document.id,
                    chunkId: chunk.id,
                    sourceKind: source.kind,
                    locationLabel: chunk.locationLabel,
                    reference: reference(for: document, chunk: chunk),
                    keywordScore: fusedItem.keywordScore,
                    semanticScore: fusedItem.semanticScore,
                    recencyScore: recencyScore(for: document.updatedAt)
                )
            }
            .prefix(options.limit)
            .map { $0 }
    }

    func buildContext(for query: String, workspaceId: String? = nil) throws -> String {
        try keywordSearch(query: query, workspaceId: workspaceId)
            .map { "[\($0.documentName)\($0.locationLabel.map { " - \($0)" } ?? "")] \($0.snippet)" }
            .joined(separator: "\n")
    }

    func chunksMissingEmbedding(model: String, workspaceId: String? = nil, limit: Int = 64) throws -> [KnowledgeChunkRecord] {
        let targetWorkspaceId = workspaceId ?? self.workspaceId
        let embeddedKeys = try storedEmbeddingKeys(model: model)
        let documentsById = Dictionary(uniqueKeysWithValues: try documentRecords().filter { $0.workspaceId == targetWorkspaceId }.map { ($0.id, $0) })
        let sourcesById = Dictionary(uniqueKeysWithValues: try sources(workspaceId: targetWorkspaceId).map { ($0.id, $0) })
        return try chunkRecords()
            .filter { $0.workspaceId == targetWorkspaceId }
            .filter { chunk in
                guard sourcesById[chunk.sourceId]?.isEnabled == true else { return false }
                let contentHash = embeddingContentHash(
                    for: chunk,
                    document: documentsById[chunk.documentId],
                    source: sourcesById[chunk.sourceId]
                )
                return !embeddedKeys.contains("\(chunk.id.uuidString)|\(contentHash)")
            }
            .prefix(limit)
            .map { $0 }
    }

    func saveEmbeddings(_ embeddings: [(chunkId: UUID, model: String, contentHash: String, vector: [Double])]) throws {
        let existing = try storedEmbeddings()
        for item in embeddings {
            for stored in existing where stored.chunkId == item.chunkId && stored.model == item.model {
                deleteVectorBlob(for: stored)
                context.delete(stored)
            }
            let sidecarKey = vectorBlobStore?.storageKey(model: item.model, chunkId: item.chunkId, contentHash: item.contentHash)
            if let sidecarKey {
                try vectorBlobStore?.writeVector(item.vector, storageKey: sidecarKey, cryptor: cryptor)
            }
            context.insert(try StoredKnowledgeEmbeddingRecord(
                embedding: KnowledgeEmbeddingRecord(
                    id: UUID(),
                    chunkId: item.chunkId,
                    model: item.model,
                    contentHash: item.contentHash,
                    dimensions: item.vector.count,
                    vector: item.vector,
                    createdAt: Date()
                ),
                cryptor: cryptor,
                sidecarKey: sidecarKey
            ))
        }
        invalidateEmbeddingVectorCache()
        try context.save()
    }

    func indexMissingEmbeddings(
        provider: any EmbeddingProvider,
        workspaceId: String? = nil,
        limit: Int = 512,
        finalizeVectorShard: Bool = true
    ) async throws -> Int {
        guard provider.executionScope.isLocal else {
            throw EmbeddingProviderSafetyError.remoteProviderRejected(provider.modelIdentifier)
        }
        let targetWorkspaceId = workspaceId ?? self.workspaceId
        let model = provider.modelIdentifier
        _ = try repairEmbeddingIndex(model: model, workspaceId: targetWorkspaceId, rebuildVectorShard: false)
        let missing = try chunksMissingEmbedding(model: model, workspaceId: targetWorkspaceId, limit: limit)
        guard !missing.isEmpty else { return 0 }
        let documentsById = Dictionary(uniqueKeysWithValues: try documentRecords().filter { $0.workspaceId == targetWorkspaceId }.map { ($0.id, $0) })
        let sourcesById = Dictionary(uniqueKeysWithValues: try sources(workspaceId: targetWorkspaceId).map { ($0.id, $0) })
        let inputs = missing.map { chunk in
            embeddingInput(
                for: chunk,
                document: documentsById[chunk.documentId],
                source: sourcesById[chunk.sourceId]
            )
        }
        let vectors = try await provider.embed(inputs)
        try validateEmbeddingBatch(vectors, expectedCount: missing.count, provider: provider)
        let payload = zip(missing, vectors).map { chunk, vector in
            (
                chunkId: chunk.id,
                model: model,
                contentHash: embeddingContentHash(
                    for: chunk,
                    document: documentsById[chunk.documentId],
                    source: sourcesById[chunk.sourceId]
                ),
                vector: vector
            )
        }
        try saveEmbeddings(payload)
        if finalizeVectorShard {
            try rebuildVectorShard(model: model, workspaceId: targetWorkspaceId)
        }
        return payload.count
    }

    private func validateEmbeddingBatch(
        _ vectors: [[Double]],
        expectedCount: Int,
        provider: any EmbeddingProvider
    ) throws {
        guard vectors.count == expectedCount else {
            throw EmbeddingProviderSafetyError.invalidBatchCount(
                model: provider.modelIdentifier,
                expected: expectedCount,
                actual: vectors.count
            )
        }
        let expectedDimensions = provider.dimensions
        for vector in vectors {
            guard vector.count == expectedDimensions else {
                throw EmbeddingProviderSafetyError.invalidVectorDimensions(
                    model: provider.modelIdentifier,
                    expected: expectedDimensions,
                    actual: vector.count
                )
            }
            guard vector.allSatisfy({ $0.isFinite }) else {
                throw EmbeddingProviderSafetyError.invalidVectorValue(model: provider.modelIdentifier)
            }
        }
    }

    func finalizeEmbeddingIndex(model: String, workspaceId: String? = nil) throws {
        _ = try warmRetrievalIndexes(model: model, workspaceId: workspaceId ?? self.workspaceId)
    }

    @discardableResult
    func warmRetrievalIndexes(model: String, workspaceId: String? = nil) throws -> KnowledgeRetrievalWarmupReport {
        let targetWorkspaceId = workspaceId ?? self.workspaceId
        let sourcesById = Dictionary(uniqueKeysWithValues: try sources(workspaceId: targetWorkspaceId).map { ($0.id, $0) })
        let enabledSourceIds = Set(sourcesById.values.filter(\.isEnabled).map(\.id))
        let documentsById = Dictionary(uniqueKeysWithValues: try documentRecords().filter { $0.workspaceId == targetWorkspaceId }.map { ($0.id, $0) })
        let chunks = try chunkRecords()
            .filter { $0.workspaceId == targetWorkspaceId && enabledSourceIds.contains($0.sourceId) }
        guard !chunks.isEmpty else {
            return KnowledgeRetrievalWarmupReport(
                workspaceId: targetWorkspaceId,
                sourceCount: sourcesById.count,
                chunkCount: 0,
                embeddedVectorCount: 0,
                bm25Ready: false,
                annReady: false,
                warmedAt: Date()
            )
        }

        _ = cachedBM25Index(chunks: chunks, documentsById: documentsById, sourcesById: sourcesById)
        let vectorsByChunkId = try cachedEmbeddingVectors(
            model: model,
            workspaceId: targetWorkspaceId,
            chunks: chunks,
            documentsById: documentsById,
            sourcesById: sourcesById
        )
        let candidates = chunks.compactMap { chunk -> VectorSearchService.Candidate? in
            guard let vector = vectorsByChunkId[chunk.id], !vector.isEmpty else { return nil }
            return VectorSearchService.Candidate(chunkId: chunk.id, vector: vector)
        }
        let annReady: Bool
        if candidates.count >= LocalVectorANNIndex.minimumCandidateCount {
            _ = cachedANNIndex(model: model, chunks: chunks, candidates: candidates)
            annReady = true
        } else {
            annReady = false
        }
        return KnowledgeRetrievalWarmupReport(
            workspaceId: targetWorkspaceId,
            sourceCount: sourcesById.count,
            chunkCount: chunks.count,
            embeddedVectorCount: candidates.count,
            bm25Ready: true,
            annReady: annReady,
            warmedAt: Date()
        )
    }

    func embeddingCoverage(model: String, workspaceId: String? = nil) throws -> (embedded: Int, total: Int) {
        let targetWorkspaceId = workspaceId ?? self.workspaceId
        let sourcesById = Dictionary(uniqueKeysWithValues: try sources(workspaceId: targetWorkspaceId).map { ($0.id, $0) })
        let chunks = try chunkRecords().filter {
            $0.workspaceId == targetWorkspaceId &&
                sourcesById[$0.sourceId]?.isEnabled == true
        }
        let documentsById = Dictionary(uniqueKeysWithValues: try documentRecords().filter { $0.workspaceId == targetWorkspaceId }.map { ($0.id, $0) })
        let embeddedKeys = try storedEmbeddingKeys(model: model)
        let embedded = chunks.filter { chunk in
            let contentHash = embeddingContentHash(
                for: chunk,
                document: documentsById[chunk.documentId],
                source: sourcesById[chunk.sourceId]
            )
            return embeddedKeys.contains("\(chunk.id.uuidString)|\(contentHash)")
        }.count
        return (embedded, chunks.count)
    }

    func hasSearchableEmbeddings(model: String, options: KnowledgeRetrievalOptions) throws -> Bool {
        let sourcesById = Dictionary(uniqueKeysWithValues: try sources(workspaceId: options.workspaceId).map { ($0.id, $0) })
        let documentsById = Dictionary(uniqueKeysWithValues: try documentRecords().filter { $0.workspaceId == options.workspaceId }.map { ($0.id, $0) })
        let embeddedKeys = try storedEmbeddingKeys(model: model)
        for chunk in try chunkRecords() where chunk.workspaceId == options.workspaceId {
            guard let source = sourcesById[chunk.sourceId], source.isEnabled else { continue }
            if let selectedSourceId = options.selectedSourceId, selectedSourceId != source.id { continue }
            guard options.allowedKinds.contains(source.kind) else { continue }
            let contentHash = embeddingContentHash(
                for: chunk,
                document: documentsById[chunk.documentId],
                source: source
            )
            if embeddedKeys.contains("\(chunk.id.uuidString)|\(contentHash)") {
                return true
            }
        }
        return false
    }

    @discardableResult
    func repairEmbeddingIndex(
        model: String,
        workspaceId: String? = nil,
        rebuildVectorShard: Bool = true
    ) throws -> KnowledgeEmbeddingMaintenanceReport {
        let targetWorkspaceId = workspaceId ?? self.workspaceId
        let sourceList = try sources(workspaceId: targetWorkspaceId)
        let sourcesById = Dictionary(uniqueKeysWithValues: sourceList.map { ($0.id, $0) })
        let enabledSourceIds = Set(sourceList.filter(\.isEnabled).map(\.id))
        let documentsById = Dictionary(uniqueKeysWithValues: try documentRecords().filter { $0.workspaceId == targetWorkspaceId }.map { ($0.id, $0) })
        let allChunks = try chunkRecords()
        let allChunkIds = Set(allChunks.map(\.id))
        let targetChunks = allChunks.filter { $0.workspaceId == targetWorkspaceId }
        let activeChunks = targetChunks.filter { enabledSourceIds.contains($0.sourceId) }
        let targetChunksById = Dictionary(uniqueKeysWithValues: targetChunks.map { ($0.id, $0) })
        let expectedHashesByChunkId = Dictionary(uniqueKeysWithValues: activeChunks.map { chunk in
            (
                chunk.id,
                embeddingContentHash(
                    for: chunk,
                    document: documentsById[chunk.documentId],
                    source: sourcesById[chunk.sourceId]
                )
            )
        })

        var validChunkIds = Set<UUID>()
        var deletedStaleEmbeddingCount = 0
        var deletedOrphanEmbeddingCount = 0
        var deletedDuplicateEmbeddingCount = 0

        for stored in try storedEmbeddings() where stored.model == model {
            if !allChunkIds.contains(stored.chunkId) {
                deleteVectorBlob(for: stored)
                context.delete(stored)
                deletedOrphanEmbeddingCount += 1
                continue
            }

            guard targetChunksById[stored.chunkId] != nil else { continue }
            guard let expectedHash = expectedHashesByChunkId[stored.chunkId],
                  stored.contentHash == expectedHash else {
                deleteVectorBlob(for: stored)
                context.delete(stored)
                deletedStaleEmbeddingCount += 1
                continue
            }

            if !validChunkIds.insert(stored.chunkId).inserted {
                deleteVectorBlob(for: stored)
                context.delete(stored)
                deletedDuplicateEmbeddingCount += 1
            }
        }

        let deletedCount = deletedStaleEmbeddingCount + deletedOrphanEmbeddingCount + deletedDuplicateEmbeddingCount
        if deletedCount > 0 {
            vectorBlobStore?.deleteAllShards()
            invalidateEmbeddingVectorCache()
            try context.save()
        }

        let missingEmbeddingCount = max(activeChunks.count - validChunkIds.count, 0)
        var rebuiltVectorShard = false
        if rebuildVectorShard, !activeChunks.isEmpty {
            _ = try warmRetrievalIndexes(model: model, workspaceId: targetWorkspaceId)
            rebuiltVectorShard = true
        }

        return KnowledgeEmbeddingMaintenanceReport(
            workspaceId: targetWorkspaceId,
            model: model,
            activeChunkCount: activeChunks.count,
            validEmbeddingCount: validChunkIds.count,
            missingEmbeddingCount: missingEmbeddingCount,
            deletedStaleEmbeddingCount: deletedStaleEmbeddingCount,
            deletedOrphanEmbeddingCount: deletedOrphanEmbeddingCount,
            deletedDuplicateEmbeddingCount: deletedDuplicateEmbeddingCount,
            rebuiltVectorShard: rebuiltVectorShard,
            maintainedAt: Date()
        )
    }

    func indexHealthReport(
        model: String,
        workspaceId: String? = nil,
        latencyTargetMs: Int = 250,
        traceWindow: TimeInterval = 7 * 86_400
    ) throws -> KnowledgeIndexHealthReport {
        let targetWorkspaceId = workspaceId ?? self.workspaceId
        let sourceList = try sources(workspaceId: targetWorkspaceId)
        let documents = try documentRecords().filter { $0.workspaceId == targetWorkspaceId }
        let enabledSourceIds = Set(sourceList.filter(\.isEnabled).map(\.id))
        let chunks = try chunkRecords().filter { $0.workspaceId == targetWorkspaceId && enabledSourceIds.contains($0.sourceId) }
        let coverage = try embeddingCoverage(model: model, workspaceId: targetWorkspaceId)
        let traceSignals = try recentRetrievalTraceSignals(workspaceId: targetWorkspaceId, traceWindow: traceWindow)
        let p95Latency = Self.percentile(traceSignals.map(\.latencyMs), percentile: 0.95)
        let staleChunkCount = max(coverage.total - coverage.embedded, 0)
        let failedSourceCount = sourceList.filter { $0.status == .failed }.count
        let weakTraceCount = traceSignals.filter(\.isWeakEvidence).count
        let uncitedTraceCount = traceSignals.filter {
            $0.resultCount > 0 && $0.structuredReferenceCount == 0
        }.count
        let hybridTraceCount = traceSignals.filter {
            $0.hybridEvidenceCount > 0
        }.count
        let embeddingCoverage = coverage.total > 0 ? Double(coverage.embedded) / Double(coverage.total) : 0
        var recommendations: [String] = []

        if sourceList.isEmpty {
            recommendations.append("Connect a Directory, Obsidian vault, file, or meeting source before relying on local RAG.")
        }
        if failedSourceCount > 0 {
            recommendations.append("Reconnect or reindex \(failedSourceCount) failed knowledge source\(failedSourceCount == 1 ? "" : "s").")
        }
        if coverage.total > 0, staleChunkCount > 0 {
            recommendations.append("Embed \(staleChunkCount) stale or missing chunk\(staleChunkCount == 1 ? "" : "s") in the background before realtime use.")
        }
        if coverage.total == 0, !documents.isEmpty {
            recommendations.append("Run background chunking and local embedding indexation for the current workspace.")
        }
        if let p95Latency, p95Latency > latencyTargetMs {
            recommendations.append("Switch to the fast local embedding runtime or rebuild ANN/vector shards; retrieval p95 is \(p95Latency)ms.")
        }
        let queryEmbeddingP95Ms = Self.percentile(traceSignals.compactMap { $0.stageLatencies?.queryEmbeddingMs }, percentile: 0.95)
        let hybridSearchP95Ms = Self.percentile(traceSignals.compactMap { $0.stageLatencies?.hybridSearchMs }, percentile: 0.95)
        let rerankP95Ms = Self.percentile(traceSignals.compactMap { $0.stageLatencies?.rerankMs }, percentile: 0.95)
        let contextAssemblyP95Ms = Self.percentile(traceSignals.compactMap { $0.stageLatencies?.contextAssemblyMs }, percentile: 0.95)
        if let queryEmbeddingP95Ms, queryEmbeddingP95Ms > max(80, latencyTargetMs / 3) {
            recommendations.append("Query embedding p95 is \(queryEmbeddingP95Ms)ms; benchmark a faster local embedding runtime for realtime meetings.")
        }
        if let hybridSearchP95Ms, hybridSearchP95Ms > 60 {
            recommendations.append("Hybrid search p95 is \(hybridSearchP95Ms)ms; warm or rebuild local BM25/ANN/vector shards.")
        }
        if uncitedTraceCount > 0 {
            recommendations.append("Repair citation metadata for \(uncitedTraceCount) retrieval trace\(uncitedTraceCount == 1 ? "" : "s") without chunk/source/document references.")
        }
        if traceSignals.count >= 4, Double(weakTraceCount) / Double(traceSignals.count) > 0.25 {
            recommendations.append("Add or refresh sources for recent weak queries; too many retrieval traces have low evidence.")
        }
        if recommendations.isEmpty {
            recommendations.append("Local RAG index is healthy for realtime retrieval.")
        }

        return KnowledgeIndexHealthReport(
            workspaceId: targetWorkspaceId,
            sourceCount: sourceList.count,
            failedSourceCount: failedSourceCount,
            documentCount: documents.count,
            chunkCount: chunks.count,
            embeddedChunkCount: coverage.embedded,
            staleChunkCount: staleChunkCount,
            embeddingCoverage: embeddingCoverage,
            recentTraceCount: traceSignals.count,
            weakTraceCount: weakTraceCount,
            uncitedTraceCount: uncitedTraceCount,
            hybridTraceCount: hybridTraceCount,
            slowTraceP95Ms: p95Latency,
            queryEmbeddingP95Ms: queryEmbeddingP95Ms,
            hybridSearchP95Ms: hybridSearchP95Ms,
            rerankP95Ms: rerankP95Ms,
            contextAssemblyP95Ms: contextAssemblyP95Ms,
            recommendations: recommendations
        )
    }

    func recordRetrievalTrace(
        query: String,
        workspaceId: String,
        results: [KnowledgeSearchResult],
        latencyMs: Int,
        stageLatencies: KnowledgeRetrievalStageLatencies? = nil
    ) {
        let summary = results.map {
            RetrievalTraceResultSummary(
                document: $0.documentName,
                source: $0.sourceKind.rawValue,
                chunkId: $0.chunkId?.uuidString ?? "",
                documentId: $0.documentId?.uuidString ?? "",
                sourceId: $0.sourceId?.uuidString ?? "",
                score: String(format: "%.4f", $0.score),
                keywordScore: String(format: "%.4f", $0.keywordScore),
                semanticScore: String(format: "%.4f", $0.semanticScore)
            )
        }
        let payload = RetrievalTracePayload(stages: stageLatencies, results: summary)
        let resultJSON = Self.encodedJSONString(payload, encoder: encoder, fallback: "[]")
        let queryHash = Self.hash(query)
        if let trace = try? StoredRetrievalTrace(queryHash: queryHash, query: query, workspaceId: workspaceId, resultJSON: resultJSON, latencyMs: latencyMs, cryptor: cryptor) {
            context.insert(trace)
            try? context.save()
        }
    }

    private func indexFiles(in rootURL: URL, source: KnowledgeSource) throws -> Set<String> {
        var indexedPaths = Set<String>()
        let existingSnapshots = try indexedFileSnapshots(sourceId: source.id)
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsPackageDescendants],
            errorHandler: nil
        ) else { return indexedPaths }

        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: Set(resourceKeys))
            if values?.isDirectory == true {
                if shouldSkipDirectory(fileURL, source: source) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            guard DocumentIngestionService.supportedExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
            guard (values?.fileSize ?? 0) <= 25_000_000 else { continue }
            indexedPaths.insert(fileURL.path)
            try indexFile(
                fileURL,
                source: source,
                fileSize: values?.fileSize ?? 0,
                modifiedAt: values?.contentModificationDate,
                existingSnapshots: existingSnapshots
            )
        }
        return indexedPaths
    }

    private func indexFile(
        _ url: URL,
        source: KnowledgeSource,
        fileSize: Int,
        modifiedAt: Date?,
        existingSnapshots: [String: IndexedFileSnapshot]
    ) throws {
        if isUnchangedFile(path: url.path, fileSize: fileSize, modifiedAt: modifiedAt, existingSnapshots: existingSnapshots) {
            return
        }
        let ingestion = DocumentIngestionService()
        let text = try ingestion.readText(from: url)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try upsertDocument(
            source: source,
            displayName: url.lastPathComponent,
            filePath: url.path,
            content: text,
            kind: ingestion.documentKind(for: url),
            modifiedAt: modifiedAt,
            metadata: source.kind == .obsidian ? obsidianMetadata(from: text) : [:],
            fileSize: fileSize
        )
    }

    private func indexedFileSnapshots(sourceId: UUID) throws -> [String: IndexedFileSnapshot] {
        try documentRecords()
            .filter { $0.sourceId == sourceId }
            .reduce(into: [String: IndexedFileSnapshot]()) { partial, document in
                guard let filePath = document.filePath else { return }
                partial[filePath] = IndexedFileSnapshot(
                    fileSize: document.fileSize,
                    modifiedAt: document.modifiedAt
                )
            }
    }

    private func isUnchangedFile(
        path: String,
        fileSize: Int,
        modifiedAt: Date?,
        existingSnapshots: [String: IndexedFileSnapshot]
    ) -> Bool {
        guard let snapshot = existingSnapshots[path],
              snapshot.fileSize == fileSize,
              let existingModifiedAt = snapshot.modifiedAt,
              let modifiedAt else {
            return false
        }
        return abs(existingModifiedAt.timeIntervalSince(modifiedAt)) < 0.5
    }

    private func upsertDocument(
        source: KnowledgeSource,
        displayName: String,
        filePath: String?,
        content: String,
        kind: KnowledgeDocumentKind,
        modifiedAt: Date?,
        metadata: [String: String],
        fileSize: Int? = nil
    ) throws {
        let contentHash = Self.hash(content)
        let existing = try storedDocumentRecords().first { stored in
            guard stored.sourceId == source.id else { return false }
            if let filePath {
                return (try? cryptor.decryptOptionalString(stored.filePath, context: StoredKnowledgeDocumentRecord.filePathContext)) == filePath
            }
            return stored.contentHash == contentHash
        }
        let now = Date()
        let document: KnowledgeDocumentRecord
        if let existing {
            let existingDocument = try existing.decrypt(cryptor: cryptor)
            if existingDocument.contentHash == contentHash {
                return
            }
            document = KnowledgeDocumentRecord(
                id: existingDocument.id,
                sourceId: source.id,
                displayName: displayName,
                filePath: filePath,
                contentHash: contentHash,
                fileSize: fileSize ?? content.utf8.count,
                modifiedAt: modifiedAt,
                workspaceId: source.workspaceId,
                kind: kind,
                metadata: metadata,
                createdAt: existingDocument.createdAt,
                updatedAt: now
            )
            try existing.update(from: document, encoder: encoder, cryptor: cryptor)
            try deleteChunks(documentId: document.id)
        } else {
            document = KnowledgeDocumentRecord(
                id: UUID(),
                sourceId: source.id,
                displayName: displayName,
                filePath: filePath,
                contentHash: contentHash,
                fileSize: fileSize ?? content.utf8.count,
                modifiedAt: modifiedAt,
                workspaceId: source.workspaceId,
                kind: kind,
                metadata: metadata,
                createdAt: now,
                updatedAt: now
            )
            context.insert(try StoredKnowledgeDocumentRecord(document: document, encoder: encoder, cryptor: cryptor))
        }

        let drafts = DocumentIngestionService().structuredChunks(
            from: content,
            kind: kind,
            targetTokens: chunkTargetTokens,
            overlapTokens: chunkOverlapTokens
        )
        for (index, draft) in drafts.enumerated() {
            context.insert(try StoredKnowledgeChunk(
                chunk: KnowledgeChunkRecord(
                    id: UUID(),
                    documentId: document.id,
                    sourceId: source.id,
                    sequence: index,
                    heading: draft.heading,
                    content: normalizedObsidianText(draft.content),
                    tokenEstimate: draft.tokenEstimate,
                    locationLabel: draft.locationLabel,
                    contentHash: Self.hash(draft.content),
                    workspaceId: source.workspaceId,
                    createdAt: now,
                    updatedAt: now
                ),
                cryptor: cryptor
            ))
        }
    }

    private func upsertSource(
        kind: KnowledgeSourceKind,
        displayName: String,
        rootPath: String?,
        bookmarkData: Data?,
        workspaceId: String,
        status: KnowledgeSourceStatus
    ) throws -> KnowledgeSource {
        let existing = try sources(workspaceId: workspaceId).first { $0.kind == kind && $0.rootPath == rootPath && rootPath != nil }
        let now = Date()
        let source = KnowledgeSource(
            id: existing?.id ?? UUID(),
            kind: kind,
            displayName: displayName,
            rootPath: rootPath,
            bookmarkData: bookmarkData ?? existing?.bookmarkData,
            workspaceId: workspaceId,
            status: status,
            isEnabled: existing?.isEnabled ?? true,
            lastIndexedAt: existing?.lastIndexedAt,
            lastError: nil,
            documentCount: existing?.documentCount ?? 0,
            chunkCount: existing?.chunkCount ?? 0,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
        try saveSource(source)
        return source
    }

    private func saveSource(_ source: KnowledgeSource) throws {
        if let stored = try storedSources().first(where: { $0.id == source.id }) {
            try stored.update(from: source, cryptor: cryptor)
        } else {
            context.insert(try StoredKnowledgeSource(source: source, cryptor: cryptor))
        }
    }

    private func source(id: UUID) throws -> KnowledgeSource {
        guard let stored = try storedSources().first(where: { $0.id == id }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try stored.decrypt(cryptor: cryptor)
    }

    private func legacySource(workspaceId: String) throws -> KnowledgeSource {
        if let existing = try sources(workspaceId: workspaceId).first(where: { $0.kind == .legacy }) {
            return existing
        }
        return try upsertSource(kind: .legacy, displayName: "Imported Knowledge", rootPath: nil, bookmarkData: nil, workspaceId: workspaceId, status: .connected)
    }

    private func fileSource(workspaceId: String) throws -> KnowledgeSource {
        if let existing = try sources(workspaceId: workspaceId).first(where: { $0.kind == .file }) {
            return existing
        }
        return try upsertSource(kind: .file, displayName: "Files", rootPath: nil, bookmarkData: nil, workspaceId: workspaceId, status: .connected)
    }

    private func meetingSource(workspaceId: String) throws -> KnowledgeSource {
        if let existing = try sources(workspaceId: workspaceId).first(where: { $0.kind == .meeting }) {
            return existing
        }
        return try upsertSource(kind: .meeting, displayName: "Meetings", rootPath: nil, bookmarkData: nil, workspaceId: workspaceId, status: .connected)
    }

    private func refreshSourceCounts(sourceId: UUID) throws {
        var source = try source(id: sourceId)
        let documents = try storedDocumentRecords().filter { $0.sourceId == sourceId }
        let chunks = try storedChunks().filter { $0.sourceId == sourceId }
        source.documentCount = documents.count
        source.chunkCount = chunks.count
        source.updatedAt = Date()
        if source.status != .indexing {
            source.status = documents.isEmpty ? .empty : .connected
        }
        try saveSource(source)
    }

    private func migrateLegacyDocumentsIfNeeded() throws {
        for legacy in try storedDocuments().map({ try $0.decrypt(cryptor: cryptor) }) {
            let source = try legacySource(workspaceId: legacy.workspaceId)
            let alreadyExists = try documentRecords().contains { record in
                record.workspaceId == legacy.workspaceId &&
                    record.contentHash == Self.hash(legacy.content) &&
                    record.displayName == legacy.displayName
            }
            guard !alreadyExists else { continue }
            try upsertDocument(
                source: source,
                displayName: legacy.displayName,
                filePath: legacy.filePath,
                content: legacy.content,
                kind: legacy.filePath.map { DocumentIngestionService().documentKind(for: URL(fileURLWithPath: $0)) } ?? .text,
                modifiedAt: legacy.createdAt,
                metadata: ["origin": "legacy"]
            )
            try refreshSourceCounts(sourceId: source.id)
        }
    }

    private func legacyKeywordSearch(query: String, limit: Int = 4, workspaceId: String? = nil) throws -> [KnowledgeSearchResult] {
        let terms = Set(tokenized(query))
        guard !terms.isEmpty else { return [] }
        let targetWorkspaceId = workspaceId ?? self.workspaceId
        return try storedDocuments()
            .map { try $0.decrypt(cryptor: cryptor) }
            .filter { $0.workspaceId == targetWorkspaceId }
            .compactMap { document in
                let lowered = document.content.lowercased()
                let matches = terms.filter { lowered.contains($0) }.count
                guard matches > 0 else { return nil }
                let snippet = makeSnippet(content: document.content, terms: terms)
                return KnowledgeSearchResult(documentName: document.displayName, snippet: snippet, score: Double(matches) / Double(max(terms.count, 1)), workspaceId: document.workspaceId)
            }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    private func rankedByKeyword(
        chunks: [KnowledgeChunkRecord],
        documentsById: [UUID: KnowledgeDocumentRecord],
        sourcesById: [UUID: KnowledgeSource],
        terms: [String],
        limit: Int
    ) -> [(chunkId: UUID, score: Double)] {
        guard !terms.isEmpty else { return [] }
        let index = cachedBM25Index(chunks: chunks, documentsById: documentsById, sourcesById: sourcesById)
        let chunksById = Dictionary(uniqueKeysWithValues: chunks.map { ($0.id, $0) })
        return index.search(terms: terms, limit: limit).compactMap { item in
            guard let chunk = chunksById[item.chunkId] else { return nil }
            var score = item.score
            if let document = documentsById[chunk.documentId] {
                score += recencyScore(for: document.updatedAt) * 0.08
            }
            if let source = sourcesById[chunk.sourceId], source.kind == .meeting {
                score += 0.03
            }
            return score > 0 ? (chunk.id, score) : nil
        }
        .sorted { $0.score > $1.score }
    }

    private func rankedBySemantic(
        chunks: [KnowledgeChunkRecord],
        queryEmbedding: [Double]?,
        embeddingModel: String?,
        workspaceId: String?,
        documentsById: [UUID: KnowledgeDocumentRecord],
        sourcesById: [UUID: KnowledgeSource],
        limit: Int
    ) throws -> [(chunkId: UUID, score: Double)] {
        guard let queryEmbedding, !queryEmbedding.isEmpty else { return [] }
        let byChunk = try cachedEmbeddingVectors(
            model: embeddingModel,
            workspaceId: workspaceId,
            chunks: chunks,
            documentsById: documentsById,
            sourcesById: sourcesById
        )
        let vectorSearch = VectorSearchService()
        let candidates = chunks.compactMap { chunk -> VectorSearchService.Candidate? in
            guard let vector = byChunk[chunk.id] else { return nil }
            return VectorSearchService.Candidate(chunkId: chunk.id, vector: vector)
        }
        if candidates.count >= LocalVectorANNIndex.minimumCandidateCount {
            let index = cachedANNIndex(model: embeddingModel, chunks: chunks, candidates: candidates)
            return index.search(query: queryEmbedding, limit: limit, efSearch: max(limit * 14, 96))
        }
        return vectorSearch.rank(query: queryEmbedding, candidates: candidates, limit: limit)
    }

    private func reciprocalRankFuse(
        keywordRanked: [(chunkId: UUID, score: Double)],
        semanticRanked: [(chunkId: UUID, score: Double)]
    ) -> [(chunkId: UUID, score: Double, keywordScore: Double, semanticScore: Double)] {
        var scores: [UUID: (score: Double, keywordScore: Double, semanticScore: Double)] = [:]
        for (rank, item) in keywordRanked.enumerated() {
            var current = scores[item.chunkId] ?? (0, 0, 0)
            current.score += 1.0 / Double(60 + rank + 1)
            current.keywordScore = item.score
            scores[item.chunkId] = current
        }
        for (rank, item) in semanticRanked.enumerated() {
            var current = scores[item.chunkId] ?? (0, 0, 0)
            current.score += 1.0 / Double(60 + rank + 1)
            current.semanticScore = item.score
            scores[item.chunkId] = current
        }
        if semanticRanked.isEmpty {
            for (rank, item) in keywordRanked.enumerated() {
                var current = scores[item.chunkId] ?? (0, item.score, 0)
                current.score += max(0, item.score) * 0.12 / Double(rank + 1)
                scores[item.chunkId] = current
            }
        }
        return scores.map { (chunkId: $0.key, score: $0.value.score, keywordScore: $0.value.keywordScore, semanticScore: $0.value.semanticScore) }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score { return lhs.keywordScore > rhs.keywordScore }
                return lhs.score > rhs.score
            }
    }

    private func deleteDocumentsMissing(from paths: Set<String>, sourceId: UUID) throws {
        for document in try documentRecords().filter({ $0.sourceId == sourceId }) {
            guard let filePath = document.filePath, !paths.contains(filePath) else { continue }
            for stored in try storedDocumentRecords() where stored.id == document.id {
                context.delete(stored)
            }
            try deleteChunks(documentId: document.id)
        }
    }

    private func deleteChunks(documentId: UUID) throws {
        let chunkIds = try storedChunks().filter { $0.documentId == documentId }.map(\.id)
        for chunk in try storedChunks() where chunk.documentId == documentId {
            context.delete(chunk)
        }
        for embedding in try storedEmbeddings() where chunkIds.contains(embedding.chunkId) {
            deleteVectorBlob(for: embedding)
            context.delete(embedding)
        }
        invalidateEmbeddingVectorCache()
    }

    private func shouldSkipDirectory(_ url: URL, source: KnowledgeSource) -> Bool {
        let name = url.lastPathComponent
        if name.hasPrefix(".") { return true }
        if source.kind == .obsidian, name == ".obsidian" { return true }
        return ["node_modules", ".git", "DerivedData", "build"].contains(name)
    }

    private func obsidianMetadata(from text: String) -> [String: String] {
        var metadata: [String: String] = [:]
        if text.hasPrefix("---"), let end = text.dropFirst(3).range(of: "---") {
            let frontmatter = text[text.index(text.startIndex, offsetBy: 3)..<end.lowerBound]
            metadata["frontmatter"] = String(frontmatter.prefix(900))
            let frontmatterTags = Self.frontmatterTags(from: String(frontmatter))
            if !frontmatterTags.isEmpty {
                metadata["tags"] = frontmatterTags.sorted().joined(separator: ",")
            }
        }
        var tags = Set((metadata["tags"] ?? "")
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
        tags.formUnion(text.split(whereSeparator: \.isWhitespace).compactMap { token -> String? in
            let value = String(token).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:()[]{}"))
            return value.hasPrefix("#") && value.count > 1 ? value : nil
        })
        if !tags.isEmpty {
            metadata["tags"] = tags.sorted().joined(separator: ",")
        }
        let links = Self.obsidianLinks(in: text)
        if !links.wikilinks.isEmpty {
            metadata["wikilinks"] = links.wikilinks.sorted().joined(separator: "\n")
        }
        if !links.attachments.isEmpty {
            metadata["attachments"] = links.attachments.sorted().joined(separator: "\n")
        }
        return metadata
    }

    private func refreshObsidianGraphMetadata(sourceId: UUID) throws {
        let storedRecords = try storedDocumentRecords().filter { $0.sourceId == sourceId }
        let documents = try storedRecords.map { try $0.decrypt(cryptor: cryptor) }
        let documentsByCanonicalName = Dictionary(grouping: documents, by: { Self.obsidianCanonicalName(Self.obsidianTitle(for: $0)) })
        var backlinksByDocumentId: [UUID: Set<String>] = [:]

        for document in documents {
            let sourceTitle = Self.obsidianTitle(for: document)
            for link in Self.metadataList(document.metadata["wikilinks"]) {
                let targetName = Self.obsidianCanonicalName(link)
                for target in documentsByCanonicalName[targetName] ?? [] where target.id != document.id {
                    backlinksByDocumentId[target.id, default: []].insert(sourceTitle)
                }
            }
        }

        var didChange = false
        for stored in storedRecords {
            var document = try stored.decrypt(cryptor: cryptor)
            var metadata = document.metadata
            let backlinks = backlinksByDocumentId[document.id]?.sorted() ?? []
            let encodedBacklinks = backlinks.joined(separator: "\n")
            if encodedBacklinks.isEmpty {
                if metadata.removeValue(forKey: "backlinks") != nil {
                    didChange = true
                }
            } else if metadata["backlinks"] != encodedBacklinks {
                metadata["backlinks"] = encodedBacklinks
                didChange = true
            }
            guard document.metadata != metadata else { continue }
            document.metadata = metadata
            document.updatedAt = Date()
            try stored.update(from: document, encoder: encoder, cryptor: cryptor)
        }
        if didChange {
            invalidateEmbeddingVectorCache()
            try context.save()
        }
    }

    private func embeddingInput(
        for chunk: KnowledgeChunkRecord,
        document: KnowledgeDocumentRecord?,
        source: KnowledgeSource?
    ) -> String {
        var lines: [String] = []
        let semanticProfile = Self.semanticProfile(for: document, source: source)
        if let source {
            lines.append("Source: \(source.kind.displayName)")
        }
        lines.append("Content role: \(semanticProfile.role)")
        lines.append("Retrieval focus: \(semanticProfile.retrievalFocus)")
        if let document {
            lines.append("Document: \(document.displayName)")
            if let kind = document.metadata["kind"], !kind.isEmpty {
                lines.append("Document kind: \(kind)")
            } else {
                lines.append("Document kind: \(document.kind.rawValue)")
            }
            if let tags = document.metadata["tags"], !tags.isEmpty {
                lines.append("Tags: \(tags)")
            }
            if let meetingType = document.metadata["meetingType"], !meetingType.isEmpty {
                lines.append("Meeting type: \(meetingType)")
            }
            if let speakers = document.metadata["speakers"], !speakers.isEmpty {
                lines.append("Speakers: \(speakers)")
            }
            if let audioSources = document.metadata["audioSources"], !audioSources.isEmpty {
                lines.append("Audio sources: \(audioSources)")
            }
            if let language = document.metadata["language"], !language.isEmpty {
                lines.append("Language: \(language)")
            }
            if let wikilinks = Self.metadataSummary(document.metadata["wikilinks"]) {
                lines.append("Wikilinks: \(wikilinks)")
            }
            if let backlinks = Self.metadataSummary(document.metadata["backlinks"]) {
                lines.append("Backlinks: \(backlinks)")
            }
            if let attachments = Self.metadataSummary(document.metadata["attachments"]) {
                lines.append("Attachments: \(attachments)")
            }
        }
        if let heading = chunk.heading, !heading.isEmpty {
            lines.append("Heading: \(heading)")
        }
        if let locationLabel = chunk.locationLabel, !locationLabel.isEmpty {
            lines.append("Location: \(locationLabel)")
        }
        lines.append(chunk.content)
        return lines.joined(separator: "\n")
    }

    private func embeddingContentHash(
        for chunk: KnowledgeChunkRecord,
        document: KnowledgeDocumentRecord?,
        source: KnowledgeSource?
    ) -> String {
        Self.hash(embeddingInput(for: chunk, document: document, source: source))
    }

    private func meetingMetadata(
        for meeting: MeetingSession,
        segments: [TranscriptSegment],
        kind: String
    ) -> [String: String] {
        var metadata: [String: String] = [
            "meetingId": meeting.id.uuidString,
            "kind": kind,
            "meetingType": meeting.meetingType.rawValue,
            "meetingSource": meeting.source.rawValue,
            "startedAt": Self.iso8601String(meeting.startedAt)
        ]
        if let endedAt = meeting.endedAt {
            metadata["endedAt"] = Self.iso8601String(endedAt)
        }
        if let primaryLanguage = meeting.primaryLanguage, !primaryLanguage.isEmpty {
            metadata["language"] = primaryLanguage
        }
        if let appName = meeting.appName, !appName.isEmpty {
            metadata["appName"] = appName
        }
        if !meeting.tags.isEmpty {
            metadata["tags"] = meeting.tags.map { $0.hasPrefix("#") ? $0 : "#\($0)" }.sorted().joined(separator: ",")
        }
        let speakers = Set(segments.map(\.speakerLabel).filter { !$0.isEmpty })
        if !speakers.isEmpty {
            metadata["speakers"] = speakers.sorted().joined(separator: ",")
        }
        let audioSources = Set(segments.map(\.audioSource.rawValue))
        if !audioSources.isEmpty {
            metadata["audioSources"] = audioSources.sorted().joined(separator: ",")
        }
        return metadata
    }

    private static func meetingTranscriptLine(_ segment: TranscriptSegment) -> String {
        let endTime = max(segment.endTime, segment.startTime)
        let timeRange = "\(DateFormatting.duration(segment.startTime))-\(DateFormatting.duration(endTime))"
        return "[\(timeRange)] [\(segment.audioSource.displayName)] \(segment.speakerLabel): \(segment.text)"
    }

    private static func summaryActionLine(_ action: ActionItem) -> String {
        var parts = ["Action: \(action.title)"]
        if let owner = action.owner, !owner.isEmpty {
            parts.append("Owner: \(owner)")
        }
        parts.append("Priority: \(action.priority.rawValue)")
        if let dueDate = action.dueDate {
            parts.append("Due: \(iso8601String(dueDate))")
        }
        if let sourceQuote = action.sourceQuote, !sourceQuote.isEmpty {
            parts.append("Evidence: \(sourceQuote)")
        }
        return parts.joined(separator: " | ")
    }

    private static func iso8601String(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func normalizedObsidianText(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"!\[\[([^\]]+)\]\]"#, with: "Attachment: $1", options: .regularExpression)
            .replacingOccurrences(of: #"\[\[([^\]\|]+)\|([^\]]+)\]\]"#, with: "$2 ($1)", options: .regularExpression)
            .replacingOccurrences(of: #"\[\[([^\]]+)\]\]"#, with: "$1", options: .regularExpression)
    }

    private static func obsidianLinks(in text: String) -> (wikilinks: Set<String>, attachments: Set<String>) {
        let pattern = #"(!?)\[\[([^\]]+)\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return ([], []) }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var wikilinks = Set<String>()
        var attachments = Set<String>()
        for match in regex.matches(in: text, range: nsRange) {
            guard let bodyRange = Range(match.range(at: 2), in: text) else { continue }
            let target = obsidianLinkTarget(String(text[bodyRange]))
            guard !target.isEmpty else { continue }
            if let markerRange = Range(match.range(at: 1), in: text), text[markerRange] == "!" {
                attachments.insert(target)
            } else {
                wikilinks.insert(target)
            }
        }
        return (wikilinks, attachments)
    }

    private static func obsidianLinkTarget(_ raw: String) -> String {
        raw
            .split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init)?
            .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func obsidianCanonicalName(_ value: String) -> String {
        let normalizedPath = obsidianLinkTarget(value)
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lastComponent = normalizedPath.split(separator: "/").last.map(String.init) ?? normalizedPath
        let withoutExtension = URL(fileURLWithPath: lastComponent).deletingPathExtension().lastPathComponent
        return withoutExtension
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private static func obsidianTitle(for document: KnowledgeDocumentRecord) -> String {
        if let filePath = document.filePath, !filePath.isEmpty {
            return URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
        }
        return URL(fileURLWithPath: document.displayName).deletingPathExtension().lastPathComponent
    }

    private static func metadataList(_ value: String?) -> [String] {
        guard let value else { return [] }
        return value
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func metadataSummary(_ value: String?, limit: Int = 12) -> String? {
        let values = metadataList(value)
        guard !values.isEmpty else { return nil }
        return values.prefix(limit).joined(separator: ", ")
    }

    private static func frontmatterTags(from frontmatter: String) -> Set<String> {
        var tags = Set<String>()
        let lines = frontmatter.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("tags:") {
                let remainder = String(trimmed.dropFirst("tags:".count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: " []"))
                for tag in remainder.split(whereSeparator: { $0 == "," || $0 == " " }) {
                    let cleaned = String(tag).trimmingCharacters(in: CharacterSet(charactersIn: "\"'[]"))
                    if !cleaned.isEmpty {
                        tags.insert(cleaned.hasPrefix("#") ? cleaned : "#\(cleaned)")
                    }
                }
                for nested in lines.dropFirst(index + 1) {
                    let nestedTrimmed = nested.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard nestedTrimmed.hasPrefix("-") else { break }
                    let cleaned = String(nestedTrimmed.dropFirst()).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                    if !cleaned.isEmpty {
                        tags.insert(cleaned.hasPrefix("#") ? cleaned : "#\(cleaned)")
                    }
                }
            }
        }
        return tags
    }

    private func reference(for document: KnowledgeDocumentRecord, chunk: KnowledgeChunkRecord) -> String? {
        if let filePath = document.filePath, filePath.hasPrefix("notchly://") {
            return filePath
        }
        if let filePath = document.filePath {
            return URL(fileURLWithPath: filePath).absoluteString
        }
        return "notchly://source/\(chunk.sourceId.uuidString)/chunk/\(chunk.id.uuidString)"
    }

    func fileURL(for answerSource: AnswerSource) throws -> URL? {
        if let reference = answerSource.reference,
           let url = URL(string: reference),
           url.isFileURL {
            return url
        }

        if let chunkId = answerSource.chunkId,
           let chunk = try chunkRecords().first(where: { $0.id == chunkId }),
           let document = try documentRecords().first(where: { $0.id == chunk.documentId }),
           let url = fileURL(for: document) {
            return url
        }

        if let documentId = answerSource.documentId,
           let document = try documentRecords().first(where: { $0.id == documentId }),
           let url = fileURL(for: document) {
            return url
        }

        if let sourceId = answerSource.sourceId,
           let source = try sources().first(where: { $0.id == sourceId }),
           let rootPath = source.rootPath {
            return URL(fileURLWithPath: rootPath, isDirectory: true)
        }

        return nil
    }

    private func fileURL(for document: KnowledgeDocumentRecord) -> URL? {
        guard let filePath = document.filePath,
              !filePath.hasPrefix("notchly://") else {
            return nil
        }
        return URL(fileURLWithPath: filePath)
    }

    private func makeSnippet(content: String, terms: Set<String>) -> String {
        let sentences = content.split(whereSeparator: { ".!?\n".contains($0) }).map(String.init)
        let selected = sentences.first { sentence in
            let lowered = sentence.lowercased()
            return terms.contains { lowered.contains($0) }
        }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? String(content.prefix(360))
        return selected.count > 420 ? String(selected.prefix(420)) : selected
    }

    private func makeContextSnippet(
        for chunk: KnowledgeChunkRecord,
        document: KnowledgeDocumentRecord,
        source: KnowledgeSource,
        siblings: [KnowledgeChunkRecord]
    ) -> String {
        let semanticProfile = Self.semanticProfile(for: document, source: source)
        var lines: [String] = [
            "Source: \(source.kind.displayName)",
            "Content role: \(semanticProfile.role)",
            "Retrieval focus: \(semanticProfile.retrievalFocus)",
            "Document: \(document.displayName)",
            "Document kind: \(document.metadata["kind"] ?? document.kind.rawValue)"
        ]
        if let tags = document.metadata["tags"], !tags.isEmpty {
            lines.append("Tags: \(tags)")
        }
        if let meetingType = document.metadata["meetingType"], !meetingType.isEmpty {
            lines.append("Meeting type: \(meetingType)")
        }
        if let speakers = document.metadata["speakers"], !speakers.isEmpty {
            lines.append("Speakers: \(speakers)")
        }
        if let audioSources = document.metadata["audioSources"], !audioSources.isEmpty {
            lines.append("Audio sources: \(audioSources)")
        }
        if let language = document.metadata["language"], !language.isEmpty {
            lines.append("Language: \(language)")
        }
        if let wikilinks = Self.metadataSummary(document.metadata["wikilinks"]) {
            lines.append("Wikilinks: \(wikilinks)")
        }
        if let backlinks = Self.metadataSummary(document.metadata["backlinks"]) {
            lines.append("Backlinks: \(backlinks)")
        }
        if let attachments = Self.metadataSummary(document.metadata["attachments"]) {
            lines.append("Attachments: \(attachments)")
        }
        if let heading = chunk.heading, !heading.isEmpty {
            lines.append("Heading: \(heading)")
        }
        if let locationLabel = chunk.locationLabel, !locationLabel.isEmpty {
            lines.append("Location: \(locationLabel)")
        }

        let orderedSiblings = siblings.sorted { $0.sequence < $1.sequence }
        let localWindow = orderedSiblings.filter { abs($0.sequence - chunk.sequence) <= 1 }
        for sibling in localWindow {
            let label: String
            if sibling.id == chunk.id {
                label = "Matched chunk"
            } else if sibling.sequence < chunk.sequence {
                label = "Previous context"
            } else {
                label = "Next context"
            }
            let limit = sibling.id == chunk.id ? 900 : 420
            lines.append("\(label): \(Self.singleLine(String(sibling.content.prefix(limit))))")
        }
        return Self.clipped(lines.joined(separator: "\n"), limit: 1_800)
    }

    private static func semanticProfile(
        for document: KnowledgeDocumentRecord?,
        source: KnowledgeSource?
    ) -> ContentSemanticProfile {
        let documentKind = effectiveDocumentKind(document)
        switch source?.kind {
        case .meeting:
            switch documentKind {
            case .summary:
                return ContentSemanticProfile(
                    role: "Meeting summary",
                    retrievalFocus: "decisions, action items, owners, risks, open questions, insights"
                )
            case .transcript:
                return ContentSemanticProfile(
                    role: "Meeting transcript",
                    retrievalFocus: "spoken questions, speaker statements, timestamps, decisions in conversation"
                )
            default:
                return ContentSemanticProfile(
                    role: "Meeting knowledge",
                    retrievalFocus: "meeting context, participants, decisions, action items, follow-ups"
                )
            }
        case .obsidian:
            return ContentSemanticProfile(
                role: "Obsidian note",
                retrievalFocus: "note headings, tags, wikilinks, backlinks, attachments"
            )
        case .directory:
            return fileSemanticProfile(sourceLabel: "Directory", documentKind: documentKind)
        case .file:
            return fileSemanticProfile(sourceLabel: "File", documentKind: documentKind)
        case .legacy:
            return ContentSemanticProfile(
                role: "Imported legacy knowledge",
                retrievalFocus: "saved facts, exact terms, user-provided notes, prior knowledge"
            )
        case nil:
            return fileSemanticProfile(sourceLabel: "Knowledge", documentKind: documentKind)
        }
    }

    private static func effectiveDocumentKind(_ document: KnowledgeDocumentRecord?) -> KnowledgeDocumentKind {
        if let rawKind = document?.metadata["kind"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let metadataKind = KnowledgeDocumentKind(rawValue: rawKind) {
            return metadataKind
        }
        return document?.kind ?? .unknown
    }

    private static func fileSemanticProfile(
        sourceLabel: String,
        documentKind: KnowledgeDocumentKind
    ) -> ContentSemanticProfile {
        switch documentKind {
        case .markdown:
            return ContentSemanticProfile(
                role: "\(sourceLabel) markdown note",
                retrievalFocus: "headings, exact facts, specs, IDs, implementation details"
            )
        case .pdf:
            return ContentSemanticProfile(
                role: "\(sourceLabel) PDF document",
                retrievalFocus: "page-level facts, cited details, names, dates, specs"
            )
        case .text:
            return ContentSemanticProfile(
                role: "\(sourceLabel) text document",
                retrievalFocus: "exact facts, names, dates, IDs, implementation details"
            )
        case .transcript:
            return ContentSemanticProfile(
                role: "\(sourceLabel) transcript",
                retrievalFocus: "speaker statements, timestamps, decisions, action items"
            )
        case .summary:
            return ContentSemanticProfile(
                role: "\(sourceLabel) summary",
                retrievalFocus: "decisions, action items, owners, risks, open questions, insights"
            )
        case .unknown:
            return ContentSemanticProfile(
                role: "\(sourceLabel) document",
                retrievalFocus: "exact facts, source-specific terms, names, dates, IDs"
            )
        }
    }

    private static func singleLine(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func clipped(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit))
    }

    private func tokenized(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 1 }
    }

    private func recencyScore(for date: Date) -> Double {
        let days = max(0, Date().timeIntervalSince(date) / 86_400)
        return 1.0 / (1.0 + days / 30.0)
    }

    private func recentRetrievalTraceSignals(workspaceId: String, traceWindow: TimeInterval) throws -> [RetrievalTraceSignal] {
        let cutoff = Date().addingTimeInterval(-traceWindow)
        return try context.fetch(FetchDescriptor<StoredRetrievalTrace>())
            .filter { $0.workspaceId == workspaceId && $0.createdAt >= cutoff }
            .compactMap { trace in
                let resultJSON = try? cryptor.decryptString(trace.resultJSON, context: StoredRetrievalTrace.resultContext)
                let payload = Self.decodeRetrievalTracePayload(resultJSON ?? "[]", decoder: decoder)
                let summaries = payload.results
                let topScore = summaries
                    .compactMap { summary in summary.score.flatMap(Double.init) }
                    .max() ?? 0
                let topKeywordScore = summaries
                    .compactMap { summary in summary.keywordScore.flatMap(Double.init) }
                    .max() ?? 0
                let topSemanticScore = summaries
                    .compactMap { summary in summary.semanticScore.flatMap(Double.init) }
                    .max() ?? 0
                let structuredReferenceCount = summaries.filter {
                    Self.isNonEmptyReference($0.chunkId) &&
                        Self.isNonEmptyReference($0.documentId) &&
                        Self.isNonEmptyReference($0.sourceId)
                }.count
                let hybridEvidenceCount = summaries.filter {
                    ($0.keywordScore.flatMap(Double.init) ?? 0) > 0.18 &&
                        ($0.semanticScore.flatMap(Double.init) ?? 0) > 0.12 &&
                        Self.isNonEmptyReference($0.chunkId)
                }.count
                return RetrievalTraceSignal(
                    latencyMs: trace.latencyMs,
                    resultCount: summaries.count,
                    topScore: topScore,
                    topKeywordScore: topKeywordScore,
                    topSemanticScore: topSemanticScore,
                    structuredReferenceCount: structuredReferenceCount,
                    hybridEvidenceCount: hybridEvidenceCount,
                    stageLatencies: payload.stages
                )
            }
    }

    private static func isNonEmptyReference(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func decodeRetrievalTracePayload(
        _ json: String,
        decoder: JSONDecoder
    ) -> RetrievalTracePayload {
        guard let data = json.data(using: .utf8) else {
            return RetrievalTracePayload(stages: nil, results: [])
        }
        if let payload = try? decoder.decode(RetrievalTracePayload.self, from: data) {
            return payload
        }
        if let legacySummaries = try? decoder.decode([RetrievalTraceResultSummary].self, from: data) {
            return RetrievalTracePayload(stages: nil, results: legacySummaries)
        }
        return RetrievalTracePayload(stages: nil, results: [])
    }

    private static func percentile(_ values: [Int], percentile: Double) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let clamped = min(max(percentile, 0), 1)
        let offset = min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * clamped)) - 1))
        return sorted[offset]
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func encodedJSONString<T: Encodable>(_ value: T, encoder: JSONEncoder, fallback: String) -> String {
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return fallback
        }
        return string
    }

    private func storedDocuments() throws -> [StoredKnowledgeDocument] {
        try context.fetch(FetchDescriptor<StoredKnowledgeDocument>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
    }

    private func storedSources() throws -> [StoredKnowledgeSource] {
        try context.fetch(FetchDescriptor<StoredKnowledgeSource>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))
    }

    private func storedDocumentRecords() throws -> [StoredKnowledgeDocumentRecord] {
        try context.fetch(FetchDescriptor<StoredKnowledgeDocumentRecord>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))
    }

    private func storedChunks() throws -> [StoredKnowledgeChunk] {
        try context.fetch(FetchDescriptor<StoredKnowledgeChunk>(sortBy: [SortDescriptor(\.sequence)]))
    }

    private func storedEmbeddings() throws -> [StoredKnowledgeEmbeddingRecord] {
        try context.fetch(FetchDescriptor<StoredKnowledgeEmbeddingRecord>())
    }

    private func documentRecords() throws -> [KnowledgeDocumentRecord] {
        try storedDocumentRecords().map { try $0.decrypt(cryptor: cryptor) }
    }

    private func chunkRecords() throws -> [KnowledgeChunkRecord] {
        try storedChunks().map { try $0.decrypt(cryptor: cryptor) }
    }

    private func cachedEmbeddingVectors(
        model: String?,
        workspaceId: String?,
        chunks: [KnowledgeChunkRecord],
        documentsById: [UUID: KnowledgeDocumentRecord],
        sourcesById: [UUID: KnowledgeSource]
    ) throws -> [UUID: [Double]] {
        let chunkIds = Set(chunks.map(\.id))
        let expectedHashesByChunkId = Dictionary(uniqueKeysWithValues: chunks.map { chunk in
            (
                chunk.id,
                embeddingContentHash(
                    for: chunk,
                    document: documentsById[chunk.documentId],
                    source: sourcesById[chunk.sourceId]
                )
            )
        })
        let records = try storedEmbeddings()
            .filter { model == nil || $0.model == model }
            .filter { chunkIds.contains($0.chunkId) }
            .filter { stored in
                expectedHashesByChunkId[stored.chunkId] == stored.contentHash
            }
        let scopeFingerprint = vectorScopeFingerprint(model: model, workspaceId: workspaceId, records: records)
        let cacheKey = "\(workspaceId ?? "__all__")|\(model ?? "__all__")|\(scopeFingerprint)"
        if let cached = embeddingVectorCache[cacheKey],
           cached.recordCount == records.count,
           cached.scopeFingerprint == scopeFingerprint {
            return cached.vectorsByChunkId
        }

        if let shard = try? readVectorShard(model: model, workspaceId: workspaceId, records: records, fingerprint: scopeFingerprint),
           shard.count == records.count {
            embeddingVectorCache[cacheKey] = EmbeddingVectorCacheEntry(
                recordCount: records.count,
                scopeFingerprint: scopeFingerprint,
                vectorsByChunkId: shard
            )
            return shard
        }

        let vectors = try records.reduce(into: [UUID: [Double]]()) { partial, stored in
            if let storageKey = try stored.sidecarKey(cryptor: cryptor),
               let vector = try? vectorBlobStore?.readVector(storageKey: storageKey, dimensions: stored.dimensions, cryptor: cryptor),
               !vector.isEmpty {
                partial[stored.chunkId] = vector
                return
            }
            let embedding = try stored.decrypt(cryptor: cryptor)
            guard !embedding.vector.isEmpty else { return }
            partial[embedding.chunkId] = embedding.vector
        }
        try writeVectorShardIfPossible(
            model: model,
            workspaceId: workspaceId,
            records: records,
            vectorsByChunkId: vectors,
            fingerprint: scopeFingerprint
        )
        embeddingVectorCache[cacheKey] = EmbeddingVectorCacheEntry(
            recordCount: records.count,
            scopeFingerprint: scopeFingerprint,
            vectorsByChunkId: vectors
        )
        return vectors
    }

    private func rebuildVectorShard(model: String, workspaceId: String) throws {
        let sourcesById = Dictionary(uniqueKeysWithValues: try sources(workspaceId: workspaceId).map { ($0.id, $0) })
        let documentsById = Dictionary(uniqueKeysWithValues: try documentRecords().filter { $0.workspaceId == workspaceId }.map { ($0.id, $0) })
        let chunks = try chunkRecords().filter {
            $0.workspaceId == workspaceId &&
                sourcesById[$0.sourceId]?.isEnabled == true
        }
        guard !chunks.isEmpty else { return }
        _ = try cachedEmbeddingVectors(
            model: model,
            workspaceId: workspaceId,
            chunks: chunks,
            documentsById: documentsById,
            sourcesById: sourcesById
        )
    }

    private func readVectorShard(
        model: String?,
        workspaceId: String?,
        records: [StoredKnowledgeEmbeddingRecord],
        fingerprint: String
    ) throws -> [UUID: [Double]]? {
        guard let vectorBlobStore, let model, let workspaceId, !records.isEmpty else { return nil }
        let storageKey = vectorBlobStore.shardStorageKey(model: model, workspaceId: workspaceId, fingerprint: fingerprint)
        let vectors = try vectorBlobStore.readShard(storageKey: storageKey, cryptor: cryptor)
        let expectedChunkIds = Set(records.map(\.chunkId))
        guard Set(vectors.keys) == expectedChunkIds else { return nil }
        return vectors
    }

    private func writeVectorShardIfPossible(
        model: String?,
        workspaceId: String?,
        records: [StoredKnowledgeEmbeddingRecord],
        vectorsByChunkId: [UUID: [Double]],
        fingerprint: String
    ) throws {
        guard let vectorBlobStore,
              let model,
              let workspaceId,
              !records.isEmpty,
              vectorsByChunkId.count == records.count else { return }
        let ordered = records
            .sorted { $0.chunkId.uuidString < $1.chunkId.uuidString }
            .compactMap { record -> (chunkId: UUID, vector: [Double])? in
                guard let vector = vectorsByChunkId[record.chunkId], !vector.isEmpty else { return nil }
                return (record.chunkId, vector)
            }
        guard ordered.count == records.count else { return }
        let storageKey = vectorBlobStore.shardStorageKey(model: model, workspaceId: workspaceId, fingerprint: fingerprint)
        try vectorBlobStore.writeShard(ordered, storageKey: storageKey, cryptor: cryptor)
    }

    private func deleteVectorBlob(for stored: StoredKnowledgeEmbeddingRecord) {
        guard let storageKey = try? stored.sidecarKey(cryptor: cryptor) else { return }
        vectorBlobStore?.deleteVector(storageKey: storageKey)
    }

    private func cachedANNIndex(
        model: String?,
        chunks: [KnowledgeChunkRecord],
        candidates: [VectorSearchService.Candidate]
    ) -> LocalVectorANNIndex {
        let scopeFingerprint = annScopeFingerprint(model: model, chunks: chunks, candidateCount: candidates.count)
        if let cached = annIndexCache[scopeFingerprint], cached.scopeFingerprint == scopeFingerprint {
            return cached.index
        }
        let index = LocalVectorANNIndex(candidates: candidates)
        annIndexCache[scopeFingerprint] = ANNIndexCacheEntry(scopeFingerprint: scopeFingerprint, index: index)
        return index
    }

    private func cachedBM25Index(
        chunks: [KnowledgeChunkRecord],
        documentsById: [UUID: KnowledgeDocumentRecord],
        sourcesById: [UUID: KnowledgeSource]
    ) -> LocalBM25Index {
        let scopeFingerprint = bm25ScopeFingerprint(chunks: chunks, documentsById: documentsById, sourcesById: sourcesById)
        if let cached = bm25IndexCache[scopeFingerprint], cached.scopeFingerprint == scopeFingerprint {
            return cached.index
        }
        let index = LocalBM25Index(chunks: chunks, documentsById: documentsById, sourcesById: sourcesById)
        bm25IndexCache[scopeFingerprint] = BM25IndexCacheEntry(scopeFingerprint: scopeFingerprint, index: index)
        return index
    }

    private func annScopeFingerprint(model: String?, chunks: [KnowledgeChunkRecord], candidateCount: Int) -> String {
        var hash = UInt64(14_695_981_039_346_656_037)
        func mix(_ value: String) {
            for byte in value.utf8 {
                hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
            }
        }
        mix(model ?? "__all__")
        mix(String(candidateCount))
        for chunk in chunks.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            mix(chunk.id.uuidString)
            mix(chunk.contentHash)
        }
        return String(hash, radix: 16)
    }

    private func vectorScopeFingerprint(model: String?, workspaceId: String?, records: [StoredKnowledgeEmbeddingRecord]) -> String {
        var hash = UInt64(14_695_981_039_346_656_037)
        func mix(_ value: String) {
            for byte in value.utf8 {
                hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
            }
        }
        mix(model ?? "__all__")
        mix(workspaceId ?? "__all__")
        mix(String(records.count))
        for record in records.sorted(by: { $0.chunkId.uuidString < $1.chunkId.uuidString }) {
            mix(record.chunkId.uuidString)
            mix(record.contentHash)
            mix(String(record.dimensions))
            mix(record.quantization)
        }
        return String(hash, radix: 16)
    }

    private func bm25ScopeFingerprint(
        chunks: [KnowledgeChunkRecord],
        documentsById: [UUID: KnowledgeDocumentRecord],
        sourcesById: [UUID: KnowledgeSource]
    ) -> String {
        var hash = UInt64(14_695_981_039_346_656_037)
        func mix(_ value: String) {
            for byte in value.utf8 {
                hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
            }
        }
        mix(String(chunks.count))
        for chunk in chunks.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            mix(chunk.id.uuidString)
            mix(chunk.contentHash)
            if let document = documentsById[chunk.documentId] {
                mix(document.displayName)
                mix(document.kind.rawValue)
                mix(document.metadata["tags"] ?? "")
                mix(document.metadata["kind"] ?? "")
                mix(document.metadata["wikilinks"] ?? "")
                mix(document.metadata["backlinks"] ?? "")
                mix(document.metadata["attachments"] ?? "")
            }
            if let source = sourcesById[chunk.sourceId] {
                mix(source.kind.rawValue)
                mix(source.displayName)
            }
        }
        return String(hash, radix: 16)
    }

    private func storedEmbeddingKeys(model: String) throws -> Set<String> {
        Set(try storedEmbeddings()
            .filter { $0.model == model }
            .map { "\($0.chunkId.uuidString)|\($0.contentHash)" })
    }

    private func invalidateEmbeddingVectorCache() {
        embeddingVectorCache.removeAll()
        bm25IndexCache.removeAll()
        annIndexCache.removeAll()
    }
}
