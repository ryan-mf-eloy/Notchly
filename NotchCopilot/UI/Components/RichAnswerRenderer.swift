import AppKit
import SwiftUI

enum RichAnswerLeadStyle: Equatable {
    case card
    case plain
}

struct RichAnswerRenderer: View {
    var text: String
    var richAnswer: RichAnswerPayload?
    var format: CopilotAnswerFormat?
    var sources: [AnswerSource]
    var confidence: Double?
    var riskLevel: AnswerRiskLevel?
    var tone: AnswerStyle?
    var caveats: [String] = []
    var allowRemoteLinkPreview: Bool
    var density: DynamicAnswerContentView.Density = .qa
    var leadStyle: RichAnswerLeadStyle = .card
    var showsMetadataBadges = false
    var showsEvidenceBlocks = true
    var onCopy: (() -> Void)?
    var onOpenSources: (() -> Void)?
    var onRegenerateWithWeb: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var payload: RichAnswerPayload {
        RichAnswerValidator().validated(richAnswer, sources: sources) ??
            RichAnswerFallbackBuilder.payload(
                text: text,
                format: format,
                sources: sources,
                confidence: confidence,
                riskLevel: riskLevel,
                tone: tone,
                caveats: caveats,
                includeEvidence: showsEvidenceBlocks
            )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(payload.blocks.enumerated()), id: \.offset) { index, block in
                blockView(block)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.14).delay(Double(index) * 0.015), value: payload.blocks)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: RichAnswerBlockPayload) -> some View {
        switch RichAnswerBlockKind(rawValue: block.type) {
        case .lead:
            AnswerLeadCard(
                block: block,
                confidence: confidence,
                riskLevel: riskLevel,
                tone: tone,
                style: leadStyle,
                showsMetadataBadges: showsMetadataBadges
            )
        case .paragraph:
            DynamicAnswerContentView(text: block.text ?? "", density: density, alignment: .leading)
        case .sourceCards:
            SourceRail(sources: selectedSources(block.sourceIndexes), allowRemoteLinkPreview: allowRemoteLinkPreview)
        case .steps:
            StepsView(title: block.title, items: block.items, numbered: true)
        case .checklist:
            ChecklistView(title: block.title, items: block.items)
        case .comparison:
            ComparisonMatrixView(title: block.title, items: block.items)
        case .metrics:
            MetricResultView(block: block)
        case .code:
            RichCodeBlockView(language: block.language, code: block.code ?? "")
        case .timeline:
            StepsView(title: block.title, items: block.items, numbered: false)
        case .memoryResults:
            if showsEvidenceBlocks {
                MeetingEvidenceView(title: block.title ?? "Evidence", items: block.items, sources: sources)
            } else {
                EmptyView()
            }
        case .clarification:
            ClarificationCard(block: block, actions: block.actions, onCopy: onCopy, onOpenSources: onOpenSources, onRegenerateWithWeb: onRegenerateWithWeb)
        case .warning:
            WarningBlockView(block: block)
        case .actions:
            RichActionStrip(actions: block.actions, onCopy: onCopy, onOpenSources: onOpenSources, onRegenerateWithWeb: onRegenerateWithWeb)
        case .none:
            EmptyView()
        }
    }

    private func selectedSources(_ indexes: [Int]) -> [AnswerSource] {
        indexes.compactMap { sources.indices.contains($0) ? sources[$0] : nil }
    }
}

private struct AnswerLeadCard: View {
    var block: RichAnswerBlockPayload
    var confidence: Double?
    var riskLevel: AnswerRiskLevel?
    var tone: AnswerStyle?
    var style: RichAnswerLeadStyle
    var showsMetadataBadges: Bool
    @Environment(\.islandDesignMode) private var islandDesignMode

    private var chips: [String] {
        guard showsMetadataBadges else { return [] }
        return [
            riskLevel.map { $0.rawValue.replacingOccurrences(of: "_", with: " ") },
            tone.map { $0.rawValue.replacingOccurrences(of: "_", with: " ") },
            confidence.map { "\(Int(($0 * 100).rounded()))%" }
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmptyRichAnswer }
    }

