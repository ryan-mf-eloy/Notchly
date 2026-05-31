import AppKit
import SwiftUI

struct AIConnectionSettingsView: View {
    @ObservedObject var appState: AppState
    @State private var selectedAuthKind: AIProviderAuthKind = .accountLogin
    @State private var apiKeyDrafts: [AIProviderKind: String] = [:]
    @State private var accountCodeDrafts: [AIProviderKind: String] = [:]
    @State private var elevenLabsAPIKeyDraft = ""

    private var activeProvider: AIProviderDescriptor {
        ProviderRegistry.descriptor(for: appState.preferences.aiConfig.provider)
    }

    var body: some View {
        VStack(spacing: 30) {
            AISection(title: "Provider") {
                aiPickerRow("Active provider", selection: providerSelection) {
                    ForEach(ProviderRegistry.visibleProviders) { provider in
                        Text(provider.title).tag(provider.kind)
                    }
                }
                AIDivider()
                authMethodRow
                AIDivider()
                providerStatusRow
                AIDivider()
                providerControls
                if !appState.settingsStatus.isEmpty {
                    AIDivider()
                    noticeRow(appState.settingsStatus)
                }
            }

            AISection(title: "Processing") {
                aiToggleRow("Local Only Mode", isOn: $appState.preferences.localOnlyMode)
                    .onChange(of: appState.preferences.localOnlyMode) {
                        if appState.preferences.localOnlyMode {
                            appState.preferences.aiConfig.cloudProcessingEnabled = false
                            appState.preferences.aiConfig.webSearchEnabled = false
                            appState.preferences.transcriptionEngineMode = .appleSpeech
                        }
                        appState.savePreferences()
                    }
                AIDivider()
                aiToggleRow("Cloud processing", isOn: $appState.preferences.aiConfig.cloudProcessingEnabled)
                    .onChange(of: appState.preferences.aiConfig.cloudProcessingEnabled) {
                        if appState.preferences.aiConfig.cloudProcessingEnabled {
                            appState.preferences.localOnlyMode = false
                        }
                        appState.savePreferences()
                    }
                AIDivider()
                aiToggleRow("Web search", isOn: $appState.preferences.aiConfig.webSearchEnabled)
                AIDivider()
                aiToggleRow("Realtime suggestions", isOn: $appState.preferences.realtimeSuggestionsEnabled)
            }

            AISection(title: "Realtime Transcription") {
                aiPickerRow("Provider", selection: realtimeTranscriptionProviderSelection) {
                    ForEach(RealtimeTranscriptionProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                AIDivider()
                secureRow("ElevenLabs key", text: $elevenLabsAPIKeyDraft)
                AIDivider()
                aiValueRow("Keychain") {
                    HStack(spacing: 8) {
                        statusChip(appState.elevenLabsConnectionStatus.title, isPositive: elevenLabsIsConnected)
                        Button("Save & Test") {
                            appState.saveElevenLabsAPIKey(elevenLabsAPIKeyDraft)
                        }
                        .buttonStyle(AIPillButtonStyle())
                        .disabled(elevenLabsAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button("Use") {
                            appState.useElevenLabsRealtimeTranscription()
                        }
                        .buttonStyle(AIPillButtonStyle())
                        .disabled(!appState.hasElevenLabsAPIKey())

                        Button("Clear") {
                            elevenLabsAPIKeyDraft = ""
                            appState.saveElevenLabsAPIKey("")
                        }
                        .buttonStyle(AIPillButtonStyle(isDestructive: true))
                        .disabled(!appState.hasElevenLabsAPIKey() && elevenLabsAPIKeyDraft.isEmpty)
                    }
                }
            }
        }
        .onAppear {
            syncSelectionFromPreferences()
            appState.refreshProviderConnectionStatuses()
        }
        .onChange(of: appState.preferences.aiConfig.provider) {
            syncSelectionFromPreferences()
        }
    }

    private var providerSelection: Binding<AIProviderKind> {
        Binding(
            get: { appState.preferences.aiConfig.provider },
            set: { provider in
                let descriptor = ProviderRegistry.descriptor(for: provider)
                appState.preferences.aiConfig.provider = descriptor.kind
                appState.preferences.aiConfig.authMode = descriptor.defaultAuthMode
                selectedAuthKind = descriptor.authKind(for: descriptor.defaultAuthMode)
                if descriptor.kind == .appleLocal {
                    appState.preferences.localOnlyMode = true
                    appState.preferences.aiConfig.cloudProcessingEnabled = false
                    appState.preferences.aiConfig.webSearchEnabled = false
                }
                appState.savePreferences()
            }
        )
    }

    private var realtimeTranscriptionProviderSelection: Binding<RealtimeTranscriptionProvider> {
        Binding(
            get: { appState.preferences.aiConfig.realtimeTranscriptionProvider ?? .elevenLabs },
            set: { provider in
                appState.preferences.aiConfig.realtimeTranscriptionProvider = provider
                if provider == .elevenLabs {
                    appState.preferences.aiConfig.realtimeTranscriptionModel = ElevenLabsRealtimeTranscriptionService.modelID
                }
                appState.savePreferences()
            }
        )
    }

    private var authMethodRow: some View {
        aiValueRow("Authentication") {
            if activeProvider.supportedAuthKinds.count > 1 {
                Picker("", selection: authKindSelection) {
                    ForEach(activeProvider.supportedAuthKinds) { authKind in
                        Text(authKind.title).tag(authKind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 280)
            } else {
                Text(activeProvider.supportedAuthKinds.first?.title ?? "Default")
                    .aiSecondaryText()
            }
        }
    }

    private var authKindSelection: Binding<AIProviderAuthKind> {
        Binding(
            get: { selectedAuthKind },
            set: { authKind in
                selectedAuthKind = authKind
                if let mode = activeProvider.authMode(for: authKind) {
                    appState.preferences.aiConfig.authMode = mode
                    appState.savePreferences()
                }
            }
        )
    }

    private var providerStatusRow: some View {
        aiValueRow("Status") {
            HStack(spacing: 8) {
                statusChip(appState.providerConnectionStatus(for: activeProvider.kind).title, isPositive: providerIsConnected(activeProvider.kind))
                Text(activeProvider.subtitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(MinimalTheme.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    @ViewBuilder
    private var providerControls: some View {
        switch selectedAuthKind {
        case .accountLogin:
            accountControls
        case .apiKey:
            apiKeyControls
        case .local:
            localControls
        }
    }

    private var accountControls: some View {
        VStack(spacing: 0) {
            aiValueRow("Account") {
                HStack(spacing: 8) {
                    Button(loginInProgress(activeProvider.kind) ? "Opening" : "Connect") {
                        appState.connectProviderAccount(activeProvider.kind)
                    }
                    .buttonStyle(AIPillButtonStyle())
                    .disabled(loginInProgress(activeProvider.kind))

                    Button("Disconnect") {
                        appState.disconnectProvider(activeProvider.kind)
                    }
                    .buttonStyle(AIPillButtonStyle(isDestructive: true))
                    .disabled(!canDisconnect(activeProvider.kind))
                }
            }

            if activeProvider.kind == .openAI, let session = appState.openAICodexLoginSession {
                AIDivider()
                loginSessionRows(
                    authURL: session.authURL,
                    userCode: session.userCode,
                    isVerifying: appState.isVerifyingOpenAICodexLogin,
                    outputPreview: session.outputPreview,
                    open: { appState.openOpenAICodexApprovalPage() },
                    submitCode: nil,
                    cancel: { appState.cancelOpenAICodexLogin() }
                )
            } else if let session = appState.providerLoginSessions[activeProvider.kind] {
                AIDivider()
                loginSessionRows(
                    authURL: session.authURL,
                    userCode: session.userCode,
                    isVerifying: appState.verifyingProviderLogins.contains(session.provider),
                    outputPreview: session.outputPreview,
                    open: { appState.openProviderApprovalPage(session.provider) },
                    submitCode: session.provider == .anthropicClaude ? {
                        appState.submitProviderAccountCode(session.provider, code: accountCodeDrafts[session.provider, default: ""])
                    } : nil,
                    cancel: { appState.cancelProviderAccountLogin(session.provider) }
                )
            }
        }
    }

    private var apiKeyControls: some View {
        VStack(spacing: 0) {
            secureRow("API key", text: Binding(
                get: { apiKeyDrafts[activeProvider.kind, default: ""] },
                set: { apiKeyDrafts[activeProvider.kind] = $0 }
            ))
            AIDivider()
            aiValueRow("Keychain") {
                HStack(spacing: 8) {
                    statusChip(appState.hasProviderAPIKey(activeProvider.kind) ? "Saved" : "No key", isPositive: appState.hasProviderAPIKey(activeProvider.kind))
                    Button("Save & Test") {
                        appState.saveProviderAPIKey(activeProvider.kind, value: apiKeyDrafts[activeProvider.kind, default: ""])
                    }
                    .buttonStyle(AIPillButtonStyle())
                    .disabled(apiKeyDrafts[activeProvider.kind, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Use") {
                        appState.useProviderAPIKeyMode(activeProvider.kind)
                    }
                    .buttonStyle(AIPillButtonStyle())
                    .disabled(!appState.hasProviderAPIKey(activeProvider.kind))

                    Button("Clear") {
                        apiKeyDrafts[activeProvider.kind] = ""
                        appState.saveProviderAPIKey(activeProvider.kind, value: "")
                    }
                    .buttonStyle(AIPillButtonStyle(isDestructive: true))
                    .disabled(!appState.hasProviderAPIKey(activeProvider.kind) && apiKeyDrafts[activeProvider.kind, default: ""].isEmpty)
                }
            }
        }
    }

    private var localControls: some View {
        aiValueRow("Local") {
            HStack(spacing: 8) {
                statusChip("On device", isPositive: true)
                Button("Use") {
                    appState.useProviderLocalMode(activeProvider.kind)
                }
                .buttonStyle(AIPillButtonStyle())
            }
        }
    }

    private func loginSessionRows(
        authURL: URL?,
        userCode: String?,
        isVerifying: Bool,
        outputPreview: String,
        open: @escaping () -> Void,
        submitCode: (() -> Void)?,
        cancel: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 0) {
            if let authURL {
                aiValueRow("Browser") {
                    HStack(spacing: 8) {
                        Text(authURL.host ?? authURL.absoluteString)
                            .aiSecondaryText()
                            .lineLimit(1)
                        Button("Open", action: open)
                            .buttonStyle(AIPillButtonStyle())
                    }
                }
            }
            if let userCode {
                AIDivider()
                aiValueRow("Code") {
                    HStack(spacing: 8) {
                        Text(userCode)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(MinimalTheme.primary)
                            .textSelection(.enabled)
                        Button("Copy") { copyToClipboard(userCode) }
                            .buttonStyle(AIPillButtonStyle())
                    }
                }
            }
            if let submitCode {
                AIDivider()
                secureRow("Auth code", text: Binding(
                    get: { accountCodeDrafts[activeProvider.kind, default: ""] },
                    set: { accountCodeDrafts[activeProvider.kind] = $0 }
                ))
                AIDivider()
                aiValueRow("Submit") {
                    Button("Submit", action: submitCode)
                        .buttonStyle(AIPillButtonStyle())
                }
            }
            AIDivider()
            aiValueRow("Approval") {
                HStack(spacing: 8) {
                    statusChip(isVerifying ? "Verifying" : "Waiting", isPositive: isVerifying)
                    Button("Cancel", action: cancel)
                        .buttonStyle(AIPillButtonStyle(isDestructive: true))
                }
            }
            if !outputPreview.isEmpty {
                AIDivider()
                noticeRow(outputPreview)
            }
        }
    }

    private func syncSelectionFromPreferences() {
        let descriptor = ProviderRegistry.descriptor(for: appState.preferences.aiConfig.provider)
        selectedAuthKind = descriptor.authKind(for: appState.preferences.aiConfig.authMode)
    }

    private func providerIsConnected(_ provider: AIProviderKind) -> Bool {
        if case .connected = appState.providerConnectionStatus(for: provider) {
            return true
        }
        return false
    }

    private var elevenLabsIsConnected: Bool {
        if case .connected = appState.elevenLabsConnectionStatus {
            return true
        }
        return false
    }

    private func loginInProgress(_ provider: AIProviderKind) -> Bool {
        if provider == .openAI {
            return appState.openAICodexLoginSession != nil || appState.isVerifyingOpenAICodexLogin
        }
        return appState.providerLoginSessions[provider] != nil || appState.verifyingProviderLogins.contains(provider)
    }

    private func canDisconnect(_ provider: AIProviderKind) -> Bool {
        if loginInProgress(provider) { return false }
        switch appState.providerConnectionStatus(for: provider) {
        case .connected, .tokenExpired, .localOnlyMode:
            return true
        case .notConnected, .unsupportedOAuthFlow:
            return false
        }
    }

    private func secureRow(_ title: String, text: Binding<String>) -> some View {
        aiValueRow(title) {
            SecureField("", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(MinimalTheme.primary)
                .multilineTextAlignment(.trailing)
                .frame(width: 282)
        }
    }

    private func aiToggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        aiValueRow(title) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(MinimalTheme.notchAccent.opacity(0.82))
                .scaleEffect(0.82)
        }
    }

    private func aiPickerRow<Selection: Hashable, Content: View>(
        _ title: String,
        selection: Binding<Selection>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        aiValueRow(title) {
            Picker("", selection: selection, content: content)
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 282)
        }
    }

    private func aiValueRow<Accessory: View>(_ title: String, @ViewBuilder accessory: () -> Accessory) -> some View {
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

    private func noticeRow(_ text: String) -> some View {
        aiValueRow("Notice") {
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MinimalTheme.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
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

    private func copyToClipboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private struct AISection<Content: View>: View {
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
            .overlay(alignment: .top) { AIDivider(fullWidth: true) }
            .overlay(alignment: .bottom) { AIDivider(fullWidth: true) }
        }
    }
}

private struct AIDivider: View {
    var fullWidth = false

    var body: some View {
        Rectangle()
            .fill(MinimalTheme.divider)
            .frame(height: 0.6)
            .padding(.leading, fullWidth ? 0 : 190)
    }
}

private struct AIPillButtonStyle: ButtonStyle {
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
    func aiSecondaryText() -> some View {
        self
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(MinimalTheme.secondary)
    }
}
