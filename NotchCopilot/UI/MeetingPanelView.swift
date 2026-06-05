import AppKit
import SwiftUI

struct TranscriptQuestionHighlight: Equatable, Sendable {
    var segmentIds: Set<UUID>
    var text: String
    var isLoading = false
    var loadingPhase: Double = 0

    var normalizedText: String {
        Self.normalized(text)
    }

    var isEmpty: Bool {
        segmentIds.isEmpty || normalizedText.isEmpty
    }

    static func normalized(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum TranscriptQuestionHighlighter {
    static let exactBackgroundColor = NSColor.white.withAlphaComponent(0.145)
    static let fallbackBackgroundColor = NSColor.white.withAlphaComponent(0.072)

    private static func backgroundColor(for highlight: TranscriptQuestionHighlight, isFallback: Bool) -> NSColor {
        guard highlight.isLoading else {
            return isFallback ? fallbackBackgroundColor : exactBackgroundColor
        }

        let pulse = (sin(highlight.loadingPhase) + 1) * 0.5
        let alpha = isFallback
            ? CGFloat(0.052 + (pulse * 0.046))
            : CGFloat(0.112 + (pulse * 0.082))
        return NSColor.white.withAlphaComponent(alpha)
    }

    static func apply(
        to attributedString: NSMutableAttributedString,
        visibleText: String,
        visibleRange: NSRange,
        segmentId: UUID,
        highlights: [TranscriptQuestionHighlight]
    ) {
        for highlight in highlights {
            apply(
                to: attributedString,
                visibleText: visibleText,
                visibleRange: visibleRange,
                segmentId: segmentId,
                highlight: highlight
            )
        }
    }

    static func apply(
        to attributedString: NSMutableAttributedString,
        visibleText: String,
        visibleRange: NSRange,
        segmentId: UUID,
        highlight: TranscriptQuestionHighlight?
    ) {
        guard let highlight,
              !highlight.isEmpty,
              highlight.segmentIds.contains(segmentId),
              visibleRange.location != NSNotFound,
              visibleRange.length > 0
        else { return }

        let text = visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let nsText = visibleText as NSString
        let exactRange = nsText.range(
            of: highlight.text,
            options: [.caseInsensitive, .diacriticInsensitive]
        )

        if exactRange.location != NSNotFound {
            attributedString.addAttribute(
                .backgroundColor,
                value: backgroundColor(for: highlight, isFallback: false),
                range: NSRange(location: visibleRange.location + exactRange.location, length: exactRange.length)
            )
            return
        }

        let normalizedVisible = TranscriptQuestionHighlight.normalized(text)
        let normalizedHighlight = highlight.normalizedText
        if normalizedHighlight.contains(normalizedVisible) || normalizedVisible.contains(normalizedHighlight) {
            attributedString.addAttribute(
                .backgroundColor,
                value: backgroundColor(for: highlight, isFallback: false),
                range: visibleRange
            )
        } else {
            attributedString.addAttribute(
                .backgroundColor,
                value: backgroundColor(for: highlight, isFallback: true),
                range: visibleRange
            )
        }
    }
}

struct MeetingPanelView: View {
    @ObservedObject var appState: AppState
    @Environment(\.islandDesignMode) private var islandDesignMode
    @State private var hoveredPresentationMode: QuestionAnswerPresentationMode?
    @State private var pressedPresentationMode: QuestionAnswerPresentationMode?
    private let primaryColor = Color.white.opacity(0.84)
    private let presentationToggleWidth: CGFloat = 176
    private let presentationToggleHeight: CGFloat = 26
    private let presentationTopPadding: CGFloat = 2
    private let presentationContentSpacing: CGFloat = 16
    private var panelWidth: CGFloat { appState.expandedPanelContentWidth }
    private var panelHeight: CGFloat { appState.expandedPanelContentHeight }

    private var segments: [TranscriptSegment] {
        appState.presentationTranscriptSegments
    }

    private var hasQuestionFlow: Bool {
        appState.activeQuestion != nil ||
            appState.suggestedAnswer != nil ||
            !appState.streamingAnswerText.isEmpty ||
            (appState.isShowingCopilotAnswerDetail && appState.activeCopilotInteraction != nil)
    }

    private var qaBodyHeight: CGFloat {
        let chromeHeight = shouldShowPresentationToggle ? presentationToggleHeight + presentationTopPadding + presentationContentSpacing : 0
        return max(150, panelHeight - chromeHeight)
    }

    private var readingColumnWidth: CGFloat {
        max(1, min(panelWidth - 18, 620))
    }

    private var shouldShowPresentationToggle: Bool {
        appState.currentMeeting != nil
    }

    private var shouldShowAmbientAnswerScreen: Bool {
        appState.currentMeeting == nil &&
            (appState.activeQuestion != nil ||
                appState.suggestedAnswer != nil ||
                !appState.streamingAnswerText.isEmpty ||
                (appState.isShowingCopilotAnswerDetail && appState.activeCopilotInteraction != nil) ||
                appState.answerStage.isInProgress)
    }

    var body: some View {
        VStack(alignment: .center, spacing: 0) {
            if appState.isShowingCopilotHistory {
                CopilotTimelinePanelView(
                    appState: appState,
                    width: panelWidth,
                    height: panelHeight,
                    primaryColor: primaryColor
                )
            } else if appState.currentMeeting == nil {
                if shouldShowAmbientAnswerScreen {
                    CopilotIsolatedAnswerPanelView(
                        appState: appState,
                        width: panelWidth,
                        height: panelHeight,
                        primaryColor: primaryColor
                    )
                } else {
                    CopilotTimelinePanelView(
                        appState: appState,
                        width: panelWidth,
                        height: panelHeight,
                        primaryColor: primaryColor
                    )
                }
            } else if hasQuestionFlow {
                answerDetail
            } else {
                transcriptStream(height: panelHeight)
            }
        }
        .frame(width: panelWidth, height: panelHeight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meeting-panel")
        .animation(.easeInOut(duration: 0.14), value: appState.questionAnswerPresentationMode)
        .animation(.easeInOut(duration: 0.14), value: appState.selectedQuestionId)
        .animation(.easeOut(duration: 0.14), value: appState.streamingAnswerText)
    }

    private var presentationToggle: some View {
        HStack(spacing: 2) {
            ForEach(QuestionAnswerPresentationMode.allCases) { mode in
                let isSelected = appState.questionAnswerPresentationMode == mode
                Button {
                    selectPresentationMode(mode)
                } label: {
                    Text(mode.title)
                }
                .buttonStyle(PresentationToggleButtonStyle(
                    isSelected: isSelected,
                    isHovering: hoveredPresentationMode == mode,
                    isOverlayPressed: pressedPresentationMode == mode,
                    primaryColor: primaryColor,
                    designMode: islandDesignMode
                ))
                .contentShape(Rectangle())
                .overlay {
                    MouseDownActionOverlay(
                        action: { selectPresentationMode(mode) },
                        onHover: { hovering in
                            hoveredPresentationMode = hovering ? mode : (hoveredPresentationMode == mode ? nil : hoveredPresentationMode)
                        },
                        onPress: { pressing in
                            pressedPresentationMode = pressing ? mode : (pressedPresentationMode == mode ? nil : pressedPresentationMode)
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .help(mode.title)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(mode.title)
                .accessibilityIdentifier("qa-toggle-\(mode.rawValue)")
            }
        }
        .padding(2)
        .frame(width: min(readingColumnWidth, presentationToggleWidth), height: presentationToggleHeight)
        .background(
            IslandGlassFill(
                shape: RoundedRectangle(cornerRadius: 7, style: .continuous),
                mode: islandDesignMode,
                solidOpacity: 0.026,
                glassTintOpacity: 0.044,
                glassFallbackOpacity: 0.030
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.white.opacity(islandDesignMode == .liquidGlass ? 0.075 : 0.042), lineWidth: 0.5)
        )
    }

    private var answerDetail: some View {
        VStack(alignment: .center, spacing: shouldShowPresentationToggle ? presentationContentSpacing : 0) {
            if shouldShowPresentationToggle {
                presentationToggle
                    .frame(width: readingColumnWidth, height: presentationToggleHeight, alignment: .center)
            }
            if shouldShowPresentationToggle && appState.questionAnswerPresentationMode == .transcript {
                transcriptStream(height: qaBodyHeight)
            } else {
                qaColumn
                    .frame(width: readingColumnWidth, height: qaBodyHeight, alignment: .topLeading)
            }
        }
        .padding(.top, shouldShowPresentationToggle ? presentationTopPadding : 0)
        .frame(width: panelWidth, height: panelHeight, alignment: .top)
        .overlay(alignment: .bottomTrailing) {
            if appState.activeQuestion != nil && appState.answerStage.isInProgress {
                TranscriptQuestionSpinner(primaryColor: primaryColor)
                    .padding(.trailing, 12)
                    .padding(.bottom, 11)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
    }

    private var qaColumn: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 18) {
                questionTitleRow
                    .layoutPriority(1)

                RichAnswerRenderer(
                    text: answerTextForDisplay,
                    richAnswer: selectedRichAnswer,
                    format: selectedAnswerFormat,
                    sources: selectedSources,
                    confidence: appState.suggestedAnswer?.confidence ?? appState.activeCopilotInteraction?.confidence,
                    riskLevel: appState.suggestedAnswer?.riskLevel,
                    tone: appState.suggestedAnswer?.suggestedTone,
                    caveats: appState.suggestedAnswer?.caveats ?? [],
                    allowRemoteLinkPreview: allowRemoteLinkPreview,
                    leadStyle: .plain,
                    showsEvidenceBlocks: showsAnswerEvidenceBlocks
                )
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .protectedContentRegion(appState.preferences.stealthModeEnabled)
        .accessibilityIdentifier("qa-answer-scroll")
    }

    private var questionTitleText: String {
        appState.questionClassification?.extractedQuestion ??
            appState.detectedQuestion ??
            appState.activeQuestion?.rawText ??
            (appState.isShowingCopilotAnswerDetail ? appState.activeCopilotInteraction?.prompt : nil) ??
            ""
    }

    private var questionTitleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if appState.questionAnswerQueue.count > 1 {
                questionNavigationTextButton("‹", help: "Previous question") {
                    withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.9)) {
                        appState.selectPreviousQuestion()
                    }
                }
            }

            Text(questionTitleText)
                .font(.system(size: 16.1, weight: .medium))
                .foregroundStyle(primaryColor.opacity(0.9))
                .multilineTextAlignment(.leading)
                .lineSpacing(4.4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(questionTitleText)
                .accessibilityIdentifier("qa-question-title")

            if appState.questionAnswerQueue.count > 1 {
                questionNavigationTextButton("›", help: "Next question") {
                    withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.9)) {
                        appState.selectNextQuestion()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var answerTextForDisplay: String {
        let text = appState.visibleAnswerText
        if !text.isEmpty {
            return text
        }
        if appState.isShowingCopilotAnswerDetail,
           let response = appState.activeCopilotInteraction?.response.trimmingCharacters(in: .whitespacesAndNewlines),
           !response.isEmpty {
            return response
        }
        if appState.answerStage == .failed {
            return appState.copilotFailureMessage ?? "Nao consegui concluir esta acao agora."
        }
        return ""
    }

    private var selectedSources: [AnswerSource] {
        appState.suggestedAnswer?.usedSources ?? appState.activeCopilotInteraction?.sources ?? []
    }

    private var selectedRichAnswer: RichAnswerPayload? {
        appState.suggestedAnswer?.richAnswer ?? appState.activeCopilotInteraction?.richAnswer
    }

    private var selectedAnswerFormat: CopilotAnswerFormat? {
        appState.suggestedAnswer?.answerFormat ?? inferredFormat(tool: appState.activeCopilotInteraction?.tool, intent: appState.activeCopilotInteraction?.intent)
    }

    private var showsAnswerEvidenceBlocks: Bool {
        appState.suggestedAnswer == nil
            && appState.activeQuestion == nil
            && appState.activeCopilotInteraction?.questionId == nil
    }

    private var allowRemoteLinkPreview: Bool {
        !appState.preferences.localOnlyMode
    }

    private func inferredFormat(tool: CopilotToolKind?, intent: CopilotIntentKind?) -> CopilotAnswerFormat? {
        if intent == .newsSearch { return .newsWithSources }
        switch tool {
        case .calculator:
            return .calculation
        case .reminder:
            return .reminderConfirmation
        case .localMemory:
            return .memoryResults
        case .webSearch:
            return .bullets
        case .unavailable:
            return .errorState
        case .answerSynthesis, .none:
            return nil
        }
    }

    private func selectPresentationMode(_ mode: QuestionAnswerPresentationMode) {
        guard appState.questionAnswerPresentationMode != mode else { return }

        withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.9)) {
            appState.selectPresentationMode(mode)
        }
    }

    private func questionNavigationTextButton(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        QuestionNavigationTextButton(title: title, help: help, primaryColor: primaryColor, action: action)
    }

    private func transcriptStream(height: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            if segments.isEmpty {
                Color.clear
                emptyStateView
                    .transition(.opacity)
            } else {
                TimelineView(.animation(
                    minimumInterval: 0.36,
                    paused: !appState.shouldShowTranscriptQuestionLoadingIndicator
                )) { timeline in
                    LiveTranscriptScrollView(
                        segments: segments,
                        showOriginalText: appState.preferences.showOriginalText,
                        showTranslatedText: appState.preferences.showTranslatedText,
                        questionHighlights: activeTranscriptQuestionHighlights(
                            loadingPhase: transcriptQuestionHighlightLoadingPhase(for: timeline.date)
                        ),
                        onCopyBlock: { segment, text in
                            appState.copyTranscriptSegmentToPasteboard(segment, text: text)
                        },
                        onDeleteSegment: { segment in
                            appState.deleteTranscriptSegment(segment)
                        }
                    )
                    .frame(width: panelWidth, height: height)
                    .protectedContentRegion(appState.preferences.stealthModeEnabled)
                    .transition(.opacity)
                }

                bottomScrollFade
            }
        }
        .frame(height: height)
        .clipped()
        .animation(.easeOut(duration: 0.12), value: segments.isEmpty)
        .animation(.easeOut(duration: 0.16), value: appState.shouldShowTranscriptQuestionLoadingIndicator)
        .accessibilityIdentifier("qa-transcript-stream")
    }

    private func activeTranscriptQuestionHighlights(loadingPhase: Double = 0) -> [TranscriptQuestionHighlight] {
        let queuedHighlights = appState.questionAnswerQueue.compactMap { item -> TranscriptQuestionHighlight? in
            guard item.stage != .cancelled else { return nil }
            if let classification = item.classification,
               (!classification.responseNeeded || classification.rhetorical) {
                return nil
            }
            let questionText = item.classification?.extractedQuestion ?? item.candidate.rawText
            let isLoading = item.stage.isInProgress ||
                (appState.activeQuestion?.id == item.candidate.id && appState.answerStage.isInProgress)
            let highlight = TranscriptQuestionHighlight(
                segmentIds: Set(item.candidate.sourceSegmentIds),
                text: questionText,
                isLoading: isLoading,
                loadingPhase: isLoading ? loadingPhase : 0
            )
            return highlight.isEmpty ? nil : highlight
        }
        if !queuedHighlights.isEmpty {
            return queuedHighlights
        }

        guard let question = appState.activeQuestion else { return [] }
        let questionText = questionTitleText.trimmingCharacters(in: .whitespacesAndNewlines)
        let isLoading = appState.answerStage.isInProgress
        let highlight = TranscriptQuestionHighlight(
            segmentIds: Set(question.sourceSegmentIds),
            text: questionText.isEmpty ? question.rawText : questionText,
            isLoading: isLoading,
            loadingPhase: isLoading ? loadingPhase : 0
        )
        return highlight.isEmpty ? [] : [highlight]
    }

    private func transcriptQuestionHighlightLoadingPhase(for date: Date) -> Double {
        guard appState.shouldShowTranscriptQuestionLoadingIndicator else { return 0 }
        return date.timeIntervalSinceReferenceDate * 4.4
    }

    private var bottomScrollFade: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            ZStack {
                VisualEffectBlur(material: .hudWindow, blendingMode: .withinWindow)
                    .opacity(islandDesignMode == .liquidGlass ? 0.18 : 0.24)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black.opacity(0.45), location: 0.58),
                                .init(color: .black, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: Color.black.opacity(islandDesignMode == .liquidGlass ? 0.07 : 0.10), location: 0.55),
                        .init(color: Color.black.opacity(islandDesignMode == .liquidGlass ? 0.20 : 0.28), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(height: 22)
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    private var emptyStateText: String {
        switch appState.currentMeeting?.status {
        case .listening:
            appState.meetingTranscriptionStatus == .idle ? "Loading transcript..." : appState.meetingTranscriptionStatus.displayText
        case .paused:
            "Paused"
        case .summarizing:
            "Summarizing..."
        default:
            "Ready to start"
        }
    }

    private var shouldShowLoadingIndicator: Bool {
        appState.currentMeeting?.status == .listening && segments.isEmpty
    }

    private var emptyStateView: some View {
        HStack(spacing: 8) {
            if shouldShowLoadingIndicator {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.58)
                    .tint(primaryColor.opacity(0.58))
            }
            Text(emptyStateText)
                .font(.system(size: 15.4, weight: .light))
                .foregroundStyle(primaryColor.opacity(0.68))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

private struct CopilotIsolatedAnswerPanelView: View {
    @ObservedObject var appState: AppState
    var width: CGFloat
    var height: CGFloat
    var primaryColor: Color
    @Environment(\.islandDesignMode) private var islandDesignMode

    private var secondaryColor: Color { primaryColor.opacity(0.56) }
    private var dividerColor: Color { Color.white.opacity(islandDesignMode == .liquidGlass ? 0.085 : 0.052) }
    private var questionRowMaxWidth: CGFloat { max(220, min(width - 72, 660)) }
    private var questionTextMaxWidth: CGFloat { max(160, questionRowMaxWidth) }
    private var answerSources: [AnswerSource] {
        appState.suggestedAnswer?.usedSources ?? appState.activeCopilotInteraction?.sources ?? []
    }

    private var questionText: String {
        let candidates = [
            appState.questionClassification?.extractedQuestion,
            appState.detectedQuestion,
            appState.activeQuestion?.rawText,
            appState.copilotPushToTalkTranscript,
            appState.activeCopilotInteraction?.prompt
        ]
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }

    private var answerText: String {
        let visible = appState.visibleAnswerText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !visible.isEmpty { return visible }
        if appState.isShowingCopilotAnswerDetail,
           let response = appState.activeCopilotInteraction?.response.trimmingCharacters(in: .whitespacesAndNewlines),
           !response.isEmpty {
            return response
        }
        if appState.answerStage == .failed {
            return appState.copilotFailureMessage ?? appState.copilotPushToTalkErrorMessage ?? "Could not complete this request."
        }
        return ""
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 18) {
                questionRow

                Rectangle()
                    .fill(dividerColor)
                    .frame(height: 0.5)

                answerSection
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.bottom, 8)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .protectedContentRegion(appState.preferences.stealthModeEnabled)
        .animation(.easeOut(duration: 0.14), value: appState.answerStage)
        .animation(.easeOut(duration: 0.14), value: answerText)
    }

    private var questionRow: some View {
        Text(questionText)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(primaryColor.opacity(0.90))
            .multilineTextAlignment(.leading)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: questionTextMaxWidth, alignment: .leading)
        .frame(maxWidth: questionRowMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var showsAnswerEvidenceBlocks: Bool {
        appState.suggestedAnswer == nil
            && appState.activeQuestion == nil
            && appState.activeCopilotInteraction?.questionId == nil
    }

    @ViewBuilder
    private var answerSection: some View {
        if answerText.isEmpty && appState.answerStage.isInProgress {
            HStack {
                Spacer(minLength: 0)
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.58)
                    .tint(secondaryColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
        } else {
                RichAnswerRenderer(
                    text: answerText,
                    richAnswer: appState.suggestedAnswer?.richAnswer ?? appState.activeCopilotInteraction?.richAnswer,
                    format: appState.suggestedAnswer?.answerFormat ?? inferredFormat(tool: appState.activeCopilotInteraction?.tool, intent: appState.activeCopilotInteraction?.intent),
                    sources: answerSources,
                    confidence: appState.suggestedAnswer?.confidence ?? appState.activeCopilotInteraction?.confidence,
                    riskLevel: appState.suggestedAnswer?.riskLevel,
                    tone: appState.suggestedAnswer?.suggestedTone,
                    caveats: appState.suggestedAnswer?.caveats ?? [],
                    allowRemoteLinkPreview: !appState.preferences.localOnlyMode,
                    leadStyle: .plain,
                    showsEvidenceBlocks: showsAnswerEvidenceBlocks
                )
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func inferredFormat(tool: CopilotToolKind?, intent: CopilotIntentKind?) -> CopilotAnswerFormat? {
        if intent == .newsSearch { return .newsWithSources }
        switch tool {
        case .calculator:
            return .calculation
        case .reminder:
            return .reminderConfirmation
        case .localMemory:
            return .memoryResults
        case .webSearch:
            return .bullets
        case .unavailable:
            return .errorState
        case .answerSynthesis, .none:
            return nil
            }
        }
    }

private struct CopilotTimelinePanelView: View {
    @ObservedObject var appState: AppState
    var width: CGFloat
    var height: CGFloat
    var primaryColor: Color
    @Environment(\.islandDesignMode) private var islandDesignMode
    @State private var selectedEntryID: String?

    private var secondaryColor: Color { primaryColor.opacity(0.56) }
    private var tertiaryColor: Color { primaryColor.opacity(0.34) }

    private var entries: [CopilotTimelineEntry] {
        var items = appState.copilotInteractions.map(CopilotTimelineEntry.persisted)

        if let activeInteraction = appState.activeCopilotInteraction,
           !items.contains(where: { $0.interaction?.id == activeInteraction.id }) {
            items.insert(.persisted(activeInteraction), at: 0)
        } else if let transient = CopilotTimelineEntry.transient(from: appState),
                  !items.contains(where: { $0.questionId == transient.questionId }) {
            items.insert(transient, at: 0)
        }

        return items.sorted { lhs, rhs in
            if lhs.isLive != rhs.isLive { return lhs.isLive && !rhs.isLive }
            return lhs.createdAt > rhs.createdAt
        }
    }

    private var entryIDs: [String] {
        entries.map(\.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if entries.isEmpty {
                emptyTimeline
                    .frame(width: width, height: height, alignment: .center)
            } else {
                timelineList
                    .frame(width: width, height: height, alignment: .topLeading)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .protectedContentRegion(appState.preferences.stealthModeEnabled)
        .onAppear(perform: ensureSelection)
        .onChange(of: entryIDs) {
            ensureSelection()
        }
        .animation(.easeOut(duration: 0.14), value: selectedEntryID)
        .animation(.easeOut(duration: 0.16), value: entryIDs)
    }

    private var timelineList: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    let previous = index > 0 ? entries[index - 1] : nil
                    if shouldShowDayDivider(for: entry, previous: previous) {
                        dayDivider(entry.dayLabel)
                            .padding(.top, index == 0 ? 0 : 4)
                    }

                    CopilotTimelineRow(
                        entry: entry,
                        primaryColor: primaryColor,
                        secondaryColor: secondaryColor,
                        tertiaryColor: tertiaryColor,
                        designMode: islandDesignMode,
                        allowRemoteLinkPreview: !appState.preferences.localOnlyMode,
                        onSelect: {
                            select(entry)
                        },
                        onCopy: {
                            copy(entry)
                        },
                        onOpenSources: {
                            openSources(entry)
                        },
                        onOpenAnswer: {
                            openAnswer(entry)
                        },
                        onRegenerateWeb: {
                            regenerate(entry, forceWeb: true)
                        }
                    )
                }
            }
            .padding(.top, 2)
            .padding(.trailing, 4)
            .padding(.bottom, 8)
        }
    }

    private var emptyTimeline: some View {
        VStack(spacing: 7) {
            Image(systemName: "clock")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tertiaryColor)
            Text("No interactions yet")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(secondaryColor)
                .lineLimit(1)
        }
    }

    private func dayDivider(_ label: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(tertiaryColor)
                .lineLimit(1)
            Rectangle()
                .fill(Color.white.opacity(islandDesignMode == .liquidGlass ? 0.085 : 0.052))
                .frame(height: 0.5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ensureSelection() {
        guard let first = entries.first else {
            selectedEntryID = nil
            return
        }
        if let selectedEntryID, entries.contains(where: { $0.id == selectedEntryID }) {
            return
        }
        selectedEntryID = first.id
        if let interaction = first.interaction {
            appState.selectCopilotInteraction(interaction)
        }
    }

    private func shouldShowDayDivider(for entry: CopilotTimelineEntry, previous: CopilotTimelineEntry?) -> Bool {
        guard let previous else { return true }
        return !Calendar.current.isDate(entry.createdAt, inSameDayAs: previous.createdAt)
    }

    private func select(_ entry: CopilotTimelineEntry) {
        selectedEntryID = entry.id
        if let interaction = entry.interaction {
            appState.selectCopilotInteraction(interaction)
        }
    }

    private func copy(_ entry: CopilotTimelineEntry) {
        if let interaction = entry.interaction {
            appState.copyCopilotInteractionToPasteboard(interaction)
        } else {
            appState.copySelectedAnswerToPasteboard()
        }
    }

    private func openSources(_ entry: CopilotTimelineEntry) {
        if let interaction = entry.interaction {
            appState.openCopilotInteractionSources(interaction)
        } else {
            appState.openSelectedAnswerSources()
        }
    }

    private func openAnswer(_ entry: CopilotTimelineEntry) {
        select(entry)
        if let interaction = entry.interaction {
            appState.openCopilotInteractionAnswer(interaction)
        } else {
            appState.showSelectedCopilotAnswerPanel()
        }
    }

    private func regenerate(_ entry: CopilotTimelineEntry, forceWeb: Bool) {
        if let interaction = entry.interaction {
            appState.regenerateCopilotInteraction(interaction, forceWeb: forceWeb)
        } else {
            appState.analyzeCopilotPrompt(entry.prompt, forceWeb: forceWeb)
        }
    }
}

private struct CopilotTimelineRow: View {
    var entry: CopilotTimelineEntry
    var primaryColor: Color
    var secondaryColor: Color
    var tertiaryColor: Color
    var designMode: IslandDesignMode
    var allowRemoteLinkPreview: Bool
    var onSelect: () -> Void
    var onCopy: () -> Void
    var onOpenSources: () -> Void
    var onOpenAnswer: () -> Void
    var onRegenerateWeb: () -> Void
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            header
            preview
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(timelineHoverBackground)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovering = $0 }
        .onTapGesture(perform: handleTap)
        .contextMenu {
            Button("Open answer", action: onOpenAnswer)
            Button("Copy", action: onCopy)
            if entry.hasSourceLink {
                Button("Open sources", action: onOpenSources)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.prompt). \(entry.responsePreview)")
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    @ViewBuilder
    private var timelineHoverBackground: some View {
        if isHovering {
            IslandGlassFill(
                shape: RoundedRectangle(cornerRadius: 8, style: .continuous),
                mode: designMode,
                solidOpacity: 0.036,
                glassTintOpacity: 0.052,
                glassFallbackOpacity: 0.036
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.068), lineWidth: 0.5)
            )
            .transition(.opacity)
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Text(entry.timeLabel)
                .font(.system(size: 9.8, weight: .medium, design: .monospaced))
                .foregroundStyle(tertiaryColor)
                .lineLimit(1)

            if entry.isLive {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.46)
                    .tint(secondaryColor)
                    .frame(width: 12, height: 12)
                    .accessibilityLabel("Loading")
            }

            Spacer(minLength: 8)

            Text(entry.metaLabel)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tertiaryColor)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(entry.prompt)
                .font(.system(size: 12.8, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.88))
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)

            if !entry.responsePreview.isEmpty {
                Text(entry.responsePreview)
                    .font(.system(size: 11.6, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.52))
                    .lineLimit(2)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            } else if entry.isLive {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.48)
                        .tint(secondaryColor)
                    Text("Preparing")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(secondaryColor)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func handleTap() {
        if entry.isLive {
            onSelect()
        } else {
            onOpenAnswer()
        }
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let richPreviewPayload {
                RichAnswerRenderer(
                    text: "",
                    richAnswer: richPreviewPayload,
                    format: entry.answerFormat,
                    sources: entry.sources,
                    confidence: entry.confidence,
                    allowRemoteLinkPreview: allowRemoteLinkPreview,
                    density: .detail,
                    showsEvidenceBlocks: entry.questionId == nil,
                    onCopy: onCopy,
                    onOpenSources: onOpenSources,
                    onRegenerateWithWeb: onRegenerateWeb
                )
            } else if let webSource = entry.primaryWebSource {
                WebSourcePreviewView(
                    source: webSource,
                    primaryColor: primaryColor,
                    secondaryColor: secondaryColor,
                    tertiaryColor: tertiaryColor,
                    designMode: designMode,
                    allowRemoteLinkPreview: allowRemoteLinkPreview
                )
            } else if !entry.sources.isEmpty {
                sourceStrip
            }

            actionStrip
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var richPreviewPayload: RichAnswerPayload? {
        let validator = RichAnswerValidator()
        let validatedPayload = validator.validated(entry.richAnswer, sources: entry.sources)
        let fallbackPayload = fallbackSourceCardsPayload()
        guard let payload = validatedPayload ?? fallbackPayload else { return nil }

        let compactBlockTypes: Set<String> = [
            RichAnswerBlockKind.sourceCards.rawValue,
            RichAnswerBlockKind.steps.rawValue,
            RichAnswerBlockKind.checklist.rawValue,
            RichAnswerBlockKind.comparison.rawValue,
            RichAnswerBlockKind.metrics.rawValue,
            RichAnswerBlockKind.code.rawValue,
            RichAnswerBlockKind.timeline.rawValue,
            RichAnswerBlockKind.memoryResults.rawValue,
            RichAnswerBlockKind.clarification.rawValue,
            RichAnswerBlockKind.warning.rawValue
        ]
        let blocks = payload.blocks.filter { compactBlockTypes.contains($0.type) }
        guard !blocks.isEmpty else { return nil }
        return validator.validated(RichAnswerPayload(version: payload.version, blocks: blocks), sources: entry.sources)
    }

    private func fallbackSourceCardsPayload() -> RichAnswerPayload? {
        let sourceIndexes = entry.sources.indices.filter { index in
            let source = entry.sources[index]
            return source.type == .web && source.webURL != nil
        }
        guard !sourceIndexes.isEmpty else { return nil }
        return RichAnswerPayload(blocks: [
            RichAnswerBlockPayload(
                type: RichAnswerBlockKind.sourceCards.rawValue,
                title: "Sources",
                sourceIndexes: Array(sourceIndexes.prefix(6))
            )
        ])
    }

    private var sourceStrip: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(entry.sources.prefix(3).enumerated()), id: \.offset) { _, source in
                HStack(spacing: 6) {
                    Image(systemName: "link")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(tertiaryColor)
                    Text(source.title)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(secondaryColor)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.top, 1)
    }

    private var actionStrip: some View {
        let hasPrompt = !entry.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasResponse = !entry.response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return HStack(spacing: 4) {
            if hasPrompt || hasResponse {
                IconButton(systemName: "arrow.up.forward.square", help: "Open answer", size: .compact, action: onOpenAnswer)
            }
            if hasResponse {
                IconButton(systemName: "doc.on.doc", help: "Copy", size: .compact, action: onCopy)
            }
            Spacer(minLength: 0)
        }
        .opacity(entry.isLive ? 0.45 : 1)
    }
}

private struct WebSourcePreviewView: View {
    var source: AnswerSource
    var primaryColor: Color
    var secondaryColor: Color
    var tertiaryColor: Color
    var designMode: IslandDesignMode
    var allowRemoteLinkPreview: Bool
    @State private var loadedPreview: WebLinkPreview?

    private var preview: WebLinkPreview {
        loadedPreview ?? WebLinkPreview.fallback(for: source)
    }

    var body: some View {
        HStack(spacing: 10) {
            thumbnail

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    favicon
                    Text(preview.domain)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(tertiaryColor)
                        .lineLimit(1)
                }

                Text(preview.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(primaryColor.opacity(0.86))
                    .lineLimit(1)

                if let description = preview.description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 10.2, weight: .regular))
                        .foregroundStyle(secondaryColor)
                        .lineLimit(2)
                        .lineSpacing(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            IslandGlassFill(
                shape: RoundedRectangle(cornerRadius: 7, style: .continuous),
                mode: designMode,
                solidOpacity: 0.026,
                glassTintOpacity: 0.038,
                glassFallbackOpacity: 0.026
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.white.opacity(0.040), lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onTapGesture {
            NSWorkspace.shared.open(preview.url)
        }
        .task(id: source.reference) {
            loadedPreview = await WebLinkPreviewService.shared.preview(for: source, allowRemoteFetch: allowRemoteLinkPreview)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Web source \(preview.title), \(preview.domain)")
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.040))

            if let imageURL = preview.imageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .empty:
                        favicon
                    case .failure:
                        fallbackLinkIcon
                    @unknown default:
                        fallbackLinkIcon
                    }
                }
            } else {
                fallbackLinkIcon
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.white.opacity(0.038), lineWidth: 0.5)
        )
    }

    private var favicon: some View {
        ZStack {
            if let faviconURL = preview.faviconURL {
                AsyncImage(url: faviconURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                    default:
                        Image(systemName: "link")
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundStyle(tertiaryColor)
                    }
                }
            } else {
                Image(systemName: "link")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(tertiaryColor)
            }
        }
        .frame(width: 12, height: 12)
    }

    private var fallbackLinkIcon: some View {
        Image(systemName: "link")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(tertiaryColor)
    }
}

private struct CopilotTimelineEntry: Identifiable, Hashable {
    enum Status: Hashable {
        case preparing
        case ready
        case failed
    }

