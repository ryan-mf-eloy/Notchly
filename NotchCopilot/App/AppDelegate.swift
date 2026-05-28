import AppKit
import Carbon.HIToolbox
import Combine
import ServiceManagement
import SwiftData
import SwiftUI

struct CopilotHotkeyDescriptor: Equatable {
    static let `default` = CopilotHotkeyDescriptor(requiredModifiers: [.option, .command], displayName: "⌥⌘")

    let requiredModifiers: NSEvent.ModifierFlags
    let displayName: String

    func matches(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags, isRepeat: Bool) -> Bool {
        guard !isRepeat else { return false }
        return matches(modifierFlags: modifierFlags)
    }

    func matches(modifierFlags: NSEvent.ModifierFlags) -> Bool {
        let relevant = modifierFlags.intersection(.deviceIndependentFlagsMask)
        let required = requiredModifiers.intersection(.deviceIndependentFlagsMask)
        let disallowed: NSEvent.ModifierFlags = [.control, .shift]
        return required.isSubset(of: relevant) && relevant.intersection(disallowed).isEmpty
    }
}

struct GlobalHotkeyRegistrationError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        "Could not register Notchly hotkey. OSStatus \(status)."
    }
}

final class GlobalHotkeyService: @unchecked Sendable {
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var descriptor: CopilotHotkeyDescriptor?
    private var onPress: (@MainActor () -> Void)?
    private var onRelease: (@MainActor () -> Void)?
    private var isPressed = false

    deinit {
        unregister()
    }

    func register(
        descriptor: CopilotHotkeyDescriptor = .default,
        onPress: @escaping @MainActor () -> Void,
        onRelease: @escaping @MainActor () -> Void
    ) throws {
        unregister()
        self.descriptor = descriptor
        self.onPress = onPress
        self.onRelease = onRelease

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleModifierFlags(event.modifierFlags)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleModifierFlags(event.modifierFlags)
        }
    }

    func unregister() {
        let release = isPressed ? onRelease : nil
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        descriptor = nil
        onPress = nil
        onRelease = nil
        isPressed = false
        if let release {
            Task { @MainActor in release() }
        }
    }

    private func handleModifierFlags(_ modifierFlags: NSEvent.ModifierFlags) {
        guard let descriptor else { return }
        let isMatching = descriptor.matches(modifierFlags: modifierFlags)
        if isMatching, !isPressed {
            isPressed = true
            Task { @MainActor in self.onPress?() }
        } else if !isMatching, isPressed {
            isPressed = false
            Task { @MainActor in self.onRelease?() }
        }
    }

    private static func fourCharacterCode(_ string: String) -> OSType {
        string.utf8.reduce(0) { partial, byte in
            (partial << 8) + OSType(byte)
        }
    }
}

struct DoubleEscapeShortcutDetector {
    private var lastTimestamp: TimeInterval?
    let threshold: TimeInterval

    init(threshold: TimeInterval = 0.45) {
        self.threshold = threshold
    }

    mutating func registerEscapePress(timestamp: TimeInterval) -> Bool {
        if let lastTimestamp {
            let delta = timestamp - lastTimestamp
            if delta >= 0, delta <= threshold {
                self.lastTimestamp = nil
                return true
            }
        }

        lastTimestamp = timestamp
        return false
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appState: AppState!
    private var notchWindowController: NotchIslandWindowController!
    private var statusItem: NSStatusItem!
    private var stealthModeMenuItem: NSMenuItem?
    private var settingsWindow: NSWindowController?
    private var historyWindow: NSWindowController?
    private var summaryWindow: NSWindowController?
    private var meetingDetectionService: MeetingDetectionService?
    private var meetingAutomationController: MeetingAutomationController?
    private var ambientCopilotController: AmbientCopilotController?
    private let globalHotkeyService = GlobalHotkeyService()
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var escapeShortcutDetector = DoubleEscapeShortcutDetector()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        bootstrap()
        configureKeyboardShortcuts()
        configureStatusItem()
        observeStealthMode()
        observeCopilotLifecycle()
        observeLaunchAtLogin()
        notchWindowController.show()
        applyStealthMode(appState.preferences.stealthModeEnabled)
        appState.reloadHistory()
        appState.reloadKnowledgeDocuments()
        appState.reloadSpeechVocabulary()
        if !ProcessInfo.processInfo.isRunningXCTest {
            meetingAutomationController?.start()
            ambientCopilotController?.start()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState?.savePreferences()

        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }

        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
        }

