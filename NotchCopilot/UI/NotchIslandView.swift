import AppKit
import SwiftUI

struct NotchIslandView: View {
    @ObservedObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var islandSpring: Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .interactiveSpring(response: 0.24, dampingFraction: 0.96, blendDuration: 0.04)
    }
    private var contentFade: Animation {
        reduceMotion ? .easeOut(duration: 0.08) : .easeInOut(duration: 0.14)
    }
    private let chromeSettleDelayMs = 280
    private let primaryText = Color.white.opacity(0.92)
    private let secondaryText = Color.white.opacity(0.58)
    private let hairline = Color.white.opacity(0.055)
    private let notchKeepoutExpanded: CGFloat = 184
    private let notchKeepoutCompactRatio: CGFloat = 0.38
    @State private var renderedIslandSize: CGSize = .zero
    @State private var renderedCanvasSize: CGSize = .zero
    @State private var didInitializeChromeMetrics = false
    @State private var chromeSettleTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
            ZStack(alignment: .top) {
                islandChromeBackground
                islandContent
                    .frame(width: contentWidth, height: contentHeight, alignment: .top)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, topPadding)
                    .padding(.bottom, bottomPadding)
                    .opacity(appState.isPanelExpanded ? 1 : 0.98)
                    .animation(.easeInOut(duration: 0.16), value: appState.isPanelExpanded)
            }
            .frame(width: chromeIslandSize.width, height: chromeIslandSize.height, alignment: .top)
            .clipShape(islandShape, style: FillStyle(eoFill: false, antialiased: true))
            .overlay(
                islandShape
                    .stroke(islandStrokeColor, lineWidth: islandStrokeWidth)
                    .allowsHitTesting(false)
            )
            .compositingGroup()
            .shadow(color: islandShadowColor, radius: islandShadowRadius, x: 0, y: islandShadowYOffset)
            .offset(y: islandVerticalOffset)
            .animation(islandSpring, value: chromeIslandSize)
            .animation(islandSpring, value: appState.isPanelExpanded)
            .animation(islandSpring, value: isHiddenBehindNotch)
            .animation(contentFade, value: appState.preferences.islandDesignMode)
        }
        .environment(\.islandDesignMode, appState.preferences.islandDesignMode)
        .frame(width: chromeCanvasSize.width, height: chromeCanvasSize.height, alignment: .top)
        .ignoresSafeArea(.all)
        .background(
            AppleNativeTranslationTaskHostView()
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            syncChromeMetrics(animated: false)
        }
        .onChange(of: appState.notchIslandSize) {
            syncChromeMetrics(animated: true)
        }
        .onChange(of: appState.notchIslandCanvasSize) {
            syncChromeMetrics(animated: true)
        }
        .onDisappear {
            chromeSettleTask?.cancel()
        }
    }

    private var chromeIslandSize: CGSize {
        didInitializeChromeMetrics ? renderedIslandSize : appState.notchIslandSize
    }

    private var chromeCanvasSize: CGSize {
        didInitializeChromeMetrics ? renderedCanvasSize : appState.notchIslandCanvasSize
    }

    private func syncChromeMetrics(animated: Bool) {
        let targetIslandSize = appState.notchIslandSize
        let targetCanvasSize = appState.notchIslandCanvasSize

        guard didInitializeChromeMetrics else {
            renderedIslandSize = targetIslandSize
            renderedCanvasSize = targetCanvasSize
            didInitializeChromeMetrics = true
            return
        }

        chromeSettleTask?.cancel()

        guard animated else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                renderedIslandSize = targetIslandSize
                renderedCanvasSize = targetCanvasSize
            }
            return
        }

        let envelopeCanvasSize = CGSize(
            width: max(renderedCanvasSize.width, targetCanvasSize.width, targetIslandSize.width),
            height: max(renderedCanvasSize.height, targetCanvasSize.height, targetIslandSize.height)
        )

        var immediateTransaction = Transaction()
        immediateTransaction.disablesAnimations = true
        withTransaction(immediateTransaction) {
            renderedCanvasSize = envelopeCanvasSize
        }

        withAnimation(islandSpring) {
            renderedIslandSize = targetIslandSize
        }

        chromeSettleTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(chromeSettleDelayMs))
            guard !Task.isCancelled else { return }
            var settleTransaction = Transaction()
            settleTransaction.disablesAnimations = true
            withTransaction(settleTransaction) {
                renderedCanvasSize = targetCanvasSize
            }
        }
    }

    private var isHiddenBehindNotch: Bool {
        appState.isIdleHiddenBehindNotch
    }

    private var isLiquidGlassDesign: Bool {
        appState.preferences.islandDesignMode == .liquidGlass
    }

    @ViewBuilder
    private var islandChromeBackground: some View {
        if usesFlushCompactCopilotChrome {
            Color.black
                .opacity(isLiquidGlassDesign ? 0.88 : 0.98)
                .allowsHitTesting(false)
        } else if isLiquidGlassDesign {
            liquidGlassIslandBackground
        } else {
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                .allowsHitTesting(false)
            LinearGradient(
                colors: [Color.black.opacity(0.98), Color(red: 0.025, green: 0.025, blue: 0.025).opacity(0.94)],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var liquidGlassIslandBackground: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 0) {
                Color.clear
                    .glassEffect(
                        .regular
                            .tint(Color.white.opacity(appState.isPanelExpanded ? 0.078 : 0.064))
                            .interactive(true),
                        in: islandShape
                    )
            }
            .background {
                islandShape
                    .fill(Color.black.opacity(appState.isPanelExpanded ? 0.22 : 0.18))
            }
            .allowsHitTesting(false)
        } else {
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                .opacity(0.92)
                .allowsHitTesting(false)
            islandShape
                .fill(Color.black.opacity(appState.isPanelExpanded ? 0.28 : 0.22))
                .allowsHitTesting(false)
        }

        LinearGradient(
            colors: [
                Color.white.opacity(appState.isPanelExpanded ? 0.060 : 0.046),
                Color.black.opacity(appState.isPanelExpanded ? 0.18 : 0.14)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .allowsHitTesting(false)
    }

    private var islandStrokeColor: Color {
        if usesFlushCompactCopilotChrome {
            return .clear
        }
        return isLiquidGlassDesign ? Color.white.opacity(0.135) : hairline
    }

    private var islandStrokeWidth: CGFloat {
        if usesFlushCompactCopilotChrome {
            return 0
        }
        return isLiquidGlassDesign ? 0.7 : 0.6
    }

    private var islandShadowColor: Color {
        if usesFlushCompactCopilotChrome {
            return .clear
        }
        if isLiquidGlassDesign {
            return Color.black.opacity(appState.isPanelExpanded ? 0.14 : 0.18)
        }
        return Color.black.opacity(appState.isPanelExpanded ? 0.18 : 0.22)
    }

    private var islandShadowRadius: CGFloat {
        if usesFlushCompactCopilotChrome {
            return 0
        }
        if isLiquidGlassDesign {
            return appState.isPanelExpanded ? 12 : 8
        }
        return appState.isPanelExpanded ? 8 : 6
    }

    private var islandShadowYOffset: CGFloat {
        if usesFlushCompactCopilotChrome {
            return 0
        }
        if isLiquidGlassDesign {
            return appState.isPanelExpanded ? 6 : 4
        }
        return appState.isPanelExpanded ? 5 : 3
    }

    private var isCompactListeningMode: Bool {
        (appState.islandMode == .listening || appState.shouldShowAmbientCopilotIdle) && !appState.isPanelExpanded
    }

    private var isCompactCopilotIndicatorMode: Bool {
        appState.shouldShowCopilotPushToTalkCompactIndicator ||
            appState.shouldShowAmbientCopilotLoadingIndicator ||
            appState.shouldShowAmbientCopilotMicroState
    }

    private var usesFlushCompactCopilotChrome: Bool {
        false
    }

    private var islandVerticalOffset: CGFloat {
        isHiddenBehindNotch ? -(chromeIslandSize.height + 2) : 0
    }

    private var horizontalPadding: CGFloat {
        if isCompactListeningMode {
            return NotchIslandChromeMetrics.compactListeningHorizontalPadding
        }
        if appState.islandMode == .idle && !appState.isPanelExpanded {
            return appState.isNotchHovered ? NotchIslandChromeMetrics.compactRecordButtonHorizontalInset : 8
        }
        if appState.islandMode == .meetingDetected && !appState.isPanelExpanded {
            return NotchIslandChromeMetrics.compactRecordButtonHorizontalInset
        }
        return appState.isPanelExpanded ? appState.expandedHorizontalContentInset : 12
    }

    private var topPadding: CGFloat {
        if isCompactCopilotIndicatorMode {
            return 24
        }
        if isCompactListeningMode {
            return 8
        }
        if appState.islandMode == .idle && !appState.isPanelExpanded {
            return appState.isNotchHovered ? 24 : 6
        }
        if appState.islandMode == .meetingDetected && !appState.isPanelExpanded {
            return 24
        }
        return appState.isPanelExpanded ? NotchIslandChromeMetrics.expandedTopPadding : 8
    }

    private var bottomPadding: CGFloat {
        if isCompactCopilotIndicatorMode {
            return 6
        }
        if isCompactListeningMode {
            return 8
        }
        if appState.islandMode == .idle && !appState.isPanelExpanded {
            return appState.isNotchHovered ? NotchIslandChromeMetrics.compactRecordButtonBottomInset : 6
        }
        if appState.islandMode == .meetingDetected && !appState.isPanelExpanded {
            return NotchIslandChromeMetrics.compactRecordButtonBottomInset
        }
        return appState.isPanelExpanded ? 0 : 8
    }

    private var contentWidth: CGFloat {
        max(1, chromeIslandSize.width - horizontalPadding * 2)
    }

    private var contentHeight: CGFloat {
        max(1, chromeIslandSize.height - topPadding - bottomPadding)
    }

    private var notchKeepoutWidth: CGFloat {
        if appState.isPanelExpanded {
            return notchKeepoutExpanded
        }
        if isCompactListeningMode {
            return NotchIslandChromeMetrics.compactListeningNotchKeepoutWidth
        }
        return min(184, max(146, chromeIslandSize.width * notchKeepoutCompactRatio))
    }

    private var islandShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(
                topLeading: 0,
                bottomLeading: appState.notchCornerRadius,
                bottomTrailing: appState.notchCornerRadius,
                topTrailing: 0
            ),
            style: .continuous
        )
    }

    @ViewBuilder
    private var islandContent: some View {
        if appState.isPanelExpanded {
            expandedIslandContent
        } else {
            compactContent
        }
    }

    @ViewBuilder
    private var compactContent: some View {
        if appState.shouldShowCopilotPushToTalkCompactIndicator {
            compactCopilotIndicatorContent(isProcessing: appState.shouldShowCopilotPushToTalkProcessingIndicator)
        } else {
            VStack(spacing: 0) {
                switch appState.islandMode {
                case .idle:
                    idleContent
                case .meetingDetected:
                    meetingDetectedContent
                case .listening:
                    listeningContent
                case .questionDetected:
                    questionAnswerRedirectContent
                case .thinking:
                    thinkingContent
                case .summarizing:
                    summarizingContent
                case .suggestedAnswer:
                    if appState.currentMeeting != nil {
                        listeningContent
                    } else {
                        questionAnswerRedirectContent
                    }
                case .summaryReady:
                    summaryReadyContent
                }
            }
        }
    }

    private var expandedIslandContent: some View {
        VStack(spacing: NotchIslandChromeMetrics.expandedHeaderContentSpacing) {
            expandedHeader
            MeetingPanelView(appState: appState)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(primaryText)
    }

    private var expandedHeader: some View {
        notchAwareBar {
            HStack(spacing: 8) {
                headerControlButton(systemName: expandedPrimaryControlIcon, help: expandedPrimaryControlHelp) {
                    if expandedHasActiveMeeting {
                        appState.pauseOrResume()
                    } else {
                        appState.startManualMeeting()
                    }
                }
                headerControlButton(systemName: "stop.fill", help: "Stop", role: .destructive, isDisabled: !expandedHasActiveMeeting) {
                    appState.stopMeeting()
                }
                IconButton(
                    systemName: "translate",
                    help: appState.preferences.liveTranslationEnabled ? "Disable translation" : "Enable translation",
                    isActive: appState.preferences.liveTranslationEnabled,
                    size: .header
                ) {
                    appState.toggleLiveTranslation()
                }
                if appState.currentMeeting != nil {
                    Text(DateFormatting.duration(appState.elapsed))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(secondaryText)
                        .lineLimit(1)
                    .padding(.leading, 2)
                }
            }
        } right: {
            HStack(spacing: 8) {
                IconButton(systemName: "clock.arrow.circlepath", help: "Notchly history", size: .header) { appState.showCopilotHistoryPanel() }
                IconButton(systemName: "gearshape", help: "Settings", size: .header) { appState.openSettingsHandler?() }
                IconButton(systemName: "chevron.up", help: "Collapse", size: .header) {
                    withAnimation(islandSpring) {
                        appState.collapsePanelPreservingContext()
                    }
                }
            }
        }
        .frame(height: NotchIslandChromeMetrics.expandedHeaderHeight, alignment: .top)
        .animation(contentFade, value: expandedHasActiveMeeting)
    }

    private var expandedHasActiveMeeting: Bool {
        guard let status = appState.currentMeeting?.status else { return false }
        return status == .listening || status == .paused
    }

    private var expandedPrimaryControlIcon: String {
        appState.currentMeeting?.status == .listening ? "pause.fill" : "play.fill"
    }

    private var expandedPrimaryControlHelp: String {
        if appState.currentMeeting?.status == .listening { return "Pause" }
        if appState.currentMeeting?.status == .paused { return "Resume" }
        return "Start"
    }

    private func headerControlButton(systemName: String, help: String, role: ButtonRole? = nil, isDisabled: Bool = false, action: @escaping () -> Void) -> some View {
        IconButton(
            systemName: systemName,
            help: help,
            role: role,
            isDisabled: isDisabled,
            size: .header,
            action: action
        )
    }

    @ViewBuilder
    private func recordButton(
        iconResolution: MeetingAppIconResolution,
        remainingSeconds: Int? = nil,
        showsIcon: Bool = true,
        showsHoverActions: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        if showsHoverActions && showsCompactRecordSideActions {
            HStack(spacing: NotchIslandChromeMetrics.compactRecordHoverActionTrailingGap) {
                compactRecordHoverControls
                recordPillButton(
                    iconResolution: iconResolution,
                    remainingSeconds: remainingSeconds,
                    showsIcon: showsIcon,
                    width: compactRecordPrimaryButtonWidth,
                    action: action
                )
            }
            .frame(width: recordButtonWidth, height: NotchIslandChromeMetrics.compactRecordButtonHeight, alignment: .leading)
            .transition(.opacity.combined(with: .move(edge: .leading)))
            .animation(contentFade, value: showsCompactRecordSideActions)
        } else {
            recordPillButton(
                iconResolution: iconResolution,
                remainingSeconds: remainingSeconds,
                showsIcon: showsIcon,
                width: recordButtonWidth,
                action: action
            )
        }
    }

    private var recordButtonWidth: CGFloat {
        max(1, contentWidth)
    }

    private var showsCompactRecordSideActions: Bool {
        appState.isNotchHovered &&
            !appState.isPanelExpanded &&
            !appState.shouldShowAmbientCopilotIdle &&
            (appState.islandMode == .idle || appState.islandMode == .meetingDetected)
    }

    private var compactRecordPrimaryButtonWidth: CGFloat {
        max(
            1,
            recordButtonWidth -
                NotchIslandChromeMetrics.compactRecordHoverActionsButtonWidth -
                NotchIslandChromeMetrics.compactRecordHoverActionTrailingGap
        )
    }

    private var compactRecordHoverControls: some View {
        HStack(spacing: NotchIslandChromeMetrics.compactRecordHoverActionSpacing) {
            IconButton(systemName: "gearshape", help: "Settings", size: .compact, feedbackDelayMs: 76) {
                appState.openSettingsHandler?()
            }
            IconButton(systemName: "clock.arrow.circlepath", help: "Notchly history", size: .compact, feedbackDelayMs: 76) {
                appState.showCopilotHistoryPanel()
            }
        }
        .frame(
            width: NotchIslandChromeMetrics.compactRecordHoverActionsButtonWidth,
            height: NotchIslandChromeMetrics.compactRecordButtonHeight,
            alignment: .leading
        )
    }

    private func recordPillButton(
        iconResolution: MeetingAppIconResolution,
        remainingSeconds: Int?,
        showsIcon: Bool,
        width: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        RecordPillButton(
            iconResolution: iconResolution,
            remainingSeconds: remainingSeconds,
            showsIcon: showsIcon,
            width: width,
            feedbackTrigger: appState.compactRecordButtonFeedbackTrigger
        ) {
            performRecordButtonAction(action)
        }
    }

    private func performRecordButtonAction(_ action: @escaping () -> Void) {
        appState.triggerCompactRecordButtonFeedback()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(92))
            action()
        }
    }

    private func openSummaryButton(action: @escaping () -> Void) -> some View {
        IslandPillButton(title: "Open", help: "Open summary", width: 62, height: 32, fontSize: 12, action: action)
    }

    private var idleContent: some View {
        Group {
            if appState.shouldShowAmbientCopilotMicroState {
                ambientCopilotMicroStateContent
            } else if appState.shouldShowAmbientCopilotIdle {
                ambientCopilotContent
            } else {
                recordButton(iconResolution: defaultRecordIconResolution) {
                    appState.startManualMeeting()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private var ambientCopilotMicroStateContent: some View {
        return HStack(spacing: 0) {
            Group {
                if appState.copilotHealthSnapshot.state.usesSpinner {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.50)
                        .tint(Color.white.opacity(0.54))
                } else {
                    Image(systemName: appState.copilotHealthSnapshot.state.systemImageName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.50))
                }
            }
            .frame(width: 24, height: 24)
            .accessibilityLabel(Text(appState.copilotHealthSnapshot.state.displayText))
            .help(appState.copilotHealthSnapshot.state.tooltip)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.leading, 9)
        .padding(.trailing, 86)
        .protectedContentRegion(appState.preferences.stealthModeEnabled)
        .transition(.opacity.combined(with: .move(edge: .trailing)))
    }

    private func compactCopilotIndicatorContent(isProcessing: Bool) -> some View {
        let indicatorHeight = min(20, max(14, contentHeight - 4))
        let spinnerSide = min(22, max(16, contentHeight - 2))

        return ZStack {
            WhiprFlowAudioMark(levels: appState.waveformLevels, isPaused: false)
                .frame(width: min(116, max(72, contentWidth - 24)), height: indicatorHeight)
                .opacity(isProcessing ? 0 : 0.72)
                .scaleEffect(isProcessing ? 0.96 : 1)
                .accessibilityLabel(Text("Listening"))

            ProgressView()
                .controlSize(.small)
                .frame(width: spinnerSide, height: spinnerSide)
                .scaleEffect(isProcessing ? 0.78 : 0.68)
                .tint(Color.white.opacity(0.62))
                .opacity(isProcessing ? 1 : 0)
                .accessibilityLabel(Text("Notchly loading"))
        }
        .frame(width: contentWidth, height: contentHeight, alignment: .center)
        .animation(.easeInOut(duration: reduceMotion ? 0.10 : 0.24), value: isProcessing)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .protectedContentRegion(appState.preferences.stealthModeEnabled)
        .transition(.opacity)
    }

    private var ambientCopilotContent: some View {
        notchAwareBar {
            HStack(spacing: 8) {
                WhiprFlowAudioMark(levels: appState.waveformLevels, isPaused: !appState.isAmbientCopilotListening)
                    .opacity(0.78)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Notchly")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(primaryText)
                        .lineLimit(1)
                    Text(appState.ambientCopilotDisplayStatus)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(secondaryText)
                        .lineLimit(1)
                }
                .opacity(appState.copilotRuntimeState == .idle && !reduceMotion ? 0.86 : 1)
                .animation(reduceMotion ? nil : .easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: appState.copilotRuntimeState)
            }
        } right: {
            HStack(spacing: 6) {
                IconButton(systemName: "pause.fill", help: "Pause Notchly", size: .compact) {
                    appState.pauseCopilot()
                }
                IconButton(systemName: "gearshape", help: "Settings", size: .compact) {
                    appState.openSettingsHandler?()
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard appState.hasQuestionAnswerContext else { return }
            withAnimation(islandSpring) { appState.isPanelExpanded = true }
        }
    }

    private var meetingDetectedContent: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let remaining = appState.detectedMeetingOfferRemainingSeconds(at: timeline.date)
            recordButton(
                iconResolution: MeetingAppIconResolver.resolve(for: appState.currentMeeting),
                remainingSeconds: remaining
            ) {
                if let meeting = appState.currentMeeting {
                    appState.clearDetectedMeetingOfferTimer()
                    Task { await appState.sessionManager?.startDetectedMeeting(meeting) }
                } else {
                    appState.startManualMeeting()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    private var defaultRecordIconResolution: MeetingAppIconResolution {
        MeetingAppIconResolution(image: MeetingAppIconResolver.fallbackIcon(), isFallback: true, platformName: nil)
    }

    private var listeningContent: some View {
        listeningContentView(isPaused: appState.currentMeeting?.status == .paused)
    }

    private func listeningContentView(isPaused: Bool) -> some View {
        notchAwareBar {
            HStack(spacing: 8) {
                WhiprFlowAudioMark(levels: appState.waveformLevels, isPaused: isPaused)
                Text(DateFormatting.duration(appState.elapsed))
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.62))
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
            }
        } right: {
            HStack(spacing: 6) {
                IconButton(systemName: isPaused ? "play.fill" : "pause.fill", help: isPaused ? "Resume" : "Pause", size: .compact) { appState.pauseOrResume() }
                IconButton(systemName: "stop.fill", help: "Stop", role: .destructive, size: .compact) { appState.stopMeeting() }
                IconButton(
                    systemName: "translate",
                    help: appState.preferences.liveTranslationEnabled ? "Disable translation" : "Enable translation",
                    isActive: appState.preferences.liveTranslationEnabled,
                    size: .compact
                ) {
                    appState.toggleLiveTranslation()
                }
                IconButton(systemName: "gearshape", help: "Settings", size: .compact) { appState.openSettingsHandler?() }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(islandSpring) { appState.isPanelExpanded = true }
        }
    }

    private var thinkingContent: some View {
        Group {
            if appState.currentMeeting == nil && !appState.isPanelExpanded {
                ambientThinkingContent
            } else {
                notchAwareBar {
                    HStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(0.62)
                            .tint(.white)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Preparing answer")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(primaryText)
                                .lineLimit(1)
                            Text(appState.activeQuestion?.rawText ?? appState.answerStage.displayName)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(secondaryText)
                                .lineLimit(1)
                                .protectedContentRegion(appState.preferences.stealthModeEnabled)
                            if appState.activeQuestion?.rawText != nil {
                                Text(appState.answerStage.displayName)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(secondaryText.opacity(0.78))
                                    .lineLimit(1)
                            }
                        }
                    }
                } right: {
                    if appState.questionAnswerQueue.count > 1 {
                        compactQuestionQueueControls
                    } else {
                        Color.clear.frame(width: 92, height: 1)
                    }
                }
            }
        }
    }

    private var ambientThinkingContent: some View {
        compactCopilotIndicatorContent(isProcessing: true)
    }

    private var summarizingContent: some View {
        notchAwareBar {
            HStack(spacing: 12) {
                ProgressView()
                    .scaleEffect(0.58)
                    .tint(.white.opacity(0.82))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Summarizing")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(primaryText)
                    Text("Saving notes")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(secondaryText)
                        .lineLimit(1)
                }
            }
        } right: {
            Color.clear.frame(width: 96, height: 1)
        }
    }

    private var summaryReadyContent: some View {
        notchAwareBar {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(secondaryText)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Summary ready")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(primaryText)
                    Text(appState.currentMeeting?.title ?? "Meeting ended")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(secondaryText)
                        .lineLimit(1)
                }
            }
        } right: {
            openSummaryButton {
                appState.openSummaryHandler?()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            appState.openSummaryHandler?()
        }
    }

    private func notchAwareBar<Left: View, Right: View>(
        @ViewBuilder left: () -> Left,
        @ViewBuilder right: () -> Right
    ) -> some View {
        HStack(spacing: 0) {
            left()
                .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear
                .frame(width: notchKeepoutWidth)
                .accessibilityHidden(true)
            right()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var questionAnswerRedirectContent: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                redirectCollapsedQuestionToAnswerPanel()
            }
    }

    private func redirectCollapsedQuestionToAnswerPanel() {
        guard !appState.isPanelExpanded else { return }
        guard appState.hasQuestionAnswerContext else {
            appState.islandMode = appState.currentMeeting == nil ? .idle : .listening
            return
        }

        DispatchQueue.main.async {
            guard !appState.isPanelExpanded else { return }
            withAnimation(islandSpring) {
                appState.showQuestionAnswerPanel(mode: .answer)
            }
        }
    }

    @ViewBuilder
    private var compactQuestionQueueControls: some View {
        if appState.questionAnswerQueue.count > 1 {
            HStack(spacing: 5) {
                IconButton(systemName: "chevron.left", help: "Previous question") {
                    appState.selectPreviousQuestion()
                }
                Text(appState.selectedQuestionPositionText ?? "")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(secondaryText)
                    .frame(minWidth: 28)
                IconButton(systemName: "chevron.right", help: "Next question") {
                    appState.selectNextQuestion()
                }
            }
        }
    }

}

