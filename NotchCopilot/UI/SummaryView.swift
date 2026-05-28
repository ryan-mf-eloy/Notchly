import SwiftUI

struct SummaryView: View {
    var meeting: MeetingSession?
    var showsTitle = true
    var contentPadding: CGFloat = 20
    var isProtected = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if showsTitle {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(meeting?.title ?? "No meeting selected")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(MinimalTheme.historyInk)
                            .lineLimit(1)
                        if let meeting {
                            Text("\(meeting.meetingType.displayName) · \(DateFormatting.shortDateTime.string(from: meeting.startedAt))")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(MinimalTheme.historyMuted)
                        }
                    }
                }

                if let summary = meeting?.summary {
                    summarySection("Executive Summary", systemName: "text.alignleft", items: [summary.executiveSummary])
                    summarySection("Decisions", systemName: "checkmark.seal", items: summary.keyDecisions)
                    summarySection("Action Items", systemName: "checklist", items: summary.actionItems.map { item in
                        [item.title, item.owner.map { "Owner: \($0)" }].compactMap { $0 }.joined(separator: " · ")
                    })
                    summarySection("Risks", systemName: "exclamationmark.triangle", items: summary.risks)
                    summarySection("Open Questions", systemName: "questionmark.bubble", items: summary.openQuestions)
                    summarySection("Insights", systemName: "sparkles", items: summary.strategicInsights)
                    summarySection("Follow-ups", systemName: "arrowshape.turn.up.right", items: summary.followUps)
                } else {
                    emptySummary
                }
            }
            .padding(contentPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .background(MinimalTheme.historyCanvas)
        .foregroundStyle(MinimalTheme.historyInk)
        .preferredColorScheme(.dark)
        .protectedContentRegion(isProtected)
    }

    private var emptySummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(MinimalTheme.historyAccentSoft)
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(MinimalTheme.historyAccent)
            }
            .frame(width: 42, height: 42)
            Text("Summary is not available yet.")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(MinimalTheme.historyText)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(MinimalTheme.historyCard))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(MinimalTheme.historyBorder, lineWidth: 0.8))
        .shadow(color: MinimalTheme.historyShadow.opacity(0.35), radius: 16, x: 0, y: 10)
    }

    private func summarySection(_ title: String, systemName: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(MinimalTheme.historyAccentSoft)
                    Image(systemName: systemName)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(MinimalTheme.historyAccent)
                }
                .frame(width: 28, height: 28)
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(MinimalTheme.historyText)
                Spacer()
            }

            if items.filter({ !$0.isEmpty }).isEmpty {
                Text("None captured.")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(MinimalTheme.historyFaint)
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(items.filter { !$0.isEmpty }, id: \.self) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle()
                                .fill(MinimalTheme.historyAccent)
                                .frame(width: 4, height: 4)
                            Text(item)
                                .font(.system(size: 13.5, weight: .medium))
                                .lineSpacing(2)
                                .foregroundStyle(MinimalTheme.historyText)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(MinimalTheme.historyCard))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(MinimalTheme.historyBorder, lineWidth: 0.8))
        .shadow(color: MinimalTheme.historyShadow.opacity(0.28), radius: 14, x: 0, y: 9)
    }
}
