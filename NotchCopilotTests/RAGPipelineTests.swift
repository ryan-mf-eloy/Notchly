import Foundation
import SwiftData
import XCTest
@testable import NotchCopilot

@MainActor
final class RAGPipelineTests: XCTestCase {
    private func testCryptor(byte: UInt8 = 0x64) throws -> LocalDataCryptor {
        try LocalDataCryptor.ephemeralForTests(byte: byte)
    }

    func testStructuredMarkdownChunkingPreservesHeadings() {
        let text = """
        # Roadmap
        Ship the desktop capture flow.

        ## Risks
        Confirm rollback before the customer launch.
        """
        let chunks = DocumentIngestionService().structuredChunks(from: text, kind: .markdown, targetTokens: 20, overlapTokens: 4)
        XCTAssertTrue(chunks.contains { $0.heading == "Roadmap" })
        XCTAssertTrue(chunks.contains { $0.heading == "Risks" })
        XCTAssertTrue(chunks.contains { ($0.locationLabel ?? "").contains("lines") })
    }

    func testPDFChunkingPreservesPageLabels() {
        let text = """
        %%NOTCHLY_PDF_PAGE 1
        First page contains onboarding notes.

        %%NOTCHLY_PDF_PAGE 2
        Second page contains renewal pricing.
        """
        let chunks = DocumentIngestionService().structuredChunks(from: text, kind: .pdf, targetTokens: 80, overlapTokens: 0)

        XCTAssertEqual(chunks.map(\.locationLabel), ["page 1", "page 2"])
        XCTAssertTrue(chunks.first?.content.contains("First page") == true)
        XCTAssertTrue(chunks.last?.content.contains("Second page") == true)
    }

    func testConfiguredChunkSizeIsUsedDuringIngestion() throws {
        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let store = LocalKnowledgeStore(container: container, workspaceId: "alpha", cryptor: try testCryptor())
        var preferences = AppPreferences()
        preferences.ragChunkTargetTokens = 300
        preferences.ragChunkOverlapTokens = 0
        store.configure(preferences: preferences)

        let longText = String(repeating: "Alpha roadmap renewal risk needs owner. ", count: 180)
        try store.addDocument(name: "Long.md", content: longText, workspaceId: "alpha")

        let source = try XCTUnwrap(store.sourceConnectionViewModels(workspaceId: "alpha").first)
        XCTAssertGreaterThan(source.chunkCount, 1)
    }

