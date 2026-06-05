import SwiftUI

struct TranscriptLiveView: View {
    var segments: [TranscriptSegment]
    var limit = 18
    var isProtected = false
    var onCopySegment: ((TranscriptSegment) -> Void)?
    var onDeleteSegment: ((TranscriptSegment) -> Void)?

    @State private var hoveredSegmentID: UUID?
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
        let isHovered = hoveredSegmentID == segment.id
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
                .fill(Color.white.opacity(isHovered ? 0.088 : 0))
        )
        .overlay(alignment: .topTrailing) {
            if hasInlineActions {
                TranscriptInlineActions(
                    isVisible: isHovered,
                    onCopy: { onCopySegment?(segment) },
                    onDelete: { onDeleteSegment?(segment) },
                    onHoverChanged: { hovering in
                        updateHoveredSegment(hovering ? segment.id : nil)
                    }
                )
                .padding(.top, 1)
                .padding(.trailing, 0)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { hovering in
            updateHoveredSegment(hovering ? segment.id : nil)
        }
        .onDisappear {
            if hoveredSegmentID == segment.id {
                updateHoveredSegment(nil)
            }
        }
        .animation(nil, value: isHovered)
    }

    private func updateHoveredSegment(_ segmentID: UUID?) {
        hoverClearTask?.cancel()
        hoverClearTask = nil
        if let segmentID {
            hoveredSegmentID = segmentID
        } else if let current = hoveredSegmentID {
            hoverClearTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled, hoveredSegmentID == current else { return }
                hoveredSegmentID = nil
            }
        }
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
    static let buttonHitSize: CGFloat = 23
    static let visibleButtonSize: CGFloat = 11
    static let visibleButtonCornerRadius: CGFloat = 4
    static let hitTargetCornerRadius: CGFloat = 5
    static let rowTrailingReserve: CGFloat = buttonHitSize * 2 + 4
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
        .opacity(isVisible ? 0.76 : 0.001)
        .allowsHitTesting(true)
        .animation(nil, value: isVisible)
        .contentShape(Rectangle())
        .onHover(perform: onHoverChanged)
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
                    .fill(Color.white.opacity(isHovered ? 0.065 : 0.010))
                    .frame(width: TranscriptInlineActionMetrics.visibleButtonSize, height: TranscriptInlineActionMetrics.visibleButtonSize)
                Image(systemName: systemName)
                    .font(.system(size: 5.1, weight: .regular))
                    .foregroundStyle(Color.white.opacity(isHovered ? 0.82 : 0.56))
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
