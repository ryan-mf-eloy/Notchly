import Foundation

enum AutoEndDecision: Equatable {
    case notApplicable
    case waiting(inactiveSince: Date)
    case shouldEnd
}

struct MeetingAutomationPolicy {
    func shouldAutoStart(preferences: AppPreferences) -> Bool {
        preferences.autoStartListening && !preferences.requireConfirmationBeforeRecording
    }

    func autoEndDecision(
        meeting: MeetingSession?,
        preferences: AppPreferences,
        microphoneInUseByAnotherApplication: Bool,
        now: Date,
        inactiveSince: Date?
    ) -> AutoEndDecision {
        guard preferences.autoEndDetectedMeetings,
              let meeting,
              meeting.status == .listening,
              meeting.source == .activeApp || meeting.automationSourceAppName != nil || meeting.automationSourceBundleId != nil,
              !meeting.wasAutoEnded
        else {
            return .notApplicable
        }
        guard !microphoneInUseByAnotherApplication else { return .notApplicable }

        let grace = TimeInterval(max(1, preferences.autoEndGraceSeconds))
        let inactiveStart = inactiveSince ?? now
        if now.timeIntervalSince(inactiveStart) >= grace {
            return .shouldEnd
        }
        return .waiting(inactiveSince: inactiveStart)
    }
}

@MainActor
final class MeetingAutomationController {
    private unowned let appState: AppState
    private let meetingDetectionService: MeetingDetectionService
    private let microphoneUsageMonitor: MicrophoneUsageMonitoring
    private let policy: MeetingAutomationPolicy
    private let pollInterval: Duration
    private var task: Task<Void, Never>?
    private var inactiveSince: Date?

    init(
        appState: AppState,
        meetingDetectionService: MeetingDetectionService,
        microphoneUsageMonitor: MicrophoneUsageMonitoring = MicrophoneUsageMonitor(),
        policy: MeetingAutomationPolicy = MeetingAutomationPolicy(),
        pollInterval: Duration = .seconds(1)
    ) {
        self.appState = appState
        self.meetingDetectionService = meetingDetectionService
        self.microphoneUsageMonitor = microphoneUsageMonitor
        self.policy = policy
        self.pollInterval = pollInterval
    }

    func start() {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: self?.pollInterval ?? .seconds(2))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        inactiveSince = nil
    }

    func tick(now: Date = Date()) async {
        handleAutoEnd(now: now)
        if appState.expireDetectedMeetingOfferIfNeeded(now: now) {
            return
        }
        await offerDetectionIfNeeded(now: now)
    }

    private func handleAutoEnd(now: Date) {
        let micInUse = microphoneUsageMonitor.isInputInUseByAnotherApplication()
        switch policy.autoEndDecision(
            meeting: appState.currentMeeting,
            preferences: appState.preferences,
            microphoneInUseByAnotherApplication: micInUse,
            now: now,
            inactiveSince: inactiveSince
        ) {
        case .notApplicable:
            inactiveSince = nil
        case .waiting(let inactiveStart):
            inactiveSince = inactiveStart
        case .shouldEnd:
            inactiveSince = nil
            appState.stopMeeting(autoEnded: true)
        }
    }

    private func offerDetectionIfNeeded(now: Date) async {
        guard appState.preferences.autoDetectMeetings,
              appState.currentMeeting == nil,
              appState.islandMode == .idle,
              !appState.shouldSuppressMeetingDetectionForCopilot(now: now)
        else { return }

        guard let detected = await meetingDetectionService.detectMeeting(preferences: appState.preferences),
              !appState.shouldIgnoreDetection(detected, now: now)
        else { return }

        if policy.shouldAutoStart(preferences: appState.preferences) {
            await appState.sessionManager?.startDetectedMeeting(detected)
        } else {
            appState.setMeetingDetected(detected)
        }
    }
}
