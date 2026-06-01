import Foundation
import SwiftData

@Model
final class StoredMeeting {
    static let titleContext = "StoredMeeting.title.v1"
    static let appNameContext = "StoredMeeting.appName.v1"
    static let meetingURLContext = "StoredMeeting.meetingURL.v1"
    static let audioFilePathContext = "StoredMeeting.audioFilePath.v1"
    static let tagsContext = "StoredMeeting.tagsJSON.v1"
    static let participantsContext = "StoredMeeting.participantsJSON.v1"
    static let automationSourceAppNameContext = "StoredMeeting.automationSourceAppName.v1"
    static let automationSourceBundleIdContext = "StoredMeeting.automationSourceBundleId.v1"

    @Attribute(.unique) var id: UUID
    var title: String
    var sourceRaw: String
    var appName: String?
    var meetingURL: String?
    var startedAt: Date
    var endedAt: Date?
    var statusRaw: String
    var primaryLanguage: String?
    var audioFilePath: String?
    var tagsJSON: String
    var participantsJSON: String
    var meetingTypeRaw: String
    var automationSourceAppName: String?
    var automationSourceBundleId: String?
    var wasAutoEnded: Bool = false

    init(session: MeetingSession, encoder: JSONEncoder = JSONEncoder(), cryptor: LocalDataCryptor) throws {
        self.id = session.id
        self.sourceRaw = session.source.rawValue
        self.startedAt = session.startedAt
        self.endedAt = session.endedAt
        self.statusRaw = session.status.rawValue
        self.primaryLanguage = session.primaryLanguage
        self.meetingTypeRaw = session.meetingType.rawValue
        self.wasAutoEnded = session.wasAutoEnded
        self.title = try cryptor.encryptString(session.title, context: Self.titleContext)
        self.appName = try cryptor.encryptOptionalString(session.appName, context: Self.appNameContext)
        self.meetingURL = try cryptor.encryptOptionalString(session.meetingURL, context: Self.meetingURLContext)
        self.audioFilePath = try cryptor.encryptOptionalString(session.audioFileURL?.path, context: Self.audioFilePathContext)
        self.tagsJSON = try cryptor.encryptString(encodedJSONString(session.tags, encoder: encoder, fallback: "[]"), context: Self.tagsContext)
        self.participantsJSON = try cryptor.encryptString(encodedJSONString(session.participants, encoder: encoder, fallback: "[]"), context: Self.participantsContext)
        self.automationSourceAppName = try cryptor.encryptOptionalString(session.automationSourceAppName, context: Self.automationSourceAppNameContext)
        self.automationSourceBundleId = try cryptor.encryptOptionalString(session.automationSourceBundleId, context: Self.automationSourceBundleIdContext)
    }

    func update(from session: MeetingSession, encoder: JSONEncoder = JSONEncoder(), cryptor: LocalDataCryptor) throws {
        sourceRaw = session.source.rawValue
        startedAt = session.startedAt
        endedAt = session.endedAt
        statusRaw = session.status.rawValue
        primaryLanguage = session.primaryLanguage
        meetingTypeRaw = session.meetingType.rawValue
        wasAutoEnded = session.wasAutoEnded
        try updateEncryptedFields(from: session, encoder: encoder, cryptor: cryptor)
    }

    func encryptSensitiveFieldsIfNeeded(cryptor: LocalDataCryptor) throws {
        title = try cryptor.encryptStringIfNeeded(title, context: Self.titleContext)
        appName = try cryptor.encryptOptionalStringIfNeeded(appName, context: Self.appNameContext)
        meetingURL = try cryptor.encryptOptionalStringIfNeeded(meetingURL, context: Self.meetingURLContext)
        audioFilePath = try cryptor.encryptOptionalStringIfNeeded(audioFilePath, context: Self.audioFilePathContext)
        tagsJSON = try cryptor.encryptStringIfNeeded(tagsJSON, context: Self.tagsContext)
        participantsJSON = try cryptor.encryptStringIfNeeded(participantsJSON, context: Self.participantsContext)
        automationSourceAppName = try cryptor.encryptOptionalStringIfNeeded(automationSourceAppName, context: Self.automationSourceAppNameContext)
        automationSourceBundleId = try cryptor.encryptOptionalStringIfNeeded(automationSourceBundleId, context: Self.automationSourceBundleIdContext)
    }

    private func updateEncryptedFields(from session: MeetingSession, encoder: JSONEncoder, cryptor: LocalDataCryptor) throws {
        title = try cryptor.encryptString(session.title, context: Self.titleContext)
        appName = try cryptor.encryptOptionalString(session.appName, context: Self.appNameContext)
        meetingURL = try cryptor.encryptOptionalString(session.meetingURL, context: Self.meetingURLContext)
        audioFilePath = try cryptor.encryptOptionalString(session.audioFileURL?.path, context: Self.audioFilePathContext)
        tagsJSON = try cryptor.encryptString(encodedJSONString(session.tags, encoder: encoder, fallback: "[]"), context: Self.tagsContext)
        participantsJSON = try cryptor.encryptString(encodedJSONString(session.participants, encoder: encoder, fallback: "[]"), context: Self.participantsContext)
        automationSourceAppName = try cryptor.encryptOptionalString(session.automationSourceAppName, context: Self.automationSourceAppNameContext)
        automationSourceBundleId = try cryptor.encryptOptionalString(session.automationSourceBundleId, context: Self.automationSourceBundleIdContext)
    }
}

@Model
final class StoredTranscriptSegment {
    static let speakerLabelContext = "StoredTranscriptSegment.speakerLabel.v1"
    static let textContext = "StoredTranscriptSegment.text.v1"
    static let draftTranslatedTextContext = "StoredTranscriptSegment.draftTranslatedText.v1"
    static let translatedTextContext = "StoredTranscriptSegment.translatedText.v1"
    static let preservedTermsContext = "StoredTranscriptSegment.preservedTermsJSON.v1"
    static let wordTimestampsContext = "StoredTranscriptSegment.wordTimestampsJSON.v1"

    @Attribute(.unique) var id: UUID
    var meetingId: UUID
    var speakerId: UUID?
    var speakerLabel: String
    var audioSourceRaw: String = TranscriptAudioSource.unknown.rawValue
    var text: String
    var originalLanguage: String?
    var sourceLanguage: String?
    var targetLanguage: String?
    var draftTranslatedText: String?
    var translatedText: String?
    var translatedLanguage: String?
    var translationPhaseRaw: String?
    var translationConfidence: Double?
    var preservedTermsJSON: String?
    var translationStateRaw: String?
    var transcriptionPhaseRaw: String?
    var transcriptionEngineRaw: String?
    var engineConfidence: Double?
    var languageConfidence: Double?
    var revisionOfSegmentId: UUID?
    var revisionNumber: Int = 0
    var finalizedByRaw: String?
    var latencyMs: Double?
    var sourceFrameStart: Int64?
    var sourceFrameEnd: Int64?
    var audioEnergy: Double?
    var stitchingConfidence: Double?
    var retentionReasonRaw: String?
    var wordTimestampsJSON: String?
    var startTime: TimeInterval
    var endTime: TimeInterval
    var confidence: Double
    var isFinal: Bool
    var createdAt: Date

