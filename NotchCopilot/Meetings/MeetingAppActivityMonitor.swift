import AppKit
import Foundation

struct RunningApplicationSnapshot: Hashable {
    var localizedName: String
    var bundleIdentifier: String?
    var isActive: Bool
    var processIdentifier: pid_t? = nil
}

struct BrowserTabSnapshot: Hashable {
    var title: String?
    var url: String?
}

struct MeetingAppActivity: Hashable {
    var appName: String
    var bundleIdentifier: String?
    var matchedApp: KnownMeetingApp
    var detectedAt: Date
    var browserTab: BrowserTabSnapshot? = nil

    var displayName: String {
        guard let browserTab,
              let platform = MeetingWebPlatform.detect(url: browserTab.url, title: browserTab.title, appName: matchedApp.displayName) else {
            return appName
        }
        return platform.displayName
    }

    var meetingTitle: String {
        "\(displayName) meeting"
    }
}

@MainActor
protocol MeetingAppActivityMonitoring {
    func detect(preferences: AppPreferences) -> MeetingAppActivity?
    func shouldSuppressCalendarFallback(preferences: AppPreferences) -> Bool
}

extension MeetingAppActivityMonitoring {
    func shouldSuppressCalendarFallback(preferences: AppPreferences) -> Bool {
        false
    }
}

@MainActor
struct MeetingAppActivityMonitor: MeetingAppActivityMonitoring {
    var snapshots: () -> [RunningApplicationSnapshot] = {
        let workspace = NSWorkspace.shared
        let frontmost = workspace.frontmostApplication
        return workspace.runningApplications.compactMap { app in
            guard let name = app.localizedName else { return nil }
            return RunningApplicationSnapshot(
                localizedName: name,
                bundleIdentifier: app.bundleIdentifier,
                isActive: app == frontmost,
                processIdentifier: app.processIdentifier
            )
        }
    }
    var activeBrowserTab: (RunningApplicationSnapshot) -> BrowserTabSnapshot? = BrowserActiveTabResolver.activeTab(for:)

    func detect(preferences: AppPreferences) -> MeetingAppActivity? {
        let knownApps = preferences.knownMeetingApps.isEmpty ? KnownMeetingApp.defaults : preferences.knownMeetingApps
        let candidates = snapshots()
        if let active = candidates.first(where: \.isActive),
           let matched = matchedKnownApp(for: active, knownApps: knownApps),
           let activity = meetingActivity(from: active, matched: matched) {
            return activity
        }
        if let activity = candidates.lazy.compactMap({ snapshot -> MeetingAppActivity? in
            guard let matched = matchedKnownApp(for: snapshot, knownApps: knownApps) else { return nil }
            return meetingActivity(from: snapshot, matched: matched)
        }).first {
            return activity
        }
        return nil
    }

    func shouldSuppressCalendarFallback(preferences: AppPreferences) -> Bool {
        let knownApps = preferences.knownMeetingApps.isEmpty ? KnownMeetingApp.defaults : preferences.knownMeetingApps
        guard let active = snapshots().first(where: \.isActive),
              matchedKnownApp(for: active, knownApps: knownApps) != nil,
              BrowserActiveTabResolver.isBrowser(active)
        else {
            return false
        }

        guard let browserTab = activeBrowserTab(active) else {
            return true
        }

        return MeetingWebPlatform.detect(
            url: browserTab.url,
            title: browserTab.title,
            appName: active.localizedName
        ) == nil
    }

    private func matchedKnownApp(for snapshot: RunningApplicationSnapshot, knownApps: [KnownMeetingApp]) -> KnownMeetingApp? {
        let name = snapshot.localizedName.lowercased()
        let bundleIdentifier = snapshot.bundleIdentifier?.lowercased()
        return knownApps.first { app in
            app.bundleIdentifiers.contains { identifier in
                guard let bundleIdentifier else { return false }
                return bundleIdentifier == identifier.lowercased()
            } || app.nameKeywords.contains { keyword in
                name.contains(keyword.lowercased())
            }
        }
    }

    private func meetingActivity(from snapshot: RunningApplicationSnapshot, matched: KnownMeetingApp) -> MeetingAppActivity? {
        if BrowserActiveTabResolver.isBrowser(snapshot) {
            guard let browserTab = activeBrowserTab(snapshot),
                  MeetingWebPlatform.detect(
                    url: browserTab.url,
                    title: browserTab.title,
                    appName: snapshot.localizedName
                  ) != nil
            else {
                return nil
            }
            return activity(from: snapshot, matched: matched, browserTab: browserTab)
        }

        guard MeetingWebPlatform.detect(url: nil, title: nil, appName: snapshot.localizedName) != nil ||
            MeetingWebPlatform.detect(url: nil, title: nil, appName: matched.displayName) != nil
        else {
            return nil
        }

        return activity(from: snapshot, matched: matched)
    }