    var id: String
    var questionId: UUID?
    var prompt: String
    var response: String
    var tool: CopilotToolKind
    var intent: CopilotIntentKind
    var sources: [AnswerSource]
    var richAnswer: RichAnswerPayload?
    var confidence: Double
    var latencyMs: Int
    var createdAt: Date
    var status: Status
    var interaction: CopilotInteraction?

    var isLive: Bool {
        status == .preparing
    }

    var hasSourceLink: Bool {
        sources.contains { source in
            guard let reference = source.reference?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
            return URL(string: reference)?.scheme?.hasPrefix("http") == true
        }
    }

    var primaryWebSource: AnswerSource? {
        sources.first { $0.webURL != nil }
    }

    var answerFormat: CopilotAnswerFormat? {
        if intent == .newsSearch { return .newsWithSources }
        switch tool {
        case .calculator:
            return .calculation
        case .reminder:
            return .reminderConfirmation
        case .localMemory:
            return .memoryResults
        case .webSearch:
            return .bullets
        case .unavailable:
            return .errorState
        case .answerSynthesis:
            return nil
        }
    }

    var responsePreview: String {
        CopilotTimelinePreviewBuilder.preview(
            response: response,
            richAnswer: richAnswer,
            sources: sources,
            limit: 128
        )
    }

