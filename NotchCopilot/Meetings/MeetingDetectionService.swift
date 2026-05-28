import Foundation

@MainActor
final class MeetingDetectionService {
    private let calendarDetector: any CalendarMeetingDetecting
    private let microphoneUsageMonitor: MicrophoneUsageMonitoring
    private let appActivityMonitor: MeetingAppActivityMonitoring

    init(
        calendarDetector: any CalendarMeetingDetecting = CalendarMeetingDetector(),
        microphoneUsageMonitor: MicrophoneUsageMonitoring = MicrophoneUsageMonitor(),
        appActivityMonitor: MeetingAppActivityMonitoring = MeetingAppActivityMonitor()
    ) {
        self.calendarDetector = calendarDetector
        self.microphoneUsageMonitor = microphoneUsageMonitor
        self.appActivityMonitor = appActivityMonitor
    }

    func detectMeeting(preferences: AppPreferences) async -> MeetingSession? {
        guard preferences.autoDetectMeetings else { return nil }
        if preferences.smartMeetingDetectionEnabled,
           microphoneUsageMonitor.isInputInUseByAnotherApplication(),
           let activity = appActivityMonitor.detect(preferences: preferences) {
            return MeetingSession(
                title: activity.meetingTitle,
                source: .activeApp,
                appName: activity.displayName,
                meetingURL: activity.browserTab?.url,
                status: .detected,
                primaryLanguage: SupportedLanguage.normalizedCode(preferences.defaultLanguage),
                meetingType: preferences.defaultMeetingType,
                automationSourceAppName: activity.displayName,
                automationSourceBundleId: activity.bundleIdentifier
            )
        }
        if let calendarMeeting = await calendarDetector.detectCurrentMeeting() {
            return calendarMeeting
        }
        return nil
    }
}
