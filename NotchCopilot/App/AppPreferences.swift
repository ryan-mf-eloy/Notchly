import Foundation

enum AudioCaptureMode: String, Codable, CaseIterable, Identifiable {
    case microphoneOnly
    case systemOnly
    case microphoneAndSystem

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .microphoneOnly: "Mic only"
        case .systemOnly: "System audio"
        case .microphoneAndSystem: "Mic + system"
        }
    }
}

enum ResponseStyle: String, Codable, CaseIterable, Identifiable {
    case concise
    case technical
    case diplomatic
    case executive

    var id: String { rawValue }
}

enum TranscriptionEngineMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case appleSpeech
    case cloudRealtime

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleSpeech: "Apple Speech"
        case .cloudRealtime: "Cloud Realtime"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = (try? container.decode(String.self)) ?? Self.appleSpeech.rawValue
        self = Self(rawValue: rawValue) ?? .appleSpeech
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum TranscriptionAccuracyMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case standard
    case highAccuracy

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: "Standard"
        case .highAccuracy: "High Accuracy"
        }
    }

    var legacyAudioQualityName: String {
        switch self {
        case .standard: "Standard"
        case .highAccuracy: "High"
        }
    }

    init(legacyAudioQuality: String) {
        let normalized = legacyAudioQuality.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self = normalized == "high" || normalized == "high accuracy" ? .highAccuracy : .standard
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = (try? container.decode(String.self)) ?? Self.highAccuracy.rawValue
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "standard":
            self = .standard
        case "high", "highaccuracy", "high_accuracy", "high accuracy":
            self = .highAccuracy
        default:
            self = Self(rawValue: rawValue) ?? .highAccuracy
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum CopilotASRCommitPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case fast
    case balanced
    case accurate

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fast: "Fast"
        case .balanced: "Balanced"
        case .accurate: "Accurate"
        }
    }
}

enum QAPrecisionMode: String, Codable, CaseIterable, Identifiable {
    case highPrecision
    case balanced
    case highCoverage

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .highPrecision: "High Precision"
        case .balanced: "Balanced"
        case .highCoverage: "High Coverage"
        }
    }

    var confidenceThreshold: Double {
        switch self {
        case .highPrecision: 0.82
        case .balanced: 0.74
        case .highCoverage: 0.66
        }
    }

    var partialConfidenceThreshold: Double {
        switch self {
        case .highPrecision: 0.92
        case .balanced: 0.86
        case .highCoverage: 0.78
        }
    }

    var requiredStrongSignalCount: Int {
        switch self {
        case .highPrecision: 2
        case .balanced, .highCoverage: 1
        }
    }
}

enum QAMultimodalMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    case shadow
    case enforced

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: "Off"
        case .shadow: "Shadow"
        case .enforced: "Enforced"
        }
    }
}

enum LocalQuestionModelProfile: String, Codable, CaseIterable, Identifiable {
    case fastMiniLM
    case maxAccuracyMDeBERTa

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fastMiniLM: "Fast MiniLM"
        case .maxAccuracyMDeBERTa: "Max Accuracy mDeBERTa"
        }
    }

    var modelIdentifier: String {
        switch self {
        case .fastMiniLM:
            "MoritzLaurer/multilingual-MiniLMv2-L6-mnli-xnli"
        case .maxAccuracyMDeBERTa:
            "MoritzLaurer/mDeBERTa-v3-base-xnli-multilingual-nli-2mil7"
        }
    }

    var bundledCoreMLResourceName: String {
        switch self {
        case .fastMiniLM: "qa-intent-minilm"
        case .maxAccuracyMDeBERTa: "qa-intent-mdeberta"
        }
    }
}

enum AmbientAudioScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case microphoneOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .microphoneOnly: "Mic only"
        }
    }
}

enum CopilotWebMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case onDemand
    case always
    case confirmBeforeCloud

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .onDemand: "On demand"
        case .always: "Always"
        case .confirmBeforeCloud: "Confirm first"
        }
    }
}

enum CopilotActivationPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case clearIntent
    case aggressive
    case wakeWord

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .clearIntent: "Clear Intent"
        case .aggressive: "High Coverage"
        case .wakeWord: "Wake Word"
        }
    }
}