struct MeetingAppIconResolution {
    let image: NSImage
    let isFallback: Bool
    let platformName: String?
}

@MainActor
struct MeetingAppIconResolver {
    static func resolve(for meeting: MeetingSession?) -> MeetingAppIconResolution {
        if let platform = webPlatform(for: meeting),
           shouldPreferWebPlatformIcon(for: meeting) {
            return MeetingAppIconResolution(
                image: MeetingPlatformIconFactory.image(for: platform),
                isFallback: false,
                platformName: platform.displayName
            )
        }

        if let icon = appIcon(bundleIdentifier: meeting?.automationSourceBundleId) {
            return MeetingAppIconResolution(image: icon, isFallback: false, platformName: nil)
        }
        if let icon = appIcon(appName: meeting?.automationSourceAppName ?? meeting?.appName) {
            return MeetingAppIconResolution(image: icon, isFallback: false, platformName: nil)
        }
        if let platform = webPlatform(for: meeting) {
            return MeetingAppIconResolution(
                image: MeetingPlatformIconFactory.image(for: platform),
                isFallback: false,
                platformName: platform.displayName
            )
        }
        return MeetingAppIconResolution(image: fallbackIcon(), isFallback: true, platformName: nil)
    }

    static func webPlatform(for meeting: MeetingSession?) -> MeetingWebPlatform? {
        MeetingWebPlatform.detect(
            url: meeting?.meetingURL,
            title: meeting?.title,
            appName: meeting?.automationSourceAppName ?? meeting?.appName
        )
    }