    var timeLabel: String {
        DateFormatting.time.string(from: createdAt)
    }

    var dayLabel: String {
        if Calendar.current.isDateInToday(createdAt) {
            return "Today"
        }
        if Calendar.current.isDateInYesterday(createdAt) {
            return "Yesterday"
        }
        return Self.dayFormatter.string(from: createdAt)
    }

    var metaLabel: String {
        if isLive {
            return "LIVE"
        }
        if sources.contains(where: { $0.type == .web }) {
            return sources.count == 1 ? "WEB 1" : "WEB \(sources.count)"
        }
        if latencyMs > 0 {
            return Self.formattedLatency(latencyMs)
        }
        return tool.shortLabel
    }

    private static func formattedLatency(_ milliseconds: Int) -> String {
        guard milliseconds >= 1_000 else {
            return "\(milliseconds) ms"
        }

        let seconds = Double(milliseconds) / 1_000
        return String(format: "%.1f s", seconds)
    }

    var iconName: String {
        switch status {
        case .preparing:
            return "circle.dotted"
        case .failed:
            return "exclamationmark.triangle"
        case .ready:
            return tool.iconName
        }
    }

    static func persisted(_ interaction: CopilotInteraction) -> CopilotTimelineEntry {
        CopilotTimelineEntry(
            id: interaction.id.uuidString,
            questionId: interaction.questionId,
            prompt: interaction.prompt,
            response: interaction.response,
            tool: interaction.tool,
            intent: interaction.intent,
            sources: interaction.sources,
            richAnswer: interaction.richAnswer,
            confidence: interaction.confidence,
            latencyMs: interaction.latencyMs,
            createdAt: interaction.createdAt,
            status: interaction.tool == .unavailable || interaction.intent == .ambiguous ? .failed : .ready,
            interaction: interaction
        )
    }

