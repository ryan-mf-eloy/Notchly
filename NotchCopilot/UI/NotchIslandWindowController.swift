import AppKit
import Combine
import SwiftUI

@MainActor
final class NotchIslandWindowController {
    private let panel: NotchPanel
    private let appState: AppState
    private var cancellables = Set<AnyCancellable>()
    private var lastFrame: CGRect?
    private var frameSettleTask: Task<Void, Never>?
    private let chromeFrameSettleDelayMs = NotchIslandVisualEnvelope.chromeSettleDelayMs

    init(appState: AppState) {
        self.appState = appState
        self.panel = NotchPanel(
            contentRect: CGRect(origin: .zero, size: NotchIslandVisualEnvelope.windowCanvasSize(for: appState.notchIslandCanvasSize)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configurePanel()
        observeState()
    }

    func show() {
        position(animated: false)
        FocusSafeInteractionPolicy.showWithoutActivation(panel)
    }

    private func configurePanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        applyOverlayZOrder()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.appState = appState
        panel.contentView = NotchInteractionContainerView(rootView: NotchIslandView(appState: appState), appState: appState)
        FocusSafeInteractionPolicy.apply(to: panel)
        applyOverlayZOrder()
        WindowCaptureProtection.apply(
            isEnabled: appState.preferences.stealthModeEnabled,
            to: panel,
            role: .notchOverlay
        )
    }

    private func observeState() {
        appState.$islandMode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.position(animated: true) }
            .store(in: &cancellables)
        appState.$isPanelExpanded
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.position(animated: true) }
            .store(in: &cancellables)
        appState.$isNotchHovered
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.position(animated: true) }
            .store(in: &cancellables)
        appState.$statusMessage
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.position(animated: true) }
            .store(in: &cancellables)
        appState.$questionAnswerPresentationMode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.position(animated: true) }
            .store(in: &cancellables)
        appState.$selectedQuestionId
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.position(animated: true) }
            .store(in: &cancellables)
        appState.$streamingAnswerText
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.position(animated: true) }
            .store(in: &cancellables)
        appState.$suggestedAnswer
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.position(animated: true) }
            .store(in: &cancellables)
        appState.$preferences
            .map(\.stealthModeEnabled)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] isEnabled in
                guard let self else { return }
                WindowCaptureProtection.apply(isEnabled: isEnabled, to: self.panel, role: .notchOverlay)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.recoverWindowPositionAfterDisplayChange() }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.recoverWindowPositionAfterDisplayChange() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.recoverWindowPositionAfterDisplayChange(animated: true) }
            .store(in: &cancellables)
    }

    private func recoverWindowPositionAfterDisplayChange(animated: Bool = false) {
        frameSettleTask?.cancel()
        lastFrame = nil
        position(animated: animated)

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            self?.lastFrame = nil
            self?.position(animated: animated)
        }
    }

    private func position(animated: Bool) {
        guard let screen = targetScreen() else { return }
        let logicalCanvasSize = appState.notchIslandCanvasSize
        let size = NotchIslandVisualEnvelope.windowCanvasSize(for: logicalCanvasSize)
        let frame = panelFrame(for: size, on: screen)

        if animated,
           let lastFrame,
           frame.width < lastFrame.width || frame.height < lastFrame.height {
            let envelopeSize = CGSize(
                width: max(size.width, lastFrame.width),
                height: max(size.height, lastFrame.height)
            )
            let envelopeFrame = panelFrame(for: envelopeSize, on: screen)
            applyPanelFrame(envelopeFrame)
            scheduleFrameSettle(to: frame, targetLogicalCanvasSize: logicalCanvasSize)
            return
        }

        frameSettleTask?.cancel()

        guard lastFrame != frame else {
            FocusSafeInteractionPolicy.showWithoutActivation(panel)
            return
        }

        applyPanelFrame(frame)
    }

    private func panelFrame(for size: CGSize, on screen: NSScreen) -> CGRect {
        if appState.shouldAnchorCompactIslandToNotchRightEdge {
            return NotchIslandWindowPlacement.topAnchoredFrameExtendingLeft(
                for: size,
                collapsedWidth: NotchIslandChromeMetrics.collapsedNotchFootprintSize.width,
                in: screen.frame
            )
        }
        return NotchIslandWindowPlacement.topAnchoredFrame(for: size, in: screen.frame)
    }

    private func applyPanelFrame(_ frame: CGRect) {
        guard lastFrame != frame else {
            applyOverlayZOrder()
            FocusSafeInteractionPolicy.showWithoutActivation(panel)
            return
        }
        lastFrame = frame
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            panel.setFrame(frame, display: true, animate: false)
        }
        applyOverlayZOrder()
        FocusSafeInteractionPolicy.showWithoutActivation(panel)
    }

    private func applyOverlayZOrder() {
        panel.level = NotchIslandWindowZOrder.overlayLevel
        panel.collectionBehavior = NotchIslandWindowZOrder.collectionBehavior
    }

    private func scheduleFrameSettle(to targetFrame: CGRect, targetLogicalCanvasSize: CGSize) {
        frameSettleTask?.cancel()
        let delayMs = chromeFrameSettleDelayMs
        frameSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMs))
            guard let self, !Task.isCancelled else { return }
            guard self.appState.notchIslandCanvasSize == targetLogicalCanvasSize else { return }
            self.applyPanelFrame(targetFrame)
        }
    }

    private func targetScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }
}

