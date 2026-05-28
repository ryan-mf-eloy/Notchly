import Foundation

@MainActor
struct SummaryEngine {
    private let provider: any AIProvider

    init(provider: any AIProvider) {
        self.provider = provider
    }

    func summarize(_ meeting: MeetingSession) async throws -> MeetingSummary {
        try await provider.summarizeMeeting(meeting: meeting, transcript: meeting.transcriptSegments, type: meeting.meetingType)
    }
}
