import Foundation
import NaturalLanguage

struct UtteranceFrame: Identifiable, Hashable, Sendable {
    var id: UUID
    var meetingId: UUID
    var rawText: String
    var normalizedText: String
    var language: String?
    var speakerId: UUID?
    var speakerLabel: String?
    var audioSource: TranscriptAudioSource
    var startTime: TimeInterval
    var endTime: TimeInterval?
    var sourceSegmentId: UUID
    var isPartial: Bool
    var isFinal: Bool
    var asrConfidence: Double?
    var hasTerminalPause: Bool
    var multimodalSignal: QuestionMultimodalSignal?
}

struct UtteranceFrameBuilder {
    var textPolicy: QuestionTextSegmentationPolicy = .fallback
    var questionSplitMarkers: [String] = []
    var questionSplitPreambleMarkers: [String] = []
    var questionSplitSuppressionLeadMarkers: [String] = []
    var questionSplitContinuationLeadMarkers: [String] = []
    var maximumQuestionSplitPreambleTokens: Int = 0

    private struct TokenSpan {
        var normalized: String
        var range: Range<String.Index>
    }

    func frames(from segment: TranscriptSegment, context: TranscriptContext, signal: QuestionMultimodalSignal? = nil) -> [UtteranceFrame] {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= textPolicy.minimumFrameCharacters else { return [] }

        let spans = sentenceSpans(in: text).flatMap(embeddedQuestionSpans)
        guard !spans.isEmpty else {
            return [frame(text: text, segment: segment, index: 0, count: 1, signal: signal)]
        }

        return spans.enumerated().compactMap { index, span in
            let value = span.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.count >= textPolicy.minimumFrameCharacters else { return nil }
            return frame(text: value, segment: segment, index: index, count: spans.count, signal: signal)
        }
    }

    private func frame(text: String, segment: TranscriptSegment, index: Int, count: Int, signal: QuestionMultimodalSignal?) -> UtteranceFrame {
        let duration = max(segment.endTime - segment.startTime, 0)
        let step = count > 0 ? duration / Double(count) : 0
        let start = segment.startTime + (Double(index) * step)
        let end = duration > 0 ? start + step : segment.endTime
        let frameSignal = signal.map {
            QuestionMultimodalSignal(
                language: $0.language,
                asrConfidence: $0.asrConfidence,
                isFinal: $0.isFinal,
                isPartial: $0.isPartial,
                speakerLabel: $0.speakerLabel,
                audioSource: $0.audioSource,
                duration: step > 0 ? step : $0.duration,
                hasTerminalPause: index == count - 1 && $0.hasTerminalPause,
                partialStability: $0.partialStability,
                partialRevisionCount: $0.partialRevisionCount,
                rms: $0.rms,
                peak: $0.peak,
                isClipping: $0.isClipping,
                isSilence: $0.isSilence,
                isTooQuiet: $0.isTooQuiet,
                gapCount: $0.gapCount,
                noiseFloor: $0.noiseFloor,
                audioEnergy: $0.audioEnergy,
                createdAt: $0.createdAt
            )
        }
        return UtteranceFrame(
            id: index == 0 ? segment.id : UUID(),
            meetingId: segment.meetingId,
            rawText: text,
            normalizedText: QuestionDetectionService.normalize(text),
            language: segment.originalLanguage,
            speakerId: segment.speakerId,
            speakerLabel: segment.speakerLabel,
            audioSource: segment.audioSource,
            startTime: start,
            endTime: end,
            sourceSegmentId: segment.id,
            isPartial: !segment.isFinal,
            isFinal: segment.isFinal,
            asrConfidence: segment.confidence,
            hasTerminalPause: segment.isFinal,
            multimodalSignal: frameSignal
        )
    }

    private func sentenceSpans(in text: String) -> [String] {
        var spans: [String] = []
        var current = ""

        func appendCurrent() {
            let span = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !span.isEmpty {
                spans.append(span)
            }
            current = ""
        }

        for character in text {
            if textPolicy.isLineBoundary(character) {
                appendCurrent()
                continue
            }
            current.append(character)
            if textPolicy.isSentenceBoundary(character) {
                appendCurrent()
            }
        }
        appendCurrent()
        return spans.isEmpty ? [text] : spans
    }

    private func embeddedQuestionSpans(in text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let markerSequences = splitMarkerTokenSequences()
        guard markerSequences.isEmpty == false else { return [trimmed] }

        let tokens = tokenSpans(in: trimmed)
        guard tokens.count > 2,
              let firstMarker = firstQuestionSplitMarker(in: tokens, markerSequences: markerSequences),
              !hasContinuationLeadMarker(firstMarker, in: tokens),
              !hasSuppressedSplitLead(in: tokens),
              firstMarker.index == 0 || hasAllowedPreamble(before: firstMarker.index, tokens: tokens) else {
            return [trimmed]
        }

        var splitTokenIndexes: [Int] = []
        var index = firstMarker.index + max(1, firstMarker.length)
        while index < tokens.count {
            guard let matchLength = matchesAnyMarker(at: index, tokens: tokens, markerSequences: markerSequences) else {
                index += 1
                continue
            }
            let splitStart = tokens[index].range.lowerBound
            let prefixStart = splitTokenIndexes.last.map { tokens[$0].range.lowerBound } ?? trimmed.startIndex
            let prefix = trimmed[prefixStart..<splitStart].trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = trimmed[splitStart...].trimmingCharacters(in: .whitespacesAndNewlines)
            if prefix.count >= textPolicy.minimumFrameCharacters,
               suffix.count >= textPolicy.minimumFrameCharacters {
                splitTokenIndexes.append(index)
                index += max(1, matchLength)
            } else {
                index += 1
            }
        }

        let spanStart = tokens[firstMarker.index].range.lowerBound
        guard !splitTokenIndexes.isEmpty || spanStart != trimmed.startIndex else { return [trimmed] }
        var spans: [String] = []
        var start = spanStart
        for tokenIndex in splitTokenIndexes {
            let end = tokens[tokenIndex].range.lowerBound
            let span = trimmed[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !span.isEmpty {
                spans.append(String(span))
            }
            start = end
        }
        let tail = trimmed[start...].trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            spans.append(String(tail))
        }
        return spans.isEmpty ? [trimmed] : spans
    }

    private func firstQuestionSplitMarker(
        in tokens: [TokenSpan],
        markerSequences: [[String]]
    ) -> (index: Int, length: Int)? {
        let maximumPreamble = min(max(0, maximumQuestionSplitPreambleTokens), max(0, tokens.count - 1))
        for index in 0...maximumPreamble {
            if let length = matchesAnyMarker(at: index, tokens: tokens, markerSequences: markerSequences) {
                return (index, length)
            }
        }
        return nil
    }

    private func hasAllowedPreamble(before markerIndex: Int, tokens: [TokenSpan]) -> Bool {
        guard markerIndex > 0,
              markerIndex <= maximumQuestionSplitPreambleTokens else {
            return false
        }

        let preambleSequences = preambleMarkerTokenSequences()
        guard !preambleSequences.isEmpty else { return false }
        let preambleTokens = tokens[..<markerIndex].map(\.normalized)
        var index = 0
        while index < preambleTokens.count {
            guard let length = matchesAnySequence(
                at: index,
                tokens: preambleTokens,
                markerSequences: preambleSequences
            ) else {
                return false
            }
            index += max(1, length)
        }
        return true
    }

    private func splitMarkerTokenSequences() -> [[String]] {
        markerTokenSequences(from: questionSplitMarkers)
    }

    private func preambleMarkerTokenSequences() -> [[String]] {
        markerTokenSequences(from: questionSplitPreambleMarkers)
    }

    private func suppressionLeadMarkerTokenSequences() -> [[String]] {
        markerTokenSequences(from: questionSplitSuppressionLeadMarkers)
    }