enum IslandDesignMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case solid
    case liquidGlass

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .solid: "Sólido"
        case .liquidGlass: "Liquid Glass"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = (try? container.decode(String.self)) ?? Self.solid.rawValue
        self = Self(rawValue: rawValue) ?? .solid
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct KnownMeetingApp: Identifiable, Codable, Hashable {
    var id: String { bundleIdentifiers.first ?? displayName }
    var displayName: String
    var bundleIdentifiers: [String]
    var nameKeywords: [String]

    init(displayName: String, bundleIdentifiers: [String], nameKeywords: [String]) {
        self.displayName = displayName
        self.bundleIdentifiers = bundleIdentifiers
        self.nameKeywords = nameKeywords
    }

    static let defaults: [KnownMeetingApp] = [
        KnownMeetingApp(displayName: "Zoom", bundleIdentifiers: ["us.zoom.xos"], nameKeywords: ["zoom", "zoom.us"]),
        KnownMeetingApp(displayName: "Microsoft Teams", bundleIdentifiers: ["com.microsoft.teams", "com.microsoft.teams2"], nameKeywords: ["teams", "microsoft teams", "teams work", "teams classic"]),
        KnownMeetingApp(displayName: "Google Meet", bundleIdentifiers: [], nameKeywords: ["google meet", "meet.google", "meet"]),
        KnownMeetingApp(displayName: "WhatsApp", bundleIdentifiers: ["net.whatsapp.WhatsApp", "WhatsApp", "com.facebook.archon"], nameKeywords: ["whatsapp"]),
        KnownMeetingApp(displayName: "Slack", bundleIdentifiers: ["com.tinyspeck.slackmacgap"], nameKeywords: ["slack"]),
        KnownMeetingApp(displayName: "Discord", bundleIdentifiers: ["com.hnc.Discord"], nameKeywords: ["discord"]),
        KnownMeetingApp(displayName: "Arc", bundleIdentifiers: ["company.thebrowser.Browser"], nameKeywords: ["arc"]),
        KnownMeetingApp(displayName: "Google Chrome", bundleIdentifiers: ["com.google.Chrome", "com.google.Chrome.canary"], nameKeywords: ["chrome", "google chrome", "chrome canary"]),
        KnownMeetingApp(displayName: "Microsoft Edge", bundleIdentifiers: ["com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev"], nameKeywords: ["microsoft edge", "edge"]),
        KnownMeetingApp(displayName: "Brave Browser", bundleIdentifiers: ["com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly"], nameKeywords: ["brave", "brave browser"]),
        KnownMeetingApp(displayName: "Firefox", bundleIdentifiers: ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly"], nameKeywords: ["firefox", "firefox developer edition", "firefox nightly"]),
        KnownMeetingApp(displayName: "Safari", bundleIdentifiers: ["com.apple.Safari", "com.apple.SafariTechnologyPreview"], nameKeywords: ["safari", "safari technology preview"]),
        KnownMeetingApp(displayName: "Opera", bundleIdentifiers: ["com.operasoftware.Opera", "com.operasoftware.OperaGX"], nameKeywords: ["opera", "opera gx"]),
        KnownMeetingApp(displayName: "Vivaldi", bundleIdentifiers: ["com.vivaldi.Vivaldi"], nameKeywords: ["vivaldi"]),
        KnownMeetingApp(displayName: "DuckDuckGo", bundleIdentifiers: ["com.duckduckgo.macos.browser"], nameKeywords: ["duckduckgo", "duckduckgo browser"]),
        KnownMeetingApp(displayName: "Dia", bundleIdentifiers: ["company.thebrowser.dia"], nameKeywords: ["dia browser"]),
        KnownMeetingApp(displayName: "Orion", bundleIdentifiers: ["com.kagi.kagimacOS", "com.kagi.kagimacOS.Development"], nameKeywords: ["orion", "kagi"])
    ]
}

struct AppPreferences: Codable, Hashable {
    static var deviceDefaultTranscriptionLanguage: String {
        let languageCode: String?
        if #available(macOS 13.0, *) {
            languageCode = Locale.current.language.languageCode?.identifier
        } else {
            languageCode = Locale.current.languageCode
        }
        return languageCode?.lowercased() == "pt" ? SupportedLanguage.portugueseBR.rawValue : SupportedLanguage.englishUS.rawValue
    }

    var hasCompletedOnboarding: Bool = false
    var launchAtLogin: Bool = false
    var autoDetectMeetings: Bool = true
    var autoStartListening: Bool = false
    var requireConfirmationBeforeRecording: Bool = true
    var smartMeetingDetectionEnabled: Bool = true
    var autoEndDetectedMeetings: Bool = true
    var autoEndGraceSeconds: Int = 5
    var knownMeetingApps: [KnownMeetingApp] = KnownMeetingApp.defaults
    var userDisplayName: String = "Ryan"
    var userNicknames: String = "Ryan"
    var userRole: String = "Senior Fullstack Software Engineer"
    var workspaceId: String = "default"
    var defaultMeetingType: MeetingType = .engineering
    var defaultLanguage: String = AppPreferences.deviceDefaultTranscriptionLanguage
    var audioCaptureMode: AudioCaptureMode = .microphoneAndSystem
    var captureSystemAudio: Bool = true
    var didMigrateRealtimeAudioDefaults: Bool = true
    var didMigrateLanguageDefaults: Bool = true
    var didPromoteTrainedQAMultimodalDefault: Bool = true
    var didAuditSyntheticQAMultimodalDefault: Bool = true
    var didPromoteHardenedQAMultimodalDefault: Bool = true
    var saveAudioRecordings: Bool = false
    var audioQuality: String = "High"
    var transcriptionAccuracyMode: TranscriptionAccuracyMode = .highAccuracy
    var copilotASRCommitPolicy: CopilotASRCommitPolicy = .accurate
    var showWaveform: Bool = true
    var islandDesignMode: IslandDesignMode = .solid
    var aiConfig: AIProviderConfig = .default
    var localOnlyMode: Bool = true
    var realtimeSuggestionsEnabled: Bool = true
    var liveTranslationEnabled: Bool = false
    var targetLanguage: String = SupportedLanguage.portugueseBR.rawValue
    var showOriginalText: Bool = true
    var showTranslatedText: Bool = false
    var transcriptionEngineMode: TranscriptionEngineMode = .appleSpeech
    var showTranscriptionDiagnostics: Bool = false
    var retentionDays: Int = 30
    var showRecordingIndicator: Bool = true
    var stealthModeEnabled: Bool = false
    var doNotSendCodeSnippetsToCloud: Bool = true
    var questionAnsweringProfile: QuestionAnsweringAdaptiveProfile = QuestionAnsweringAdaptiveProfile()
    var qaPrecisionMode: QAPrecisionMode = .highPrecision
    var qaMultimodalMode: QAMultimodalMode = .enforced
    var localQuestionModelProfile: LocalQuestionModelProfile = .maxAccuracyMDeBERTa
    var allowLocalModelDownloads: Bool = true
    var qaShadowMode: Bool = true
    var copilotAlwaysOnEnabled: Bool = false
    var copilotHotkeyEnabled: Bool = true
    var ambientAudioScope: AmbientAudioScope = .microphoneOnly
    var copilotRetentionDays: Int = 7
    var copilotWebMode: CopilotWebMode = .onDemand
    var copilotActivationPolicy: CopilotActivationPolicy = .clearIntent
    var copilotLaunchAtLoginEnabled: Bool = false

    init() {}

    enum CodingKeys: String, CodingKey {
        case hasCompletedOnboarding
        case launchAtLogin
        case autoDetectMeetings
        case autoStartListening
        case requireConfirmationBeforeRecording
        case smartMeetingDetectionEnabled
        case autoEndDetectedMeetings
        case autoEndGraceSeconds
        case knownMeetingApps
        case userDisplayName
        case userNicknames
        case userRole
        case workspaceId
        case defaultMeetingType
        case defaultLanguage
        case audioCaptureMode
        case captureSystemAudio
        case didMigrateRealtimeAudioDefaults
        case didMigrateLanguageDefaults
        case didPromoteTrainedQAMultimodalDefault
        case didAuditSyntheticQAMultimodalDefault
        case didPromoteHardenedQAMultimodalDefault
        case saveAudioRecordings
        case audioQuality
        case transcriptionAccuracyMode
        case copilotASRCommitPolicy
        case showWaveform
        case islandDesignMode
        case aiConfig
        case localOnlyMode
        case realtimeSuggestionsEnabled
        case liveTranslationEnabled
        case targetLanguage
        case showOriginalText
        case showTranslatedText
        case transcriptionEngineMode
        case showTranscriptionDiagnostics
        case retentionDays
        case showRecordingIndicator
        case stealthModeEnabled
        case doNotSendCodeSnippetsToCloud
        case questionAnsweringProfile
        case qaPrecisionMode
        case qaMultimodalMode
        case localQuestionModelProfile
        case allowLocalModelDownloads
        case qaShadowMode
        case copilotAlwaysOnEnabled
        case copilotHotkeyEnabled
        case ambientAudioScope
        case copilotRetentionDays
        case copilotWebMode
        case copilotActivationPolicy
        case copilotLaunchAtLoginEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasCompletedOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        autoDetectMeetings = try container.decodeIfPresent(Bool.self, forKey: .autoDetectMeetings) ?? true
        autoStartListening = try container.decodeIfPresent(Bool.self, forKey: .autoStartListening) ?? false
        requireConfirmationBeforeRecording = try container.decodeIfPresent(Bool.self, forKey: .requireConfirmationBeforeRecording) ?? true
        smartMeetingDetectionEnabled = try container.decodeIfPresent(Bool.self, forKey: .smartMeetingDetectionEnabled) ?? true
        autoEndDetectedMeetings = try container.decodeIfPresent(Bool.self, forKey: .autoEndDetectedMeetings) ?? true
        autoEndGraceSeconds = try container.decodeIfPresent(Int.self, forKey: .autoEndGraceSeconds) ?? 5
        knownMeetingApps = try container.decodeIfPresent([KnownMeetingApp].self, forKey: .knownMeetingApps) ?? KnownMeetingApp.defaults
        userDisplayName = try container.decodeIfPresent(String.self, forKey: .userDisplayName) ?? "Ryan"
        userNicknames = try container.decodeIfPresent(String.self, forKey: .userNicknames) ?? "Ryan"
        userRole = try container.decodeIfPresent(String.self, forKey: .userRole) ?? "Senior Fullstack Software Engineer"
        workspaceId = try container.decodeIfPresent(String.self, forKey: .workspaceId) ?? "default"
        defaultMeetingType = try container.decodeIfPresent(MeetingType.self, forKey: .defaultMeetingType) ?? .engineering
        defaultLanguage = try container.decodeIfPresent(String.self, forKey: .defaultLanguage) ?? AppPreferences.deviceDefaultTranscriptionLanguage
        audioCaptureMode = try container.decodeIfPresent(AudioCaptureMode.self, forKey: .audioCaptureMode) ?? .microphoneAndSystem
        captureSystemAudio = try container.decodeIfPresent(Bool.self, forKey: .captureSystemAudio) ?? true
        didMigrateRealtimeAudioDefaults = try container.decodeIfPresent(Bool.self, forKey: .didMigrateRealtimeAudioDefaults) ?? false
        didMigrateLanguageDefaults = try container.decodeIfPresent(Bool.self, forKey: .didMigrateLanguageDefaults) ?? false
        didPromoteTrainedQAMultimodalDefault = try container.decodeIfPresent(Bool.self, forKey: .didPromoteTrainedQAMultimodalDefault) ?? false
        didAuditSyntheticQAMultimodalDefault = try container.decodeIfPresent(Bool.self, forKey: .didAuditSyntheticQAMultimodalDefault) ?? false
        didPromoteHardenedQAMultimodalDefault = try container.decodeIfPresent(Bool.self, forKey: .didPromoteHardenedQAMultimodalDefault) ?? false
        saveAudioRecordings = try container.decodeIfPresent(Bool.self, forKey: .saveAudioRecordings) ?? false
        audioQuality = try container.decodeIfPresent(String.self, forKey: .audioQuality) ?? "High"
        transcriptionAccuracyMode = try container.decodeIfPresent(TranscriptionAccuracyMode.self, forKey: .transcriptionAccuracyMode)
            ?? TranscriptionAccuracyMode(legacyAudioQuality: audioQuality)
        copilotASRCommitPolicy = try container.decodeIfPresent(CopilotASRCommitPolicy.self, forKey: .copilotASRCommitPolicy) ?? .accurate
        showWaveform = try container.decodeIfPresent(Bool.self, forKey: .showWaveform) ?? true
        islandDesignMode = try container.decodeIfPresent(IslandDesignMode.self, forKey: .islandDesignMode) ?? .solid
        aiConfig = try container.decodeIfPresent(AIProviderConfig.self, forKey: .aiConfig) ?? .default
        localOnlyMode = try container.decodeIfPresent(Bool.self, forKey: .localOnlyMode) ?? true
        realtimeSuggestionsEnabled = try container.decodeIfPresent(Bool.self, forKey: .realtimeSuggestionsEnabled) ?? true
        liveTranslationEnabled = try container.decodeIfPresent(Bool.self, forKey: .liveTranslationEnabled) ?? false
        targetLanguage = try container.decodeIfPresent(String.self, forKey: .targetLanguage) ?? SupportedLanguage.portugueseBR.rawValue
        showOriginalText = try container.decodeIfPresent(Bool.self, forKey: .showOriginalText) ?? true
        showTranslatedText = try container.decodeIfPresent(Bool.self, forKey: .showTranslatedText) ?? false
        transcriptionEngineMode = try container.decodeIfPresent(TranscriptionEngineMode.self, forKey: .transcriptionEngineMode) ?? .appleSpeech
        showTranscriptionDiagnostics = try container.decodeIfPresent(Bool.self, forKey: .showTranscriptionDiagnostics) ?? false
        retentionDays = try container.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 30
        showRecordingIndicator = try container.decodeIfPresent(Bool.self, forKey: .showRecordingIndicator) ?? true
        stealthModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .stealthModeEnabled) ?? false
        doNotSendCodeSnippetsToCloud = try container.decodeIfPresent(Bool.self, forKey: .doNotSendCodeSnippetsToCloud) ?? true
        questionAnsweringProfile = try container.decodeIfPresent(QuestionAnsweringAdaptiveProfile.self, forKey: .questionAnsweringProfile) ?? QuestionAnsweringAdaptiveProfile()
        qaPrecisionMode = try container.decodeIfPresent(QAPrecisionMode.self, forKey: .qaPrecisionMode) ?? .highPrecision
        qaMultimodalMode = try container.decodeIfPresent(QAMultimodalMode.self, forKey: .qaMultimodalMode) ?? .enforced
        localQuestionModelProfile = try container.decodeIfPresent(LocalQuestionModelProfile.self, forKey: .localQuestionModelProfile) ?? .maxAccuracyMDeBERTa
        allowLocalModelDownloads = try container.decodeIfPresent(Bool.self, forKey: .allowLocalModelDownloads) ?? true
        qaShadowMode = try container.decodeIfPresent(Bool.self, forKey: .qaShadowMode) ?? true
        _ = try container.decodeIfPresent(Bool.self, forKey: .copilotAlwaysOnEnabled)
        copilotAlwaysOnEnabled = false
        copilotHotkeyEnabled = try container.decodeIfPresent(Bool.self, forKey: .copilotHotkeyEnabled) ?? true
        ambientAudioScope = try container.decodeIfPresent(AmbientAudioScope.self, forKey: .ambientAudioScope) ?? .microphoneOnly
        copilotRetentionDays = try container.decodeIfPresent(Int.self, forKey: .copilotRetentionDays) ?? 7
        copilotWebMode = try container.decodeIfPresent(CopilotWebMode.self, forKey: .copilotWebMode) ?? .onDemand
        copilotActivationPolicy = try container.decodeIfPresent(CopilotActivationPolicy.self, forKey: .copilotActivationPolicy) ?? .clearIntent
        copilotLaunchAtLoginEnabled = try container.decodeIfPresent(Bool.self, forKey: .copilotLaunchAtLoginEnabled) ?? launchAtLogin
    }

    mutating func normalizeForPersistence() {
        defaultLanguage = SupportedLanguage.normalizedCode(defaultLanguage)
        targetLanguage = SupportedLanguage.normalizedCode(targetLanguage)
        autoEndGraceSeconds = min(max(autoEndGraceSeconds, 1), 120)
        if knownMeetingApps.isEmpty {
            knownMeetingApps = KnownMeetingApp.defaults
        } else {
            mergeDefaultKnownMeetingApps()
        }
        if workspaceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            workspaceId = "default"
        }
        copilotRetentionDays = min(max(copilotRetentionDays, 1), 30)
        copilotAlwaysOnEnabled = false
        ambientAudioScope = .microphoneOnly
        launchAtLogin = launchAtLogin || copilotLaunchAtLoginEnabled
        audioQuality = transcriptionAccuracyMode.legacyAudioQualityName

        if !didMigrateRealtimeAudioDefaults {
            audioCaptureMode = .microphoneAndSystem
            captureSystemAudio = true
            didMigrateRealtimeAudioDefaults = true
        }

        if !didMigrateLanguageDefaults {
            if defaultLanguage == SupportedLanguage.englishUS.rawValue,
               AppPreferences.deviceDefaultTranscriptionLanguage == SupportedLanguage.portugueseBR.rawValue {
                defaultLanguage = SupportedLanguage.portugueseBR.rawValue
            }
            didMigrateLanguageDefaults = true
        }

        if !didAuditSyntheticQAMultimodalDefault {
            didAuditSyntheticQAMultimodalDefault = true
        }

        if !didPromoteHardenedQAMultimodalDefault {
            if qaMultimodalMode == .shadow {
                qaMultimodalMode = .enforced
            }
            didPromoteHardenedQAMultimodalDefault = true
        }

        if audioCaptureMode == .microphoneAndSystem || audioCaptureMode == .systemOnly {
            captureSystemAudio = true
        }

        if localOnlyMode {
            aiConfig.cloudProcessingEnabled = false
            aiConfig.webSearchEnabled = false
            transcriptionEngineMode = .appleSpeech
        }
        aiConfig.normalizeRealtimeTranscriptionDefaults()
        questionAnsweringProfile.prune()

        switch aiConfig.provider {
        case .appleLocal, .appleFoundationModels:
            aiConfig.provider = .appleLocal
            aiConfig.authMode = .appleLocal
        case .openAI where aiConfig.authMode == .appleLocal:
            aiConfig.authMode = .openAICodexCLI
        case .openAI:
            break
        case .googleGemini where ![.googleGeminiOAuth, .googleGeminiAPIKey].contains(aiConfig.authMode):
            aiConfig.authMode = .googleGeminiAPIKey
        case .googleGemini:
            break
        case .anthropicClaude where ![.anthropicClaudeOAuth, .anthropicClaudeAPIKey].contains(aiConfig.authMode):
            aiConfig.authMode = .anthropicClaudeAPIKey
        case .anthropicClaude:
            break
        case .perplexity where aiConfig.authMode != .perplexityAPIKey:
            aiConfig.authMode = .perplexityAPIKey
        case .perplexity:
            break
        }
    }

    func normalizedForPersistence() -> AppPreferences {
        var preferences = self
        preferences.normalizeForPersistence()
        return preferences
    }

    var sourceSeparatedHighAccuracyEnabled: Bool {
        transcriptionAccuracyMode == .highAccuracy
    }

    private mutating func mergeDefaultKnownMeetingApps() {
        var merged = knownMeetingApps
        for defaultApp in KnownMeetingApp.defaults {
            if let index = merged.firstIndex(where: { existing in
                existing.displayName == defaultApp.displayName ||
                    !Set(existing.bundleIdentifiers).isDisjoint(with: Set(defaultApp.bundleIdentifiers))
            }) {
                merged[index].bundleIdentifiers = Array(Set(merged[index].bundleIdentifiers + defaultApp.bundleIdentifiers)).sorted()
                merged[index].nameKeywords = Array(Set(merged[index].nameKeywords + defaultApp.nameKeywords)).sorted()
            } else {
                merged.append(defaultApp)
            }
        }
        knownMeetingApps = merged
    }
}
