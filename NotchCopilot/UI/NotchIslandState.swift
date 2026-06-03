import CoreGraphics
import Foundation

enum NotchIslandChromeMetrics {
    static let collapsedNotchFootprintSize = CGSize(width: 188, height: 40)
    static let detectedMeetingSize = CGSize(width: collapsedNotchFootprintSize.width, height: 78)
    static let compactListeningSize = CGSize(width: 512, height: 44)
    static let ambientCopilotDropdownSize = detectedMeetingSize
    static var ambientCopilotListeningSize: CGSize { ambientCopilotDropdownSize }
    static var ambientCopilotProcessingSize: CGSize { ambientCopilotDropdownSize }

    static var ambientCopilotLoadingSize: CGSize { ambientCopilotProcessingSize }
    static let expandedTopPadding: CGFloat = 2
    static let expandedHeaderHeight: CGFloat = 34
    static let expandedHeaderContentSpacing: CGFloat = 12
    static let expandedBodyChromeHeight: CGFloat = expandedTopPadding + expandedHeaderHeight + expandedHeaderContentSpacing
    static let compactListeningNotchKeepoutWidth: CGFloat = 176
    static let compactListeningHorizontalPadding: CGFloat = 14
    static let compactRecordButtonHorizontalInset: CGFloat = 6
    static let compactRecordButtonBottomInset: CGFloat = compactRecordButtonHorizontalInset
    static let compactRecordButtonHeight: CGFloat = 36
    static let compactRecordButtonCornerRadius: CGFloat = 12
    static let compactRecordLogoSize = CGSize(width: 42, height: 21)
    static let compactRecordPlatformIconSize = CGSize(width: 21, height: 21)
    static let compactRecordHoverActionHitDiameter: CGFloat = 32
    static let compactRecordHoverActionSpacing: CGFloat = 2
    static let compactRecordHoverActionTrailingGap: CGFloat = 8
    static let compactRecordHoverActionsButtonWidth = compactRecordHoverActionHitDiameter * 2 +
        compactRecordHoverActionSpacing
    static let compactRecordHoverActionsWidth = compactRecordHoverActionsButtonWidth +
        compactRecordHoverActionTrailingGap
    static let compactRecordHoverActionsSize = CGSize(
        width: detectedMeetingSize.width + compactRecordHoverActionsWidth,
        height: detectedMeetingSize.height
    )
}

enum NotchIslandVisualEnvelope {
    static let horizontalShadowOutset: CGFloat = 24
    static let bottomShadowOutset: CGFloat = 22
    static let chromeSettleDelayMs = 340

    static func windowCanvasSize(for canvasSize: CGSize) -> CGSize {
        CGSize(
            width: ceil(canvasSize.width + horizontalShadowOutset * 2),
            height: ceil(canvasSize.height + bottomShadowOutset)
        )
    }
}

enum NotchIslandMode: String, Codable, CaseIterable, Identifiable {
    case idle
    case meetingDetected
    case listening
    case questionDetected
    case thinking
    case summarizing
    case suggestedAnswer
    case summaryReady

    var id: String { rawValue }

    var preferredSize: CGSize {
        switch self {
        case .idle:
            CGSize(width: 184, height: 38)
        case .meetingDetected:
            NotchIslandChromeMetrics.detectedMeetingSize
        case .listening:
            NotchIslandChromeMetrics.compactListeningSize
        case .questionDetected:
            CGSize(width: 486, height: 100)
        case .thinking:
            CGSize(width: 430, height: 62)
        case .summarizing:
            CGSize(width: 456, height: 60)
        case .suggestedAnswer:
            CGSize(width: 570, height: 230)
        case .summaryReady:
            CGSize(width: 456, height: 64)
        }
    }

    static let chromeCornerRadius: CGFloat = 18

    var cornerRadius: CGFloat {
        Self.chromeCornerRadius
    }
}

enum QuestionAnswerPresentationMode: String, Codable, CaseIterable, Identifiable {
    case answer
    case transcript

    var id: String { rawValue }

    var title: String {
        switch self {
        case .answer: "Notchly"
        case .transcript: "Transcrição"
        }
    }

}