    var body: some View {
        content
            .modifier(AnswerLeadChrome(style: style, islandDesignMode: islandDesignMode))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: style == .plain ? 0 : 9) {
            if style == .card, let title = block.title {
                leadTitle(title)
            }

            leadText

            if !chips.isEmpty {
                metadataBadges
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func leadTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.46))
            .lineLimit(1)
    }

    private var leadText: some View {
        Text(block.text ?? "")
            .font(.system(size: style == .plain ? 15.8 : 16.2, weight: style == .plain ? .regular : .medium))
            .foregroundStyle(Color.white.opacity(style == .plain ? 0.76 : 0.88))
            .lineSpacing(style == .plain ? 5.0 : 4.4)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var metadataBadges: some View {
        HStack(spacing: 6) {
            ForEach(chips.prefix(3), id: \.self) { chip in
                Text(chip.uppercased())
                    .font(.system(size: 8.6, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.44))
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .frame(height: 18)
                    .background(Capsule(style: .continuous).fill(Color.white.opacity(0.045)))
                    .overlay(Capsule(style: .continuous).stroke(Color.white.opacity(0.055), lineWidth: 0.5))
            }
        }
    }
}

private struct AnswerLeadChrome: ViewModifier {
    var style: RichAnswerLeadStyle
    var islandDesignMode: IslandDesignMode

    @ViewBuilder
    func body(content: Content) -> some View {
        if style == .plain {
            content
        } else {
            content
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(
                    IslandGlassFill(
                        shape: RoundedRectangle(cornerRadius: 8, style: .continuous),
                        mode: islandDesignMode,
                        solidOpacity: 0.040,
                        glassTintOpacity: 0.058,
                        glassFallbackOpacity: 0.036
                    )
                )
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.070), lineWidth: 0.6))
        }
    }
}

private struct SourceRail: View {
    var sources: [AnswerSource]
    var allowRemoteLinkPreview: Bool

    var body: some View {
        if sources.count == 1, let source = sources.first {
            SourcePreviewCard(source: source, allowRemoteLinkPreview: allowRemoteLinkPreview)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 9) {
                    ForEach(Array(sources.enumerated()), id: \.offset) { _, source in
                        SourcePreviewCard(source: source, allowRemoteLinkPreview: allowRemoteLinkPreview)
                            .frame(width: 268)
                    }
                }
                .padding(.vertical, 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SourcePreviewCard: View {
    var source: AnswerSource
    var allowRemoteLinkPreview: Bool
    @State private var loadedPreview: WebLinkPreview?
    @Environment(\.islandDesignMode) private var islandDesignMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var preview: WebLinkPreview {
        loadedPreview ?? WebLinkPreview.fallback(for: source)
    }

    var body: some View {
        Button {
            if let url = source.webURL {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                thumbnail

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        favicon
                        Text(preview.domain)
                            .font(.system(size: 9.2, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.38))
                            .lineLimit(1)
                    }

                    Text(preview.title)
                        .font(.system(size: 12.4, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.84))
                        .lineLimit(2)
                        .lineSpacing(1.4)

                    if let description = preview.description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 10.6, weight: .regular))
                            .foregroundStyle(Color.white.opacity(0.56))
                            .lineLimit(2)
                            .lineSpacing(1.4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(9)
            .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
            .background(
                IslandGlassFill(
                    shape: RoundedRectangle(cornerRadius: 8, style: .continuous),
                    mode: islandDesignMode,
                    solidOpacity: 0.032,
                    glassTintOpacity: 0.045,
                    glassFallbackOpacity: 0.030
                )
            )
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.052), lineWidth: 0.6))
        }
        .buttonStyle(.plain)
        .disabled(source.webURL == nil)
        .task(id: "\(source.reference ?? "")-\(allowRemoteLinkPreview)") {
            loadedPreview = await WebLinkPreviewService.shared.preview(for: source, allowRemoteFetch: allowRemoteLinkPreview)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: loadedPreview)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Source \(preview.title), \(preview.domain)")
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.042))

            if let imageURL = preview.imageURL, allowRemoteLinkPreview {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .empty:
                        placeholderIcon
                    case .failure:
                        placeholderIcon
                    @unknown default:
                        placeholderIcon
                    }
                }
            } else {
                placeholderIcon
            }
        }
        .frame(width: 58, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.white.opacity(0.048), lineWidth: 0.5))
    }

    private var favicon: some View {
        ZStack {
            if let faviconURL = preview.faviconURL, allowRemoteLinkPreview {
                AsyncImage(url: faviconURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    default:
                        Image(systemName: "link")
                            .font(.system(size: 8.2, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.40))
                    }
                }
            } else {
                Image(systemName: source.type == .web ? "link" : "doc.text")
                    .font(.system(size: 8.2, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.40))
            }
        }
        .frame(width: 12, height: 12)
    }

    private var placeholderIcon: some View {
        Image(systemName: source.type == .web ? "link" : "doc.text")
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.34))
    }
}

