import Foundation

struct TranscriptWindowBuffer {
    private(set) var segments: [TranscriptSegment] = []
    private(set) var completeSegments: [TranscriptSegment] = []
    var shortWindowSeconds: TimeInterval = 90
    var mediumWindowSeconds: TimeInterval = 10 * 60

    mutating func append(_ segment: TranscriptSegment) {
        Self.upsert(segment, into: &segments)
        Self.upsert(segment, into: &completeSegments)
        trim()
    }

    mutating func reset() {
        segments = []
        completeSegments = []
    }

    func transcriptContext(currentSegment: TranscriptSegment?) -> TranscriptContext {
        TranscriptContext(
            recentTranscript: transcript(inLast: shortWindowSeconds),
            mediumTranscript: transcript(inLast: mediumWindowSeconds),
            completeTranscript: completeTranscript,
            dominantLanguage: dominantLanguage,
            currentSegment: currentSegment
        )
    }

    func transcript(inLast seconds: TimeInterval) -> String {
        guard let newest = segments.map(\.startTime).max() else { return "" }
        return segments
            .filter { newest - $0.startTime <= seconds }
            .map(Self.render)
            .joined(separator: "\n")
    }

    var dominantLanguage: String? {
        let counts = Dictionary(grouping: completeSegments.compactMap(\.originalLanguage), by: { $0 })
            .mapValues(\.count)
        return counts.sorted { $0.value > $1.value }.first?.key
    }

    var completeTranscript: String {
        completeSegments
            .map(Self.render)
            .joined(separator: "\n")
    }

    var shortTermMemory: MeetingShortTermMemory {
        let recentText = transcript(inLast: mediumWindowSeconds)
        return MeetingShortTermMemory(
            currentTopic: extractCurrentTopic(from: recentText),
            recentDecisions: extractLines(containing: ["decided", "decision", "decidimos", "decisão", "決定", "decidimos"], from: recentText),
            mentionedPeople: extractCapitalizedTerms(from: recentText),
            mentionedProjects: extractProjectTerms(from: recentText),
            openQuestions: segments.filter { $0.text.contains("?") }.suffix(5).map(\.text),
            actionItems: extractLines(containing: ["action", "follow up", "ação", "próximo", "tarea", "次"], from: recentText),
            conversationMood: nil,
            dominantLanguage: dominantLanguage
        )
    }

    private mutating func trim() {
        guard let newest = segments.map(\.startTime).max() else { return }
        segments = segments.filter { newest - $0.startTime <= mediumWindowSeconds }
    }

    private static func upsert(_ segment: TranscriptSegment, into target: inout [TranscriptSegment]) {
        if let index = target.firstIndex(where: { $0.id == segment.id }) {
            target[index] = segment
        } else {
            target.append(segment)
        }
        target.sort {
            if $0.startTime == $1.startTime {
                return $0.createdAt < $1.createdAt
            }
            return $0.startTime < $1.startTime
        }
    }

    private static func render(_ segment: TranscriptSegment) -> String {
        "[\(segment.audioSource.displayName)] \(segment.speakerLabel): \(segment.text)"
    }

    private func extractCurrentTopic(from text: String) -> String? {
        text.split(separator: "\n").last.map(String.init)
    }

    private func extractLines(containing needles: [String], from text: String) -> [String] {
        let loweredNeedles = needles.map { $0.lowercased() }
        return text
            .split(separator: "\n")
            .map(String.init)
            .filter { line in
                let lowered = line.lowercased()
                return loweredNeedles.contains { lowered.contains($0) }
            }
            .suffix(6)
            .map { $0 }
    }

    private func extractCapitalizedTerms(from text: String) -> [String] {
        let words = text.split { !$0.isLetter }
        let names = words.compactMap { word -> String? in
            let value = String(word)
            guard value.count > 2, value.first?.isUppercase == true else { return nil }
            return value
        }
        return Array(Set(names)).sorted().prefix(8).map { $0 }
    }

    private func extractProjectTerms(from text: String) -> [String] {
        let terms = ["API", "PR", "MVP", "backend", "frontend", "auth", "authentication", "migration", "login", "produção", "production"]
        return terms.filter { text.localizedCaseInsensitiveContains($0) }
    }
}
