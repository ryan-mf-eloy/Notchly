import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @StateObject private var permissions = PermissionsManager()
    @State private var selectedPane: SettingsPane = .general
    @State private var fileImporterPresented = false
    @State private var diagnosticsRefreshID = UUID()
    @State private var speechVocabularySearch = ""
    @State private var speechTermText = ""
    @State private var speechTermAliases = ""
    @State private var speechTermPronunciation = ""
    @State private var speechTermTemplatePattern = ""
    @State private var speechTermTemplateSlots = ""
    @State private var speechTermCategory: SpeechVocabularyCategory = .custom
    @State private var speechTermLocale: String = SupportedLanguage.portugueseBR.rawValue
    @State private var speechTermBoost = 1.4

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(MinimalTheme.divider)
                .frame(width: 0.6)
            content
        }
        .background(MinimalTheme.background)
        .foregroundStyle(MinimalTheme.primary)
        .preferredColorScheme(.dark)
        .frame(minWidth: 760, minHeight: 560)
        .onAppear {
            permissions.refresh()
            appState.reloadKnowledgeDocuments()
            appState.reloadSpeechVocabulary()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
        .fileImporter(isPresented: $fileImporterPresented, allowedContentTypes: [.plainText, .text, .pdf, .item], allowsMultipleSelection: true) { result in
            if let urls = try? result.get() {
                appState.addKnowledgeFiles(urls: urls)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image("NotchIcon")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 26, height: 14)
                Text("Notchly")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(MinimalTheme.primary)
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 10)

            ForEach(SettingsPane.allCases) { pane in
                Button {
                    selectedPane = pane
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: pane.systemName)
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 18)
                        Text(pane.title)
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                    }
                    .foregroundStyle(selectedPane == pane ? MinimalTheme.primary : MinimalTheme.secondary)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selectedPane == pane ? MinimalTheme.selected : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer()

            HStack(spacing: 8) {
                Circle()
                    .fill(appState.preferences.localOnlyMode ? MinimalTheme.primary : MinimalTheme.tertiary)
                    .frame(width: 7, height: 7)
                Text(appState.preferences.localOnlyMode ? "Local Only" : "Cloud enabled")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MinimalTheme.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 8)
        .frame(width: 190)
        .background(MinimalTheme.sidebar)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(selectedPane.title)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(MinimalTheme.primary)
                        Text(selectedPane.subtitle)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(MinimalTheme.tertiary)
                    }
                    Spacer()
                    Button {
                        appState.savePreferences()
                    } label: {
                        Label("Save", systemImage: "checkmark")
                    }
                    .buttonStyle(MinimalButtonStyle())
                }
                .padding(.top, 2)

                paneContent
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .background(MinimalTheme.background)
    }

    @ViewBuilder
    private var paneContent: some View {
        switch selectedPane {
        case .general:
            general
        case .audio:
            audio
        case .ai:
            ai
        case .speechVocabulary:
            speechVocabulary
        case .privacy:
            privacy
        case .knowledge:
            knowledge
        }
    }

    private var general: some View {
        VStack(spacing: 16) {
            MinimalSection(title: "Appearance") {
                pickerRow("Island design", systemName: "circle.lefthalf.filled", selection: $appState.preferences.islandDesignMode) {
                    ForEach(IslandDesignMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .onChange(of: appState.preferences.islandDesignMode) {
                    appState.savePreferences()
                }
            }

            MinimalSection(title: "Meeting") {
                toggleRow("Launch at login", systemName: "power", isOn: $appState.preferences.launchAtLogin)
                MinimalDivider()
                toggleRow("Auto-detect meetings", systemName: "calendar.badge.clock", isOn: $appState.preferences.autoDetectMeetings)
                MinimalDivider()
                toggleRow("Smart mic detection", systemName: "mic.badge.plus", isOn: $appState.preferences.smartMeetingDetectionEnabled)
                MinimalDivider()
                toggleRow("Auto-start listening", systemName: "play.circle", isOn: $appState.preferences.autoStartListening)
                MinimalDivider()
                toggleRow("Confirm before recording", systemName: "checkmark.shield", isOn: $appState.preferences.requireConfirmationBeforeRecording)
                MinimalDivider()
                toggleRow("Auto-end detected meetings", systemName: "stop.circle", isOn: $appState.preferences.autoEndDetectedMeetings)
                MinimalDivider()
                stepperRow("Auto-end delay", systemName: "timer", value: $appState.preferences.autoEndGraceSeconds, suffix: "sec")
            }

            MinimalSection(title: "Profile") {
                textRow("Name", systemName: "person", text: $appState.preferences.userDisplayName)
                MinimalDivider()
                textRow("Nicknames", systemName: "person.2", text: $appState.preferences.userNicknames)
                MinimalDivider()
                textRow("Role", systemName: "briefcase", text: $appState.preferences.userRole)
                MinimalDivider()
                pickerRow("Meeting type", systemName: "rectangle.stack", selection: $appState.preferences.defaultMeetingType) {
                    ForEach(MeetingType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                MinimalDivider()
                languagePickerRow("Transcript language", systemName: "globe", selection: $appState.preferences.defaultLanguage)
            }

            MinimalSection(title: "Notchly") {
                toggleRow("Hotkey enabled", systemName: "keyboard", isOn: $appState.preferences.copilotHotkeyEnabled)
                    .onChange(of: appState.preferences.copilotHotkeyEnabled) {
                        appState.savePreferences()
                    }
                MinimalDivider()
                diagnosticRow("Hotkey", systemName: "command", value: CopilotHotkeyDescriptor.default.displayName)
                MinimalDivider()
                toggleRow("Launch at login", systemName: "power", isOn: $appState.preferences.copilotLaunchAtLoginEnabled)
                    .onChange(of: appState.preferences.copilotLaunchAtLoginEnabled) {
                        appState.savePreferences()
                    }
                MinimalDivider()
                pickerRow("Web", systemName: "globe", selection: $appState.preferences.copilotWebMode) {
                    ForEach(CopilotWebMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                MinimalDivider()
                stepperRow("Notchly retention", systemName: "clock.arrow.circlepath", value: $appState.preferences.copilotRetentionDays, suffix: "days")
                MinimalDivider()
                pickerRow("Precision", systemName: "scope", selection: $appState.preferences.qaPrecisionMode) {
                    ForEach(QAPrecisionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                MinimalDivider()
                pickerRow("Local model", systemName: "brain", selection: $appState.preferences.localQuestionModelProfile) {
                    ForEach(LocalQuestionModelProfile.allCases) { profile in
                        Text(profile.displayName).tag(profile)
                    }
                }
                MinimalDivider()
                toggleRow("Model downloads", systemName: "arrow.down.circle", isOn: $appState.preferences.allowLocalModelDownloads)
                MinimalDivider()
                toggleRow("Shadow validation", systemName: "chart.xyaxis.line", isOn: $appState.preferences.qaShadowMode)
                MinimalDivider()
                actionRow("History", systemName: "trash") {
                    Button("Clear 7 days") { appState.clearCopilotHistory() }
                        .buttonStyle(MinimalButtonStyle(isDestructive: true))
                }
            }

            MinimalSection(title: "Notchly Quality") {
                diagnosticRow("Runtime", systemName: "dot.radiowaves.left.and.right", value: appState.copilotRuntimeState.displayText)
                MinimalDivider()
                diagnosticRow("Accepted", systemName: "checkmark.circle", value: "\(appState.copilotQualitySnapshot.acceptedCount)")
                MinimalDivider()
                diagnosticRow("Ignored", systemName: "moon", value: "\(appState.copilotQualitySnapshot.ignoredCount)")
                MinimalDivider()
                diagnosticRow("Failures", systemName: "exclamationmark.triangle", value: "\(appState.copilotQualitySnapshot.failureCount)")
                MinimalDivider()
                diagnosticRow("Latency p95", systemName: "speedometer", value: formatLatency(appState.copilotQualitySnapshot.p95LatencyMs))
                if let reason = appState.copilotQualitySnapshot.latestReason {
                    MinimalDivider()
                    diagnosticRow("Last decision", systemName: "list.bullet.clipboard", value: reason)
                }
            }

            MinimalSection(title: "Translation") {
                toggleRow("Live translation", systemName: "captions.bubble", isOn: $appState.preferences.liveTranslationEnabled)
                    .onChange(of: appState.preferences.liveTranslationEnabled) {
                        appState.setLiveTranslationEnabled(appState.preferences.liveTranslationEnabled)
                    }
                MinimalDivider()
                languagePickerRow("Translate to", systemName: "arrow.left.arrow.right", selection: $appState.preferences.targetLanguage)
                    .onChange(of: appState.preferences.targetLanguage) {
                        appState.savePreferences()
                        if appState.preferences.liveTranslationEnabled {
                            appState.prepareTranslationLanguages()
                            appState.sessionManager?.refreshTranslationsForCurrentMeeting()
                        }
                    }
                MinimalDivider()
                actionRow("Languages", systemName: "arrow.down.circle") {
                    if appState.isPreparingTranslationLanguages {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.72)
                        Text("Preparing")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(MinimalTheme.secondary)
                    } else {
                        Button("Prepare") { appState.prepareTranslationLanguages() }
                            .buttonStyle(MinimalButtonStyle())
                        Button("System Settings") { appState.openTranslationSystemSettings() }
                            .buttonStyle(MinimalButtonStyle())
                    }
                }
                if !appState.translationPreparationStatus.isEmpty {
                    MinimalDivider()
                    statusRow(appState.translationPreparationStatus, systemName: "info.circle")
                }
                MinimalDivider()
                toggleRow("Show original", systemName: "text.quote", isOn: $appState.preferences.showOriginalText)
                MinimalDivider()
                toggleRow("Show translation", systemName: "character.bubble", isOn: $appState.preferences.showTranslatedText)
            }
        }
    }

    private var audio: some View {
        VStack(spacing: 16) {
            MinimalSection(title: "Capture") {
                pickerRow("Mode", systemName: "waveform", selection: $appState.preferences.audioCaptureMode) {
                    ForEach(AudioCaptureMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                MinimalDivider()
                toggleRow("System audio", systemName: "speaker.wave.2", isOn: $appState.preferences.captureSystemAudio)
                MinimalDivider()
                toggleRow("Save recordings", systemName: "record.circle", isOn: $appState.preferences.saveAudioRecordings)
                MinimalDivider()
                toggleRow("Waveform", systemName: "waveform.path", isOn: $appState.preferences.showWaveform)
                MinimalDivider()
                pickerRow("Quality", systemName: "slider.horizontal.3", selection: transcriptionAccuracySelection) {
                    ForEach(TranscriptionAccuracyMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            }

            MinimalSection(title: "Transcription") {
                statusRow(appState.speechVocabularyStatus, systemName: "text.badge.checkmark")
                MinimalDivider()
                pickerRow("Commit", systemName: "checkmark.seal", selection: $appState.preferences.copilotASRCommitPolicy) {
                    ForEach(CopilotASRCommitPolicy.allCases) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                MinimalDivider()
                statusRow(transcriptionBackendStatus, systemName: "waveform.badge.magnifyingglass")
                MinimalDivider()
                statusRow(transcriptionPrivacyStatus, systemName: appState.preferences.localOnlyMode ? "lock.shield" : "cloud")
                if appState.preferences.localOnlyMode {
                    MinimalDivider()
                    statusRow("Custom vocabulary model eligible", systemName: "lock.shield")
                }
            }

            MinimalSection(title: "Permissions") {
                permissionRow("Microphone", systemName: "mic", granted: permissions.state.microphone) {
                    Task { await permissions.requestMicrophone() }
                }
                MinimalDivider()
                permissionRow("Speech Recognition", systemName: "text.quote", granted: permissions.state.speech) {
                    Task { await permissions.requestSpeech() }
                }
                MinimalDivider()
                permissionRow("Screen Recording", systemName: "rectangle.dashed", granted: permissions.state.screenCapture) {
                    permissions.requestScreenCapture()
                }
            }
        }
    }

    private var transcriptionAccuracySelection: Binding<TranscriptionAccuracyMode> {
        Binding(
            get: { appState.preferences.transcriptionAccuracyMode },
            set: { mode in
                appState.preferences.transcriptionAccuracyMode = mode
                appState.preferences.audioQuality = mode.legacyAudioQualityName
            }
        )
    }

    private var transcriptionBackendStatus: String {
        let engine = appState.capabilityReport?.transcriptionEngine.rawValue ?? "Apple Speech"
        let mode = appState.preferences.transcriptionAccuracyMode.displayName
        let commit = appState.preferences.copilotASRCommitPolicy.displayName
        return "\(mode) · \(commit) · \(engine)"
    }

    private var transcriptionPrivacyStatus: String {
        if appState.preferences.localOnlyMode {
            return "Local Only: remote ASR disabled"
        }
        return "Hybrid: cloud realtime when authenticated, Apple fallback"
    }

    private var speechVocabulary: some View {
        VStack(spacing: 16) {
            MinimalSection(title: "Add Term") {
                textRow("Term", systemName: "textformat", text: $speechTermText)
                MinimalDivider()
                textRow("Aliases", systemName: "text.badge.plus", text: $speechTermAliases)
                MinimalDivider()
                languagePickerRow("Language", systemName: "globe", selection: $speechTermLocale)
                MinimalDivider()
                pickerRow("Category", systemName: "tag", selection: $speechTermCategory) {
                    ForEach(SpeechVocabularyCategory.allCases) { category in
                        Text(category.displayName).tag(category)
                    }
                }
                MinimalDivider()
                baseRow("Boost", systemName: "slider.horizontal.3") {
                    Stepper(String(format: "%.1fx", speechTermBoost), value: $speechTermBoost, in: 0.1...3.0, step: 0.1)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MinimalTheme.secondary)
                        .frame(width: 160, alignment: .trailing)
                }
                MinimalDivider()
                textRow("X-SAMPA", systemName: "waveform", text: $speechTermPronunciation)
                MinimalDivider()
                textRow("Template", systemName: "text.insert", text: $speechTermTemplatePattern)
                MinimalDivider()
                textRow("Slots", systemName: "list.bullet.rectangle", text: $speechTermTemplateSlots)
                MinimalDivider()
                actionRow("Actions", systemName: "plus.circle") {
                    Button("Add") {
                        let aliases = speechTermAliases.split(separator: ",").map(String.init)
                        let templateSlots = speechTermTemplateSlots.split(separator: ",").map(String.init)
                        appState.saveSpeechVocabularyTerm(SpeechVocabularyTerm(
                            text: speechTermText,
                            locale: speechTermLocale,
                            category: speechTermCategory,
                            aliases: aliases,
                            pronunciationXSAMPA: speechTermPronunciation,
                            boost: speechTermBoost,
                            scope: .workspace,
                            scopeValue: appState.preferences.workspaceId,
                            templatePattern: speechTermTemplatePattern,
                            templateSlots: templateSlots
                        ))
                        speechTermText = ""
                        speechTermAliases = ""
                        speechTermPronunciation = ""
                        speechTermTemplatePattern = ""
                        speechTermTemplateSlots = ""
                    }
                    .buttonStyle(MinimalButtonStyle())
                    .disabled(SpeechVocabularyTerm.cleaned(speechTermText).isEmpty)

                    Button("Import CSV") {
                        if let csv = NSPasteboard.general.string(forType: .string) {
                            appState.importSpeechVocabularyCSV(csv)
                        }
                    }
                    .buttonStyle(MinimalButtonStyle())

                    Button("Copy CSV") {
                        appState.exportSpeechVocabularyCSVToPasteboard()
                    }
                    .buttonStyle(MinimalButtonStyle())
                }
            }

            MinimalSection(title: "Vocabulary") {
                textRow("Search", systemName: "magnifyingglass", text: $speechVocabularySearch)
                MinimalDivider()
                diagnosticRow("Status", systemName: "text.badge.checkmark", value: appState.speechVocabularyStatus)
                if filteredSpeechVocabularyTerms.isEmpty {
                    MinimalDivider()
                    emptyRow("No vocabulary terms match this search.")
                } else {
                    ForEach(filteredSpeechVocabularyTerms) { term in
                        MinimalDivider()
                        speechVocabularyTermRow(term)
                    }
                }
                MinimalDivider()
                actionRow("Maintenance", systemName: "trash") {
                    Button("Clear custom") {
                        appState.clearUserSpeechVocabulary()
                    }
                    .buttonStyle(MinimalButtonStyle(isDestructive: true))
                }
            }

            let suggestions = speechVocabularySuggestions
            if !suggestions.isEmpty {
                MinimalSection(title: "Suggestions") {
                    ForEach(suggestions) { suggestion in
                        speechVocabularySuggestionRow(suggestion)
                        if suggestion.id != suggestions.last?.id {
                            MinimalDivider()
                        }
                    }
                }
            }
        }
    }

    private var ai: some View {
        AIConnectionSettingsView(appState: appState)
    }

    private var privacy: some View {
        let diagnostics = PrivacyDiagnostics.snapshot(isStealthModeEnabled: appState.preferences.stealthModeEnabled)
        return VStack(spacing: 16) {
            MinimalSection(title: "Privacy") {
                toggleRow("Local Only Mode", systemName: "lock.shield", isOn: $appState.preferences.localOnlyMode)
                    .onChange(of: appState.preferences.localOnlyMode) {
                        if appState.preferences.localOnlyMode {
                            appState.preferences.aiConfig.cloudProcessingEnabled = false
                            appState.preferences.aiConfig.webSearchEnabled = false
                        }
                    }
                MinimalDivider()
                stepperRow("Retention", systemName: "clock.arrow.circlepath", value: $appState.preferences.retentionDays, suffix: "days")
                MinimalDivider()
                toggleRow("Recording indicator", systemName: "record.circle", isOn: $appState.preferences.showRecordingIndicator)
                MinimalDivider()
                toggleRow("Stealth Mode", systemName: "eye.slash", isOn: $appState.preferences.stealthModeEnabled)
                    .onChange(of: appState.preferences.stealthModeEnabled) {
                        appState.savePreferences()
                    }
                MinimalDivider()
                toggleRow("Keep code snippets local", systemName: "chevron.left.forwardslash.chevron.right", isOn: $appState.preferences.doNotSendCodeSnippetsToCloud)
            }

            MinimalSection(title: "Privacy Diagnostics") {
                diagnosticRow("Mode", systemName: "shield.lefthalf.filled", value: diagnostics.modeDisplayName)
                MinimalDivider()
                diagnosticRow("Capture policy", systemName: "camera.viewfinder", value: diagnostics.capturePolicySummary)
                MinimalDivider()
                diagnosticRow("Focus policy", systemName: "cursorarrow.rays", value: diagnostics.focusPolicySummary)
                MinimalDivider()
                diagnosticRow("Local encryption", systemName: "lock.doc", value: diagnostics.localEncryptionSummary)
                MinimalDivider()
                diagnosticRow("macOS", systemName: "desktopcomputer", value: diagnostics.macOSVersion)
                MinimalDivider()
                actionRow("Window audit", systemName: "list.bullet.rectangle") {
                    Text("\(diagnostics.protectedWindowCount)/\(diagnostics.windowAudits.count) protected")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MinimalTheme.secondary)
                    Button("Refresh") {
                        WindowCaptureProtection.applyToCurrentAppWindows(isEnabled: appState.preferences.stealthModeEnabled)
                        diagnosticsRefreshID = UUID()
                    }
                    .buttonStyle(MinimalButtonStyle())
                }
                if diagnostics.windowAudits.isEmpty {
                    MinimalDivider()
                    emptyRow("No protected windows have been audited yet.")
                } else {
                    ForEach(diagnostics.windowAudits) { audit in
                        MinimalDivider()
                        windowAuditRow(audit)
                    }
                }
            }
            .id(diagnosticsRefreshID)

            MinimalSection(title: "Validation Limits") {
                ForEach(Array(diagnostics.limitations.enumerated()), id: \.offset) { index, limitation in
                    limitationRow(limitation)
                    if index < diagnostics.limitations.count - 1 {
                        MinimalDivider()
                    }
                }
            }

            MinimalSection(title: "Manual Validation") {
                ForEach(Array(diagnostics.manualValidationItems.enumerated()), id: \.element.id) { index, item in
                    validationItemRow(item)
                    if index < diagnostics.manualValidationItems.count - 1 {
                        MinimalDivider()
                    }
                }
            }

            MinimalSection(title: "Access") {
                permissionRow("Calendar", systemName: "calendar", granted: permissions.state.calendar) {
                    Task { await permissions.requestCalendar() }
                }
                MinimalDivider()
                actionRow("Data", systemName: "externaldrive") {
                    Button("Export") { appState.openHistoryHandler?() }
                        .buttonStyle(MinimalButtonStyle())
                    Button("Delete All") { appState.deleteAllData() }
                        .buttonStyle(MinimalButtonStyle(isDestructive: true))
                }
            }
        }
    }

    private var knowledge: some View {
        VStack(spacing: 16) {
            MinimalSection(title: "Local Knowledge") {
                actionRow("Files", systemName: "doc.badge.plus") {
                    Button("Add") { fileImporterPresented = true }
                        .buttonStyle(MinimalButtonStyle())
                    Button("Reindex") { appState.reloadKnowledgeDocuments() }
                        .buttonStyle(MinimalButtonStyle())
                    Button("Clear") { appState.clearKnowledge() }
                        .buttonStyle(MinimalButtonStyle(isDestructive: true))
                }
            }

            MinimalSection(title: "Indexed") {
                if appState.knowledgeDocumentNames.isEmpty {
                    emptyRow("No local documents indexed yet.")
                } else {
                    ForEach(Array(appState.knowledgeDocumentNames.enumerated()), id: \.offset) { index, name in
                        labelRow(name, systemName: "doc.text")
                        if index < appState.knowledgeDocumentNames.count - 1 {
                            MinimalDivider()
                        }
                    }
                }
            }
        }
    }

    private var technicalRows: some View {
        let report = appState.capabilityReport
        return VStack(spacing: 0) {
            engineRow("Transcription", engine: report?.transcriptionEngine ?? .unavailable, mode: report?.transcriptionMode ?? .unavailable)
            MinimalDivider()
            engineRow("Translation", engine: report?.translationEngine ?? .appleTranslation, mode: report?.translationMode ?? .local)
            MinimalDivider()
            engineRow("Summary", engine: report?.summaryEngine ?? .unavailable, mode: report?.summaryMode ?? .unavailable)
            MinimalDivider()
            engineRow("Language", engine: report?.languageDetectionEngine ?? .appleNaturalLanguage, mode: .local)
            MinimalDivider()
            engineRow("Audio", engine: report?.audioCaptureEngine ?? .avFoundationScreenCaptureKit, mode: .local)
        }
    }

    private func baseRow<Accessory: View>(_ title: String, systemName: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(spacing: 11) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MinimalTheme.secondary)
                .frame(width: 18)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(MinimalTheme.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
            Spacer(minLength: 12)
            accessory()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 42)
    }

    private func toggleRow(_ title: String, systemName: String, isOn: Binding<Bool>) -> some View {
        baseRow(title, systemName: systemName) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.gray)
                .scaleEffect(0.82)
        }
    }

    private func textRow(_ title: String, systemName: String, text: Binding<String>) -> some View {
        baseRow(title, systemName: systemName) {
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MinimalTheme.primary)
                .multilineTextAlignment(.trailing)
                .frame(width: 260)
        }
    }

    private func secureRow(_ title: String, systemName: String, text: Binding<String>) -> some View {
        baseRow(title, systemName: systemName) {
            SecureField("", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MinimalTheme.primary)
                .multilineTextAlignment(.trailing)
                .frame(width: 260)
        }
    }

    private func pickerRow<Selection: Hashable, Content: View>(_ title: String, systemName: String, selection: Binding<Selection>, @ViewBuilder content: () -> Content) -> some View {
        baseRow(title, systemName: systemName) {
            Picker("", selection: selection, content: content)
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 230, alignment: .trailing)
        }
    }

    private func languagePickerRow(_ title: String, systemName: String, selection: Binding<String>) -> some View {
        pickerRow(title, systemName: systemName, selection: selection) {
            ForEach(SupportedLanguage.allCases) { language in
                Text(language.displayName).tag(language.rawValue)
            }
        }
    }

    private func stepperRow(_ title: String, systemName: String, value: Binding<Int>, suffix: String) -> some View {
        baseRow(title, systemName: systemName) {
            Stepper("\(value.wrappedValue) \(suffix)", value: value, in: 0...365)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MinimalTheme.secondary)
                .frame(width: 170, alignment: .trailing)
        }
    }

    private func permissionRow(_ title: String, systemName: String, granted: Bool, action: @escaping () -> Void) -> some View {
        baseRow(title, systemName: systemName) {
            HStack(spacing: 8) {
                Label(granted ? "Granted" : "Needed", systemImage: granted ? "checkmark.circle" : "circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(granted ? MinimalTheme.primary : MinimalTheme.secondary)
                Button("Request", action: action)
                    .buttonStyle(MinimalButtonStyle())
            }
        }
    }

    private func actionRow<Actions: View>(_ title: String, systemName: String, @ViewBuilder actions: () -> Actions) -> some View {
        baseRow(title, systemName: systemName) {
            HStack(spacing: 8) {
                actions()
            }
        }
    }

    private func statusRow(_ text: String, systemName: String) -> some View {
        baseRow("Status", systemName: systemName) {
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MinimalTheme.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
    }

    private func diagnosticRow(_ title: String, systemName: String, value: String) -> some View {
        baseRow(title, systemName: systemName) {
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MinimalTheme.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
    }

    private var filteredSpeechVocabularyTerms: [SpeechVocabularyTerm] {
        let query = speechVocabularySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return appState.speechVocabularyTerms }
        return appState.speechVocabularyTerms.filter { term in
            ([term.text] + term.aliases + [term.category.displayName, term.locale ?? ""])
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var speechVocabularySuggestions: [SpeechVocabularyTerm] {
        let segments = appState.currentMeeting?.transcriptSegments ?? appState.selectedMeeting?.transcriptSegments ?? []
        return appState.speechVocabularyStore?.suggestedTerms(
            from: segments,
            locale: appState.preferences.defaultLanguage,
            limit: 6
        ) ?? []
    }

    private func speechVocabularyTermRow(_ term: SpeechVocabularyTerm) -> some View {
        HStack(spacing: 11) {
            Image(systemName: term.enabled ? "text.badge.checkmark" : "text.badge.xmark")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MinimalTheme.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(term.text)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MinimalTheme.primary)
                    .lineLimit(1)
                Text("\(term.category.displayName) • \(term.locale ?? "Any") • \(String(format: "%.1fx", term.boost))\(term.templatePattern == nil ? "" : " • Template")")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MinimalTheme.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 10)
            if term.isSystemSeed {
                Text("System")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MinimalTheme.tertiary)
            } else {
                Button("Delete") {
                    appState.deleteSpeechVocabularyTerm(term)
                }
                .buttonStyle(MinimalButtonStyle(isDestructive: true))
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 46)
    }

    private func speechVocabularySuggestionRow(_ suggestion: SpeechVocabularyTerm) -> some View {
        actionRow(suggestion.text, systemName: "sparkle.magnifyingglass") {
            Button("Add") {
                appState.saveSpeechVocabularyTerm(suggestion)
            }
            .buttonStyle(MinimalButtonStyle())
        }
    }

    private func formatLatency(_ value: Double) -> String {
        value <= 0 ? "-" : "\(Int(value.rounded())) ms"
    }

    private func windowAuditRow(_ audit: WindowCaptureProtectionAudit) -> some View {
        baseRow(audit.role.displayName, systemName: audit.isSharingBlocked ? "eye.slash" : "eye") {
            VStack(alignment: .trailing, spacing: 2) {
                Text(audit.windowTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MinimalTheme.secondary)
                    .lineLimit(1)
                Text("\(audit.sharingTypeDescription) · \(audit.lastAppliedAt.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(MinimalTheme.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private func limitationRow(_ text: String) -> some View {
        baseRow("Limit", systemName: "exclamationmark.triangle") {
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MinimalTheme.secondary)
                .lineLimit(3)
                .multilineTextAlignment(.trailing)
        }
    }

    private func validationItemRow(_ item: PrivacyManualValidationItem) -> some View {
        baseRow(item.title, systemName: "checklist") {
            Text(item.expectedResult)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MinimalTheme.secondary)
                .lineLimit(3)
                .multilineTextAlignment(.trailing)
        }
    }

    private func labelRow(_ title: String, systemName: String) -> some View {
        baseRow(title, systemName: systemName) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MinimalTheme.secondary)
        }
    }

    private func emptyRow(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(MinimalTheme.tertiary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    private func engineRow(_ feature: String, engine: EngineName, mode: ProcessingMode) -> some View {
        HStack(spacing: 11) {
            Image(systemName: mode == .cloud ? "icloud" : "cpu")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MinimalTheme.secondary)
                .frame(width: 18)
            Text(feature)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(MinimalTheme.primary)
                .frame(width: 100, alignment: .leading)
            Text(engine.rawValue)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MinimalTheme.secondary)
                .lineLimit(1)
            Spacer()
            Text(mode.rawValue.capitalized)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MinimalTheme.tertiary)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
    }

    private func optionalString(_ source: Binding<String?>) -> Binding<String> {
        Binding<String>(
            get: { source.wrappedValue ?? "" },
            set: { source.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }
}

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case audio
    case ai
    case speechVocabulary
    case privacy
    case knowledge

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .audio: "Audio"
        case .ai: "AI"
        case .speechVocabulary: "Speech Vocabulary"
        case .privacy: "Privacy"
        case .knowledge: "Knowledge"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Meeting behavior and user context"
        case .audio: "Capture modes, waveform and permissions"
        case .ai: "Local first routing and optional cloud provider"
        case .speechVocabulary: "Terms that improve Apple Speech accuracy"
        case .privacy: "Retention, access and local-only controls"
        case .knowledge: "Private files used for local context"
        }
    }

    var systemName: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .audio: "waveform"
        case .ai: "sparkles"
        case .speechVocabulary: "text.badge.plus"
        case .privacy: "lock.shield"
        case .knowledge: "books.vertical"
        }
    }
}
