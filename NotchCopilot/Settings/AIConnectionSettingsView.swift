import AppKit
import SwiftUI

struct AIConnectionSettingsView: View {
    @ObservedObject var appState: AppState
    @State private var expandedProvider: AIProviderKind? = .openAI
    @State private var selectedAuthKind: AIProviderAuthKind = .accountLogin
    @State private var apiKeyDrafts: [AIProviderKind: String] = [:]
    @State private var accountCodeDrafts: [AIProviderKind: String] = [:]
    @State private var elevenLabsAPIKeyDraft: String = ""

    var body: some View {
        VStack(spacing: 16) {
            MinimalSection(title: "AI Providers") {
                ForEach(ProviderRegistry.visibleProviders) { provider in
                    providerItem(provider)
                    if provider.kind != ProviderRegistry.visibleProviders.last?.kind {
                        MinimalDivider()
                    }
                }
            }

            modelsSection
            realtimeTranscriptionSection
            processingSection
        }
        .onAppear {
            syncSelectionFromPreferences()
            appState.refreshProviderConnectionStatuses()
            appState.refreshAIModelCatalog()
        }
        .onChange(of: expandedProvider) {
            guard let expandedProvider else { return }
            let descriptor = ProviderRegistry.descriptor(for: expandedProvider)
            selectedAuthKind = descriptor.authKind(for: appState.preferences.aiConfig.provider == expandedProvider ? appState.preferences.aiConfig.authMode : descriptor.defaultAuthMode)
        }
        .onChange(of: appState.openAIConnectionStatus) {
            collapseAccountLoginProviderIfConnected(.openAI)
        }
        .onChange(of: appState.providerConnectionStatuses) {
            for provider in ProviderRegistry.visibleProviders.map(\.kind) {
                collapseAccountLoginProviderIfConnected(provider)
            }
        }
    }

    @ViewBuilder
    private func expandedProviderControls(_ provider: AIProviderDescriptor) -> some View {
        VStack(spacing: 0) {
            if provider.supportedAuthKinds.count > 1 {
                authMethodRow(provider)
                MinimalDivider()
            }

            switch selectedAuthKind {
            case .accountLogin:
                accountLoginControls(for: provider)
            case .apiKey:
                apiKeyControls(for: provider)
            case .local:
                localControls(for: provider)
            }

            if !appState.settingsStatus.isEmpty {
                MinimalDivider()
                noticeRow(appState.settingsStatus)
            }
        }
    }

