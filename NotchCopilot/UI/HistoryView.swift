import AppKit
import SwiftUI

struct HistoryView: View {
    @ObservedObject var appState: AppState
    @State private var searchText = ""
    private let sidebarWidth: CGFloat = 286

    private var filteredMeetings: [MeetingSession] {
        guard !searchText.isEmpty else { return appState.history }
        return appState.history.filter { meeting in
            meeting.title.localizedCaseInsensitiveContains(searchText) ||
            meeting.transcriptSegments.contains { $0.text.localizedCaseInsensitiveContains(searchText) }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            detail
        }
        .background(MinimalTheme.historyChrome)
        .foregroundStyle(MinimalTheme.historyInk)
        .preferredColorScheme(.dark)
        .onAppear {
            appState.reloadHistory()
            if appState.selectedMeeting == nil {
                appState.selectedMeeting = appState.history.first
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            sidebarHeader

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(MinimalTheme.historyChromeMuted)
                TextField("Search", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(MinimalTheme.historyChromeText)
                    .accentColor(MinimalTheme.historyAccent)
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.075)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.095), lineWidth: 0.7))
            .padding(.horizontal, 14)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(filteredMeetings) { meeting in
                        meetingRow(meeting)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 18)
            }
            .scrollContentBackground(.hidden)
        }
        .frame(width: sidebarWidth)
        .background(
            LinearGradient(
                colors: [MinimalTheme.historyChromeRaised, MinimalTheme.historyChrome],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(width: 0.8)
        }
    }

    private var sidebarHeader: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(MinimalTheme.historyChromeText)
                Circle()
                    .fill(MinimalTheme.historyAccent)
                    .frame(width: 5, height: 5)
                    .padding(.top, 6)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("History")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(MinimalTheme.historyChromeText)
                Text("\(appState.history.count) local meetings")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MinimalTheme.historyChromeMuted)
            }
        }
        .padding(.top, 28)
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private var detail: some View {
        if let meeting = appState.selectedMeeting {
            VStack(spacing: 0) {
                header(for: meeting)

                HStack(alignment: .top, spacing: 22) {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeader("Summary", systemName: "doc.text")
                        SummaryView(
                            meeting: meeting,
                            showsTitle: false,
                            contentPadding: 0,
                            isProtected: appState.preferences.stealthModeEnabled
                        )
                    }
                    .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)

                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeader("Transcript", systemName: "text.quote")
                        TranscriptLiveView(
                            segments: meeting.transcriptSegments,
                            limit: 32,
                            isProtected: appState.preferences.stealthModeEnabled
                        )
                            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(MinimalTheme.historyCard))
                            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(MinimalTheme.historyBorder, lineWidth: 0.8))
                            .shadow(color: MinimalTheme.historyShadow.opacity(0.42), radius: 18, x: 0, y: 12)
                    }
                    .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(MinimalTheme.historyCanvas)
            }
            .background(MinimalTheme.historyCanvas)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(MinimalTheme.historyAccent)
                Text("No meetings yet")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(MinimalTheme.historyInk)
                Text("Start listening to create history.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MinimalTheme.historyMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MinimalTheme.historyCanvas)
        }
    }

    private func meetingRow(_ meeting: MeetingSession) -> some View {
        let isSelected = appState.selectedMeeting?.id == meeting.id
        return Button {
            appState.selectedMeeting = meeting
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(isSelected ? MinimalTheme.historyAccentSoft : Color.white.opacity(0.06))
                    Image(systemName: meeting.status == .ended ? "checkmark.circle.fill" : "waveform")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isSelected ? MinimalTheme.historyAccent : MinimalTheme.historyChromeMuted)
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 4) {
                    Text(meeting.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(isSelected ? MinimalTheme.historyInk : MinimalTheme.historyChromeText.opacity(0.76))
                        .lineLimit(1)
                    Text(DateFormatting.shortDateTime.string(from: meeting.startedAt))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isSelected ? MinimalTheme.historyMuted : MinimalTheme.historyChromeMuted)
                }
                Spacer()

                if isSelected {
                    Circle()
                        .fill(MinimalTheme.historyAccent)
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 62)
            .background(
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(isSelected ? MinimalTheme.historyCard : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .stroke(isSelected ? MinimalTheme.historyAccent.opacity(0.23) : Color.clear, lineWidth: 0.8)
            )
            .shadow(color: isSelected ? Color.black.opacity(0.28) : Color.clear, radius: 12, x: 0, y: 8)
        }
        .buttonStyle(.plain)
    }

    private func header(for meeting: MeetingSession) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(meeting.title)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(MinimalTheme.historyChromeText)
                    .lineLimit(1)
                HStack(spacing: 9) {
                    Text(meeting.meetingType.displayName)
                    Circle().fill(MinimalTheme.historyAccent).frame(width: 4, height: 4)
                    Text(meeting.status.rawValue.capitalized)
                    Circle().fill(Color.white.opacity(0.22)).frame(width: 4, height: 4)
                    Text(DateFormatting.shortDateTime.string(from: meeting.startedAt))
                }
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(MinimalTheme.historyChromeMuted)
            }
            Spacer(minLength: 22)
            HStack(spacing: 10) {
                Button {
                    export(meeting: meeting, format: "md")
                } label: {
                    Label("Markdown", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(HistoryToolbarButtonStyle())
                Button {
                    export(meeting: meeting, format: "json")
                } label: {
                    Label("JSON", systemImage: "curlybraces")
                }
                .buttonStyle(HistoryToolbarButtonStyle())
                Button(role: .destructive) {
                    appState.deleteMeeting(meeting)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(HistoryToolbarButtonStyle(isDestructive: true))
            }
        }
        .padding(.leading, 30)
        .padding(.trailing, 28)
        .padding(.top, 28)
        .padding(.bottom, 24)
        .background(
            LinearGradient(
                colors: [MinimalTheme.historyChromeRaised, MinimalTheme.historyChrome],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.065))
                .frame(height: 0.8)
        }
    }

    private func sectionHeader(_ title: String, systemName: String) -> some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(MinimalTheme.historyAccentSoft)
                Image(systemName: systemName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(MinimalTheme.historyAccent)
            }
            .frame(width: 26, height: 26)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(MinimalTheme.historyText)
            Spacer()
        }
    }

    private func export(meeting: MeetingSession, format: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(meeting.title.replacingOccurrences(of: " ", with: "-")).\(format)"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                switch format {
                case "json":
                    let data = try JSONEncoder().encode(meeting)
                    try data.write(to: url, options: [.atomic])
                default:
                    try markdown(for: meeting).write(to: url, atomically: true, encoding: .utf8)
                }
            } catch {
                appState.statusMessage = "Export failed"
            }
        }
    }

    private func markdown(for meeting: MeetingSession) -> String {
        var output = "# \(meeting.title)\n\n"
        if let summary = meeting.summary {
            output += "## Summary\n\(summary.executiveSummary)\n\n"
            output += "## Decisions\n" + summary.keyDecisions.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
            output += "## Action Items\n" + summary.actionItems.map { "- \($0.title)" }.joined(separator: "\n") + "\n\n"
        }
        output += "## Transcript\n"
        output += meeting.transcriptSegments.map { "- **[\($0.audioSource.displayName)] \($0.speakerLabel):** \($0.text)" }.joined(separator: "\n")
        return output
    }
}