enum NotchIslandWindowPlacement {
    static func topAnchoredFrame(for size: CGSize, in screenFrame: CGRect) -> CGRect {
        let width = ceil(size.width)
        let height = ceil(size.height)
        let x = (screenFrame.midX - width / 2).rounded(.toNearestOrAwayFromZero)
        let y = screenFrame.maxY - height
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func topAnchoredFrameExtendingLeft(for size: CGSize, collapsedWidth: CGFloat, in screenFrame: CGRect) -> CGRect {
        let width = ceil(size.width)
        let height = ceil(size.height)
        let collapsedRightEdge = screenFrame.midX + ceil(collapsedWidth) / 2
        let x = (collapsedRightEdge - width).rounded(.toNearestOrAwayFromZero)
        let y = screenFrame.maxY - height
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

enum NotchIslandWindowZOrder {
    static let overlayLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
    static let collectionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces,
        .fullScreenAuxiliary,
        .stationary,
        .ignoresCycle
    ]
}

@MainActor
final class NotchPanel: NSPanel {
    weak var appState: AppState?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override func makeKey() {}

    override func makeKeyAndOrderFront(_ sender: Any?) {
        FocusSafeInteractionPolicy.showWithoutActivation(self)
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        false
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown,
           let appState,
           !eventTargetsMouseDownActionOverlay(event) {
            var handled = false
            _ = FocusSafeInteractionPolicy.canPerformOverlayActionWithoutActivation {
                handled = handleIslandButtonFallback(at: event.locationInWindow, appState: appState)
            }
            if handled {
                return
            }
        }

        super.sendEvent(event)
    }

    private func eventTargetsMouseDownActionOverlay(_ event: NSEvent) -> Bool {
        guard let contentView else { return false }
        let point = contentView.convert(event.locationInWindow, from: nil)
        guard contentView.bounds.contains(point),
              let hitView = contentView.hitTest(point)
        else { return false }

        var current: NSView? = hitView
        while let view = current {
            if view is MouseDownActionNSView {
                return true
            }
            if view === contentView {
                break
            }
            current = view.superview
        }
        return false
    }

    #if DEBUG
    func eventTargetsMouseDownActionOverlayForTesting(at point: NSPoint) -> Bool {
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ) else { return false }
        return eventTargetsMouseDownActionOverlay(event)
    }

    func handleIslandButtonFallbackForTesting(at point: NSPoint) -> Bool {
        guard let appState else { return false }
        return handleIslandButtonFallback(at: point, appState: appState)
    }
    #endif

    private func handleIslandButtonFallback(at point: NSPoint, appState: AppState) -> Bool {
        guard let bounds = contentView?.bounds, bounds.contains(point) else { return false }
        guard !appState.isIdleHiddenBehindNotch else { return false }
        let islandRect = visibleIslandRect(in: bounds, appState: appState)

        if appState.isPanelExpanded {
            return handleExpandedButtonFallback(at: point, in: islandRect, appState: appState)
        }

        switch appState.islandMode {
        case .idle:
            guard appState.isNotchHovered && appState.currentMeeting == nil else { return false }
            return handleCompactRecordButtonFallback(
                at: point,
                in: islandRect,
                appState: appState,
                reservesHoverActionArea: true
            ) {
                appState.isNotchHovered = false
                appState.startManualMeeting()
            }
        case .meetingDetected:
            return handleCompactRecordButtonFallback(
                at: point,
                in: islandRect,
                appState: appState,
                reservesHoverActionArea: appState.isNotchHovered
            ) {
                appState.isNotchHovered = false
                if let meeting = appState.currentMeeting {
                    appState.clearDetectedMeetingOfferTimer()
                    Task { await appState.sessionManager?.startDetectedMeeting(meeting) }
                } else {
                    appState.startManualMeeting()
                }
            }
        case .listening, .suggestedAnswer:
            if appState.currentMeeting != nil {
                return handleCompactListeningButtons(at: point, in: islandRect, appState: appState)
            }
            return handleCompactQuestionAnswerRedirect(at: point, in: islandRect, appState: appState)
        case .questionDetected:
            return handleCompactQuestionAnswerRedirect(at: point, in: islandRect, appState: appState)
        case .thinking:
            return handleCompactQuestionQueueButtons(at: point, in: islandRect, appState: appState)
        case .summaryReady:
            return handleRightPillButton(at: point, in: islandRect, width: 74) {
                appState.openSummaryHandler?()
            }
        case .summarizing:
            return false
        }
    }

    private func handleExpandedButtonFallback(at point: NSPoint, in islandRect: CGRect, appState: AppState) -> Bool {
        if handleExpandedHeaderButtons(at: point, in: islandRect, appState: appState) {
            return true
        }

        return handleExpandedQuestionAnswerButtons(at: point, in: islandRect, appState: appState)
    }

    private func handleExpandedHeaderButtons(at point: NSPoint, in islandRect: CGRect, appState: AppState) -> Bool {
        let topPadding = expandedTopPadding
        let inset = appState.expandedHorizontalContentInset
        let hit = IslandButtonFallbackGeometry.expandedHeaderHit
        let spacing = IslandButtonFallbackGeometry.expandedHeaderSpacing
        let y = islandRect.maxY - topPadding - hit
        let row = CGRect(x: islandRect.minX + inset, y: y, width: islandRect.width - inset * 2, height: hit)
            .insetBy(dx: -IslandButtonFallbackGeometry.horizontalHitSlop, dy: -IslandButtonFallbackGeometry.verticalHitSlop)
        guard row.contains(point) else { return false }

        let leftX = islandRect.minX + inset
        let showsTranslationControl = appState.shouldShowLiveTranslationControl
        let leftRects = buttonRects(startX: leftX, y: y, count: showsTranslationControl ? 3 : 2, hit: hit, spacing: spacing)
        if leftRects.indices.contains(0), IslandButtonFallbackGeometry.expandedHitRect(leftRects[0]).contains(point) {
            if expandedHasActiveMeeting(appState) {
                appState.pauseOrResume()
            } else {
                appState.startManualMeeting()
            }
            return true
        }
        if leftRects.indices.contains(1), IslandButtonFallbackGeometry.expandedHitRect(leftRects[1]).contains(point) {
            if expandedHasActiveMeeting(appState) {
                appState.stopMeeting()
            }
            return true
        }
        if showsTranslationControl,
           leftRects.indices.contains(2),
           IslandButtonFallbackGeometry.expandedHitRect(leftRects[2]).contains(point) {
            appState.toggleLiveTranslation()
            return true
        }

        let rightGroupWidth = hit * 3 + spacing * 2
        let rightX = islandRect.maxX - inset - rightGroupWidth
        let rightRects = buttonRects(startX: rightX, y: y, count: 3, hit: hit, spacing: spacing)
        if rightRects.indices.contains(0), IslandButtonFallbackGeometry.expandedHitRect(rightRects[0]).contains(point) {
            appState.showCopilotHistoryPanel()
            return true
        }
        if rightRects.indices.contains(1), IslandButtonFallbackGeometry.expandedHitRect(rightRects[1]).contains(point) {
            appState.openSettingsHandler?()
            return true
        }
        if rightRects.indices.contains(2), IslandButtonFallbackGeometry.expandedHitRect(rightRects[2]).contains(point) {
            withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.96, blendDuration: 0.04)) {
                appState.collapsePanelPreservingContext()
            }
            return true
        }