    private func authMethodRow(_ provider: AIProviderDescriptor) -> some View {
        baseRow("Method", systemName: "person.badge.key") {
            Picker("", selection: $selectedAuthKind) {
                ForEach(provider.supportedAuthKinds) { authKind in
                    Text(authKind.title).tag(authKind)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(minWidth: 220, maxWidth: 300)
        }
    }

    private func accountLoginControls(for provider: AIProviderDescriptor) -> some View {
        VStack(spacing: 0) {
            if let message = provider.accountLoginUnsupportedMessage {
                noticeRow(message)
            } else {
                actionRow("Account", systemName: "link") {
                    Button(loginInProgress(for: provider.kind) ? "Opening" : "Connect") {
                        appState.connectProviderAccount(provider.kind)
                    }
                    .buttonStyle(MinimalButtonStyle())
                    .disabled(loginInProgress(for: provider.kind))

                    Button("Disconnect") {
                        appState.disconnectProvider(provider.kind)
                    }
                    .buttonStyle(MinimalButtonStyle(isDestructive: true))
                    .disabled(!canDisconnect(provider.kind))
                }

                if provider.kind == .openAI, let session = appState.openAICodexLoginSession {
                    MinimalDivider()
                    codexLoginRows(session)
                } else if let session = appState.providerLoginSessions[provider.kind] {
                    MinimalDivider()
                    providerLoginRows(session)
                } else {
                    MinimalDivider()
                    noticeRow(accountLoginCopy(for: provider.kind))
                }
            }
        }
    }

    private func apiKeyControls(for provider: AIProviderDescriptor) -> some View {
        return AnyView(providerAPIKeyControls(for: provider, title: "API Key"))
    }

    private func providerAPIKeyControls(for provider: AIProviderDescriptor, title: String) -> some View {
        VStack(spacing: 0) {
            secureRow(title, systemName: "key", text: Binding(
                get: { apiKeyDrafts[provider.kind, default: ""] },
                set: { apiKeyDrafts[provider.kind] = $0 }
            ))
            MinimalDivider()
            actionRow("Keychain", systemName: appState.hasProviderAPIKey(provider.kind) ? "checkmark.shield" : "lock.shield") {
                Text(appState.hasProviderAPIKey(provider.kind) ? "Saved" : "No key")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MinimalTheme.secondary)
                    .lineLimit(1)

                Button("Save & Test") {
                    appState.saveProviderAPIKey(provider.kind, value: apiKeyDrafts[provider.kind, default: ""])
                }
                .buttonStyle(MinimalButtonStyle())
                .disabled(apiKeyDrafts[provider.kind, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Use") {
                    appState.useProviderAPIKeyMode(provider.kind)
                }
                .buttonStyle(MinimalButtonStyle())
                .disabled(!appState.hasProviderAPIKey(provider.kind))

                Button("Clear") {
                    apiKeyDrafts[provider.kind] = ""
                    appState.saveProviderAPIKey(provider.kind, value: "")
                }
                .buttonStyle(MinimalButtonStyle(isDestructive: true))
                .disabled(!appState.hasProviderAPIKey(provider.kind) && apiKeyDrafts[provider.kind, default: ""].isEmpty)
            }
        }
    }

    private func localControls(for provider: AIProviderDescriptor) -> some View {
        actionRow("Local", systemName: "lock.shield") {
            Text("On device")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MinimalTheme.secondary)
                .lineLimit(1)

            Button("Use") {
                appState.useProviderLocalMode(provider.kind)
            }
            .buttonStyle(MinimalButtonStyle())
        }
    }

    private var modelsSection: some View {
        MinimalSection(title: "Models") {
            statusLabelRow(
                "Active Provider",
                systemName: "switch.2",
                value: ProviderRegistry.descriptor(for: appState.preferences.aiConfig.provider).title
            )
            MinimalDivider()
            actionRow("Catalog", systemName: "list.bullet.rectangle") {
                Text(appState.aiModelCatalog.source)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MinimalTheme.secondary)
                    .lineLimit(1)
                Button(appState.isRefreshingAIModelCatalog ? "Refreshing" : "Refresh") {
                    appState.refreshAIModelCatalog()
                }
                .buttonStyle(MinimalButtonStyle())
                .disabled(appState.isRefreshingAIModelCatalog)
            }
            MinimalDivider()
            modelPickerRow(
                "Chat",
                systemName: "text.bubble",
                selection: $appState.preferences.aiConfig.model,
                options: appState.aiModelCatalog.chatModels
            )
            MinimalDivider()
            optionalModelPickerRow(
                "Translation",
                systemName: "translate",
                selection: $appState.preferences.aiConfig.translationModel,
                options: appState.aiModelCatalog.translationModels
            )
            MinimalDivider()
            optionalModelPickerRow(
                "Realtime",
                systemName: "dot.radiowaves.left.and.right",
                selection: $appState.preferences.aiConfig.realtimeModel,
                options: appState.aiModelCatalog.realtimeModels
            )
            MinimalDivider()
            optionalModelPickerRow(
                "Embeddings",
                systemName: "point.3.connected.trianglepath.dotted",
                selection: $appState.preferences.aiConfig.embeddingModel,
                options: appState.aiModelCatalog.embeddingModels
            )
            if !appState.aiModelCatalogStatus.isEmpty {
                MinimalDivider()
                noticeRow(appState.aiModelCatalogStatus)
            }
        }
    }

