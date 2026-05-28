import Foundation
import SwiftData

@MainActor
final class MeetingRepository {
    private let context: ModelContext
    private let cryptor: LocalDataCryptor
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(container: ModelContainer, cryptor: LocalDataCryptor = .defaultOrCrash()) {
        self.context = ModelContext(container)
        self.cryptor = cryptor
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func save(_ session: MeetingSession) throws {
        let meetings = try context.fetch(FetchDescriptor<StoredMeeting>())
        if let stored = meetings.first(where: { $0.id == session.id }) {
            try stored.update(from: session, encoder: encoder, cryptor: cryptor)
        } else {
            context.insert(try StoredMeeting(session: session, encoder: encoder, cryptor: cryptor))
        }

        let allSegments = try context.fetch(FetchDescriptor<StoredTranscriptSegment>())
        let existingSegments = Dictionary(uniqueKeysWithValues: allSegments.filter { $0.meetingId == session.id }.map { ($0.id, $0) })
        for segment in session.transcriptSegments {
            if let storedSegment = existingSegments[segment.id] {
                try storedSegment.update(from: segment, cryptor: cryptor)
            } else {
                context.insert(try StoredTranscriptSegment(segment: segment, cryptor: cryptor))
            }
        }

        let allSummaries = try context.fetch(FetchDescriptor<StoredSummary>())
        for storedSummary in allSummaries where storedSummary.meetingId == session.id {
            context.delete(storedSummary)
        }
        if let summary = session.summary {
            context.insert(try StoredSummary(summary: summary, encoder: encoder, cryptor: cryptor))
        }

        try context.save()
    }

    func migrateEncryptedFields() throws {
        for meeting in try context.fetch(FetchDescriptor<StoredMeeting>()) {
            try meeting.encryptSensitiveFieldsIfNeeded(cryptor: cryptor)
        }
        for segment in try context.fetch(FetchDescriptor<StoredTranscriptSegment>()) {
            try segment.encryptSensitiveFieldsIfNeeded(cryptor: cryptor)
        }
        for summary in try context.fetch(FetchDescriptor<StoredSummary>()) {
            try summary.encryptSensitiveFieldsIfNeeded(cryptor: cryptor)
        }
        for speechTerm in try context.fetch(FetchDescriptor<StoredSpeechVocabularyTerm>()) {
            try speechTerm.encryptSensitiveFieldsIfNeeded(cryptor: cryptor)
        }
        for record in try context.fetch(FetchDescriptor<StoredQuestionAnswerRecord>()) {
            try record.encryptSensitiveFieldsIfNeeded(cryptor: cryptor)
        }
        for interaction in try context.fetch(FetchDescriptor<StoredCopilotInteraction>()) {
            try interaction.encryptSensitiveFieldsIfNeeded(cryptor: cryptor)
        }
        for memoryEntry in try context.fetch(FetchDescriptor<StoredCopilotMemoryEntry>()) {
            try memoryEntry.encryptSensitiveFieldsIfNeeded(cryptor: cryptor)
        }
        for reminder in try context.fetch(FetchDescriptor<StoredCopilotReminder>()) {
            try reminder.encryptSensitiveFieldsIfNeeded(cryptor: cryptor)
        }
        try context.save()
    }

    func fetchMeetings() throws -> [MeetingSession] {
        let storedMeetings = try context.fetch(FetchDescriptor<StoredMeeting>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)]))
        let storedSegments = try context.fetch(FetchDescriptor<StoredTranscriptSegment>())
        let storedSummaries = try context.fetch(FetchDescriptor<StoredSummary>())
        return try storedMeetings.map { stored in
            let segments = try storedSegments
                .filter { $0.meetingId == stored.id }
                .sorted { $0.startTime < $1.startTime }
                .map { try Self.mapSegment($0, cryptor: cryptor) }
            let summary = try storedSummaries.first(where: { $0.meetingId == stored.id }).map { try mapSummary($0) }
            return try mapMeeting(stored, segments: segments, summary: summary)
        }
    }

    func delete(_ session: MeetingSession) throws {
        for meeting in try context.fetch(FetchDescriptor<StoredMeeting>()) where meeting.id == session.id {
            context.delete(meeting)
        }
        for segment in try context.fetch(FetchDescriptor<StoredTranscriptSegment>()) where segment.meetingId == session.id {
            context.delete(segment)
        }
        for summary in try context.fetch(FetchDescriptor<StoredSummary>()) where summary.meetingId == session.id {
            context.delete(summary)
        }
        try context.save()
    }

    func deleteAll() throws {
        for meeting in try context.fetch(FetchDescriptor<StoredMeeting>()) { context.delete(meeting) }
        for segment in try context.fetch(FetchDescriptor<StoredTranscriptSegment>()) { context.delete(segment) }
        for summary in try context.fetch(FetchDescriptor<StoredSummary>()) { context.delete(summary) }
        for document in try context.fetch(FetchDescriptor<StoredKnowledgeDocument>()) { context.delete(document) }
        for speechTerm in try context.fetch(FetchDescriptor<StoredSpeechVocabularyTerm>()) { context.delete(speechTerm) }
        for record in try context.fetch(FetchDescriptor<StoredQuestionAnswerRecord>()) { context.delete(record) }
        for interaction in try context.fetch(FetchDescriptor<StoredCopilotInteraction>()) { context.delete(interaction) }
        for memoryEntry in try context.fetch(FetchDescriptor<StoredCopilotMemoryEntry>()) { context.delete(memoryEntry) }
        for reminder in try context.fetch(FetchDescriptor<StoredCopilotReminder>()) { context.delete(reminder) }
        try context.save()
    }

    func saveQuestionAnswerRecord(_ record: QuestionAnswerRecord) throws {
        let records = try context.fetch(FetchDescriptor<StoredQuestionAnswerRecord>())
        if let stored = records.first(where: { $0.id == record.id }) {
            try stored.update(from: record, encoder: encoder, cryptor: cryptor)
        } else {
            context.insert(try StoredQuestionAnswerRecord(record: record, encoder: encoder, cryptor: cryptor))
        }
        try context.save()
    }

    func questionAnswerRecords(for meetingId: UUID? = nil) throws -> [QuestionAnswerRecord] {
        let records = try context.fetch(FetchDescriptor<StoredQuestionAnswerRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
        var mappedRecords = [QuestionAnswerRecord]()
        for record in records where meetingId == nil || record.meetingId == meetingId {
            if let mapped = try mapQuestionAnswerRecord(record) {
                mappedRecords.append(mapped)
            }
        }
        return mappedRecords
    }

    func appendFeedback(_ feedback: QuestionAnswerFeedbackEvent, to recordId: UUID) throws {
        let records = try context.fetch(FetchDescriptor<StoredQuestionAnswerRecord>())
        guard let stored = records.first(where: { $0.id == recordId }),
              var record = try mapQuestionAnswerRecord(stored) else { return }
        record.feedbackEvents.append(feedback)
        record.updatedAt = Date()
        try stored.update(from: record, encoder: encoder, cryptor: cryptor)
        try context.save()
    }

    func saveCopilotInteraction(_ interaction: CopilotInteraction) throws {
        let records = try context.fetch(FetchDescriptor<StoredCopilotInteraction>())
        if let stored = records.first(where: { $0.id == interaction.id }) {
            try stored.update(from: interaction, encoder: encoder, cryptor: cryptor)
        } else {
            context.insert(try StoredCopilotInteraction(interaction: interaction, encoder: encoder, cryptor: cryptor))
        }
        try context.save()
    }

    func copilotInteractions(now: Date = Date()) throws -> [CopilotInteraction] {
        let records = try context.fetch(FetchDescriptor<StoredCopilotInteraction>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
        return try records
            .filter { $0.expiresAt > now }
            .map(mapCopilotInteraction)
    }

    func saveCopilotMemoryEntry(_ entry: CopilotMemoryEntry) throws {
        let records = try context.fetch(FetchDescriptor<StoredCopilotMemoryEntry>())
        if let stored = records.first(where: { $0.id == entry.id }) {
            try stored.update(from: entry, cryptor: cryptor)
        } else {
            context.insert(try StoredCopilotMemoryEntry(entry: entry, cryptor: cryptor))
        }
        try context.save()
    }

    func copilotMemoryEntries(query: String, now: Date = Date(), limit: Int = 5) throws -> [CopilotMemoryEntry] {
        let terms = Set(query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        guard !terms.isEmpty else { return [] }
        let records = try context.fetch(FetchDescriptor<StoredCopilotMemoryEntry>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
        return try records
            .filter { $0.expiresAt > now }
            .map(mapCopilotMemoryEntry)
            .filter { entry in
                let lowered = entry.text.lowercased()
                return terms.contains { lowered.contains($0) }
            }
            .prefix(max(0, limit))
            .map { $0 }
    }

    func saveCopilotReminder(_ reminder: CopilotReminder) throws {
        let records = try context.fetch(FetchDescriptor<StoredCopilotReminder>())
        if let stored = records.first(where: { $0.id == reminder.id }) {
            try stored.update(from: reminder, cryptor: cryptor)
        } else {
            context.insert(try StoredCopilotReminder(reminder: reminder, cryptor: cryptor))
        }
        try context.save()
    }

    func copilotReminders(now: Date = Date()) throws -> [CopilotReminder] {
        let records = try context.fetch(FetchDescriptor<StoredCopilotReminder>(sortBy: [SortDescriptor(\.scheduledAt)]))
        return try records
            .filter { $0.expiresAt > now }
            .map(mapCopilotReminder)
    }

    func purgeExpiredCopilotData(now: Date = Date()) throws {
        for interaction in try context.fetch(FetchDescriptor<StoredCopilotInteraction>()) where interaction.expiresAt <= now {
            context.delete(interaction)
        }
        for memoryEntry in try context.fetch(FetchDescriptor<StoredCopilotMemoryEntry>()) where memoryEntry.expiresAt <= now {
            context.delete(memoryEntry)
        }
        for reminder in try context.fetch(FetchDescriptor<StoredCopilotReminder>()) where reminder.expiresAt <= now {
            context.delete(reminder)
        }
        try context.save()
    }

    func deleteCopilotHistory(now: Date = Date()) throws {
        for interaction in try context.fetch(FetchDescriptor<StoredCopilotInteraction>()) where interaction.expiresAt > now {
            context.delete(interaction)
        }
        for memoryEntry in try context.fetch(FetchDescriptor<StoredCopilotMemoryEntry>()) where memoryEntry.expiresAt > now {
            context.delete(memoryEntry)
        }
        for reminder in try context.fetch(FetchDescriptor<StoredCopilotReminder>()) where reminder.expiresAt > now {
            context.delete(reminder)
        }
        try context.save()
    }

    private func mapMeeting(_ stored: StoredMeeting, segments: [TranscriptSegment], summary: MeetingSummary?) throws -> MeetingSession {
        let participantsJSON = try cryptor.decryptString(stored.participantsJSON, context: StoredMeeting.participantsContext)
        let tagsJSON = try cryptor.decryptString(stored.tagsJSON, context: StoredMeeting.tagsContext)
        let participants = decode([Participant].self, from: participantsJSON) ?? []
        let tags = decode([String].self, from: tagsJSON) ?? []
        return MeetingSession(
            id: stored.id,
            title: try cryptor.decryptString(stored.title, context: StoredMeeting.titleContext),
            source: MeetingSource(rawValue: stored.sourceRaw) ?? .unknown,
            appName: try cryptor.decryptOptionalString(stored.appName, context: StoredMeeting.appNameContext),
            meetingURL: try cryptor.decryptOptionalString(stored.meetingURL, context: StoredMeeting.meetingURLContext),
            startedAt: stored.startedAt,
            endedAt: stored.endedAt,
            status: MeetingStatus(rawValue: stored.statusRaw) ?? .ended,
            primaryLanguage: stored.primaryLanguage,
            participants: participants,
            transcriptSegments: segments,
            audioFileURL: try cryptor.decryptOptionalString(stored.audioFilePath, context: StoredMeeting.audioFilePathContext).map(URL.init(fileURLWithPath:)),
            summary: summary,
            tags: tags,
            meetingType: MeetingType(rawValue: stored.meetingTypeRaw) ?? .unknown,
            automationSourceAppName: try cryptor.decryptOptionalString(stored.automationSourceAppName, context: StoredMeeting.automationSourceAppNameContext),
            automationSourceBundleId: try cryptor.decryptOptionalString(stored.automationSourceBundleId, context: StoredMeeting.automationSourceBundleIdContext),
            wasAutoEnded: stored.wasAutoEnded
        )
    }

    private static func mapSegment(_ stored: StoredTranscriptSegment, cryptor: LocalDataCryptor) throws -> TranscriptSegment {
        let preservedTermsJSON = try cryptor.decryptOptionalString(stored.preservedTermsJSON, context: StoredTranscriptSegment.preservedTermsContext)
        let wordTimestampsJSON = try cryptor.decryptOptionalString(stored.wordTimestampsJSON, context: StoredTranscriptSegment.wordTimestampsContext)
        return TranscriptSegment(
            id: stored.id,
            meetingId: stored.meetingId,
            speakerId: stored.speakerId,
            speakerLabel: try cryptor.decryptString(stored.speakerLabel, context: StoredTranscriptSegment.speakerLabelContext),
            audioSource: TranscriptAudioSource(rawValue: stored.audioSourceRaw) ?? .unknown,
            text: try cryptor.decryptString(stored.text, context: StoredTranscriptSegment.textContext),
            originalLanguage: stored.originalLanguage,
            sourceLanguage: stored.sourceLanguage,
            targetLanguage: stored.targetLanguage,
            draftTranslatedText: try cryptor.decryptOptionalString(stored.draftTranslatedText, context: StoredTranscriptSegment.draftTranslatedTextContext),
            translatedText: try cryptor.decryptOptionalString(stored.translatedText, context: StoredTranscriptSegment.translatedTextContext),
            translatedLanguage: stored.translatedLanguage,
            translationPhase: TranslationPhase(rawValue: stored.translationPhaseRaw ?? ""),
            translationConfidence: stored.translationConfidence,
            preservedTerms: decodeStringArray(preservedTermsJSON),
            translationState: TranslationState(rawValue: stored.translationStateRaw ?? "") ?? (stored.translatedText == nil ? .none : .translated),
            transcriptionPhase: TranscriptionPhase(rawValue: stored.transcriptionPhaseRaw ?? ""),
            transcriptionEngine: TranscriptionEngineName(rawValue: stored.transcriptionEngineRaw ?? ""),
            engineConfidence: stored.engineConfidence,
            languageConfidence: stored.languageConfidence,
            revisionOfSegmentId: stored.revisionOfSegmentId,
            revisionNumber: stored.revisionNumber,
            finalizedBy: TranscriptionEngineName(rawValue: stored.finalizedByRaw ?? ""),
            latencyMs: stored.latencyMs,
            sourceFrameRange: sourceFrameRange(start: stored.sourceFrameStart, end: stored.sourceFrameEnd),
            audioEnergy: stored.audioEnergy,
            stitchingConfidence: stored.stitchingConfidence,
            retentionReason: TranscriptionRetentionReason(rawValue: stored.retentionReasonRaw ?? ""),
            wordTimestamps: decodeWordTimestamps(wordTimestampsJSON),
            startTime: stored.startTime,
            endTime: stored.endTime,
            confidence: stored.confidence,
            isFinal: stored.isFinal,
            createdAt: stored.createdAt
        )
    }

    private static func decodeStringArray(_ value: String?) -> [String] {
        guard let value, let data = value.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private static func decodeWordTimestamps(_ value: String?) -> [TranscriptWordTimestamp] {
        guard let value, let data = value.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([TranscriptWordTimestamp].self, from: data)) ?? []
    }

    private static func sourceFrameRange(start: Int64?, end: Int64?) -> AudioSourceFrameRange? {
        guard let start, let end else { return nil }
        return AudioSourceFrameRange(start: start, end: end)
    }

    private func mapSummary(_ stored: StoredSummary) throws -> MeetingSummary {
        MeetingSummary(
            id: stored.id,
            meetingId: stored.meetingId,
            executiveSummary: try cryptor.decryptString(stored.executiveSummary, context: StoredSummary.executiveSummaryContext),
            keyDecisions: decode([String].self, from: try cryptor.decryptString(stored.keyDecisionsJSON, context: StoredSummary.keyDecisionsContext)) ?? [],
            actionItems: decode([ActionItem].self, from: try cryptor.decryptString(stored.actionItemsJSON, context: StoredSummary.actionItemsContext)) ?? [],
            risks: decode([String].self, from: try cryptor.decryptString(stored.risksJSON, context: StoredSummary.risksContext)) ?? [],
            openQuestions: decode([String].self, from: try cryptor.decryptString(stored.openQuestionsJSON, context: StoredSummary.openQuestionsContext)) ?? [],
            strategicInsights: decode([String].self, from: try cryptor.decryptString(stored.strategicInsightsJSON, context: StoredSummary.strategicInsightsContext)) ?? [],
            followUps: decode([String].self, from: try cryptor.decryptString(stored.followUpsJSON, context: StoredSummary.followUpsContext)) ?? [],
            generatedAt: stored.generatedAt
        )
    }

    private func mapQuestionAnswerRecord(_ stored: StoredQuestionAnswerRecord) throws -> QuestionAnswerRecord? {
        let questionJSON = try cryptor.decryptString(stored.questionJSON, context: StoredQuestionAnswerRecord.questionContext)
        let classificationJSON = try cryptor.decryptString(stored.classificationJSON, context: StoredQuestionAnswerRecord.classificationContext)
        guard let question = decode(QuestionCandidate.self, from: questionJSON),
              let classification = decode(QuestionClassification.self, from: classificationJSON) else { return nil }
        let answer = try cryptor.decryptOptionalString(stored.answerJSON, context: StoredQuestionAnswerRecord.answerContext)
            .flatMap { decode(SuggestedAnswer.self, from: $0) }
        return QuestionAnswerRecord(
            id: stored.id,
            meetingId: stored.meetingId,
            question: question,
            classification: classification,
            answer: answer,
            contextSummary: try cryptor.decryptString(stored.contextSummary, context: StoredQuestionAnswerRecord.contextSummaryContext),
            sources: decode([AnswerSource].self, from: try cryptor.decryptString(stored.sourcesJSON, context: StoredQuestionAnswerRecord.sourcesContext)) ?? [],
            decision: try cryptor.decryptString(stored.decision, context: StoredQuestionAnswerRecord.decisionContext),
            feedbackEvents: decode([QuestionAnswerFeedbackEvent].self, from: try cryptor.decryptString(stored.feedbackJSON, context: StoredQuestionAnswerRecord.feedbackContext)) ?? [],
            createdAt: stored.createdAt,
            updatedAt: stored.updatedAt
        )
    }

    private func mapCopilotInteraction(_ stored: StoredCopilotInteraction) throws -> CopilotInteraction {
        CopilotInteraction(
            id: stored.id,
            contextKind: CopilotRuntimeKind(rawValue: stored.contextKindRaw) ?? .ambient,
            source: CopilotRuntimeSource(rawValue: stored.sourceRaw) ?? .microphone,
            questionId: stored.questionId,
            prompt: try cryptor.decryptString(stored.prompt, context: StoredCopilotInteraction.promptContext),
            response: try cryptor.decryptString(stored.response, context: StoredCopilotInteraction.responseContext),
            tool: CopilotToolKind(rawValue: stored.toolRaw) ?? .unavailable,
            intent: CopilotIntentKind(rawValue: stored.intentRaw) ?? .ambiguous,
            languageCode: stored.languageCode,
            confidence: stored.confidence,
            latencyMs: stored.latencyMs,
            sources: decode([AnswerSource].self, from: try cryptor.decryptString(stored.sourcesJSON, context: StoredCopilotInteraction.sourcesContext)) ?? [],
            richAnswer: try cryptor.decryptOptionalString(stored.richAnswerJSON, context: StoredCopilotInteraction.richAnswerContext)
                .flatMap { decode(RichAnswerPayload.self, from: $0) },
            feedbackEvents: decode([QuestionAnswerFeedbackEvent].self, from: try cryptor.decryptString(stored.feedbackJSON, context: StoredCopilotInteraction.feedbackContext)) ?? [],
            createdAt: stored.createdAt,
            expiresAt: stored.expiresAt
        )
    }

    private func mapCopilotMemoryEntry(_ stored: StoredCopilotMemoryEntry) throws -> CopilotMemoryEntry {
        CopilotMemoryEntry(
            id: stored.id,
            text: try cryptor.decryptString(stored.text, context: StoredCopilotMemoryEntry.textContext),
            languageCode: stored.languageCode,
            sourceInteractionId: stored.sourceInteractionId,
            createdAt: stored.createdAt,
            expiresAt: stored.expiresAt
        )
    }

    private func mapCopilotReminder(_ stored: StoredCopilotReminder) throws -> CopilotReminder {
        CopilotReminder(
            id: stored.id,
            title: try cryptor.decryptString(stored.title, context: StoredCopilotReminder.titleContext),
            scheduledAt: stored.scheduledAt,
            notificationId: try cryptor.decryptString(stored.notificationId, context: StoredCopilotReminder.notificationIdContext),
            status: CopilotReminderStatus(rawValue: stored.statusRaw) ?? .scheduled,
            createdAt: stored.createdAt,
            expiresAt: stored.expiresAt
        )
    }

    private func decode<T: Decodable>(_ type: T.Type, from string: String) -> T? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? decoder.decode(type, from: data)
    }
}
