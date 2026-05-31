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

            EssentialSection(title: "Language") {
                settingsPickerRow("Transcript language", selection: $appState.preferences.defaultLanguage) {
                    ForEach(SupportedLanguage.allCases) { language in
                        Text(language.displayName).tag(language.rawValue)
                    }
                }
                SettingsDivider()
                settingsPickerRow("Meeting type", selection: $appState.preferences.defaultMeetingType) {
                    ForEach(MeetingType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
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
                settingsPickerRow("Island design", selection: $appState.preferences.islandDesignMode) {
                    ForEach(IslandDesignMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            }
        }
    }

    private var audio: some View {
        VStack(spacing: 30) {
            audioStatus

            EssentialSection(title: "Capture") {
                settingsPickerRow("Capture mode", selection: audioCaptureModeBinding) {
                    ForEach(AudioCaptureMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                SettingsDivider()
                devicePickerRow("Input device", direction: .input, selection: inputDeviceSelection)
                SettingsDivider()
                devicePickerRow("Output device", direction: .output, selection: outputDeviceSelection)
            }

            EssentialSection(title: "Transcription") {
                settingsSegmentedRow("Quality", selection: transcriptionAccuracySelection) {
                    ForEach(TranscriptionAccuracyMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                SettingsDivider()
                settingsSegmentedRow("Commit", selection: $appState.preferences.copilotASRCommitPolicy) {
                    ForEach(CopilotASRCommitPolicy.allCases) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
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
                settingsToggleRow("Local Only Mode", isOn: $appState.preferences.localOnlyMode)
                    .onChange(of: appState.preferences.localOnlyMode) {
                        if appState.preferences.localOnlyMode {
                            appState.preferences.aiConfig.cloudProcessingEnabled = false
                            appState.preferences.aiConfig.webSearchEnabled = false
                        }
                        appState.savePreferences()
                    }
                SettingsDivider()
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

    private var inputDeviceSelection: Binding<String> {
        deviceSelectionBinding(\.selectedInputDeviceUID)
    }

    private var outputDeviceSelection: Binding<String> {
        deviceSelectionBinding(\.selectedOutputDeviceUID)
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
        let devices = audioDevices.devices(for: direction)
        let selectedUID = selection.wrappedValue == AudioDevicePickerSentinel.systemDefault ? nil : selection.wrappedValue
        return settingsValueRow(title) {
            Picker("", selection: selection) {
                Text(systemDefaultLabel(for: direction)).tag(AudioDevicePickerSentinel.systemDefault)
                ForEach(devices) { device in
                    Text(device.isDefault ? "\(device.name) • Default" : device.name).tag(device.uid)
                }
                if let selectedUID, !audioDevices.isAvailable(selectedUID, direction: direction) {
                    Text("Disconnected device").tag(selectedUID)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 276, alignment: .trailing)
        }
    }

    private func systemDefaultLabel(for direction: AudioDeviceDirection) -> String {
        if let name = audioDevices.defaultDeviceName(for: direction) {
            return "System Default — \(name)"
        }
        return "System Default"
    }

    private func settingsToggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        settingsValueRow(title) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(MinimalTheme.notchAccent.opacity(0.82))
                .scaleEffect(0.82)
        }
    }

    private func settingsPickerRow<Selection: Hashable, Content: View>(
        _ title: String,
        selection: Binding<Selection>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        settingsValueRow(title) {
            Picker("", selection: selection, content: content)
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 250, alignment: .trailing)
        }
    }

    private func settingsSegmentedRow<Selection: Hashable, Content: View>(
        _ title: String,
        selection: Binding<Selection>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        settingsValueRow(title) {
            Picker("", selection: selection, content: content)
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 260, alignment: .trailing)
        }
    }

    private func settingsStepperRow(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, suffix: String) -> some View {
        settingsValueRow(title) {
            Stepper("\(value.wrappedValue) \(suffix)", value: value, in: range)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(MinimalTheme.secondary)
                .frame(width: 190, alignment: .trailing)
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
                .frame(width: 174, alignment: .trailing)
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
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                Capsule()
                    .fill(isPositive ? MinimalTheme.success.opacity(0.18) : MinimalTheme.settingsControl)
            )
            .overlay(
                Capsule()
                    .stroke(isPositive ? MinimalTheme.success.opacity(0.24) : MinimalTheme.divider, lineWidth: 0.7)
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
    case privacy
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .audio: "Audio"
        case .ai: "AI"
        case .privacy: "Privacy"
        case .about: "About"
        }
    }

    var systemName: String {
        switch self {
        case .general: "gearshape"
        case .audio: "waveform"
        case .ai: "sparkles"
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
                .frame(width: 174, alignment: .trailing)
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
            .padding(.leading, fullWidth ? 0 : 190)
    }
}

private struct NotchMark: View {
    var body: some View {
        ZStack {
            Capsule()
                .fill(MinimalTheme.primary.opacity(0.92))
                .frame(width: 28, height: 10)
            Capsule()
                .fill(MinimalTheme.background)
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
                        .fill(index % 5 == 0 ? MinimalTheme.notchAccent.opacity(0.88) : MinimalTheme.primary.opacity(0.62))
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
            .foregroundStyle(isDestructive ? MinimalTheme.notchAccent : MinimalTheme.primary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(
                Capsule()
                    .fill(configuration.isPressed ? MinimalTheme.settingsControlPressed : MinimalTheme.settingsControl)
            )
            .overlay(
                Capsule()
                    .stroke(isDestructive ? MinimalTheme.notchAccent.opacity(0.28) : MinimalTheme.divider, lineWidth: 0.7)
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