        return false
    }

    private func handleExpandedQuestionAnswerButtons(at point: NSPoint, in islandRect: CGRect, appState: AppState) -> Bool {
        guard appState.activeQuestion != nil || appState.suggestedAnswer != nil || !appState.streamingAnswerText.isEmpty else {
            return false
        }

        let inset = appState.expandedHorizontalContentInset
        let panelWidth = appState.expandedPanelContentWidth
        let panelTop = islandRect.maxY
            - NotchIslandChromeMetrics.expandedTopPadding
            - NotchIslandChromeMetrics.expandedHeaderHeight
            - NotchIslandChromeMetrics.expandedHeaderContentSpacing
        let readingWidth = max(1, min(panelWidth - 18, 620))
        let readingX = islandRect.minX + inset + max(0, (panelWidth - readingWidth) / 2)
        let toggleWidth = min(readingWidth, 176)
        let toggleHeight: CGFloat = 26
        let toggleFrame = CGRect(
            x: readingX + max(0, (readingWidth - toggleWidth) / 2),
            y: panelTop - 2 - toggleHeight,
            width: toggleWidth,
            height: toggleHeight
        )

        let toggleRect = toggleFrame.insetBy(dx: -5, dy: -5)

        if toggleRect.contains(point) {
            let isTranscriptHalf = point.x >= toggleRect.midX
            withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.9)) {
                appState.selectPresentationMode(isTranscriptHalf ? .transcript : .answer)
            }
            return true
        }

        guard appState.questionAnswerPresentationMode == .answer,
              appState.questionAnswerQueue.count > 1
        else { return false }

        let questionTop = toggleFrame.minY - 16
        let navY = questionTop - 32
        let leftNav = CGRect(x: readingX - 4, y: navY, width: 38, height: 38)
        let rightNav = CGRect(x: readingX + readingWidth - 34, y: navY, width: 38, height: 38)

        if leftNav.contains(point) {
            withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.9)) {
                appState.selectPreviousQuestion()
            }
            return true
        }

        if rightNav.contains(point) {
            withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.9)) {
                appState.selectNextQuestion()
            }
            return true
        }

        return false
    }

    private func handleCompactListeningButtons(at point: NSPoint, in islandRect: CGRect, appState: AppState) -> Bool {
        let hit = IslandButtonFallbackGeometry.compactListeningHit
        let spacing = IslandButtonFallbackGeometry.compactListeningSpacing
        let inset = compactHorizontalPadding(appState)
        let groupWidth = hit * 4 + spacing * 3
        let y = islandRect.midY - hit / 2
        let rects = buttonRects(startX: islandRect.maxX - inset - groupWidth, y: y, count: 4, hit: hit, spacing: spacing)

        guard rects.contains(where: { IslandButtonFallbackGeometry.compactHitRect($0).contains(point) }) else { return false }

        if IslandButtonFallbackGeometry.compactHitRect(rects[0]).contains(point) {
            appState.pauseOrResume()
            return true
        }
        if IslandButtonFallbackGeometry.compactHitRect(rects[1]).contains(point) {
            appState.stopMeeting()
            return true
        }
        if IslandButtonFallbackGeometry.compactHitRect(rects[2]).contains(point) {
            appState.toggleLiveTranslation()
            return true
        }
        if IslandButtonFallbackGeometry.compactHitRect(rects[3]).contains(point) {
            appState.openSettingsHandler?()
            return true
        }

        return false
    }

    private func handleCompactQuestionAnswerRedirect(at point: NSPoint, in islandRect: CGRect, appState: AppState) -> Bool {
        guard islandRect.contains(point) else { return false }
        withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.96, blendDuration: 0.04)) {
            appState.showQuestionAnswerPanel(mode: .answer)
        }
        return true
    }

    private func handleCompactQuestionQueueButtons(at point: NSPoint, in islandRect: CGRect, appState: AppState) -> Bool {
        let inset = compactHorizontalPadding(appState)
        let hit = IslandButtonFallbackGeometry.compactQuestionHit
        let topY = islandRect.maxY - compactTopPadding(appState) - hit
        let dismissFrame = CGRect(x: islandRect.maxX - inset - hit, y: topY, width: hit, height: hit)
        let dismissRect = IslandButtonFallbackGeometry.compactHitRect(dismissFrame)

        let hasDismissButton = appState.islandMode == .questionDetected || (appState.islandMode == .suggestedAnswer && appState.currentMeeting == nil)
        if hasDismissButton {
            if dismissRect.contains(point) {
                appState.dismissActiveQuestion()
                return true
            }
        }

        guard appState.questionAnswerQueue.count > 1 else { return false }

        let queueWidth = IslandButtonFallbackGeometry.compactQuestionQueueWidth
        let queueRight = hasDismissButton ? dismissFrame.minX - 6 : islandRect.maxX - inset
        let prevRect = IslandButtonFallbackGeometry.compactHitRect(CGRect(x: queueRight - queueWidth, y: topY, width: hit, height: hit))
        let nextRect = IslandButtonFallbackGeometry.compactHitRect(CGRect(x: queueRight - hit, y: topY, width: hit, height: hit))

        if prevRect.contains(point) {
            appState.selectPreviousQuestion()
            return true
        }

        if nextRect.contains(point) {
            appState.selectNextQuestion()
            return true
        }

        return false
    }

    private func handleCenteredPillButton(
        at point: NSPoint,
        in islandRect: CGRect,
        appState: AppState,
        reservesHoverActionArea: Bool = false,
        action: @escaping () -> Void
    ) -> Bool {
        let horizontalInset = compactHorizontalPadding(appState)
        let buttonRect = IslandButtonFallbackGeometry.compactRecordButtonRect(
            in: islandRect,
            horizontalInset: horizontalInset
        )
        if reservesHoverActionArea {
            let actionRects = IslandButtonFallbackGeometry.compactRecordHoverActionHitRects(in: buttonRect)
            if actionRects.settings.contains(point) || actionRects.history.contains(point) {
                return false
            }
        }

        let rect = IslandButtonFallbackGeometry.compactRecordPrimaryHitRect(
            in: buttonRect,
            reservesHoverActionArea: reservesHoverActionArea
        )

        guard rect.contains(point) else { return false }
        appState.triggerCompactRecordButtonFeedback()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(92))
            action()
        }
        return true
    }

    private func handleCompactRecordButtonFallback(
        at point: NSPoint,
        in islandRect: CGRect,
        appState: AppState,
        reservesHoverActionArea: Bool,
        primaryAction: @escaping () -> Void
    ) -> Bool {
        let buttonRect = IslandButtonFallbackGeometry.compactRecordButtonRect(
            in: islandRect,
            horizontalInset: compactHorizontalPadding(appState)
        )

        if reservesHoverActionArea {
            let actionRects = IslandButtonFallbackGeometry.compactRecordHoverActionHitRects(in: buttonRect)
            if actionRects.settings.contains(point) {
                appState.isNotchHovered = false
                appState.openSettingsHandler?()
                return true
            }

            if actionRects.history.contains(point) {
                appState.isNotchHovered = false
                appState.showCopilotHistoryPanel()
                return true
            }
        }

        let primaryRect = IslandButtonFallbackGeometry.compactRecordPrimaryHitRect(
            in: buttonRect,
            reservesHoverActionArea: reservesHoverActionArea
        )

        guard primaryRect.contains(point) else { return false }
        appState.triggerCompactRecordButtonFeedback()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(92))
            primaryAction()
        }
        return true
    }

    private func handleRightPillButton(at point: NSPoint, in islandRect: CGRect, width: CGFloat = 92, action: () -> Void) -> Bool {
        let rect = CGRect(
            x: islandRect.maxX - width,
            y: islandRect.minY,
            width: width,
            height: islandRect.height
        ).insetBy(dx: -4, dy: -4)

        guard rect.contains(point) else { return false }
        action()
        return true
    }

    private func buttonRects(startX: CGFloat, y: CGFloat, count: Int, hit: CGFloat, spacing: CGFloat) -> [CGRect] {
        (0..<count).map { index in
            CGRect(x: startX + CGFloat(index) * (hit + spacing), y: y, width: hit, height: hit)
        }
    }

    private func visibleIslandRect(in bounds: CGRect, appState: AppState) -> CGRect {
        let size = appState.notchIslandSize
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    private var expandedTopPadding: CGFloat { NotchIslandChromeMetrics.expandedTopPadding }

    private func compactTopPadding(_ appState: AppState) -> CGFloat {
        if appState.islandMode == .idle && !appState.isPanelExpanded {
            return appState.isNotchHovered ? 24 : 6
        }
        if appState.islandMode == .meetingDetected && !appState.isPanelExpanded {
            return 24
        }
        if appState.islandMode == .listening && !appState.isPanelExpanded {
            return 8
        }
        return 8
    }

    private func compactHorizontalPadding(_ appState: AppState) -> CGFloat {
        if appState.islandMode == .idle && !appState.isPanelExpanded {
            return appState.isNotchHovered ? NotchIslandChromeMetrics.compactRecordButtonHorizontalInset : 8
        }
        if appState.islandMode == .meetingDetected && !appState.isPanelExpanded {
            return NotchIslandChromeMetrics.compactRecordButtonHorizontalInset
        }
        if appState.islandMode == .listening && !appState.isPanelExpanded {
            return NotchIslandChromeMetrics.compactListeningHorizontalPadding
        }
        return 12
    }

    private func expandedHasActiveMeeting(_ appState: AppState) -> Bool {
        guard let status = appState.currentMeeting?.status else { return false }
        return status == .listening || status == .paused
    }
}