    func testObsidianSourceSkipsDotObsidianAndIndexesMarkdown() throws {
        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let store = LocalKnowledgeStore(container: container, workspaceId: "alpha", cryptor: try testCryptor())
        let root = FileManager.default.temporaryDirectory.appending(path: "notchly-rag-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: ".obsidian", directoryHint: .isDirectory), withIntermediateDirectories: true)
        try "Should never be indexed".write(to: root.appending(path: ".obsidian/config.md"), atomically: true, encoding: .utf8)
        try "# Launch\n[[Project Alpha|Project]] needs a rollback owner.".write(to: root.appending(path: "Launch.md"), atomically: true, encoding: .utf8)

        _ = try store.connectDirectory(root, kind: .obsidian, workspaceId: "alpha")
        let results = try store.keywordSearch(query: "rollback owner", workspaceId: "alpha")

        XCTAssertEqual(results.first?.documentName, "Launch.md")
        XCTAssertFalse(results.contains { $0.snippet.contains("Should never be indexed") })
        XCTAssertEqual(try store.sources(workspaceId: "alpha").first?.kind, .obsidian)
    }

    func testObsidianWikilinksAttachmentsAndBacklinksBecomeRetrievableMetadata() throws {
        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let store = LocalKnowledgeStore(container: container, workspaceId: "alpha", cryptor: try testCryptor())
        let root = try temporaryDirectory(named: "notchly-rag-obsidian-graph")
        try """
        ---
        tags: [customer, renewal]
        ---
        # Atlas
        Customer profile for the enterprise renewal.
        """.write(to: root.appending(path: "Atlas.md"), atomically: true, encoding: .utf8)
        try """
        # Launch
        Rollback window is Friday. Depends on [[Atlas]] and [[Risk Ledger|risk plan]].
        ![[Architecture.png]]
        """.write(to: root.appending(path: "Launch.md"), atomically: true, encoding: .utf8)
        try """
        # Decision
        [[Atlas]] is the customer escalation anchor for the renewal.
        """.write(to: root.appending(path: "Decision.md"), atomically: true, encoding: .utf8)

        _ = try store.connectDirectory(root, kind: .obsidian, workspaceId: "alpha")
        let backlinkResults = try store.hybridSearch(
            query: "Atlas backlinks Launch Decision",
            options: KnowledgeRetrievalOptions(workspaceId: "alpha", limit: 5, candidateLimit: 20)
        )
        let launchResults = try store.hybridSearch(
            query: "wikilinks risk plan attachments Architecture",
            options: KnowledgeRetrievalOptions(workspaceId: "alpha", limit: 5, candidateLimit: 20)
        )

        XCTAssertEqual(backlinkResults.first?.documentName, "Atlas.md")
        XCTAssertTrue(backlinkResults.first?.contextSnippet?.contains("Backlinks: Decision, Launch") == true)
        XCTAssertTrue(backlinkResults.first?.contextSnippet?.contains("#customer") == true)
        XCTAssertEqual(launchResults.first?.documentName, "Launch.md")
        XCTAssertTrue(launchResults.first?.contextSnippet?.contains("Wikilinks: Atlas, Risk Ledger") == true)
        XCTAssertTrue(launchResults.first?.contextSnippet?.contains("Attachments: Architecture.png") == true)
    }

    func testHybridRetrievalDoesNotMixWorkspaces() throws {
        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let store = LocalKnowledgeStore(container: container, workspaceId: "alpha", cryptor: try testCryptor())
        try store.addDocument(name: "Alpha.md", content: "authentication rollback risk alpha", workspaceId: "alpha")
        try store.addDocument(name: "Beta.md", content: "authentication rollback risk beta", workspaceId: "beta")

        let result = try store.hybridSearch(
            query: "authentication rollback",
            options: KnowledgeRetrievalOptions(workspaceId: "alpha", limit: 5)
        )

        XCTAssertEqual(result.map(\.workspaceId), ["alpha"])
        XCTAssertTrue(result.contains { $0.documentName == "Alpha.md" })
        XCTAssertFalse(result.contains { $0.documentName == "Beta.md" })
    }

    func testSelectedSourceFilterDoesNotLeakOtherSources() throws {
        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let store = LocalKnowledgeStore(container: container, workspaceId: "alpha", cryptor: try testCryptor())
        let first = try temporaryDirectory(named: "notchly-rag-first")
        let second = try temporaryDirectory(named: "notchly-rag-second")
        try "Project Saturn renewal risk".write(to: first.appending(path: "Saturn.md"), atomically: true, encoding: .utf8)
        try "Project Atlas renewal risk".write(to: second.appending(path: "Atlas.md"), atomically: true, encoding: .utf8)

        let firstSource = try store.connectDirectory(first, kind: .directory, workspaceId: "alpha")
        _ = try store.connectDirectory(second, kind: .directory, workspaceId: "alpha")

        let results = try store.hybridSearch(
            query: "renewal risk",
            options: KnowledgeRetrievalOptions(workspaceId: "alpha", limit: 5, selectedSourceId: firstSource.id)
        )

        XCTAssertTrue(results.contains { $0.documentName == "Saturn.md" })
        XCTAssertFalse(results.contains { $0.documentName == "Atlas.md" })
    }

    func testCachedBM25FindsExactAcronymAndIdAcrossLargeLocalCorpus() throws {
        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let store = LocalKnowledgeStore(container: container, workspaceId: "alpha", cryptor: try testCryptor())
        let root = try temporaryDirectory(named: "notchly-rag-bm25")

        for index in 0..<420 {
            let text = """
            # Status \(index)
            Customer notes mention onboarding, integrations, renewal timing, dashboard metrics and generic incident follow-up.
            Ref \(index): ticket LC-\(1000 + index) remains informational and has no named executive owner.
            """
            try text.write(to: root.appending(path: "Noise-\(index).md"), atomically: true, encoding: .utf8)
        }
        try """
        # Escalation
        Incident NX-42B has owner Priya. The exact mitigation is to rotate the Okta bridge key before Friday.
        """.write(to: root.appending(path: "Escalation.md"), atomically: true, encoding: .utf8)

        _ = try store.connectDirectory(root, kind: .directory, workspaceId: "alpha")
        let options = KnowledgeRetrievalOptions(workspaceId: "alpha", limit: 5, candidateLimit: 80)
        _ = try store.hybridSearch(query: "generic incident follow-up", options: options)

        let startedAt = Date()
        let results = try store.hybridSearch(query: "NX-42B owner", options: options)
        let latencyMs = Date().timeIntervalSince(startedAt) * 1_000

        XCTAssertEqual(results.first?.documentName, "Escalation.md")
        XCTAssertGreaterThan(results.first?.keywordScore ?? 0, 0)
        XCTAssertLessThan(latencyMs, 80)
    }

    func testBM25InvertedPostingsFindExactIdWithoutScanningMassiveCorpus() {
        let sourceId = UUID()
        let documentId = UUID()
        let targetChunkId = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let source = KnowledgeSource(
            id: sourceId,
            kind: .directory,
            displayName: "Massive Directory",
            rootPath: nil,
            bookmarkData: nil,
            workspaceId: "alpha",
            status: .connected,
            isEnabled: true,
            lastIndexedAt: now,
            lastError: nil,
            documentCount: 1,
            chunkCount: 20_001,
            createdAt: now,
            updatedAt: now
        )
        let document = KnowledgeDocumentRecord(
            id: documentId,
            sourceId: sourceId,
            displayName: "Massive Notes.md",
            filePath: nil,
            contentHash: "massive-notes",
            fileSize: 1_000_000,
            modifiedAt: now,
            workspaceId: "alpha",
            kind: .markdown,
            metadata: ["tags": "status,customers"],
            createdAt: now,
            updatedAt: now
        )
        var chunks: [KnowledgeChunkRecord] = (0..<20_000).map { index in
            KnowledgeChunkRecord(
                id: UUID(),
                documentId: documentId,
                sourceId: sourceId,
                sequence: index,
                heading: "Status \(index)",
                content: "Generic onboarding dashboard metrics renewal sentiment update \(index).",
                tokenEstimate: 9,
                locationLabel: "line \(index + 1)",
                contentHash: "noise-\(index)",
                workspaceId: "alpha",
                createdAt: now,
                updatedAt: now
            )
        }
        chunks.append(KnowledgeChunkRecord(
            id: targetChunkId,
            documentId: documentId,
            sourceId: sourceId,
            sequence: 20_000,
            heading: "Escalation",
            content: "Incident ZXQ-8841 owner Priya must rotate the bridge key before Friday.",
            tokenEstimate: 11,
            locationLabel: "line 20001",
            contentHash: "target",
            workspaceId: "alpha",
            createdAt: now,
            updatedAt: now
        ))
        let index = LocalBM25Index(chunks: chunks, documentsById: [documentId: document], sourcesById: [sourceId: source])

        let startedAt = Date()
        let results = index.search(terms: LocalBM25Index.tokens(from: "ZXQ-8841 owner"), limit: 5)
        let compactResults = index.search(terms: LocalBM25Index.tokens(from: "ZXQ8841 owner"), limit: 5)
        let latencyMs = Date().timeIntervalSince(startedAt) * 1_000

        XCTAssertEqual(results.first?.chunkId, targetChunkId)
        XCTAssertEqual(compactResults.first?.chunkId, targetChunkId)
        XCTAssertLessThan(latencyMs, 60)
    }

    func testReindexDeletesOrphanedChunksForRemovedFiles() throws {
        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let store = LocalKnowledgeStore(container: container, workspaceId: "alpha", cryptor: try testCryptor())
        let root = try temporaryDirectory(named: "notchly-rag-orphans")
        let file = root.appending(path: "Launch.md")
        try "# Launch\nRollback owner is Bea.".write(to: file, atomically: true, encoding: .utf8)

        let source = try store.connectDirectory(root, kind: .directory, workspaceId: "alpha")
        XCTAssertEqual(try store.sourceConnectionViewModels(workspaceId: "alpha").first?.documentCount, 1)

        try FileManager.default.removeItem(at: file)
        _ = try store.indexSource(source.id)

        let updated = try XCTUnwrap(store.sourceConnectionViewModels(workspaceId: "alpha").first)
        XCTAssertEqual(updated.documentCount, 0)
        XCTAssertEqual(updated.chunkCount, 0)
        XCTAssertTrue(try store.keywordSearch(query: "rollback owner", workspaceId: "alpha").isEmpty)
    }

    func testDirectoryReindexSkipsUnchangedFilesBeforeReadingContent() throws {
        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let store = LocalKnowledgeStore(container: container, workspaceId: "alpha", cryptor: try testCryptor())
        let root = try temporaryDirectory(named: "notchly-rag-snapshot")
        let file = root.appending(path: "Snapshot.md")
        try "# Snapshot\nThe launch fallback owner is Bea.".write(to: file, atomically: true, encoding: .utf8)

        let source = try store.connectDirectory(root, kind: .directory, workspaceId: "alpha")
        XCTAssertEqual(try store.sourceConnectionViewModels(workspaceId: "alpha").first?.documentCount, 1)

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        let reindexed = try store.indexSource(source.id)

        XCTAssertEqual(reindexed.status, .connected)
        XCTAssertEqual(reindexed.documentCount, 1)
        XCTAssertEqual(try store.keywordSearch(query: "fallback owner", workspaceId: "alpha").first?.documentName, "Snapshot.md")
    }

    func testRetrievalServiceUsesLocalEmbeddingsWhenIndexed() async throws {
        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let store = LocalKnowledgeStore(container: container, workspaceId: "alpha", cryptor: try testCryptor())
        try store.addDocument(name: "Rollback.md", content: "The deployment needs a rollback strategy and owner.", workspaceId: "alpha")
        try store.addDocument(name: "Fruit.md", content: "Bananas and oranges are unrelated.", workspaceId: "alpha")
        var preferences = AppPreferences()
        preferences.workspaceId = "alpha"
        preferences.ragDefaultResultLimit = 3
        let provider = StubEmbeddingProvider()
        let indexed = try await store.indexMissingEmbeddings(provider: provider, workspaceId: "alpha")

        let retrieval = await KnowledgeRetrievalService(store: store, embeddingProvider: provider)
            .retrieve(query: "fallback plan", preferences: preferences, limit: 3)

        XCTAssertEqual(indexed, 2)
        XCTAssertEqual(retrieval.results.first?.documentName, "Rollback.md")
        XCTAssertGreaterThan(retrieval.results.first?.semanticScore ?? 0, 0)
    }

    func testRetrievalSkipsQueryEmbeddingWhenSemanticIndexIsEmptyAndDoesNotBackfill() async throws {
        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let store = LocalKnowledgeStore(container: container, workspaceId: "alpha", cryptor: try testCryptor())
        try store.addDocument(name: "Local.md", content: "The pricing review owner is Carla.", workspaceId: "alpha")
        var preferences = AppPreferences()
        preferences.workspaceId = "alpha"
        preferences.localOnlyMode = true
        let provider = CountingEmbeddingProvider()

        let retrieval = await KnowledgeRetrievalService(store: store, embeddingProvider: provider)
            .retrieve(query: "pricing review owner", preferences: preferences, limit: 3)

        let coverage = try store.embeddingCoverage(model: provider.modelIdentifier, workspaceId: "alpha")
        XCTAssertEqual(provider.embedCalls, 0)
        XCTAssertEqual(coverage.embedded, 0)
        XCTAssertEqual(retrieval.results.first?.documentName, "Local.md")
        XCTAssertEqual(retrieval.stageLatencies.queryEmbeddingMs, 0)
        XCTAssertGreaterThan(retrieval.results.first?.keywordScore ?? 0, 0)
    }

    func testRetrievalOnlyEmbedsQueryWhenSemanticIndexExistsAndDoesNotBackfillMissingChunks() async throws {
        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let store = LocalKnowledgeStore(container: container, workspaceId: "alpha", cryptor: try testCryptor())
        try store.addDocument(name: "Indexed.md", content: "The launch fallback owner is Maya.", workspaceId: "alpha")
        try store.addDocument(name: "Missing.md", content: "The pricing review owner is Carla.", workspaceId: "alpha")
        var preferences = AppPreferences()
        preferences.workspaceId = "alpha"
        preferences.localOnlyMode = true
        let provider = CountingEmbeddingProvider()

        let indexed = try await store.indexMissingEmbeddings(provider: provider, workspaceId: "alpha", limit: 1)
        let coverageBefore = try store.embeddingCoverage(model: provider.modelIdentifier, workspaceId: "alpha")
        let retrieval = await KnowledgeRetrievalService(store: store, embeddingProvider: provider)
            .retrieve(query: "pricing review owner", preferences: preferences, limit: 3)
        let coverageAfter = try store.embeddingCoverage(model: provider.modelIdentifier, workspaceId: "alpha")

        XCTAssertEqual(indexed, 1)
        XCTAssertEqual(provider.embedCalls, 2)
        XCTAssertEqual(coverageBefore.embedded, 1)
        XCTAssertEqual(coverageBefore.total, 2)
        XCTAssertEqual(coverageAfter.embedded, 1)
        XCTAssertEqual(coverageAfter.total, 2)
        XCTAssertEqual(retrieval.results.first?.documentName, "Missing.md")
    }

    func testBackgroundIndexingRejectsRemoteEmbeddingProviders() async throws {
        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let store = LocalKnowledgeStore(container: container, workspaceId: "alpha", cryptor: try testCryptor())
        try store.addDocument(name: "Local.md", content: "The pricing review owner is Carla.", workspaceId: "alpha")
        let provider = RemoteEmbeddingProvider(modelIdentifier: "openai-text-embedding-legacy")

        do {
            _ = try await store.indexMissingEmbeddings(provider: provider, workspaceId: "alpha")
            XCTFail("Remote embedding providers must be rejected for local-first indexing.")
        } catch let error as EmbeddingProviderSafetyError {
            XCTAssertEqual(error, .remoteProviderRejected("openai-text-embedding-legacy"))
        }

        let coverage = try store.embeddingCoverage(model: provider.modelIdentifier, workspaceId: "alpha")
        XCTAssertEqual(provider.embedCalls, 0)
        XCTAssertEqual(coverage.embedded, 0)
    }

    func testBackgroundIndexingRejectsMalformedEmbeddingBatchWithoutSavingCoverage() async throws {
        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let store = LocalKnowledgeStore(container: container, workspaceId: "alpha", cryptor: try testCryptor())
        try store.addDocument(name: "Local.md", content: "The pricing review owner is Carla.", workspaceId: "alpha")
        try store.addDocument(name: "Roadmap.md", content: "The roadmap owner is Leo.", workspaceId: "alpha")
        let provider = MalformedEmbeddingProvider(mode: .missingVector)

        do {
            _ = try await store.indexMissingEmbeddings(provider: provider, workspaceId: "alpha")
            XCTFail("Malformed embedding batches must not be persisted.")
        } catch let error as EmbeddingProviderSafetyError {
            XCTAssertEqual(error, .invalidBatchCount(model: "malformed-local-v1", expected: 2, actual: 1))
        }

        let coverage = try store.embeddingCoverage(model: provider.modelIdentifier, workspaceId: "alpha")
        XCTAssertEqual(provider.embedCalls, 1)
        XCTAssertEqual(coverage.embedded, 0)
        XCTAssertEqual(coverage.total, 2)
    }

    func testBackgroundIndexingRejectsWrongEmbeddingDimensionsWithoutSavingCoverage() async throws {
        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let store = LocalKnowledgeStore(container: container, workspaceId: "alpha", cryptor: try testCryptor())
        try store.addDocument(name: "Local.md", content: "The pricing review owner is Carla.", workspaceId: "alpha")
        let provider = MalformedEmbeddingProvider(mode: .wrongDimensions)

        do {
            _ = try await store.indexMissingEmbeddings(provider: provider, workspaceId: "alpha")
            XCTFail("Wrong embedding dimensions must not be persisted.")
        } catch let error as EmbeddingProviderSafetyError {
            XCTAssertEqual(error, .invalidVectorDimensions(model: "malformed-local-v1", expected: 2, actual: 1))
        }

        let coverage = try store.embeddingCoverage(model: provider.modelIdentifier, workspaceId: "alpha")
        XCTAssertEqual(provider.embedCalls, 1)
        XCTAssertEqual(coverage.embedded, 0)
        XCTAssertEqual(coverage.total, 1)
    }

    func testBackgroundIndexingRejectsNonFiniteEmbeddingValuesWithoutSavingCoverage() async throws {
        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let store = LocalKnowledgeStore(container: container, workspaceId: "alpha", cryptor: try testCryptor())
        try store.addDocument(name: "Local.md", content: "The pricing review owner is Carla.", workspaceId: "alpha")
        let provider = MalformedEmbeddingProvider(mode: .nonFinite)

        do {
            _ = try await store.indexMissingEmbeddings(provider: provider, workspaceId: "alpha")
            XCTFail("Non-finite embedding values must not be persisted.")
        } catch let error as EmbeddingProviderSafetyError {
            XCTAssertEqual(error, .invalidVectorValue(model: "malformed-local-v1"))
        }

        let coverage = try store.embeddingCoverage(model: provider.modelIdentifier, workspaceId: "alpha")
        XCTAssertEqual(provider.embedCalls, 1)
        XCTAssertEqual(coverage.embedded, 0)
        XCTAssertEqual(coverage.total, 1)
    }

    func testLocalEmbeddingInputsCarrySemanticRolesForMeetingsAndObsidian() async throws {
        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let store = LocalKnowledgeStore(container: container, workspaceId: "alpha", cryptor: try testCryptor())
        let meetingId = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let meeting = MeetingSession(
            id: meetingId,
            title: "Launch Review",
            source: .activeApp,
            appName: "Zoom",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(1_800),
            status: .ended,
            primaryLanguage: "en-US",
            transcriptSegments: [
                TranscriptSegment(
                    meetingId: meetingId,
                    speakerLabel: "Maya",
                    audioSource: .microphone,
                    text: "The rollback owner is Priya and the launch decision stays blocked.",
                    startTime: 12,
                    endTime: 19
                )
            ],
            summary: MeetingSummary(
                meetingId: meetingId,
                executiveSummary: "Launch review with rollback ownership.",
                keyDecisions: ["Block launch until rollback owner confirms readiness"],
                actionItems: [
                    ActionItem(title: "Confirm rollback owner", owner: "Priya", priority: .high)
                ],
                risks: ["Checkout errors may delay launch"],
                openQuestions: ["Can support cover the Friday window?"],
                strategicInsights: ["Owner clarity is the launch gate"],
                generatedAt: startedAt.addingTimeInterval(1_900)
            ),
            tags: ["launch", "rollback"],
            meetingType: .product
        )
        let vault = try temporaryDirectory(named: "notchly-rag-role-vault")
        try """
        ---
        tags: [launch, rollback]
        ---
        # Launch Note
        [[Rollout Plan]] says Priya owns the rollback checklist.
        ![[launch-map.png]]
        """.write(to: vault.appending(path: "Launch Note.md"), atomically: true, encoding: .utf8)

        try store.indexMeeting(meeting, workspaceId: "alpha")
        _ = try store.connectDirectory(vault, kind: .obsidian, workspaceId: "alpha")
        let provider = CapturingEmbeddingProvider()

        let indexed = try await store.indexMissingEmbeddings(provider: provider, workspaceId: "alpha", limit: 10)
        var preferences = AppPreferences()
        preferences.workspaceId = "alpha"
        let retrieval = await KnowledgeRetrievalService(store: store, embeddingProvider: provider)
            .retrieve(query: "Priya rollback owner launch decision", preferences: preferences, limit: 3)
        let indexedInputs = provider.capturedInputs.joined(separator: "\n\n")

        XCTAssertGreaterThanOrEqual(indexed, 3)
        XCTAssertTrue(indexedInputs.contains("Content role: Meeting transcript"))
        XCTAssertTrue(indexedInputs.contains("Retrieval focus: spoken questions, speaker statements, timestamps, decisions in conversation"))
        XCTAssertTrue(indexedInputs.contains("Content role: Meeting summary"))
        XCTAssertTrue(indexedInputs.contains("Retrieval focus: decisions, action items, owners, risks, open questions, insights"))
        XCTAssertTrue(indexedInputs.contains("Content role: Obsidian note"))
        XCTAssertTrue(indexedInputs.contains("Retrieval focus: note headings, tags, wikilinks, backlinks, attachments"))
        XCTAssertTrue(retrieval.context.contains("Content role:"))
        XCTAssertTrue(retrieval.context.contains("Retrieval focus:"))
    }

    func testRetrievalFallsBackToLocalProviderWhenRemoteEmbeddingProviderIsInjected() async throws {
        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let store = LocalKnowledgeStore(container: container, workspaceId: "alpha", cryptor: try testCryptor())
        try store.addDocument(name: "Owner.md", content: "The pricing review owner is Carla.", workspaceId: "alpha")
        try store.addDocument(name: "Noise.md", content: "General onboarding notes mention dashboards.", workspaceId: "alpha")
        var preferences = AppPreferences()
        preferences.workspaceId = "alpha"
        preferences.ragDefaultResultLimit = 3
        let provider = RemoteEmbeddingProvider(modelIdentifier: "openai-text-embedding-legacy")

        let retrieval = await KnowledgeRetrievalService(store: store, embeddingProvider: provider)
            .retrieve(query: "pricing review owner", preferences: preferences, limit: 3)

        XCTAssertEqual(provider.embedCalls, 0)
        XCTAssertEqual(retrieval.results.first?.documentName, "Owner.md")
        XCTAssertGreaterThan(retrieval.results.first?.keywordScore ?? 0, 0)
    }

    func testLegacyCloudEmbeddingModelIsIgnoredAndNotPersisted() throws {
        let legacy = Data("""
        {
          "provider": "openAI",
          "authMode": "openAICodexCLI",
          "model": "gpt-5-mini",
          "embeddingModel": "text-embedding-3-small"
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(AIProviderConfig.self, from: legacy)
        let encoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)

        XCTAssertEqual(decoded.model, "gpt-5-mini")
        XCTAssertFalse(encoded.contains("embeddingModel"))
        XCTAssertFalse(encoded.contains("text-embedding-3-small"))
    }

    func testRealtimeRetrievalFallsBackToBM25WhenQueryEmbeddingExceedsBudget() async throws {
        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let store = LocalKnowledgeStore(container: container, workspaceId: "alpha", cryptor: try testCryptor())
        try store.addDocument(name: "Owner.md", content: "The pricing review owner is Carla and the deadline is Friday.", workspaceId: "alpha")
        try store.addDocument(name: "Noise.md", content: "General onboarding notes mention dashboards and sentiment.", workspaceId: "alpha")
        var preferences = AppPreferences()
        preferences.workspaceId = "alpha"
        preferences.ragRealtimeLatencyTargetMs = 120
        preferences.ragDefaultResultLimit = 3
        let indexingProvider = SlowEmbeddingProvider(delayNanoseconds: 0)
        let indexed = try await store.indexMissingEmbeddings(provider: indexingProvider, workspaceId: "alpha", limit: 1)
        let provider = SlowEmbeddingProvider(delayNanoseconds: 350_000_000)

        let retrieval = await KnowledgeRetrievalService(store: store, embeddingProvider: provider)
            .retrieve(query: "pricing review owner", preferences: preferences, limit: 3)
        let coverage = try store.embeddingCoverage(model: provider.modelIdentifier, workspaceId: "alpha")
        let report = try store.indexHealthReport(
            model: provider.modelIdentifier,
            workspaceId: "alpha",
            latencyTargetMs: preferences.ragRealtimeLatencyTargetMs
        )

        XCTAssertEqual(indexed, 1)
        XCTAssertEqual(provider.embedCalls, 1)
        XCTAssertEqual(coverage.embedded, 1)
        XCTAssertEqual(coverage.total, 2)
        XCTAssertEqual(retrieval.results.first?.documentName, "Owner.md")
        XCTAssertGreaterThan(retrieval.results.first?.keywordScore ?? 0, 0)
        XCTAssertEqual(retrieval.results.first?.semanticScore ?? -1, 0)
        XCTAssertGreaterThan(retrieval.stageLatencies.queryEmbeddingMs, 0)
        XCTAssertLessThanOrEqual(retrieval.stageLatencies.queryEmbeddingMs, retrieval.latencyMs)
        XCTAssertEqual(report.queryEmbeddingP95Ms, retrieval.stageLatencies.queryEmbeddingMs)
        XCTAssertEqual(report.hybridSearchP95Ms, retrieval.stageLatencies.hybridSearchMs)
        XCTAssertEqual(report.rerankP95Ms, retrieval.stageLatencies.rerankMs)
        XCTAssertEqual(report.contextAssemblyP95Ms, retrieval.stageLatencies.contextAssemblyMs)
        XCTAssertLessThan(retrieval.latencyMs, 220)
    }

    func testRetrievalMarksMissingEvidenceInsteadOfReturningSilentEmptyContext() async throws {
        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let store = LocalKnowledgeStore(container: container, workspaceId: "alpha", cryptor: try testCryptor())
        var preferences = AppPreferences()
        preferences.workspaceId = "alpha"
        let provider = CountingEmbeddingProvider()

        let retrieval = await KnowledgeRetrievalService(store: store, embeddingProvider: provider)
            .retrieve(query: "Who owns the NX-42B mitigation?", preferences: preferences, limit: 3)

        XCTAssertTrue(retrieval.results.isEmpty)
        XCTAssertEqual(retrieval.grounding, .none)
        XCTAssertEqual(retrieval.evidenceScore, 0)
        XCTAssertTrue(retrieval.context.contains("Local evidence: none"))
    }

    func testRetrievalKeepsWeakGroundingWhenOnlyThinKeywordEvidenceMatches() async throws {
        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let store = LocalKnowledgeStore(container: container, workspaceId: "alpha", cryptor: try testCryptor())
        try store.addDocument(
            name: "Generic.md",
            content: "Dashboards are mentioned in a generic onboarding note without owners, deadlines, or decisions.",
            workspaceId: "alpha"
        )
        var preferences = AppPreferences()
        preferences.workspaceId = "alpha"

        let retrieval = await KnowledgeRetrievalService(store: store, embeddingProvider: CountingEmbeddingProvider())
            .retrieve(query: "dashboards compliance escalation", preferences: preferences, limit: 3)

        XCTAssertEqual(retrieval.results.first?.documentName, "Generic.md")
        XCTAssertEqual(retrieval.grounding, .weak)
        XCTAssertLessThan(retrieval.evidenceScore, 0.40)
        XCTAssertTrue(retrieval.context.contains("Local evidence: weak"))
    }

    func testSmallToBigContextIncludesHeadingAndNeighboringEvidence() async throws {
        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let store = LocalKnowledgeStore(container: container, workspaceId: "alpha", cryptor: try testCryptor())
        var indexingPreferences = AppPreferences()
        indexingPreferences.ragChunkTargetTokens = 350
        indexingPreferences.ragChunkOverlapTokens = 0
        store.configure(preferences: indexingPreferences)
        let filler = String(repeating: "General launch notes discuss telemetry, support handoff and customer readiness. ", count: 26)
        let content = """
        # Launch Protocol
        Owner: Maya owns launch recovery and customer escalation.
        \(filler)
        The fallback procedure uses staged rollback when the release monitor detects elevated error rates.
        """
        try store.addDocument(name: "Launch.md", filePath: "/tmp/Launch.md", content: content, workspaceId: "alpha")

        var preferences = AppPreferences()
        preferences.workspaceId = "alpha"
        let retrieval = await KnowledgeRetrievalService(store: store, embeddingProvider: CountingEmbeddingProvider())
            .retrieve(query: "fallback procedure staged rollback", preferences: preferences, limit: 2)

        XCTAssertEqual(retrieval.results.first?.documentName, "Launch.md")
        XCTAssertTrue(retrieval.context.contains("Heading: Launch Protocol"))
        XCTAssertTrue(retrieval.context.contains("Previous context"))
        XCTAssertTrue(retrieval.context.contains("Maya owns launch recovery"))
        XCTAssertTrue(retrieval.context.contains("Matched chunk"))
        XCTAssertTrue(retrieval.context.contains("fallback procedure"))
        XCTAssertEqual(retrieval.results.first?.chunkId, retrieval.results.first?.answerSource().chunkId)
    }

    func testMeetingIndexPreservesTranscriptTimestampsAudioSourceAndActionMetadata() async throws {
        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let store = LocalKnowledgeStore(container: container, workspaceId: "alpha", cryptor: try testCryptor())
        let meetingId = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let meeting = MeetingSession(
            id: meetingId,
            title: "Incident Review",
            source: .activeApp,
            appName: "Zoom",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(1_800),
            status: .ended,
            primaryLanguage: "en-US",
            transcriptSegments: [
                TranscriptSegment(
                    meetingId: meetingId,
                    speakerLabel: "Priya",
                    audioSource: .system,
                    text: "The rollback window opens if checkout errors stay elevated.",
                    startTime: 12,
                    endTime: 18
                ),
                TranscriptSegment(
                    meetingId: meetingId,
                    speakerLabel: "Maya",
                    audioSource: .microphone,
                    text: "I own the customer update and will send the action plan.",
                    startTime: 20,
                    endTime: 27
                )
            ],
            summary: MeetingSummary(
                meetingId: meetingId,
                executiveSummary: "Checkout incident review.",
                actionItems: [
                    ActionItem(
                        title: "Send rollback action plan",
                        owner: "Maya",
                        dueDate: startedAt.addingTimeInterval(86_400),
                        priority: .urgent,
                        sourceQuote: "I own the customer update"
                    )
                ],
                generatedAt: startedAt.addingTimeInterval(1_900)
            ),
            tags: ["incident", "checkout"],
            meetingType: .incident
        )

        try store.indexMeeting(meeting, workspaceId: "alpha")
        let documents = try store.documents()
        let transcript = try XCTUnwrap(documents.first { $0.displayName == "Incident Review transcript" })
        let summary = try XCTUnwrap(documents.first { $0.displayName == "Incident Review summary" })
        var preferences = AppPreferences()
        preferences.workspaceId = "alpha"
        let retrieval = await KnowledgeRetrievalService(store: store, embeddingProvider: CountingEmbeddingProvider())
            .retrieve(query: "system Priya rollback window checkout errors", preferences: preferences, limit: 3)

        XCTAssertTrue(transcript.content.contains("[00:12-00:18] [System] Priya:"))
        XCTAssertTrue(transcript.content.contains("[00:20-00:27] [Mic] Maya:"))
        XCTAssertTrue(summary.content.contains("Action: Send rollback action plan | Owner: Maya | Priority: urgent"))
        XCTAssertTrue(summary.content.contains("Evidence: I own the customer update"))
        XCTAssertEqual(retrieval.results.first?.documentName, "Incident Review transcript")
        XCTAssertEqual(retrieval.results.first?.locationLabel, "00:12-00:27 / turns 1-2")
        XCTAssertTrue(retrieval.context.contains("Meeting type: incident"))
        XCTAssertTrue(retrieval.context.contains("Speakers: Maya,Priya"))
        XCTAssertTrue(retrieval.context.contains("Audio sources: microphone,system"))
        XCTAssertTrue(retrieval.context.contains("[00:12-00:18] [System] Priya"))
    }

    func testLocalEmbeddingProviderFindsSemanticMatchWithoutKeywordOverlap() async throws {
        let provider = LocalEmbeddingProvider(tier: .balanced)
        let query = try await provider.embed("fallback plan")
        let rollback = try await provider.embed("rollback strategy with owner")
        let fruit = try await provider.embed("bananas and oranges")

        let vectorSearch = VectorSearchService()
        XCTAssertGreaterThan(vectorSearch.cosineSimilarity(query, rollback), vectorSearch.cosineSimilarity(query, fruit))
    }

    func testLocalEmbeddingTiersExposeProductionProfilesAndRuntimeKeys() {
        XCTAssertEqual(LocalEmbeddingTier.fast.modelProfile.targetModelId, "Qwen/Qwen3-Embedding-0.6B")
        XCTAssertEqual(LocalEmbeddingTier.balanced.modelProfile.targetModelId, "BAAI/bge-m3")
        XCTAssertEqual(LocalEmbeddingTier.advanced.modelProfile.targetModelId, "Qwen/Qwen3-Embedding-4B")
        XCTAssertEqual(LocalEmbeddingTier.fast.dimensions, 1024)
        XCTAssertEqual(LocalEmbeddingTier.balanced.dimensions, 1024)
        XCTAssertEqual(LocalEmbeddingTier.advanced.dimensions, 2560)
        XCTAssertTrue(LocalEmbeddingTier.balanced.modelProfile.supportsSparseSignals)
        XCTAssertTrue(LocalEmbeddingTier.balanced.modelProfile.supportsLateInteraction)

        let featureHash = LocalEmbeddingProvider(tier: .balanced, runtime: .featureHash)
        let naturalLanguage = LocalEmbeddingProvider(tier: .balanced, runtime: .naturalLanguageHybrid)
        XCTAssertNotEqual(featureHash.modelIdentifier, naturalLanguage.modelIdentifier)
        XCTAssertTrue(featureHash.modelIdentifier.contains("feature-hash"))
        XCTAssertTrue(naturalLanguage.modelIdentifier.contains("nl-hybrid"))
    }

    func testLocalEmbeddingServerRejectsNonLocalEndpoint() {
        XCTAssertThrowsError(
            try LocalEmbeddingServerClient.validateLocalEndpoint("https://example.com/embeddings")
        ) { error in
            XCTAssertEqual(error as? LocalEmbeddingServerError, .nonLocalEndpoint)
        }
    }

    func testLocalEmbeddingServerIndexesAndRetrievesFromLocalhost() async throws {
        let session = Self.localEmbeddingServerSession()
        LocalEmbeddingServerURLProtocol.reset()

        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let store = LocalKnowledgeStore(container: container, workspaceId: "alpha", cryptor: try testCryptor())
        try store.addDocument(name: "Rollback.md", content: "The launch fallback plan uses staged rollback with Maya as owner.", workspaceId: "alpha")
        try store.addDocument(name: "Fruit.md", content: "Bananas and oranges are unrelated.", workspaceId: "alpha")
        let provider = LocalEmbeddingProvider(
            tier: .advanced,
            runtime: .localServer,
            allowModelDownloads: false,
            serverConfiguration: LocalEmbeddingServerConfiguration(
                isEnabled: true,
                endpoint: "http://127.0.0.1:39876/v1/embeddings",
                model: "local-qwen3-4b",
                dimensions: 128
            ),
            urlSession: session
        )

        let indexed = try await store.indexMissingEmbeddings(provider: provider, workspaceId: "alpha", limit: 8)
        var preferences = AppPreferences()
        preferences.workspaceId = "alpha"
        let retrieval = await KnowledgeRetrievalService(store: store, embeddingProvider: provider)
            .retrieve(query: "Who owns the fallback plan?", preferences: preferences, limit: 3)
        let coverage = try store.embeddingCoverage(model: provider.modelIdentifier, workspaceId: "alpha")

        XCTAssertEqual(provider.activeRuntime, .localServer)
        XCTAssertEqual(provider.dimensions, 128)
        XCTAssertEqual(indexed, 2)
        XCTAssertEqual(coverage.embedded, 2)
        XCTAssertEqual(retrieval.results.first?.documentName, "Rollback.md")
        XCTAssertGreaterThan(retrieval.results.first?.semanticScore ?? 0, 0)
        XCTAssertGreaterThanOrEqual(LocalEmbeddingServerURLProtocol.lastRequests.count, 2)
        XCTAssertTrue(LocalEmbeddingServerURLProtocol.lastRequests.allSatisfy { $0.url?.host == "127.0.0.1" })
        XCTAssertFalse(LocalEmbeddingServerURLProtocol.lastRequests.contains { $0.url?.absoluteString.localizedCaseInsensitiveContains("openai") == true })
    }

    func testLocalEmbeddingRuntimeSelectorBenchmarksExecutableRuntime() async throws {
        let result = await LocalEmbeddingRuntimeSelector(targetLatencyMs: 250).benchmark(tier: .balanced)
        let selected = try XCTUnwrap(result.selectedCandidate)

        XCTAssertEqual(result.tier, .balanced)
        XCTAssertEqual(result.targetModelId, "BAAI/bge-m3")
        XCTAssertFalse(result.machineFingerprint.isEmpty)
        XCTAssertTrue(selected.executable)
        XCTAssertGreaterThan(selected.dimensions, 0)
        XCTAssertNotNil(selected.semanticProbeScore)
        XCTAssertEqual(selected.semanticProbeCount, 4)
        XCTAssertGreaterThanOrEqual(selected.semanticProbeScore ?? 0, 0.50)
        XCTAssertTrue(result.summary.contains("q"))
        XCTAssertGreaterThanOrEqual(result.candidates.count, 2)
    }

    func testAppleMetalToggleDisablesMLXEmbeddingRuntime() async throws {
        let manager = LocalEmbeddingModelManager()
        let requestedMLX = manager.resolvedRuntime(
            tier: .balanced,
            requested: .mlx,
            allowDownloads: true,
            allowMetalAcceleration: false
        )
        let automatic = manager.resolvedRuntime(
            tier: .balanced,
            requested: .automatic,
            allowDownloads: true,
            allowMetalAcceleration: false
        )
        let provider = LocalEmbeddingProvider(
            tier: .balanced,
            runtime: .mlx,
            allowModelDownloads: true,
            allowMetalAcceleration: false,
            modelManager: manager
        )
        let selectorResult = await LocalEmbeddingRuntimeSelector(
            targetLatencyMs: 250,
            allowModelDownloads: true,
            allowMetalAcceleration: false,
            modelManager: manager
        ).benchmark(tier: .balanced)

        XCTAssertEqual(requestedMLX, .naturalLanguageHybrid)
        XCTAssertNotEqual(automatic, .mlx)
        XCTAssertFalse(manager.isUsable(tier: .balanced, runtime: .mlx, allowDownloads: true, allowMetalAcceleration: false))
        XCTAssertEqual(provider.activeRuntime, .naturalLanguageHybrid)
        XCTAssertFalse(selectorResult.candidates.contains { $0.runtime == .mlx })
        XCTAssertNotEqual(selectorResult.selectedRuntime, .mlx)
    }

    func testAppleMetalPreferencePersistsAndDropsMLXSelectionWhenDisabled() throws {
        var preferences = AppPreferences()
        preferences.ragAppleMetalAccelerationEnabled = false
        preferences.ragLocalEmbeddingRuntime = .mlx
        preferences.ragLocalEmbeddingBenchmark = LocalEmbeddingRuntimeBenchmarkResult(
            tier: .balanced,
            targetModelId: LocalEmbeddingTier.balanced.modelProfile.targetModelId,
            selectedRuntime: .mlx,
            targetLatencyMs: 250,
            machineFingerprint: "test-machine",
            measuredAt: Date(timeIntervalSince1970: 1_700_000_000),
            candidates: []
        )

        let normalized = preferences.normalizedForPersistence()
        let encoded = try JSONEncoder().encode(normalized)
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: encoded)

        XCTAssertFalse(normalized.ragAppleMetalAccelerationEnabled)
        XCTAssertEqual(normalized.ragLocalEmbeddingRuntime, .automatic)
        XCTAssertNil(normalized.ragLocalEmbeddingBenchmark)
        XCTAssertFalse(decoded.ragAppleMetalAccelerationEnabled)
    }

    func testLocalEmbeddingModelManagerExposesMLXDescriptorsAndDownloadGate() throws {
        let manager = LocalEmbeddingModelManager()
        let fast = try XCTUnwrap(manager.descriptor(tier: .fast, runtime: .mlx))
        let balanced = try XCTUnwrap(manager.descriptor(tier: .balanced, runtime: .mlx))

        XCTAssertEqual(fast.modelIdentifier, "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ")
        XCTAssertEqual(fast.dimensions, LocalEmbeddingTier.fast.dimensions)
        XCTAssertEqual(balanced.modelIdentifier, "BAAI/bge-m3")
        XCTAssertEqual(balanced.dimensions, LocalEmbeddingTier.balanced.dimensions)

        let offlineRuntime = manager.resolvedRuntime(tier: .balanced, requested: .mlx, allowDownloads: false)
        if manager.isUsable(tier: .balanced, runtime: .mlx, allowDownloads: false) {
            XCTAssertEqual(offlineRuntime, .mlx)
        } else {
            XCTAssertEqual(offlineRuntime, .naturalLanguageHybrid)
        }

        if LocalEmbeddingModelManager.isMLXEmbeddingRuntimeLinked {
            XCTAssertEqual(manager.resolvedRuntime(tier: .fast, requested: .mlx, allowDownloads: true), .mlx)
        }
        if !manager.isUsable(tier: .fast, runtime: .mlx, allowDownloads: false) {
            XCTAssertEqual(manager.resolvedRuntime(tier: .fast, requested: .automatic, allowDownloads: false), .naturalLanguageHybrid)
            XCTAssertEqual(manager.resolvedRuntime(tier: .fast, requested: .mlx, allowDownloads: false), .naturalLanguageHybrid)
        }
    }

    func testCoreMLEmbeddingRuntimeRequiresLoadableLocalPackage() throws {
        let root = try temporaryDirectory(named: "notchly-coreml-embedding-runtime")
        let manager = LocalEmbeddingModelManager(modelsRootOverride: root)
        let descriptor = try XCTUnwrap(manager.descriptor(tier: .fast, runtime: .coreML))
        let directory = try manager.modelDirectory(for: descriptor)
        let modelURL = directory.appendingPathComponent("Embedding.mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: modelURL, withIntermediateDirectories: true)
        let manifest = LocalCoreMLEmbeddingManifest(
            modelFileName: "Embedding.mlmodelc",
            inputName: "text",
            outputName: "embedding",
            dimensions: LocalEmbeddingTier.fast.dimensions
        )
        try JSONEncoder()
            .encode(manifest)
            .write(to: directory.appendingPathComponent(LocalCoreMLEmbeddingManifest.fileName), options: [.atomic])

        XCTAssertEqual(descriptor.displayName, "Qwen3 Embedding 0.6B Core ML")
        XCTAssertEqual(descriptor.runtime, .coreML)
        XCTAssertNotNil(manager.availableLocalDirectory(for: descriptor))
        XCTAssertNotNil(manager.coreMLPackage(tier: .fast))
        XCTAssertFalse(manager.isUsable(tier: .fast, runtime: .coreML, allowDownloads: false))
        XCTAssertEqual(manager.resolvedRuntime(tier: .fast, requested: .coreML, allowDownloads: false), .naturalLanguageHybrid)
        XCTAssertTrue(manager.statusText(tier: .fast, runtime: .coreML, allowDownloads: false).contains("cannot load"))
    }

    func testLocalEmbeddingProviderMaintainsLocalFallbackWhenMLXUnavailable() async throws {
        let manager = LocalEmbeddingModelManager()
        let provider = LocalEmbeddingProvider(
            tier: .balanced,
            runtime: .mlx,
            allowModelDownloads: false,
            modelManager: manager
        )

        let vector = try await provider.embed("rollback plan owner for launch")

        XCTAssertEqual(vector.count, LocalEmbeddingTier.balanced.dimensions)
        XCTAssertEqual(provider.activeRuntime, manager.resolvedRuntime(tier: .balanced, requested: .mlx, allowDownloads: false))
    }

    func testLocalVectorANNIndexFindsNeedleInLargeCandidateSet() {
        let dimensions = 384
        let targetId = UUID()
        let query = unitVector(angle: 0, dimensions: dimensions)
        var candidates: [VectorSearchService.Candidate] = (0..<640).map { index in
            let angle = 0.75 + Double(index % 160) * 0.0125
            return VectorSearchService.Candidate(chunkId: UUID(), vector: unitVector(angle: angle, dimensions: dimensions))
        }
        candidates.insert(VectorSearchService.Candidate(chunkId: targetId, vector: query), at: 511)

        let index = LocalVectorANNIndex(candidates: candidates)
        let startedAt = Date()
        let results = index.search(query: query, limit: 5)
        let latencyMs = Date().timeIntervalSince(startedAt) * 1_000

        XCTAssertEqual(results.first?.chunkId, targetId)
        XCTAssertLessThan(latencyMs, 30)
    }

    func testEmbeddingVectorsAreStoredAsBinaryAndRemainSearchable() async throws {
        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let store = LocalKnowledgeStore(container: container, workspaceId: "alpha", cryptor: try testCryptor())
        try store.addDocument(name: "Security.md", content: "Security action: rotate customer demo tokens every Friday.", workspaceId: "alpha")
        let provider = StubEmbeddingProvider()

        let indexed = try await store.indexMissingEmbeddings(provider: provider, workspaceId: "alpha")
        let coverage = try store.embeddingCoverage(model: provider.modelIdentifier, workspaceId: "alpha")
        let results = await KnowledgeRetrievalService(store: store, embeddingProvider: provider)
            .retrieve(query: "token rotation action", preferences: {
                var preferences = AppPreferences()
                preferences.workspaceId = "alpha"
                return preferences
            }(), limit: 3)

        XCTAssertEqual(indexed, 1)
        XCTAssertEqual(coverage.embedded, coverage.total)
        XCTAssertEqual(results.results.first?.documentName, "Security.md")
        XCTAssertGreaterThan(results.results.first?.semanticScore ?? 0, 0)
    }

    func testEmbeddingVectorsUseSidecarBlobStoreAndRemainSearchable() async throws {
        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let cryptor = try testCryptor()
        let vectorRoot = try temporaryDirectory(named: "notchly-vector-sidecar")
        let blobStore = try LocalVectorBlobStore(root: vectorRoot)
        let store = LocalKnowledgeStore(container: container, workspaceId: "alpha", cryptor: cryptor, vectorBlobStore: blobStore)
        try store.addDocument(name: "Security.md", content: "Security action: rotate customer demo tokens every Friday.", workspaceId: "alpha")
        let provider = StubEmbeddingProvider()

        let indexed = try await store.indexMissingEmbeddings(provider: provider, workspaceId: "alpha")
        let context = ModelContext(container)
        let stored = try XCTUnwrap(context.fetch(FetchDescriptor<StoredKnowledgeEmbeddingRecord>()).first)
        let retrieval = await KnowledgeRetrievalService(store: store, embeddingProvider: provider)
            .retrieve(query: "token rotation action", preferences: {
                var preferences = AppPreferences()
                preferences.workspaceId = "alpha"
                return preferences
            }(), limit: 3)

        XCTAssertEqual(indexed, 1)
        XCTAssertEqual(stored.quantization, LocalVectorBlobStore.quantization)
        XCTAssertEqual(try vectorBlobFiles(in: vectorRoot).count, 1)
        XCTAssertEqual(try vectorShardFiles(in: vectorRoot).count, 1)
        XCTAssertEqual(retrieval.results.first?.documentName, "Security.md")
        XCTAssertGreaterThan(retrieval.results.first?.semanticScore ?? 0, 0)

        try store.deleteAll()
        XCTAssertTrue(try vectorBlobFiles(in: vectorRoot).isEmpty)
        XCTAssertTrue(try vectorShardFiles(in: vectorRoot).isEmpty)
    }

    func testVectorShardSurvivesMissingSidecarsAndKeepsSemanticSearchable() async throws {
        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let cryptor = try testCryptor()
        let vectorRoot = try temporaryDirectory(named: "notchly-vector-shard")
        let blobStore = try LocalVectorBlobStore(root: vectorRoot)
        let store = LocalKnowledgeStore(container: container, workspaceId: "alpha", cryptor: cryptor, vectorBlobStore: blobStore)
        try store.addDocument(name: "Rollback.md", content: "The launch rollback strategy has Maya as owner.", workspaceId: "alpha")
        try store.addDocument(name: "Fruit.md", content: "Bananas and oranges are unrelated.", workspaceId: "alpha")
        let provider = StubEmbeddingProvider()

        while try await store.indexMissingEmbeddings(provider: provider, workspaceId: "alpha", limit: 8) > 0 {}
        XCTAssertEqual(try vectorBlobFiles(in: vectorRoot).count, 2)
        XCTAssertEqual(try vectorShardFiles(in: vectorRoot).count, 1)

        for file in try vectorBlobFiles(in: vectorRoot) {
            try FileManager.default.removeItem(at: file)
        }

        let coldStore = LocalKnowledgeStore(container: container, workspaceId: "alpha", cryptor: cryptor, vectorBlobStore: blobStore)
        var preferences = AppPreferences()
        preferences.workspaceId = "alpha"
        preferences.ragDefaultResultLimit = 3
        let retrieval = await KnowledgeRetrievalService(store: coldStore, embeddingProvider: provider)
            .retrieve(query: "fallback plan", preferences: preferences, limit: 3)

        XCTAssertTrue(try vectorBlobFiles(in: vectorRoot).isEmpty)
        XCTAssertEqual(retrieval.results.first?.documentName, "Rollback.md")
        XCTAssertGreaterThan(retrieval.results.first?.semanticScore ?? 0, 0)
    }

    func testBatchIndexingCanDeferShardRebuildUntilFinalize() async throws {
        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let cryptor = try testCryptor()
        let vectorRoot = try temporaryDirectory(named: "notchly-vector-finalize")
        let blobStore = try LocalVectorBlobStore(root: vectorRoot)
        let store = LocalKnowledgeStore(container: container, workspaceId: "alpha", cryptor: cryptor, vectorBlobStore: blobStore)
        for index in 0..<12 {
            try store.addDocument(
                name: "Doc-\(index).md",
                content: index == 7 ? "Rollback fallback owner is Maya." : "Generic onboarding note \(index).",
                workspaceId: "alpha"
            )
        }
        let provider = StubEmbeddingProvider()

        var indexedTotal = 0
        while true {
            let indexed = try await store.indexMissingEmbeddings(
                provider: provider,
                workspaceId: "alpha",
                limit: 3,
                finalizeVectorShard: false
            )
            if indexed == 0 { break }
            indexedTotal += indexed
        }
        let coverage = try store.embeddingCoverage(model: provider.modelIdentifier, workspaceId: "alpha")

        XCTAssertEqual(indexedTotal, coverage.total)
        XCTAssertEqual(coverage.embedded, coverage.total)
        XCTAssertEqual(try vectorBlobFiles(in: vectorRoot).count, coverage.total)
        XCTAssertTrue(try vectorShardFiles(in: vectorRoot).isEmpty)

        try store.finalizeEmbeddingIndex(model: provider.modelIdentifier, workspaceId: "alpha")
        XCTAssertEqual(try vectorShardFiles(in: vectorRoot).count, 1)
    }

    func testRetrievalWarmupBuildsBM25AndVectorCachesBeforeRealtimeQuery() async throws {
        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let cryptor = try testCryptor()
        let vectorRoot = try temporaryDirectory(named: "notchly-vector-warmup")
        let blobStore = try LocalVectorBlobStore(root: vectorRoot)
        let store = LocalKnowledgeStore(container: container, workspaceId: "alpha", cryptor: cryptor, vectorBlobStore: blobStore)
        for index in 0..<18 {
            try store.addDocument(
                name: "Warm-\(index).md",
                content: index == 11 ? "The launch fallback owner is Maya." : "Generic onboarding note \(index).",
                workspaceId: "alpha"
            )
        }
        let provider = StubEmbeddingProvider()
        while try await store.indexMissingEmbeddings(provider: provider, workspaceId: "alpha", limit: 6, finalizeVectorShard: false) > 0 {}

        let report = try store.warmRetrievalIndexes(model: provider.modelIdentifier, workspaceId: "alpha")
        var preferences = AppPreferences()
        preferences.workspaceId = "alpha"
        let retrieval = await KnowledgeRetrievalService(store: store, embeddingProvider: provider)
            .retrieve(query: "fallback owner", preferences: preferences, limit: 3)

        XCTAssertTrue(report.bm25Ready)
        XCTAssertEqual(report.chunkCount, 18)
        XCTAssertEqual(report.embeddedVectorCount, 18)
        XCTAssertEqual(try vectorShardFiles(in: vectorRoot).count, 1)
        XCTAssertEqual(retrieval.results.first?.documentName, "Warm-11.md")
    }

    func testStaleMetadataEmbeddingsAreExcludedAndPurgedBeforeRealtimeUse() async throws {
        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let cryptor = try testCryptor()
        let vectorRoot = try temporaryDirectory(named: "notchly-vector-stale-metadata")
        let blobStore = try LocalVectorBlobStore(root: vectorRoot)
        let store = LocalKnowledgeStore(container: container, workspaceId: "alpha", cryptor: cryptor, vectorBlobStore: blobStore)
        let vault = try temporaryDirectory(named: "notchly-obsidian-stale")
        let alpha = vault.appending(path: "Alpha.md")
        let links = vault.appending(path: "Links.md")
        try "# Alpha\nProject Atlas fallback owner is Maya.\n".write(to: alpha, atomically: true, encoding: .utf8)
        try "# Links\n[[Alpha]] keeps the backlink alive.\n".write(to: links, atomically: true, encoding: .utf8)
        let source = try store.connectDirectory(vault, kind: .obsidian, workspaceId: "alpha")
        let provider = StubEmbeddingProvider()

        while try await store.indexMissingEmbeddings(provider: provider, workspaceId: "alpha", limit: 8) > 0 {}
        let readyCoverage = try store.embeddingCoverage(model: provider.modelIdentifier, workspaceId: "alpha")
        let readyWarmup = try store.warmRetrievalIndexes(model: provider.modelIdentifier, workspaceId: "alpha")
        XCTAssertEqual(readyCoverage.embedded, readyCoverage.total)
        XCTAssertEqual(readyWarmup.embeddedVectorCount, readyWarmup.chunkCount)
        XCTAssertEqual(try vectorBlobFiles(in: vectorRoot).count, readyCoverage.total)
        XCTAssertEqual(try vectorShardFiles(in: vectorRoot).count, 1)

        try "# Links\nBacklink removed; this note no longer references Alpha.\n".write(to: links, atomically: true, encoding: .utf8)
        _ = try store.indexSource(source.id)

        let staleCoverage = try store.embeddingCoverage(model: provider.modelIdentifier, workspaceId: "alpha")
        let staleWarmup = try store.warmRetrievalIndexes(model: provider.modelIdentifier, workspaceId: "alpha")
        XCTAssertEqual(staleCoverage.total, 2)
        XCTAssertEqual(staleCoverage.embedded, 0)
        XCTAssertEqual(staleWarmup.embeddedVectorCount, 0)

        let maintenance = try store.repairEmbeddingIndex(model: provider.modelIdentifier, workspaceId: "alpha")
        XCTAssertEqual(maintenance.activeChunkCount, 2)
        XCTAssertEqual(maintenance.validEmbeddingCount, 0)
        XCTAssertEqual(maintenance.missingEmbeddingCount, 2)
        XCTAssertEqual(maintenance.deletedStaleEmbeddingCount, 1)
        XCTAssertEqual(maintenance.deletedOrphanEmbeddingCount, 0)
        XCTAssertEqual(maintenance.deletedDuplicateEmbeddingCount, 0)
        XCTAssertFalse(maintenance.isReadyForRealtime)
        XCTAssertTrue(try vectorBlobFiles(in: vectorRoot).isEmpty)
        XCTAssertTrue(try vectorShardFiles(in: vectorRoot).isEmpty)

        while try await store.indexMissingEmbeddings(provider: provider, workspaceId: "alpha", limit: 8) > 0 {}
        let repairedCoverage = try store.embeddingCoverage(model: provider.modelIdentifier, workspaceId: "alpha")
        let repairedMaintenance = try store.repairEmbeddingIndex(model: provider.modelIdentifier, workspaceId: "alpha")
        XCTAssertEqual(repairedCoverage.embedded, 2)
        XCTAssertEqual(repairedCoverage.total, 2)
        XCTAssertEqual(repairedMaintenance.validEmbeddingCount, 2)
        XCTAssertEqual(repairedMaintenance.missingEmbeddingCount, 0)
        XCTAssertTrue(repairedMaintenance.isReadyForRealtime)
    }

    func testLocalIndexHealthReportUsesCoverageAndRetrievalTracesForMaintenance() async throws {
        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let store = LocalKnowledgeStore(container: container, workspaceId: "alpha", cryptor: try testCryptor())
        try store.addDocument(name: "Indexed.md", content: "The launch fallback owner is Maya.", workspaceId: "alpha")
        try store.addDocument(name: "Pending.md", content: "The security rotation owner is Priya.", workspaceId: "alpha")
        let provider = StubEmbeddingProvider()

        let indexed = try await store.indexMissingEmbeddings(
            provider: provider,
            workspaceId: "alpha",
            limit: 1,
            finalizeVectorShard: false
        )
        store.recordRetrievalTrace(query: "unmatched query", workspaceId: "alpha", results: [], latencyMs: 410)
        store.recordRetrievalTrace(
            query: "launch fallback owner",
            workspaceId: "alpha",
            results: [
                KnowledgeSearchResult(
                    documentName: "Indexed.md",
                    snippet: "The launch fallback owner is Maya.",
                    score: 0.09,
                    workspaceId: "alpha",
                    sourceKind: .file
                )
            ],
            latencyMs: 80
        )

        let report = try store.indexHealthReport(
            model: provider.modelIdentifier,
            workspaceId: "alpha",
            latencyTargetMs: 150
        )

        XCTAssertEqual(indexed, 1)
        XCTAssertEqual(report.sourceCount, 1)
        XCTAssertEqual(report.documentCount, 2)
        XCTAssertEqual(report.chunkCount, 2)
        XCTAssertEqual(report.embeddedChunkCount, 1)
        XCTAssertEqual(report.staleChunkCount, 1)
        XCTAssertEqual(report.embeddingCoverage, 0.5, accuracy: 0.0001)
        XCTAssertEqual(report.recentTraceCount, 2)
        XCTAssertEqual(report.weakTraceCount, 1)
        XCTAssertEqual(report.uncitedTraceCount, 1)
        XCTAssertEqual(report.hybridTraceCount, 0)
        XCTAssertEqual(report.slowTraceP95Ms, 410)
        XCTAssertFalse(report.isReadyForRealtime)
        XCTAssertTrue(report.recommendations.contains { $0.contains("Embed 1 stale") })
        XCTAssertTrue(report.recommendations.contains { $0.contains("Repair citation metadata") })
        XCTAssertTrue(report.recommendations.contains { $0.contains("retrieval p95 is 410ms") })
    }

    func testRetrievalTraceHealthTracksCitationsAndHybridEvidence() async throws {
        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let store = LocalKnowledgeStore(container: container, workspaceId: "alpha", cryptor: try testCryptor())
        try store.addDocument(name: "Launch.md", content: "Launch fallback owner is Maya.", workspaceId: "alpha")
        let provider = StubEmbeddingProvider()
        while try await store.indexMissingEmbeddings(provider: provider, workspaceId: "alpha", limit: 8) > 0 {}

        var preferences = AppPreferences()
        preferences.workspaceId = "alpha"
        let retrieval = await KnowledgeRetrievalService(store: store, embeddingProvider: provider)
            .retrieve(query: "fallback owner", preferences: preferences, limit: 3)
        let report = try store.indexHealthReport(model: provider.modelIdentifier, workspaceId: "alpha")

        XCTAssertEqual(retrieval.results.first?.documentName, "Launch.md")
        XCTAssertNotNil(retrieval.results.first?.sourceId)
        XCTAssertNotNil(retrieval.results.first?.documentId)
        XCTAssertNotNil(retrieval.results.first?.chunkId)
        XCTAssertEqual(report.recentTraceCount, 1)
        XCTAssertEqual(report.weakTraceCount, 0)
        XCTAssertEqual(report.uncitedTraceCount, 0)
        XCTAssertEqual(report.hybridTraceCount, 1)
        XCTAssertTrue(report.isReadyForRealtime)
    }

    func testDisabledSourcesDoNotConsumeEmbeddingsOrBlockRealtimeReadiness() async throws {
        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let store = LocalKnowledgeStore(container: container, workspaceId: "alpha", cryptor: try testCryptor())
        let enabledRoot = try temporaryDirectory(named: "notchly-rag-enabled")
        let disabledRoot = try temporaryDirectory(named: "notchly-rag-disabled")
        try "Launch fallback owner is Maya.".write(to: enabledRoot.appending(path: "Launch.md"), atomically: true, encoding: .utf8)
        try "Disabled escalation owner is Priya.".write(to: disabledRoot.appending(path: "Disabled.md"), atomically: true, encoding: .utf8)

        let enabledSource = try store.connectDirectory(enabledRoot, kind: .directory, workspaceId: "alpha")
        let disabledSource = try store.connectDirectory(disabledRoot, kind: .directory, workspaceId: "alpha")
        try store.setSourceEnabled(disabledSource.id, isEnabled: false)
        let provider = StubEmbeddingProvider()

        let initialCoverage = try store.embeddingCoverage(model: provider.modelIdentifier, workspaceId: "alpha")
        let indexed = try await store.indexMissingEmbeddings(provider: provider, workspaceId: "alpha", limit: 10)
        let finalCoverage = try store.embeddingCoverage(model: provider.modelIdentifier, workspaceId: "alpha")
        let missing = try store.chunksMissingEmbedding(model: provider.modelIdentifier, workspaceId: "alpha", limit: 10)
        let report = try store.indexHealthReport(model: provider.modelIdentifier, workspaceId: "alpha")
        let disabledResults = try store.keywordSearch(query: "Priya escalation", limit: 5, workspaceId: "alpha")
        let enabledResults = try store.keywordSearch(query: "fallback owner", limit: 5, workspaceId: "alpha")

        XCTAssertEqual(enabledSource.isEnabled, true)
        XCTAssertEqual(initialCoverage.total, 1)
        XCTAssertEqual(initialCoverage.embedded, 0)
        XCTAssertEqual(indexed, 1)
        XCTAssertEqual(finalCoverage.total, 1)
        XCTAssertEqual(finalCoverage.embedded, 1)
        XCTAssertTrue(missing.isEmpty)
        XCTAssertEqual(report.chunkCount, 1)
        XCTAssertEqual(report.embeddingCoverage, 1.0, accuracy: 0.0001)
        XCTAssertTrue(report.isReadyForRealtime)
        XCTAssertTrue(disabledResults.isEmpty)
        XCTAssertEqual(enabledResults.first?.documentName, "Launch.md")
    }

    func testRAGEvaluationGoldCasesMeasureRecallAndPrecision() async throws {
        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let store = LocalKnowledgeStore(container: container, workspaceId: "alpha", cryptor: try testCryptor())
        try store.addDocument(name: "Roadmap.md", content: "Roadmap decision: ship offline capture before team dashboards.", workspaceId: "alpha")
        try store.addDocument(name: "Security.md", content: "Security action: rotate customer demo tokens every Friday.", workspaceId: "alpha")
        try store.addDocument(name: "Incidents.md", content: "Rollback plan owner: Maya handles launch recovery.", workspaceId: "alpha")
        let provider = LocalEmbeddingProvider(tier: .balanced)
        while try await store.indexMissingEmbeddings(provider: provider, workspaceId: "alpha", limit: 64) > 0 {}

        let cases = [
            RAGGoldCase(query: "What ships before dashboards?", expectedDocument: "Roadmap.md"),
            RAGGoldCase(query: "When do demo tokens rotate?", expectedDocument: "Security.md"),
            RAGGoldCase(query: "Who is responsible for contingency recovery?", expectedDocument: "Incidents.md")
        ]
        let report = await RAGEvaluationHarness().evaluate(cases: cases, store: store, provider: provider, workspaceId: "alpha", k: 2)

        XCTAssertEqual(report.recallAtK, 1.0)
        XCTAssertGreaterThanOrEqual(report.precisionAtK, 0.5)
    }

    func testLocalRAGEvaluatorTracksHardNegativesGroundingAndLatency() async throws {
        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let store = LocalKnowledgeStore(container: container, workspaceId: "alpha", cryptor: try testCryptor())
        let root = try temporaryDirectory(named: "notchly-rag-eval-hard-negatives")
        let disabledRoot = try temporaryDirectory(named: "notchly-rag-eval-disabled")
        try "Project Atlas renewal fallback owner is Maya. The action is staged rollback.".write(to: root.appending(path: "Atlas.md"), atomically: true, encoding: .utf8)
        try "Security action: rotate customer demo tokens every Friday.".write(to: root.appending(path: "Security.md"), atomically: true, encoding: .utf8)
        try "Roadmap decision: ship offline capture before team dashboards.".write(to: root.appending(path: "Roadmap.md"), atomically: true, encoding: .utf8)
        for index in 0..<80 {
            try "Generic workspace note \(index) mentions dashboards, onboarding, sentiment, and planning.".write(to: root.appending(path: "Distractor-\(index).md"), atomically: true, encoding: .utf8)
        }
        try "Project Atlas renewal fallback owner is Priya. This disabled source must not leak.".write(to: disabledRoot.appending(path: "Disabled.md"), atomically: true, encoding: .utf8)

        _ = try store.connectDirectory(root, kind: .directory, workspaceId: "alpha")
        let disabledSource = try store.connectDirectory(disabledRoot, kind: .directory, workspaceId: "alpha")
        try store.setSourceEnabled(disabledSource.id, isEnabled: false)
        try store.addDocument(name: "Beta-Atlas.md", content: "Project Atlas renewal fallback owner is Rafael in another workspace.", workspaceId: "beta")
        let provider = StubEmbeddingProvider()
        while try await store.indexMissingEmbeddings(provider: provider, workspaceId: "alpha", limit: 64) > 0 {}

        let cases = [
            LocalRAGEvaluationCase(
                id: "atlas-owner",
                query: "Who owns the Atlas renewal fallback?",
                expectedDocuments: ["Atlas.md"],
                forbiddenDocuments: ["Disabled.md", "Beta-Atlas.md"]
            ),
            LocalRAGEvaluationCase(
                id: "security-rotation",
                query: "When do demo tokens rotate?",
                expectedDocuments: ["Security.md"],
                forbiddenDocuments: ["Disabled.md", "Beta-Atlas.md"]
            ),
            LocalRAGEvaluationCase(
                id: "roadmap-order",
                query: "What ships before dashboards?",
                expectedDocuments: ["Roadmap.md"],
                forbiddenDocuments: ["Disabled.md", "Beta-Atlas.md"]
            )
        ]

        let report = await LocalRAGEvaluator().evaluate(
            cases: cases,
            store: store,
            provider: provider,
            workspaceId: "alpha",
            k: 1
        )

        XCTAssertEqual(report.caseCount, 3)
        XCTAssertEqual(report.recallAtK, 1.0)
        XCTAssertEqual(report.precisionAtK, 1.0)
        XCTAssertEqual(report.hardNegativeLeakRate, 0)
        XCTAssertEqual(report.groundednessRate, 1.0)
        XCTAssertLessThan(report.p95LatencyMs ?? .max, 250)
        XCTAssertTrue(report.failedCaseIds.isEmpty)
        XCTAssertTrue(report.passesTopTierGate)
    }

    func testMassiveLocalRAGEvaluationAcrossSourcesKeepsLatencyAndPrecision() async throws {
        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let cryptor = try testCryptor()
        let vectorRoot = try temporaryDirectory(named: "notchly-rag-massive-vectors")
        let blobStore = try LocalVectorBlobStore(root: vectorRoot)
        let store = LocalKnowledgeStore(container: container, workspaceId: "alpha", cryptor: cryptor, vectorBlobStore: blobStore)
        let root = try temporaryDirectory(named: "notchly-rag-massive")
        let directory = root.appending(path: "Directory", directoryHint: .isDirectory)
        let obsidian = root.appending(path: "Vault", directoryHint: .isDirectory)
        let disabled = root.appending(path: "Disabled", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: obsidian, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: disabled, withIntermediateDirectories: true)

        for index in 0..<640 {
            let text = """
            # Note \(index)
            Project \(index) discussed generic onboarding material, metrics, dashboards and customer sentiment.
            Follow-up: share broad status notes with stakeholders.
            """
            try text.write(to: directory.appending(path: "Note-\(index).md"), atomically: true, encoding: .utf8)
        }
        try "# Renewal\n[[Atlas]] pricing owner is Maya. The renewal fallback plan is a staged rollback.".write(to: obsidian.appending(path: "Atlas.md"), atomically: true, encoding: .utf8)
        try "Decision: ship offline capture before dashboards. Owner: Leo.".write(to: directory.appending(path: "Roadmap.md"), atomically: true, encoding: .utf8)
        try "Project Atlas renewal fallback owner is Priya. This disabled source must not leak.".write(to: disabled.appending(path: "Disabled-Atlas.md"), atomically: true, encoding: .utf8)
        let meetingId = UUID()
        let meeting = MeetingSession(
            id: meetingId,
            title: "Incident Bridge",
            startedAt: Date(timeIntervalSince1970: 1_700_001_000),
            endedAt: Date(timeIntervalSince1970: 1_700_002_000),
            status: .ended,
            transcriptSegments: [
                TranscriptSegment(
                    meetingId: meetingId,
                    speakerLabel: "Nora",
                    audioSource: .system,
                    text: "I own the incident bridge escalation and customer refund SLA.",
                    startTime: 12,
                    endTime: 20
                )
            ],
            summary: MeetingSummary(
                meetingId: meetingId,
                executiveSummary: "Incident bridge escalation owner is Nora.",
                keyDecisions: ["Nora owns the customer refund SLA escalation."],
                actionItems: [
                    ActionItem(
                        title: "Prepare refund SLA update",
                        owner: "Nora",
                        dueDate: Date(timeIntervalSince1970: 1_700_088_400)
                    )
                ],
                risks: [],
                openQuestions: [],
                strategicInsights: [],
                followUps: [],
                generatedAt: Date(timeIntervalSince1970: 1_700_002_100)
            )
        )

        _ = try store.connectDirectory(directory, kind: .directory, workspaceId: "alpha")
        _ = try store.connectDirectory(obsidian, kind: .obsidian, workspaceId: "alpha")
        let disabledSource = try store.connectDirectory(disabled, kind: .directory, workspaceId: "alpha")
        try store.setSourceEnabled(disabledSource.id, isEnabled: false)
        try store.indexMeeting(meeting, workspaceId: "alpha")
        try store.addDocument(name: "Beta-Atlas.md", content: "Project Atlas renewal fallback owner is Rafael in another workspace.", workspaceId: "beta")
        let provider = TopicEmbeddingProvider()
        while try await store.indexMissingEmbeddings(provider: provider, workspaceId: "alpha", limit: 96, finalizeVectorShard: false) > 0 {}
        let coverage = try store.embeddingCoverage(model: provider.modelIdentifier, workspaceId: "alpha")
        let warmup = try store.warmRetrievalIndexes(model: provider.modelIdentifier, workspaceId: "alpha")

        var preferences = AppPreferences()
        preferences.workspaceId = "alpha"
        preferences.ragDefaultResultLimit = 5
        let atlas = await KnowledgeRetrievalService(store: store, embeddingProvider: provider)
            .retrieve(query: "Atlas pricing owner renewal fallback", preferences: preferences, limit: 5)
        let roadmap = await KnowledgeRetrievalService(store: store, embeddingProvider: provider)
            .retrieve(query: "What ships before dashboards?", preferences: preferences, limit: 5)
        let report = await LocalRAGEvaluator().evaluate(
            cases: [
                LocalRAGEvaluationCase(
                    id: "atlas-owner",
                    query: "Atlas pricing owner renewal fallback",
                    expectedDocuments: ["Atlas.md"],
                    forbiddenDocuments: ["Disabled-Atlas.md", "Beta-Atlas.md"]
                ),
                LocalRAGEvaluationCase(
                    id: "roadmap-order",
                    query: "What ships before dashboards?",
                    expectedDocuments: ["Roadmap.md"],
                    forbiddenDocuments: ["Disabled-Atlas.md", "Beta-Atlas.md"]
                ),
                LocalRAGEvaluationCase(
                    id: "meeting-escalation",
                    query: "Who owns the incident bridge escalation?",
                    expectedDocuments: ["Incident Bridge transcript", "Incident Bridge summary"],
                    forbiddenDocuments: ["Disabled-Atlas.md", "Beta-Atlas.md"]
                )
            ],
            store: store,
            provider: provider,
            workspaceId: "alpha",
            k: 1
        )

        XCTAssertGreaterThanOrEqual(coverage.total, LocalVectorANNIndex.minimumCandidateCount)
        XCTAssertEqual(coverage.embedded, coverage.total)
        XCTAssertTrue(warmup.bm25Ready)
        XCTAssertTrue(warmup.annReady)
        XCTAssertEqual(try vectorShardFiles(in: vectorRoot).count, 1)
        XCTAssertEqual(atlas.results.first?.documentName, "Atlas.md")
        XCTAssertEqual(roadmap.results.first?.documentName, "Roadmap.md")
        XCTAssertLessThan(atlas.latencyMs, 250)
        XCTAssertLessThan(roadmap.latencyMs, 250)
        XCTAssertEqual(report.recallAtK, 1.0)
        XCTAssertEqual(report.precisionAtK, 1.0)
        XCTAssertEqual(report.hardNegativeLeakRate, 0)
        XCTAssertEqual(report.groundednessRate, 1.0)
        XCTAssertLessThan(report.p95LatencyMs ?? .max, 250)
        XCTAssertTrue(report.failedCaseIds.isEmpty)
        XCTAssertTrue(report.passesTopTierGate)
    }

    private func temporaryDirectory(named prefix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "\(prefix)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func vectorBlobFiles(in root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return try enumerator.compactMap { item -> URL? in
            guard let url = item as? URL, url.pathExtension == "ncv" else { return nil }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            return values.isRegularFile == true ? url : nil
        }
    }

    private func vectorShardFiles(in root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return try enumerator.compactMap { item -> URL? in
            guard let url = item as? URL, url.pathExtension == "ncvs" else { return nil }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            return values.isRegularFile == true ? url : nil
        }
    }

    private func unitVector(angle: Double, dimensions: Int) -> [Double] {
        var vector = Array(repeating: 0.0, count: dimensions)
        vector[0] = cos(angle)
        vector[1] = sin(angle)
        return vector
    }

    private static func localEmbeddingServerSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalEmbeddingServerURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private struct StubEmbeddingProvider: EmbeddingProvider {
    var modelIdentifier: String { "stub-local-v1" }
    var dimensions: Int { 2 }
    var executionScope: EmbeddingProviderExecutionScope { .localDevice }

    func embed(_ texts: [String]) async throws -> [[Double]] {
        texts.map { text in
            let lowered = text.lowercased()
            return (lowered.contains("fallback") || lowered.contains("rollback")) ? [1, 0] : [0, 1]
        }
    }
}

private struct TopicEmbeddingProvider: EmbeddingProvider {
    var modelIdentifier: String { "topic-local-massive-v1" }
    var dimensions: Int { 8 }
    var executionScope: EmbeddingProviderExecutionScope { .localDevice }

    func embed(_ texts: [String]) async throws -> [[Double]] {
        texts.map { text in
            let lowered = text.lowercased()
            var vector = Array(repeating: 0.0, count: dimensions)
            if lowered.contains("atlas") || lowered.contains("renewal") || lowered.contains("pricing") || lowered.contains("fallback") {
                vector[0] = 1
            } else if lowered.contains("roadmap") || lowered.contains("offline capture") || lowered.contains("dashboards") {
                vector[1] = 1
            } else if lowered.contains("incident bridge") || lowered.contains("refund") || lowered.contains("escalation") {
                vector[2] = 1
            } else {
                vector[3] = 1
            }
            return vector
        }
    }
}

@MainActor
private final class CountingEmbeddingProvider: EmbeddingProvider {
    var modelIdentifier: String { "counting-local-v1" }
    var dimensions: Int { 2 }
    var executionScope: EmbeddingProviderExecutionScope { .localDevice }
    private(set) var embedCalls = 0

    func embed(_ texts: [String]) async throws -> [[Double]] {
        embedCalls += 1
        return texts.map { _ in [1, 0] }
    }
}

@MainActor
private final class CapturingEmbeddingProvider: EmbeddingProvider {
    var modelIdentifier: String { "capturing-local-v1" }
    var dimensions: Int { 2 }
    var executionScope: EmbeddingProviderExecutionScope { .localDevice }
    private(set) var capturedInputs: [String] = []

    func embed(_ texts: [String]) async throws -> [[Double]] {
        capturedInputs.append(contentsOf: texts)
        return texts.map { text in
            text.localizedCaseInsensitiveContains("rollback") ? [1, 0] : [0, 1]
        }
    }
}

@MainActor
private final class SlowEmbeddingProvider: EmbeddingProvider {
    var modelIdentifier: String { "slow-local-v1" }
    var dimensions: Int { 2 }
    var executionScope: EmbeddingProviderExecutionScope { .localDevice }
    private(set) var embedCalls = 0
    let delayNanoseconds: UInt64

    init(delayNanoseconds: UInt64) {
        self.delayNanoseconds = delayNanoseconds
    }

    func embed(_ texts: [String]) async throws -> [[Double]] {
        embedCalls += 1
        try await Task.sleep(nanoseconds: delayNanoseconds)
        return texts.map { _ in [0, 1] }
    }
}

@MainActor
private final class MalformedEmbeddingProvider: EmbeddingProvider {
    enum Mode {
        case missingVector
        case wrongDimensions
        case nonFinite
    }

    var modelIdentifier: String { "malformed-local-v1" }
    var dimensions: Int { 2 }
    var executionScope: EmbeddingProviderExecutionScope { .localDevice }
    private(set) var embedCalls = 0
    let mode: Mode

    init(mode: Mode) {
        self.mode = mode
    }

    func embed(_ texts: [String]) async throws -> [[Double]] {
        embedCalls += 1
        switch mode {
        case .missingVector:
            return Array(repeating: [1, 0], count: max(0, texts.count - 1))
        case .wrongDimensions:
            return texts.map { _ in [1] }
        case .nonFinite:
            return texts.map { _ in [Double.nan, 0] }
        }
    }
}

@MainActor
private final class RemoteEmbeddingProvider: EmbeddingProvider {
    let modelIdentifier: String
    var dimensions: Int { 2 }
    var executionScope: EmbeddingProviderExecutionScope { .remoteNetwork }
    private(set) var embedCalls = 0

    init(modelIdentifier: String) {
        self.modelIdentifier = modelIdentifier
    }

    func embed(_ texts: [String]) async throws -> [[Double]] {
        embedCalls += 1
        return texts.map { _ in [0, 1] }
    }
}

private struct RAGGoldCase {
    var query: String
    var expectedDocument: String
}

private struct RAGEvaluationReport {
    var recallAtK: Double
    var precisionAtK: Double
}

private final class LocalEmbeddingServerURLProtocol: URLProtocol {
    nonisolated(unsafe) static var lastRequests: [URLRequest] = []
    nonisolated(unsafe) static var lastRequestBodies: [Data] = []

    static func reset() {
        lastRequests = []
        lastRequestBodies = []
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = request.httpBody ?? Self.readBodyStream(from: request)
        Self.lastRequests.append(request)
        if let body {
            Self.lastRequestBodies.append(body)
        }
        do {
            let responseData = try Self.responseData(for: body)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: responseData)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func readBodyStream(from request: URLRequest) -> Data? {
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count > 0 {
                data.append(buffer, count: count)
            } else {
                break
            }
        }
        return data
    }

    private static func responseData(for body: Data?) throws -> Data {
        let input = try requestInputs(from: body ?? Data())
        let items = input.enumerated().map { index, text -> [String: Any] in
            let lowered = text.lowercased()
            let vector: [Double] = lowered.contains("fallback") || lowered.contains("rollback") ? [1, 0, 0, 0] : [0, 1, 0, 0]
            return ["index": index, "embedding": vector]
        }
        return try JSONSerialization.data(withJSONObject: ["data": items])
    }

    private static func requestInputs(from body: Data) throws -> [String] {
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let input = object["input"] as? [String] else {
            return []
        }
        return input
    }
}

@MainActor
private struct RAGEvaluationHarness {
    func evaluate(
        cases: [RAGGoldCase],
        store: LocalKnowledgeStore,
        provider: any EmbeddingProvider,
        workspaceId: String,
        k: Int
    ) async -> RAGEvaluationReport {
        guard !cases.isEmpty else { return RAGEvaluationReport(recallAtK: 0, precisionAtK: 0) }
        var preferences = AppPreferences()
        preferences.workspaceId = workspaceId
        preferences.ragDefaultResultLimit = k
        var hits = 0
        var precisionTotal = 0.0
        for goldCase in cases {
            let retrieval = await KnowledgeRetrievalService(store: store, embeddingProvider: provider)
                .retrieve(query: goldCase.query, preferences: preferences, limit: k)
            let results = retrieval.results
            let matchedIndexes = results.indices.filter { results[$0].documentName == goldCase.expectedDocument }
            if !matchedIndexes.isEmpty {
                hits += 1
                precisionTotal += 1.0 / Double(max(results.count, 1))
            }
        }
        return RAGEvaluationReport(
            recallAtK: Double(hits) / Double(cases.count),
            precisionAtK: precisionTotal / Double(cases.count)
        )
    }
}
