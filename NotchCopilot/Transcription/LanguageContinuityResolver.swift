import Foundation

struct LanguageContinuitySignal: Sendable, Hashable {
    var languageCode: String
    var confidence: Double
    var source: String
}

struct LanguageContinuityResolver: Sendable {
    private enum EvidenceKind: Sendable, Hashable {
        case incomingHint
        case textDetection
        case asrMetadata
        case spokenLanguage
    }

    private struct Candidate: Sendable, Hashable {
        var language: SupportedLanguage
        var confidence: Double
        var evidenceKind: EvidenceKind
        var source: String

        var selectionScore: Double {
            let bias: Double = switch evidenceKind {
            case .spokenLanguage: 0.12
            case .asrMetadata: 0.04
            case .incomingHint: -0.02
            case .textDetection: -0.04
            }
            return min(1, max(0, confidence + bias))
        }
    }

    private struct State: Sendable, Hashable {
        var language: SupportedLanguage
        var confidence: Double
        var pendingCandidate: SupportedLanguage?
        var pendingCandidateCount: Int
        var updatedAt: Date
    }

    private var states: [TranscriptAudioSource: State] = [:]
    private let detector = AppleLanguageDetectionService()

    mutating func resolve(
        text: String,
        audioSource: TranscriptAudioSource,
        incomingLanguage: String?,
        existingLanguage: String?,
        meetingLanguage: String?,
        defaultLanguage: String?,
        isFinal: Bool,
        supplementalSignals: [LanguageContinuitySignal] = []
    ) -> (language: SupportedLanguage, isTextDetected: Bool, confidence: Double) {
        let fallback = SupportedLanguage.language(for: existingLanguage)
            ?? states[audioSource]?.language
            ?? SupportedLanguage.language(for: incomingLanguage)
            ?? SupportedLanguage.language(for: meetingLanguage)
            ?? SupportedLanguage.language(for: defaultLanguage)
            ?? .englishUS

        guard let candidate = strongestSignal(
            text: text,
            incomingLanguage: incomingLanguage,
            isFinal: isFinal,
            supplementalSignals: supplementalSignals
        ) else {
            states[audioSource] = State(
                language: fallback,
                confidence: states[audioSource]?.confidence ?? 0.45,
                pendingCandidate: nil,
                pendingCandidateCount: 0,
                updatedAt: Date()
            )
            return (fallback, false, 0.45)
        }

        let previousState = states[audioSource]
        let previousLanguage = previousState?.language ?? SupportedLanguage.language(for: existingLanguage)
        let candidateLanguage = candidate.language
        let consecutiveCount: Int
        if previousLanguage == candidateLanguage {
            consecutiveCount = max(previousState?.pendingCandidateCount ?? 0, 1)
        } else if previousState?.pendingCandidate == candidateLanguage {
            consecutiveCount = (previousState?.pendingCandidateCount ?? 0) + 1
        } else {
            consecutiveCount = 1
        }

        let shouldSwitch = shouldSwitchLanguage(
            from: previousLanguage,
            to: candidate,
            text: text,
            isFinal: isFinal,
            consecutiveCount: consecutiveCount
        )

        let resolved = shouldSwitch ? candidateLanguage : (previousLanguage ?? fallback)
        states[audioSource] = State(
            language: resolved,
            confidence: candidate.confidence,
            pendingCandidate: shouldSwitch ? nil : candidateLanguage,
            pendingCandidateCount: shouldSwitch ? 0 : consecutiveCount,
            updatedAt: Date()
        )
        return (resolved, shouldSwitch, candidate.confidence)
    }

