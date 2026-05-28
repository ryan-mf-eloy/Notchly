import AppKit
import Foundation

struct PrivacyGuard {
    private let secretPatterns: [NSRegularExpression]

    init() {
        let patterns = [
            #"sk-[A-Za-z0-9_\-]{20,}"#,
            #"sk-proj-[A-Za-z0-9_\-]{20,}"#,
            #"(?i)(api[_-]?key|token|secret|password)\s*[:=]\s*['"]?[^'"\s,;]{8,}"#,
            #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#
        ]
        self.secretPatterns = patterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }

    func redact(_ text: String) -> String {
        var redacted = text
        for pattern in secretPatterns {
            let range = NSRange(redacted.startIndex..<redacted.endIndex, in: redacted)
            redacted = pattern.stringByReplacingMatches(in: redacted, range: range, withTemplate: "[redacted]")
        }
        return redacted
    }

    func minimizedContext(from segments: [TranscriptSegment], maxCharacters: Int = 4_000) -> String {
        let combined = segments
            .suffix(30)
            .map { "[\($0.audioSource.displayName)] \($0.speakerLabel): \($0.text)" }
            .joined(separator: "\n")
        let redacted = redact(combined)
        guard redacted.count > maxCharacters else { return redacted }
        return String(redacted.suffix(maxCharacters))
    }
}

@MainActor
enum WindowCaptureProtection {
    private static var auditsByWindow = [ObjectIdentifier: WindowCaptureProtectionAudit]()

    static func apply(
        isEnabled: Bool,
        to window: NSWindow?,
        role: WindowCaptureProtectionAudit.WindowRole? = nil,
        containsProtectedContent: Bool = true
    ) {
        guard let window else { return }
        window.sharingType = isEnabled ? .none : .readOnly
        NSAccessibility.setMayContainProtectedContent(isEnabled)
        recordAudit(
            for: window,
            isEnabled: isEnabled,
            role: role ?? inferredRole(for: window),
            containsProtectedContent: containsProtectedContent
        )
    }

    static func apply(
        isEnabled: Bool,
        to windows: [NSWindow?],
        role: WindowCaptureProtectionAudit.WindowRole? = nil,
        containsProtectedContent: Bool = true
    ) {
        windows.forEach {
            apply(
                isEnabled: isEnabled,
                to: $0,
                role: role,
                containsProtectedContent: containsProtectedContent
            )
        }
    }

    static func applyToCurrentAppWindows(isEnabled: Bool) {
        apply(isEnabled: isEnabled, to: NSApp.windows)
        pruneAuditToCurrentAppWindows()
    }

    static func auditSnapshots() -> [WindowCaptureProtectionAudit] {
        pruneAuditToCurrentAppWindows()
        return auditsByWindow.values.sorted { lhs, rhs in
            if lhs.role.sortOrder != rhs.role.sortOrder {
                return lhs.role.sortOrder < rhs.role.sortOrder
            }
            if lhs.windowTitle != rhs.windowTitle {
                return lhs.windowTitle < rhs.windowTitle
            }
            return lhs.windowNumber < rhs.windowNumber
        }
    }

    static func resetAuditForTests() {
        auditsByWindow.removeAll()
    }

    private static func recordAudit(
        for window: NSWindow,
        isEnabled: Bool,
        role: WindowCaptureProtectionAudit.WindowRole,
        containsProtectedContent: Bool
    ) {
        let identifier = ObjectIdentifier(window)
        auditsByWindow[identifier] = WindowCaptureProtectionAudit(
            windowObjectIdentifier: String(describing: identifier),
            windowNumber: window.windowNumber,
            windowTitle: displayTitle(for: window),
            role: role,
            requestedProtection: isEnabled,
            sharingTypeDescription: sharingTypeDescription(window.sharingType),
            isSharingBlocked: window.sharingType == .none,
            mayContainProtectedContent: isEnabled && containsProtectedContent,
            lastAppliedAt: Date()
        )
    }

    private static func pruneAuditToCurrentAppWindows() {
        let currentIdentifiers = Set(NSApp.windows.map { ObjectIdentifier($0) })
        auditsByWindow = auditsByWindow.filter { currentIdentifiers.contains($0.key) }
    }

    private static func inferredRole(for window: NSWindow) -> WindowCaptureProtectionAudit.WindowRole {
        let title = window.title.localizedLowercase
        if title.contains("settings") { return .settings }
        if title.contains("history") { return .history }
        if title.contains("summary") { return .summary }
        if window.styleMask.contains(.nonactivatingPanel) { return .notchOverlay }
        return .appWindow
    }

    private static func displayTitle(for window: NSWindow) -> String {
        let trimmed = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? inferredRole(for: window).displayName : trimmed
    }

    private static func sharingTypeDescription(_ sharingType: NSWindow.SharingType) -> String {
        switch sharingType {
        case .none:
            return "none"
        case .readOnly:
            return "readOnly"
        case .readWrite:
            return "readWrite"
        @unknown default:
            return "unknown"
        }
    }
}

struct WindowCaptureProtectionAudit: Identifiable, Equatable {
    enum WindowRole: String, CaseIterable, Equatable {
        case notchOverlay
        case settings
        case history
        case summary
        case appWindow

        var displayName: String {
            switch self {
            case .notchOverlay: "Notch overlay"
            case .settings: "Settings"
            case .history: "History"
            case .summary: "Summary"
            case .appWindow: "App window"
            }
        }