    private func activity(from snapshot: RunningApplicationSnapshot, matched: KnownMeetingApp, browserTab: BrowserTabSnapshot? = nil) -> MeetingAppActivity {
        MeetingAppActivity(
            appName: snapshot.localizedName,
            bundleIdentifier: snapshot.bundleIdentifier,
            matchedApp: matched,
            detectedAt: Date(),
            browserTab: browserTab
        )
    }
}

enum MeetingWebPlatform: String, CaseIterable, Hashable {
    case googleMeet
    case zoom
    case microsoftTeams
    case slack
    case discord
    case whatsApp
    case webex

    var displayName: String {
        switch self {
        case .googleMeet:
            return "Google Meet"
        case .zoom:
            return "Zoom"
        case .microsoftTeams:
            return "Microsoft Teams"
        case .slack:
            return "Slack"
        case .discord:
            return "Discord"
        case .whatsApp:
            return "WhatsApp"
        case .webex:
            return "Webex"
        }
    }

    static func detect(url: String?, title: String?, appName: String?) -> MeetingWebPlatform? {
        let normalizedURL = url?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let host = normalizedURL.flatMap { URLComponents(string: $0)?.host?.lowercased() }
        if isKnownNonMeetingMediaHost(host) {
            return nil
        }
        let text = [normalizedURL, title?.lowercased(), appName?.lowercased()]
            .compactMap { $0 }
            .joined(separator: " ")

        if host == "meet.google.com" ||
            host == "hangouts.google.com" ||
            text.contains("google meet") ||
            text.contains("meet.google") ||
            looksLikeGoogleMeetTitle(title, appName: appName) {
            return .googleMeet
        }
        if host?.hasSuffix("zoom.us") == true || host?.hasSuffix("zoom.com") == true || text.contains("zoom meeting") || appName?.localizedCaseInsensitiveContains("Zoom") == true {
            return .zoom
        }
        if host == "teams.microsoft.com" ||
            host == "teams.live.com" ||
            host?.hasSuffix("teams.cloud.microsoft") == true ||
            text.contains("microsoft teams") ||
            appName?.localizedCaseInsensitiveContains("Teams") == true {
            return .microsoftTeams
        }
        if host == "app.slack.com" || text.contains("slack huddle") || appName?.localizedCaseInsensitiveContains("Slack") == true {
            return .slack
        }
        if host == "discord.com" || host == "discordapp.com" || appName?.localizedCaseInsensitiveContains("Discord") == true {
            return .discord
        }
        if host == "web.whatsapp.com" || appName?.localizedCaseInsensitiveContains("WhatsApp") == true {
            return .whatsApp
        }
        if host?.hasSuffix("webex.com") == true || text.contains("webex") {
            return .webex
        }
        return nil
    }

    private static func looksLikeGoogleMeetTitle(_ title: String?, appName: String?) -> Bool {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), title.isEmpty == false else {
            return false
        }

        let normalizedTitle = title.lowercased()
        if normalizedTitle.contains("google meet") {
            return true
        }

        let isBrowserContext = BrowserActiveTabResolver.isBrowserAppName(appName)
        guard isBrowserContext else { return false }

        if normalizedTitle.hasPrefix("meet:") || normalizedTitle.hasPrefix("meet -") || normalizedTitle.hasPrefix("meet |") {
            return true
        }

        return normalizedTitle.range(
            of: #"\bmeet[:\s-]+[a-z]{3}-[a-z]{4}-[a-z]{3}\b"#,
            options: .regularExpression
        ) != nil
    }

    private static func isKnownNonMeetingMediaHost(_ host: String?) -> Bool {
        guard let host else { return false }
        let blockedHosts = [
            "youtube.com",
            "youtu.be",
            "vimeo.com",
            "twitch.tv",
            "netflix.com",
            "primevideo.com",
            "hulu.com",
            "disneyplus.com",
            "udemy.com",
            "coursera.org"
        ]
        return blockedHosts.contains { blockedHost in
            host == blockedHost || host.hasSuffix(".\(blockedHost)")
        }
    }
}