private struct StepsView: View {
    var title: String?
    var items: [RichAnswerItemPayload]
    var numbered: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(title)
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                let displayItem = RichAnswerStepDisplayNormalizer.normalized(
                    item,
                    index: index,
                    numbered: numbered
                )
                HStack(alignment: .top, spacing: 9) {
                    Text(numbered ? "\(index + 1)" : " ")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.54))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.055)))
                        .overlay(Circle().stroke(Color.white.opacity(0.058), lineWidth: 0.5))

                    itemText(displayItem)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum RichAnswerStepDisplayNormalizer {
    nonisolated static func normalized(
        _ item: RichAnswerItemPayload,
        index: Int,
        numbered: Bool
    ) -> RichAnswerItemPayload {
        let expectedIndex = index + 1
        let title = cleanedTitle(item.title, expectedIndex: expectedIndex)
        let text = cleanedText(item.text, expectedIndex: expectedIndex, numbered: numbered)
        let detail = item.detail.map {
            cleanedText($0, expectedIndex: expectedIndex, numbered: numbered)
        }

        return RichAnswerItemPayload(
            title: title,
            text: text,
            detail: detail,
            value: item.value,
            isChecked: item.isChecked,
            sourceIndex: item.sourceIndex
        )
    }

    nonisolated private static func cleanedTitle(_ title: String?, expectedIndex: Int) -> String? {
        guard let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }

        if isRedundantMarker(trimmed, expectedIndex: expectedIndex) {
            return nil
        }

        return cleanedText(trimmed, expectedIndex: expectedIndex, numbered: true)
            .nilIfEmptyRichAnswer
    }

    nonisolated private static func cleanedText(
        _ text: String,
        expectedIndex: Int,
        numbered: Bool
    ) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if let marker = leadingBulletMarker(in: trimmed) {
            trimmed.removeSubrange(trimmed.startIndex..<marker)
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if numbered, let marker = leadingNumberMarker(in: trimmed, expectedIndex: expectedIndex) {
            trimmed.removeSubrange(trimmed.startIndex..<marker)
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return trimmed
    }

    nonisolated private static func leadingBulletMarker(in text: String) -> String.Index? {
        guard let first = text.first, first == "-" || first == "*" || first == "•" else { return nil }
        let afterMarker = text.index(after: text.startIndex)
        guard afterMarker < text.endIndex, text[afterMarker].isWhitespace else { return nil }
        return text.index(after: afterMarker)
    }

    nonisolated private static func leadingNumberMarker(in text: String, expectedIndex: Int) -> String.Index? {
        var cursor = text.startIndex
        while cursor < text.endIndex, text[cursor].isNumber {
            cursor = text.index(after: cursor)
        }

        guard cursor > text.startIndex,
              let value = Int(text[text.startIndex..<cursor]),
              value == expectedIndex else {
            return nil
        }

        var separatorCursor = cursor
        while separatorCursor < text.endIndex, text[separatorCursor].isWhitespace {
            separatorCursor = text.index(after: separatorCursor)
        }

        guard separatorCursor < text.endIndex,
              [".", ")", ":", "-", "–", "—"].contains(String(text[separatorCursor])) else {
            return nil
        }

        let afterSeparator = text.index(after: separatorCursor)
        guard afterSeparator < text.endIndex,
              text[afterSeparator].isWhitespace else {
            return nil
        }

        return text.index(after: afterSeparator)
    }

    nonisolated private static func isRedundantMarker(_ title: String, expectedIndex: Int) -> Bool {
        let normalized = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".):-–—"))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return normalized == "\(expectedIndex)"
    }
}