final class InteractiveHostingView<Content: View>: NSHostingView<Content> {
    override var acceptsFirstResponder: Bool { false }
    override var safeAreaInsets: NSEdgeInsets { .init() }

    override func becomeFirstResponder() -> Bool {
        false
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

enum IslandButtonFallbackGeometry {
    static let expandedHeaderSpacing: CGFloat = 8
    static let compactListeningSpacing: CGFloat = 6
    static let compactQuestionQueueSpacing: CGFloat = 5
    static let compactQuestionCounterWidth: CGFloat = 28
    static let horizontalHitSlop: CGFloat = 5
    static let verticalHitSlop: CGFloat = 8

    static var expandedHeaderHit: CGFloat { IconButtonSize.header.hitDiameter }
    static var compactListeningHit: CGFloat { IconButtonSize.compact.hitDiameter }
    static var compactQuestionHit: CGFloat { IconButtonSize.standard.hitDiameter }

    static var compactQuestionQueueWidth: CGFloat {
        compactQuestionHit * 2 + compactQuestionCounterWidth + compactQuestionQueueSpacing * 2
    }

    static func compactRecordButtonRect(
        in islandRect: CGRect,
        horizontalInset: CGFloat = NotchIslandChromeMetrics.compactRecordButtonHorizontalInset
    ) -> CGRect {
        CGRect(
            x: islandRect.minX + horizontalInset,
            y: islandRect.minY + NotchIslandChromeMetrics.compactRecordButtonBottomInset,
            width: max(1, islandRect.width - horizontalInset * 2),
            height: NotchIslandChromeMetrics.compactRecordButtonHeight
        )
    }

    static func compactRecordPrimaryHitRect(
        in buttonRect: CGRect,
        reservesHoverActionArea: Bool
    ) -> CGRect {
        let rect: CGRect
        if reservesHoverActionArea {
            let reservedWidth = NotchIslandChromeMetrics.compactRecordHoverActionsButtonWidth +
                NotchIslandChromeMetrics.compactRecordHoverActionTrailingGap
            rect = CGRect(
                x: buttonRect.minX + reservedWidth,
                y: buttonRect.minY,
                width: max(1, buttonRect.width - reservedWidth),
                height: buttonRect.height
            )
        } else {
            rect = buttonRect
        }
        return rect.insetBy(dx: -4, dy: -4)
    }

    static func compactRecordHoverActionHitRects(in buttonRect: CGRect) -> (settings: CGRect, history: CGRect) {
        let hit = NotchIslandChromeMetrics.compactRecordHoverActionHitDiameter
        let spacing = NotchIslandChromeMetrics.compactRecordHoverActionSpacing
        let splitGap = spacing / 2
        let settings = CGRect(
            x: buttonRect.minX,
            y: buttonRect.minY,
            width: hit + splitGap,
            height: buttonRect.height
        )
        let history = CGRect(
            x: settings.maxX,
            y: buttonRect.minY,
            width: hit + splitGap,
            height: buttonRect.height
        )
        return (settings, history)
    }

    static func expandedHeaderButtonRects(startX: CGFloat, y: CGFloat, count: Int) -> [CGRect] {
        buttonRects(startX: startX, y: y, count: count, hit: expandedHeaderHit, spacing: expandedHeaderSpacing)
    }

    static func compactListeningButtonRects(startX: CGFloat, y: CGFloat, count: Int) -> [CGRect] {
        buttonRects(startX: startX, y: y, count: count, hit: compactListeningHit, spacing: compactListeningSpacing)
    }

    static func expandedHitRect(_ rect: CGRect) -> CGRect {
        rect.insetBy(dx: -horizontalHitSlop, dy: -verticalHitSlop)
    }

    static func compactHitRect(_ rect: CGRect) -> CGRect {
        rect.insetBy(dx: -4, dy: -verticalHitSlop)
    }

    static func buttonRects(startX: CGFloat, y: CGFloat, count: Int, hit: CGFloat, spacing: CGFloat) -> [CGRect] {
        (0..<count).map { index in
            CGRect(x: startX + CGFloat(index) * (hit + spacing), y: y, width: hit, height: hit)
        }
    }
}

final class NotchInteractionContainerView<Content: View>: NSView {
    private weak var appState: AppState?
    private let hostingView: InteractiveHostingView<Content>
    private let visibleIslandHitInset: CGFloat = 6
    private let hoverExitDelayMs = 260
    private let hoverGraceInset: CGFloat = 14
    private var hoverTrackingArea: NSTrackingArea?
    private var hoverExitTask: Task<Void, Never>?

    init(rootView: Content, appState: AppState) {
        self.appState = appState
        self.hostingView = InteractiveHostingView(rootView: rootView)
        super.init(frame: CGRect(origin: .zero, size: appState.notchIslandCanvasSize))
        wantsLayer = true
        layer?.masksToBounds = true
        hostingView.frame = bounds
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.masksToBounds = true
        addSubview(hostingView)
    }

    @MainActor @preconcurrency required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override func becomeFirstResponder() -> Bool {
        false
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostingView.frame = bounds
        CATransaction.commit()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostingView.frame = bounds
        CATransaction.commit()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        hoverTrackingArea = trackingArea
        addTrackingArea(trackingArea)
        super.updateTrackingAreas()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let appState else { return nil }
        guard bounds.contains(point) else { return nil }
        if shouldRouteToHostedContent(at: point, appState: appState) {
            let hostedPoint = convert(point, to: hostingView)
            return hostingView.hitTest(hostedPoint) ?? hostingView
        }
        if shouldHandleLocally(at: point, appState: appState) {
            return self
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let appState else {
            super.mouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if shouldHandleLocally(at: point, appState: appState) {
            _ = FocusSafeInteractionPolicy.canPerformOverlayActionWithoutActivation {
                handleLocalClick(at: point, appState: appState)
            }
            return
        }
        super.mouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let appState else {
            super.scrollWheel(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if appState.isIdleHiddenBehindNotch,
           notchActivationRect(appState: appState).contains(point),
           abs(event.scrollingDeltaY) + abs(event.scrollingDeltaX) > 0.2 {
            _ = FocusSafeInteractionPolicy.canPerformOverlayActionWithoutActivation {
                withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.96, blendDuration: 0.04)) {
                    appState.isNotchHovered = false
                    appState.handleNotchRegionClick()
                }
            }
            return
        }
        super.scrollWheel(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(for: event)
        super.mouseMoved(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(for: event)
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        guard let appState else {
            super.mouseExited(with: event)
            return
        }
        scheduleNotchHoverExit(appState)
        super.mouseExited(with: event)
    }

    private func updateHover(for event: NSEvent) {
        guard let appState else { return }
        let point = convert(event.locationInWindow, from: nil)
        setNotchHover(shouldMaintainHover(at: point, appState: appState))
    }

    private func setNotchHover(_ isHovered: Bool) {
        guard let appState else { return }
        let shouldHover = isHovered && supportsCompactRecordHoverActions(appState)
        if shouldHover {
            hoverExitTask?.cancel()
            applyNotchHover(true, appState: appState)
            return
        }
        scheduleNotchHoverExit(appState)
    }

    private func applyNotchHover(_ shouldHover: Bool, appState: AppState) {
        guard appState.isNotchHovered != shouldHover else { return }
        withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.96, blendDuration: 0.04)) {
            appState.isNotchHovered = shouldHover
        }
    }

    private func scheduleNotchHoverExit(_ appState: AppState) {
        hoverExitTask?.cancel()
        hoverExitTask = Task { @MainActor [weak self, weak appState] in
            try? await Task.sleep(for: .milliseconds(self?.hoverExitDelayMs ?? 260))
            guard let self, let appState else { return }
            guard !Task.isCancelled else { return }
            if let currentPoint = self.currentMousePointInBounds(),
               self.shouldMaintainHover(at: currentPoint, appState: appState, allowsGrace: true) {
                self.applyNotchHover(true, appState: appState)
                return
            }
            self.applyNotchHover(false, appState: appState)
        }
    }

    private func shouldHandleLocally(at point: NSPoint, appState: AppState) -> Bool {
        if appState.isIdleHiddenBehindNotch {
            return notchActivationRect(appState: appState).contains(point)
        }
        return appState.islandMode == .idle &&
            !appState.isPanelExpanded &&
            appState.currentMeeting == nil &&
            appState.isNotchHovered &&
            visibleIslandRect(appState: appState).contains(point)
    }

    private func handleLocalClick(at point: NSPoint, appState: AppState) {
        if appState.isIdleHiddenBehindNotch {
            withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.96, blendDuration: 0.04)) {
                appState.handleNotchRegionClick()
            }
            return
        }

        let islandRect = visibleIslandRect(appState: appState)
        let buttonRect = compactRecordButtonRect(in: islandRect, appState: appState)
        let actionRects = IslandButtonFallbackGeometry.compactRecordHoverActionHitRects(in: buttonRect)

        if actionRects.settings.contains(point) {
            appState.isNotchHovered = false
            appState.openSettingsHandler?()
            return
        }

        if actionRects.history.contains(point) {
            appState.isNotchHovered = false
            appState.showCopilotHistoryPanel()
            return
        }

        let primaryRect = IslandButtonFallbackGeometry.compactRecordPrimaryHitRect(
            in: buttonRect,
            reservesHoverActionArea: appState.isNotchHovered
        )

        if primaryRect.contains(point) {
            appState.isNotchHovered = false
            appState.startManualMeeting()
            return
        }

        withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.96, blendDuration: 0.04)) {
            appState.isNotchHovered = false
            appState.handleNotchRegionClick()
        }
    }