    private var realtimeTranscriptionSection: some View {
        MinimalSection(title: "Realtime Transcription") {
            realtimeTranscriptionProviderRow
            MinimalDivider()
            optionalModelPickerRow(
                "Model",
                systemName: "waveform.badge.magnifyingglass",
                selection: $appState.preferences.aiConfig.realtimeTranscriptionModel,
                options: appState.realtimeTranscriptionModelOptions
            )
            MinimalDivider()
            secureRow("ElevenLabs Key", systemName: "key", text: $elevenLabsAPIKeyDraft)
            MinimalDivider()
            actionRow("Keychain", systemName: appState.hasElevenLabsAPIKey() ? "checkmark.shield" : "lock.shield") {
                Text(appState.elevenLabsConnectionStatus.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MinimalTheme.secondary)
                    .lineLimit(1)

                Button("Save & Test") {
                    appState.saveElevenLabsAPIKey(elevenLabsAPIKeyDraft)
                }
                .buttonStyle(MinimalButtonStyle())
                .disabled(elevenLabsAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Use") {
                    appState.useElevenLabsRealtimeTranscription()
                }
                .buttonStyle(MinimalButtonStyle())
                .disabled(!appState.hasElevenLabsAPIKey())

                Button("Clear") {
                    elevenLabsAPIKeyDraft = ""
                    appState.saveElevenLabsAPIKey("")
                }
                .buttonStyle(MinimalButtonStyle(isDestructive: true))
                .disabled(!appState.hasElevenLabsAPIKey() && elevenLabsAPIKeyDraft.isEmpty)
            }
            MinimalDivider()
            noticeRow("Zero retention is enforced for ElevenLabs realtime requests. Accounts that cannot use zero retention will fail verification.")
        }
    }