    private func continuationLeadMarkerTokenSequences() -> [[String]] {
        markerTokenSequences(from: questionSplitContinuationLeadMarkers)
    }

    private func hasSuppressedSplitLead(in tokens: [TokenSpan]) -> Bool {
        let normalizedTokens = tokens.map(\.normalized)
        return matchesAnySequence(
            at: 0,
            tokens: normalizedTokens,
            markerSequences: suppressionLeadMarkerTokenSequences()
        ) != nil
    }

    private func hasContinuationLeadMarker(
        _ marker: (index: Int, length: Int),
        in tokens: [TokenSpan]
    ) -> Bool {
        guard marker.index == 0 else { return false }
        let normalizedTokens = tokens.map(\.normalized)
        return matchesAnySequence(
            at: marker.index,
            tokens: normalizedTokens,
            markerSequences: continuationLeadMarkerTokenSequences()
        ) != nil
    }

    private func markerTokenSequences(from markers: [String]) -> [[String]] {
        var seen: Set<[String]> = []
        let sequences = markers
            .map { textPolicy.lexicalTokens(in: $0) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
        return sequences.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.joined(separator: " ").count > $1.joined(separator: " ").count
        }
    }

    private func tokenSpans(in text: String) -> [TokenSpan] {
        var spans: [TokenSpan] = []
        var start: String.Index?
        var index = text.startIndex

        func appendToken(endingAt end: String.Index) {
            guard let tokenStart = start else { return }
            let token = String(text[tokenStart..<end])
            let normalized = QuestionDetectionService.normalize(token)
            if !normalized.isEmpty {
                spans.append(TokenSpan(normalized: normalized, range: tokenStart..<end))
            }
            start = nil
        }

        while index < text.endIndex {
            let character = text[index]
            if isTokenCharacter(character) {
                if start == nil {
                    start = index
                }
            } else {
                appendToken(endingAt: index)
            }
            index = text.index(after: index)
        }
        appendToken(endingAt: text.endIndex)
        return spans
    }

    private func isTokenCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || textPolicy.containsCodeIdentifierCharacter(in: String(character))
    }

    private func matchesAnyMarker(
        at tokenIndex: Int,
        tokens: [TokenSpan],
        markerSequences: [[String]]
    ) -> Int? {
        for marker in markerSequences where matchesMarker(marker, at: tokenIndex, tokens: tokens) {
            return marker.count
        }
        return nil
    }

    private func matchesAnySequence(
        at tokenIndex: Int,
        tokens: [String],
        markerSequences: [[String]]
    ) -> Int? {
        for marker in markerSequences where matchesSequence(marker, at: tokenIndex, tokens: tokens) {
            return marker.count
        }
        return nil
    }

    private func matchesMarker(_ marker: [String], at tokenIndex: Int, tokens: [TokenSpan]) -> Bool {
        guard tokenIndex + marker.count <= tokens.count else { return false }
        for offset in marker.indices where tokens[tokenIndex + offset].normalized != marker[offset] {
            return false
        }
        return true
    }

    private func matchesSequence(_ marker: [String], at tokenIndex: Int, tokens: [String]) -> Bool {
        guard tokenIndex + marker.count <= tokens.count else { return false }
        for offset in marker.indices where tokens[tokenIndex + offset] != marker[offset] {
            return false
        }
        return true
    }
}

struct QuestionSurfaceAnalysis: Hashable, Sendable {
    var plainText: String
    var textAfterAddress: String
    var strongSignals: Set<QuestionUnderstandingSignal> = []
    var negativeSignals: [String] = []
    var meaningfulTokens: [String] = []
    var hasQuestionPunctuation: Bool = false
    var hasWeakQuestionWordOnly: Bool = false
    var structuralQuestionScore: Double = 0
    var objectFocusScore: Double = 0

    var isRejected: Bool { !negativeSignals.isEmpty }
    var strongSignalCount: Int { strongSignals.count }
}

struct QuestionRejectedFrame: Hashable, Sendable {
    var frame: UtteranceFrame
    var surfaceSignals: [String]
    var suppressionSignals: [String]
    var hardSuppressionSignals: Set<String> = QuestionIntentRulePack.default.hardSuppressionSignals
    var reason: String

    var hasHardSuppression: Bool {
        suppressionSignals.contains { signal in
            hardSuppressionSignals.contains(signal)
        }
    }
}

struct QuestionDetectionResult: Hashable, Sendable {
    var surfaceCandidates: [QuestionCandidate]
    var rejectedFrames: [QuestionRejectedFrame]

    static let empty = QuestionDetectionResult(surfaceCandidates: [], rejectedFrames: [])
}

private struct StructuralQuestionProfile: Hashable, Sendable {
    var questionScore: Double
    var objectScore: Double
    var answerableObjectFocusThreshold: Double
    var questionLikeThreshold: Double

    var hasAnswerableObjectFocus: Bool {
        objectScore >= answerableObjectFocusThreshold
    }

    var isQuestionLike: Bool {
        questionScore >= questionLikeThreshold && hasAnswerableObjectFocus
    }
}

private struct ContextualQuestionCueMatcher {
    var rulePack: QuestionIntentRulePack

    func matches(plain currentPlain: String, context: TranscriptContext?) -> Bool {
        guard let context else { return false }
        let plain = QuestionIntentGate.plainQuestionText(
            QuestionDetectionService.normalize(currentPlain),
            textPolicy: rulePack.textSegmentationPolicy
        )
        guard !plain.isEmpty else { return false }

        let learned = learnedCues(from: context, excluding: plain)
        guard !learned.leads.isEmpty || !learned.compactSuffixes.isEmpty else { return false }

        if leadCues(from: plain).contains(where: { cue in
            let observationCount = learned.leads[cue, default: 0]
            return observationCount >= observationThreshold(forLeadCue: cue)
        }) {
            return true
        }

        guard rulePack.textSegmentationPolicy.containsCompactScript(in: plain) else { return false }
        return compactSuffixes(from: plain).contains {
            learned.compactSuffixes[$0, default: 0] >= rulePack.contextualCuePolicy.compactSuffixMinimumObservations
        }
    }

    private func learnedCues(
        from context: TranscriptContext,
        excluding currentPlain: String
    ) -> (leads: [String: Int], compactSuffixes: [String: Int]) {
        let examples = priorQuestionExamples(from: context, excluding: currentPlain)
        var leads: [String: Int] = [:]
        var compactSuffixCounts: [String: Int] = [:]
        for example in examples {
            for cue in leadCues(from: example) {
                leads[cue, default: 0] += 1
            }
            for suffix in compactSuffixes(from: example) {
                compactSuffixCounts[suffix, default: 0] += 1
            }
        }
        return (leads, compactSuffixCounts)
    }

    private func priorQuestionExamples(from context: TranscriptContext, excluding currentPlain: String) -> [String] {
        let currentSegmentPlain = context.currentSegment.map {
            QuestionIntentGate.plainQuestionText(
                QuestionDetectionService.normalize($0.text),
                textPolicy: rulePack.textSegmentationPolicy
            )
        }
        let sources = [
            context.completeTranscript,
            context.mediumTranscript,
            context.recentTranscript
        ]
        var seen: Set<String> = []
        var examples: [String] = []

        for source in sources where !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            for span in sentenceSpans(in: source).reversed() {
                guard examples.count < rulePack.contextualCuePolicy.maximumQuestionExamples else { return examples }
                guard rulePack.textSegmentationPolicy.containsQuestionPunctuation(in: span) else { continue }
                let normalized = QuestionDetectionService.normalize(strippingTranscriptPrefix(from: span))
                let plain = QuestionIntentGate.plainQuestionText(normalized, textPolicy: rulePack.textSegmentationPolicy)
                guard !plain.isEmpty,
                      plain != currentPlain,
                      plain != currentSegmentPlain,
                      seen.insert(plain).inserted,
                      !shouldIgnoreExample(plain) else {
                    continue
                }
                examples.append(plain)
            }
        }