private struct ChecklistView: View {
    var title: String?
    var items: [RichAnswerItemPayload]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(title)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: item.isChecked == true ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(item.isChecked == true ? Color(red: 0.52, green: 0.86, blue: 0.64) : Color.white.opacity(0.36))
                        .frame(width: 22, height: 22)

                    itemText(item)
                }
            }
        }
    }
}

private struct ComparisonMatrixView: View {
    var title: String?
    var items: [RichAnswerItemPayload]
    @Environment(\.islandDesignMode) private var islandDesignMode

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(title)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 5) {
                        if let title = item.title {
                            Text(title)
                                .font(.system(size: 11.4, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.82))
                                .lineLimit(2)
                        }
                        Text(item.text)
                            .font(.system(size: 11.2, weight: .regular))
                            .foregroundStyle(Color.white.opacity(0.62))
                            .lineLimit(4)
                            .lineSpacing(1.6)
                        if let value = item.value {
                            Text(value)
                                .font(.system(size: 9.4, weight: .bold))
                                .foregroundStyle(Color.white.opacity(0.44))
                                .lineLimit(1)
                        }
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
                    .background(
                        IslandGlassFill(
                            shape: RoundedRectangle(cornerRadius: 8, style: .continuous),
                            mode: islandDesignMode,
                            solidOpacity: 0.026,
                            glassTintOpacity: 0.038,
                            glassFallbackOpacity: 0.026
                        )
                    )
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.042), lineWidth: 0.5))
                }
            }
        }
    }
}

private struct MetricResultView: View {
    var block: RichAnswerBlockPayload
    @Environment(\.islandDesignMode) private var islandDesignMode

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = block.title {
                sectionTitle(title)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let label = block.label {
                    Text(label)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.42))
                        .lineLimit(1)
                }
                Text(block.value ?? block.text ?? "")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.90))
                    .lineLimit(2)
                    .minimumScaleFactor(0.68)
            }
            if let formula = block.formula {
                Text(formula)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.46))
                    .lineLimit(2)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            IslandGlassFill(
                shape: RoundedRectangle(cornerRadius: 8, style: .continuous),
                mode: islandDesignMode,
                solidOpacity: 0.036,
                glassTintOpacity: 0.052,
                glassFallbackOpacity: 0.032
            )
        )
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.064), lineWidth: 0.6))
    }
}

private struct RichCodeBlockView: View {
    var language: String?
    var code: String

    private var markdown: String {
        "```\(language ?? "")\n\(code)\n```"
    }

    var body: some View {
        DynamicAnswerContentView(text: markdown, density: .qa, alignment: .leading)
    }
}

private struct MeetingEvidenceView: View {
    var title: String
    var items: [RichAnswerItemPayload]
    var sources: [AnswerSource]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(title)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: evidenceIcon(for: item))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.42))
                        .frame(width: 18, height: 18)
                    itemText(item)
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func evidenceIcon(for item: RichAnswerItemPayload) -> String {
        guard let sourceIndex = item.sourceIndex, sources.indices.contains(sourceIndex) else {
            return "doc.text"
        }
        switch sources[sourceIndex].type {
        case .transcript:
            return "text.quote"
        case .rag, .manualContext:
            return "archivebox"
        case .calendar:
            return "calendar"
        case .github:
            return "chevron.left.forwardslash.chevron.right"
        case .jira:
            return "checklist"
        case .web:
            return "link"
        case .unknown:
            return "doc.text"
        }
    }
}