    static func shouldPreferWebPlatformIcon(for meeting: MeetingSession?) -> Bool {
        guard let meeting else { return false }
        return meeting.meetingURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ||
            BrowserActiveTabResolver.isBrowserBundleIdentifier(meeting.automationSourceBundleId) ||
            meeting.automationSourceBundleId == nil
    }

    static func appIcon(bundleIdentifier: String?) -> NSImage? {
        guard let bundleIdentifier, !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        if let runningIcon = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: { $0.icon != nil })?
            .icon {
            return runningIcon
        }

        if let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return NSWorkspace.shared.icon(forFile: applicationURL.path)
        }

        return nil
    }

    static func appIcon(appName: String?) -> NSImage? {
        guard let appName, !appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let normalizedName = appName.lowercased()
        return NSWorkspace.shared.runningApplications
            .first { application in
                application.localizedName?.lowercased() == normalizedName ||
                    application.localizedName?.lowercased().contains(normalizedName) == true
            }?
            .icon
    }

    static func fallbackIcon() -> NSImage {
        NSImage(named: "NotchIcon") ??
            NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Notchly") ??
            NSImage(size: NSSize(width: 20, height: 20))
    }
}

@MainActor
private enum MeetingPlatformIconFactory {
    static func image(for platform: MeetingWebPlatform) -> NSImage {
        drawIcon { rect in
            switch platform {
            case .googleMeet:
                drawGoogleMeet(in: rect)
            case .zoom:
                drawVideoPlatform(in: rect, background: NSColor(calibratedRed: 0.10, green: 0.43, blue: 0.98, alpha: 1))
            case .microsoftTeams:
                drawLetterPlatform(
                    in: rect,
                    background: NSColor(calibratedRed: 0.38, green: 0.34, blue: 0.83, alpha: 1),
                    letter: "T"
                )
            case .slack:
                drawSlack(in: rect)
            case .discord:
                drawLetterPlatform(
                    in: rect,
                    background: NSColor(calibratedRed: 0.35, green: 0.39, blue: 0.95, alpha: 1),
                    letter: "D"
                )
            case .whatsApp:
                drawLetterPlatform(
                    in: rect,
                    background: NSColor(calibratedRed: 0.08, green: 0.72, blue: 0.34, alpha: 1),
                    letter: "W"
                )
            case .webex:
                drawWebex(in: rect)
            }
        }
    }

