import Foundation

struct LocalCapabilityReport: Sendable, Hashable {
    var microphonePermission: Bool
    var screenCapturePermission: Bool
    var calendarPermission: Bool
    var supportsSystemAudioCapture: Bool
    var supportsFoundationModels: Bool
    var supportsMetal: Bool
    var transcriptionEngine: EngineName
    var transcriptionMode: ProcessingMode
    var translationEngine: EngineName
    var translationMode: ProcessingMode
    var summaryEngine: EngineName
    var summaryMode: ProcessingMode
    var languageDetectionEngine: EngineName
    var audioCaptureEngine: EngineName
    var waveformEngine: EngineName
}