        return examples
    }

    private func sentenceSpans(in text: String) -> [String] {
        var spans: [String] = []
        var current = ""

        func appendCurrent() {
            let span = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !span.isEmpty {
                spans.append(span)
            }
            current = ""
        }

        for character in text {
            if rulePack.textSegmentationPolicy.isLineBoundary(character) {
                appendCurrent()
                continue
            }
            current.append(character)
            if rulePack.textSegmentationPolicy.isSentenceBoundary(character) {
                appendCurrent()
            }
        }
        appendCurrent()
        return spans
    }

    private func strippingTranscriptPrefix(from span: String) -> String {
        let trimmed = span.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let questionIndex = trimmed.firstIndex(where: { rulePack.textSegmentationPolicy.questionPunctuationCharacters.contains($0) }),
              let colonIndex = trimmed[..<questionIndex].lastIndex(of: ":") else {
            return trimmed
        }
        let remainder = trimmed[trimmed.index(after: colonIndex)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return remainder.isEmpty ? trimmed : String(remainder)
    }

    private func shouldIgnoreExample(_ plain: String) -> Bool {
        let gate = QuestionIntentGate(rulePack: rulePack)
        return gate.isSmallTalk(plain)
            || gate.isQuotedOrExplaining(plain)
            || gate.isFragment(plain, context: nil)
            || RhetoricalQuestionFilter(rulePack: rulePack).isRhetorical(plain)
    }

    private func leadCues(from plain: String) -> [String] {
        let tokens = rulePack.textSegmentationPolicy
            .lexicalTokens(in: plain)
            .filter(isLeadCueToken)
        guard !tokens.isEmpty else { return [] }

        let maximumCount = min(rulePack.contextualCuePolicy.maximumLeadTokenCount, tokens.count)
        var cues: [String] = []
        for count in 1...maximumCount {
            cues.append(tokens.prefix(count).joined(separator: " "))
        }
        return cues
    }

    private func compactSuffixes(from plain: String) -> [String] {
        let compactText = String(
            plain.filter { character in
                !character.isWhitespace
                    && !rulePack.textSegmentationPolicy.isSentenceBoundary(character)
                    && !rulePack.textSegmentationPolicy.questionPunctuationCharacters.contains(character)
            }
        )
        guard rulePack.textSegmentationPolicy.containsCompactScript(in: compactText) else { return [] }
        let characters = Array(compactText)
        let policy = rulePack.contextualCuePolicy
        let maximumLength = min(policy.compactSuffixMaximumCharacters, characters.count)
        guard maximumLength >= policy.compactSuffixMinimumCharacters else { return [] }
        return (policy.compactSuffixMinimumCharacters...maximumLength).map { length in
            String(characters.suffix(length))
        }
    }

    private func isLeadCueToken(_ token: String) -> Bool {
        token.count >= rulePack.contextualCuePolicy.minimumLeadTokenLength
            && token.unicodeScalars.contains {
                CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
            }
    }

    private func observationThreshold(forLeadCue cue: String) -> Int {
        rulePack.textSegmentationPolicy.lexicalTokenCount(in: cue) <= 1
            ? rulePack.contextualCuePolicy.minimumSingleTokenObservations
            : rulePack.contextualCuePolicy.minimumMultiTokenObservations
    }
}

struct QuestionSurfaceAnalyzer {
    var rulePack: QuestionIntentRulePack = .default
    var adaptiveProfile: QuestionAnsweringAdaptiveProfile = QuestionAnsweringAdaptiveProfile()

    func analyze(
        text rawText: String,
        normalized: String? = nil,
        context: TranscriptContext?,
        profile: UserMeetingProfile? = nil,
        isPartial: Bool,
        isFinal: Bool
    ) -> QuestionSurfaceAnalysis {
        let normalized = normalized ?? QuestionDetectionService.normalize(rawText)
        let plain = QuestionIntentGate.plainQuestionText(normalized, textPolicy: rulePack.textSegmentationPolicy)
        let addressed = removeLeadingDiscourse(from: removeLeadingAddress(from: plain, profile: profile))
        var analysis = QuestionSurfaceAnalysis(
            plainText: plain,
            textAfterAddress: addressed,
            meaningfulTokens: meaningfulTokens(in: addressed)
        )
        analysis.hasQuestionPunctuation = rulePack.textSegmentationPolicy.containsQuestionPunctuation(in: normalized)

        if plain.isEmpty {
            analysis.negativeSignals.append(rulePack.signalLabels.empty)
            return analysis
        }

        if QuestionIntentGate(rulePack: rulePack).isSmallTalk(plain) {
            analysis.negativeSignals.append(rulePack.signalLabels.smallTalk)
        }
        if isOperationalNoAnswerCheck(plain) {
            analysis.negativeSignals.append(rulePack.signalLabels.operationalCheck)
        }
        if QuestionIntentGate(rulePack: rulePack).isQuotedOrExplaining(plain) {
            analysis.negativeSignals.append(rulePack.signalLabels.reportedQuestion)
        }
        if RhetoricalQuestionFilter(rulePack: rulePack).isRhetorical(normalized) {
            analysis.negativeSignals.append(rulePack.signalLabels.rhetorical)
        }
        if RhetoricalQuestionFilter(rulePack: rulePack).isSelfAnswered(rawText) {
            analysis.negativeSignals.append(rulePack.signalLabels.selfAnswered)
        }
        if isFragment(addressed) {
            analysis.negativeSignals.append(rulePack.signalLabels.fragment)
        }
        if isLikelyTitleOrNounPhrase(addressed, rawText: rawText) {
            analysis.negativeSignals.append(rulePack.signalLabels.nounPhraseOrTitle)
        }

        if analysis.hasQuestionPunctuation {
            analysis.strongSignals.insert(.terminalQuestionMark)
        }
        if startsWithInterrogative(addressed) {
            analysis.strongSignals.insert(.interrogativeStarter)
        }
        if startsWithModalQuestionFrame(addressed) {
            analysis.strongSignals.insert(.modalQuestionFrame)
        }
        if hasIndirectQuestionFrame(addressed) {
            analysis.strongSignals.insert(.indirectQuestionFrame)
        }
        if hasActionRequestFrame(addressed) {
            analysis.strongSignals.insert(.actionRequestFrame)
        }
        if isDirectedToUser(plain, profile: profile) {
            analysis.strongSignals.insert(.directedToUser)
        }
        if isDirectedToGroup(addressed) {
            analysis.strongSignals.insert(.directedToGroup)
        }
        if !analysis.meaningfulTokens.isEmpty || hasNumericQuestionPayload(addressed) || containsCompactScript(addressed) && addressed.count >= rulePack.surfaceScoringPolicy.cjkMinimumCharacters {
            analysis.strongSignals.insert(.concreteObject)
        }
        if containsAny(addressed, rulePack.domainHintMarkers) {
            analysis.strongSignals.insert(.domainObject)
        }
        if hasContextualCarryover(plain: addressed, context: context) {
            analysis.strongSignals.insert(.contextualCarryover)
        }
        if hasContextualQuestionCue(plain: addressed, context: context) {
            analysis.strongSignals.insert(.contextualQuestionLead)
        }
        if isFinal && !isPartial {
            analysis.strongSignals.insert(.finalUtterance)
        }

        let structural = structuralQuestionProfile(
            rawText: rawText,
            plain: addressed,
            context: context,
            analysis: analysis
        )
        analysis.structuralQuestionScore = structural.questionScore
        analysis.objectFocusScore = structural.objectScore
        if structural.isQuestionLike {
            analysis.strongSignals.insert(.semanticQuestionShape)
        }
        if structural.hasAnswerableObjectFocus {
            analysis.strongSignals.insert(.answerableObjectFocus)
        }
        if adaptiveProfile.isPromoted(plain) {
            analysis.strongSignals.insert(.adaptivePromotion)
        }
        if adaptiveProfile.isSuppressed(plain) {
            analysis.negativeSignals.append(rulePack.signalLabels.adaptiveSuppressed)
        }

        analysis.hasWeakQuestionWordOnly = isWeakQuestionWordOnly(analysis)

        if isDeclarativeWithoutInterrogativeSyntax(addressed, analysis: analysis) {
            analysis.negativeSignals.append(rulePack.signalLabels.declarativeWithoutInterrogativeSyntax)
        }

        return analysis
    }