    private static func drawIcon(_ drawing: @escaping (NSRect) -> Void) -> NSImage {
        NSImage(size: NSSize(width: 28, height: 28), flipped: false) { rect in
            drawing(rect)
            return true
        }
    }

    private static func drawGoogleMeet(in rect: NSRect) {
        NSColor.white.setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 7, yRadius: 7).fill()

        NSColor(calibratedRed: 0.00, green: 0.62, blue: 0.38, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 8, y: 7, width: 11.5, height: 14), xRadius: 3, yRadius: 3).fill()
        let lens = NSBezierPath()
        lens.move(to: NSPoint(x: 18, y: 11))
        lens.line(to: NSPoint(x: 24, y: 7.8))
        lens.line(to: NSPoint(x: 24, y: 20.2))
        lens.line(to: NSPoint(x: 18, y: 17))
        lens.close()
        lens.fill()

        NSColor(calibratedRed: 0.98, green: 0.74, blue: 0.18, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 4.5, y: 14, width: 5.5, height: 7), xRadius: 2, yRadius: 2).fill()
        NSColor(calibratedRed: 0.92, green: 0.25, blue: 0.20, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 4.5, y: 7, width: 5.5, height: 7), xRadius: 2, yRadius: 2).fill()
        NSColor(calibratedRed: 0.24, green: 0.51, blue: 0.96, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 8, y: 17, width: 11.5, height: 4), xRadius: 2, yRadius: 2).fill()
    }

    private static func drawVideoPlatform(in rect: NSRect, background: NSColor) {
        background.setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: 2.5, dy: 2.5), xRadius: 7, yRadius: 7).fill()

        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 7, y: 9, width: 11, height: 10), xRadius: 3, yRadius: 3).fill()
        let lens = NSBezierPath()
        lens.move(to: NSPoint(x: 17, y: 12))
        lens.line(to: NSPoint(x: 22, y: 9.5))
        lens.line(to: NSPoint(x: 22, y: 18.5))
        lens.line(to: NSPoint(x: 17, y: 16))
        lens.close()
        lens.fill()
    }

    private static func drawLetterPlatform(in rect: NSRect, background: NSColor, letter: String) {
        background.setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: 2.5, dy: 2.5), xRadius: 7, yRadius: 7).fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        NSString(string: letter).draw(in: NSRect(x: 0, y: 5.5, width: rect.width, height: 18), withAttributes: attributes)
    }

    private static func drawSlack(in rect: NSRect) {
        NSColor(calibratedWhite: 1, alpha: 0.96).setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: 2.5, dy: 2.5), xRadius: 7, yRadius: 7).fill()

        func capsule(_ color: NSColor, _ rect: NSRect) {
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2.5, yRadius: 2.5).fill()
        }

        capsule(NSColor(calibratedRed: 0.88, green: 0.16, blue: 0.32, alpha: 1), NSRect(x: 7, y: 14, width: 11, height: 4))
        capsule(NSColor(calibratedRed: 0.96, green: 0.71, blue: 0.11, alpha: 1), NSRect(x: 14, y: 10, width: 4, height: 11))
        capsule(NSColor(calibratedRed: 0.02, green: 0.60, blue: 0.62, alpha: 1), NSRect(x: 10, y: 7, width: 4, height: 11))
        capsule(NSColor(calibratedRed: 0.24, green: 0.67, blue: 0.31, alpha: 1), NSRect(x: 10, y: 10, width: 11, height: 4))
    }

    private static func drawWebex(in rect: NSRect) {
        NSColor(calibratedWhite: 1, alpha: 0.96).setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: 2.5, dy: 2.5), xRadius: 7, yRadius: 7).fill()

        let strokeWidth: CGFloat = 2.7
        NSColor(calibratedRed: 0.00, green: 0.64, blue: 0.78, alpha: 1).setStroke()
        let left = NSBezierPath(ovalIn: NSRect(x: 6.8, y: 8.5, width: 10.5, height: 11))
        left.lineWidth = strokeWidth
        left.stroke()

        NSColor(calibratedRed: 0.42, green: 0.30, blue: 0.88, alpha: 1).setStroke()
        let right = NSBezierPath(ovalIn: NSRect(x: 10.7, y: 8.5, width: 10.5, height: 11))
        right.lineWidth = strokeWidth
        right.stroke()
    }
}