        var sortOrder: Int {
            switch self {
            case .notchOverlay: 0
            case .settings: 1
            case .history: 2
            case .summary: 3
            case .appWindow: 4
            }
        }
    }

    var id: String { windowObjectIdentifier }
    var windowObjectIdentifier: String
    var windowNumber: Int
    var windowTitle: String
    var role: WindowRole
    var requestedProtection: Bool
    var sharingTypeDescription: String
    var isSharingBlocked: Bool
    var mayContainProtectedContent: Bool
    var lastAppliedAt: Date
}

struct PrivacyManualValidationItem: Identifiable, Equatable {
    var id: String
    var title: String
    var expectedResult: String
}

struct PrivacyDiagnosticsSnapshot: Equatable {
    var modeDisplayName: String
    var isStealthModeEnabled: Bool
    var macOSVersion: String
    var localEncryptionSummary: String
    var windowAudits: [WindowCaptureProtectionAudit]
    var limitations: [String]
    var manualValidationItems: [PrivacyManualValidationItem]

    var protectedWindowCount: Int {
        windowAudits.filter(\.isSharingBlocked).count
    }

    var capturePolicySummary: String {
        isStealthModeEnabled ? "Protected where public APIs are honored" : "Readable by capture APIs"
    }

    var focusPolicySummary: String {
        "Notch overlay is non-activating"
    }
}

@MainActor
enum PrivacyDiagnostics {
    static let modeDisplayName = "Stealth Mode (Privacy)"

    static func snapshot(isStealthModeEnabled: Bool) -> PrivacyDiagnosticsSnapshot {
        PrivacyDiagnosticsSnapshot(
            modeDisplayName: modeDisplayName,
            isStealthModeEnabled: isStealthModeEnabled,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            localEncryptionSummary: "Active: AES.GCM + Keychain ThisDeviceOnly",
            windowAudits: WindowCaptureProtection.auditSnapshots(),
            limitations: limitations,
            manualValidationItems: manualValidationItems
        )
    }

    static let limitations = [
        "Uses public macOS capture-protection APIs only.",
        "Local text history, transcripts, summaries, knowledge, Q&A, Notchly memory, and preferences are encrypted at rest.",
        "Optional audio recordings and explicit user exports are not encrypted in this v1.",
        "Legitimate system tools can still see the app, windows, process, permissions, and real input events.",
        "Tools that capture the final framebuffer or ignore public protection APIs may still capture visible content."
    ]

    static let manualValidationItems = [
        PrivacyManualValidationItem(
            id: "macos-screenshot",
            title: "macOS screenshot / screencapture",
            expectedResult: "Protected content is omitted when macOS honors window sharing."
        ),
        PrivacyManualValidationItem(
            id: "quicktime",
            title: "QuickTime screen recording",
            expectedResult: "Record whether protected content is omitted on this macOS version."
        ),
        PrivacyManualValidationItem(
            id: "meeting-apps",
            title: "Zoom, Google Meet, Teams",
            expectedResult: "Document whether each app honors public capture protection."
        ),
        PrivacyManualValidationItem(
            id: "obs",
            title: "OBS and framebuffer capture tools",
            expectedResult: "Document any visible capture as a platform/tool limitation."
        ),
        PrivacyManualValidationItem(
            id: "accessibility",
            title: "Accessibility Inspector / VoiceOver",
            expectedResult: "Controls remain usable; sensitive regions are marked protected."
        ),
        PrivacyManualValidationItem(
            id: "system-audit",
            title: "Activity Monitor / ps / event monitors",
            expectedResult: "The app and real user events remain visible to legitimate tools."
        )
    ]
}

@MainActor
enum FocusSafeInteractionPolicy {
    static func apply(to panel: NSPanel?) {
        guard let panel else { return }
        panel.styleMask.insert(.nonactivatingPanel)
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.tabbingMode = .disallowed
    }

    static func showWithoutActivation(_ window: NSWindow?) {
        guard let window else { return }
        window.orderFrontRegardless()
    }

    static func canPerformOverlayActionWithoutActivation(_ action: () -> Void) -> FocusSafeActionResult {
        let before = FocusSafeActionSnapshot.current
        action()
        let after = FocusSafeActionSnapshot.current
        return FocusSafeActionResult(before: before, after: after)
    }
}

struct FocusSafeActionResult: Equatable {
    var before: FocusSafeActionSnapshot
    var after: FocusSafeActionSnapshot

    var preservedAppActivation: Bool {
        before.isCurrentAppActive == after.isCurrentAppActive
    }

    var preservedFrontmostApplication: Bool {
        before.frontmostProcessIdentifier == after.frontmostProcessIdentifier &&
            before.frontmostBundleIdentifier == after.frontmostBundleIdentifier
    }
}

struct FocusSafeActionSnapshot: Equatable {
    var isCurrentAppActive: Bool
    var frontmostProcessIdentifier: pid_t?
    var frontmostBundleIdentifier: String?

    @MainActor
    static var current: FocusSafeActionSnapshot {
        let frontmost = NSWorkspace.shared.frontmostApplication
        return FocusSafeActionSnapshot(
            isCurrentAppActive: NSApp.isActive,
            frontmostProcessIdentifier: frontmost?.processIdentifier,
            frontmostBundleIdentifier: frontmost?.bundleIdentifier
        )
    }
}