    func isCandidateSurface(_ analysis: QuestionSurfaceAnalysis, precisionMode: QAPrecisionMode) -> Bool {
        guard !analysis.isRejected else { return false }
        let policy = rulePack.surfaceCandidatePolicy
        if analysis.hasQuestionPunctuation {
            return !analysis.strongSignals.isDisjoint(with: policy.punctuatedAnySignals)
        }
        if policy.unpunctuatedGroups.contains(where: { acceptsCandidateGroup($0, analysis: analysis) }) {
            return true
        }
        return precisionMode != .highPrecision && analysis.hasWeakQuestionWordOnly
    }

    private func isWeakQuestionWordOnly(_ analysis: QuestionSurfaceAnalysis) -> Bool {
        let policy = rulePack.surfaceCandidatePolicy
        return !analysis.strongSignals.isEmpty
            && analysis.strongSignals.isSubset(of: policy.weakQuestionWordOnlySignals)
            && !analysis.hasQuestionPunctuation
            && !startsWithInterrogative(analysis.textAfterAddress, requireObject: true)
    }

    private func acceptsCandidateGroup(_ group: QuestionSignalGroupPolicy, analysis: QuestionSurfaceAnalysis) -> Bool {
        guard group.all.allSatisfy({ analysis.strongSignals.contains($0) }) else { return false }
        if !group.any.isEmpty, !analysis.strongSignals.isDisjoint(with: group.any) {
            return true
        }
        if group.minStructuralQuestionScore.map({ analysis.structuralQuestionScore >= $0 }) == true {
            return true
        }
        if group.minObjectFocusScore.map({ analysis.objectFocusScore >= $0 }) == true {
            return true
        }
        if group.requiresInterrogativeObject {
            return startsWithInterrogative(analysis.textAfterAddress, requireObject: true)
        }
        return group.any.isEmpty && group.minStructuralQuestionScore == nil && group.minObjectFocusScore == nil
    }

    func confidence(for analysis: QuestionSurfaceAnalysis, isPartial: Bool, precisionMode: QAPrecisionMode) -> Double {
        let scoring = rulePack.surfaceScoringPolicy
        if analysis.isRejected { return scoring.rejectedConfidence }
        var score = scoring.confidenceBase
        if analysis.hasQuestionPunctuation { score += scoring.questionPunctuationConfidence }
        if analysis.strongSignals.contains(.interrogativeStarter) { score += scoring.interrogativeConfidence }
        if analysis.strongSignals.contains(.modalQuestionFrame) { score += scoring.modalConfidence }
        if analysis.strongSignals.contains(.indirectQuestionFrame) { score += scoring.indirectConfidence }
        if analysis.strongSignals.contains(.actionRequestFrame) { score += scoring.actionConfidence }
        if analysis.strongSignals.contains(.directedToUser) { score += scoring.directedUserConfidence }
        if analysis.strongSignals.contains(.directedToGroup) { score += scoring.directedGroupConfidence }
        if analysis.strongSignals.contains(.concreteObject) { score += scoring.concreteObjectConfidence }
        if analysis.strongSignals.contains(.domainObject) { score += scoring.domainObjectConfidence }
        if analysis.strongSignals.contains(.semanticQuestionShape) {
            score += min(scoring.semanticShapeConfidenceMax, analysis.structuralQuestionScore * scoring.semanticShapeConfidenceWeight)
        }
        if analysis.strongSignals.contains(.answerableObjectFocus) {
            score += min(scoring.answerableFocusConfidenceMax, analysis.objectFocusScore * scoring.answerableFocusConfidenceWeight)
        }
        if analysis.strongSignals.contains(.adaptivePromotion) { score += scoring.adaptivePromotionConfidence }
        if analysis.strongSignals.contains(.contextualCarryover) { score += scoring.contextualCarryoverConfidence }
        if analysis.strongSignals.contains(.contextualQuestionLead) { score += scoring.interrogativeConfidence }
        if analysis.strongSignals.contains(.finalUtterance) { score += scoring.finalUtteranceConfidence }
        if analysis.hasWeakQuestionWordOnly { score -= scoring.weakQuestionWordPenalty }
        if isPartial { score -= precisionMode == .highPrecision ? scoring.partialHighPrecisionPenalty : scoring.partialStandardPenalty }
        return min(max(score, scoring.minConfidence), scoring.maxConfidence)
    }

    private func structuralQuestionProfile(
        rawText: String,
        plain: String,
        context: TranscriptContext?,
        analysis: QuestionSurfaceAnalysis
    ) -> StructuralQuestionProfile {
        let tokens = rulePack.textSegmentationPolicy.lexicalTokens(in: plain)
        let tokenCount = tokens.count
        let meaningfulCount = analysis.meaningfulTokens.count
        let tokenBase = max(tokenCount, 1)
        let objectDensity = Double(meaningfulCount) / Double(tokenBase)
        let hasNamedEntity = hasNamedEntitySignal(in: rawText)
        let hasContextOverlap = hasMeaningfulContextOverlap(plain: plain, context: context)
        let hasCueNearLead = hasQuestionCueNearLead(plain)
        let scoring = rulePack.surfaceScoringPolicy
        let compactUtterance = tokenCount >= scoring.compactUtteranceMinTokens && tokenCount <= scoring.compactUtteranceMaxTokens
        let longEnoughCJK = containsCompactScript(plain) && plain.count >= scoring.cjkMinimumCharacters

        var objectScore = min(scoring.objectMeaningfulTokenMax, Double(meaningfulCount) * scoring.objectMeaningfulTokenWeight)
        objectScore += min(scoring.objectDensityMax, objectDensity * scoring.objectDensityWeight)
        if hasNumericQuestionPayload(plain) { objectScore += scoring.objectNumericPayloadBonus }
        if containsAny(plain, rulePack.domainHintMarkers) { objectScore += scoring.objectDomainBonus }
        if hasContextOverlap { objectScore += scoring.objectContextOverlapBonus }
        if hasNamedEntity { objectScore += scoring.objectNamedEntityBonus }
        if longEnoughCJK { objectScore += scoring.objectCJKBonus }
        objectScore = min(objectScore, 1.0)

        var questionScore = 0.0
        if analysis.hasQuestionPunctuation { questionScore += scoring.questionPunctuationScore }
        if analysis.strongSignals.contains(.interrogativeStarter) { questionScore += scoring.questionInterrogativeScore }
        if analysis.strongSignals.contains(.modalQuestionFrame) { questionScore += scoring.questionModalScore }
        if analysis.strongSignals.contains(.indirectQuestionFrame) { questionScore += scoring.questionIndirectScore }
        if analysis.strongSignals.contains(.actionRequestFrame) { questionScore += scoring.questionActionScore }
        if analysis.strongSignals.contains(.contextualQuestionLead) {
            questionScore += scoring.questionInterrogativeScore + scoring.questionCueNearLeadScore
        }
        if hasCueNearLead { questionScore += scoring.questionCueNearLeadScore }
        if compactUtterance && objectScore >= scoring.questionCompactObjectThreshold { questionScore += scoring.questionCompactUtteranceScore }
        if hasContextOverlap { questionScore += scoring.questionContextOverlapScore }
        if hasNamedEntity { questionScore += scoring.questionNamedEntityScore }
        if longEnoughCJK && objectScore >= scoring.questionCJKObjectThreshold { questionScore += scoring.questionCJKScore }
        if analysis.strongSignals.contains(.finalUtterance) { questionScore += scoring.questionFinalUtteranceScore }

        return StructuralQuestionProfile(
            questionScore: min(questionScore, 1.0),
            objectScore: objectScore,
            answerableObjectFocusThreshold: scoring.answerableObjectFocusThreshold,
            questionLikeThreshold: scoring.questionLikeThreshold
        )
    }