    @MainActor
    static func transient(from appState: AppState) -> CopilotTimelineEntry? {
        guard let question = appState.activeQuestion else { return nil }
        let response = appState.visibleAnswerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let isFailed = appState.answerStage == .failed
        let isReady = appState.answerStage == .ready || !response.isEmpty
        let fallbackResponse: String
        if !response.isEmpty {
            fallbackResponse = response
        } else if isFailed {
            fallbackResponse = appState.copilotFailureMessage ?? "Could not finish this action."
        } else {
            fallbackResponse = ""
        }

        return CopilotTimelineEntry(
            id: "live-\(question.id.uuidString)",
            questionId: question.id,
            prompt: question.rawText,
            response: fallbackResponse,
            tool: .answerSynthesis,
            intent: .answerableQuestion,
            sources: appState.suggestedAnswer?.usedSources ?? [],
            richAnswer: appState.suggestedAnswer?.richAnswer,
            confidence: appState.questionClassification?.confidence ?? 0,
            latencyMs: appState.suggestedAnswer?.latencyMs ?? 0,
            createdAt: question.detectedAt,
            status: isFailed ? .failed : (isReady ? .ready : .preparing),
            interaction: nil
        )
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

enum CopilotTimelinePreviewBuilder {
    nonisolated static func preview(
        response: String,
        richAnswer: RichAnswerPayload?,
        sources: [AnswerSource],
        limit: Int = 128
    ) -> String {
        let rawText = richPreviewText(from: richAnswer)
            ?? RichAnswerTextSanitizer.removingRenderedSourceURLs(from: response, sources: sources)
        return trimmedPreview(from: plainPreviewText(rawText), limit: limit)
    }

    nonisolated private static func richPreviewText(from payload: RichAnswerPayload?) -> String? {
        guard let payload else { return nil }

        for block in payload.blocks {
            switch RichAnswerBlockKind(rawValue: block.type) {
            case .lead:
                if let text = firstNonEmpty(block.text, block.subtitle, block.title) {
                    return text
                }
            case .paragraph, .clarification, .warning:
                if let text = firstNonEmpty(block.text, block.title) {
                    return text
                }
            case .steps, .checklist, .timeline:
                let items = block.items.prefix(2).enumerated().compactMap { index, item in
                    item.text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmptyRichAnswer.map { "\(index + 1). \($0)" }
                }
                if !items.isEmpty {
                    return items.joined(separator: "  ")
                }
            case .comparison, .memoryResults:
                let items = block.items.prefix(2).compactMap { item in
                    firstNonEmpty(item.title, item.text)
                }
                if !items.isEmpty {
                    return items.joined(separator: "  ")
                }
            case .metrics:
                if let value = firstNonEmpty(block.value, block.text, block.label) {
                    return [block.label, value]
                        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmptyRichAnswer }
                        .joined(separator: ": ")
                }
            case .code:
                if let code = block.code,
                   let firstLine = code.replacingOccurrences(of: "\r\n", with: "\n")
                    .components(separatedBy: "\n")
                    .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                    .first(where: { !$0.isEmpty }) {
                    return "Code: \(firstLine)"
                }
            case .sourceCards, .actions, .none:
                continue
            }
        }

        return nil
    }

    nonisolated private static func plainPreviewText(_ text: String) -> String {
        var output = text.replacingOccurrences(of: "\r\n", with: "\n")
        output = output.replacingOccurrences(of: "```", with: " ")
        for marker in ["**", "__", "`", "#", ">"] {
            output = output.replacingOccurrences(of: marker, with: "")
        }
        return output
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func trimmedPreview(from text: String, limit: Int) -> String {
        guard text.count > limit else { return text }

        let candidate = String(text.prefix(limit))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let breakCharacters = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;:"))
        if let breakIndex = candidate.rangeOfCharacter(from: breakCharacters, options: .backwards)?.lowerBound,
           candidate.distance(from: candidate.startIndex, to: breakIndex) > max(40, limit / 2) {
            return String(candidate[..<breakIndex]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
        }
        return candidate + "..."
    }

    nonisolated private static func firstNonEmpty(_ values: String?...) -> String? {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmptyRichAnswer }
            .first
    }
}

private extension CopilotToolKind {
    var shortLabel: String {
        switch self {
        case .answerSynthesis:
            return "ANSWER"
        case .calculator:
            return "CALC"
        case .reminder:
            return "REMINDER"
        case .localMemory:
            return "MEMORY"
        case .webSearch:
            return "WEB"
        case .unavailable:
            return "ERROR"
        }
    }

    var iconName: String {
        switch self {
        case .answerSynthesis:
            return "sparkles"
        case .calculator:
            return "function"
        case .reminder:
            return "bell"
        case .localMemory:
            return "archivebox"
        case .webSearch:
            return "globe"
        case .unavailable:
            return "exclamationmark.triangle"
        }
    }
}

private extension AnswerSource {
    var canOpenFromAnswerSurface: Bool {
        if webURL != nil {
            return true
        }

        guard let reference = reference?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reference.isEmpty,
              let url = URL(string: reference),
              let scheme = url.scheme?.lowercased() else {
            return false
        }

        return scheme == "file" || scheme == "notchly"
    }
}

private struct TranscriptQuestionSpinner: View {
    var primaryColor: Color
    @Environment(\.islandDesignMode) private var islandDesignMode

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .scaleEffect(0.54)
            .tint(primaryColor.opacity(0.48))
            .frame(width: 22, height: 22)
            .accessibilityIdentifier("qa-question-spinner")
            .background(
                IslandGlassFill(
                    shape: Capsule(style: .continuous),
                    mode: islandDesignMode,
                    solidOpacity: 0.13,
                    glassTintOpacity: 0.052,
                    glassFallbackOpacity: 0.046
                )
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(islandDesignMode == .liquidGlass ? 0.095 : 0.050), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(islandDesignMode == .liquidGlass ? 0.10 : 0.16), radius: 5, x: 0, y: 2)
            .accessibilityLabel("Question answer loading")
    }
}

private struct PresentationToggleButtonStyle: ButtonStyle {
    var isSelected: Bool
    var isHovering: Bool
    var isOverlayPressed: Bool
    var primaryColor: Color
    var designMode: IslandDesignMode

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed || isOverlayPressed
        configuration.label
            .font(.system(size: 10.5, weight: isSelected ? .medium : .regular))
            .foregroundStyle(isSelected ? primaryColor.opacity(0.82) : primaryColor.opacity(pressed || isHovering ? 0.62 : 0.48))
            .lineLimit(1)
            .minimumScaleFactor(0.86)
            .frame(maxWidth: .infinity)
            .frame(height: 22)
            .background(
                IslandGlassFill(
                    shape: RoundedRectangle(cornerRadius: 6, style: .continuous),
                    mode: designMode,
                    solidOpacity: backgroundOpacity(isPressed: pressed),
                    glassTintOpacity: glassTintOpacity(isPressed: pressed),
                    glassFallbackOpacity: glassFallbackOpacity(isPressed: pressed)
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.white.opacity(strokeOpacity(isPressed: pressed)), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .scaleEffect(pressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.10), value: isOverlayPressed)
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private func backgroundOpacity(isPressed: Bool) -> Double {
        guard designMode == .solid else { return glassFallbackOpacity(isPressed: isPressed) }
        if isSelected { return isPressed ? 0.115 : 0.072 }
        if isPressed { return 0.075 }
        if isHovering { return 0.036 }
        return 0
    }

    private func strokeOpacity(isPressed: Bool) -> Double {
        if designMode == .liquidGlass {
            if isPressed { return 0.15 }
            if isSelected || isHovering { return 0.095 }
            return 0.035
        }
        if isPressed { return 0.12 }
        if isSelected || isHovering { return 0.055 }
        return 0
    }

    private func glassTintOpacity(isPressed: Bool) -> Double {
        if isSelected { return isPressed ? 0.105 : 0.074 }
        if isPressed { return 0.070 }
        if isHovering { return 0.045 }
        return 0.018
    }

    private func glassFallbackOpacity(isPressed: Bool) -> Double {
        if isSelected { return isPressed ? 0.085 : 0.060 }
        if isPressed { return 0.058 }
        if isHovering { return 0.034 }
        return 0.012
    }
}

private struct QuestionNavigationTextButton: View {
    var title: String
    var help: String
    var primaryColor: Color
    var action: () -> Void
    @Environment(\.islandDesignMode) private var islandDesignMode
    @State private var isHovering = false
    @State private var isOverlayPressed = false