        globalHotkeyService.unregister()
    }

    private func bootstrap() {
        let isRunningXCTest = ProcessInfo.processInfo.isRunningXCTest
        let keychain = AppleKeychainService.runtimeDefault()
        let cryptor: LocalDataCryptor
        do {
            cryptor = try LocalDataCryptor(keychain: keychain)
        } catch {
            fatalError("Local encryption key unavailable: \(error.localizedDescription)")
        }
        let settingsRepository: SettingsRepository
        if isRunningXCTest {
            let suiteName = "NotchCopilotTests.bootstrap.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            settingsRepository = SettingsRepository(defaults: defaults, cryptor: cryptor)
        } else {
            settingsRepository = SettingsRepository(cryptor: cryptor)
        }
        let preferences = settingsRepository.load()
        settingsRepository.save(preferences)
        let appState = AppState(preferences: preferences)
        let tokenStore = KeychainTokenStore(keychain: keychain)
        let cliTokenStore: TokenStore? = isRunningXCTest ? tokenStore : nil
        let openAIAccountOAuthProvider = OpenAIAccountOAuthProvider(
            configuration: OpenAIAccountOAuthConfiguration.fromBundle(),
            tokenStore: tokenStore,
            sessionManager: OpenAIAuthSessionManager(),
            urlSession: OpenAIURLSessionFactory.makeSecureSession()
        )
        let legacyAPIKeyAuthProvider = OpenAIApiKeyAuthProvider(keychain: keychain)
        let codexCLIRunner = ProcessCodexCLICommandRunner()
        let codexCLIAuthProvider = CodexCLIAuthProvider(runner: codexCLIRunner, tokenStore: cliTokenStore)
        let geminiAPIKeyAuthProvider = ProviderAPIKeyAuthProvider(providerType: .googleGeminiAPIKey, keychain: keychain)
        let anthropicAPIKeyAuthProvider = ProviderAPIKeyAuthProvider(providerType: .anthropicClaudeAPIKey, keychain: keychain)
        let perplexityAPIKeyAuthProvider = ProviderAPIKeyAuthProvider(providerType: .perplexityAPIKey, keychain: keychain)
        let elevenLabsAPIKeyAuthProvider = ProviderAPIKeyAuthProvider(providerType: .elevenLabsAPIKey, keychain: keychain)
        let geminiCLIRunner = ProcessProviderCLICommandRunner(configuration: .gemini)
        let anthropicCLIRunner = ProcessProviderCLICommandRunner(configuration: .claude)
        let geminiCLIAuthProvider = ProviderCLIAuthProvider(configuration: .gemini, runner: geminiCLIRunner, tokenStore: cliTokenStore)
        let anthropicCLIAuthProvider = ProviderCLIAuthProvider(configuration: .claude, runner: anthropicCLIRunner, tokenStore: cliTokenStore)
        codexCLIAuthProvider.onLoginPrompt = { [weak appState] _, userCode in
            if let userCode {
                appState?.settingsStatus = "OpenAI approval opened. Copy code \(userCode) into the browser page."
            } else {
                appState?.settingsStatus = "OpenAI approval opened in your browser. Notchly will connect automatically."
            }
        }
        codexCLIAuthProvider.onLoginStateChange = { [weak appState] state in
            appState?.handleOpenAICodexLoginState(state)
        }
        geminiCLIAuthProvider.onLoginPrompt = { [weak appState] _, _, userCode in
            if let userCode {
                appState?.settingsStatus = "Gemini approval opened. Copy code \(userCode) into the browser page."
            } else {
                appState?.settingsStatus = "Gemini approval opened in your browser. Notchly will connect automatically."
            }
        }
        geminiCLIAuthProvider.onLoginStateChange = { [weak appState] state in
            appState?.handleProviderLoginState(state)
        }
        anthropicCLIAuthProvider.onLoginPrompt = { [weak appState] _, _, userCode in
            if let userCode {
                appState?.settingsStatus = "Claude approval opened. Copy code \(userCode) into the browser page or submit it in Notchly if prompted."
            } else {
                appState?.settingsStatus = "Claude approval opened in your browser."
            }
        }
        anthropicCLIAuthProvider.onLoginStateChange = { [weak appState] state in
            appState?.handleProviderLoginState(state)
        }
        let openAIProvider = OpenAIProvider(authProvider: openAIAccountOAuthProvider) { appState.preferences }
        let legacyOpenAIProvider = OpenAIProvider(authProvider: legacyAPIKeyAuthProvider) { appState.preferences }
        let codexCLIProvider = CodexCLIAIProvider(authProvider: codexCLIAuthProvider, runner: codexCLIRunner) { appState.preferences }
        let geminiAPIKeyProvider = GoogleGeminiProvider(authProvider: geminiAPIKeyAuthProvider) { appState.preferences }
        let geminiCLIProvider = ProviderCLIAIProvider(configuration: .gemini, authProvider: geminiCLIAuthProvider, runner: geminiCLIRunner) { appState.preferences }
        let anthropicAPIKeyProvider = AnthropicClaudeProvider(authProvider: anthropicAPIKeyAuthProvider) { appState.preferences }
        let anthropicCLIProvider = ProviderCLIAIProvider(configuration: .claude, authProvider: anthropicCLIAuthProvider, runner: anthropicCLIRunner) { appState.preferences }
        let perplexityProvider = PerplexityProvider(authProvider: perplexityAPIKeyAuthProvider) { appState.preferences }
        let router = ProviderRouter(
            openAIProvider: openAIProvider,
            legacyOpenAIProvider: legacyOpenAIProvider,
            codexCLIProvider: codexCLIProvider,
            geminiAPIKeyProvider: geminiAPIKeyProvider,
            geminiCLIProvider: geminiCLIProvider,
            anthropicAPIKeyProvider: anthropicAPIKeyProvider,
            anthropicCLIProvider: anthropicCLIProvider,
            perplexityProvider: perplexityProvider,
            elevenLabsAPIKeyAuthProvider: elevenLabsAPIKeyAuthProvider
        )
        let container: ModelContainer
        do {
            container = try DatabaseFactory.makeContainer(inMemory: isRunningXCTest)
        } catch {
            AppLog.persistence.error("Persistent SwiftData failed, using in-memory store: \(error.localizedDescription, privacy: .public)")
            container = try! DatabaseFactory.makeContainer(inMemory: true)
        }
        let fileStorageRoot = isRunningXCTest
            ? FileManager.default.temporaryDirectory.appending(path: "NotchCopilotTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            : nil
        let fileStorage = try! FileStorageService(root: fileStorageRoot, cryptor: cryptor)
        let repository = MeetingRepository(container: container, cryptor: cryptor)
        let knowledgeStore = LocalKnowledgeStore(container: container, cryptor: cryptor)
        let speechVocabularyStore = SpeechVocabularyStore(container: container, cryptor: cryptor)
        do {
            try repository.migrateEncryptedFields()
            try knowledgeStore.migrateEncryptedFields()
            try fileStorage.migrateLegacyTranscriptFiles()
        } catch {
            AppLog.persistence.error("Local encryption migration failed: \(error.localizedDescription, privacy: .public)")
        }
        let manager = MeetingSessionManager(
            appState: appState,
            repository: repository,
            fileStorage: fileStorage,
            settingsRepository: settingsRepository,
            providerRouter: router,
            knowledgeStore: knowledgeStore,
            localDataCryptor: cryptor
        )
        let ambientCopilotController = AmbientCopilotController(
            appState: appState,
            repository: repository,
            settingsRepository: settingsRepository,
            providerRouter: router,
            knowledgeStore: knowledgeStore
        )

        appState.sessionManager = manager
        appState.ambientCopilotController = ambientCopilotController
        appState.settingsRepository = settingsRepository
        appState.providerRouter = router
        appState.keychain = keychain
        appState.tokenStore = tokenStore
        appState.openAIAccountOAuthProvider = openAIAccountOAuthProvider
        appState.codexCLIAuthProvider = codexCLIAuthProvider
        appState.legacyAPIKeyAuthProvider = legacyAPIKeyAuthProvider
        appState.geminiAPIKeyAuthProvider = geminiAPIKeyAuthProvider
        appState.geminiCLIAuthProvider = geminiCLIAuthProvider
        appState.anthropicAPIKeyAuthProvider = anthropicAPIKeyAuthProvider
        appState.anthropicCLIAuthProvider = anthropicCLIAuthProvider
        appState.perplexityAPIKeyAuthProvider = perplexityAPIKeyAuthProvider
        appState.elevenLabsAPIKeyAuthProvider = elevenLabsAPIKeyAuthProvider
        appState.openAIProvider = openAIProvider
        appState.legacyOpenAIProvider = legacyOpenAIProvider
        appState.geminiAPIKeyProvider = geminiAPIKeyProvider
        appState.geminiCLIProvider = geminiCLIProvider
        appState.anthropicAPIKeyProvider = anthropicAPIKeyProvider
        appState.anthropicCLIProvider = anthropicCLIProvider
        appState.perplexityProvider = perplexityProvider
        appState.knowledgeStore = knowledgeStore
        appState.speechVocabularyStore = speechVocabularyStore
        appState.capabilityReport = router.report(preferences: preferences)
        appState.refreshProviderConnectionStatuses()
        appState.refreshAIModelCatalog()
        appState.openSettingsHandler = { [weak self] in self?.openSettings() }
        appState.openHistoryHandler = { [weak self] in self?.openHistory() }
        appState.openSummaryHandler = { [weak self] in self?.openSummary() }
        appState.quitHandler = { NSApp.terminate(nil) }

        self.appState = appState
        self.ambientCopilotController = ambientCopilotController
        self.notchWindowController = NotchIslandWindowController(appState: appState)
        let meetingDetectionService = MeetingDetectionService()
        self.meetingDetectionService = meetingDetectionService
        self.meetingAutomationController = MeetingAutomationController(
            appState: appState,
            meetingDetectionService: meetingDetectionService
        )
    }

    private func configureKeyboardShortcuts() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.scheduleKeyboardShortcutHandling(for: event)
            return event
        }

        configureGlobalCopilotHotkey()
    }

    private func configureGlobalCopilotHotkey() {
        guard appState.preferences.copilotHotkeyEnabled else {
            globalHotkeyService.unregister()
            return
        }
        do {
            try globalHotkeyService.register(
                onPress: { [weak self] in
                    self?.handleCopilotHotkeyPressed()
                },
                onRelease: { [weak self] in
                    self?.handleCopilotHotkeyReleased()
                }
            )
            appState.settingsStatus = "Notchly hotkey ready: \(CopilotHotkeyDescriptor.default.displayName)"
        } catch {
            appState.settingsStatus = "Could not register \(CopilotHotkeyDescriptor.default.displayName)."
            appState.applyCopilotHealthSnapshot(CopilotHealthSnapshot(state: .llmProviderInvalid, lastASRError: error.localizedDescription))
            AppLog.app.error("Notchly hotkey registration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated private func scheduleKeyboardShortcutHandling(for event: NSEvent) {
        let escapeKeyCode: UInt16 = 53
        guard event.keyCode == escapeKeyCode, !event.isARepeat else { return }
        let timestamp = event.timestamp

        Task { @MainActor [weak self] in
            self?.handleEscapeShortcut(timestamp: timestamp)
        }
    }

    private func handleEscapeShortcut(timestamp: TimeInterval) {
        guard escapeShortcutDetector.registerEscapePress(timestamp: timestamp) else { return }

        withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.96, blendDuration: 0.04)) {
            appState.togglePanelExpansionPreservingContext()
        }
    }

    private func handleCopilotHotkeyPressed() {
        guard appState.preferences.copilotHotkeyEnabled else { return }
        withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.96, blendDuration: 0.04)) {
            if appState.currentMeeting != nil {
                appState.openCopilotFromHotkey()
            } else {
                appState.beginCopilotPushToTalk()
            }
        }
    }

    private func handleCopilotHotkeyReleased() {
        guard appState.preferences.copilotHotkeyEnabled, appState.currentMeeting == nil else { return }
        withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.96, blendDuration: 0.04)) {
            appState.endCopilotPushToTalk()
        }
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = makeTrayIcon()
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.imageScaling = .scaleProportionallyDown

        let menu = NSMenu()
        let copilotItem = NSMenuItem(title: "Open Notchly (\(CopilotHotkeyDescriptor.default.displayName))", action: #selector(openCopilotSelector), keyEquivalent: "")
        menu.addItem(copilotItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Start Meeting", action: #selector(startMeeting), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Stop Meeting", action: #selector(stopMeeting), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "History", action: #selector(openHistorySelector), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings", action: #selector(openSettingsSelector), keyEquivalent: ","))
        menu.addItem(.separator())
        let privacyItem = NSMenuItem(title: "Toggle Local Only", action: #selector(toggleLocalOnly), keyEquivalent: "")
        menu.addItem(privacyItem)
        let stealthItem = NSMenuItem(title: "Stealth Mode", action: #selector(toggleStealthMode), keyEquivalent: "")
        stealthModeMenuItem = stealthItem
        menu.addItem(stealthItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
        updateStealthModeMenuItem()
    }

    private func makeTrayIcon() -> NSImage? {
        let image = NSImage(named: "NotchIcon") ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Notchly")
        image?.isTemplate = true
        image?.size = CGSize(width: 24, height: 18)
        image?.accessibilityDescription = "Notchly"
        return image
    }

    @objc private func startMeeting() {
        appState.startManualMeeting()
    }

    @objc private func stopMeeting() {
        appState.stopMeeting()
    }

    @objc private func openCopilotSelector() {
        appState.openCopilotFromHotkey()
    }

    @objc private func openHistorySelector() {
        openHistory()
    }

    @objc private func openSettingsSelector() {
        openSettings()
    }

    @objc private func toggleLocalOnly() {
        appState.preferences.localOnlyMode.toggle()
        if appState.preferences.localOnlyMode {
            appState.preferences.aiConfig.cloudProcessingEnabled = false
        }
        appState.savePreferences()
    }

    @objc private func toggleStealthMode() {
        appState.preferences.stealthModeEnabled.toggle()
        appState.savePreferences()
        applyStealthMode(appState.preferences.stealthModeEnabled)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func observeStealthMode() {
        appState.$preferences
            .map(\.stealthModeEnabled)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] isEnabled in
                self?.applyStealthMode(isEnabled)
            }
            .store(in: &cancellables)
    }

    private func observeCopilotLifecycle() {
        appState.$currentMeeting
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.ambientCopilotController?.evaluateRunningState()
            }
            .store(in: &cancellables)

        appState.$preferences
            .map(\.copilotHotkeyEnabled)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.configureGlobalCopilotHotkey()
            }
            .store(in: &cancellables)
    }

    private func observeLaunchAtLogin() {
        appState.$preferences
            .map { $0.launchAtLogin || $0.copilotLaunchAtLoginEnabled }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] isEnabled in
                self?.applyLaunchAtLogin(isEnabled)
            }
            .store(in: &cancellables)
    }

    private func applyLaunchAtLogin(_ isEnabled: Bool) {
        do {
            if isEnabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            appState.settingsStatus = "Could not update login item."
            AppLog.app.error("Launch at login update failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func applyStealthMode(_ isEnabled: Bool) {
        WindowCaptureProtection.applyToCurrentAppWindows(isEnabled: isEnabled)
        updateStealthModeMenuItem()
    }

    private func updateStealthModeMenuItem() {
        stealthModeMenuItem?.state = appState?.preferences.stealthModeEnabled == true ? .on : .off
    }

    private func openSettings() {
        settingsWindow = makeWindow(
            title: "Notchly Settings",
            size: CGSize(width: 760, height: 640),
            role: .settings,
            rootView: SettingsView(appState: appState)
        )
        settingsWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openHistory() {
        appState.reloadHistory()
        historyWindow = makeWindow(
            title: "Meeting History",
            size: CGSize(width: 1120, height: 720),
            role: .history,
            rootView: HistoryView(appState: appState)
        )
        historyWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openSummary() {
        summaryWindow = makeWindow(
            title: "Meeting Summary",
            size: CGSize(width: 720, height: 620),
            role: .summary,
            rootView: SummaryView(
                meeting: appState.selectedMeeting ?? appState.currentMeeting ?? appState.history.first,
                isProtected: appState.preferences.stealthModeEnabled
            )
        )
        summaryWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow<Content: View>(
        title: String,
        size: CGSize,
        role: WindowCaptureProtectionAudit.WindowRole,
        rootView: Content
    ) -> NSWindowController {
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.center()
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .windowBackgroundColor
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentView = NSHostingView(rootView: rootView.preferredColorScheme(.dark))
        WindowCaptureProtection.apply(
            isEnabled: appState.preferences.stealthModeEnabled,
            to: window,
            role: role
        )
        return NSWindowController(window: window)
    }

}