    private func hasQuestionCueNearLead(_ plain: String) -> Bool {
        if isRejectedQuestionLead(plain) || hasUnsatisfiedConditionalQuestionLead(plain) {
            return false
        }
        let words = rulePack.textSegmentationPolicy
            .lexicalTokens(in: plain)
            .prefix(rulePack.textSegmentationPolicy.questionCueLeadTokenLimit)
        guard !words.isEmpty else { return false }
        let lead = words.joined(separator: " ")
        let markers = rulePack.directQuestionMarkers
            + rulePack.modalQuestionStarters
            + rulePack.indirectQuestionMarkers
            + rulePack.actionRequestMarkers
        return markers.contains { marker in
            rulePack.textSegmentationPolicy.matchesLeadOrCompactMarker(marker, in: lead)
                || rulePack.textSegmentationPolicy.matchesLeadOrCompactMarker(marker, in: plain)
        }
    }

    private func hasNamedEntitySignal(in rawText: String) -> Bool {
        switch rulePack.textSegmentationPolicy.namedEntityRecognitionStrategy {
        case .naturalLanguage:
            return hasNaturalLanguageNamedEntitySignal(in: rawText)
        case .heuristic:
            return hasHeuristicNamedEntitySignal(in: rawText)
        case .automatic:
            return hasHeuristicNamedEntitySignal(in: rawText) || hasNaturalLanguageNamedEntitySignal(in: rawText)
        }
    }

    private func hasNaturalLanguageNamedEntitySignal(in rawText: String) -> Bool {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }

        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let range = text.startIndex..<text.endIndex
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        var foundEntity = false

        tagger.enumerateTags(in: range, unit: .word, scheme: .nameType, options: options) { tag, _ in
            guard let tag else { return true }
            if tag == .personalName || tag == .organizationName || tag == .placeName {
                foundEntity = true
                return false
            }
            return true
        }