    private func shouldMaintainHover(at point: NSPoint, appState: AppState) -> Bool {
        shouldMaintainHover(at: point, appState: appState, allowsGrace: false)
    }

    private func shouldMaintainHover(at point: NSPoint, appState: AppState, allowsGrace: Bool) -> Bool {
        guard supportsCompactRecordHoverActions(appState) else { return false }
        if appState.islandMode == .idle,
           appState.currentMeeting == nil,
           notchActivationRect(appState: appState).contains(point) {
            return true
        }
        let islandRect = visibleIslandRect(appState: appState)
        let hoverRect = allowsGrace ? islandRect.insetBy(dx: -hoverGraceInset, dy: -hoverGraceInset) : islandRect
        return (appState.isNotchHovered || appState.islandMode == .meetingDetected) && hoverRect.contains(point)
    }

    private func supportsCompactRecordHoverActions(_ appState: AppState) -> Bool {
        !appState.isPanelExpanded &&
            !appState.shouldShowAmbientCopilotIdle &&
            ((appState.islandMode == .idle && appState.currentMeeting == nil) ||
             appState.islandMode == .meetingDetected)
    }

    private func compactRecordButtonRect(in islandRect: CGRect, appState: AppState) -> CGRect {
        let horizontalInset: CGFloat
        if appState.islandMode == .idle || appState.islandMode == .meetingDetected {
            horizontalInset = NotchIslandChromeMetrics.compactRecordButtonHorizontalInset
        } else {
            horizontalInset = 12
        }
        return IslandButtonFallbackGeometry.compactRecordButtonRect(
            in: islandRect,
            horizontalInset: horizontalInset
        )
    }

