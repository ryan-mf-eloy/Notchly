import AVFoundation
import EventKit
import Foundation
import Metal
import Speech

struct CapabilityChecker {
    func supportsOnDeviceSpeechRecognition(language: String?) -> Bool {
        let language = SupportedLanguage.normalizedCode(language)
        return SFSpeechRecognizer(locale: Locale(identifier: language))?.supportsOnDeviceRecognition == true
    }

    func supportsAppleSpeechRecognition(language: String?) -> Bool {
        let language = SupportedLanguage.normalizedCode(language)
        return SFSpeechRecognizer(locale: Locale(identifier: language)) != nil
    }

    func supportsSystemAudioCapture() -> Bool {
        if #available(macOS 13.0, *) {
            return true
        }
        return false
    }

    func supportsAppleTranslation(source: String, target: String) async -> Bool {
        await AppleTranslationService().supports(source: source, target: target)
    }

    func supportsFoundationModels() -> Bool {
        guard #available(macOS 26.0, *) else { return false }
        #if canImport(FoundationModels)
        return true
        #else
        return false
        #endif
    }

    func supportsCoreMLModel(modelName: String) -> Bool {
        AppleCoreMLClassifier().supportsModel(named: modelName)
    }

    func supportsMetal() -> Bool {
        MTLCreateSystemDefaultDevice() != nil
    }

    func hasMicrophonePermission() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func hasScreenCapturePermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func hasCalendarPermission() -> Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    func localReport(preferences: AppPreferences) -> LocalCapabilityReport {
        let cloudAllowed = preferences.aiConfig.cloudProcessingEnabled &&
            !preferences.localOnlyMode &&
            preferences.aiConfig.provider == .openAI &&
            (preferences.aiConfig.authMode == .openAIAccountOAuth ||
                preferences.aiConfig.authMode == .openAICodexCLI ||
                (preferences.aiConfig.authMode == .apiKeyLegacy && preferences.aiConfig.legacyAPIKeyAccessEnabled))
        let canRecognize = supportsAppleSpeechRecognition(language: preferences.defaultLanguage)
        let canRunLocal = !preferences.localOnlyMode || supportsOnDeviceSpeechRecognition(language: preferences.defaultLanguage)
        let transcriptionEngine: EngineName
        if canRecognize && canRunLocal {
            if #available(macOS 26.0, *), SpeechTranscriber.isAvailable {
                transcriptionEngine = .speechAnalyzer
            } else {
                transcriptionEngine = .appleSpeech
            }
        } else {
            transcriptionEngine = .unavailable
        }
        let transcriptionMode: ProcessingMode = transcriptionEngine == .unavailable ? .unavailable : .local

        let localLLMAvailable = LocalLLMAIProvider.isRuntimeLinked &&
            supportsMetal() &&
            (preferences.allowLocalModelDownloads || LocalLLMModelManager().availableDescriptor() != nil)
        let localSummaryEngine: EngineName = supportsFoundationModels() ? .appleFoundationModels : (localLLMAvailable ? .mlxLocalLLM : .unavailable)
        let localSummaryMode: ProcessingMode = localSummaryEngine == .unavailable ? .unavailable : .local

        return LocalCapabilityReport(
            microphonePermission: hasMicrophonePermission(),
            screenCapturePermission: hasScreenCapturePermission(),
            calendarPermission: hasCalendarPermission(),
            supportsSystemAudioCapture: supportsSystemAudioCapture(),
            supportsFoundationModels: supportsFoundationModels(),
            supportsMetal: supportsMetal(),
            transcriptionEngine: transcriptionEngine,
            transcriptionMode: transcriptionMode,
            translationEngine: .appleTranslation,
            translationMode: .local,
            summaryEngine: preferences.localOnlyMode ? localSummaryEngine : (cloudAllowed ? .openAI : .unavailable),
            summaryMode: preferences.localOnlyMode ? localSummaryMode : (cloudAllowed ? .cloud : .unavailable),
            languageDetectionEngine: .appleNaturalLanguage,
            audioCaptureEngine: .avFoundationScreenCaptureKit,
            waveformEngine: .accelerate
        )
    }
}