    init(segment: TranscriptSegment, cryptor: LocalDataCryptor) throws {
        self.id = segment.id
        self.meetingId = segment.meetingId
        self.speakerId = segment.speakerId
        self.audioSourceRaw = segment.audioSource.rawValue
        self.originalLanguage = segment.originalLanguage
        self.sourceLanguage = segment.sourceLanguage
        self.targetLanguage = segment.targetLanguage
        self.translatedLanguage = segment.translatedLanguage
        self.translationPhaseRaw = segment.translationPhase?.rawValue
        self.translationConfidence = segment.translationConfidence
        self.translationStateRaw = segment.translationState.rawValue
        self.transcriptionPhaseRaw = segment.transcriptionPhase?.rawValue
        self.transcriptionEngineRaw = segment.transcriptionEngine?.rawValue
        self.engineConfidence = segment.engineConfidence
        self.languageConfidence = segment.languageConfidence
        self.revisionOfSegmentId = segment.revisionOfSegmentId
        self.revisionNumber = segment.revisionNumber
        self.finalizedByRaw = segment.finalizedBy?.rawValue
        self.latencyMs = segment.latencyMs
        self.sourceFrameStart = segment.sourceFrameRange?.start
        self.sourceFrameEnd = segment.sourceFrameRange?.end
        self.audioEnergy = segment.audioEnergy
        self.stitchingConfidence = segment.stitchingConfidence
        self.retentionReasonRaw = segment.retentionReason?.rawValue
        self.startTime = segment.startTime
        self.endTime = segment.endTime
        self.confidence = segment.confidence
        self.isFinal = segment.isFinal
        self.createdAt = segment.createdAt
        self.speakerLabel = try cryptor.encryptString(segment.speakerLabel, context: Self.speakerLabelContext)
        self.text = try cryptor.encryptString(segment.text, context: Self.textContext)
        self.draftTranslatedText = try cryptor.encryptOptionalString(segment.draftTranslatedText, context: Self.draftTranslatedTextContext)
        self.translatedText = try cryptor.encryptOptionalString(segment.translatedText, context: Self.translatedTextContext)
        self.preservedTermsJSON = try cryptor.encryptString(
            encodedJSONString(segment.preservedTerms, encoder: JSONEncoder(), fallback: "[]"),
            context: Self.preservedTermsContext
        )
        self.wordTimestampsJSON = try cryptor.encryptString(
            encodedJSONString(segment.wordTimestamps, encoder: JSONEncoder(), fallback: "[]"),
            context: Self.wordTimestampsContext
        )
    }

    func update(from segment: TranscriptSegment, cryptor: LocalDataCryptor) throws {
        meetingId = segment.meetingId
        speakerId = segment.speakerId
        audioSourceRaw = segment.audioSource.rawValue
        originalLanguage = segment.originalLanguage
        sourceLanguage = segment.sourceLanguage
        targetLanguage = segment.targetLanguage
        translatedLanguage = segment.translatedLanguage
        translationPhaseRaw = segment.translationPhase?.rawValue
        translationConfidence = segment.translationConfidence
        translationStateRaw = segment.translationState.rawValue
        transcriptionPhaseRaw = segment.transcriptionPhase?.rawValue
        transcriptionEngineRaw = segment.transcriptionEngine?.rawValue
        engineConfidence = segment.engineConfidence
        languageConfidence = segment.languageConfidence
        revisionOfSegmentId = segment.revisionOfSegmentId
        revisionNumber = segment.revisionNumber
        finalizedByRaw = segment.finalizedBy?.rawValue
        latencyMs = segment.latencyMs
        sourceFrameStart = segment.sourceFrameRange?.start
        sourceFrameEnd = segment.sourceFrameRange?.end
        audioEnergy = segment.audioEnergy
        stitchingConfidence = segment.stitchingConfidence
        retentionReasonRaw = segment.retentionReason?.rawValue
        startTime = segment.startTime
        endTime = segment.endTime
        confidence = segment.confidence
        isFinal = segment.isFinal
        createdAt = segment.createdAt
        try updateEncryptedFields(from: segment, cryptor: cryptor)
    }

    func encryptSensitiveFieldsIfNeeded(cryptor: LocalDataCryptor) throws {
        speakerLabel = try cryptor.encryptStringIfNeeded(speakerLabel, context: Self.speakerLabelContext)
        text = try cryptor.encryptStringIfNeeded(text, context: Self.textContext)
        draftTranslatedText = try cryptor.encryptOptionalStringIfNeeded(draftTranslatedText, context: Self.draftTranslatedTextContext)
        translatedText = try cryptor.encryptOptionalStringIfNeeded(translatedText, context: Self.translatedTextContext)
        preservedTermsJSON = try cryptor.encryptOptionalStringIfNeeded(preservedTermsJSON, context: Self.preservedTermsContext)
        wordTimestampsJSON = try cryptor.encryptOptionalStringIfNeeded(wordTimestampsJSON, context: Self.wordTimestampsContext)
    }

    private func updateEncryptedFields(from segment: TranscriptSegment, cryptor: LocalDataCryptor) throws {
        speakerLabel = try cryptor.encryptString(segment.speakerLabel, context: Self.speakerLabelContext)
        text = try cryptor.encryptString(segment.text, context: Self.textContext)
        draftTranslatedText = try cryptor.encryptOptionalString(segment.draftTranslatedText, context: Self.draftTranslatedTextContext)
        translatedText = try cryptor.encryptOptionalString(segment.translatedText, context: Self.translatedTextContext)
        preservedTermsJSON = try cryptor.encryptString(
            encodedJSONString(segment.preservedTerms, encoder: JSONEncoder(), fallback: "[]"),
            context: Self.preservedTermsContext
        )
        wordTimestampsJSON = try cryptor.encryptString(
            encodedJSONString(segment.wordTimestamps, encoder: JSONEncoder(), fallback: "[]"),
            context: Self.wordTimestampsContext
        )
    }
}

@Model
final class StoredSummary {
    static let executiveSummaryContext = "StoredSummary.executiveSummary.v1"
    static let keyDecisionsContext = "StoredSummary.keyDecisionsJSON.v1"
    static let actionItemsContext = "StoredSummary.actionItemsJSON.v1"
    static let risksContext = "StoredSummary.risksJSON.v1"
    static let openQuestionsContext = "StoredSummary.openQuestionsJSON.v1"
    static let strategicInsightsContext = "StoredSummary.strategicInsightsJSON.v1"
    static let followUpsContext = "StoredSummary.followUpsJSON.v1"