private struct RecordPillButton: View {
    let iconResolution: MeetingAppIconResolution
    let remainingSeconds: Int?
    let showsIcon: Bool
    let width: CGFloat
    let feedbackTrigger: Int
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var isResting = false
    @State private var isPressing = false
    @State private var clickPulse = false
    @State private var feedbackTask: Task<Void, Never>?

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    if showsIcon {
                        RecordPillLeadingIcon(
                            resolution: iconResolution,
                            fallbackOpacity: iconOpacity
                        )
                        .scaleEffect(isPressing ? 0.965 : (isHovering ? 1.018 : 1))
                        .animation(.easeOut(duration: 0.22), value: isHovering)
                        .animation(.interactiveSpring(response: 0.24, dampingFraction: 0.86), value: isPressing)
                    } else {
                        Color.clear
                            .frame(
                                width: NotchIslandChromeMetrics.compactRecordLogoSize.width,
                                height: 1
                            )
                            .accessibilityHidden(true)
                    }
                }
                .layoutPriority(1)

                Spacer(minLength: 8)

                HStack(spacing: 7) {
                    if let remainingSeconds {
                        Text("\(remainingSeconds)s")
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(isPressing ? 0.66 : 0.50))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }

                    Text("Record")
                        .font(.system(size: 14.6, weight: .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.86)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .layoutPriority(2)
            }
            .padding(.leading, 13)
            .padding(.trailing, 16)
        }
        .buttonStyle(RecordPillButtonStyle(
            isHovering: isHovering,
            isPressing: isPressing,
            isResting: isResting,
            clickPulse: clickPulse,
            width: width,
            reduceMotion: reduceMotion
        ))
        .frame(width: width, height: NotchIslandChromeMetrics.compactRecordButtonHeight)
        .contentShape(Rectangle())
        .overlay {
            MouseDownActionOverlay(
                action: action,
                onHover: { hovering in
                    isHovering = hovering
                },
                onPress: { pressing in
                    withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.86)) {
                        isPressing = pressing
                    }
                }
            )
            .frame(
                width: width,
                height: NotchIslandChromeMetrics.compactRecordButtonHeight
            )
            .contentShape(Rectangle())
        }
        .help("Start recording")
        .accessibilityLabel(Text("Start recording"))
        .onAppear(perform: startRestingMotion)
        .onChange(of: reduceMotion) {
            startRestingMotion()
        }
        .onChange(of: feedbackTrigger) {
            playClickFeedback()
        }
        .onDisappear {
            feedbackTask?.cancel()
        }
    }

    private var iconOpacity: Double {
        if isPressing { return 0.90 }
        if isHovering { return 0.82 }
        return 0.74
    }

    private func startRestingMotion() {
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) {
            isResting = false
        }

        guard !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 3.8).repeatForever(autoreverses: true)) {
            isResting = true
        }
    }

    private func playClickFeedback() {
        feedbackTask?.cancel()
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) {
            clickPulse = false
        }

        withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.78)) {
            isPressing = true
        }
        withAnimation(.easeOut(duration: reduceMotion ? 0.18 : 0.46)) {
            clickPulse = true
        }

        feedbackTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(148))
            guard !Task.isCancelled else { return }
            withAnimation(.interactiveSpring(response: 0.30, dampingFraction: 0.86)) {
                isPressing = false
            }

            try? await Task.sleep(for: .milliseconds(reduceMotion ? 110 : 360))
            guard !Task.isCancelled else { return }
            var settle = Transaction()
            settle.disablesAnimations = true
            withTransaction(settle) {
                clickPulse = false
            }
        }
    }
}

private struct RecordPillLeadingIcon: View {
    let resolution: MeetingAppIconResolution
    let fallbackOpacity: Double

    var body: some View {
        Group {
            if resolution.isFallback {
                NotchlyMarkVectorIcon(opacity: fallbackOpacity)
                    .frame(
                        width: NotchIslandChromeMetrics.compactRecordLogoSize.width,
                        height: NotchIslandChromeMetrics.compactRecordLogoSize.height
                    )
                    .layoutPriority(2)
            } else {
                MeetingAppIconImage(resolution: resolution, fallbackOpacity: fallbackOpacity, cornerRadius: 6)
                    .frame(
                        width: NotchIslandChromeMetrics.compactRecordPlatformIconSize.width,
                        height: NotchIslandChromeMetrics.compactRecordPlatformIconSize.height
                    )
                    .frame(
                        width: NotchIslandChromeMetrics.compactRecordLogoSize.width,
                        height: NotchIslandChromeMetrics.compactRecordLogoSize.height,
                        alignment: .center
                    )
            }
        }
        .frame(
            width: NotchIslandChromeMetrics.compactRecordLogoSize.width,
            height: NotchIslandChromeMetrics.compactRecordLogoSize.height,
            alignment: .center
        )
        .accessibilityHidden(true)
    }
}

private struct NotchlyMarkVectorIcon: View {
    let opacity: Double

    private let sourceRect = CGRect(x: 8, y: 9, width: 112, height: 46)

    var body: some View {
        Canvas(opaque: false, colorMode: .linear) { context, size in
            guard size.width > 0, size.height > 0 else { return }

            let scale = min(size.width / sourceRect.width, size.height / sourceRect.height)
            let fittedSize = CGSize(width: sourceRect.width * scale, height: sourceRect.height * scale)
            let origin = CGPoint(
                x: (size.width - fittedSize.width) / 2 - sourceRect.minX * scale,
                y: (size.height - fittedSize.height) / 2 - sourceRect.minY * scale
            )

            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
            }

            func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
                CGRect(
                    x: origin.x + x * scale,
                    y: origin.y + y * scale,
                    width: width * scale,
                    height: height * scale
                )
            }

            var outline = Path()
            outline.move(to: point(30.5, 11.13))
            outline.addCurve(to: point(10.25, 32), control1: point(19.31, 11.13), control2: point(10.25, 20.26))
            outline.addCurve(to: point(30.5, 52), control1: point(10.25, 43.41), control2: point(19.39, 52))
            outline.addLine(to: point(97.5, 52))
            outline.addCurve(to: point(117.75, 32), control1: point(108.61, 52), control2: point(117.75, 43.41))
            outline.addCurve(to: point(97.5, 11.13), control1: point(117.75, 20.26), control2: point(108.69, 11.13))
            outline.addLine(to: point(80.75, 11.13))
            outline.addCurve(to: point(73, 14.45), control1: point(77.66, 11.13), control2: point(75.13, 12.11))
            outline.addCurve(to: point(66, 16.25), control1: point(71.43, 16.19), control2: point(69.04, 16.25))
            outline.addLine(to: point(62, 16.25))
            outline.addCurve(to: point(55, 14.45), control1: point(58.96, 16.25), control2: point(56.58, 16.19))
            outline.addCurve(to: point(47.25, 11.13), control1: point(52.88, 12.11), control2: point(50.34, 11.13))
            outline.addLine(to: point(30.5, 11.13))
            outline.closeSubpath()

            let color = Color(red: 0.78, green: 0.80, blue: 0.82)
                .opacity(min(0.90, opacity + 0.04))
            context.stroke(
                outline,
                with: .color(color),
                style: StrokeStyle(lineWidth: max(1.1, 2 * scale), lineCap: .round, lineJoin: .round)
            )

            func fillRoundedRect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, radius: CGFloat) {
                context.fill(
                    Path(roundedRect: rect(x, y, width, height), cornerSize: CGSize(width: radius * scale, height: radius * scale)),
                    with: .color(color)
                )
            }

            func fillCircle(cx: CGFloat, cy: CGFloat, radius: CGFloat) {
                context.fill(
                    Path(ellipseIn: rect(cx - radius, cy - radius, radius * 2, radius * 2)),
                    with: .color(color)
                )
            }

            fillCircle(cx: 21, cy: 31.75, radius: 1.88)
            fillRoundedRect(x: 26.5, y: 28.75, width: 3.75, height: 6.25, radius: 1.88)
            fillRoundedRect(x: 33.63, y: 25.5, width: 3.75, height: 12.75, radius: 1.88)
            fillRoundedRect(x: 40.88, y: 23.63, width: 3.75, height: 16.63, radius: 1.88)
            fillRoundedRect(x: 48, y: 27.63, width: 3.75, height: 8.5, radius: 1.88)
            fillRoundedRect(x: 55, y: 24.5, width: 3.75, height: 14.63, radius: 1.88)
            fillRoundedRect(x: 62.13, y: 20, width: 3.75, height: 23.75, radius: 1.88)
            fillRoundedRect(x: 69.25, y: 24.5, width: 3.75, height: 14.63, radius: 1.88)
            fillRoundedRect(x: 76.38, y: 27.63, width: 3.75, height: 8.5, radius: 1.88)
            fillRoundedRect(x: 83.38, y: 23.63, width: 3.75, height: 16.63, radius: 1.88)
            fillRoundedRect(x: 90.63, y: 25.5, width: 3.75, height: 12.75, radius: 1.88)
            fillRoundedRect(x: 97.75, y: 28.75, width: 3.75, height: 6.25, radius: 1.88)
            fillCircle(cx: 107, cy: 31.75, radius: 1.88)
        }
        .aspectRatio(sourceRect.width / sourceRect.height, contentMode: .fit)
        .drawingGroup(opaque: false, colorMode: .linear)
        .accessibilityHidden(true)
    }
}

private struct RecordPillButtonStyle: ButtonStyle {
    var isHovering: Bool
    var isPressing: Bool
    var isResting: Bool
    var clickPulse: Bool
    var width: CGFloat
    var reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        let visualState = RecordPillButtonVisualState(
            isHovering: isHovering,
            isPressing: isPressing,
            isConfigurationPressed: configuration.isPressed,
            isResting: isResting,
            clickPulse: clickPulse,
            reduceMotion: reduceMotion
        )

