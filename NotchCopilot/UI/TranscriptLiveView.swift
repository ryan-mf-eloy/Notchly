import SwiftUI

struct TranscriptLiveView: View {
    var segments: [TranscriptSegment]
    var limit = 18
    var isProtected = false
    var onCopySegment: ((TranscriptSegment) -> Void)?
    var onDeleteSegment: ((TranscriptSegment) -> Void)?

    @State private var hoveredSegmentID: UUID?

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
                .padding(14)
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
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
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
                    .font(.system(size: segment.audioSource.isUserSide ? 13.6 : 14.4, weight: .regular))
                    .foregroundStyle(MinimalTheme.historyText.opacity(0.96))
                    .multilineTextAlignment(.leading)
                    .lineSpacing(2.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)

                Text(segment.text)
                    .font(.system(size: 12.2, weight: .regular))
                    .foregroundStyle(MinimalTheme.historyMuted.opacity(0.72))
                    .multilineTextAlignment(.leading)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            } else {
                Text(segment.text)
                    .font(.system(size: segment.audioSource.isUserSide ? 13.6 : 14.4, weight: .regular))
                    .foregroundStyle(transcriptColor(for: segment))
                    .multilineTextAlignment(.leading)
                    .lineSpacing(2.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(isHovered ? 0.055 : 0))
        )
        .overlay(alignment: .topTrailing) {
            if onCopySegment != nil || onDeleteSegment != nil {
                TranscriptInlineActions(
                    isVisible: isHovered,
                    onCopy: { onCopySegment?(segment) },
                    onDelete: { onDeleteSegment?(segment) }
                )
                .padding(.top, 5)
                .padding(.trailing, 5)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { hovering in
            hoveredSegmentID = hovering ? segment.id : (hoveredSegmentID == segment.id ? nil : hoveredSegmentID)
        }
        .animation(.easeOut(duration: 0.12), value: isHovered)
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

private struct TranscriptInlineActions: View {
    var isVisible: Bool
    var onCopy: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            TranscriptInlineActionButton(systemName: "doc.on.doc", accessibilityLabel: "Copy transcript", action: onCopy)
            TranscriptInlineActionButton(systemName: "trash", accessibilityLabel: "Delete transcript", action: onDelete)
        }
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .animation(.easeOut(duration: 0.08), value: isVisible)
    }
}

private struct TranscriptInlineActionButton: View {
    var systemName: String
    var accessibilityLabel: String
    var action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.white.opacity(isHovered ? 0.84 : 0.60))
                .frame(width: 17, height: 17)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(isHovered ? 0.095 : 0.038))
                )
        }
        .buttonStyle(.plain)
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
        .onHover { isHovered = $0 }
    }
}