    @Attribute(.unique) var id: UUID
    var meetingId: UUID
    var executiveSummary: String
    var keyDecisionsJSON: String
    var actionItemsJSON: String
    var risksJSON: String
    var openQuestionsJSON: String
    var strategicInsightsJSON: String
    var followUpsJSON: String
    var generatedAt: Date

    init(summary: MeetingSummary, encoder: JSONEncoder = JSONEncoder(), cryptor: LocalDataCryptor) throws {
        self.id = summary.id
        self.meetingId = summary.meetingId
        self.generatedAt = summary.generatedAt
        self.executiveSummary = try cryptor.encryptString(summary.executiveSummary, context: Self.executiveSummaryContext)
        self.keyDecisionsJSON = try cryptor.encryptString(encodedJSONString(summary.keyDecisions, encoder: encoder, fallback: "[]"), context: Self.keyDecisionsContext)
        self.actionItemsJSON = try cryptor.encryptString(encodedJSONString(summary.actionItems, encoder: encoder, fallback: "[]"), context: Self.actionItemsContext)
        self.risksJSON = try cryptor.encryptString(encodedJSONString(summary.risks, encoder: encoder, fallback: "[]"), context: Self.risksContext)
        self.openQuestionsJSON = try cryptor.encryptString(encodedJSONString(summary.openQuestions, encoder: encoder, fallback: "[]"), context: Self.openQuestionsContext)
        self.strategicInsightsJSON = try cryptor.encryptString(encodedJSONString(summary.strategicInsights, encoder: encoder, fallback: "[]"), context: Self.strategicInsightsContext)
        self.followUpsJSON = try cryptor.encryptString(encodedJSONString(summary.followUps, encoder: encoder, fallback: "[]"), context: Self.followUpsContext)
    }

    func encryptSensitiveFieldsIfNeeded(cryptor: LocalDataCryptor) throws {
        executiveSummary = try cryptor.encryptStringIfNeeded(executiveSummary, context: Self.executiveSummaryContext)
        keyDecisionsJSON = try cryptor.encryptStringIfNeeded(keyDecisionsJSON, context: Self.keyDecisionsContext)
        actionItemsJSON = try cryptor.encryptStringIfNeeded(actionItemsJSON, context: Self.actionItemsContext)
        risksJSON = try cryptor.encryptStringIfNeeded(risksJSON, context: Self.risksContext)
        openQuestionsJSON = try cryptor.encryptStringIfNeeded(openQuestionsJSON, context: Self.openQuestionsContext)
        strategicInsightsJSON = try cryptor.encryptStringIfNeeded(strategicInsightsJSON, context: Self.strategicInsightsContext)
        followUpsJSON = try cryptor.encryptStringIfNeeded(followUpsJSON, context: Self.followUpsContext)
    }
}

struct KnowledgeDocument: Identifiable, Sendable, Hashable {
    var id: UUID
    var displayName: String
    var filePath: String?
    var content: String
    var workspaceId: String
    var createdAt: Date
}

@Model
final class StoredKnowledgeDocument {
    static let displayNameContext = "StoredKnowledgeDocument.displayName.v1"
    static let filePathContext = "StoredKnowledgeDocument.filePath.v1"
    static let contentContext = "StoredKnowledgeDocument.content.v1"

    @Attribute(.unique) var id: UUID
    var displayName: String
    var filePath: String?
    var content: String
    var workspaceId: String = "default"
    var createdAt: Date

    init(id: UUID = UUID(), displayName: String, filePath: String? = nil, content: String, workspaceId: String = "default", createdAt: Date = Date(), cryptor: LocalDataCryptor) throws {
        self.id = id
        self.displayName = try cryptor.encryptString(displayName, context: Self.displayNameContext)
        self.filePath = try cryptor.encryptOptionalString(filePath, context: Self.filePathContext)
        self.content = try cryptor.encryptString(content, context: Self.contentContext)
        self.workspaceId = workspaceId
        self.createdAt = createdAt
    }

    func decrypt(cryptor: LocalDataCryptor) throws -> KnowledgeDocument {
        KnowledgeDocument(
            id: id,
            displayName: try cryptor.decryptString(displayName, context: Self.displayNameContext),
            filePath: try cryptor.decryptOptionalString(filePath, context: Self.filePathContext),
            content: try cryptor.decryptString(content, context: Self.contentContext),
            workspaceId: workspaceId,
            createdAt: createdAt
        )
    }

    func encryptSensitiveFieldsIfNeeded(cryptor: LocalDataCryptor) throws {
        displayName = try cryptor.encryptStringIfNeeded(displayName, context: Self.displayNameContext)
        filePath = try cryptor.encryptOptionalStringIfNeeded(filePath, context: Self.filePathContext)
        content = try cryptor.encryptStringIfNeeded(content, context: Self.contentContext)
    }
}

@Model
final class StoredKnowledgeSource {
    static let displayNameContext = "StoredKnowledgeSource.displayName.v1"
    static let rootPathContext = "StoredKnowledgeSource.rootPath.v1"
    static let bookmarkContext = "StoredKnowledgeSource.bookmarkDataBase64.v1"
    static let lastErrorContext = "StoredKnowledgeSource.lastError.v1"
    static let metadataContext = "StoredKnowledgeSource.metadataJSON.v1"

