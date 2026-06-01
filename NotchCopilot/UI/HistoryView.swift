import AppKit
import SwiftUI

@MainActor
final class KnowledgeWorkspaceViewModel: ObservableObject {
    @Published var selectedPane: KnowledgeWorkspacePane = .home
    @Published var searchText = ""
    @Published var copilotPrompt = ""
    @Published var hoveredSourceId: UUID?

    func filteredMeetings(from meetings: [MeetingSession]) -> [MeetingSession] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return meetings }
        return meetings.filter { meeting in
            meeting.title.localizedCaseInsensitiveContains(query) ||
                meeting.transcriptSegments.contains { $0.text.localizedCaseInsensitiveContains(query) }
        }
    }
}

enum KnowledgeWorkspacePane: String, CaseIterable, Identifiable {
    case home
    case meetings
    case transcripts
    case sources
    case copilot
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .meetings: "Meetings"
        case .transcripts: "Transcripts"
        case .sources: "Sources"
        case .copilot: "Copilot"
        case .settings: "Settings"
        }
    }

    var systemName: String {
        switch self {
        case .home: "house"
        case .meetings: "calendar"
        case .transcripts: "text.quote"
        case .sources: "archivebox"
        case .copilot: "sparkles"
        case .settings: "gearshape"
        }
    }
}

