import Foundation

@MainActor
struct KnowledgeRetrievalService {
    var store: LocalKnowledgeStore
    var embeddingProvider: any EmbeddingProvider
    var privacyGuard = PrivacyGuard()

    private enum QueryEmbeddingRaceResult: Sendable {
        case embedding([Double]?)
        case timeout
    }

    private final class QueryEmbeddingRaceCoordinator: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<QueryEmbeddingRaceResult, Never>?
        private var didResolve = false
        private var embeddingTask: Task<Void, Never>?
        private var timeoutTask: Task<Void, Never>?

        init(continuation: CheckedContinuation<QueryEmbeddingRaceResult, Never>) {
            self.continuation = continuation
        }

        func setTasks(embeddingTask: Task<Void, Never>, timeoutTask: Task<Void, Never>) {
            lock.lock()
            if didResolve {
                lock.unlock()
                embeddingTask.cancel()
                timeoutTask.cancel()
                return
            }
            self.embeddingTask = embeddingTask
            self.timeoutTask = timeoutTask
            lock.unlock()
        }

        func resolve(_ result: QueryEmbeddingRaceResult) {
            lock.lock()
            guard !didResolve, let continuation else {
                lock.unlock()
                return
            }
            didResolve = true
            self.continuation = nil
            let embeddingTask = self.embeddingTask
            let timeoutTask = self.timeoutTask
            lock.unlock()

            switch result {
            case .embedding:
                timeoutTask?.cancel()
            case .timeout:
                embeddingTask?.cancel()
            }
            continuation.resume(returning: result)
        }
    }

    init(store: LocalKnowledgeStore, embeddingProvider: (any EmbeddingProvider)? = nil) {
        self.store = store
        let candidate = embeddingProvider ?? LocalEmbeddingProvider()
        self.embeddingProvider = candidate.executionScope.isLocal ? candidate : LocalEmbeddingProvider()
    }

    func retrieve(
        query: String,
        preferences: AppPreferences,
        limit: Int? = nil,
        selectedSourceId: UUID? = nil,
        allowedKinds: Set<KnowledgeSourceKind> = Set(KnowledgeSourceKind.allCases)
    ) async -> KnowledgeRetrievalResult {
        let startedAt = Date()
        let workspaceId = preferences.workspaceId
        let resultLimit = limit ?? preferences.ragDefaultResultLimit
        let candidateLimit = max(resultLimit * 10, 80)
        let embeddingModel = embeddingProvider.modelIdentifier
        let options = KnowledgeRetrievalOptions(
            workspaceId: workspaceId,
            limit: candidateLimit,
            candidateLimit: candidateLimit,
            selectedSourceId: selectedSourceId,
            allowedKinds: allowedKinds,
            minScore: 0.015,
            contextCharacterBudget: 6_000
        )
        let shouldAttemptSemanticSearch = (try? store.hasSearchableEmbeddings(
            model: embeddingModel,
            options: options
        )) ?? true
        let queryEmbeddingStartedAt = Date()
        let queryEmbedding = shouldAttemptSemanticSearch
            ? await queryEmbeddingWithinRealtimeBudget(query, preferences: preferences)
            : nil
        let queryEmbeddingMs = shouldAttemptSemanticSearch ? Self.elapsedMs(since: queryEmbeddingStartedAt) : 0

        let hybridSearchStartedAt = Date()
        let localResults = (try? store.hybridSearch(
            query: query,
            options: options,
            queryEmbedding: queryEmbedding,
            embeddingModel: embeddingModel
        )) ?? []
        let hybridSearchMs = Self.elapsedMs(since: hybridSearchStartedAt)
        let rerankStartedAt = Date()
        let reranked = await rerankIfAllowed(localResults, query: query, preferences: preferences, limit: resultLimit)
        let rerankMs = Self.elapsedMs(since: rerankStartedAt)
        let finalResults = Array(reranked.prefix(resultLimit))
        let contextStartedAt = Date()
        let grounding = groundingLevel(for: finalResults, query: query)
        let context = assembleContext(from: finalResults, budget: options.contextCharacterBudget, grounding: grounding.level)
        let contextAssemblyMs = Self.elapsedMs(since: contextStartedAt)
        let latency = Int(Date().timeIntervalSince(startedAt) * 1_000)
        let stageLatencies = KnowledgeRetrievalStageLatencies(
            queryEmbeddingMs: queryEmbeddingMs,
            hybridSearchMs: hybridSearchMs,
            rerankMs: rerankMs,
            contextAssemblyMs: contextAssemblyMs
        )
        store.recordRetrievalTrace(
            query: query,
            workspaceId: workspaceId,
            results: finalResults,
            latencyMs: latency,
            stageLatencies: stageLatencies
        )
        return KnowledgeRetrievalResult(
            query: query,
            results: finalResults,
            context: context,
            latencyMs: latency,
            stageLatencies: stageLatencies,
            grounding: grounding.level,
            evidenceScore: grounding.score
        )
    }

    private func queryEmbeddingWithinRealtimeBudget(_ query: String, preferences: AppPreferences) async -> [Double]? {
        let budgetMs = queryEmbeddingBudgetMs(preferences: preferences)
        let result = await withCheckedContinuation { continuation in
            let coordinator = QueryEmbeddingRaceCoordinator(continuation: continuation)
            let embeddingTask = Task { @MainActor [embeddingProvider] in
                coordinator.resolve(.embedding(try? await embeddingProvider.embed(query)))
            }
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(budgetMs) * 1_000_000)
                coordinator.resolve(.timeout)
            }
            coordinator.setTasks(embeddingTask: embeddingTask, timeoutTask: timeoutTask)
        }

        switch result {
        case .embedding(let vector):
            guard let vector, !vector.isEmpty else { return nil }
            return vector
        case .timeout:
            return nil
        }
    }

    private func queryEmbeddingBudgetMs(preferences: AppPreferences) -> Int {
        let target = min(max(preferences.ragRealtimeLatencyTargetMs, 120), 500)
        return min(max(target / 3, 40), 120)
    }

    private static func elapsedMs(since startedAt: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
    }

    private func rerankIfAllowed(
        _ results: [KnowledgeSearchResult],
        query: String,
        preferences: AppPreferences,
        limit: Int
    ) async -> [KnowledgeSearchResult] {
        guard preferences.ragLocalRerankEnabled, results.count > 2 else {
            return deterministicRerank(results, query: query, limit: limit)
        }
        return deterministicRerank(results, query: query, limit: limit)
    }

    private func deterministicRerank(_ results: [KnowledgeSearchResult], query: String, limit: Int) -> [KnowledgeSearchResult] {
        let queryTokens = meaningfulTokenList(in: query)
        let queryTerms = Set(queryTokens)
        var seenChunks = Set<UUID>()
        var seenFingerprints = Set<String>()
        let scored = results.map { result -> KnowledgeSearchResult in
            var adjusted = result
            let coverage = queryCoverage(queryTerms, in: result.snippet + " " + result.documentName)
            let phraseBoost = phraseMatchBoost(queryTokens, in: result.snippet)
            let hasLexicalSupport = result.keywordScore > 0 || coverage >= 0.25
            let semanticBoostWeight = hasLexicalSupport ? 0.12 : 0.035
            let hybridBoost = result.keywordScore > 0 && result.semanticScore > 0 ? 0.06 : 0
            let meetingBoost = result.sourceKind == .meeting ? 0.02 + recentMeetingBoost(for: result) : 0
            adjusted.score = result.score
                + min(max(result.semanticScore, 0), 1) * semanticBoostWeight
                + min(max(result.keywordScore, 0), 4) * 0.035
                + coverage * 0.12
                + phraseBoost
                + result.recencyScore * 0.025
                + hybridBoost
                + meetingBoost
            return adjusted
        }
        let unique = scored
            .sorted { $0.score > $1.score }
            .filter { result in
                if let chunkId = result.chunkId, !seenChunks.insert(chunkId).inserted {
                    return false
                }
                let key = dedupeFingerprint(for: result)
                return seenFingerprints.insert(key).inserted
            }
        return diversified(unique, queryTerms: queryTerms, limit: limit)
    }

    private func diversified(_ results: [KnowledgeSearchResult], queryTerms: Set<String>, limit: Int) -> [KnowledgeSearchResult] {
        var selected: [KnowledgeSearchResult] = []
        var candidates = results
        while !candidates.isEmpty, selected.count < limit {
            let nextIndex = candidates.indices.max { lhs, rhs in
                mmrScore(candidates[lhs], selected: selected, queryTerms: queryTerms) < mmrScore(candidates[rhs], selected: selected, queryTerms: queryTerms)
            }
            guard let nextIndex else { break }
            selected.append(candidates.remove(at: nextIndex))
        }
        return selected
    }

    private func mmrScore(_ result: KnowledgeSearchResult, selected: [KnowledgeSearchResult], queryTerms: Set<String>) -> Double {
        guard !selected.isEmpty else { return result.score }
        let maxOverlap = selected
            .map { lexicalOverlap(result.snippet, $0.snippet) }
            .max() ?? 0
        let sameDocumentPenalty = selected.contains { $0.documentId == result.documentId && result.documentId != nil } ? 0.015 : 0
        let sameSourcePenalty = selected.contains { $0.sourceId == result.sourceId && result.sourceId != nil } ? 0.006 : 0
        let queryCoverage = queryCoverage(queryTerms, in: result.snippet)
        return result.score + queryCoverage * 0.02 - maxOverlap * 0.06 - sameDocumentPenalty - sameSourcePenalty
    }

    private func lexicalOverlap(_ lhs: String, _ rhs: String) -> Double {
        let left = meaningfulTerms(in: lhs)
        let right = meaningfulTerms(in: rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let intersection = left.intersection(right).count
        let union = left.union(right).count
        return Double(intersection) / Double(max(union, 1))
    }

    private func queryCoverage(_ terms: Set<String>, in text: String) -> Double {
        guard !terms.isEmpty else { return 0 }
        let haystack = meaningfulTerms(in: text)
        guard !haystack.isEmpty else { return 0 }
        return Double(terms.intersection(haystack).count) / Double(terms.count)
    }

    private func phraseMatchBoost(_ queryTerms: [String], in text: String) -> Double {
        guard queryTerms.count >= 2 else { return 0 }
        let lowered = text.lowercased()
        var matches = 0
        for index in 0..<(queryTerms.count - 1) {
            if lowered.contains("\(queryTerms[index]) \(queryTerms[index + 1])") {
                matches += 1
            }
        }
        return min(Double(matches) * 0.035, 0.105)
    }

    private func meaningfulTerms(in text: String) -> Set<String> {
        Set(meaningfulTokenList(in: text))
    }

    private func meaningfulTokenList(in text: String) -> [String] {
        let stopWords: Set<String> = [
            "a", "an", "and", "are", "as", "at", "be", "by", "com", "da", "de", "do", "e",
            "for", "from", "in", "is", "it", "na", "no", "o", "of", "on", "or", "os", "para",
            "que", "the", "to", "um", "uma", "with"
        ]
        return text.lowercased().split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 2 && !stopWords.contains($0) }
    }

    private func dedupeFingerprint(for result: KnowledgeSearchResult) -> String {
        let prefix = meaningfulTerms(in: String(result.snippet.prefix(240))).sorted().prefix(24).joined(separator: "|")
        return "\(result.documentId?.uuidString ?? result.documentName)|\(prefix)"
    }

    private struct GroundingEvidence {
        var score: Double
        var meetsStrongThreshold: Bool
        var meetsModerateThreshold: Bool
        var hasStructuredReference: Bool

        static let empty = GroundingEvidence(
            score: 0,
            meetsStrongThreshold: false,
            meetsModerateThreshold: false,
            hasStructuredReference: false
        )
    }

    private func groundingEvidence(for result: KnowledgeSearchResult, queryTerms: Set<String>) -> GroundingEvidence {
        let thresholds = sourceEvidenceThresholds(for: result.sourceKind)
        let normalizedKeyword = min(max(result.keywordScore / 3.0, 0), 1)
        let normalizedSemantic = min(max(result.semanticScore, 0), 1)
        let coverage = queryCoverage(queryTerms, in: result.snippet + " " + result.documentName)
        let hasHybridEvidence = normalizedSemantic >= 0.12 && normalizedKeyword >= 0.18
        let hasStructuredReference = result.sourceId != nil && result.documentId != nil && result.chunkId != nil
        let meetingRecencyBoost = recentMeetingBoost(for: result)
        let citationPenalty = hasStructuredReference ? 0.0 : 0.10
        let score = min(
            1.0,
            max(
                0,
                normalizedSemantic * 0.56 +
                    normalizedKeyword * 0.30 +
                    coverage * 0.06 +
                    (hasHybridEvidence ? 0.08 : 0) +
                    meetingRecencyBoost -
                    citationPenalty
            )
        )
        let meetsStrong = normalizedSemantic >= thresholds.strongSemantic ||
            normalizedKeyword >= thresholds.strongKeyword ||
            (hasHybridEvidence && score >= thresholds.strongScore)
        let meetsModerate = normalizedSemantic >= thresholds.moderateSemantic ||
            normalizedKeyword >= thresholds.moderateKeyword ||
            score >= thresholds.moderateScore ||
            (
                result.sourceKind == .meeting &&
                    meetingRecencyBoost > 0 &&
                    coverage >= thresholds.coverage &&
                    (normalizedKeyword > 0.12 || normalizedSemantic > 0.08)
            )
        return GroundingEvidence(
            score: score,
            meetsStrongThreshold: meetsStrong,
            meetsModerateThreshold: meetsModerate,
            hasStructuredReference: hasStructuredReference
        )
    }

    private func sourceEvidenceThresholds(
        for kind: KnowledgeSourceKind
    ) -> (
        strongSemantic: Double,
        strongKeyword: Double,
        moderateSemantic: Double,
        moderateKeyword: Double,
        strongScore: Double,
        moderateScore: Double,
        coverage: Double
    ) {
        switch kind {
        case .meeting:
            return (0.50, 0.66, 0.20, 0.22, 0.58, 0.34, 0.30)
        case .obsidian:
            return (0.58, 0.76, 0.25, 0.30, 0.64, 0.42, 0.34)
        case .file, .directory:
            return (0.56, 0.75, 0.25, 0.28, 0.62, 0.40, 0.34)
        case .legacy:
            return (0.68, 0.86, 0.34, 0.40, 0.72, 0.50, 0.42)
        }
    }

    private func recentMeetingBoost(for result: KnowledgeSearchResult) -> Double {
        guard result.sourceKind == .meeting else { return 0 }
        return result.recencyScore >= 0.66 ? 0.06 : 0
    }

    private func groundingLevel(for results: [KnowledgeSearchResult], query: String) -> (level: KnowledgeRetrievalGrounding, score: Double) {
        guard let top = results.first else { return (.none, 0) }
        let queryTerms = Set(meaningfulTokenList(in: query))
        let bestEvidence = results
            .map { groundingEvidence(for: $0, queryTerms: queryTerms) }
            .max { lhs, rhs in lhs.score < rhs.score } ?? .empty
        if bestEvidence.hasStructuredReference,
           bestEvidence.meetsStrongThreshold {
            return (.strong, bestEvidence.score)
        }
        if bestEvidence.hasStructuredReference,
           bestEvidence.meetsModerateThreshold {
            return (.moderate, bestEvidence.score)
        }
        if bestEvidence.score > 0 || top.score > 0 {
            return (.weak, bestEvidence.score)
        }
        return (.none, 0)
    }

    private func assembleContext(from results: [KnowledgeSearchResult], budget: Int, grounding: KnowledgeRetrievalGrounding) -> String {
        var remaining = budget
        var lines: [String] = []
        if let notice = grounding.contextNotice {
            lines.append(notice)
            remaining -= notice.count
        }
        for result in results {
            guard remaining > 120 else { break }
            let location = result.locationLabel.map { " - \($0)" } ?? ""
            let evidence = result.contextSnippet ?? result.snippet
            let line = "[\(result.documentName)\(location)] \(evidence)"
            let clipped = line.count > remaining ? String(line.prefix(remaining)) : line
            lines.append(clipped)
            remaining -= clipped.count
        }
        return lines.joined(separator: "\n")
    }

}

