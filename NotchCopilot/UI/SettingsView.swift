import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @StateObject private var permissions = PermissionsManager()
    @StateObject private var audioDevices = AudioDeviceManager()
    @Namespace private var tabNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedPane: SettingsPane = .general
    @State private var hoveredPane: SettingsPane?

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(MinimalTheme.divider)
                .frame(height: 0.6)
            content
        }
        .background(MinimalTheme.background)
        .foregroundStyle(MinimalTheme.primary)
        .preferredColorScheme(.dark)
        .frame(minWidth: 920, minHeight: 640)
        .onAppear {
            permissions.refresh()
            audioDevices.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
            audioDevices.refresh()
        }
    }

    private var header: some View {
        VStack(spacing: 18) {
            HStack(spacing: 9) {
                NotchMark()
                    .frame(width: 28, height: 14)
                Text("Notchly Settings")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(MinimalTheme.primary)
            }
            .padding(.top, 8)

            HStack(spacing: 34) {
                ForEach(SettingsPane.allCases) { pane in
                    tabButton(pane)
                }
            }
        }
        .padding(.top, 18)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .background(MinimalTheme.sidebar.opacity(0.18))
    }

    private func tabButton(_ pane: SettingsPane) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.86)) {
                selectedPane = pane
            }
        } label: {
            VStack(spacing: 7) {
                Image(systemName: pane.systemName)
                    .font(.system(size: 24, weight: .semibold))
                Text(pane.title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(selectedPane == pane ? MinimalTheme.primary : MinimalTheme.secondary)
            .frame(width: 106, height: 74)
            .background {
                if selectedPane == pane {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(MinimalTheme.settingsControlPressed)
                        .matchedGeometryEffect(id: "selected-tab", in: tabNamespace)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.white.opacity(0.11), lineWidth: 0.8)
                        )
                } else if hoveredPane == pane {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(MinimalTheme.settingsControl.opacity(0.72))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                hoveredPane = isHovered ? pane : nil
            }
        }
        .help(pane.title)
    }

    private var content: some View {
        ScrollView {
            ZStack {
                paneContent
                    .id(selectedPane)
                    .transition(reduceMotion ? .identity : .asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .trailing)),
                        removal: .opacity.combined(with: .move(edge: .leading))
                    ))
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: selectedPane)
            .frame(maxWidth: 650)
            .padding(.top, 42)
            .padding(.bottom, 42)
            .frame(maxWidth: .infinity)
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
            AIConnectionSettingsView(appState: appState)
        case .knowledge:
            knowledge
        case .privacy:
            privacy
        case .about:
            about
        }
    }

    private var general: some View {
        VStack(spacing: 30) {
            EssentialSection(title: "Startup") {
                settingsToggleRow("Launch at login", isOn: launchAtLoginBinding)
                SettingsDivider()
                settingsToggleRow("Auto-detect meetings", isOn: $appState.preferences.autoDetectMeetings)
                SettingsDivider()
                settingsToggleRow("Confirm before recording", isOn: $appState.preferences.requireConfirmationBeforeRecording)
            }

            EssentialSection(title: "Notchly") {
                settingsToggleRow("Hotkey", isOn: $appState.preferences.copilotHotkeyEnabled)
                    .onChange(of: appState.preferences.copilotHotkeyEnabled) {
                        appState.savePreferences()
                    }
                SettingsDivider()
                settingsValueRow("Shortcut") {
                    Text(CopilotHotkeyDescriptor.default.displayName)
                        .settingsSecondaryText()
                }
                SettingsDivider()
                settingsMenuRow("Island design", selection: $appState.preferences.islandDesignMode, options: islandDesignOptions)
            }
        }
    }

    private var audio: some View {
        VStack(spacing: 30) {
            audioStatus

            EssentialSection(title: "Capture") {
                settingsMenuRow("Capture mode", selection: audioCaptureModeBinding, options: captureModeOptions)
                SettingsDivider()
                devicePickerRow("Input device", direction: .input, selection: inputDeviceSelection)
                SettingsDivider()
                devicePickerRow("Output device", direction: .output, selection: outputDeviceSelection)
            }

            EssentialSection(title: "Transcription") {
                settingsMenuRow("Language", selection: transcriptionLanguageSelection, options: languageOptions)
                SettingsDivider()
                settingsMenuRow("Meeting type", selection: transcriptionMeetingTypeSelection, options: meetingTypeOptions)
                SettingsDivider()
                settingsSegmentedRow("Quality", selection: transcriptionAccuracySelection, options: transcriptionQualityOptions)
                SettingsDivider()
                settingsSegmentedRow("Commit", selection: $appState.preferences.copilotASRCommitPolicy, options: commitPolicyOptions)
            }

            EssentialSection(title: "Output") {
                settingsToggleRow("Save recordings", isOn: $appState.preferences.saveAudioRecordings)
                SettingsDivider()
                settingsToggleRow("Waveform", isOn: $appState.preferences.showWaveform)
            }

            EssentialSection(title: "Permissions") {
                permissionRow("Microphone", granted: permissions.state.microphone) {
                    Task { await permissions.requestMicrophone() }
                }
                SettingsDivider()
                permissionRow("Speech Recognition", granted: permissions.state.speech) {
                    Task { await permissions.requestSpeech() }
                }
                SettingsDivider()
                permissionRow("Screen Recording", granted: permissions.state.screenCapture) {
                    permissions.requestScreenCapture()
                }
            }
        }
    }

    private var audioStatus: some View {
        HStack(spacing: 14) {
            AudioMicroWaveform(isActive: appState.currentMeeting?.status == .listening)
                .frame(width: 96, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(audioStatusTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(MinimalTheme.primary)
                    .lineLimit(1)
                Text(audioStatusDetail)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(MinimalTheme.secondary)
                    .lineLimit(1)
            }
            Spacer()
            statusChip(appState.currentMeeting?.status == .listening ? "Live" : "Ready", isPositive: true)
        }
        .padding(.horizontal, 16)
        .frame(height: 58)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(MinimalTheme.surface.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.075), lineWidth: 0.7)
        )
    }

    private var privacy: some View {
        VStack(spacing: 30) {
            EssentialSection(title: "Privacy") {
                settingsStepperRow("Retention", value: $appState.preferences.retentionDays, range: 1...365, suffix: "days")
                SettingsDivider()
                settingsToggleRow("Recording indicator", isOn: $appState.preferences.showRecordingIndicator)
                SettingsDivider()
                settingsToggleRow("Stealth Mode", isOn: $appState.preferences.stealthModeEnabled)
                    .onChange(of: appState.preferences.stealthModeEnabled) {
                        appState.savePreferences()
                    }
                SettingsDivider()
                settingsToggleRow("Keep code snippets local", isOn: $appState.preferences.doNotSendCodeSnippetsToCloud)
            }

            EssentialSection(title: "Data") {
                settingsValueRow("Local history") {
                    HStack(spacing: 8) {
                        Button("Export") { appState.openHistoryHandler?() }
                            .buttonStyle(SettingsPillButtonStyle())
                        Button("Delete All") { appState.deleteAllData() }
                            .buttonStyle(SettingsPillButtonStyle(isDestructive: true))
                    }
                }
            }
        }
    }

    private var knowledge: some View {
        VStack(spacing: 30) {
            EssentialSection(title: "Sources") {
                settingsToggleRow("Knowledge sources", isOn: $appState.preferences.knowledgeSourcesEnabled)
                SettingsDivider()
                settingsValueRow("Connected") {
                    Text("\(appState.knowledgeSources.count) sources")
                        .settingsSecondaryText()
                }
                SettingsDivider()
                settingsValueRow("Index health") {
                    HStack(spacing: 8) {
                        Text(appState.retrievalStatus.detail)
                            .settingsSecondaryText()
                            .lineLimit(1)
                        statusChip(knowledgeHealthStatus.text, isPositive: knowledgeHealthStatus.isPositive)
                    }
                }
                SettingsDivider()
                settingsMenuRow("Copilot scope", selection: $appState.preferences.copilotKnowledgeScope, options: knowledgeScopeOptions)
            }

            EssentialSection(title: "Retrieval") {
                settingsStepperRow("Results", value: $appState.preferences.ragDefaultResultLimit, range: 3...12, suffix: "")
                SettingsDivider()
                settingsMenuRow("Embedding", selection: localEmbeddingTierSelection, options: localEmbeddingTierOptions)
                SettingsDivider()
                settingsMenuRow("Runtime", selection: localEmbeddingRuntimeSelection, options: localEmbeddingRuntimeOptions)
                SettingsDivider()
                appleMetalAccelerationRow
                SettingsDivider()
                settingsToggleRow("Model downloads", isOn: allowLocalModelDownloadsSelection)
                SettingsDivider()
                settingsToggleRow("Local server", isOn: localEmbeddingServerEnabledSelection)
                SettingsDivider()
                settingsTextRow("Endpoint", text: localEmbeddingServerEndpointSelection, placeholder: LocalEmbeddingServerConfiguration.defaultEndpoint)
                SettingsDivider()
                settingsTextRow("Server model", text: localEmbeddingServerModelSelection, placeholder: LocalEmbeddingServerConfiguration.defaultModel)
                SettingsDivider()
                settingsTextRow("Server dims", text: localEmbeddingServerDimensionsSelection, placeholder: "\(appState.preferences.ragLocalEmbeddingTier.dimensions)")
                SettingsDivider()
                settingsValueRow("Runtime status") {
                    statusChip(localEmbeddingRuntimeStatus.text, isPositive: localEmbeddingRuntimeStatus.isReady)
                }
                SettingsDivider()
                settingsValueRow("Benchmark") {
                    HStack(spacing: 8) {
                        statusChip(appState.preferences.ragLocalEmbeddingBenchmark?.summary ?? "Pending", isPositive: appState.preferences.ragLocalEmbeddingBenchmark != nil)
                        Button("Run") { appState.runLocalEmbeddingBenchmark() }
                            .buttonStyle(SettingsPillButtonStyle())
                    }
                }
                SettingsDivider()
                settingsToggleRow("Local rerank", isOn: $appState.preferences.ragLocalRerankEnabled)
                SettingsDivider()
                settingsStepperRow("Realtime target", value: $appState.preferences.ragRealtimeLatencyTargetMs, range: 120...500, suffix: "ms")
                SettingsDivider()
                settingsStepperRow("Chunk size", value: $appState.preferences.ragChunkTargetTokens, range: 300...1400, suffix: "tokens")
                SettingsDivider()
                settingsStepperRow("Overlap", value: $appState.preferences.ragChunkOverlapTokens, range: 0...700, suffix: "tokens")
            }
        }
        .onAppear {
            appState.reloadKnowledgeDocuments()
        }
    }

    private var about: some View {
        VStack(spacing: 30) {
            VStack(spacing: 16) {
                Image("NotchIcon")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 66, height: 34)
                    .foregroundStyle(MinimalTheme.notchAccent)
                VStack(spacing: 5) {
                    Text("Notchly")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(MinimalTheme.primary)
                    Text("Version \(appVersion)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(MinimalTheme.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 38)

            EssentialSection(title: "Links") {
                settingsValueRow("Website") {
                    Button("Visit Website") { openURL("https://github.com/ryan-mf-eloy/Notchly") }
                        .buttonStyle(SettingsPillButtonStyle())
                }
                SettingsDivider()
                settingsValueRow("Feedback") {
                    Button("Send Feedback") { openURL("https://github.com/ryan-mf-eloy/Notchly/issues") }
                        .buttonStyle(SettingsPillButtonStyle())
                }
            }
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { appState.preferences.launchAtLogin || appState.preferences.copilotLaunchAtLoginEnabled },
            set: { value in
                appState.preferences.launchAtLogin = value
                appState.preferences.copilotLaunchAtLoginEnabled = value
                appState.savePreferences()
            }
        )
    }

    private var audioCaptureModeBinding: Binding<AudioCaptureMode> {
        Binding(
            get: { appState.preferences.audioCaptureMode },
            set: { mode in
                appState.preferences.audioCaptureMode = mode
                appState.preferences.captureSystemAudio = mode != .microphoneOnly
                appState.savePreferences()
            }
        )
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

    private var transcriptionLanguageSelection: Binding<String> {
        Binding(
            get: {
                SupportedLanguage.normalizedCode(appState.currentMeeting?.primaryLanguage ?? appState.preferences.defaultLanguage)
            },
            set: { language in
                appState.updateTranscriptionLanguage(language)
            }
        )
    }

    private var transcriptionMeetingTypeSelection: Binding<MeetingType> {
        Binding(
            get: {
                appState.currentMeeting?.meetingType ?? appState.preferences.defaultMeetingType
            },
            set: { meetingType in
                appState.updateTranscriptionMeetingType(meetingType)
            }
        )
    }

    private var localEmbeddingTierSelection: Binding<LocalEmbeddingTier> {
        Binding(
            get: { appState.preferences.ragLocalEmbeddingTier },
            set: { tier in
                guard appState.preferences.ragLocalEmbeddingTier != tier else { return }
                appState.preferences.ragLocalEmbeddingTier = tier
                appState.preferences.ragLocalEmbeddingBenchmark = nil
                appState.savePreferences()
                appState.reloadKnowledgeDocuments()
            }
        )
    }

    private var localEmbeddingRuntimeSelection: Binding<LocalEmbeddingRuntimeKind> {
        Binding(
            get: { appState.preferences.ragLocalEmbeddingRuntime },
            set: { runtime in
                let canSelectMLX = appState.preferences.ragAppleMetalAccelerationEnabled &&
                    LocalEmbeddingModelManager.supportsMetalAcceleration
                guard runtime != .mlx || canSelectMLX else { return }
                guard appState.preferences.ragLocalEmbeddingRuntime != runtime else { return }
                appState.preferences.ragLocalEmbeddingRuntime = runtime
                appState.preferences.ragLocalEmbeddingBenchmark = nil
                appState.savePreferences()
                appState.reloadKnowledgeDocuments()
            }
        )
    }

    private var appleMetalAccelerationSelection: Binding<Bool> {
        Binding(
            get: { appState.preferences.ragAppleMetalAccelerationEnabled },
            set: { isEnabled in
                guard appState.preferences.ragAppleMetalAccelerationEnabled != isEnabled else { return }
                appState.preferences.ragAppleMetalAccelerationEnabled = isEnabled
                if !isEnabled && appState.preferences.ragLocalEmbeddingRuntime == .mlx {
                    appState.preferences.ragLocalEmbeddingRuntime = .automatic
                }
                invalidateLocalEmbeddingRuntime()
            }
        )
    }

    private var allowLocalModelDownloadsSelection: Binding<Bool> {
        Binding(
            get: { appState.preferences.allowLocalModelDownloads },
            set: { isAllowed in
                guard appState.preferences.allowLocalModelDownloads != isAllowed else { return }
                appState.preferences.allowLocalModelDownloads = isAllowed
                appState.preferences.ragLocalEmbeddingBenchmark = nil
                appState.savePreferences()
                appState.reloadKnowledgeDocuments()
            }
        )
    }

    private var localEmbeddingServerEnabledSelection: Binding<Bool> {
        Binding(
            get: { appState.preferences.ragLocalEmbeddingServerEnabled },
            set: { isEnabled in
                guard appState.preferences.ragLocalEmbeddingServerEnabled != isEnabled else { return }
                appState.preferences.ragLocalEmbeddingServerEnabled = isEnabled
                invalidateLocalEmbeddingRuntime()
            }
        )
    }

    private var localEmbeddingServerEndpointSelection: Binding<String> {
        Binding(
            get: { appState.preferences.ragLocalEmbeddingServerEndpoint },
            set: { endpoint in
                appState.preferences.ragLocalEmbeddingServerEndpoint = endpoint
                invalidateLocalEmbeddingRuntime(reload: false)
            }
        )
    }

    private var localEmbeddingServerModelSelection: Binding<String> {
        Binding(
            get: { appState.preferences.ragLocalEmbeddingServerModel },
            set: { model in
                appState.preferences.ragLocalEmbeddingServerModel = model
                invalidateLocalEmbeddingRuntime(reload: false)
            }
        )
    }

    private var localEmbeddingServerDimensionsSelection: Binding<String> {
        Binding(
            get: {
                let dimensions = appState.preferences.ragLocalEmbeddingServerDimensions
                return dimensions > 0 ? "\(dimensions)" : ""
            },
            set: { value in
                let digits = value.filter(\.isNumber)
                appState.preferences.ragLocalEmbeddingServerDimensions = Int(digits) ?? 0
                invalidateLocalEmbeddingRuntime(reload: false)
            }
        )
    }

    private var localEmbeddingRuntimeStatus: (text: String, isReady: Bool) {
        let preferences = appState.preferences
        let manager = LocalEmbeddingModelManager()
        let provider = LocalEmbeddingProvider(
            tier: preferences.ragLocalEmbeddingTier,
            runtime: preferences.resolvedLocalEmbeddingRuntime,
            allowModelDownloads: preferences.allowLocalModelDownloads,
            allowMetalAcceleration: preferences.ragAppleMetalAccelerationEnabled,
            serverConfiguration: preferences.localEmbeddingServerConfiguration
        )
        let runtime = provider.activeRuntime
        if runtime == .localServer {
            let configuration = preferences.localEmbeddingServerConfiguration
            if configuration.isUsable {
                return ("Local server \(provider.dimensions)d ready", true)
            }
            return ("Local server not configured", false)
        }
        return (
            manager.statusText(
                tier: preferences.ragLocalEmbeddingTier,
                runtime: runtime,
                allowDownloads: preferences.allowLocalModelDownloads,
                allowMetalAcceleration: preferences.ragAppleMetalAccelerationEnabled
            ),
            runtime != .mlx || manager.isUsable(
                tier: preferences.ragLocalEmbeddingTier,
                runtime: runtime,
                allowDownloads: preferences.allowLocalModelDownloads,
                allowMetalAcceleration: preferences.ragAppleMetalAccelerationEnabled
            )
        )
    }

    private var knowledgeHealthStatus: (text: String, isPositive: Bool) {
        if appState.retrievalStatus.isIndexing {
            return ("Syncing", false)
        }
        if appState.retrievalStatus.title == "Knowledge needs attention" {
            return ("Attention", false)
        }
        if appState.knowledgeSources.isEmpty {
            return ("Empty", false)
        }
        return ("Ready", true)
    }

    private var knowledgeScopeOptions: [SettingsMenuOption<KnowledgeCopilotScope>] {
        KnowledgeCopilotScope.allCases.map {
            SettingsMenuOption(value: $0, title: $0.displayName, systemImage: $0 == .selectedSource ? "archivebox" : ($0 == .currentMeeting ? "waveform.and.mic" : "square.stack.3d.up"))
        }
    }

    private var localEmbeddingTierOptions: [SettingsMenuOption<LocalEmbeddingTier>] {
        LocalEmbeddingTier.allCases.map {
            SettingsMenuOption(value: $0, title: $0.displayName, subtitle: "\($0.modelProfile.displayName) - \($0.dimensions)d", systemImage: $0.systemImage)
        }
    }

    private var localEmbeddingRuntimeOptions: [SettingsMenuOption<LocalEmbeddingRuntimeKind>] {
        LocalEmbeddingRuntimeKind.allCases.map {
            let isMLXRuntime = $0 == .mlx
            let isMetalEnabled = appState.preferences.ragAppleMetalAccelerationEnabled
            let isMetalAvailable = LocalEmbeddingModelManager.supportsMetalAcceleration
            let isMLXUnavailable = isMLXRuntime && (!isMetalEnabled || !isMetalAvailable)
            let subtitle: String? = if $0 == .automatic {
                "Benchmarked"
            } else if $0 == .mlx {
                if !isMetalEnabled {
                    "Apple Metal disabled"
                } else if !isMetalAvailable {
                    "Apple Metal unavailable"
                } else {
                    "Apple Metal"
                }
            } else if $0 == .localServer {
                "localhost only"
            } else {
                nil
            }
            return SettingsMenuOption(
                value: $0,
                title: $0.displayName,
                subtitle: subtitle,
                systemImage: $0.systemImage,
                isUnavailable: isMLXUnavailable
            )
        }
    }

    private func invalidateLocalEmbeddingRuntime(reload: Bool = true) {
        appState.preferences.ragLocalEmbeddingBenchmark = nil
        appState.savePreferences()
        if reload {
            appState.reloadKnowledgeDocuments()
        }
    }

    private var inputDeviceSelection: Binding<String> {
        deviceSelectionBinding(\.selectedInputDeviceUID)
    }

    private var outputDeviceSelection: Binding<String> {
        deviceSelectionBinding(\.selectedOutputDeviceUID)
    }

    private var languageOptions: [SettingsMenuOption<String>] {
        SupportedLanguage.allCases.map { language in
            SettingsMenuOption(
                value: language.rawValue,
                title: language.displayName,
                systemImage: "textformat"
            )
        }
    }

    private var meetingTypeOptions: [SettingsMenuOption<MeetingType>] {
        MeetingType.allCases.map { type in
            SettingsMenuOption(
                value: type,
                title: type.displayName,
                systemImage: "person.2"
            )
        }
    }

    private var islandDesignOptions: [SettingsMenuOption<IslandDesignMode>] {
        IslandDesignMode.allCases.map { mode in
            SettingsMenuOption(
                value: mode,
                title: mode.displayName,
                systemImage: mode == .liquidGlass ? "circle.hexagongrid" : "capsule"
            )
        }
    }

    private var captureModeOptions: [SettingsMenuOption<AudioCaptureMode>] {
        AudioCaptureMode.allCases.map { mode in
            SettingsMenuOption(
                value: mode,
                title: mode.displayName,
                systemImage: captureModeSystemImage(mode)
            )
        }
    }

    private var transcriptionQualityOptions: [SettingsMenuOption<TranscriptionAccuracyMode>] {
        TranscriptionAccuracyMode.allCases.map { mode in
            SettingsMenuOption(value: mode, title: mode.displayName)
        }
    }

    private var commitPolicyOptions: [SettingsMenuOption<CopilotASRCommitPolicy>] {
        CopilotASRCommitPolicy.allCases.map { policy in
            SettingsMenuOption(value: policy, title: policy.displayName)
        }
    }

    private func deviceSelectionBinding(_ keyPath: WritableKeyPath<AppPreferences, String?>) -> Binding<String> {
        Binding(
            get: { appState.preferences[keyPath: keyPath] ?? AudioDevicePickerSentinel.systemDefault },
            set: { value in
                appState.preferences[keyPath: keyPath] = value == AudioDevicePickerSentinel.systemDefault ? nil : value
                appState.savePreferences()
            }
        )
    }

    private var audioStatusTitle: String {
        let input = audioDevices.deviceName(for: appState.preferences.selectedInputDeviceUID, direction: .input)
        let output = audioDevices.deviceName(for: appState.preferences.selectedOutputDeviceUID, direction: .output)
        switch appState.preferences.audioCaptureMode {
        case .microphoneOnly:
            return "Listening from \(cleanDefaultLabel(input))"
        case .systemOnly:
            return "Capturing \(cleanDefaultLabel(output))"
        case .microphoneAndSystem:
            return "Mic + system ready"
        }
    }

    private var audioStatusDetail: String {
        let input = audioDevices.deviceName(for: appState.preferences.selectedInputDeviceUID, direction: .input)
        let output = audioDevices.deviceName(for: appState.preferences.selectedOutputDeviceUID, direction: .output)
        return "Input: \(cleanDefaultLabel(input)) • Output: \(cleanDefaultLabel(output))"
    }

    private func cleanDefaultLabel(_ label: String) -> String {
        label
            .replacingOccurrences(of: "System Default (", with: "")
            .replacingOccurrences(of: ")", with: "")
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    private func devicePickerRow(_ title: String, direction: AudioDeviceDirection, selection: Binding<String>) -> some View {
        settingsValueRow(title) {
            SettingsMenuSelector(
                selection: selection,
                options: deviceOptions(for: direction, selectedValue: selection.wrappedValue),
                width: SettingsLayout.controlWidth
            )
        }
    }

    private func deviceOptions(for direction: AudioDeviceDirection, selectedValue: String) -> [SettingsMenuOption<String>] {
        let devices = audioDevices.devices(for: direction)
        let selectedUID = selectedValue == AudioDevicePickerSentinel.systemDefault ? nil : selectedValue
        var options: [SettingsMenuOption<String>] = [
            SettingsMenuOption(
                value: AudioDevicePickerSentinel.systemDefault,
                title: "System Default",
                subtitle: audioDevices.defaultDeviceName(for: direction),
                systemImage: deviceSystemImage(for: direction)
            )
        ]

        options.append(contentsOf: devices.map { device in
            SettingsMenuOption(
                value: device.uid,
                title: device.name,
                subtitle: device.isDefault ? "Default" : nil,
                systemImage: deviceSystemImage(for: direction)
            )
        })

        if let selectedUID, !audioDevices.isAvailable(selectedUID, direction: direction) {
            options.append(
                SettingsMenuOption(
                    value: selectedUID,
                    title: "Disconnected device",
                    subtitle: selectedUID,
                    systemImage: "exclamationmark.triangle",
                    isUnavailable: true
                )
            )
        }

        return options
    }

    private func systemDefaultLabel(for direction: AudioDeviceDirection) -> String {
        if let name = audioDevices.defaultDeviceName(for: direction) {
            return "System Default — \(name)"
        }
        return "System Default"
    }

    private func deviceSystemImage(for direction: AudioDeviceDirection) -> String {
        switch direction {
        case .input: "mic"
        case .output: "speaker.wave.2"
        }
    }

    private func captureModeSystemImage(_ mode: AudioCaptureMode) -> String {
        switch mode {
        case .microphoneOnly: "mic"
        case .systemOnly: "speaker.wave.2"
        case .microphoneAndSystem: "waveform"
        }
    }

    private func settingsToggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        settingsValueRow(title) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(NotchlySwitchStyle())
        }
    }

    private var appleMetalAccelerationRow: some View {
        HStack(spacing: 14) {
            appleLogoBadge

            VStack(alignment: .leading, spacing: 3) {
                Text("Apple Metal")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(MinimalTheme.primary)
                    .lineLimit(1)

                Text("Accelerates local MLX embeddings on Apple GPUs.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MinimalTheme.secondary.opacity(0.86))
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            }

            Spacer(minLength: 16)

            Toggle("Apple Metal", isOn: appleMetalAccelerationSelection)
                .labelsHidden()
                .toggleStyle(NotchlySwitchStyle())
        }
        .frame(minHeight: 58)
        .contentShape(Rectangle())
        .help("Use Apple Metal acceleration for local MLX embedding models.")
    }

    private var appleLogoBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(MinimalTheme.settingsControl)
                .frame(width: 34, height: 34)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(MinimalTheme.divider, lineWidth: 0.7)
                )

            Image(systemName: "apple.logo")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(MinimalTheme.primary)
        }
        .accessibilityHidden(true)
    }

    private func settingsMenuRow<Selection: Hashable>(
        _ title: String,
        selection: Binding<Selection>,
        options: [SettingsMenuOption<Selection>]
    ) -> some View {
        settingsValueRow(title) {
            SettingsMenuSelector(
                selection: selection,
                options: options,
                width: SettingsLayout.controlWidth
            )
        }
    }

    private func settingsSegmentedRow<Selection: Hashable>(
        _ title: String,
        selection: Binding<Selection>,
        options: [SettingsMenuOption<Selection>]
    ) -> some View {
        settingsValueRow(title) {
            SettingsSegmentedSelector(
                selection: selection,
                options: options,
                width: SettingsLayout.controlWidth
            )
        }
    }

    private func settingsStepperRow(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, suffix: String) -> some View {
        settingsValueRow(title) {
            Stepper("\(value.wrappedValue) \(suffix)", value: value, in: range)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(MinimalTheme.secondary)
                .frame(width: 190, alignment: .leading)
        }
    }

    private func settingsTextRow(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        settingsValueRow(title) {
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(MinimalTheme.primary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(width: SettingsLayout.controlWidth, height: 30, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(MinimalTheme.settingsControl)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(MinimalTheme.divider, lineWidth: 0.7)
                )
        }
    }

    private func permissionRow(_ title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        settingsValueRow(title) {
            HStack(spacing: 8) {
                statusChip(granted ? "Granted" : "Needed", isPositive: granted)
                if !granted {
                    Button("Request", action: action)
                        .buttonStyle(SettingsPillButtonStyle())
                }
            }
        }
    }

    private func settingsValueRow<Accessory: View>(_ title: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(spacing: 16) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(MinimalTheme.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.88)
                .frame(width: SettingsLayout.labelWidth, alignment: .leading)
            accessory()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 54)
        .contentShape(Rectangle())
    }

    private func statusChip(_ text: String, isPositive: Bool) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(isPositive ? MinimalTheme.primary : MinimalTheme.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                Capsule()
                    .fill(isPositive ? MinimalTheme.settingsActive.opacity(0.18) : MinimalTheme.settingsControl)
            )
            .overlay(
                Capsule()
                    .stroke(isPositive ? MinimalTheme.settingsActive.opacity(0.24) : MinimalTheme.divider, lineWidth: 0.7)
            )
    }

    private func openURL(_ value: String) {
        guard let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }
}