    #if DEBUG
    func shouldMaintainHoverForTesting(at point: NSPoint, allowingGrace: Bool = false) -> Bool {
        guard let appState else { return false }
        return shouldMaintainHover(at: point, appState: appState, allowsGrace: allowingGrace)
    }
    #endif

    private func currentMousePointInBounds() -> NSPoint? {
        guard let window else { return nil }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let localPoint = convert(windowPoint, from: nil)
        return bounds.insetBy(dx: -hoverGraceInset, dy: -hoverGraceInset).contains(localPoint) ? localPoint : nil
    }

    private func isVisibleIslandPoint(_ point: NSPoint, appState: AppState) -> Bool {
        guard !appState.isIdleHiddenBehindNotch else { return false }
        let isVisible = appState.isPanelExpanded ||
            appState.isNotchHovered ||
            appState.currentMeeting != nil ||
            appState.islandMode != .idle
        guard isVisible else { return false }
        return visibleIslandRect(appState: appState)
            .insetBy(dx: -visibleIslandHitInset, dy: -visibleIslandHitInset)
            .contains(point)
    }

    private func shouldRouteToHostedContent(at point: NSPoint, appState: AppState) -> Bool {
        guard !appState.isIdleHiddenBehindNotch else { return false }
        if appState.isPanelExpanded {
            return logicalCanvasRect(appState: appState).contains(point)
        }
        return isVisibleIslandPoint(point, appState: appState)
    }

    private func logicalCanvasRect(appState: AppState) -> CGRect {
        let size = appState.notchIslandCanvasSize
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    private func visibleIslandRect(appState: AppState) -> CGRect {
        let size = appState.notchIslandSize
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    private func notchActivationRect(appState: AppState) -> CGRect {
        if appState.islandMode == .idle &&
            !appState.isPanelExpanded &&
            appState.currentMeeting == nil {
            return logicalCanvasRect(appState: appState)
        }

        let footprint = NotchIslandChromeMetrics.collapsedNotchFootprintSize
        return CGRect(
            x: bounds.midX - footprint.width / 2,
            y: bounds.maxY - footprint.height,
            width: footprint.width,
            height: footprint.height
        )
    }
}