        return foundEntity
    }

    private func hasHeuristicNamedEntitySignal(in rawText: String) -> Bool {
        let tokens = rawText
            .split { rulePack.textSegmentationPolicy.isNamedEntitySeparator($0) }
            .map(String.init)
        for (index, token) in tokens.enumerated() {
            guard token.count >= rulePack.textSegmentationPolicy.minimumNamedEntityTokenLength else { continue }
            let scalars = token.unicodeScalars
            let letterScalars = scalars.filter { CharacterSet.letters.contains($0) }
            guard letterScalars.count >= rulePack.textSegmentationPolicy.minimumNamedEntityLetterCount else { continue }
            let uppercaseCount = letterScalars.filter { CharacterSet.uppercaseLetters.contains($0) }.count
            let hasDigit = scalars.contains { CharacterSet.decimalDigits.contains($0) }
            if uppercaseCount >= rulePack.textSegmentationPolicy.namedEntityUppercaseMinimum || (hasDigit && !letterScalars.isEmpty) {
                return true
            }
            if index > 0, let first = letterScalars.first, CharacterSet.uppercaseLetters.contains(first) {
                return true
            }
        }
        return false
    }

    private func hasMeaningfulContextOverlap(plain: String, context: TranscriptContext?) -> Bool {
        guard let context else { return false }
        let current = Set(meaningfulTokens(in: plain))
        guard !current.isEmpty else { return false }

        var contextPool = QuestionDetectionService.normalize(context.mediumTranscript + " " + context.completeTranscript)
        let currentSegment = QuestionDetectionService.normalize(context.currentSegment?.text ?? "")
        if !currentSegment.isEmpty {
            contextPool = contextPool.replacingOccurrences(of: currentSegment, with: " ")
        }
        guard !contextPool.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let contextTerms = Set(meaningfulTokens(in: contextPool))
        guard !contextTerms.isEmpty else { return false }
        return current.intersection(contextTerms).count >= min(rulePack.surfaceScoringPolicy.contextOverlapMaximumRequiredMatches, current.count)
    }

    private func removeLeadingAddress(from plain: String, profile: UserMeetingProfile?) -> String {
        var text = plain
        let aliases = ([profile?.userName].compactMap { $0 } + (profile?.userAliases ?? []))
            .map(QuestionDetectionService.normalize)
            .filter { !$0.isEmpty }
        for alias in aliases where rulePack.textSegmentationPolicy.matchesLeadMarker(alias, in: text) {
            text = text.removingPrefix(alias)
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: rulePack.textSegmentationPolicy.addressSeparatorTrimCharacters)))
            break
        }
        let words = rulePack.textSegmentationPolicy.lexicalTokens(in: text)
        if words.count >= rulePack.textSegmentationPolicy.leadAddressMinimumTokens,
           let first = words.first,
           first.count >= rulePack.textSegmentationPolicy.leadAddressMinimumTokenLength,
           !nonAddressLeadTokens.contains(first),
           !rulePack.stopWords.contains(first),
           !rulePack.lowInformationWords.contains(first) {
            let remainder = words.dropFirst().joined(separator: " ")
            if startsWithInterrogative(remainder)
                || startsWithModalQuestionFrame(remainder)
                || hasActionRequestFrame(remainder) {
                return remainder
            }
        }
        return text
    }

    private func removeLeadingDiscourse(from plain: String) -> String {
        for normalized in rulePack.discourseLeadPhrases {
            guard rulePack.textSegmentationPolicy.matchesLeadMarker(normalized, in: plain) else { continue }
            guard !isConfiguredQuestionIntentLead(normalized) else { continue }
            let remainder = plain.removingPrefix(normalized)
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: rulePack.textSegmentationPolicy.addressSeparatorTrimCharacters)))
            if isQuestionLikeLead(remainder) {
                return remainder
            }
        }
        return plain
    }

    private func isQuestionLikeLead(_ text: String) -> Bool {
        startsWithInterrogative(text)
            || startsWithModalQuestionFrame(text)
            || hasIndirectQuestionFrame(text)
            || hasActionRequestFrame(text)
    }

    private func isConfiguredQuestionIntentLead(_ normalizedPrefix: String) -> Bool {
        let normalizedPrefix = QuestionDetectionService.normalize(normalizedPrefix)
        guard !normalizedPrefix.isEmpty else { return false }
        let markers = rulePack.directQuestionMarkers
            + rulePack.indirectQuestionMarkers
            + rulePack.actionRequestMarkers
            + rulePack.modalQuestionStarters
        return markers.contains { marker in
            let normalizedMarker = QuestionDetectionService.normalize(marker)
            return normalizedMarker == normalizedPrefix
                || rulePack.textSegmentationPolicy.matchesLeadMarker(normalizedPrefix, in: normalizedMarker)
        }
    }

    private func startsWithInterrogative(_ text: String, requireObject: Bool = false) -> Bool {
        if isRejectedQuestionLead(text) || hasUnsatisfiedConditionalQuestionLead(text) {
            return false
        }
        guard rulePack.directQuestionMarkers.contains(where: { marker in questionCueMatchesLeadOrCJKBoundary(text, marker: marker) }) else {
            return false
        }
        guard requireObject else { return true }
        return meaningfulTokens(in: text).count >= 1
            || hasNumericQuestionPayload(text)
            || containsAny(text, rulePack.domainHintMarkers)
            || containsCompactScript(text) && text.count >= rulePack.surfaceScoringPolicy.cjkMinimumCharacters
    }

    private func startsWithModalQuestionFrame(_ text: String) -> Bool {
        if isRejectedQuestionLead(text) {
            return false
        }
        if hasUnsatisfiedConditionalQuestionLead(text) {
            return false
        }
        guard rulePack.modalQuestionStarters.contains(where: { marker in
            rulePack.textSegmentationPolicy.matchesLeadMarker(marker, in: text)
        }) else { return false }
        return meaningfulTokens(in: text).count >= 1 || containsAny(text, rulePack.domainHintMarkers)
    }

    private func isRejectedQuestionLead(_ text: String) -> Bool {
        rulePack.modalQuestionRejectPrefixes.contains {
            rulePack.textSegmentationPolicy.matchesLeadMarker($0, in: text)
        }
    }

    private func hasUnsatisfiedConditionalQuestionLead(_ text: String) -> Bool {
        guard rulePack.modalQuestionConditionalPrefixes.contains(where: {
            rulePack.textSegmentationPolicy.matchesLeadMarker($0, in: text)
        }) else { return false }
        return !containsAny(text, rulePack.modalQuestionConditionalObjectMarkers)
    }

    private func hasIndirectQuestionFrame(_ text: String) -> Bool {
        containsAny(text, rulePack.indirectQuestionMarkers)
    }

    private func hasActionRequestFrame(_ text: String) -> Bool {
        rulePack.actionRequestMarkers.contains { marker in
            rulePack.textSegmentationPolicy.matchesLeadMarker(marker, in: text)
        }
    }

    private func isDirectedToUser(_ plain: String, profile: UserMeetingProfile?) -> Bool {
        let aliases = ([profile?.userName].compactMap { $0 } + (profile?.userAliases ?? []))
            .map(QuestionDetectionService.normalize)
            .filter { !$0.isEmpty }
        return aliases.contains { alias in
            rulePack.textSegmentationPolicy.containsMarker(alias, in: plain)
        }
    }

    private func isDirectedToGroup(_ text: String) -> Bool {
        containsAny(text, rulePack.groupAddressMarkers)
    }

    private func isOperationalNoAnswerCheck(_ plain: String) -> Bool {
        rulePack.operationalNoAnswerPhrases.contains { phrase in
            rulePack.textSegmentationPolicy.containsBoundedMarker(phrase, in: plain)
        }
    }

    private func isFragment(_ text: String) -> Bool {
        if rulePack.fragmentPhrases.contains(text) { return true }
        for prefix in rulePack.fragmentPrefixes where text == prefix {
            return true
        }
        for prefix in rulePack.fragmentPhrases where rulePack.textSegmentationPolicy.matchesLeadMarker(prefix, in: text) {
            let remainder = text.removingPrefix(prefix).trimmingCharacters(in: .whitespacesAndNewlines)
            if meaningfulTokens(in: remainder).isEmpty
                && !hasNumericQuestionPayload(remainder)
                && !containsAny(remainder, rulePack.domainHintMarkers) {
                return true
            }
        }
        return rulePack.textSegmentationPolicy.hasFragmentTerminalMarker(in: text)
            && rulePack.textSegmentationPolicy.lexicalTokenCount(in: text) <= rulePack.textSegmentationPolicy.fragmentEllipsisMaximumTokens
    }

    private func isLikelyTitleOrNounPhrase(_ text: String, rawText: String) -> Bool {
        guard !rulePack.textSegmentationPolicy.containsQuestionPunctuation(in: rawText) else { return false }
        guard rulePack.textSegmentationPolicy.lexicalTokenCount(in: text) >= rulePack.textSegmentationPolicy.titleMinimumTokens else { return false }
        let hasVerbLikeQuestionFrame = startsWithInterrogative(text, requireObject: true)
            || startsWithModalQuestionFrame(text)
            || hasIndirectQuestionFrame(text)
            || hasActionRequestFrame(text)
        guard !hasVerbLikeQuestionFrame else { return false }
        return containsAny(text, rulePack.nonQuestionTitleMarkers)
    }

    private func isDeclarativeWithoutInterrogativeSyntax(_ text: String, analysis: QuestionSurfaceAnalysis) -> Bool {
        if analysis.hasQuestionPunctuation { return false }
        if analysis.strongSignals.contains(.modalQuestionFrame)
            || analysis.strongSignals.contains(.indirectQuestionFrame)
            || analysis.strongSignals.contains(.actionRequestFrame) {
            return false
        }
        if startsWithInterrogative(text, requireObject: true) { return false }
        return rulePack.textSegmentationPolicy.lexicalTokenCount(in: text) >= rulePack.textSegmentationPolicy.declarativeMinimumTokens
            && containsAny(text, rulePack.declarativeBridgeMarkers)
    }

    private func hasContextualCarryover(plain: String, context: TranscriptContext?) -> Bool {
        guard let context else { return false }
        let hasPronoun = rulePack.textSegmentationPolicy.lexicalTokens(in: plain).contains { rulePack.contextualPronouns.contains($0) }
        guard hasPronoun else { return false }
        let recent = QuestionDetectionService.normalize(context.recentTranscript + " " + context.mediumTranscript)
        return containsAny(recent, rulePack.domainHintMarkers)
            || meaningfulTokens(in: recent).count >= rulePack.surfaceScoringPolicy.contextualCarryoverMinimumRecentTerms
    }

    private func hasContextualQuestionCue(plain: String, context: TranscriptContext?) -> Bool {
        ContextualQuestionCueMatcher(rulePack: rulePack).matches(plain: plain, context: context)
    }

    private func meaningfulTokens(in plain: String) -> [String] {
        rulePack.textSegmentationPolicy
            .lexicalTokens(in: plain)
            .filter { token in
                token.count >= rulePack.textSegmentationPolicy.meaningfulTokenMinimumLength(for: token)
                    && token.unicodeScalars.contains { CharacterSet.letters.contains($0) }
                    && !rulePack.stopWords.contains(token)
                    && !rulePack.lowInformationWords.contains(token)
            }
    }

    private func hasNumericQuestionPayload(_ text: String) -> Bool {
        QuestionDetectionService.hasNumericQuestionPayload(text, rulePack: rulePack)
    }

    private func containsAny(_ text: String, _ patterns: [String]) -> Bool {
        patterns.contains { pattern in
            rulePack.textSegmentationPolicy.containsBoundedMarker(pattern, in: text)
        }
    }

    private func questionCueMatchesLeadOrCJKBoundary(_ text: String, marker: String) -> Bool {
        rulePack.textSegmentationPolicy.matchesLeadOrCompactMarker(marker, in: text)
    }

    private func containsCompactScript(_ text: String) -> Bool {
        rulePack.textSegmentationPolicy.containsCompactScript(in: text)
    }

    private var nonAddressLeadTokens: Set<String> {
        rulePack.nonAddressLeadTokens
    }
}

struct QuestionCandidateExtractor {
    var rulePack: QuestionIntentRulePack = .default
    var adaptiveProfile: QuestionAnsweringAdaptiveProfile = QuestionAnsweringAdaptiveProfile()
    var precisionMode: QAPrecisionMode = .highPrecision
    var analyzer: QuestionSurfaceAnalyzer {
        QuestionSurfaceAnalyzer(rulePack: rulePack, adaptiveProfile: adaptiveProfile)
    }