private enum AudioDevicePickerSentinel {
    static let systemDefault = "__system_default__"
}

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case audio
    case ai
    case knowledge
    case privacy
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .audio: "Audio"
        case .ai: "AI"
        case .knowledge: "Knowledge"
        case .privacy: "Privacy"
        case .about: "About"
        }
    }

    var systemName: String {
        switch self {
        case .general: "gearshape"
        case .audio: "waveform"
        case .ai: "sparkles"
        case .knowledge: "archivebox"
        case .privacy: "lock.shield"
        case .about: "app.badge"
        }
    }
}

private struct EssentialSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MinimalTheme.tertiary)
                .textCase(.uppercase)
                .frame(width: SettingsLayout.labelWidth, alignment: .leading)
            VStack(spacing: 0) {
                content
            }
            .overlay(alignment: .top) { SettingsDivider(fullWidth: true) }
            .overlay(alignment: .bottom) { SettingsDivider(fullWidth: true) }
        }
    }
}

private struct SettingsDivider: View {
    var fullWidth = false

    var body: some View {
        Rectangle()
            .fill(MinimalTheme.divider)
            .frame(height: 0.6)
            .padding(.leading, fullWidth ? 0 : SettingsLayout.dividerInset)
    }
}

private struct NotchMark: View {
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

private struct AudioMicroWaveform: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var isActive: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.22, paused: reduceMotion)) { timeline in
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<18, id: \.self) { index in
                    Capsule()
                        .fill(index % 5 == 0 ? MinimalTheme.settingsActive.opacity(0.9) : MinimalTheme.primary.opacity(0.62))
                        .frame(width: 3, height: barHeight(index: index, date: timeline.date))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .drawingGroup()
        .accessibilityLabel("Audio activity")
    }

    private func barHeight(index: Int, date: Date) -> CGFloat {
        guard isActive, !reduceMotion else {
            return CGFloat([7, 10, 13, 9, 16, 11, 8, 14, 10, 17, 12, 9, 15, 11, 8, 13, 10, 7][index])
        }
        let phase = date.timeIntervalSinceReferenceDate * 2.5 + Double(index) * 0.48
        let normalized = (sin(phase) + 1) * 0.5
        return CGFloat(7 + normalized * 14)
    }
}

private struct SettingsPillButtonStyle: ButtonStyle {
    var isDestructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isDestructive ? MinimalTheme.destructive : MinimalTheme.primary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(
                Capsule()
                    .fill(configuration.isPressed ? MinimalTheme.settingsControlPressed : MinimalTheme.settingsControl)
            )
            .overlay(
                Capsule()
                    .stroke(isDestructive ? MinimalTheme.destructive.opacity(0.28) : MinimalTheme.divider, lineWidth: 0.7)
            )
    }
}

private extension Text {
    func settingsSecondaryText() -> some View {
        self
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(MinimalTheme.secondary)
            .lineLimit(1)
    }
}