    var body: some View {
        Button(action: action) {
            Text(title)
        }
        .buttonStyle(QuestionNavigationTextButtonStyle(primaryColor: primaryColor, designMode: islandDesignMode, isHovering: isHovering, isOverlayPressed: isOverlayPressed))
        .contentShape(Rectangle())
        .overlay {
            MouseDownActionOverlay(
                action: action,
                onHover: { hovering in
                    isHovering = hovering
                },
                onPress: { pressing in
                    isOverlayPressed = pressing
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .help(help)
        .accessibilityLabel(Text(help))
    }
}

private struct QuestionNavigationTextButtonStyle: ButtonStyle {
    var primaryColor: Color
    var designMode: IslandDesignMode
    var isHovering: Bool
    var isOverlayPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed || isOverlayPressed
        configuration.label
            .font(.system(size: 18, weight: .light))
            .foregroundStyle(primaryColor.opacity(pressed ? 0.84 : (isHovering ? 0.72 : 0.58)))
            .frame(width: 28, height: 30)
            .background(
                IslandGlassFill(
                    shape: RoundedRectangle(cornerRadius: 8, style: .continuous),
                    mode: designMode,
                    solidOpacity: backgroundOpacity(isPressed: pressed),
                    glassTintOpacity: glassTintOpacity(isPressed: pressed),
                    glassFallbackOpacity: glassFallbackOpacity(isPressed: pressed)
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(strokeOpacity(isPressed: pressed)), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .scaleEffect(pressed ? 0.96 : (isHovering ? 1.025 : 1))
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.10), value: isOverlayPressed)
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private func backgroundOpacity(isPressed: Bool) -> Double {
        guard designMode == .solid else { return glassFallbackOpacity(isPressed: isPressed) }
        if isPressed { return 0.11 }
        if isHovering { return 0.058 }
        return 0
    }

    private func strokeOpacity(isPressed: Bool) -> Double {
        if designMode == .liquidGlass {
            if isPressed { return 0.16 }
            if isHovering { return 0.10 }
            return 0.025
        }
        if isPressed { return 0.15 }
        if isHovering { return 0.07 }
        return 0
    }

    private func glassTintOpacity(isPressed: Bool) -> Double {
        if isPressed { return 0.080 }
        if isHovering { return 0.052 }
        return 0.020
    }

    private func glassFallbackOpacity(isPressed: Bool) -> Double {
        if isPressed { return 0.070 }
        if isHovering { return 0.044 }
        return 0.012
    }
}

private struct LiveTranscriptScrollView: NSViewRepresentable {
    var segments: [TranscriptSegment]
    var showOriginalText: Bool
    var showTranslatedText: Bool
    var questionHighlights: [TranscriptQuestionHighlight]
    var onCopyBlock: (TranscriptSegment, String) -> Void
    var onDeleteSegment: (TranscriptSegment) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> TranscriptScrollView {
        let scrollView = TranscriptScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .allowed
        scrollView.usesPredominantAxisScrolling = true
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = FlippedTranscriptDocumentView()
        let coordinator = context.coordinator
        coordinator.bind(to: scrollView)
        scrollView.onLayout = { [weak scrollView] in
            guard let scrollView else { return }
            coordinator.render(in: scrollView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: TranscriptScrollView, context: Context) {
        context.coordinator.update(
            segments: segments,
            showOriginalText: showOriginalText,
            showTranslatedText: showTranslatedText,
            questionHighlights: questionHighlights,
            onCopyBlock: onCopyBlock,
            onDeleteSegment: onDeleteSegment
        )
        context.coordinator.render(in: scrollView)
        context.coordinator.scheduleRender(in: scrollView)
    }

    static func dismantleNSView(_ scrollView: TranscriptScrollView, coordinator: Coordinator) {
        coordinator.unbind()
    }

    @MainActor
    final class Coordinator {
        private var segments: [TranscriptSegment] = []
        private var showOriginalText = true
        private var showTranslatedText = false
        private var questionHighlights: [TranscriptQuestionHighlight] = []
        private var onCopyBlock: (TranscriptSegment, String) -> Void = { _, _ in }
        private var onDeleteSegment: (TranscriptSegment) -> Void = { _ in }
        private var lastSignature: RenderSignature?
        private var scheduledRender = false
        private var isFollowingLiveEdge = true
        private var isAdjustingScroll = false
        private var boundsObserver: NSObjectProtocol?

        func update(
            segments: [TranscriptSegment],
            showOriginalText: Bool,
            showTranslatedText: Bool,
            questionHighlights: [TranscriptQuestionHighlight],
            onCopyBlock: @escaping (TranscriptSegment, String) -> Void,
            onDeleteSegment: @escaping (TranscriptSegment) -> Void
        ) {
            self.segments = segments
            self.showOriginalText = showOriginalText
            self.showTranslatedText = showTranslatedText
            self.questionHighlights = questionHighlights
            self.onCopyBlock = onCopyBlock
            self.onDeleteSegment = onDeleteSegment
        }

        func bind(to scrollView: NSScrollView) {
            unbind()
            scrollView.contentView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self, weak scrollView] _ in
                guard let self, let scrollView else { return }
                Task { @MainActor in
                    self.handleScrollChanged(in: scrollView)
                }
            }
        }

        func unbind() {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
                self.boundsObserver = nil
            }
        }

        func render(in scrollView: NSScrollView) {
            guard let documentView = scrollView.documentView as? FlippedTranscriptDocumentView else { return }
            let viewportSize = scrollView.contentView.bounds.size
            guard viewportSize.width > 2, viewportSize.height > 2 else {
                scheduleRender(in: scrollView)
                return
            }

            let signature = RenderSignature(
                viewportSize: CGSize(width: round(viewportSize.width), height: round(viewportSize.height)),
                showOriginalText: showOriginalText,
                showTranslatedText: showTranslatedText,
                questionHighlights: questionHighlights,
                fingerprint: fingerprint(for: segments)
            )

            let shouldKeepFollowing = TranscriptLiveScrollPolicy.shouldFollowLiveEdge(
                isFollowingLiveEdge: isFollowingLiveEdge,
                scrollY: scrollView.contentView.bounds.origin.y,
                documentHeight: documentView.bounds.height,
                viewportHeight: scrollView.contentView.bounds.height
            )
            let previousScrollY = scrollView.contentView.bounds.origin.y

            if signature != lastSignature {
                let layout = TranscriptLayout.build(
                    segments: segments,
                    width: max(1, viewportSize.width),
                    minHeight: max(1, viewportSize.height),
                    showOriginalText: showOriginalText,
                    showTranslatedText: showTranslatedText,
                    questionHighlights: questionHighlights
                )
                documentView.replaceRows(
                    layout.rows,
                    documentHeight: layout.documentHeight,
                    width: max(1, viewportSize.width),
                    onCopyBlock: onCopyBlock,
                    onDeleteSegment: onDeleteSegment
                )
                lastSignature = signature
                adjustScrollPosition(in: scrollView, shouldFollowLiveEdge: shouldKeepFollowing, previousScrollY: previousScrollY)
            } else if shouldKeepFollowing {
                scrollToLiveEdge(scrollView)
            }
        }

        func scheduleRender(in scrollView: NSScrollView) {
            guard !scheduledRender else { return }
            scheduledRender = true
            let delays: [UInt64] = [0, 50, 160]
            for delay in delays {
                Task { @MainActor [weak self, weak scrollView] in
                    if delay > 0 {
                        try? await Task.sleep(for: .milliseconds(Int(delay)))
                    }
                    guard let self, let scrollView else { return }
                    self.render(in: scrollView)
                    if delay == delays.last {
                        self.scheduledRender = false
                    }
                }
            }
        }

        private func handleScrollChanged(in scrollView: NSScrollView) {
            guard !isAdjustingScroll else { return }
            isFollowingLiveEdge = isNearLiveEdge(scrollView)
        }

        private func adjustScrollPosition(in scrollView: NSScrollView, shouldFollowLiveEdge: Bool, previousScrollY: CGFloat) {
            if shouldFollowLiveEdge {
                scrollToLiveEdge(scrollView)
                isFollowingLiveEdge = true
            } else {
                scroll(to: previousScrollY, in: scrollView)
                isFollowingLiveEdge = isNearLiveEdge(scrollView)
            }
        }

        private func scrollToLiveEdge(_ scrollView: NSScrollView) {
            guard let documentView = scrollView.documentView else { return }
            let viewportHeight = scrollView.contentView.bounds.height
            let targetY = documentView.bounds.height <= viewportHeight
                ? 0
                : max(0, documentView.bounds.height - viewportHeight)

            scroll(to: targetY, in: scrollView)
        }

        private func scroll(to proposedY: CGFloat, in scrollView: NSScrollView) {
            guard let documentView = scrollView.documentView else { return }
            let targetY = TranscriptLiveScrollPolicy.clampedScrollY(
                proposedY,
                documentHeight: documentView.bounds.height,
                viewportHeight: scrollView.contentView.bounds.height
            )

            isAdjustingScroll = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            isAdjustingScroll = false
        }

        private func isNearLiveEdge(_ scrollView: NSScrollView) -> Bool {
            guard let documentView = scrollView.documentView else { return true }
            return TranscriptLiveScrollPolicy.isNearLiveEdge(
                scrollY: scrollView.contentView.bounds.origin.y,
                documentHeight: documentView.bounds.height,
                viewportHeight: scrollView.contentView.bounds.height
            )
        }

        private func fingerprint(for segments: [TranscriptSegment]) -> Int {
            var hasher = Hasher()
            hasher.combine(segments.count)
            for segment in segments {
                hasher.combine(segment.id)
                hasher.combine(segment.text)
                hasher.combine(segment.draftTranslatedText)
                hasher.combine(segment.translatedText)
                hasher.combine(segment.translationState.rawValue)
                hasher.combine(segment.isFinal)
                hasher.combine(segment.transcriptionPhase?.rawValue)
                hasher.combine(segment.revisionNumber)
                hasher.combine(segment.audioSource.rawValue)
            }
            return hasher.finalize()
        }
    }

    private struct RenderSignature: Equatable {
        var viewportSize: CGSize
        var showOriginalText: Bool
        var showTranslatedText: Bool
        var questionHighlights: [TranscriptQuestionHighlight]
        var fingerprint: Int
    }
}

struct TranscriptLiveScrollPolicy: Sendable, Equatable {
    static let liveEdgeThreshold: CGFloat = 28

    static func maxScrollY(documentHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        max(0, documentHeight - viewportHeight)
    }

    static func clampedScrollY(_ proposedY: CGFloat, documentHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        min(max(0, proposedY), maxScrollY(documentHeight: documentHeight, viewportHeight: viewportHeight))
    }

    static func shouldFollowLiveEdge(
        isFollowingLiveEdge: Bool,
        scrollY: CGFloat,
        documentHeight: CGFloat,
        viewportHeight: CGFloat,
        threshold: CGFloat = liveEdgeThreshold
    ) -> Bool {
        isFollowingLiveEdge || isNearLiveEdge(
            scrollY: scrollY,
            documentHeight: documentHeight,
            viewportHeight: viewportHeight,
            threshold: threshold
        )
    }

    static func isNearLiveEdge(
        scrollY: CGFloat,
        documentHeight: CGFloat,
        viewportHeight: CGFloat,
        threshold: CGFloat = liveEdgeThreshold
    ) -> Bool {
        let distanceToLiveEdge = maxScrollY(documentHeight: documentHeight, viewportHeight: viewportHeight)
            - clampedScrollY(scrollY, documentHeight: documentHeight, viewportHeight: viewportHeight)
        return distanceToLiveEdge <= threshold
    }
}

private final class TranscriptScrollView: NSScrollView {
    var onLayout: (() -> Void)?
    private var lastLayoutSize: CGSize = .zero

    override var acceptsFirstResponder: Bool { false }

    override func becomeFirstResponder() -> Bool {
        false
    }

    override func layout() {
        super.layout()
        let size = contentView.bounds.size
        guard size != lastLayoutSize else { return }
        lastLayoutSize = size
        onLayout?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        Task { @MainActor [weak self] in
            self?.onLayout?()
        }
    }
}

private final class FlippedTranscriptDocumentView: NSView {
    override var isFlipped: Bool { true }
    private var rowViewsByID: [String: TranscriptRowView] = [:]
    private var hoveredRowID: String?
    private var trackingArea: NSTrackingArea?
    private var hoverClearTask: Task<Void, Never>?

    func replaceRows(
        _ rows: [TranscriptLayout.Row],
        documentHeight: CGFloat,
        width: CGFloat,
        onCopyBlock: @escaping (TranscriptSegment, String) -> Void,
        onDeleteSegment: @escaping (TranscriptSegment) -> Void
    ) {
        frame = CGRect(x: 0, y: 0, width: width, height: documentHeight)
        let activeIDs = Set(rows.map(\.id))
        let staleIDs = rowViewsByID.keys.filter { !activeIDs.contains($0) }
        for id in staleIDs {
            rowViewsByID[id]?.removeFromSuperview()
            rowViewsByID[id] = nil
        }

        for row in rows {
            let rowView: TranscriptRowView
            if let existing = rowViewsByID[row.id] {
                rowView = existing
                rowView.update(
                    row: row,
                    onCopyBlock: onCopyBlock,
                    onDeleteSegment: onDeleteSegment,
                    onHoverChanged: { [weak self] rowID in
                        self?.setHoveredRow(rowID)
                    }
                )
            } else {
                rowView = TranscriptRowView(
                    row: row,
                    onCopyBlock: onCopyBlock,
                    onDeleteSegment: onDeleteSegment,
                    onHoverChanged: { [weak self] rowID in
                        self?.setHoveredRow(rowID)
                    }
                )
                rowViewsByID[row.id] = rowView
            }
            if rowView.superview !== self {
                addSubview(rowView)
            }
        }

        updateHoveredRowFromCurrentMouse()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        updateHoveredRow(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateHoveredRow(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) {
            updateHoveredRow(at: point)
        } else {
            clearHoveredRowAfterGracePeriod()
        }
    }

    private func updateHoveredRowFromCurrentMouse() {
        guard let window else {
            setHoveredRow(nil)
            return
        }
        updateHoveredRow(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    private func updateHoveredRow(at point: CGPoint) {
        guard bounds.contains(point) else {
            clearHoveredRowAfterGracePeriod()
            return
        }
        let hovered = rowViewsByID.values
            .filter { !$0.isHidden && $0.alphaValue > 0 }
            .sorted { $0.frame.minY < $1.frame.minY }
            .first { $0.hoverFrameInDocument.contains(point) }
        if let hovered {
            setHoveredRow(hovered.rowID)
        } else {
            clearHoveredRowAfterGracePeriod()
        }
    }

    private func setHoveredRow(_ rowID: String?) {
        hoverClearTask?.cancel()
        hoverClearTask = nil
        guard hoveredRowID != rowID else { return }
        if let hoveredRowID {
            rowViewsByID[hoveredRowID]?.setHovered(false)
        }
        hoveredRowID = rowID
        if let rowID {
            rowViewsByID[rowID]?.setHovered(true)
        }
    }

    private func clearHoveredRowAfterGracePeriod() {
        hoverClearTask?.cancel()
        hoverClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            self?.setHoveredRow(nil)
        }
    }
}

private final class TranscriptRowView: NSView {
    override var isFlipped: Bool { true }

    private enum LayoutMetrics {
        static let actionHitSize: CGFloat = 24
        static let actionGap: CGFloat = 0
        static let actionRightInset: CGFloat = 0
        static let textLeftInset: CGFloat = 4
        static let verticalInset: CGFloat = 1
        static let hoverInset: CGFloat = -12
    }

    private let label = NSTextField(labelWithString: "")
    private let copyButton = TranscriptRowActionButton()
    private let deleteButton = TranscriptRowActionButton()
    private var row: TranscriptLayout.Row
    private var onCopyBlock: (TranscriptSegment, String) -> Void
    private var onDeleteSegment: (TranscriptSegment) -> Void
    private var onHoverChanged: (String?) -> Void
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    var rowID: String { row.id }
    var hoverFrameInDocument: CGRect {
        frame.insetBy(dx: LayoutMetrics.hoverInset, dy: min(-3, LayoutMetrics.hoverInset / 2))
    }

    init(
        row: TranscriptLayout.Row,
        onCopyBlock: @escaping (TranscriptSegment, String) -> Void,
        onDeleteSegment: @escaping (TranscriptSegment) -> Void,
        onHoverChanged: @escaping (String?) -> Void
    ) {
        self.row = row
        self.onCopyBlock = onCopyBlock
        self.onDeleteSegment = onDeleteSegment
        self.onHoverChanged = onHoverChanged
        super.init(frame: row.frame)
        configure()
        apply(row)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    override func layout() {
        super.layout()
        let actionsWidth = LayoutMetrics.actionHitSize * 2 + LayoutMetrics.actionGap + LayoutMetrics.actionRightInset + 2
        let actionY = max(0, floor((bounds.height - LayoutMetrics.actionHitSize) / 2))
        label.frame = CGRect(
            x: LayoutMetrics.textLeftInset,
            y: LayoutMetrics.verticalInset,
            width: max(1, bounds.width - LayoutMetrics.textLeftInset - actionsWidth),
            height: max(1, bounds.height - LayoutMetrics.verticalInset * 2)
        )
        deleteButton.frame = CGRect(
            x: bounds.width - LayoutMetrics.actionRightInset - LayoutMetrics.actionHitSize,
            y: actionY,
            width: LayoutMetrics.actionHitSize,
            height: LayoutMetrics.actionHitSize
        )
        copyButton.frame = CGRect(
            x: deleteButton.frame.minX - LayoutMetrics.actionGap - LayoutMetrics.actionHitSize,
            y: actionY,
            width: LayoutMetrics.actionHitSize,
            height: LayoutMetrics.actionHitSize
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0, bounds.contains(point) else { return nil }
        if let actionButton = actionButtonHit(at: point) {
            onHoverChanged(rowID)
            return actionButton.hitTest(convert(point, to: actionButton)) ?? actionButton
        }
        onHoverChanged(rowID)
        return self
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged(rowID)
        super.mouseEntered(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        onHoverChanged(rowID)
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if bounds.insetBy(dx: LayoutMetrics.hoverInset, dy: LayoutMetrics.hoverInset / 2).contains(point) {
            onHoverChanged(rowID)
        } else {
            onHoverChanged(nil)
        }
        super.mouseExited(with: event)
    }

    private func configure() {
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.masksToBounds = true

        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        addSubview(label)

        configureButton(
            copyButton,
            systemName: "doc.on.doc",
            tooltip: "Copy transcript",
            accessibilityIdentifier: "transcript-inline-copy",
            action: #selector(copyTranscriptBlock)
        )
        configureButton(
            deleteButton,
            systemName: "trash",
            tooltip: "Delete transcript",
            accessibilityIdentifier: "transcript-inline-delete",
            action: #selector(deleteTranscriptSegment)
        )
        addSubview(copyButton)
        addSubview(deleteButton)
        setHovered(false)
    }

    func update(
        row: TranscriptLayout.Row,
        onCopyBlock: @escaping (TranscriptSegment, String) -> Void,
        onDeleteSegment: @escaping (TranscriptSegment) -> Void,
        onHoverChanged: @escaping (String?) -> Void
    ) {
        self.onCopyBlock = onCopyBlock
        self.onDeleteSegment = onDeleteSegment
        self.onHoverChanged = onHoverChanged
        apply(row)
    }

    private func apply(_ row: TranscriptLayout.Row) {
        self.row = row
        frame = row.frame
        label.attributedStringValue = row.text
        needsLayout = true
    }

    private func configureButton(
        _ button: TranscriptRowActionButton,
        systemName: String,
        tooltip: String,
        accessibilityIdentifier: String,
        action: Selector
    ) {
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.target = self
        button.action = action
        button.toolTip = tooltip
        button.setAccessibilityIdentifier(accessibilityIdentifier)
        button.setAccessibilityLabel(tooltip)
        button.setAccessibilityHelp(tooltip)
        button.wantsLayer = true
        button.layer?.cornerRadius = 4
        button.layer?.backgroundColor = NSColor.clear.cgColor
        button.onPointerHoverChanged = { [weak self] hovering in
            guard let self else { return }
            if hovering {
                self.onHoverChanged(self.rowID)
            }
        }
        if let image = NSImage(systemSymbolName: systemName, accessibilityDescription: tooltip) {
            button.image = image.withSymbolConfiguration(.init(pointSize: 5.8, weight: .regular))
        }
        button.isEnabled = true
        button.updateAppearance(rowHovered: false)
    }

    func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        layer?.backgroundColor = NSColor.white.withAlphaComponent(hovered ? 0.088 : 0).cgColor
        copyButton.updateAppearance(rowHovered: hovered)
        deleteButton.updateAppearance(rowHovered: hovered)
    }

    private func actionButtonHit(at point: NSPoint) -> NSButton? {
        if copyButton.frame.contains(point) { return copyButton }
        if deleteButton.frame.contains(point) { return deleteButton }
        return nil
    }

    @objc private func copyTranscriptBlock() {
        onCopyBlock(row.segment, row.copyText)
    }

    @objc private func deleteTranscriptSegment() {
        onDeleteSegment(row.segment)
    }
}

private final class TranscriptRowActionButton: NSButton {
    var onPointerHoverChanged: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?
    private var isPointerInside = false
    private var rowHovered = false

    override var acceptsFirstResponder: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        updateAppearance(rowHovered: rowHovered)
        onPointerHoverChanged?(true)
        super.mouseEntered(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        if !isPointerInside {
            isPointerInside = true
            updateAppearance(rowHovered: rowHovered)
        }
        onPointerHoverChanged?(true)
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        updateAppearance(rowHovered: rowHovered)
        onPointerHoverChanged?(false)
        super.mouseExited(with: event)
    }

    func updateAppearance(rowHovered: Bool) {
        self.rowHovered = rowHovered
        alphaValue = rowHovered ? 0.78 : 0.08
        contentTintColor = NSColor.white.withAlphaComponent(isPointerInside ? 0.84 : (rowHovered ? 0.58 : 0.30))
        let backgroundAlpha: CGFloat
        if isPointerInside {
            backgroundAlpha = 0.065
        } else if rowHovered {
            backgroundAlpha = 0.010
        } else {
            backgroundAlpha = 0
        }
        layer?.backgroundColor = NSColor.white.withAlphaComponent(backgroundAlpha).cgColor
    }
}

struct TranscriptReadableChunker: Sendable, Equatable {
    static let defaultTargetLength = 86
    static let defaultMaxLength = 118

    static func chunks(
        for text: String,
        targetLength: Int = defaultTargetLength,
        maxLength: Int = defaultMaxLength
    ) -> [String] {
        let normalized = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        guard normalized.count > maxLength else { return [normalized] }

        var chunks: [String] = []
        var current: [String] = []
        var currentLength = 0

        for word in normalized.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
            let proposedLength = currentLength + word.count + (current.isEmpty ? 0 : 1)
            if !current.isEmpty, proposedLength > maxLength {
                flush(&current, currentLength: &currentLength, into: &chunks)
            }

            current.append(word)
            currentLength += word.count + (current.count == 1 ? 0 : 1)

            if currentLength >= targetLength, isReadableBoundary(word) {
                flush(&current, currentLength: &currentLength, into: &chunks)
            }
        }

        flush(&current, currentLength: &currentLength, into: &chunks)
        return chunks
    }

    static func pairedChunks(original: String, translation: String) -> [(original: String?, translation: String?)] {
        let originalChunks = chunks(for: original)
        let translationChunks = chunks(for: translation)
        let count = max(originalChunks.count, translationChunks.count)
        guard count > 0 else { return [] }

        return (0..<count).map { index in
            (
                original: index < originalChunks.count ? originalChunks[index] : nil,
                translation: index < translationChunks.count ? translationChunks[index] : nil
            )
        }
    }

    private static func flush(_ words: inout [String], currentLength: inout Int, into chunks: inout [String]) {
        let chunk = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if !chunk.isEmpty {
            chunks.append(chunk)
        }
        words.removeAll(keepingCapacity: true)
        currentLength = 0
    }

    private static func isReadableBoundary(_ word: String) -> Bool {
        guard let last = word.unicodeScalars.last else { return false }
        if CharacterSet(charactersIn: ".!?;:,").contains(last) {
            return true
        }

        return [
            "and", "but", "because", "then", "now", "so",
            "e", "mas", "porque", "entao", "então", "agora"
        ].contains(word.lowercased())
    }
}

private enum TranscriptLayout {
    private struct Block {
        var id: String
        var segment: TranscriptSegment
        var text: NSAttributedString
        var copyText: String
        var spacingAfter: CGFloat
    }

    struct Row {
        var id: String
        var segment: TranscriptSegment
        var text: NSAttributedString
        var copyText: String
        var frame: CGRect
    }

    static func build(
        segments: [TranscriptSegment],
        width: CGFloat,
        minHeight: CGFloat,
        showOriginalText: Bool,
        showTranslatedText: Bool,
        questionHighlights: [TranscriptQuestionHighlight] = []
    ) -> (rows: [Row], documentHeight: CGFloat) {
        let rowWidth = max(1, min(width - 24, showTranslatedText ? 492 : 520))
        let rowHorizontalInset: CGFloat = 5
        let rowVerticalInset: CGFloat = 2
        let minInteractiveRowHeight: CGFloat = 24
        let actionReserve: CGFloat = 50
        let measuredTextWidth = max(1, rowWidth - actionReserve)
        let rowX = max(0, (width - rowWidth) / 2)
        let verticalPadding: CGFloat = 0
        let blocks = segments.flatMap {
            attributedBlocks(
                for: $0,
                showOriginalText: showOriginalText,
                showTranslatedText: showTranslatedText,
                questionHighlights: questionHighlights
            )
        }
        let heights = blocks.map { block -> CGFloat in
            let rect = block.text.boundingRect(
                with: CGSize(width: measuredTextWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            return max(minInteractiveRowHeight, ceil(rect.height) + rowVerticalInset * 2)
        }
        let contentHeight = zip(heights, blocks).reduce(CGFloat.zero) { partial, pair in
            partial + pair.0 + pair.1.spacingAfter
        } - (blocks.last?.spacingAfter ?? 0)
        let documentHeight = max(minHeight, contentHeight + verticalPadding * 2)
        var y = verticalPadding

        let rows = zip(blocks, heights).map { block, height -> Row in
            defer { y += height + block.spacingAfter }
            return Row(
                id: block.id,
                segment: block.segment,
                text: block.text,
                copyText: block.copyText,
                frame: CGRect(
                    x: max(0, rowX - rowHorizontalInset),
                    y: y,
                    width: min(width, rowWidth + rowHorizontalInset * 2),
                    height: height
                )
            )
        }

        return (rows, documentHeight)
    }

    private static func attributedBlocks(
        for segment: TranscriptSegment,
        showOriginalText: Bool,
        showTranslatedText: Bool,
        questionHighlights: [TranscriptQuestionHighlight]
    ) -> [Block] {
        if showTranslatedText, let translationLine = translationLine(for: segment) {
            if showOriginalText {
                let pairs = TranscriptReadableChunker.pairedChunks(
                    original: segment.text,
                    translation: translationLine.text
                )
                return pairs.enumerated().map { index, pair in
                    Block(
                        id: rowID(for: segment, kind: "paired", index: index),
                        segment: segment,
                        text: attributedText(
                            for: segment,
                            originalText: pair.original,
                            translatedText: pair.translation,
                            translationOnly: false,
                            questionHighlights: questionHighlights
                        ),
                        copyText: copyText(originalText: pair.original, translatedText: pair.translation),
                        spacingAfter: index == pairs.count - 1 ? 8 : 4
                    )
                }
            }

            let chunks = TranscriptReadableChunker.chunks(for: translationLine.text)
            return chunks.enumerated().map { index, chunk in
                Block(
                    id: rowID(for: segment, kind: "translation", index: index),
                    segment: segment,
                    text: attributedText(
                        for: segment,
                        originalText: nil,
                        translatedText: chunk,
                        translationOnly: true,
                        questionHighlights: questionHighlights
                    ),
                    copyText: chunk,
                    spacingAfter: index == chunks.count - 1 ? 8 : 4
                )
            }
        }

        let chunks = TranscriptReadableChunker.chunks(for: segment.text)
        return chunks.enumerated().map { index, chunk in
            Block(
                id: rowID(for: segment, kind: "original", index: index),
                segment: segment,
                text: attributedText(
                    for: segment,
                    originalText: chunk,
                    translatedText: nil,
                    translationOnly: false,
                    questionHighlights: questionHighlights
                ),
                copyText: chunk,
                spacingAfter: index == chunks.count - 1 ? 7 : 4
            )
        }
    }

    private static func rowID(for segment: TranscriptSegment, kind: String, index: Int) -> String {
        "\(segment.id.uuidString):\(kind):\(index)"
    }

    private static func copyText(originalText: String?, translatedText: String?) -> String {
        [translatedText, originalText]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func attributedText(
        for segment: TranscriptSegment,
        originalText: String?,
        translatedText: String?,
        translationOnly: Bool,
        questionHighlights: [TranscriptQuestionHighlight]
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let transcriptionColor = transcriptTextColor(for: segment)
        let translatedColor = NSColor.white.withAlphaComponent(0.96)
        let originalSecondaryColor = NSColor.white.withAlphaComponent(0.46)
        let primaryParagraph = NSMutableParagraphStyle()
        primaryParagraph.lineSpacing = 1.5
        primaryParagraph.paragraphSpacing = translatedText == nil ? 0.3 : 1.6
        let secondaryParagraph = NSMutableParagraphStyle()
        secondaryParagraph.lineSpacing = 1.2
        secondaryParagraph.paragraphSpacing = 0.3

        if let translatedText {
            let translatedStart = result.length
            result.append(NSAttributedString(
                string: translatedText,
                attributes: [
                    .font: NSFont.systemFont(ofSize: translationOnly ? 13.4 : 13.1, weight: .light),
                    .foregroundColor: translatedColor,
                    .paragraphStyle: primaryParagraph
                ]
            ))
            TranscriptQuestionHighlighter.apply(
                to: result,
                visibleText: translatedText,
                visibleRange: NSRange(location: translatedStart, length: (translatedText as NSString).length),
                segmentId: segment.id,
                highlights: translationOnly ? questionHighlights : []
            )
            if let originalText {
                result.append(NSAttributedString(string: "\n"))
                let originalStart = result.length
                result.append(NSAttributedString(
                    string: originalText,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 11.8, weight: .light),
                        .foregroundColor: originalSecondaryColor,
                        .paragraphStyle: secondaryParagraph
                    ]
                ))
                TranscriptQuestionHighlighter.apply(
                    to: result,
                    visibleText: originalText,
                    visibleRange: NSRange(location: originalStart, length: (originalText as NSString).length),
                    segmentId: segment.id,
                    highlights: questionHighlights
                )
            }
        } else if let originalText {
            let originalStart = result.length
            result.append(NSAttributedString(
                string: originalText,
                attributes: [
                    .font: NSFont.systemFont(ofSize: segment.audioSource.isUserSide ? 13.1 : 13.4, weight: .light),
                    .foregroundColor: transcriptionColor,
                    .paragraphStyle: primaryParagraph
                ]
            ))
            TranscriptQuestionHighlighter.apply(
                to: result,
                visibleText: originalText,
                visibleRange: NSRange(location: originalStart, length: (originalText as NSString).length),
                segmentId: segment.id,
                highlights: questionHighlights
            )
        }

        return result
    }

    private static func transcriptTextColor(for segment: TranscriptSegment) -> NSColor {
        NSColor.white.withAlphaComponent(0.96)
    }

    private struct TranslationDisplayLine {
        var text: String
    }

    private static func translationLine(for segment: TranscriptSegment) -> TranslationDisplayLine? {
        if let translated = translatedDisplayText(for: segment) {
            return TranslationDisplayLine(text: translated)
        }

        switch segment.translationState {
        case .drafting:
            return nil
        case .pending, .refining:
            return TranslationDisplayLine(text: "Translating...")
        case .unavailable:
            return TranslationDisplayLine(text: "Translation unavailable locally")
        case .failed:
            return TranslationDisplayLine(text: "Translation failed")
        case .none, .draftTranslated, .translated, .preserved:
            return nil
        }
    }

    private static func translatedDisplayText(for segment: TranscriptSegment) -> String? {
        if let translated = segment.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !translated.isEmpty {
            return translated
        }
        if let draft = segment.draftTranslatedText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !draft.isEmpty {
            return draft
        }
        return nil
    }
}