    func candidates(from frames: [UtteranceFrame], context: TranscriptContext, profile: UserMeetingProfile? = nil) -> [QuestionCandidate] {
        detectionResult(from: frames, context: context, profile: profile).surfaceCandidates
    }

    func detectionResult(from frames: [UtteranceFrame], context: TranscriptContext, profile: UserMeetingProfile? = nil) -> QuestionDetectionResult {
        var surfaceCandidates: [QuestionCandidate] = []
        var rejectedFrames: [QuestionRejectedFrame] = []

        for frame in frames {
            let analysis = analyzer.analyze(
                text: frame.rawText,
                normalized: frame.normalizedText,
                context: context,
                profile: profile,
                isPartial: frame.isPartial,
                isFinal: frame.isFinal
            )
            let surfaceSignals = analysis.strongSignals.map(\.rawValue).sorted()
            let suppressionSignals = analysis.negativeSignals
            guard analyzer.isCandidateSurface(analysis, precisionMode: precisionMode) else {
                rejectedFrames.append(
                    QuestionRejectedFrame(
                        frame: frame,
                        surfaceSignals: surfaceSignals,
                        suppressionSignals: suppressionSignals,
                        hardSuppressionSignals: rulePack.hardSuppressionSignals,
                        reason: suppressionSignals.isEmpty
                            ? rulePack.reasons.surfaceBelowCandidateThreshold
                            : suppressionSignals.joined(separator: ",")
                    )
                )
                continue
            }
            surfaceCandidates.append(
                QuestionCandidate(
                    meetingId: frame.meetingId,
                    rawText: frame.rawText,
                    normalizedText: frame.normalizedText,
                    language: frame.language,
                    speakerId: frame.speakerId,
                    speakerLabel: frame.speakerLabel,
                    startTime: frame.startTime,
                    endTime: frame.endTime,
                    sourceSegmentIds: [frame.sourceSegmentId],
                    isPartial: frame.isPartial,
                    multimodalSignal: frame.multimodalSignal,
                    discovery: QuestionCandidateDiscovery(
                        source: .surface,
                        surfaceSignals: surfaceSignals,
                        surfaceSuppressionSignals: suppressionSignals
                    )
                )
            )
        }

        return QuestionDetectionResult(
            surfaceCandidates: surfaceCandidates,
            rejectedFrames: rejectedFrames
        )
    }
}

struct QuestionSpanExtractor: Sendable {
    var rulePack: QuestionIntentRulePack = .default

    func extractedQuestion(
        from rawText: String,
        language: String?,
        profile: UserMeetingProfile? = nil
    ) -> String {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rawText }

