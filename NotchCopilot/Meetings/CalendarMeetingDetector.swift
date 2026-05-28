import EventKit
import Foundation

@MainActor
protocol CalendarMeetingDetecting {
    func detectCurrentMeeting() async -> MeetingSession?
}

@MainActor
final class CalendarMeetingDetector: CalendarMeetingDetecting {
    private let store = EKEventStore()

    func requestAccessIfNeeded() async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if Self.canReadCalendar(status) { return true }
        guard status == .notDetermined else { return false }
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            return false
        }
    }

    func detectCurrentMeeting() async -> MeetingSession? {
        guard Self.canReadCalendar(EKEventStore.authorizationStatus(for: .event)) else { return nil }
        let now = Date()
        let start = Calendar.current.date(byAdding: .minute, value: -10, to: now) ?? now
        let end = Calendar.current.date(byAdding: .minute, value: 15, to: now) ?? now
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let event = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .first { containsMeetingURL($0) || $0.startDate <= now && $0.endDate >= now }
        guard let event else { return nil }
        return MeetingSession(
            title: event.title ?? "Calendar meeting",
            source: .calendar,
            meetingURL: meetingURL(from: event),
            startedAt: max(event.startDate, now),
            status: .detected,
            participants: event.attendees?.map { Participant(displayName: $0.name ?? $0.url.absoluteString, confidence: 0.7, source: .calendar) } ?? [],
            meetingType: .general
        )
    }

    private func containsMeetingURL(_ event: EKEvent) -> Bool {
        let haystack = [event.url?.absoluteString, event.notes, event.location, event.title].compactMap { $0 }.joined(separator: " ")
        return ["zoom", "meet.google", "teams.microsoft", "slack", "discord", "around"].contains { haystack.localizedCaseInsensitiveContains($0) }
    }

    private func meetingURL(from event: EKEvent) -> String? {
        if let url = event.url?.absoluteString { return url }
        let notes = event.notes ?? ""
        let regex = try? NSRegularExpression(pattern: #"https?://[^\s]+"#)
        let range = NSRange(notes.startIndex..<notes.endIndex, in: notes)
        guard let match = regex?.firstMatch(in: notes, range: range),
              let swiftRange = Range(match.range, in: notes)
        else {
            return nil
        }
        return String(notes[swiftRange])
    }

    private static func canReadCalendar(_ status: EKAuthorizationStatus) -> Bool {
        status == .fullAccess
    }
}