        return configuration.label
            .foregroundStyle(Color.white.opacity(visualState.foregroundOpacity))
            .frame(
                width: width,
                height: NotchIslandChromeMetrics.compactRecordButtonHeight
            )
            .background {
                RecordPillButtonChrome(state: visualState)
            }
            .shadow(
                color: visualState.shadowColor,
                radius: visualState.shadowRadius,
                x: 0,
                y: visualState.shadowYOffset
            )
            .brightness(visualState.brightness)
            .scaleEffect(visualState.scale)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
            .animation(.interactiveSpring(response: 0.24, dampingFraction: 0.86), value: isPressing)
            .animation(.easeOut(duration: 0.20), value: isHovering)
            .animation(.easeInOut(duration: 0.42), value: clickPulse)
    }
}

private struct RecordPillButtonVisualState {
    var isHovering: Bool
    var isPressing: Bool
    var isConfigurationPressed: Bool
    var isResting: Bool
    var clickPulse: Bool
    var reduceMotion: Bool

    var pressed: Bool {
        isPressing || isConfigurationPressed
    }

    var restingEnergy: Double {
        reduceMotion ? 0 : (isResting ? 1.0 : 0.0)
    }

    var hoverEnergy: Double {
        isHovering ? 1.0 : 0.0
    }

    var pressEnergy: Double {
        pressed ? 1.0 : 0.0
    }

    var foregroundOpacity: Double {
        pressed ? 0.98 : 0.92
    }

    var fallbackBackgroundOpacity: Double {
        if pressed { return 0.15 }
        if isHovering { return 0.118 }
        return 0.098
    }

    var baseStrokeOpacity: Double {
        if pressed { return 0.15 }
        if isHovering { return 0.108 }
        return 0.075
    }

    var shadowColor: Color {
        Color(red: 0.58, green: 0.88, blue: 0.96)
            .opacity(0.014 + restingEnergy * 0.018 + hoverEnergy * 0.024 + pressEnergy * 0.052)
    }

    var shadowRadius: CGFloat {
        3.5 + CGFloat(restingEnergy) * 1.4 + CGFloat(hoverEnergy) * 1.6 + CGFloat(pressEnergy) * 4
    }

    var shadowYOffset: CGFloat {
        1 + CGFloat(pressEnergy) * 0.6
    }

    var brightness: Double {
        pressEnergy * 0.012
    }

    var scale: CGFloat {
        if pressed { return 0.976 }
        if isHovering { return 1.006 }
        return 1 + CGFloat(restingEnergy) * 0.002
    }
}

private struct RecordPillButtonChrome: View {
    let state: RecordPillButtonVisualState
    @Environment(\.islandDesignMode) private var islandDesignMode

    private var isLiquidGlass: Bool {
        islandDesignMode == .liquidGlass
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: NotchIslandChromeMetrics.compactRecordButtonCornerRadius,
            style: .continuous
        )
    }

    var body: some View {
        ZStack {
            glassBackground
            highlightFill
            baseStroke
            mineralStroke
            RecordPillAnimatedBorder(state: state)
            clickPulseStroke
        }
    }

    @ViewBuilder
    private var glassBackground: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 0) {
                Color.clear
                    .glassEffect(
                        .regular
                            .tint(Color.white.opacity(glassTintOpacity))
                            .interactive(true),
                        in: shape
                    )
            }
            .background {
                shape
                    .fill(Color.white.opacity(glassFallbackOpacity))
            }
        } else {
            shape
                .fill(Color.white.opacity(isLiquidGlass ? glassFallbackOpacity : state.fallbackBackgroundOpacity))
        }
    }

    private var highlightFill: some View {
        shape
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity((0.016 + state.restingEnergy * 0.012 + state.pressEnergy * 0.014) * highlightMultiplier),
                        Color(red: 0.60, green: 0.86, blue: 0.92).opacity((0.012 + state.hoverEnergy * 0.018 + state.pressEnergy * 0.032) * highlightMultiplier),
                        Color(red: 0.96, green: 0.76, blue: 0.42).opacity((0.008 + state.restingEnergy * 0.010 + state.pressEnergy * 0.018) * highlightMultiplier)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }

    private var baseStroke: some View {
        shape
            .stroke(Color.white.opacity(isLiquidGlass ? state.baseStrokeOpacity + 0.035 : state.baseStrokeOpacity), lineWidth: 0.7)
    }

    private var mineralStroke: some View {
        shape
            .stroke(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.14 + state.pressEnergy * 0.12),
                        Color(red: 0.56, green: 0.88, blue: 0.96).opacity(0.09 + state.restingEnergy * 0.07 + state.hoverEnergy * 0.07 + state.pressEnergy * 0.12),
                        Color(red: 1.0, green: 0.80, blue: 0.46).opacity(0.05 + state.restingEnergy * 0.04 + state.pressEnergy * 0.09)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                lineWidth: 0.9
            )
            .opacity(0.40 + state.restingEnergy * 0.15 + state.hoverEnergy * 0.16 + state.pressEnergy * 0.18)
    }

    private var glassTintOpacity: Double {
        if isLiquidGlass {
            return 0.070 + state.hoverEnergy * 0.024 + state.pressEnergy * 0.034
        }
        return 0.048 + state.hoverEnergy * 0.014 + state.pressEnergy * 0.022
    }

    private var glassFallbackOpacity: Double {
        if isLiquidGlass {
            return 0.044 + state.restingEnergy * 0.006 + state.hoverEnergy * 0.015 + state.pressEnergy * 0.026
        }
        return 0.030 + state.restingEnergy * 0.007 + state.hoverEnergy * 0.014 + state.pressEnergy * 0.026
    }

    private var highlightMultiplier: Double {
        isLiquidGlass ? 0.64 : 1
    }

    private var clickPulseStroke: some View {
        shape
            .stroke(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.46),
                        Color(red: 0.60, green: 0.90, blue: 0.98).opacity(0.32),
                        Color.white.opacity(0.16)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1.05
            )
            .scaleEffect(state.clickPulse ? 1.08 : 0.985)
            .opacity(state.clickPulse ? 0 : (state.pressed ? 0.28 : 0))
    }
}

private struct RecordPillAnimatedBorder: View {
    let state: RecordPillButtonVisualState

    private let cycleDuration: TimeInterval = 4.1

    private var shape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: NotchIslandChromeMetrics.compactRecordButtonCornerRadius,
            style: .continuous
        )
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: state.reduceMotion)) { context in
            let phase = state.reduceMotion ? 0 : normalizedPhase(for: context.date)

            ZStack {
                rotatingStroke(phase: phase)
                glintSegment(phase: phase, opacity: 0.34 + state.hoverEnergy * 0.12 + state.pressEnergy * 0.16)
                glintSegment(phase: wrappedPhase(phase + 0.52), opacity: 0.14 + state.hoverEnergy * 0.07 + state.pressEnergy * 0.10)
            }
        }
    }

    private func normalizedPhase(for date: Date) -> Double {
        let elapsed = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycleDuration)
        return elapsed / cycleDuration
    }

    private func wrappedPhase(_ phase: Double) -> Double {
        phase.truncatingRemainder(dividingBy: 1)
    }

    private func rotatingStroke(phase: Double) -> some View {
        shape
            .strokeBorder(
                AngularGradient(
                    gradient: Gradient(stops: [
                        .init(color: Color.white.opacity(0.10), location: 0.00),
                        .init(color: Color.white.opacity(0.34 + state.hoverEnergy * 0.10 + state.pressEnergy * 0.15), location: 0.18),
                        .init(color: Color(red: 0.56, green: 0.88, blue: 0.96).opacity(0.30 + state.hoverEnergy * 0.14 + state.pressEnergy * 0.16), location: 0.34),
                        .init(color: Color.white.opacity(0.12), location: 0.52),
                        .init(color: Color(red: 1.0, green: 0.78, blue: 0.48).opacity(0.18 + state.restingEnergy * 0.07 + state.pressEnergy * 0.13), location: 0.68),
                        .init(color: Color.white.opacity(0.08), location: 1.00)
                    ]),
                    center: .center,
                    angle: .degrees(phase * 360)
                ),
                lineWidth: 1.02 + CGFloat(state.pressEnergy) * 0.12
            )
            .opacity(0.38 + state.restingEnergy * 0.08 + state.hoverEnergy * 0.12 + state.pressEnergy * 0.16)
            .blendMode(.screen)
    }

    @ViewBuilder
    private func glintSegment(phase: Double, opacity: Double) -> some View {
        let start = CGFloat(phase)
        let length = CGFloat(0.14 + state.hoverEnergy * 0.026 + state.pressEnergy * 0.040)
        let end = start + length

        if end <= 1 {
            glintStroke(from: start, to: end)
                .opacity(opacity)
        } else {
            ZStack {
                glintStroke(from: start, to: 1)
                glintStroke(from: 0, to: end - 1)
            }
            .opacity(opacity)
        }
    }

    private func glintStroke(from start: CGFloat, to end: CGFloat) -> some View {
        shape
            .trim(from: start, to: end)
            .stroke(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0),
                        Color.white.opacity(0.62 + state.pressEnergy * 0.12),
                        Color(red: 0.62, green: 0.92, blue: 1.0).opacity(0.42 + state.hoverEnergy * 0.10),
                        Color.white.opacity(0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                style: StrokeStyle(
                    lineWidth: 1.36 + CGFloat(state.pressEnergy) * 0.20,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            .blendMode(.screen)
    }
}

private struct MeetingAppIconImage: View {
    let resolution: MeetingAppIconResolution
    var fallbackOpacity: Double = 0.62
    var cornerRadius: CGFloat = 4

    var body: some View {
        if resolution.isFallback {
            Image(nsImage: resolution.image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color.white.opacity(fallbackOpacity))
        } else {
            Image(nsImage: resolution.image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

private struct MeetingAppIconView: View {
    let meeting: MeetingSession?

    var body: some View {
        let resolution = MeetingAppIconResolver.resolve(for: meeting)
        Group {
            if resolution.platformName != nil {
                MeetingAppIconImage(resolution: resolution)
                    .frame(width: 29, height: 29)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.055))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.white.opacity(0.06), lineWidth: 0.6)
                        )

                    MeetingAppIconImage(resolution: resolution)
                        .frame(width: 18, height: 18)
                }
                .frame(width: 30, height: 30)
            }
        }
        .frame(width: 30, height: 30)
        .accessibilityLabel(Text(meeting?.automationSourceAppName ?? meeting?.appName ?? "Detected meeting app"))
    }
}

