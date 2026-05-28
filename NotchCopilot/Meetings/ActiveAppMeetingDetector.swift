import AppKit
import Foundation

struct ActiveAppMeetingDetector {
    private let knownMeetingApps = [
        "zoom.us",
        "Zoom",
        "Microsoft Teams",
        "Google Chrome",
        "Safari",
        "Slack",
        "Discord"
    ]

    func detect() -> MeetingSession? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let name = app.localizedName,
              knownMeetingApps.contains(where: { name.localizedCaseInsensitiveContains($0) })
        else {
            return nil
        }
        return MeetingSession(
            title: "\(name) meeting",
            source: .activeApp,
            appName: name,
            status: .detected,
            meetingType: .general
        )
    }
}

