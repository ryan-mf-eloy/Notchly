import SwiftUI

struct TranscriptLiveView: View {
    var segments: [TranscriptSegment]
    var limit = 18
    var isProtected = false
    var onCopySegment: ((TranscriptSegment) -> Void)?
    var onDeleteSegment: ((TranscriptSegment) -> Void)?

    @State private var hoverState = TranscriptInlineHoverState()
    @State private var hoverClearTask: Task<Void, Never>?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(segments.suffix(limit).enumerated()), id: \.element.id) { _, segment in
                        segmentRow(segment)
                            .id(segment.id)
                    }

                    if segments.isEmpty {
                        Text("No transcript captured yet.")
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(MinimalTheme.historyMuted)
                            .padding(18)
                    }
                }
                .padding(10)
            }
            .scrollContentBackground(.hidden)
            .onChange(of: segments.count) {
                if let last = segments.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
        .background(Color.clear)
        .foregroundStyle(MinimalTheme.historyInk)
        .protectedContentRegion(isProtected)
    }

    private func segmentRow(_ segment: TranscriptSegment) -> some View {
        let isHovered = hoverState.hoveredSegmentID == segment.id
        let hasInlineActions = onCopySegment != nil || onDeleteSegment != nil
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(DateFormatting.duration(segment.startTime))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(MinimalTheme.historyFaint)
                if let language = segment.originalLanguage {
                    Text(language)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(MinimalTheme.historyFaint)
                }
                Rectangle()
                    .fill(MinimalTheme.historyBorder)
                    .frame(height: 0.6)
            }

            if let translatedText = translatedDisplayText(for: segment) {
                Text(translatedText)
                    .font(.system(size: segment.audioSource.isUserSide ? 12.8 : 13.1, weight: .regular))
                    .foregroundStyle(MinimalTheme.historyText.opacity(0.96))
                    .multilineTextAlignment(.leading)
                    .lineSpacing(1.4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)

                Text(segment.text)
                    .font(.system(size: 11.6, weight: .regular))
                    .foregroundStyle(MinimalTheme.historyMuted.opacity(0.72))
                    .multilineTextAlignment(.leading)
                    .lineSpacing(1.2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            } else {
                Text(segment.text)
                    .font(.system(size: segment.audioSource.isUserSide ? 12.8 : 13.1, weight: .regular))
                    .foregroundStyle(transcriptColor(for: segment))
                    .multilineTextAlignment(.leading)
                    .lineSpacing(1.4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
        .padding(.leading, 4)
        .padding(.trailing, hasInlineActions ? TranscriptInlineActionMetrics.rowTrailingReserve : 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(isHovered ? TranscriptInlineActionMetrics.rowHoverAlpha : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.white.opacity(isHovered ? TranscriptInlineActionMetrics.rowHoverBorderAlpha : 0), lineWidth: 0.5)
        )
        .overlay(alignment: .topTrailing) {
            if hasInlineActions {
                TranscriptInlineActions(
                    isVisible: isHovered,
                    onCopy: { onCopySegment?(segment) },
                    onDelete: { onDeleteSegment?(segment) },
                    onHoverChanged: { hovering in
                        updateHoveredSegment(segment.id, zone: .actions, isInside: hovering)
                    }
                )
                .padding(.top, 0)
                .padding(.trailing, 0)
                .zIndex(1)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { hovering in
            updateHoveredSegment(segment.id, zone: .row, isInside: hovering)
        }
        .onDisappear {
            removeHoveredSegment(segment.id)
        }
        .animation(nil, value: isHovered)
    }

    private func updateHoveredSegment(_ segmentID: UUID, zone: TranscriptInlineHoverZone, isInside: Bool) {
        hoverClearTask?.cancel()
        hoverClearTask = nil
        let shouldClearAfterDelay = hoverState.update(segmentID: segmentID, zone: zone, isInside: isInside)
        if shouldClearAfterDelay {
            hoverClearTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(TranscriptInlineActionMetrics.hoverClearDelayMilliseconds))
                guard !Task.isCancelled else { return }
                hoverState.clearIfIdle(segmentID)
            }
        }
    }

    private func removeHoveredSegment(_ segmentID: UUID) {
        hoverClearTask?.cancel()
        hoverClearTask = nil
        hoverState.removeSegment(segmentID)
    }

    private func transcriptColor(for segment: TranscriptSegment) -> Color {
        MinimalTheme.historyText.opacity(segment.audioSource.isUserSide ? 0.90 : 0.98)
    }

    private func translatedDisplayText(for segment: TranscriptSegment) -> String? {
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

enum TranscriptInlineActionMetrics {
    static let buttonHitSize: CGFloat = 24
    static let visibleButtonSize: CGFloat = 10
    static let glyphPointSize: CGFloat = 6.6
    static let visibleButtonCornerRadius: CGFloat = 3.0
    static let hitTargetCornerRadius: CGFloat = 5
    static let rowTrailingReserve: CGFloat = buttonHitSize * 2 + 2
    static let actionsHoverSlop: CGFloat = 8
    static let rowHoverAlpha: Double = 0.155
    static let rowHoverBorderAlpha: Double = 0.065
    static let idleActionsAlpha: Double = 0.26
    static let visibleActionsAlpha: Double = 0.98
    static let hoverClearDelayMilliseconds = 520
}

enum TranscriptInlineHoverZone: Hashable {
    case row
    case actions
}

struct TranscriptInlineHoverState: Equatable {
    private(set) var hoveredSegmentID: UUID?
    private var activeZonesBySegmentID: [UUID: Set<TranscriptInlineHoverZone>] = [:]

    mutating func update(segmentID: UUID, zone: TranscriptInlineHoverZone, isInside: Bool) -> Bool {
        if isInside {
            var zones = activeZonesBySegmentID[segmentID, default: []]
            zones.insert(zone)
            activeZonesBySegmentID[segmentID] = zones
            hoveredSegmentID = segmentID
            return false
        }

        var zones = activeZonesBySegmentID[segmentID] ?? []
        zones.remove(zone)
        activeZonesBySegmentID[segmentID] = zones.isEmpty ? nil : zones
        return hoveredSegmentID == segmentID && zones.isEmpty
    }

    mutating func clearIfIdle(_ segmentID: UUID) {
        guard activeZonesBySegmentID[segmentID]?.isEmpty ?? true else { return }
        activeZonesBySegmentID[segmentID] = nil
        if hoveredSegmentID == segmentID {
            hoveredSegmentID = nil
        }
    }

    mutating func removeSegment(_ segmentID: UUID) {
        activeZonesBySegmentID[segmentID] = nil
        if hoveredSegmentID == segmentID {
            hoveredSegmentID = nil
        }
    }
}

private struct TranscriptInlineActions: View {
    var isVisible: Bool
    var onCopy: () -> Void
    var onDelete: () -> Void
    var onHoverChanged: (Bool) -> Void

    var body: some View {
        HStack(spacing: 0) {
            TranscriptInlineActionButton(
                systemName: "doc.on.doc",
                accessibilityLabel: "Copy transcript",
                accessibilityIdentifier: "transcript-inline-copy",
                action: onCopy
            )
            TranscriptInlineActionButton(
                systemName: "trash",
                accessibilityLabel: "Delete transcript",
                accessibilityIdentifier: "transcript-inline-delete",
                action: onDelete
            )
        }
        .frame(
            width: TranscriptInlineActionMetrics.rowTrailingReserve + TranscriptInlineActionMetrics.actionsHoverSlop,
            height: TranscriptInlineActionMetrics.buttonHitSize + TranscriptInlineActionMetrics.actionsHoverSlop * 2,
            alignment: .topTrailing
        )
        .opacity(isVisible ? TranscriptInlineActionMetrics.visibleActionsAlpha : TranscriptInlineActionMetrics.idleActionsAlpha)
        .allowsHitTesting(true)
        .animation(nil, value: isVisible)
        .contentShape(Rectangle())
        .onHover { hovering in
            onHoverChanged(hovering)
        }
    }
}

private struct TranscriptInlineActionButton: View {
    var systemName: String
    var accessibilityLabel: String
    var accessibilityIdentifier: String
    var action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: TranscriptInlineActionMetrics.visibleButtonCornerRadius, style: .continuous)
                    .fill(Color.white.opacity(isHovered ? 0.13 : 0.035))
                    .frame(width: TranscriptInlineActionMetrics.visibleButtonSize, height: TranscriptInlineActionMetrics.visibleButtonSize)
                Image(systemName: systemName)
                    .font(.system(size: TranscriptInlineActionMetrics.glyphPointSize, weight: .regular))
                    .foregroundStyle(Color.white.opacity(isHovered ? 0.90 : 0.62))
            }
            .frame(width: TranscriptInlineActionMetrics.buttonHitSize, height: TranscriptInlineActionMetrics.buttonHitSize)
            .background(
                RoundedRectangle(cornerRadius: TranscriptInlineActionMetrics.hitTargetCornerRadius, style: .continuous)
                    .fill(Color.clear)
            )
        }
        .buttonStyle(.plain)
        .contentShape(
            RoundedRectangle(cornerRadius: TranscriptInlineActionMetrics.hitTargetCornerRadius, style: .continuous)
        )
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
        .onHover { isHovered = $0 }
    }
}