enum BrowserActiveTabResolver {
    private static let browserBundleIdentifiers: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta",
        "com.microsoft.edgemac.Dev",
        "com.brave.Browser",
        "com.brave.Browser.beta",
        "com.brave.Browser.nightly",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "com.operasoftware.OperaGX",
        "com.duckduckgo.macos.browser",
        "company.thebrowser.Browser",
        "company.thebrowser.dia",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
        "com.kagi.kagimacOS",
        "com.kagi.kagimacOS.Development"
    ]

    static func isBrowser(_ snapshot: RunningApplicationSnapshot) -> Bool {
        isBrowserBundleIdentifier(snapshot.bundleIdentifier) ||
            isBrowserAppName(snapshot.localizedName)
    }

    static func isBrowserBundleIdentifier(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return browserBundleIdentifiers.contains(bundleIdentifier)
    }

    static func isBrowserAppName(_ appName: String?) -> Bool {
        guard let appName = appName?.lowercased() else { return false }
        return appName.contains("safari") ||
            appName.contains("chrome") ||
            appName.contains("arc") ||
            appName.contains("edge") ||
            appName.contains("brave") ||
            appName.contains("firefox") ||
            appName.contains("opera") ||
            appName.contains("vivaldi") ||
            appName.contains("duckduckgo") ||
            appName.contains("orion") ||
            appName == "dia" ||
            appName.contains("dia browser")
    }

    static func activeTab(for snapshot: RunningApplicationSnapshot) -> BrowserTabSnapshot? {
        guard let bundleIdentifier = snapshot.bundleIdentifier,
              NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty == false else {
            return fallbackWindowTitleSnapshot(for: snapshot)
        }

        for scriptSource in scriptSources(for: bundleIdentifier) {
            if let snapshot = browserTabSnapshot(from: runAppleScript(scriptSource)) {
                return snapshot
            }
        }

        return fallbackWindowTitleSnapshot(for: snapshot)
    }

    static func scriptSources(for bundleIdentifier: String) -> [String] {
        if bundleIdentifier == "com.apple.Safari" || bundleIdentifier == "com.apple.SafariTechnologyPreview" {
            return [
                """
                tell application id "\(bundleIdentifier)"
                    if (count of documents) = 0 then return ""
                    return (URL of front document as text) & linefeed & (name of front document as text)
                end tell
                """,
                """
                tell application id "\(bundleIdentifier)"
                    if (count of windows) = 0 then return ""
                    set candidateTab to current tab of front window
                    return (URL of candidateTab as text) & linefeed & (name of candidateTab as text)
                end tell
                """
            ]
        }

        if isFirefoxBundleIdentifier(bundleIdentifier) {
            return []
        }

        return [
            """
            tell application id "\(bundleIdentifier)"
                if (count of windows) = 0 then return ""
                set candidateTab to active tab of front window
                return (URL of candidateTab as text) & linefeed & (title of candidateTab as text)
            end tell
            """,
            """
            tell application id "\(bundleIdentifier)"
                if (count of windows) = 0 then return ""
                set candidateTab to active tab of window 1
                return (URL of candidateTab as text) & linefeed & (title of candidateTab as text)
            end tell
            """,
            """
            tell application id "\(bundleIdentifier)"
                if (count of windows) = 0 then return ""
                set candidateTab to active tab of first window
                return (URL of candidateTab as text) & linefeed & (title of candidateTab as text)
            end tell
            """
        ]
    }

    static func browserTabSnapshot(from output: String?) -> BrowserTabSnapshot? {
        guard let output = output?.trimmingCharacters(in: .whitespacesAndNewlines), output.isEmpty == false else {
            return nil
        }
        let parts = output.components(separatedBy: .newlines)
        return BrowserTabSnapshot(
            title: parts.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            url: parts.first?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
    }

    private static func isFirefoxBundleIdentifier(_ bundleIdentifier: String) -> Bool {
        bundleIdentifier == "org.mozilla.firefox" ||
            bundleIdentifier == "org.mozilla.firefoxdeveloperedition" ||
            bundleIdentifier == "org.mozilla.nightly"
    }

    private static func fallbackWindowTitleSnapshot(for snapshot: RunningApplicationSnapshot) -> BrowserTabSnapshot? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let title = windowInfo.first { info in
            let layer = info[kCGWindowLayer as String] as? Int
            let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t
            let ownerName = info[kCGWindowOwnerName as String] as? String
            let windowName = info[kCGWindowName as String] as? String
            guard layer == 0, windowName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return false
            }
            if let processIdentifier = snapshot.processIdentifier, ownerPID == processIdentifier {
                return true
            }
            guard let ownerName, ownerName.isEmpty == false else { return false }
            return ownerName.localizedCaseInsensitiveContains(snapshot.localizedName) ||
                snapshot.localizedName.localizedCaseInsensitiveContains(ownerName)
        }?[kCGWindowName as String] as? String

        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), title.isEmpty == false else {
            return nil
        }
        return BrowserTabSnapshot(title: title, url: nil)
    }

    private static func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard error == nil else { return nil }
        return result?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