@MainActor
struct LocalRAGEvaluator {
    func evaluate(
        cases: [LocalRAGEvaluationCase],
        store: LocalKnowledgeStore,
        provider: any EmbeddingProvider,
        workspaceId: String,
        k: Int
    ) async -> LocalRAGEvaluationReport {
        guard !cases.isEmpty else {
            return LocalRAGEvaluationReport(
                caseCount: 0,
                recallAtK: 0,
                precisionAtK: 0,
                hardNegativeLeakRate: 0,
                groundednessRate: 0,
                p95LatencyMs: nil,
                failedCaseIds: []
            )
        }

        var preferences = AppPreferences()
        preferences.workspaceId = workspaceId
        preferences.ragDefaultResultLimit = k

        var hitCount = 0
        var precisionTotal = 0.0
        var hardNegativeLeaks = 0
        var groundedCount = 0
        var latencies: [Int] = []
        var failedCaseIds: [String] = []

        for evaluationCase in cases {
            let retrieval = await KnowledgeRetrievalService(store: store, embeddingProvider: provider)
                .retrieve(query: evaluationCase.query, preferences: preferences, limit: k)
            let documentNames = retrieval.results.map(\.documentName)
            let expectedHits = documentNames.filter { evaluationCase.expectedDocuments.contains($0) }.count
            let leakedHardNegatives = documentNames.contains { evaluationCase.forbiddenDocuments.contains($0) }
            let grounded = retrieval.grounding.satisfies(evaluationCase.minimumGrounding)

            if expectedHits > 0 {
                hitCount += 1
            }
            precisionTotal += Double(expectedHits) / Double(max(documentNames.count, 1))
            if leakedHardNegatives {
                hardNegativeLeaks += 1
            }
            if grounded {
                groundedCount += 1
            }
            latencies.append(retrieval.latencyMs)

            if expectedHits == 0 || leakedHardNegatives || !grounded {
                failedCaseIds.append(evaluationCase.id)
            }
        }

        return LocalRAGEvaluationReport(
            caseCount: cases.count,
            recallAtK: Double(hitCount) / Double(cases.count),
            precisionAtK: precisionTotal / Double(cases.count),
            hardNegativeLeakRate: Double(hardNegativeLeaks) / Double(cases.count),
            groundednessRate: Double(groundedCount) / Double(cases.count),
            p95LatencyMs: Self.percentile(latencies, percentile: 0.95),
            failedCaseIds: failedCaseIds
        )
    }

    private static func percentile(_ values: [Int], percentile: Double) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let clamped = min(max(percentile, 0), 1)
        let offset = min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * clamped)) - 1))
        return sorted[offset]
    }
}

private extension KnowledgeRetrievalGrounding {
    var rank: Int {
        switch self {
        case .none: 0
        case .weak: 1
        case .moderate: 2
        case .strong: 3
        }
    }

    func satisfies(_ minimum: KnowledgeRetrievalGrounding) -> Bool {
        rank >= minimum.rank
    }
}

extension KnowledgeSearchResult {
    func answerSource(redacting privacyGuard: PrivacyGuard = PrivacyGuard()) -> AnswerSource {
        AnswerSource(
            type: .rag,
            title: locationLabel.map { "\(documentName) - \($0)" } ?? documentName,
            snippet: privacyGuard.redact(snippet),
            reference: reference,
            sourceId: sourceId,
            documentId: documentId,
            chunkId: chunkId,
            locationLabel: locationLabel,
            score: score
        )
    }
}