private struct NotchCopilotCompactIconView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.055))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 0.6)
                )

            Image(nsImage: MeetingAppIconResolver.fallbackIcon())
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color.white.opacity(0.66))
                .frame(width: 22, height: 16)
        }
        .frame(width: 30, height: 30)
        .accessibilityLabel(Text("Notchly"))
    }
}

struct WhiprFlowAudioMark: View {
    let levels: [CGFloat]
    let isPaused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated static let barCount = 13
    nonisolated static let markWidth: CGFloat = 56
    nonisolated static let markHeight: CGFloat = 18

    nonisolated private static let zeroHeight: CGFloat = 4.2
    nonisolated private static let zeroWidth: CGFloat = 1.72
    nonisolated private static let noiseFloor: CGFloat = 0.11
    nonisolated private static let responsiveness: [CGFloat] = [0.34, 0.58, 0.40, 0.78, 0.52, 0.92, 0.70, 0.88, 0.50, 0.74, 0.38, 0.54, 0.32]
    nonisolated private static let organicSampleAnchors: [Double] = [0.08, 0.57, 0.22, 0.82, 0.38, 0.66, 0.50, 0.91, 0.31, 0.74, 0.15, 0.46, 0.97]

    nonisolated static func intensity(for levels: [CGFloat], isPaused: Bool) -> CGFloat {
        signal(for: levels, isPaused: isPaused).average
    }

    nonisolated static func signal(for levels: [CGFloat], isPaused: Bool) -> WhiprFlowAudioSignal {
        guard !isPaused else { return .paused }

        let rawSamples = (levels.isEmpty ? Array(repeating: CGFloat(0), count: 18) : Array(levels.suffix(18)))
            .map { min(max($0, 0), 1) }
        let samples = rawSamples.map { gatedLevel($0) }
        guard !samples.isEmpty else { return .empty }

        let average = samples.reduce(CGFloat.zero, +) / CGFloat(samples.count)
        let peak = samples.max() ?? average
        let last = samples.last ?? average
        let previous = samples.dropLast().last ?? average
        let flux = min(max(abs(last - previous) * 3.15 + max(last - average, 0) * 1.35, 0), 1)
        let blendedAverage = min(max(average * 0.62 + peak * 0.30 + flux * 0.16, 0), 1)

        return WhiprFlowAudioSignal(
            average: blendedAverage,
            peak: min(max(peak, 0), 1),
            flux: flux,
            bands: reactiveBands(from: samples, count: barCount)
        )
    }

    nonisolated static func presentation(
        for levels: [CGFloat],
        isPaused: Bool,
        seconds: TimeInterval,
        reduceMotion: Bool = false
    ) -> WhiprFlowAudioMarkPresentation {
        let signal = signal(for: levels, isPaused: isPaused)
        let activeAmount: CGFloat = isPaused ? 0 : 1
        let energy = activeAmount * min(max(signal.average * 0.76 + signal.peak * 0.22 + signal.flux * 0.16, 0), 1)
        let clock = reduceMotion ? CGFloat.zero : CGFloat(seconds.truncatingRemainder(dividingBy: 4096))
        let organicMotion = reduceMotion || isPaused || energy <= 0.012
            ? CGFloat.zero
            : min(1, 0.20 + energy * 0.80)

        let bars = (0..<barCount).map { index in
            let band = signal.bands[index]
            let leftBand = index > 0 ? signal.bands[index - 1] : band
            let rightBand = index + 1 < barCount ? signal.bands[index + 1] : band
            let neighborAverage = (leftBand + rightBand) * 0.5
            let localContrast = max(0, band - neighborAverage)
            let response = responsiveness[index]
            let animatedBand = organicBand(
                band,
                index: index,
                signal: signal,
                localContrast: localContrast,
                seconds: clock,
                motion: organicMotion
            )
            let displayBand = displayBand(
                animatedBand,
                index: index,
                signal: signal,
                seconds: clock,
                motion: organicMotion
            )
            let shapedBand = pow(displayBand, 0.48)

            let liveLift = activeAmount * shapedBand * (2.15 + response * 10.65)
            let transientLift = activeAmount * signal.flux * (0.35 + response * 1.80) * (0.45 + shapedBand * 0.55 + localContrast)
            let globalLift = activeAmount * signal.average * (0.35 + response * 0.65)
            let height = min(markHeight - 0.8, max(zeroHeight, zeroHeight + liveLift + transientLift + globalLift))

            let width = min(2.95, zeroWidth + activeAmount * (pow(displayBand, 0.62) * 0.46 + localContrast * 0.18 + signal.flux * response * 0.05))
            let opacity = isPaused
                ? 0.34
                : min(1, 0.34 + energy * 0.26 + shapedBand * 0.29 + localContrast * 0.08 + signal.flux * response * 0.10)
            let verticalOffset = organicVerticalOffset(
                for: index,
                signal: signal,
                seconds: clock,
                motion: organicMotion
            )

            return WhiprFlowAudioBarPresentation(
                height: height,
                width: width,
                opacity: opacity,
                verticalOffset: verticalOffset,
                tint: tint(for: index, band: displayBand, signal: signal, isPaused: isPaused, seconds: seconds, reduceMotion: reduceMotion)
            )
        }

        let peakBand = signal.bands.max() ?? signal.average

        return WhiprFlowAudioMarkPresentation(
            signal: signal,
            bars: bars,
            glowRadius: energy <= 0 ? 0 : 0.35 + signal.average * 1.25 + peakBand * 0.64 + signal.flux * 0.38,
            glowOpacity: energy <= 0 ? 0 : 0.010 + signal.average * 0.032 + peakBand * 0.025 + signal.flux * 0.018,
            verticalOffset: 0
        )
    }

    var body: some View {
        if AppleMetalFlowMarkRenderer().isAvailable {
            AppleMetalFlowMarkView(levels: levels, isPaused: isPaused, reduceMotion: reduceMotion)
                .frame(width: Self.markWidth, height: Self.markHeight)
        } else {
            fallbackFlowMark
        }
    }