struct HistoryView: View {
    @ObservedObject var appState: AppState
    @StateObject private var model = KnowledgeWorkspaceViewModel()
    @Namespace private var paneNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var filteredMeetings: [MeetingSession] {
        model.filteredMeetings(from: appState.history)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            workspace
        }
        .background(MinimalTheme.background)
        .foregroundStyle(MinimalTheme.primary)
        .preferredColorScheme(.dark)
        .frame(minWidth: 980, minHeight: 660)
        .onAppear {
            appState.reloadHistory()
            appState.reloadKnowledgeDocuments()
            if appState.selectedMeeting == nil {
                appState.selectedMeeting = appState.history.first
            }
        }
        .onChange(of: model.selectedPane) {
            if model.selectedPane == .settings {
                appState.openSettingsHandler?()
                model.selectedPane = .home
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 9) {
                WorkspaceNotchMark()
                    .frame(width: 28, height: 14)
                Text("Notchly")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 22)

            workspacePicker

            VStack(spacing: 4) {
                ForEach(KnowledgeWorkspacePane.allCases) { pane in
                    paneButton(pane)
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                statusLine(title: appState.retrievalStatus.title, detail: appState.retrievalStatus.detail, positive: !appState.retrievalStatus.isIndexing)
                Button {
                    model.selectedPane = .sources
                } label: {
                    Label("Manage sources", systemImage: "plus.circle")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(MinimalTheme.secondary)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(MinimalTheme.divider, lineWidth: 0.7))
            .padding(.horizontal, 12)
            .padding(.bottom, 14)
        }
        .frame(width: 236)
        .background(Color.black.opacity(0.92))
        .overlay(alignment: .trailing) {
            Rectangle().fill(MinimalTheme.divider).frame(width: 0.7)
        }
    }

    private var workspacePicker: some View {
        HStack(spacing: 10) {
            Image(systemName: "building.2")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(MinimalTheme.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(appState.preferences.workspaceId == "default" ? "Personal" : appState.preferences.workspaceId)
                    .font(.system(size: 13, weight: .semibold))
                Text("Workspace")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MinimalTheme.tertiary)
            }
            Spacer()
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(MinimalTheme.tertiary)
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.055)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(MinimalTheme.divider, lineWidth: 0.7))
        .padding(.horizontal, 12)
    }

    private func paneButton(_ pane: KnowledgeWorkspacePane) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.88)) {
                model.selectedPane = pane
            }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: pane.systemName)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 18)
                Text(pane.title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(model.selectedPane == pane ? Color.white : MinimalTheme.secondary)
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background {
                if model.selectedPane == pane {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.09))
                        .matchedGeometryEffect(id: "pane", in: paneNamespace)
                }
            }
            .overlay(alignment: .leading) {
                if model.selectedPane == pane {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(MinimalTheme.historyAccent)
                        .frame(width: 3, height: 18)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(MinimalTheme.divider)
            ZStack {
                switch model.selectedPane {
                case .sources:
                    sourcesPane
                case .copilot:
                    copilotPane
                default:
                    meetingsPane
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.selectedPane)
            commandBar
        }
        .background(MinimalTheme.background)
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(headerTitle)
                    .font(.system(size: 24, weight: .semibold))
                Text(headerSubtitle)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(MinimalTheme.secondary)
            }
            Spacer()
            searchField
            Button {
                model.selectedPane = .sources
            } label: {
                Label("Sources", systemImage: "archivebox")
            }
            .buttonStyle(HistoryToolbarButtonStyle())
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 20)
    }

    private var headerTitle: String {
        switch model.selectedPane {
        case .sources: "Sources"
        case .copilot: "Copilot"
        default: "Knowledge Workspace"
        }
    }

    private var headerSubtitle: String {
        switch model.selectedPane {
        case .sources: "Connect folders and Obsidian vaults for grounded answers."
        case .copilot: "Ask across meetings, transcripts and selected sources."
        default: "\(appState.history.count) meetings - \(appState.knowledgeSources.count) sources"
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MinimalTheme.tertiary)
            TextField("Search meetings...", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, weight: .medium))
        }
        .padding(.horizontal, 10)
        .frame(width: 230, height: 32)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(MinimalTheme.divider, lineWidth: 0.7))
    }

    private var meetingsPane: some View {
        VStack(spacing: 18) {
            topSummary
            HStack(alignment: .top, spacing: 18) {
                meetingList
                if let meeting = appState.selectedMeeting {
                    meetingDetail(meeting)
                        .frame(width: 340)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var topSummary: some View {
        HStack(spacing: 12) {
            compactMetric(title: "Next", value: nextMeetingValue, detail: nextMeetingDetail, icon: "calendar")
            compactMetric(title: "Sources", value: "\(appState.knowledgeSources.count)", detail: appState.retrievalStatus.quality, icon: "archivebox")
            compactMetric(title: "Context", value: appState.retrievalStatus.isIndexing ? "Syncing" : "Ready", detail: appState.retrievalStatus.detail, icon: "checkmark.seal")
        }
    }

    private func compactMetric(title: String, value: String, detail: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(MinimalTheme.historyAccent)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(MinimalTheme.historyAccentSoft))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MinimalTheme.tertiary)
                Text(value)
                    .font(.system(size: 18, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MinimalTheme.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 72)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(MinimalTheme.divider, lineWidth: 0.7))
    }

    private var meetingList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.selectedPane == .transcripts ? "Transcripts" : "Meetings")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(filteredMeetings.count)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(MinimalTheme.tertiary)
            }
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(filteredMeetings) { meeting in
                        meetingRow(meeting)
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func meetingRow(_ meeting: MeetingSession) -> some View {
        let isSelected = appState.selectedMeeting?.id == meeting.id
        return Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.9)) {
                appState.selectedMeeting = meeting
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: meeting.status == .ended ? "checkmark.circle" : "waveform")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isSelected ? MinimalTheme.historyAccent : MinimalTheme.secondary)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isSelected ? MinimalTheme.historyAccentSoft : Color.white.opacity(0.045)))
                VStack(alignment: .leading, spacing: 4) {
                    Text(meeting.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 7) {
                        Text(DateFormatting.shortDateTime.string(from: meeting.startedAt))
                        Text("\(meeting.transcriptSegments.count) segments")
                        if meeting.summary != nil {
                            Label("Summary", systemImage: "doc.text")
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MinimalTheme.secondary)
                    .lineLimit(1)
                }
                Spacer()
                statusChip(meeting.status.rawValue.capitalized, positive: meeting.status == .ended)
            }
            .padding(.horizontal, 12)
            .frame(height: 62)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isSelected ? Color.white.opacity(0.075) : Color.white.opacity(0.028)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(isSelected ? MinimalTheme.historyAccent.opacity(0.26) : MinimalTheme.divider, lineWidth: 0.7))
        }
        .buttonStyle(.plain)
    }

    private func meetingDetail(_ meeting: MeetingSession) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(meeting.title)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(2)
                    Text(meeting.meetingType.displayName)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(MinimalTheme.secondary)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                Button {
                    model.copilotPrompt = "Summarize \(meeting.title)"
                    submitCopilotPrompt()
                } label: {
                    Label("Ask", systemImage: "sparkles")
                }
                .buttonStyle(HistoryToolbarButtonStyle())
                Button {
                    copyMeeting(meeting)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(HistoryToolbarButtonStyle())
                Button {
                    export(meeting: meeting, format: "md")
                } label: {
                    Label("Markdown", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(HistoryToolbarButtonStyle())
                Button {
                    openEvidence(for: meeting)
                } label: {
                    Label("Evidence", systemImage: "quote.bubble")
                }
                .buttonStyle(HistoryToolbarButtonStyle())
                Button(role: .destructive) { appState.deleteMeeting(meeting) } label: { Image(systemName: "trash") }
                    .buttonStyle(HistoryToolbarButtonStyle(isDestructive: true))
            }
            if let summary = meeting.summary {
                Text(summary.executiveSummary)
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(MinimalTheme.secondary)
                    .lineSpacing(3)
                    .lineLimit(7)
            } else {
                Text("No summary yet.")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(MinimalTheme.tertiary)
            }
            Divider().overlay(MinimalTheme.divider)
            meetingQAStrip(meeting)
            Divider().overlay(MinimalTheme.divider)
            TranscriptLiveView(
                segments: meeting.transcriptSegments,
                limit: 10,
                isProtected: appState.preferences.stealthModeEnabled,
                onCopySegment: { appState.copyTranscriptSegmentToPasteboard($0) },
                onDeleteSegment: { appState.deleteTranscriptSegment($0) }
            )
            .frame(maxHeight: .infinity)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(MinimalTheme.divider, lineWidth: 0.7))
    }

    private var sourcesPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Connected Sources")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button {
                    appState.connectKnowledgeDirectory(kind: .directory)
                } label: {
                    Label("Directory", systemImage: "folder.badge.plus")
                }
                .buttonStyle(HistoryToolbarButtonStyle())
                Button {
                    appState.connectKnowledgeDirectory(kind: .obsidian)
                } label: {
                    Label("Obsidian", systemImage: "hexagon")
                }
                .buttonStyle(HistoryToolbarButtonStyle())
                Button {
                    appState.connectKnowledgeFiles()
                } label: {
                    Label("Files", systemImage: "doc.badge.plus")
                }
                .buttonStyle(HistoryToolbarButtonStyle())
            }
            if appState.knowledgeSources.isEmpty {
                sourceEmptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(appState.knowledgeSources) { source in
                            sourceRow(source)
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var sourceEmptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "archivebox")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(MinimalTheme.historyAccent)
            Text("Add a source")
                .font(.system(size: 17, weight: .semibold))
            HStack(spacing: 8) {
                Button("Directory") { appState.connectKnowledgeDirectory(kind: .directory) }
                    .buttonStyle(HistoryToolbarButtonStyle())
                Button("Obsidian") { appState.connectKnowledgeDirectory(kind: .obsidian) }
                    .buttonStyle(HistoryToolbarButtonStyle())
                Button("Files") { appState.connectKnowledgeFiles() }
                    .buttonStyle(HistoryToolbarButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(MinimalTheme.divider, style: StrokeStyle(lineWidth: 0.8, dash: [6, 6])))
    }

    private func sourceRow(_ source: SourceConnectionViewModel) -> some View {
        let isSelected = appState.preferences.selectedKnowledgeSourceId == source.id
        return HStack(spacing: 13) {
            Image(systemName: source.kind.systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isSelected ? MinimalTheme.historyAccent : MinimalTheme.primary)
                .frame(width: 42, height: 42)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isSelected ? MinimalTheme.historyAccentSoft : Color.white.opacity(0.055)))
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(source.title)
                        .font(.system(size: 13.5, weight: .semibold))
                    statusDot(source.status)
                    Text(source.status.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(MinimalTheme.secondary)
                }
                Text(source.subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MinimalTheme.tertiary)
                    .lineLimit(1)
                Text(sourceMetadataLine(source))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MinimalTheme.secondary)
            }
            Spacer()
            Button {
                appState.preferences.selectedKnowledgeSourceId = source.id
                appState.preferences.copilotKnowledgeScope = .selectedSource
                appState.savePreferences()
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(isSelected ? MinimalTheme.historyAccent : MinimalTheme.tertiary)
            Button {
                appState.reindexKnowledgeSource(source.id)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(HistoryToolbarButtonStyle())
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(model.hoveredSourceId == source.id ? Color.white.opacity(0.07) : Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(isSelected ? MinimalTheme.historyAccent.opacity(0.24) : MinimalTheme.divider, lineWidth: 0.7))
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                model.hoveredSourceId = hovering ? source.id : nil
            }
        }
    }

    private var copilotPane: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(MinimalTheme.historyAccent)
            Text("Ask across your workspace")
                .font(.system(size: 20, weight: .semibold))
            Text("Use the command bar below to search meetings, transcripts and connected sources.")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(MinimalTheme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var commandBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Picker("", selection: $appState.preferences.copilotKnowledgeScope) {
                    ForEach(KnowledgeCopilotScope.allCases) { scope in
                        Text(scope.displayName).tag(scope)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 150)
                .onChange(of: appState.preferences.copilotKnowledgeScope) {
                    appState.savePreferences()
                }

                Divider().frame(height: 24).overlay(MinimalTheme.divider)
                Image(systemName: "paperclip")
                    .foregroundStyle(MinimalTheme.secondary)
                TextField("Ask anything about your meetings or knowledge...", text: $model.copilotPrompt)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .onSubmit(submitCopilotPrompt)
                Button(action: submitCopilotPrompt) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 13, weight: .bold))
                }
                .buttonStyle(.plain)
                .frame(width: 34, height: 34)
                .background(Circle().fill(MinimalTheme.historyAccent))
                .foregroundStyle(Color.white)
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            .background(Capsule(style: .continuous).fill(Color.white.opacity(0.065)))
            .overlay(Capsule(style: .continuous).stroke(MinimalTheme.divider, lineWidth: 0.8))

            HStack(spacing: 8) {
                suggestionButton("Summarize yesterday's meetings")
                suggestionButton("What risks came up recently?")
                suggestionButton("Find decisions about roadmap")
                Spacer()
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 18)
        .background(Color.black.opacity(0.42))
    }

    private func suggestionButton(_ title: String) -> some View {
        Button(title) {
            model.copilotPrompt = title
            submitCopilotPrompt()
        }
        .buttonStyle(HistoryToolbarButtonStyle())
    }

    private func submitCopilotPrompt() {
        let prompt = model.copilotPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        appState.analyzeCopilotPrompt(prompt, forceWeb: false)
        model.copilotPrompt = ""
        model.selectedPane = .copilot
    }

    private var upcomingMeetings: [MeetingSession] {
        appState.history
            .filter { $0.startedAt >= Calendar.current.startOfDay(for: Date()) && $0.status != .ended }
            .sorted { $0.startedAt < $1.startedAt }
    }

    private var nextMeetingValue: String {
        guard let meeting = upcomingMeetings.first else { return "None" }
        return DateFormatting.time.string(from: meeting.startedAt)
    }

    private var nextMeetingDetail: String {
        upcomingMeetings.first?.title ?? "No upcoming meetings"
    }

    private func sourceMetadataLine(_ source: SourceConnectionViewModel) -> String {
        if source.status == .failed, let error = source.lastError?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
            return error
        }
        let sync = source.lastIndexedAt.map { "synced \(DateFormatting.shortDateTime.string(from: $0))" } ?? "not synced yet"
        return "\(source.documentCount) documents - \(source.chunkCount) chunks - \(sync)"
    }

    private func meetingQAStrip(_ meeting: MeetingSession) -> some View {
        let records = appState.questionAnswerRecords
            .filter { $0.meetingId == meeting.id }
            .sorted { $0.createdAt > $1.createdAt }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Saved Q&A")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(records.count)")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(MinimalTheme.tertiary)
            }
            if records.isEmpty {
                Text("No saved answers yet.")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(MinimalTheme.tertiary)
            } else {
                ForEach(records.prefix(2)) { record in
                    HStack(spacing: 7) {
                        Image(systemName: "checkmark.bubble")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(MinimalTheme.historyAccent)
                        Text(record.question.rawText)
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                        Spacer()
                        Text("\(record.sources.count) sources")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(MinimalTheme.tertiary)
                    }
                }
            }
        }
    }

    private func copyMeeting(_ meeting: MeetingSession) {
        let transcript = meeting.transcriptSegments
            .sorted { $0.startTime < $1.startTime }
            .map { "\($0.speakerLabel): \($0.text)" }
            .joined(separator: "\n")
        let summary = meeting.summary?.executiveSummary ?? ""
        let text = [meeting.title, summary, transcript]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func openEvidence(for meeting: MeetingSession) {
        let sources = appState.questionAnswerRecords
            .filter { $0.meetingId == meeting.id }
            .flatMap(\.sources)
        appState.openAnswerSources(sources)
    }

    private func statusLine(title: String, detail: String, positive: Bool) -> some View {
        HStack(spacing: 9) {
            Circle()
                .fill(positive ? MinimalTheme.success : MinimalTheme.historyAccent)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MinimalTheme.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private func statusChip(_ text: String, positive: Bool) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(positive ? MinimalTheme.success : MinimalTheme.historyAccent)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule(style: .continuous).fill((positive ? MinimalTheme.success : MinimalTheme.historyAccent).opacity(0.12)))
            .overlay(Capsule(style: .continuous).stroke((positive ? MinimalTheme.success : MinimalTheme.historyAccent).opacity(0.22), lineWidth: 0.6))
    }

    private func statusDot(_ status: KnowledgeSourceStatus) -> some View {
        Circle()
            .fill(status == .failed ? MinimalTheme.destructive : (status == .indexing ? MinimalTheme.historyAccent : MinimalTheme.success))
            .frame(width: 6, height: 6)
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

private struct WorkspaceNotchMark: View {
    var body: some View {
        ZStack {
            Capsule()
                .fill(MinimalTheme.primary.opacity(0.92))
                .frame(width: 28, height: 10)
            Capsule()
                .fill(Color.black)
                .frame(width: 18, height: 6)
                .offset(y: -1)
        }
        .accessibilityHidden(true)
    }
}