        var text = trimmed
        text = removeLeadingAddress(from: text, profile: profile)
        text = removeLeadingDiscourse(from: text)
        text = removeTrailingSelfAnswer(from: text)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: rulePack.textSegmentationPolicy.spanTrailingTrimCharacters))
        return text.isEmpty ? trimmed : text
    }

    private func removeLeadingAddress(from text: String, profile: UserMeetingProfile?) -> String {
        var aliases = ([profile?.userName].compactMap { $0 } + (profile?.userAliases ?? []))
        aliases.append(contentsOf: rulePack.groupAddressMarkers)
        for alias in aliases.sorted(by: { $0.count > $1.count }) {
            let normalizedAlias = QuestionDetectionService.normalize(alias)
            let normalizedText = QuestionDetectionService.normalize(text)
            guard !normalizedAlias.isEmpty,
                  rulePack.textSegmentationPolicy.matchesLeadMarker(normalizedAlias, in: normalizedText) else { continue }
            let dropCount = min(alias.count, text.count)
            let remainder = String(text.dropFirst(dropCount))
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: rulePack.textSegmentationPolicy.addressSeparatorTrimCharacters)))
            if isQuestionLike(remainder) {
                return remainder
            }
        }
        return removeDynamicLeadingAddress(from: text) ?? text
    }

    private func removeDynamicLeadingAddress(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstTokenRange = firstLeadTokenRange(in: trimmed) else { return nil }
        let rawFirstToken = String(trimmed[firstTokenRange])
        let firstToken = QuestionDetectionService.normalize(rawFirstToken)
        guard isPotentialDynamicAddressToken(firstToken) else { return nil }

        let remainder = String(trimmed[firstTokenRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: rulePack.textSegmentationPolicy.addressSeparatorTrimCharacters)))
        guard hasQuestionLeadAfterOptionalDiscourse(remainder) else { return nil }
        return remainder
    }

    private func firstLeadTokenRange(in text: String) -> Range<String.Index>? {
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isLetter || character.isNumber {
                if start == nil {
                    start = index
                }
            } else if let start {
                return start..<index
            } else if !character.isWhitespace {
                return nil
            }
            index = text.index(after: index)
        }
        if let start {
            return start..<text.endIndex
        }
        return nil
    }

    private func isPotentialDynamicAddressToken(_ token: String) -> Bool {
        guard token.count >= rulePack.textSegmentationPolicy.leadAddressMinimumTokenLength else { return false }
        if rulePack.textSegmentationPolicy.containsCompactScript(in: token) { return false }
        if rulePack.nonAddressLeadTokens.contains(token)
            || rulePack.stopWords.contains(token)
            || rulePack.lowInformationWords.contains(token)
            || rulePack.domainHintMarkers.contains(token) {
            return false
        }
        return !isConfiguredQuestionLeadToken(token)
    }

    private func isConfiguredQuestionLeadToken(_ token: String) -> Bool {
        let markers = rulePack.directQuestionMarkers
            + rulePack.indirectQuestionMarkers
            + rulePack.actionRequestMarkers
            + rulePack.modalQuestionStarters
            + rulePack.discourseLeadPhrases
        return markers.contains { marker in
            let normalized = QuestionDetectionService.normalize(marker)
            return normalized == token || rulePack.textSegmentationPolicy.matchesLeadMarker(token, in: normalized)
        }
    }

    private func removeLeadingDiscourse(from text: String) -> String {
        for normalizedPrefix in rulePack.discourseLeadPhrases.sorted(by: { $0.count > $1.count }) {
            let normalizedText = QuestionDetectionService.normalize(text)
            guard rulePack.textSegmentationPolicy.matchesLeadMarker(normalizedPrefix, in: normalizedText) else { continue }
            guard !isConfiguredQuestionIntentLead(normalizedPrefix) else { continue }
            let remainder = String(text.dropFirst(min(normalizedPrefix.count, text.count)))
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: rulePack.textSegmentationPolicy.addressSeparatorTrimCharacters)))
            if isQuestionLike(remainder) {
                return remainder
            }
        }
        return text
    }

    private func removeTrailingSelfAnswer(from text: String) -> String {
        let normalized = QuestionDetectionService.normalize(text)
        for normalizedMarker in rulePack.selfAnswerSuffixMarkers {
            guard let range = normalized.range(of: normalizedMarker) else { continue }
            let distance = normalized.distance(from: normalized.startIndex, to: range.lowerBound)
            guard distance > 0, distance < text.count else { continue }
            let index = text.index(text.startIndex, offsetBy: distance)
            return String(text[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private func isQuestionLike(_ text: String) -> Bool {
        let normalized = QuestionDetectionService.normalize(text)
        guard !normalized.isEmpty else { return false }
        let plain = QuestionIntentGate.plainQuestionText(normalized, textPolicy: rulePack.textSegmentationPolicy)
        return rulePack.textSegmentationPolicy.containsQuestionPunctuation(in: normalized)
            || hasQuestionLead(plain)
    }

    private func hasQuestionLead(_ text: String) -> Bool {
        let normalized = QuestionDetectionService.normalize(text)
        guard !normalized.isEmpty else { return false }
        let plain = QuestionIntentGate.plainQuestionText(normalized, textPolicy: rulePack.textSegmentationPolicy)
        return rulePack.directQuestionMarkers.contains { rulePack.textSegmentationPolicy.matchesLeadOrCompactMarker($0, in: plain) }
            || rulePack.indirectQuestionMarkers.contains { rulePack.textSegmentationPolicy.matchesLeadOrCompactMarker($0, in: plain) }
            || rulePack.actionRequestMarkers.contains { rulePack.textSegmentationPolicy.matchesLeadOrCompactMarker($0, in: plain) }
            || rulePack.modalQuestionStarters.contains { rulePack.textSegmentationPolicy.matchesLeadOrCompactMarker($0, in: plain) }
    }

    private func isConfiguredQuestionIntentLead(_ normalizedPrefix: String) -> Bool {
        let normalizedPrefix = QuestionDetectionService.normalize(normalizedPrefix)
        guard !normalizedPrefix.isEmpty else { return false }
        let markers = rulePack.directQuestionMarkers
            + rulePack.indirectQuestionMarkers
            + rulePack.actionRequestMarkers
            + rulePack.modalQuestionStarters
        return markers.contains { marker in
            let normalizedMarker = QuestionDetectionService.normalize(marker)
            return normalizedMarker == normalizedPrefix
                || rulePack.textSegmentationPolicy.matchesLeadMarker(normalizedPrefix, in: normalizedMarker)
        }
    }

    private func hasQuestionLeadAfterOptionalDiscourse(_ text: String) -> Bool {
        if hasQuestionLead(text) { return true }
        let withoutDiscourse = removeLeadingDiscourse(from: text)
        guard withoutDiscourse != text else { return false }
        return hasQuestionLead(withoutDiscourse)
    }
}

struct QuestionDetectionService {
    private let languageDetector: AppleLanguageDetectionService
    private let rulePack: QuestionIntentRulePack
    private let adaptiveProfile: QuestionAnsweringAdaptiveProfile
    private let precisionMode: QAPrecisionMode
    private let frameBuilder: UtteranceFrameBuilder
    private let extractor: QuestionCandidateExtractor

    init(
        rulePack: QuestionIntentRulePack = .default,
        adaptiveProfile: QuestionAnsweringAdaptiveProfile = QuestionAnsweringAdaptiveProfile(),
        precisionMode: QAPrecisionMode = .highPrecision,
        languageDetector: AppleLanguageDetectionService = AppleLanguageDetectionService()
    ) {
        self.rulePack = rulePack
        self.adaptiveProfile = adaptiveProfile
        self.precisionMode = precisionMode
        self.frameBuilder = UtteranceFrameBuilder(
            textPolicy: rulePack.textSegmentationPolicy,
            questionSplitMarkers: rulePack.embeddedQuestionSplitMarkers
                + rulePack.directQuestionMarkers
                + rulePack.modalQuestionStarters
                + rulePack.indirectQuestionMarkers,
            questionSplitPreambleMarkers: rulePack.embeddedQuestionSplitPreambleMarkers,
            questionSplitSuppressionLeadMarkers: rulePack.quotedOrExplainingMarkers,
            questionSplitContinuationLeadMarkers: rulePack.embeddedQuestionSplitContinuationLeadMarkers,
            maximumQuestionSplitPreambleTokens: rulePack.embeddedQuestionSplitMaximumPreambleTokens
        )
        self.extractor = QuestionCandidateExtractor(
            rulePack: rulePack,
            adaptiveProfile: adaptiveProfile,
            precisionMode: precisionMode
        )
        self.languageDetector = languageDetector
    }

    func detectCandidates(
        from segment: TranscriptSegment,
        context: TranscriptContext,
        profile: UserMeetingProfile? = nil
    ) -> [QuestionCandidate] {
        detectCandidates(from: segment, context: context, signal: nil, profile: profile)
    }

    func detectCandidates(
        from segment: TranscriptSegment,
        context: TranscriptContext,
        signal: QuestionMultimodalSignal?,
        profile: UserMeetingProfile? = nil
    ) -> [QuestionCandidate] {
        detect(from: segment, context: context, signal: signal, profile: profile).surfaceCandidates
    }

    func detect(
        from segment: TranscriptSegment,
        context: TranscriptContext,
        profile: UserMeetingProfile? = nil
    ) -> QuestionDetectionResult {
        detect(from: segment, context: context, signal: nil, profile: profile)
    }

    func detect(
        from segment: TranscriptSegment,
        context: TranscriptContext,
        signal: QuestionMultimodalSignal?,
        profile: UserMeetingProfile? = nil
    ) -> QuestionDetectionResult {
        let frames = frameBuilder.frames(from: segment, context: context, signal: signal)
        guard !frames.isEmpty else { return .empty }
        let result = extractor.detectionResult(from: frames, context: context, profile: profile)
        return QuestionDetectionResult(
            surfaceCandidates: result.surfaceCandidates.map { candidate in
                if candidate.language != nil { return candidate }
                return QuestionCandidate(
                    id: candidate.id,
                    meetingId: candidate.meetingId,
                    rawText: candidate.rawText,
                    normalizedText: candidate.normalizedText,
                    language: languageDetector.dominantLanguage(for: candidate.rawText),
                    speakerId: candidate.speakerId,
                    speakerLabel: candidate.speakerLabel,
                    startTime: candidate.startTime,
                    endTime: candidate.endTime,
                    sourceSegmentIds: candidate.sourceSegmentIds,
                    isPartial: candidate.isPartial,
                    detectedAt: candidate.detectedAt,
                    multimodalSignal: candidate.multimodalSignal,
                    discovery: candidate.discovery,
                    classification: candidate.classification,
                    status: candidate.status
                )
            },
            rejectedFrames: result.rejectedFrames
        )
    }

    func isLikelyQuestion(_ normalized: String, profile: UserMeetingProfile? = nil) -> Bool {
        let analyzer = QuestionSurfaceAnalyzer(rulePack: rulePack, adaptiveProfile: adaptiveProfile)
        let analysis = analyzer.analyze(
            text: normalized,
            normalized: normalized,
            context: nil,
            profile: profile,
            isPartial: false,
            isFinal: true
        )
        return analyzer.isCandidateSurface(analysis, precisionMode: precisionMode)
    }

    static func normalize(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func containsCompactScript(_ text: String, textPolicy: QuestionTextSegmentationPolicy = .fallback) -> Bool {
        textPolicy.containsCompactScript(in: text)
    }

    static func containsCJK(_ text: String, textPolicy: QuestionTextSegmentationPolicy = .fallback) -> Bool {
        containsCompactScript(text, textPolicy: textPolicy)
    }

    static func hasNumericQuestionPayload(_ text: String, rulePack: QuestionIntentRulePack = .default) -> Bool {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return false }

        let digitCount = digitGroupCount(in: normalized)
        let numberWords = rulePack.numericWords
        let wordNumberCount = rulePack.textSegmentationPolicy
            .lexicalTokens(in: normalized)
            .filter { numberWords.contains($0) }
            .count
        let numericCount = digitCount + wordNumberCount
        guard numericCount >= rulePack.textSegmentationPolicy.numericPayloadMinimumCount else { return false }

        return rulePack.numericOperatorMarkers.contains { normalizedMarker in
            guard !normalizedMarker.isEmpty else { return false }
            return rulePack.textSegmentationPolicy.containsMarker(normalizedMarker, in: normalized)
        }
    }

    private static func digitGroupCount(in text: String) -> Int {
        var count = 0
        var isInsideDigitGroup = false
        for character in text {
            if character.isNumber {
                if !isInsideDigitGroup {
                    count += 1
                    isInsideDigitGroup = true
                }
            } else {
                isInsideDigitGroup = false
            }
        }
        return count
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String {
        guard hasPrefix(prefix) else { return self }
        return String(dropFirst(prefix.count))
    }
}