    @Attribute(.unique) var id: UUID
    var kindRaw: String
    var displayName: String
    var rootPath: String?
    var bookmarkDataBase64: String?
    var workspaceId: String
    var statusRaw: String
    var isEnabled: Bool
    var lastIndexedAt: Date?
    var lastError: String?
    var documentCount: Int
    var chunkCount: Int
    var sourceFingerprint: String?
    var metadataJSON: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        source: KnowledgeSource,
        metadata: [String: String] = [:],
        cryptor: LocalDataCryptor
    ) throws {
        id = source.id
        kindRaw = source.kind.rawValue
        displayName = try cryptor.encryptString(source.displayName, context: Self.displayNameContext)
        rootPath = try cryptor.encryptOptionalString(source.rootPath, context: Self.rootPathContext)
        bookmarkDataBase64 = try cryptor.encryptOptionalString(source.bookmarkData?.base64EncodedString(), context: Self.bookmarkContext)
        workspaceId = source.workspaceId
        statusRaw = source.status.rawValue
        isEnabled = source.isEnabled
        lastIndexedAt = source.lastIndexedAt
        lastError = try cryptor.encryptOptionalString(source.lastError, context: Self.lastErrorContext)
        documentCount = source.documentCount
        chunkCount = source.chunkCount
        sourceFingerprint = source.rootPath
        metadataJSON = try cryptor.encryptOptionalString(encodedJSONString(metadata, encoder: JSONEncoder(), fallback: "{}"), context: Self.metadataContext)
        createdAt = source.createdAt
        updatedAt = source.updatedAt
    }

    func update(from source: KnowledgeSource, metadata: [String: String] = [:], cryptor: LocalDataCryptor) throws {
        kindRaw = source.kind.rawValue
        displayName = try cryptor.encryptString(source.displayName, context: Self.displayNameContext)
        rootPath = try cryptor.encryptOptionalString(source.rootPath, context: Self.rootPathContext)
        bookmarkDataBase64 = try cryptor.encryptOptionalString(source.bookmarkData?.base64EncodedString(), context: Self.bookmarkContext)
        workspaceId = source.workspaceId
        statusRaw = source.status.rawValue
        isEnabled = source.isEnabled
        lastIndexedAt = source.lastIndexedAt
        lastError = try cryptor.encryptOptionalString(source.lastError, context: Self.lastErrorContext)
        documentCount = source.documentCount
        chunkCount = source.chunkCount
        sourceFingerprint = source.rootPath
        metadataJSON = try cryptor.encryptOptionalString(encodedJSONString(metadata, encoder: JSONEncoder(), fallback: "{}"), context: Self.metadataContext)
        updatedAt = source.updatedAt
    }

    func decrypt(cryptor: LocalDataCryptor) throws -> KnowledgeSource {
        let bookmarkBase64 = try cryptor.decryptOptionalString(bookmarkDataBase64, context: Self.bookmarkContext)
        return KnowledgeSource(
            id: id,
            kind: KnowledgeSourceKind(rawValue: kindRaw) ?? .legacy,
            displayName: try cryptor.decryptString(displayName, context: Self.displayNameContext),
            rootPath: try cryptor.decryptOptionalString(rootPath, context: Self.rootPathContext),
            bookmarkData: bookmarkBase64.flatMap { Data(base64Encoded: $0) },
            workspaceId: workspaceId,
            status: KnowledgeSourceStatus(rawValue: statusRaw) ?? .connected,
            isEnabled: isEnabled,
            lastIndexedAt: lastIndexedAt,
            lastError: try cryptor.decryptOptionalString(lastError, context: Self.lastErrorContext),
            documentCount: documentCount,
            chunkCount: chunkCount,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    func encryptSensitiveFieldsIfNeeded(cryptor: LocalDataCryptor) throws {
        displayName = try cryptor.encryptStringIfNeeded(displayName, context: Self.displayNameContext)
        rootPath = try cryptor.encryptOptionalStringIfNeeded(rootPath, context: Self.rootPathContext)
        bookmarkDataBase64 = try cryptor.encryptOptionalStringIfNeeded(bookmarkDataBase64, context: Self.bookmarkContext)
        lastError = try cryptor.encryptOptionalStringIfNeeded(lastError, context: Self.lastErrorContext)
        metadataJSON = try cryptor.encryptOptionalStringIfNeeded(metadataJSON, context: Self.metadataContext)
    }
}

@Model
final class StoredKnowledgeDocumentRecord {
    static let displayNameContext = "StoredKnowledgeDocumentRecord.displayName.v1"
    static let filePathContext = "StoredKnowledgeDocumentRecord.filePath.v1"
    static let metadataContext = "StoredKnowledgeDocumentRecord.metadataJSON.v1"

    @Attribute(.unique) var id: UUID
    var sourceId: UUID
    var displayName: String
    var filePath: String?
    var contentHash: String
    var fileSize: Int
    var modifiedAt: Date?
    var workspaceId: String
    var kindRaw: String
    var metadataJSON: String
    var createdAt: Date
    var updatedAt: Date

    init(document: KnowledgeDocumentRecord, encoder: JSONEncoder = JSONEncoder(), cryptor: LocalDataCryptor) throws {
        id = document.id
        sourceId = document.sourceId
        displayName = try cryptor.encryptString(document.displayName, context: Self.displayNameContext)
        filePath = try cryptor.encryptOptionalString(document.filePath, context: Self.filePathContext)
        contentHash = document.contentHash
        fileSize = document.fileSize
        modifiedAt = document.modifiedAt
        workspaceId = document.workspaceId
        kindRaw = document.kind.rawValue
        metadataJSON = try cryptor.encryptString(encodedJSONString(document.metadata, encoder: encoder, fallback: "{}"), context: Self.metadataContext)
        createdAt = document.createdAt
        updatedAt = document.updatedAt
    }

    func update(from document: KnowledgeDocumentRecord, encoder: JSONEncoder = JSONEncoder(), cryptor: LocalDataCryptor) throws {
        sourceId = document.sourceId
        displayName = try cryptor.encryptString(document.displayName, context: Self.displayNameContext)
        filePath = try cryptor.encryptOptionalString(document.filePath, context: Self.filePathContext)
        contentHash = document.contentHash
        fileSize = document.fileSize
        modifiedAt = document.modifiedAt
        workspaceId = document.workspaceId
        kindRaw = document.kind.rawValue
        metadataJSON = try cryptor.encryptString(encodedJSONString(document.metadata, encoder: encoder, fallback: "{}"), context: Self.metadataContext)
        updatedAt = document.updatedAt
    }

    func decrypt(cryptor: LocalDataCryptor) throws -> KnowledgeDocumentRecord {
        let metadataString = try cryptor.decryptString(metadataJSON, context: Self.metadataContext)
        let metadata = (try? JSONDecoder().decode([String: String].self, from: Data(metadataString.utf8))) ?? [:]
        return KnowledgeDocumentRecord(
            id: id,
            sourceId: sourceId,
            displayName: try cryptor.decryptString(displayName, context: Self.displayNameContext),
            filePath: try cryptor.decryptOptionalString(filePath, context: Self.filePathContext),
            contentHash: contentHash,
            fileSize: fileSize,
            modifiedAt: modifiedAt,
            workspaceId: workspaceId,
            kind: KnowledgeDocumentKind(rawValue: kindRaw) ?? .unknown,
            metadata: metadata,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    func encryptSensitiveFieldsIfNeeded(cryptor: LocalDataCryptor) throws {
        displayName = try cryptor.encryptStringIfNeeded(displayName, context: Self.displayNameContext)
        filePath = try cryptor.encryptOptionalStringIfNeeded(filePath, context: Self.filePathContext)
        metadataJSON = try cryptor.encryptStringIfNeeded(metadataJSON, context: Self.metadataContext)
    }
}

@Model
final class StoredKnowledgeChunk {
    static let headingContext = "StoredKnowledgeChunk.heading.v1"
    static let contentContext = "StoredKnowledgeChunk.content.v1"
    static let locationLabelContext = "StoredKnowledgeChunk.locationLabel.v1"

    @Attribute(.unique) var id: UUID
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

    init(chunk: KnowledgeChunkRecord, cryptor: LocalDataCryptor) throws {
        id = chunk.id
        documentId = chunk.documentId
        sourceId = chunk.sourceId
        sequence = chunk.sequence
        heading = try cryptor.encryptOptionalString(chunk.heading, context: Self.headingContext)
        content = try cryptor.encryptString(chunk.content, context: Self.contentContext)
        tokenEstimate = chunk.tokenEstimate
        locationLabel = try cryptor.encryptOptionalString(chunk.locationLabel, context: Self.locationLabelContext)
        contentHash = chunk.contentHash
        workspaceId = chunk.workspaceId
        createdAt = chunk.createdAt
        updatedAt = chunk.updatedAt
    }

    func update(from chunk: KnowledgeChunkRecord, cryptor: LocalDataCryptor) throws {
        documentId = chunk.documentId
        sourceId = chunk.sourceId
        sequence = chunk.sequence
        heading = try cryptor.encryptOptionalString(chunk.heading, context: Self.headingContext)
        content = try cryptor.encryptString(chunk.content, context: Self.contentContext)
        tokenEstimate = chunk.tokenEstimate
        locationLabel = try cryptor.encryptOptionalString(chunk.locationLabel, context: Self.locationLabelContext)
        contentHash = chunk.contentHash
        workspaceId = chunk.workspaceId
        updatedAt = chunk.updatedAt
    }

    func decrypt(cryptor: LocalDataCryptor) throws -> KnowledgeChunkRecord {
        KnowledgeChunkRecord(
            id: id,
            documentId: documentId,
            sourceId: sourceId,
            sequence: sequence,
            heading: try cryptor.decryptOptionalString(heading, context: Self.headingContext),
            content: try cryptor.decryptString(content, context: Self.contentContext),
            tokenEstimate: tokenEstimate,
            locationLabel: try cryptor.decryptOptionalString(locationLabel, context: Self.locationLabelContext),
            contentHash: contentHash,
            workspaceId: workspaceId,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    func encryptSensitiveFieldsIfNeeded(cryptor: LocalDataCryptor) throws {
        heading = try cryptor.encryptOptionalStringIfNeeded(heading, context: Self.headingContext)
        content = try cryptor.encryptStringIfNeeded(content, context: Self.contentContext)
        locationLabel = try cryptor.encryptOptionalStringIfNeeded(locationLabel, context: Self.locationLabelContext)
    }
}

@Model
final class StoredKnowledgeEmbeddingRecord {
    static let vectorContext = "StoredKnowledgeEmbeddingRecord.vectorData.v2"

    @Attribute(.unique) var id: UUID
    var chunkId: UUID
    var model: String
    var contentHash: String
    var dimensions: Int
    var quantization: String
    var vectorData: Data
    var createdAt: Date

    init(embedding: KnowledgeEmbeddingRecord, cryptor: LocalDataCryptor, sidecarKey: String? = nil) throws {
        id = embedding.id
        chunkId = embedding.chunkId
        model = embedding.model
        contentHash = embedding.contentHash
        dimensions = embedding.dimensions
        if let sidecarKey {
            quantization = LocalVectorBlobStore.quantization
            vectorData = try cryptor.encryptData(Data(sidecarKey.utf8), context: Self.vectorContext)
        } else {
            quantization = "float16"
            vectorData = try cryptor.encryptData(Self.encodeVector(embedding.vector), context: Self.vectorContext)
        }
        createdAt = embedding.createdAt
    }

    func decrypt(cryptor: LocalDataCryptor) throws -> KnowledgeEmbeddingRecord {
        let data = try cryptor.decryptData(vectorData, context: Self.vectorContext)
        if quantization == LocalVectorBlobStore.quantization {
            return KnowledgeEmbeddingRecord(id: id, chunkId: chunkId, model: model, contentHash: contentHash, dimensions: dimensions, vector: [], createdAt: createdAt)
        }
        let vector = Self.decodeVector(data, dimensions: dimensions, quantization: quantization)
        return KnowledgeEmbeddingRecord(id: id, chunkId: chunkId, model: model, contentHash: contentHash, dimensions: dimensions, vector: vector, createdAt: createdAt)
    }

    func sidecarKey(cryptor: LocalDataCryptor) throws -> String? {
        guard quantization == LocalVectorBlobStore.quantization else { return nil }
        let data = try cryptor.decryptData(vectorData, context: Self.vectorContext)
        return String(data: data, encoding: .utf8)
    }

    func encryptSensitiveFieldsIfNeeded(cryptor: LocalDataCryptor) throws {
        vectorData = try cryptor.encryptDataIfNeeded(vectorData, context: Self.vectorContext)
    }

    private static func encodeVector(_ vector: [Double]) -> Data {
        var data = Data(capacity: vector.count * MemoryLayout<UInt16>.size)
        for value in vector {
            var bits = Float16(value).bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func decodeVector(_ data: Data, dimensions: Int, quantization: String) -> [Double] {
        guard !data.isEmpty else { return [] }
        if quantization == "float32" || data.count == dimensions * MemoryLayout<Float>.size {
            return decodeFloat32Vector(data, dimensions: dimensions)
        }
        let count = min(dimensions, data.count / MemoryLayout<Float>.size)
        if quantization != "float16", count == dimensions {
            return decodeFloat32Vector(data, dimensions: dimensions)
        }
        return decodeFloat16Vector(data, dimensions: dimensions)
    }

    private static func decodeFloat16Vector(_ data: Data, dimensions: Int) -> [Double] {
        let count = min(dimensions, data.count / MemoryLayout<UInt16>.size)
        var vector: [Double] = []
        vector.reserveCapacity(count)
        for index in 0..<count {
            let offset = index * MemoryLayout<UInt16>.size
            var bits: UInt16 = 0
            for byteIndex in 0..<MemoryLayout<UInt16>.size {
                bits |= UInt16(data[offset + byteIndex]) << UInt16(byteIndex * 8)
            }
            vector.append(Double(Float16(bitPattern: UInt16(littleEndian: bits))))
        }
        return vector
    }

    private static func decodeFloat32Vector(_ data: Data, dimensions: Int) -> [Double] {
        let count = min(dimensions, data.count / MemoryLayout<Float>.size)
        var vector: [Double] = []
        vector.reserveCapacity(count)
        for index in 0..<count {
            let offset = index * MemoryLayout<Float>.size
            var bits: UInt32 = 0
            for byteIndex in 0..<MemoryLayout<Float>.size {
                bits |= UInt32(data[offset + byteIndex]) << UInt32(byteIndex * 8)
            }
            vector.append(Double(Float(bitPattern: bits)))
        }
        return vector
    }
}

@Model
final class StoredRetrievalTrace {
    static let queryContext = "StoredRetrievalTrace.query.v1"
    static let resultContext = "StoredRetrievalTrace.resultJSON.v1"

    @Attribute(.unique) var id: UUID
    var queryHash: String
    var query: String
    var workspaceId: String
    var resultJSON: String
    var latencyMs: Int
    var createdAt: Date

    init(id: UUID = UUID(), queryHash: String, query: String, workspaceId: String, resultJSON: String, latencyMs: Int, createdAt: Date = Date(), cryptor: LocalDataCryptor) throws {
        self.id = id
        self.queryHash = queryHash
        self.query = try cryptor.encryptString(query, context: Self.queryContext)
        self.workspaceId = workspaceId
        self.resultJSON = try cryptor.encryptString(resultJSON, context: Self.resultContext)
        self.latencyMs = latencyMs
        self.createdAt = createdAt
    }

    func encryptSensitiveFieldsIfNeeded(cryptor: LocalDataCryptor) throws {
        query = try cryptor.encryptStringIfNeeded(query, context: Self.queryContext)
        resultJSON = try cryptor.encryptStringIfNeeded(resultJSON, context: Self.resultContext)
    }
}

@Model
final class StoredSpeechVocabularyTerm {
    static let textContext = "StoredSpeechVocabularyTerm.text.v1"
    static let aliasesContext = "StoredSpeechVocabularyTerm.aliasesJSON.v1"
    static let pronunciationContext = "StoredSpeechVocabularyTerm.pronunciationXSAMPA.v1"
    static let notesContext = "StoredSpeechVocabularyTerm.notes.v1"
    static let templatePatternContext = "StoredSpeechVocabularyTerm.templatePattern.v1"
    static let templateSlotsContext = "StoredSpeechVocabularyTerm.templateSlotsJSON.v1"

    @Attribute(.unique) var id: UUID
    var text: String
    var normalizedText: String
    var locale: String?
    var categoryRaw: String
    var aliasesJSON: String
    var pronunciationXSAMPA: String?
    var boost: Double
    var scopeRaw: String
    var scopeValue: String?
    var enabled: Bool
    var isSystemSeed: Bool
    var notes: String?
    var templatePattern: String?
    var templateSlotsJSON: String?
    var correctionCount: Int = 0
    var lastCorrectionAt: Date?
    var createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?
    var useCount: Int

    init(term: SpeechVocabularyTerm, cryptor: LocalDataCryptor) throws {
        id = term.id
        normalizedText = term.normalizedText
        locale = term.locale
        categoryRaw = term.category.rawValue
        boost = term.boost
        scopeRaw = term.scope.rawValue
        scopeValue = term.scopeValue
        enabled = term.enabled
        isSystemSeed = term.isSystemSeed
        correctionCount = term.correctionCount
        lastCorrectionAt = term.lastCorrectionAt
        createdAt = term.createdAt
        updatedAt = term.updatedAt
        lastUsedAt = term.lastUsedAt
        useCount = term.useCount
        text = try cryptor.encryptString(term.text, context: Self.textContext)
        aliasesJSON = try cryptor.encryptString(
            encodedJSONString(term.aliases, encoder: JSONEncoder(), fallback: "[]"),
            context: Self.aliasesContext
        )
        pronunciationXSAMPA = try cryptor.encryptOptionalString(term.pronunciationXSAMPA, context: Self.pronunciationContext)
        notes = try cryptor.encryptOptionalString(term.notes, context: Self.notesContext)
        templatePattern = try cryptor.encryptOptionalString(term.templatePattern, context: Self.templatePatternContext)
        templateSlotsJSON = try cryptor.encryptOptionalString(
            encodedJSONString(term.templateSlots, encoder: JSONEncoder(), fallback: "[]"),
            context: Self.templateSlotsContext
        )
    }

    func update(from term: SpeechVocabularyTerm, cryptor: LocalDataCryptor) throws {
        normalizedText = term.normalizedText
        locale = term.locale
        categoryRaw = term.category.rawValue
        boost = term.boost
        scopeRaw = term.scope.rawValue
        scopeValue = term.scopeValue
        enabled = term.enabled
        isSystemSeed = term.isSystemSeed
        correctionCount = term.correctionCount
        lastCorrectionAt = term.lastCorrectionAt
        createdAt = term.createdAt
        updatedAt = term.updatedAt
        lastUsedAt = term.lastUsedAt
        useCount = term.useCount
        try updateEncryptedFields(from: term, cryptor: cryptor)
    }

    func decrypt(cryptor: LocalDataCryptor) throws -> SpeechVocabularyTerm {
        let aliasesJSON = try cryptor.decryptString(aliasesJSON, context: Self.aliasesContext)
        let templateSlotsJSON = try cryptor.decryptOptionalString(templateSlotsJSON, context: Self.templateSlotsContext) ?? "[]"
        return SpeechVocabularyTerm(
            id: id,
            text: try cryptor.decryptString(text, context: Self.textContext),
            locale: locale,
            category: SpeechVocabularyCategory(rawValue: categoryRaw) ?? .custom,
            aliases: decodeStringArray(aliasesJSON),
            pronunciationXSAMPA: try cryptor.decryptOptionalString(pronunciationXSAMPA, context: Self.pronunciationContext),
            boost: boost,
            scope: SpeechVocabularyScope(rawValue: scopeRaw) ?? .global,
            scopeValue: scopeValue,
            enabled: enabled,
            isSystemSeed: isSystemSeed,
            notes: try cryptor.decryptOptionalString(notes, context: Self.notesContext),
            templatePattern: try cryptor.decryptOptionalString(templatePattern, context: Self.templatePatternContext),
            templateSlots: decodeStringArray(templateSlotsJSON),
            correctionCount: correctionCount,
            lastCorrectionAt: lastCorrectionAt,
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastUsedAt: lastUsedAt,
            useCount: useCount
        )
    }

    func encryptSensitiveFieldsIfNeeded(cryptor: LocalDataCryptor) throws {
        text = try cryptor.encryptStringIfNeeded(text, context: Self.textContext)
        aliasesJSON = try cryptor.encryptStringIfNeeded(aliasesJSON, context: Self.aliasesContext)
        pronunciationXSAMPA = try cryptor.encryptOptionalStringIfNeeded(pronunciationXSAMPA, context: Self.pronunciationContext)
        notes = try cryptor.encryptOptionalStringIfNeeded(notes, context: Self.notesContext)
        templatePattern = try cryptor.encryptOptionalStringIfNeeded(templatePattern, context: Self.templatePatternContext)
        templateSlotsJSON = try cryptor.encryptOptionalStringIfNeeded(templateSlotsJSON, context: Self.templateSlotsContext)
    }

    private func updateEncryptedFields(from term: SpeechVocabularyTerm, cryptor: LocalDataCryptor) throws {
        text = try cryptor.encryptString(term.text, context: Self.textContext)
        aliasesJSON = try cryptor.encryptString(
            encodedJSONString(term.aliases, encoder: JSONEncoder(), fallback: "[]"),
            context: Self.aliasesContext
        )
        pronunciationXSAMPA = try cryptor.encryptOptionalString(term.pronunciationXSAMPA, context: Self.pronunciationContext)
        notes = try cryptor.encryptOptionalString(term.notes, context: Self.notesContext)
        templatePattern = try cryptor.encryptOptionalString(term.templatePattern, context: Self.templatePatternContext)
        templateSlotsJSON = try cryptor.encryptOptionalString(
            encodedJSONString(term.templateSlots, encoder: JSONEncoder(), fallback: "[]"),
            context: Self.templateSlotsContext
        )
    }
}

@Model
final class StoredQuestionAnswerRecord {
    static let questionContext = "StoredQuestionAnswerRecord.questionJSON.v1"
    static let classificationContext = "StoredQuestionAnswerRecord.classificationJSON.v1"
    static let answerContext = "StoredQuestionAnswerRecord.answerJSON.v1"
    static let contextSummaryContext = "StoredQuestionAnswerRecord.contextSummary.v1"
    static let sourcesContext = "StoredQuestionAnswerRecord.sourcesJSON.v1"
    static let decisionContext = "StoredQuestionAnswerRecord.decision.v1"
    static let feedbackContext = "StoredQuestionAnswerRecord.feedbackJSON.v1"

    @Attribute(.unique) var id: UUID
    var meetingId: UUID
    var questionJSON: String
    var classificationJSON: String
    var answerJSON: String?
    var contextSummary: String
    var sourcesJSON: String
    var decision: String
    var feedbackJSON: String
    var createdAt: Date
    var updatedAt: Date

    init(record: QuestionAnswerRecord, encoder: JSONEncoder = JSONEncoder(), cryptor: LocalDataCryptor) throws {
        self.id = record.id
        self.meetingId = record.meetingId
        self.createdAt = record.createdAt
        self.updatedAt = record.updatedAt
        self.questionJSON = try cryptor.encryptString(encodedJSONString(record.question, encoder: encoder, fallback: "{}"), context: Self.questionContext)
        self.classificationJSON = try cryptor.encryptString(encodedJSONString(record.classification, encoder: encoder, fallback: "{}"), context: Self.classificationContext)
        self.answerJSON = try record.answer.map { try cryptor.encryptString(encodedJSONString($0, encoder: encoder, fallback: "{}"), context: Self.answerContext) }
        self.contextSummary = try cryptor.encryptString(record.contextSummary, context: Self.contextSummaryContext)
        self.sourcesJSON = try cryptor.encryptString(encodedJSONString(record.sources, encoder: encoder, fallback: "[]"), context: Self.sourcesContext)
        self.decision = try cryptor.encryptString(record.decision, context: Self.decisionContext)
        self.feedbackJSON = try cryptor.encryptString(encodedJSONString(record.feedbackEvents, encoder: encoder, fallback: "[]"), context: Self.feedbackContext)
    }

    func update(from record: QuestionAnswerRecord, encoder: JSONEncoder = JSONEncoder(), cryptor: LocalDataCryptor) throws {
        meetingId = record.meetingId
        updatedAt = record.updatedAt
        try updateEncryptedFields(from: record, encoder: encoder, cryptor: cryptor)
    }

    func encryptSensitiveFieldsIfNeeded(cryptor: LocalDataCryptor) throws {
        questionJSON = try cryptor.encryptStringIfNeeded(questionJSON, context: Self.questionContext)
        classificationJSON = try cryptor.encryptStringIfNeeded(classificationJSON, context: Self.classificationContext)
        answerJSON = try cryptor.encryptOptionalStringIfNeeded(answerJSON, context: Self.answerContext)
        contextSummary = try cryptor.encryptStringIfNeeded(contextSummary, context: Self.contextSummaryContext)
        sourcesJSON = try cryptor.encryptStringIfNeeded(sourcesJSON, context: Self.sourcesContext)
        decision = try cryptor.encryptStringIfNeeded(decision, context: Self.decisionContext)
        feedbackJSON = try cryptor.encryptStringIfNeeded(feedbackJSON, context: Self.feedbackContext)
    }

    private func updateEncryptedFields(from record: QuestionAnswerRecord, encoder: JSONEncoder, cryptor: LocalDataCryptor) throws {
        questionJSON = try cryptor.encryptString(encodedJSONString(record.question, encoder: encoder, fallback: "{}"), context: Self.questionContext)
        classificationJSON = try cryptor.encryptString(encodedJSONString(record.classification, encoder: encoder, fallback: "{}"), context: Self.classificationContext)
        answerJSON = try record.answer.map { try cryptor.encryptString(encodedJSONString($0, encoder: encoder, fallback: "{}"), context: Self.answerContext) }
        contextSummary = try cryptor.encryptString(record.contextSummary, context: Self.contextSummaryContext)
        sourcesJSON = try cryptor.encryptString(encodedJSONString(record.sources, encoder: encoder, fallback: "[]"), context: Self.sourcesContext)
        decision = try cryptor.encryptString(record.decision, context: Self.decisionContext)
        feedbackJSON = try cryptor.encryptString(encodedJSONString(record.feedbackEvents, encoder: encoder, fallback: "[]"), context: Self.feedbackContext)
    }
}

@Model
final class StoredCopilotInteraction {
    static let promptContext = "StoredCopilotInteraction.prompt.v1"
    static let responseContext = "StoredCopilotInteraction.response.v1"
    static let sourcesContext = "StoredCopilotInteraction.sourcesJSON.v1"
    static let richAnswerContext = "StoredCopilotInteraction.richAnswerJSON.v1"
    static let feedbackContext = "StoredCopilotInteraction.feedbackJSON.v1"

    @Attribute(.unique) var id: UUID
    var contextKindRaw: String
    var sourceRaw: String
    var questionId: UUID?
    var prompt: String
    var response: String
    var toolRaw: String
    var intentRaw: String
    var languageCode: String?
    var confidence: Double
    var latencyMs: Int
    var sourcesJSON: String
    var richAnswerJSON: String?
    var feedbackJSON: String
    var createdAt: Date
    var expiresAt: Date

    init(interaction: CopilotInteraction, encoder: JSONEncoder = JSONEncoder(), cryptor: LocalDataCryptor) throws {
        self.id = interaction.id
        self.createdAt = interaction.createdAt
        self.expiresAt = interaction.expiresAt
        self.contextKindRaw = interaction.contextKind.rawValue
        self.sourceRaw = interaction.source.rawValue
        self.questionId = interaction.questionId
        self.toolRaw = interaction.tool.rawValue
        self.intentRaw = interaction.intent.rawValue
        self.languageCode = interaction.languageCode
        self.confidence = interaction.confidence
        self.latencyMs = interaction.latencyMs
        self.prompt = try cryptor.encryptString(interaction.prompt, context: Self.promptContext)
        self.response = try cryptor.encryptString(interaction.response, context: Self.responseContext)
        self.sourcesJSON = try cryptor.encryptString(encodedJSONString(interaction.sources, encoder: encoder, fallback: "[]"), context: Self.sourcesContext)
        self.richAnswerJSON = try interaction.richAnswer.map { try cryptor.encryptString(encodedJSONString($0, encoder: encoder, fallback: "{}"), context: Self.richAnswerContext) }
        self.feedbackJSON = try cryptor.encryptString(encodedJSONString(interaction.feedbackEvents, encoder: encoder, fallback: "[]"), context: Self.feedbackContext)
    }

    func update(from interaction: CopilotInteraction, encoder: JSONEncoder = JSONEncoder(), cryptor: LocalDataCryptor) throws {
        contextKindRaw = interaction.contextKind.rawValue
        sourceRaw = interaction.source.rawValue
        questionId = interaction.questionId
        toolRaw = interaction.tool.rawValue
        intentRaw = interaction.intent.rawValue
        languageCode = interaction.languageCode
        confidence = interaction.confidence
        latencyMs = interaction.latencyMs
        createdAt = interaction.createdAt
        expiresAt = interaction.expiresAt
        try updateEncryptedFields(from: interaction, encoder: encoder, cryptor: cryptor)
    }

    func encryptSensitiveFieldsIfNeeded(cryptor: LocalDataCryptor) throws {
        prompt = try cryptor.encryptStringIfNeeded(prompt, context: Self.promptContext)
        response = try cryptor.encryptStringIfNeeded(response, context: Self.responseContext)
        sourcesJSON = try cryptor.encryptStringIfNeeded(sourcesJSON, context: Self.sourcesContext)
        richAnswerJSON = try cryptor.encryptOptionalStringIfNeeded(richAnswerJSON, context: Self.richAnswerContext)
        feedbackJSON = try cryptor.encryptStringIfNeeded(feedbackJSON, context: Self.feedbackContext)
    }

    private func updateEncryptedFields(from interaction: CopilotInteraction, encoder: JSONEncoder, cryptor: LocalDataCryptor) throws {
        prompt = try cryptor.encryptString(interaction.prompt, context: Self.promptContext)
        response = try cryptor.encryptString(interaction.response, context: Self.responseContext)
        sourcesJSON = try cryptor.encryptString(encodedJSONString(interaction.sources, encoder: encoder, fallback: "[]"), context: Self.sourcesContext)
        richAnswerJSON = try interaction.richAnswer.map { try cryptor.encryptString(encodedJSONString($0, encoder: encoder, fallback: "{}"), context: Self.richAnswerContext) }
        feedbackJSON = try cryptor.encryptString(encodedJSONString(interaction.feedbackEvents, encoder: encoder, fallback: "[]"), context: Self.feedbackContext)
    }
}

@Model
final class StoredCopilotMemoryEntry {
    static let textContext = "StoredCopilotMemoryEntry.text.v1"

    @Attribute(.unique) var id: UUID
    var text: String
    var languageCode: String?
    var sourceInteractionId: UUID?
    var createdAt: Date
    var expiresAt: Date

    init(entry: CopilotMemoryEntry, cryptor: LocalDataCryptor) throws {
        self.id = entry.id
        self.text = try cryptor.encryptString(entry.text, context: Self.textContext)
        self.languageCode = entry.languageCode
        self.sourceInteractionId = entry.sourceInteractionId
        self.createdAt = entry.createdAt
        self.expiresAt = entry.expiresAt
    }

    func update(from entry: CopilotMemoryEntry, cryptor: LocalDataCryptor) throws {
        text = try cryptor.encryptString(entry.text, context: Self.textContext)
        languageCode = entry.languageCode
        sourceInteractionId = entry.sourceInteractionId
        createdAt = entry.createdAt
        expiresAt = entry.expiresAt
    }

    func encryptSensitiveFieldsIfNeeded(cryptor: LocalDataCryptor) throws {
        text = try cryptor.encryptStringIfNeeded(text, context: Self.textContext)
    }
}

@Model
final class StoredCopilotReminder {
    static let titleContext = "StoredCopilotReminder.title.v1"
    static let notificationIdContext = "StoredCopilotReminder.notificationId.v1"

    @Attribute(.unique) var id: UUID
    var title: String
    var scheduledAt: Date
    var notificationId: String
    var statusRaw: String
    var createdAt: Date
    var expiresAt: Date

    init(reminder: CopilotReminder, cryptor: LocalDataCryptor) throws {
        self.id = reminder.id
        self.scheduledAt = reminder.scheduledAt
        self.statusRaw = reminder.status.rawValue
        self.createdAt = reminder.createdAt
        self.expiresAt = reminder.expiresAt
        self.title = try cryptor.encryptString(reminder.title, context: Self.titleContext)
        self.notificationId = try cryptor.encryptString(reminder.notificationId, context: Self.notificationIdContext)
    }

    func update(from reminder: CopilotReminder, cryptor: LocalDataCryptor) throws {
        title = try cryptor.encryptString(reminder.title, context: Self.titleContext)
        scheduledAt = reminder.scheduledAt
        notificationId = try cryptor.encryptString(reminder.notificationId, context: Self.notificationIdContext)
        statusRaw = reminder.status.rawValue
        createdAt = reminder.createdAt
        expiresAt = reminder.expiresAt
    }

    func encryptSensitiveFieldsIfNeeded(cryptor: LocalDataCryptor) throws {
        title = try cryptor.encryptStringIfNeeded(title, context: Self.titleContext)
        notificationId = try cryptor.encryptStringIfNeeded(notificationId, context: Self.notificationIdContext)
    }
}

enum DatabaseFactory {
    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([
            StoredMeeting.self,
            StoredTranscriptSegment.self,
            StoredSummary.self,
            StoredKnowledgeDocument.self,
            StoredKnowledgeSource.self,
            StoredKnowledgeDocumentRecord.self,
            StoredKnowledgeChunk.self,
            StoredKnowledgeEmbeddingRecord.self,
            StoredRetrievalTrace.self,
            StoredSpeechVocabularyTerm.self,
            StoredQuestionAnswerRecord.self,
            StoredCopilotInteraction.self,
            StoredCopilotMemoryEntry.self,
            StoredCopilotReminder.self
        ])
        if inMemory {
            return try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }
        let url = try FileStorageService.applicationSupportDirectory().appending(path: "database.sqlite")
        let configuration = ModelConfiguration(url: url)
        return try ModelContainer(for: schema, configurations: configuration)
    }
}

private func encodedJSONString<T: Encodable>(_ value: T, encoder: JSONEncoder, fallback: String) -> String {
    (try? String(data: encoder.encode(value), encoding: .utf8)) ?? fallback
}

private func decodeStringArray(_ value: String?) -> [String] {
    guard let value, let data = value.data(using: .utf8) else { return [] }
    return (try? JSONDecoder().decode([String].self, from: data)) ?? []
}