private struct ClarificationCard: View {
    var block: RichAnswerBlockPayload
    var actions: [RichAnswerActionPayload]
    var onCopy: (() -> Void)?
    var onOpenSources: (() -> Void)?
    var onRegenerateWithWeb: (() -> Void)?
    @Environment(\.islandDesignMode) private var islandDesignMode

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.62))
                Text(block.title ?? "Clarification")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.64))
            }
            Text(block.text ?? "")
                .font(.system(size: 14.2, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.78))
                .lineSpacing(3.4)
            RichActionStrip(actions: actions, onCopy: onCopy, onOpenSources: onOpenSources, onRegenerateWithWeb: onRegenerateWithWeb)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            IslandGlassFill(
                shape: RoundedRectangle(cornerRadius: 8, style: .continuous),
                mode: islandDesignMode,
                solidOpacity: 0.038,
                glassTintOpacity: 0.050,
                glassFallbackOpacity: 0.034
            )
        )
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.062), lineWidth: 0.6))
    }
}

private struct WarningBlockView: View {
    var block: RichAnswerBlockPayload

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: block.severity == "error" ? "exclamationmark.triangle" : "info.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(block.severity == "error" ? Color(red: 1.0, green: 0.55, blue: 0.48).opacity(0.76) : Color.white.opacity(0.44))
                .frame(width: 18, height: 18)
            Text(block.text ?? block.title ?? "")
                .font(.system(size: 11.8, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.58))
                .lineSpacing(2.4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.030)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.040), lineWidth: 0.5))
    }
}

private struct RichActionStrip: View {
    var actions: [RichAnswerActionPayload]
    var onCopy: (() -> Void)?
    var onOpenSources: (() -> Void)?
    var onRegenerateWithWeb: (() -> Void)?

    var body: some View {
        let availableActions = Array(actions.enumerated()).filter { canPerform($0.element) }

        if !availableActions.isEmpty {
            HStack(spacing: 6) {
                ForEach(availableActions, id: \.offset) { _, action in
                    Button {
                        perform(action)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: iconName(for: action.kind))
                                .font(.system(size: 10.4, weight: .semibold))
                            Text(action.title)
                                .font(.system(size: 10.4, weight: .semibold))
                                .lineLimit(1)
                        }
                        .foregroundStyle(Color.white.opacity(0.68))
                        .padding(.horizontal, 8)
                        .frame(height: 25)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.050)))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.white.opacity(0.060), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .textSelection(.disabled)
        }
    }

    private func canPerform(_ action: RichAnswerActionPayload) -> Bool {
        switch RichAnswerActionKind(rawValue: action.kind) {
        case .copy:
            return onCopy != nil
        case .openSources:
            return onOpenSources != nil
        case .regenerateWithWeb:
            return onRegenerateWithWeb != nil
        case .none:
            return false
        }
    }

    private func perform(_ action: RichAnswerActionPayload) {
        switch RichAnswerActionKind(rawValue: action.kind) {
        case .copy:
            onCopy?()
        case .openSources:
            onOpenSources?()
        case .regenerateWithWeb:
            onRegenerateWithWeb?()
        case .none:
            break
        }
    }

    private func iconName(for kind: String) -> String {
        switch RichAnswerActionKind(rawValue: kind) {
        case .copy:
            return "doc.on.doc"
        case .openSources:
            return "link"
        case .regenerateWithWeb:
            return "globe"
        case .none:
            return "sparkles"
        }
    }
}

@ViewBuilder
private func sectionTitle(_ title: String?) -> some View {
    if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
        Text(title.uppercased())
            .font(.system(size: 9.2, weight: .bold))
            .foregroundStyle(Color.white.opacity(0.38))
            .lineLimit(1)
    }
}

private func itemText(_ item: RichAnswerItemPayload) -> some View {
    VStack(alignment: .leading, spacing: 3) {
        if let title = item.title {
            Text(title)
                .font(.system(size: 12.2, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.80))
                .lineLimit(2)
        }
        Text(item.text)
            .font(.system(size: 12.2, weight: .regular))
            .foregroundStyle(Color.white.opacity(0.66))
            .lineLimit(5)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
        if let detail = item.detail {
            Text(detail)
                .font(.system(size: 10.4, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.42))
                .lineLimit(3)
        }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
}