    private var realtimeTranscriptionProviderRow: some View {
        baseRow("Provider", systemName: "dot.radiowaves.left.and.right") {
            Picker("", selection: Binding(
                get: { appState.preferences.aiConfig.realtimeTranscriptionProvider ?? .elevenLabs },
                set: { provider in
                    appState.preferences.aiConfig.realtimeTranscriptionProvider = provider
                    if provider == .elevenLabs {
                        appState.preferences.aiConfig.realtimeTranscriptionModel = ElevenLabsRealtimeTranscriptionService.modelID
                    }
                    appState.savePreferences()
                }
            )) {
                ForEach(RealtimeTranscriptionProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(minWidth: 180, maxWidth: 300)
        }
    }

    private var processingSection: some View {
        MinimalSection(title: "Processing") {
            toggleRow("Cloud processing", systemName: "icloud", isOn: $appState.preferences.aiConfig.cloudProcessingEnabled)
                .onChange(of: appState.preferences.aiConfig.cloudProcessingEnabled) {
                    if appState.preferences.aiConfig.cloudProcessingEnabled {
                        appState.preferences.localOnlyMode = false
                    }
                    appState.savePreferences()
                }
            MinimalDivider()
            transcriptionEngineModeRow
            MinimalDivider()
            toggleRow("Realtime suggestions", systemName: "bolt", isOn: $appState.preferences.realtimeSuggestionsEnabled)
            MinimalDivider()
            toggleRow("Web search", systemName: "magnifyingglass", isOn: $appState.preferences.aiConfig.webSearchEnabled)
            MinimalDivider()
            toggleRow("RAG", systemName: "books.vertical", isOn: $appState.preferences.aiConfig.ragEnabled)
            MinimalDivider()
            technicalRows
        }
    }

    private var transcriptionEngineModeRow: some View {
        baseRow("Transcription", systemName: "captions.bubble") {
            Picker("", selection: Binding(
                get: { appState.preferences.transcriptionEngineMode },
                set: { mode in
                    appState.preferences.transcriptionEngineMode = appState.preferences.localOnlyMode ? .appleSpeech : mode
                    appState.savePreferences()
                }
            )) {
                ForEach(TranscriptionEngineMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(minWidth: 220, maxWidth: 300)
            .disabled(appState.preferences.localOnlyMode)
        }
    }

    private func providerItem(_ provider: AIProviderDescriptor) -> some View {
        VStack(spacing: 0) {
            providerHeader(provider)
            if provider.kind == expandedProvider {
                MinimalDivider()
                expandedProviderControls(provider)
            }
        }
    }

    private func providerHeader(_ provider: AIProviderDescriptor) -> some View {
        Button {
            expandedProvider = expandedProvider == provider.kind ? nil : provider.kind
        } label: {
            HStack(spacing: 11) {
                providerLogo(provider)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MinimalTheme.primary)
                    Text(provider.subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(MinimalTheme.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                providerStatusView(provider)
                Image(systemName: provider.kind == expandedProvider ? "chevron.down" : "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MinimalTheme.secondary)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func providerStatusView(_ provider: AIProviderDescriptor) -> some View {
        let status = appState.providerConnectionStatus(for: provider.kind)
        return HStack(spacing: 5) {
            Image(systemName: statusIcon(for: provider.kind))
                .font(.system(size: 10, weight: .semibold))
            Text(status.title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(statusColor(status, isExpanded: provider.kind == expandedProvider))
        .frame(maxWidth: 220, alignment: .trailing)
    }

    @ViewBuilder
    private func providerLogo(_ provider: AIProviderDescriptor) -> some View {
        if provider.kind == .appleLocal || provider.kind == .appleFoundationModels {
            Image(systemName: "apple.logo")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(MinimalTheme.primary)
        } else if let logoAssetName = provider.logoAssetName {
            Image(logoAssetName)
                .resizable()
                .scaledToFit()
        } else {
            Text(String(provider.title.prefix(1)))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(MinimalTheme.primary)
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

    private func codexLoginRows(_ session: CodexCLILoginSessionState) -> some View {
        VStack(spacing: 0) {
            if let url = session.authURL {
                approvalPageRow(url: url) { appState.openOpenAICodexApprovalPage() }
                MinimalDivider()
            }
            if let userCode = session.userCode {
                deviceCodeRow(userCode)
                MinimalDivider()
            }
            actionRow("Approval", systemName: appState.isVerifyingOpenAICodexLogin ? "checkmark.circle" : "hourglass") {
                Text(appState.isVerifyingOpenAICodexLogin ? "Verifying" : "Waiting")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MinimalTheme.secondary)
                    .lineLimit(1)
                Button("Cancel") { appState.cancelOpenAICodexLogin() }
                    .buttonStyle(MinimalButtonStyle(isDestructive: true))
            }
            if !session.outputPreview.isEmpty {
                MinimalDivider()
                noticeRow(session.outputPreview)
            }
        }
    }

    private func providerLoginRows(_ session: ProviderCLILoginSessionState) -> some View {
        VStack(spacing: 0) {
            if let url = session.authURL {
                approvalPageRow(url: url) { appState.openProviderApprovalPage(session.provider) }
                MinimalDivider()
            }
            if let userCode = session.userCode {
                deviceCodeRow(userCode)
                MinimalDivider()
            }
            if session.provider == .anthropicClaude {
                secureRow("Auth Code", systemName: "number", text: Binding(
                    get: { accountCodeDrafts[session.provider, default: ""] },
                    set: { accountCodeDrafts[session.provider] = $0 }
                ))
                MinimalDivider()
                actionRow("Submit", systemName: "arrow.right.circle") {
                    Button("Submit") {
                        appState.submitProviderAccountCode(session.provider, code: accountCodeDrafts[session.provider, default: ""])
                    }
                    .buttonStyle(MinimalButtonStyle())
                }
                MinimalDivider()
            }
            actionRow("Approval", systemName: appState.verifyingProviderLogins.contains(session.provider) ? "checkmark.circle" : "hourglass") {
                Text(appState.verifyingProviderLogins.contains(session.provider) ? "Verifying" : "Waiting")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MinimalTheme.secondary)
                    .lineLimit(1)
                Button("Cancel") { appState.cancelProviderAccountLogin(session.provider) }
                    .buttonStyle(MinimalButtonStyle(isDestructive: true))
            }
            if !session.outputPreview.isEmpty {
                MinimalDivider()
                noticeRow(session.outputPreview)
            }
        }
    }

    private func approvalPageRow(url: URL, open: @escaping () -> Void) -> some View {
        actionRow("Browser", systemName: "safari") {
            Text(url.host ?? url.absoluteString)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MinimalTheme.secondary)
                .lineLimit(1)
            Button("Open", action: open)
                .buttonStyle(MinimalButtonStyle())
        }
    }

    private func deviceCodeRow(_ userCode: String) -> some View {
        baseRow("Code", systemName: "number") {
            Text(userCode)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(MinimalTheme.primary)
                .textSelection(.enabled)
            Button("Copy") { copyToClipboard(userCode) }
                .buttonStyle(MinimalButtonStyle())
        }
    }

    private func syncSelectionFromPreferences() {
        let provider = appState.preferences.aiConfig.provider == .appleFoundationModels ? AIProviderKind.appleLocal : appState.preferences.aiConfig.provider
        let descriptor = ProviderRegistry.descriptor(for: provider)
        selectedAuthKind = descriptor.authKind(for: appState.preferences.aiConfig.authMode)
        expandedProvider = provider
        collapseAccountLoginProviderIfConnected(provider)
    }

    private func collapseAccountLoginProviderIfConnected(_ provider: AIProviderKind) {
        guard expandedProvider == provider else { return }
        let descriptor = ProviderRegistry.descriptor(for: provider)
        guard descriptor.authKind(for: appState.preferences.aiConfig.authMode) == .accountLogin,
              appState.preferences.aiConfig.provider == descriptor.kind,
              providerConnectionIsConnected(provider) else { return }
        expandedProvider = nil
    }

    private func providerConnectionIsConnected(_ provider: AIProviderKind) -> Bool {
        if case .connected = appState.providerConnectionStatus(for: provider) {
            return true
        }
        return false
    }

    private func statusColor(_ status: AIConnectionStatus, isExpanded: Bool) -> Color {
        if case .connected = status {
            return MinimalTheme.success
        }
        return isExpanded ? MinimalTheme.primary : MinimalTheme.secondary
    }

    private func statusIcon(for provider: AIProviderKind) -> String {
        switch appState.providerConnectionStatus(for: provider) {
        case .connected:
            "checkmark.circle"
        case .tokenExpired:
            "clock.badge.exclamationmark"
        case .unsupportedOAuthFlow:
            "exclamationmark.octagon"
        case .localOnlyMode:
            "lock.shield"
        case .notConnected:
            "circle"
        }
    }

    private func loginInProgress(for provider: AIProviderKind) -> Bool {
        if provider == .openAI {
            return appState.openAICodexLoginSession != nil || appState.isVerifyingOpenAICodexLogin
        }
        return appState.providerLoginSessions[provider] != nil || appState.verifyingProviderLogins.contains(provider)
    }

    private func canDisconnect(_ provider: AIProviderKind) -> Bool {
        if loginInProgress(for: provider) { return false }
        switch appState.providerConnectionStatus(for: provider) {
        case .connected, .tokenExpired, .localOnlyMode:
            return true
        case .notConnected, .unsupportedOAuthFlow:
            return false
        }
    }

    private func accountLoginCopy(for provider: AIProviderKind) -> String {
        switch provider {
        case .openAI:
            "Official OAuth or Codex CLI. Tokens stay with OpenAI/Codex."
        case .googleGemini:
            "Official Gemini CLI login. Tokens stay with the CLI."
        case .anthropicClaude:
            "Official Claude Code login. Paste a code here only if Claude asks."
        default:
            "Account login appears only when an official provider flow is available."
        }
    }

    private func copyToClipboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
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
            Spacer(minLength: 12)
            accessory()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 42)
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

    private func statusLabelRow(_ title: String, systemName: String, value: String) -> some View {
        baseRow(title, systemName: systemName) {
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MinimalTheme.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
    }

    private func noticeRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "info.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MinimalTheme.secondary)
                .frame(width: 18)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MinimalTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
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

    private func modelPickerRow(_ title: String, systemName: String, selection: Binding<String>, options: [AIModelOption]) -> some View {
        baseRow(title, systemName: systemName) {
            if options.isEmpty {
                Text("Unavailable")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MinimalTheme.secondary)
            } else {
                Picker("", selection: selection) {
                    ForEach(options) { option in
                        Text(option.displayName).tag(option.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(minWidth: 180, maxWidth: 300)
                .onChange(of: selection.wrappedValue) {
                    appState.savePreferences()
                }
            }
        }
    }

    private func optionalModelPickerRow(_ title: String, systemName: String, selection: Binding<String?>, options: [AIModelOption]) -> some View {
        modelPickerRow(
            title,
            systemName: systemName,
            selection: Binding<String>(
                get: { selection.wrappedValue ?? "" },
                set: { selection.wrappedValue = $0.isEmpty ? nil : $0 }
            ),
            options: options
        )
    }

    private func secureRow(_ title: String, systemName: String, text: Binding<String>) -> some View {
        baseRow(title, systemName: systemName) {
            SecureField("", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MinimalTheme.primary)
                .multilineTextAlignment(.trailing)
                .frame(minWidth: 180, maxWidth: 300)
        }
    }

    private func textRow(_ title: String, systemName: String, text: Binding<String>) -> some View {
        baseRow(title, systemName: systemName) {
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MinimalTheme.primary)
                .multilineTextAlignment(.trailing)
                .frame(minWidth: 180, maxWidth: 300)
        }
    }

    private func actionRow<Actions: View>(_ title: String, systemName: String, @ViewBuilder actions: () -> Actions) -> some View {
        baseRow(title, systemName: systemName) {
            HStack(spacing: 8) {
                actions()
            }
        }
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
}