    private var fallbackFlowMark: some View {
        TimelineView(.periodic(from: .now, by: reduceMotion ? 1.0 / 24.0 : 1.0 / 60.0)) { timeline in
            let state = Self.presentation(
                for: levels,
                isPaused: isPaused,
                seconds: timeline.date.timeIntervalSinceReferenceDate,
                reduceMotion: reduceMotion
            )

            HStack(alignment: .center, spacing: 1.55) {
                ForEach(state.bars.indices, id: \.self) { index in
                    let bar = state.bars[index]
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [bar.tint.highlightColor, bar.tint.color],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: bar.width, height: bar.height)
                        .opacity(bar.opacity)
                        .shadow(
                            color: bar.tint.color.opacity(state.glowOpacity),
                            radius: state.glowRadius,
                            x: 0,
                            y: 0
                        )
                        .offset(y: bar.verticalOffset)
                }
            }
            .frame(width: Self.markWidth, height: Self.markHeight, alignment: .center)
            .offset(y: state.verticalOffset)
            .animation(.interpolatingSpring(stiffness: 150, damping: 24), value: levels)
        }
        .accessibilityLabel(Text(isPaused ? "Audio paused" : "Audio input active"))
    }

    nonisolated private static func gatedLevel(_ level: CGFloat) -> CGFloat {
        guard level > noiseFloor else { return 0 }
        return min(max((level - noiseFloor) / (1 - noiseFloor), 0), 1)
    }

    nonisolated private static func reactiveBands(from samples: [CGFloat], count: Int) -> [CGFloat] {
        guard samples.count > 1 else {
            let level = samples.first ?? 0.10
            return Array(repeating: pow(level, 0.58), count: count)
        }

        return (0..<count).map { bandIndex in
            let visualPosition = Double(bandIndex) / Double(max(count - 1, 1))
            let target = organicSampleAnchors[bandIndex % organicSampleAnchors.count]
            var weightedTotal = CGFloat.zero
            var totalWeight = CGFloat.zero

            for (sampleIndex, sample) in samples.enumerated() {
                let position = Double(sampleIndex) / Double(samples.count - 1)
                let distance = abs(position - target)
                let weight = CGFloat(max(0.045, 1.0 - distance * (3.10 + Double(responsiveness[bandIndex]) * 1.35)))
                weightedTotal += sample * weight
                totalWeight += weight
            }

            let directAverage = weightedTotal / max(totalWeight, 0.001)
            let latest = samples.last ?? directAverage
            let previous = samples.dropLast().last ?? latest
            let peak = samples.max() ?? directAverage
            let latestWeight = 0.055 + responsiveness[bandIndex] * 0.065
            let previousWeight: CGFloat = 0.040
            let peakWeight = 0.030 + (1 - responsiveness[bandIndex]) * 0.030
            let baseWeight = max(0, 1 - latestWeight - previousWeight - peakWeight)
            let averaged = directAverage * baseWeight + latest * latestWeight + previous * previousWeight + peak * peakWeight
            let centerBias = 0.84 + 0.16 * CGFloat(cos((visualPosition - 0.5) * .pi))
            let responseBias = 0.95 + responsiveness[bandIndex] * 0.05
            return bounded(pow(averaged, 0.58) * centerBias * responseBias)
        }
    }

    nonisolated private static func organicBand(
        _ band: CGFloat,
        index: Int,
        signal: WhiprFlowAudioSignal,
        localContrast: CGFloat,
        seconds: CGFloat,
        motion: CGFloat
    ) -> CGFloat {
        guard motion > 0 else { return band }

        let response = responsiveness[index]
        let phase = Double(index) * 1.618_033_988_75
        let t = Double(seconds)
        let speedLift = 1.0 + Double(signal.peak) * 0.72 + Double(signal.average) * 0.42
        let driftA = CGFloat(sin(t * (0.54 + Double(response) * 0.42) * speedLift + phase))
        let driftB = CGFloat(sin(t * (0.92 + Double(index % 5) * 0.09) * speedLift - phase * 0.73))
        let driftC = CGFloat(sin(t * (0.30 + Double(signal.flux) * 0.28) * speedLift + phase * 2.37))
        let centerDistance = abs(CGFloat(index) - CGFloat(barCount - 1) * 0.5) / CGFloat(max(barCount - 1, 1))
        let centerWeight = 1 - centerDistance * 0.28
        let audioWeight = 0.32 + signal.average * 0.86 + signal.peak * 0.22
        let organicOffset = (driftA * 0.070 + driftB * 0.045 + driftC * 0.030) * motion * audioWeight
        let contrastOffset = localContrast * driftB * 0.055 * motion

        return bounded(band * (0.96 + centerWeight * 0.045) + organicOffset + contrastOffset)
    }

    nonisolated private static func displayBand(
        _ animatedBand: CGFloat,
        index: Int,
        signal: WhiprFlowAudioSignal,
        seconds: CGFloat,
        motion: CGFloat
    ) -> CGFloat {
        guard motion > 0 else { return animatedBand }

        let response = responsiveness[index]
        let t = Double(seconds)
        let phase = Double(index) * 1.93
        let loudness = smoothStep(edge0: 0.56, edge1: 0.96, value: max(signal.average, signal.peak))
        let speedLift = 1.0 + Double(signal.peak) * 0.92 + Double(signal.average) * 0.58
        let compressed = animatedBand <= 0.72 ? animatedBand : 0.72 + (animatedBand - 0.72) * 0.56
        let rippleA = CGFloat(sin(t * (1.36 + Double(response) * 0.72) * speedLift + phase)) * 0.082
        let rippleB = CGFloat(sin(t * (2.10 + Double(index % 4) * 0.16) * speedLift - phase * 0.61)) * 0.034
        let dynamicCeiling = 0.91 + CGFloat(sin(t * (1.02 + Double(response) * 0.36) * speedLift + phase * 0.47)) * 0.046
        let movingBand = compressed + (rippleA + rippleB) * loudness * motion

        return bounded(min(movingBand, dynamicCeiling), lower: 0.02, upper: 0.98)
    }

    nonisolated private static func organicVerticalOffset(
        for index: Int,
        signal: WhiprFlowAudioSignal,
        seconds: CGFloat,
        motion: CGFloat
    ) -> CGFloat {
        guard motion > 0 else { return 0 }

        let response = responsiveness[index]
        let phase = Double(index) * 2.11
        let speedLift = 1.0 + Double(signal.peak) * 0.70 + Double(signal.average) * 0.48
        let offset = CGFloat(sin(Double(seconds) * (0.62 + Double(response) * 0.32) * speedLift + phase))
        let centerDistance = abs(CGFloat(index) - CGFloat(barCount - 1) * 0.5) / CGFloat(max(barCount - 1, 1))
        let centerWeight = 1 - centerDistance * 0.35
        return offset * 0.52 * centerWeight * motion * (0.30 + signal.average * 0.70)
    }

    nonisolated private static func bounded(_ value: CGFloat, lower: CGFloat = 0, upper: CGFloat = 1) -> CGFloat {
        min(max(value, lower), upper)
    }

    nonisolated private static func smoothStep(edge0: CGFloat, edge1: CGFloat, value: CGFloat) -> CGFloat {
        let t = bounded((value - edge0) / max(edge1 - edge0, 0.001))
        return t * t * (3 - 2 * t)
    }

    nonisolated private static func tint(
        for index: Int,
        band: CGFloat,
        signal: WhiprFlowAudioSignal,
        isPaused: Bool,
        seconds: TimeInterval,
        reduceMotion: Bool
    ) -> WhiprFlowAudioTint {
        _ = seconds
        _ = reduceMotion
        let restGray = WhiprFlowAudioTint(red: 0.48, green: 0.48, blue: 0.47)
        guard !isPaused else {
            return restGray
        }

        let white = WhiprFlowAudioTint(red: 0.98, green: 0.98, blue: 0.95)
        let shapedBand = pow(band, 0.48)
        let amount = min(1, shapedBand * 0.52 + signal.average * 0.32 + signal.peak * 0.12 + signal.flux * responsiveness[index] * 0.12)
        return restGray.mixed(with: white, amount: amount)
    }

}

struct WhiprFlowAudioMarkPresentation: Equatable {
    let signal: WhiprFlowAudioSignal
    let bars: [WhiprFlowAudioBarPresentation]
    let glowRadius: CGFloat
    let glowOpacity: CGFloat
    let verticalOffset: CGFloat
}

struct WhiprFlowAudioSignal: Equatable {
    var average: CGFloat
    var peak: CGFloat
    var flux: CGFloat
    var bands: [CGFloat]

    static let empty = WhiprFlowAudioSignal(
        average: 0,
        peak: 0,
        flux: 0,
        bands: Array(repeating: 0, count: WhiprFlowAudioMark.barCount)
    )

    static let paused = WhiprFlowAudioSignal(
        average: 0,
        peak: 0,
        flux: 0,
        bands: Array(repeating: 0, count: WhiprFlowAudioMark.barCount)
    )
}

struct WhiprFlowAudioBarPresentation: Equatable {
    let height: CGFloat
    let width: CGFloat
    let opacity: CGFloat
    let verticalOffset: CGFloat
    let tint: WhiprFlowAudioTint
}

struct WhiprFlowAudioTint: Equatable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat

    var color: Color {
        Color(red: Double(red), green: Double(green), blue: Double(blue))
    }

    var highlightColor: Color {
        mixed(with: WhiprFlowAudioTint(red: 1, green: 1, blue: 0.96), amount: 0.18).color
    }

    func mixed(with other: WhiprFlowAudioTint, amount: CGFloat) -> WhiprFlowAudioTint {
        let clampedAmount = min(max(amount, 0), 1)
        return WhiprFlowAudioTint(
            red: red + (other.red - red) * clampedAmount,
            green: green + (other.green - green) * clampedAmount,
            blue: blue + (other.blue - blue) * clampedAmount
        )
    }
}
