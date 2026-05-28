import AVFoundation
import EventKit
import Foundation
import Speech

struct PermissionState: Sendable, Hashable {
    var microphone: Bool
    var speech: Bool
    var screenCapture: Bool
    var calendar: Bool
}

@MainActor
final class PermissionsManager: ObservableObject {
    @Published private(set) var state = PermissionState(microphone: false, speech: false, screenCapture: false, calendar: false)

    func refresh() {
        state = PermissionState(
            microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            speech: SFSpeechRecognizer.authorizationStatus() == .authorized,
            screenCapture: CGPreflightScreenCaptureAccess(),
            calendar: Self.hasCalendarAccess()
        )
    }

    func requestMicrophone() async {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        refresh()
    }

    func requestSpeech() async {
        guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else {
            refresh()
            return
        }
        _ = await SpeechAuthorizationHelper.requestAuthorization()
        refresh()
    }

    func requestScreenCapture() {
        guard !CGPreflightScreenCaptureAccess() else {
            refresh()
            return
        }
        _ = CGRequestScreenCaptureAccess()
        refresh()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            self?.refresh()
        }
    }

    func requestCalendar() async {
        let store = EKEventStore()
        if #available(macOS 14.0, *) {
            _ = try? await store.requestFullAccessToEvents()
        } else {
            _ = try? await store.requestAccess(to: .event)
        }
        refresh()
    }

    private static func hasCalendarAccess() -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        return status == .fullAccess || status == .writeOnly
    }
}