    private func strongestSignal(
        text: String,
        incomingLanguage: String?,
        isFinal: Bool,
        supplementalSignals: [LanguageContinuitySignal]
    ) -> Candidate? {
        var candidates: [Candidate] = []
        if let incoming = SupportedLanguage.language(for: incomingLanguage) {
            candidates.append(Candidate(
                language: incoming,
                confidence: isFinal ? 0.52 : 0.42,
                evidenceKind: .incomingHint,
                source: "incoming"
            ))
        }
        if let detected = detectedLanguage(for: text, isFinal: isFinal),
           let language = SupportedLanguage.language(for: detected.languageCode) {
            candidates.append(Candidate(
                language: language,
                confidence: detected.confidence,
                evidenceKind: .textDetection,
                source: "text"
            ))
        }
        for signal in supplementalSignals {
            if let language = SupportedLanguage.language(for: signal.languageCode) {
                candidates.append(Candidate(
                    language: language,
                    confidence: min(max(signal.confidence, 0), 1),
                    evidenceKind: evidenceKind(for: signal.source),
                    source: signal.source
                ))
            }
        }
        return candidates.max { lhs, rhs in
            if lhs.selectionScore == rhs.selectionScore {
                return lhs.confidence < rhs.confidence
            }
            return lhs.selectionScore < rhs.selectionScore
        }
    }

    private func shouldSwitchLanguage(
        from previous: SupportedLanguage?,
        to candidate: Candidate,
        text: String,
        isFinal: Bool,
        consecutiveCount: Int
    ) -> Bool {
        guard let previous, previous != candidate.language else { return true }
        let confidence = candidate.confidence
        if looksLikeCodeSwitchOrTechnicalIsland(text) {
            switch candidate.evidenceKind {
            case .spokenLanguage:
                return confidence >= 0.80 && wordCount(in: text) >= 5
            case .asrMetadata:
                return confidence >= 0.90 && wordCount(in: text) >= 8
            case .incomingHint, .textDetection:
                return confidence >= 0.94 && wordCount(in: text) >= 10
            }
        }
        if isFinal {
            switch candidate.evidenceKind {
            case .spokenLanguage:
                return confidence >= 0.68 || (confidence >= 0.58 && consecutiveCount >= 2)
            case .asrMetadata:
                return confidence >= 0.70 || (confidence >= 0.60 && consecutiveCount >= 2)
            case .incomingHint, .textDetection:
                return confidence >= 0.66 || (confidence >= 0.58 && consecutiveCount >= 2)
            }
        }
        let wordThreshold = candidate.evidenceKind == .spokenLanguage ? 4 : 5
        let confidenceThreshold = candidate.evidenceKind == .spokenLanguage ? 0.84 : 0.86
        return confidence >= confidenceThreshold && consecutiveCount >= 2 && wordCount(in: text) >= wordThreshold
    }

    private func evidenceKind(for source: String) -> EvidenceKind {
        let normalized = source.lowercased()
        if normalized.contains("spoken") ||
            normalized.contains("lid") ||
            normalized.contains("audio") ||
            normalized.contains("whisper") ||
            normalized.contains("voxlingua") {
            return .spokenLanguage
        }
        if normalized.contains("speechanalyzer") ||
            normalized.contains("sfspeech") ||
            normalized.contains("apple") ||
            normalized.contains("dictation") ||
            normalized == "asr" {
            return .asrMetadata
        }
        return .incomingHint
    }

    private func detectedLanguage(for text: String, isFinal: Bool) -> LanguageDetectionResult? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return nil }
        if !isFinal, (trimmed.count < 18 || wordCount(in: trimmed) < 4) {
            return nil
        }
        return detector.detectedLanguage(for: trimmed, minimumConfidence: isFinal ? 0.42 : 0.72)
    }

    private func looksLikeCodeSwitchOrTechnicalIsland(_ text: String) -> Bool {
        let tokens = text.components(separatedBy: CharacterSet.whitespacesAndNewlines).filter { !$0.isEmpty }
        guard tokens.count >= 3 else { return false }
        let technical = tokens.filter { token in
            token.contains { $0.isNumber } ||
                token.contains(where: { "_/-#.".contains($0) }) ||
                token.dropFirst().contains { $0.isUppercase } ||
                token.allSatisfy { !$0.isLetter || $0.isUppercase }
        }
        let asciiTokens = tokens.filter { $0.unicodeScalars.allSatisfy(\.isASCII) }
        return Double(technical.count) / Double(tokens.count) >= 0.28 ||
            (asciiTokens.count > 0 && asciiTokens.count < tokens.count)
    }

    private func wordCount(in text: String) -> Int {
        text
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .count
    }
}
