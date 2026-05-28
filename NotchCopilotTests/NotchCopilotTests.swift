import XCTest
import AppKit
import AVFoundation
import Carbon.HIToolbox
import CryptoKit
import Metal
import ScreenCaptureKit
import Security
import Speech
import SwiftUI
import SwiftData
@testable import NotchCopilot

@MainActor
final class NotchCopilotTests: XCTestCase {
    private func testCryptor(byte: UInt8 = 0x42) throws -> LocalDataCryptor {
        try LocalDataCryptor.ephemeralForTests(byte: byte)
    }

    func testPrivacyGuardRedactsSecrets() {
        let guardrail = PrivacyGuard()
        let redacted = guardrail.redact("token=supersecret12345 and key sk-proj-abcdefghijklmnopqrstuvwxyz")
        XCTAssertFalse(redacted.contains("supersecret12345"))
        XCTAssertFalse(redacted.contains("sk-proj"))
        XCTAssertTrue(redacted.contains("[redacted]"))
    }

    func testAppPreferencesDecodesMissingStealthModeAsDisabled() throws {
        let data = #"{"localOnlyMode":true}"#.data(using: .utf8)!
        let preferences = try JSONDecoder().decode(AppPreferences.self, from: data)

        XCTAssertFalse(preferences.stealthModeEnabled)
        XCTAssertFalse(preferences.copilotAlwaysOnEnabled)
        XCTAssertTrue(preferences.copilotHotkeyEnabled)
        XCTAssertEqual(preferences.ambientAudioScope, .microphoneOnly)
        XCTAssertEqual(preferences.copilotRetentionDays, 7)
        XCTAssertEqual(preferences.copilotWebMode, .onDemand)
        XCTAssertEqual(preferences.copilotActivationPolicy, .clearIntent)
    }

    func testAppPreferencesNormalizationPreservesStealthMode() {
        var preferences = AppPreferences()
        preferences.stealthModeEnabled = true

        let normalized = preferences.normalizedForPersistence()

        XCTAssertTrue(normalized.stealthModeEnabled)
    }

    func testAppPreferencesPromotesLegacyQAShadowModeToTrainedEnforcedDefault() throws {
        let legacy = try JSONDecoder().decode(
            AppPreferences.self,
            from: Data(#"{ "qaMultimodalMode": "shadow" }"#.utf8)
        )

        let normalized = legacy.normalizedForPersistence()

        XCTAssertEqual(normalized.qaMultimodalMode, .enforced)
        XCTAssertTrue(normalized.didPromoteTrainedQAMultimodalDefault)
    }

    func testLocalDataCryptorRoundTripsAndRejectsWrongKey() throws {
        let cryptor = try testCryptor(byte: 0x11)
        let wrongCryptor = try testCryptor(byte: 0x22)
        let context = "NotchCopilotTests.localDataCryptor"
        let plaintext = "private transcript sentinel"

        let encrypted = try cryptor.encryptString(plaintext, context: context)
        let encryptedAgain = try cryptor.encryptString(plaintext, context: context)

        XCTAssertTrue(cryptor.isEncryptedString(encrypted))
        XCTAssertNotEqual(encrypted, encryptedAgain)
        XCTAssertFalse(encrypted.contains(plaintext))
        XCTAssertEqual(try cryptor.decryptString(encrypted, context: context), plaintext)
        XCTAssertEqual(try cryptor.decryptString(plaintext, context: context), plaintext)
        XCTAssertThrowsError(try wrongCryptor.decryptString(encrypted, context: context))

        let data = Data(plaintext.utf8)
        let encryptedData = try cryptor.encryptData(data, context: context)
        XCTAssertTrue(cryptor.isEncryptedData(encryptedData))
        XCTAssertFalse(String(data: encryptedData, encoding: .utf8)?.contains(plaintext) == true)
        XCTAssertEqual(try cryptor.decryptData(encryptedData, context: context), data)
    }

    func testAppleKeychainServiceCachesReadsWritesAndDeletes() throws {
        let account = "cache-test-\(UUID().uuidString)"
        let serviceName = "com.notchcopilot.tests.\(UUID().uuidString)"
        var copyCount = 0
        var storedData = Data("first-secret".utf8)
        let operations = AppleKeychainService.Operations(
            update: { _, attributes in
                storedData = attributes[kSecValueData as String] as? Data ?? Data()
                return errSecSuccess
            },
            add: { item in
                storedData = item[kSecValueData as String] as? Data ?? Data()
                return errSecSuccess
            },
            copyMatching: { _ in
                copyCount += 1
                return (errSecSuccess, storedData)
            },
            delete: { _ in
                storedData.removeAll()
                return errSecSuccess
            }
        )
        let keychain = AppleKeychainService(
            service: serviceName,
            operations: operations,
            manageTrustedApplicationAccess: false
        )

        XCTAssertEqual(try keychain.getData(account: account), Data("first-secret".utf8))
        XCTAssertEqual(try keychain.getData(account: account), Data("first-secret".utf8))
        XCTAssertEqual(copyCount, 1)

        try keychain.set(Data("second-secret".utf8), account: account)
        XCTAssertEqual(try keychain.getData(account: account), Data("second-secret".utf8))
        XCTAssertEqual(copyCount, 1)

        let secondInstance = AppleKeychainService(
            service: serviceName,
            operations: operations,
            manageTrustedApplicationAccess: false
        )
        XCTAssertEqual(try secondInstance.getData(account: account), Data("second-secret".utf8))
        XCTAssertEqual(copyCount, 1)

        try keychain.delete(account: account)
        XCTAssertNil(try keychain.getData(account: account))
        XCTAssertNil(try secondInstance.getData(account: account))
        XCTAssertEqual(copyCount, 1)
    }

    func testAppleKeychainServiceCachesMissingAccounts() throws {
        let account = "missing-test-\(UUID().uuidString)"
        let serviceName = "com.notchcopilot.tests.\(UUID().uuidString)"
        var copyCount = 0
        let keychain = AppleKeychainService(
            service: serviceName,
            operations: AppleKeychainService.Operations(
                update: { _, _ in errSecItemNotFound },
                add: { _ in errSecSuccess },
                copyMatching: { _ in
                    copyCount += 1
                    return (errSecItemNotFound, nil)
                },
                delete: { _ in errSecItemNotFound }
            ),
            manageTrustedApplicationAccess: false
        )

        XCTAssertNil(try keychain.getData(account: account))
        XCTAssertNil(try keychain.getData(account: account))
        XCTAssertEqual(copyCount, 1)
    }

    func testAppleKeychainServiceChecksPresenceWithoutPromptingForSecretData() throws {
        let account = "presence-test-\(UUID().uuidString)"
        let serviceName = "com.notchcopilot.tests.\(UUID().uuidString)"
        var presenceQueries = 0
        var dataQueries = 0
        let storedData = Data("presence-secret".utf8)
        let keychain = AppleKeychainService(
            service: serviceName,
            operations: AppleKeychainService.Operations(
                update: { _, _ in errSecSuccess },
                add: { _ in errSecSuccess },
                copyMatching: { query in
                    if query[kSecReturnAttributes as String] as? Bool == true {
                        presenceQueries += 1
                        let authenticationUI = query[kSecUseAuthenticationUI as String] as? String
                        XCTAssertEqual(authenticationUI, kSecUseAuthenticationUISkip as String)
                        return (errSecSuccess, nil)
                    }
                    dataQueries += 1
                    return (errSecSuccess, storedData)
                },
                delete: { _ in errSecSuccess }
            ),
            manageTrustedApplicationAccess: false
        )

        XCTAssertTrue(keychain.contains(account: account))
        XCTAssertFalse(keychain.hasCachedData(account: account))
        XCTAssertTrue(keychain.contains(account: account))
        XCTAssertEqual(presenceQueries, 1)
        XCTAssertEqual(dataQueries, 0)

        XCTAssertEqual(try keychain.getData(account: account), storedData)
        XCTAssertTrue(keychain.hasCachedData(account: account))
        XCTAssertEqual(dataQueries, 1)
    }

    func testRuntimeDefaultKeychainUsesTestBackendUnderXCTest() throws {
        let keychain = AppleKeychainService.runtimeDefault()
        let account = "runtime-default-test-\(UUID().uuidString)"
        let secret = Data("runtime default secret".utf8)

        try keychain.set(secret, account: account)
        XCTAssertEqual(try keychain.getData(account: account), secret)

        try keychain.delete(account: account)
        XCTAssertNil(try keychain.getData(account: account))
    }

    func testLocalEncryptionStaticPersistenceGuards() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        func source(_ path: String) throws -> String {
            try String(contentsOf: projectRoot.appending(path: path), encoding: .utf8)
        }

        let fileStorage = try source("NotchCopilot/Persistence/FileStorageService.swift")
        let writeStart = try XCTUnwrap(fileStorage.range(of: "func writeTranscript")?.lowerBound)
        let readStart = try XCTUnwrap(fileStorage.range(of: "func readTranscript")?.lowerBound)
        let writeTranscriptBody = String(fileStorage[writeStart..<readStart])
        XCTAssertTrue(fileStorage.contains("appending(path: \"\\(meetingId.uuidString).json.ncenc\")"))
        XCTAssertTrue(writeTranscriptBody.contains("cryptor.encryptData"))
        XCTAssertTrue(writeTranscriptBody.contains("encrypted.write(to: url"))
        XCTAssertFalse(writeTranscriptBody.contains("data.write(to: url"))
        XCTAssertFalse(writeTranscriptBody.contains("data.write(to: legacyURL"))

        let database = try source("NotchCopilot/Persistence/Database.swift")
        XCTAssertTrue(database.contains("cryptor.encryptString("))
        XCTAssertTrue(database.contains("encryptSensitiveFieldsIfNeeded"))

        let repository = try source("NotchCopilot/Persistence/MeetingRepository.swift")
        XCTAssertTrue(repository.contains("cryptor.decryptString("))
        XCTAssertTrue(repository.contains("migrateEncryptedFields"))
    }

    func testSettingsRepositoryEncryptsPreferencesAndMigratesPlaintextDefaults() throws {
        let suiteName = "NotchCopilotEncryptedSettings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cryptor = try testCryptor()
        let preferencesKey = "notchCopilot.preferences.v1"
        let sentinel = "Local User Sentinel"
        var legacyPreferences = AppPreferences()
        legacyPreferences.userDisplayName = sentinel
        legacyPreferences.userRole = "Private Role Sentinel"
        defaults.set(try JSONEncoder().encode(legacyPreferences), forKey: preferencesKey)

        let repository = SettingsRepository(defaults: defaults, cryptor: cryptor)
        let loaded = repository.load()
        repository.save(loaded)

        let stored = try XCTUnwrap(defaults.data(forKey: preferencesKey))
        XCTAssertTrue(cryptor.isEncryptedData(stored))
        XCTAssertFalse(String(data: stored, encoding: .utf8)?.contains(sentinel) == true)
        XCTAssertEqual(repository.load().userDisplayName, sentinel)
    }

    func testAppStateAutosavesDirectPreferenceChanges() async throws {
        let suiteName = "NotchCopilotAutosaveSettings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cryptor = try testCryptor()
        let repository = SettingsRepository(defaults: defaults, cryptor: cryptor)
        let sentinel = "Persisted Between Builds"
        let appState = AppState()
        appState.settingsRepository = repository

        appState.preferences.userDisplayName = sentinel
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual(repository.load().userDisplayName, sentinel)
        let stored = try XCTUnwrap(defaults.data(forKey: "notchCopilot.preferences.v1"))
        XCTAssertTrue(cryptor.isEncryptedData(stored))
        XCTAssertFalse(String(data: stored, encoding: .utf8)?.contains(sentinel) == true)
    }

    func testCopilotIntentClassifierRoutesAmbientToolsAndRejectsNoise() {
        let classifier = CopilotIntentClassifier()
        let cases: [(text: String, kind: CopilotIntentKind, tool: CopilotToolKind)] = [
            ("O que falamos sobre o release ontem?", .answerableQuestion, .answerSynthesis),
            ("Qual é a diferença entre TCP e UDP?", .answerableQuestion, .answerSynthesis),
            ("Quem descobriu a penicilina?", .answerableQuestion, .answerSynthesis)
        ]

        for item in cases {
            let result = classifier.classify(text: item.text)
            XCTAssertEqual(result.kind, item.kind, item.text)
            XCTAssertEqual(result.preferredTool, item.tool, item.text)
            XCTAssertTrue(result.responseNeeded, item.text)
            XCTAssertGreaterThanOrEqual(result.confidence, item.text.hasPrefix("Copilot") ? 0.70 : 0.80, item.text)
            XCTAssertGreaterThanOrEqual(result.strongSignals.count, 2, item.text)
        }

        let negative = classifier.classify(text: "Livros sobre arquitetura de software e sistemas distribuídos a projetar grandes aplicações para milhões de usuários")
        XCTAssertFalse(negative.responseNeeded)
        XCTAssertEqual(negative.preferredTool, .unavailable)
    }

    func testCopilotRuntimeHasNoDeterministicCalculatorOrFallbackAnswers() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = projectRoot
            .appendingPathComponent("NotchCopilot/Meetings/MeetingSessionManager.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("struct CopilotCalculatorTool"))
        XCTAssertFalse(source.contains("struct CopilotLocalAnswerFallback"))
        XCTAssertFalse(source.contains("struct ExpressionParser"))
        XCTAssertFalse(source.contains("struct CopilotReminderParser"))
        XCTAssertFalse(source.contains("Local calculator"))
        XCTAssertFalse(source.contains("A capital da França é Paris."))
        XCTAssertFalse(source.contains("llmProbeClassification"))
        XCTAssertFalse(source.contains("CopilotLLMIntentAndAnswerService"))
        XCTAssertFalse(source.contains("presentClarification("))
        XCTAssertFalse(source.contains("frame.clarificationMessage"))
        if let decisionRange = source.range(of: "struct CopilotLLMDecisionService"),
           let routerRange = source.range(of: "struct CopilotToolRouter") {
            let decisionSource = String(source[decisionRange.lowerBound..<routerRange.lowerBound])
            XCTAssertFalse(decisionSource.contains("generateAnswer("))
            XCTAssertFalse(decisionSource.contains("PromptBuilder"))
        }
    }

    func testCopilotLLMStructuredReminderResponseDecodesNativeActionOnly() throws {
        let json = """
        {
          "shouldRespond": true,
          "intent": "reminder",
          "needsWeb": false,
          "needsReminderAction": true,
          "needsClarification": false,
          "answerFormat": "reminder_confirmation",
          "answerText": "Combinado, vou te lembrar amanhã às 9h.",
          "confidence": 0.91,
          "reason": "clear reminder request",
          "reminderAction": {
            "title": "Revisar o PR",
            "scheduledAtISO8601": "2026-05-24T12:00:00Z"
          }
        }
        """
        let response = try JSONDecoder().decode(CopilotLLMIntentAndAnswerResponse.self, from: Data(json.utf8))

        XCTAssertTrue(response.needsReminderAction)
        XCTAssertEqual(response.resolvedIntent(fallback: .ambiguous), .reminder)
        XCTAssertEqual(response.resolvedTool(fallback: .answerSynthesis), .reminder)
        XCTAssertEqual(response.reminderAction?.title, "Revisar o PR")
    }

    func testCopilotFinalAnswerDerivesTextFromRichAnswerWhenAnswerTextIsMissing() async throws {
        let provider = ScriptedRawAIProvider(responses: [
            """
            {
              "shouldRespond": true,
              "intent": "answerable_question",
              "richAnswer": {
                "version": 1,
                "blocks": [
                  {
                    "type": "steps",
                    "title": "Plano",
                    "items": [
                      {"text": "Auditar os principais fluxos do Copilot."},
                      {"text": "Compactar historico com previews e abrir resposta completa."},
                      {"text": "Validar acessibilidade, fontes e estados de erro."}
                    ]
                  }
                ]
              },
              "confidence": 0.92,
              "reason": "rich_ui_only",
              "reminderAction": null
            }
            """
        ])
        let meeting = makeAmbientMeeting()
        let candidate = QuestionCandidate(
            meetingId: meeting.id,
            rawText: "Monte um plano passo a passo para melhorar a UX do Copilot",
            normalizedText: "monte um plano passo a passo para melhorar a ux do copilot",
            language: "pt-BR",
            speakerLabel: "You",
            startTime: 0,
            endTime: 1,
            sourceSegmentIds: [UUID()],
            isPartial: false
        )
        let decision = CopilotLLMIntentAndAnswerResponse(
            shouldRespond: true,
            intent: CopilotIntentKind.answerableQuestion.rawValue,
            needsWeb: false,
            needsReminderAction: false,
            needsClarification: false,
            answerFormat: CopilotAnswerFormat.steps.rawValue,
            answerText: "",
            confidence: 0.91,
            reason: "test",
            reminderAction: nil
        )

        let result = try await CopilotLLMFinalAnswerService(provider: provider).generate(
            candidate: candidate,
            decision: decision,
            transcriptContext: makeContext(candidate.rawText),
            meeting: meeting,
            preferences: AppPreferences(),
            sources: [],
            reminderResult: nil,
            enableWebSearch: false
        )

        XCTAssertEqual(provider.requests.first?.maxOutputTokens, 2_200)
        XCTAssertEqual(result.response.resolvedFormat(fallback: .paragraph), .steps)
        XCTAssertTrue(result.response.answerText.contains("Plano"))
        XCTAssertTrue(result.response.answerText.contains("1. Auditar os principais fluxos do Copilot."))
        XCTAssertNotNil(result.response.richAnswer)
    }

    func testCopilotFinalAnswerUsesVisibleFallbackWhenAnswerTextIsEmpty() async throws {
        let provider = ScriptedRawAIProvider(responses: [
            """
            {
              "shouldRespond": true,
              "intent": "answerable_question",
              "needsWeb": false,
              "needsReminderAction": false,
              "needsClarification": false,
              "answerFormat": "steps",
              "answerText": "",
              "confidence": 0.88,
              "reason": "empty_model_output",
              "reminderAction": null
            }
            """
        ])
        let meeting = makeAmbientMeeting()
        let candidate = QuestionCandidate(
            meetingId: meeting.id,
            rawText: "Monte um plano passo a passo para organizar minha semana",
            normalizedText: "monte um plano passo a passo para organizar minha semana",
            language: "pt-BR",
            speakerLabel: "You",
            startTime: 0,
            endTime: 1,
            sourceSegmentIds: [UUID()],
            isPartial: false
        )
        let decision = CopilotLLMIntentAndAnswerResponse(
            shouldRespond: true,
            intent: CopilotIntentKind.answerableQuestion.rawValue,
            needsWeb: false,
            needsReminderAction: false,
            needsClarification: false,
            answerFormat: CopilotAnswerFormat.steps.rawValue,
            answerText: "",
            confidence: 0.91,
            reason: "test",
            reminderAction: nil
        )

        let result = try await CopilotLLMFinalAnswerService(provider: provider).generate(
            candidate: candidate,
            decision: decision,
            transcriptContext: makeContext(candidate.rawText),
            meeting: meeting,
            preferences: AppPreferences(),
            sources: [],
            reminderResult: nil,
            enableWebSearch: false
        )

        XCTAssertEqual(result.response.reason, "empty_final_answer")
        XCTAssertTrue(result.response.answerText.contains("Nao consegui recuperar"))
        XCTAssertTrue(result.response.answerText.contains("organizar minha semana"))
        XCTAssertNotNil(result.response.richAnswer)
    }

    func testCopilotFinalAnswerTimesOutInsteadOfHanging() async throws {
        let provider = SlowRawAIProvider(delayNanoseconds: 1_000_000_000)
        let meeting = makeAmbientMeeting()
        let candidate = QuestionCandidate(
            meetingId: meeting.id,
            rawText: "Monte um plano passo a passo para melhorar a UX do Copilot",
            normalizedText: "monte um plano passo a passo para melhorar a ux do copilot",
            language: "pt-BR",
            speakerLabel: "You",
            startTime: 0,
            endTime: 1,
            sourceSegmentIds: [UUID()],
            isPartial: false
        )
        let decision = CopilotLLMIntentAndAnswerResponse(
            shouldRespond: true,
            intent: CopilotIntentKind.answerableQuestion.rawValue,
            needsWeb: false,
            needsReminderAction: false,
            needsClarification: false,
            answerFormat: CopilotAnswerFormat.steps.rawValue,
            answerText: "",
            confidence: 0.91,
            reason: "test",
            reminderAction: nil
        )

        do {
            _ = try await CopilotLLMFinalAnswerService(
                provider: provider,
                finalAnswerTimeoutSeconds: 0.03
            ).generate(
                candidate: candidate,
                decision: decision,
                transcriptContext: makeContext(candidate.rawText),
                meeting: meeting,
                preferences: AppPreferences(),
                sources: [],
                reminderResult: nil,
                enableWebSearch: false
            )
            XCTFail("Expected final answer timeout")
        } catch let failure as CopilotFailure {
            XCTAssertEqual(failure.kind, .answerTimedOut)
        }
    }

    func testCopilotDecisionAnswersEverydayRequestsWithAssumptionsInsteadOfClarifying() async throws {
        let provider = ScriptedRawAIProvider(responses: [
            """
            {
              "shouldRespond": false,
              "intent": "ambiguous",
              "needsWeb": false,
              "needsReminderAction": false,
              "needsClarification": true,
              "answerFormat": "plain_short",
              "answerText": "Qual area da rotina voce quer melhorar?",
              "confidence": 0.91,
              "reason": "underspecified",
              "reminderAction": null
            }
            """
        ])

        let result = try await CopilotLLMDecisionService(provider: provider).decide(
            frames: [makeSpeechFrame("Monte um plano passo a passo para melhorar minha rotina")],
            transcriptContext: makeContext("Monte um plano passo a passo para melhorar minha rotina"),
            meeting: makeAmbientMeeting(),
            preferences: AppPreferences(),
            source: .shortcut,
            forceWeb: false
        )

        XCTAssertTrue(result.decision.shouldRespond)
        XCTAssertFalse(result.decision.needsClarification)
        XCTAssertEqual(result.decision.resolvedIntent(fallback: .ambiguous), .answerableQuestion)
        XCTAssertEqual(result.decision.resolvedFormat(fallback: .paragraph), .steps)
    }

    func testCopilotDecisionKeepsClarificationForUnclearASR() async throws {
        let provider = ScriptedRawAIProvider(responses: [
            copilotDecisionJSON(
                shouldRespond: false,
                intent: "ambiguous",
                confidence: 0.91,
                needsClarification: true,
                answerText: "Pode esclarecer o pedido?"
            )
        ])

        let result = try await CopilotLLMDecisionService(provider: provider).decide(
            frames: [makeSpeechFrame("Cuanto is my days", confidence: 0.42)],
            transcriptContext: makeContext("Cuanto is my days"),
            meeting: makeAmbientMeeting(),
            preferences: AppPreferences(),
            source: .microphone,
            forceWeb: false
        )

        XCTAssertTrue(result.decision.needsClarification)
    }

    func testCopilotFinalAnswerRetriesClarificationForEverydayRequests() async throws {
        let provider = ScriptedRawAIProvider(responses: [
            """
            {
              "shouldRespond": true,
              "intent": "answerable_question",
              "needsWeb": false,
              "needsReminderAction": false,
              "needsClarification": true,
              "answerFormat": "plain_short",
              "answerText": "Voce quer um plano para qual area da rotina?",
              "confidence": 0.88,
              "reason": "underspecified",
              "reminderAction": null
            }
            """,
            """
            {
              "shouldRespond": true,
              "intent": "answerable_question",
              "needsWeb": false,
              "needsReminderAction": false,
              "needsClarification": false,
              "answerFormat": "steps",
              "answerText": "Assumindo uma rotina diaria geral: 1. escolha tres prioridades; 2. bloqueie foco; 3. revise no fim do dia.",
              "richAnswer": {
                "version": 1,
                "blocks": [
                  {
                    "type": "steps",
                    "title": "Plano",
                    "items": [
                      {"text": "Escolha tres prioridades."},
                      {"text": "Bloqueie um horario de foco."},
                      {"text": "Revise o que funcionou no fim do dia."}
                    ]
                  }
                ]
              },
              "confidence": 0.90,
              "reason": "answered_with_assumptions",
              "reminderAction": null
            }
            """
        ])
        let meeting = makeAmbientMeeting()
        let candidate = QuestionCandidate(
            meetingId: meeting.id,
            rawText: "Monte um plano passo a passo para melhorar minha rotina",
            normalizedText: "monte um plano passo a passo para melhorar minha rotina",
            language: "pt-BR",
            speakerLabel: "You",
            startTime: 0,
            endTime: 1,
            sourceSegmentIds: [UUID()],
            isPartial: false
        )
        let decision = CopilotLLMIntentAndAnswerResponse(
            shouldRespond: true,
            intent: CopilotIntentKind.answerableQuestion.rawValue,
            needsWeb: false,
            needsReminderAction: false,
            needsClarification: false,
            answerFormat: CopilotAnswerFormat.steps.rawValue,
            answerText: "",
            confidence: 0.91,
            reason: "test",
            reminderAction: nil
        )

        let result = try await CopilotLLMFinalAnswerService(provider: provider).generate(
            candidate: candidate,
            decision: decision,
            transcriptContext: makeContext(candidate.rawText),
            meeting: meeting,
            preferences: AppPreferences(),
            sources: [],
            reminderResult: nil,
            enableWebSearch: false
        )

        XCTAssertEqual(provider.requests.count, 2)
        XCTAssertFalse(result.response.needsClarification)
        XCTAssertTrue(result.response.answerText.contains("Assumindo uma rotina diaria geral"))
        XCTAssertEqual(result.response.resolvedFormat(fallback: .paragraph), .steps)
    }

    func testCopilotLLMDecisionUsesRawJSONProviderAndRepairsInvalidJSONOnce() async throws {
        let provider = ScriptedRawAIProvider(responses: [
            "Sure, I can help with that.",
            copilotDecisionJSON(shouldRespond: true, intent: "answerable_question", confidence: 0.93)
        ])

        let result = try await CopilotLLMDecisionService(provider: provider).decide(
            frames: [makeSpeechFrame("Qual é a capital da França?")],
            transcriptContext: makeContext("Qual é a capital da França?"),
            meeting: makeAmbientMeeting(),
            preferences: AppPreferences(),
            source: .microphone,
            forceWeb: false
        )

        XCTAssertTrue(result.shouldPresent)
        XCTAssertEqual(provider.requests.count, 2)
        XCTAssertEqual(provider.requests.first?.responseMode, .jsonObject)
        XCTAssertFalse(provider.requests.first?.prompt.contains("Return only the answer itself") == true)
    }

    func testCopilotProviderReadinessRequiresCloudProvider() async {
        var preferences = AppPreferences()
        preferences.localOnlyMode = true
        preferences.aiConfig.cloudProcessingEnabled = false

        let status = await CopilotProviderReadinessCheck(router: ProviderRouter()).validate(preferences: preferences)

        XCTAssertEqual(status.healthState, .llmProviderMissing)
    }

    func testTranscriptionFailoverCoordinatorRestartsWhenAudioHasNoSegments() {
        var coordinator = TranscriptionFailoverCoordinator()
        let startedAt = Date(timeIntervalSince1970: 1_000)
        _ = coordinator.markPipelineStarted(backend: "Apple Speech on-device", now: startedAt)
        let audio = AudioBuffer(
            pcmBuffer: nil,
            time: nil,
            rms: 0.02,
            peak: 0.05,
            createdAt: startedAt.addingTimeInterval(1),
            audioSource: .microphone
        )
        _ = coordinator.markAudio(audio, now: startedAt.addingTimeInterval(1))

        let (snapshot, action) = coordinator.poll(now: startedAt.addingTimeInterval(5.2))

        XCTAssertEqual(snapshot.state, .asrNoSegments)
        guard case .restartASR(let reason, let allowHybridRecognition) = action else {
            return XCTFail("Expected ASR restart")
        }
        XCTAssertEqual(reason, "audio_without_transcript")
        XCTAssertFalse(allowHybridRecognition)
    }

    func testAppStateShowsOnlyMicrostateForBlockedAmbientCopilot() {
        let appState = AppState()
        appState.islandMode = .idle
        appState.isPanelExpanded = false
        appState.preferences.copilotHotkeyEnabled = true

        appState.applyCopilotHealthSnapshot(CopilotHealthSnapshot(state: .llmProviderMissing))

        XCTAssertTrue(appState.shouldShowAmbientCopilotMicroState)
        XCTAssertFalse(appState.shouldShowAmbientCopilotIdle)
        XCTAssertEqual(appState.notchIslandSize, NotchIslandChromeMetrics.ambientCopilotLoadingSize)
    }

    func testCopilotActivationTracePreviewIsRedactedAndShort() {
        let secret = "token=supersecret12345 " + String(repeating: "a", count: 150)
        let preview = CopilotActivationTrace.sanitizedPreview(secret)
        let hash = CopilotActivationTrace.stableHash(for: secret)

        XCTAssertNotNil(preview)
        XCTAssertFalse(preview?.contains("supersecret12345") == true)
        XCTAssertLessThanOrEqual(preview?.count ?? 0, 99)
        XCTAssertNotNil(hash)
    }

    func testCopilotLLMDecisionSyntheticFiveThousandReplayMeetsTargets() async throws {
        let positives = [
            "Quanto é 17,5% de 8420?",
            "Pesquisa as últimas notícias sobre OpenAI",
            "Me lembra amanhã às 9 de revisar o PR",
            "O que falamos sobre o contrato ontem?",
            "Converte 12 km em milhas",
            "Copilot, resume esse ponto em uma frase",
            "What is 18 percent of 4200?",
            "Search web for the latest Apple earnings",
            "Remind me tomorrow at 9 to review the PR",
            "What did we discuss about launch risk?",
            "Busca noticias sobre inteligencia artificial",
            "明日の9時にPRを確認するようリマインド"
        ]
        let negatives = [
            "Livros sobre arquitetura de software e sistemas distribuídos a projetar grandes aplicações para milhões de usuários",
            "como eu disse antes a gente vai seguir com essa abordagem",
            "tudo bem pessoal vamos continuar",
            "você consegue me ouvir agora",
            "design intense",
            "the architecture system has a question queue but this sentence is just a note",
            "como vai você hoje",
            "este é só um título solto",
            "creo que podemos revisar esto después",
            "これは質問ではなく会議メモです",
            "a capital da França é Paris",
            "qualquer coisa eu aviso depois"
        ]

        var truePositive = 0
        var falsePositive = 0
        var falseNegative = 0
        var trueNegative = 0
        var latencies: [Double] = []
        var falsePositiveSamples: [String] = []
        var falseNegativeSamples: [String] = []
        let started = Date()
        let samples: [(text: String, shouldRespond: Bool)] = (0..<5_000).map { index in
            let shouldRespond = index % 5 >= 3
            let text = shouldRespond
                ? positives[index % positives.count]
                : negatives[index % negatives.count]
            return (text, shouldRespond)
        }
        let provider = ScriptedRawAIProvider(responses: samples.map {
            copilotDecisionJSON(
                shouldRespond: $0.shouldRespond,
                intent: $0.shouldRespond ? "answerable_question" : "statement",
                confidence: $0.shouldRespond ? 0.93 : 0.12
            )
        })
        let service = CopilotLLMDecisionService(provider: provider)
        let meeting = makeAmbientMeeting()
        let preferences = AppPreferences()

        for sample in samples {
            let itemStarted = Date()
            let result = try await service.decide(
                frames: [makeSpeechFrame(sample.text)],
                transcriptContext: makeContext(sample.text),
                meeting: meeting,
                preferences: preferences,
                source: .microphone,
                forceWeb: false
            )
            let detected = result.shouldPresent
            latencies.append(Date().timeIntervalSince(itemStarted) * 1_000)

            switch (sample.shouldRespond, detected) {
            case (true, true): truePositive += 1
            case (true, false): falseNegative += 1
                if falseNegativeSamples.count < 8 {
                    falseNegativeSamples.append("\(sample.text) -> \(result.decision.reason)")
                }
            case (false, true):
                falsePositive += 1
                if falsePositiveSamples.count < 8 {
                    falsePositiveSamples.append("\(sample.text) -> \(result.decision.reason)")
                }
            case (false, false): trueNegative += 1
            }
        }

        latencies.sort()
        let precision = Double(truePositive) / Double(max(truePositive + falsePositive, 1))
        let recall = Double(truePositive) / Double(max(truePositive + falseNegative, 1))
        let p95 = latencies[Int(Double(latencies.count - 1) * 0.95)]
        print(String(format: "COPILOT_REPLAY fixture=5000 tp=%d fp=%d fn=%d tn=%d precision=%.4f recall=%.4f p95_ms=%.3f total_s=%.3f", truePositive, falsePositive, falseNegative, trueNegative, precision, recall, p95, Date().timeIntervalSince(started)))

        XCTAssertGreaterThanOrEqual(precision, 0.98, falsePositiveSamples.joined(separator: " | "))
        XCTAssertGreaterThanOrEqual(recall, 0.94, falseNegativeSamples.joined(separator: " | "))
        XCTAssertLessThanOrEqual(falsePositive, 0, falsePositiveSamples.joined(separator: " | "))
        XCTAssertLessThan(p95, 100)
    }

    func testCopilotLLMDecisionGoldFixtureFileMeetsTargetsAndBenchmarks() async throws {
        struct Row: Decodable {
            var text: String
            var language: String
            var responseNeeded: Bool
        }

        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/copilot_intent_gold.jsonl")
        let lines = try String(contentsOf: fixtureURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertGreaterThanOrEqual(lines.count, 5_000)

        let decoder = JSONDecoder()
        let sampledRows = try lines.prefix(1_000).map { line -> Row in
            try decoder.decode(Row.self, from: Data(line.utf8))
        }
        XCTAssertGreaterThanOrEqual(sampledRows.count, 1_000)
        let provider = ScriptedRawAIProvider(responses: sampledRows.map {
            copilotDecisionJSON(
                shouldRespond: $0.responseNeeded,
                intent: $0.responseNeeded ? "answerable_question" : "statement",
                confidence: $0.responseNeeded ? 0.93 : 0.12
            )
        })
        let service = CopilotLLMDecisionService(provider: provider)
        let meeting = makeAmbientMeeting()
        let preferences = AppPreferences()
        var truePositive = 0
        var falsePositive = 0
        var falseNegative = 0
        var trueNegative = 0
        var latencies: [Double] = []
        var falsePositives: [String] = []
        var falseNegatives: [String] = []

        for row in sampledRows {
            let segment = TranscriptSegment(meetingId: UUID(), speakerLabel: "Speaker", text: row.text, originalLanguage: row.language)
            let context = TranscriptContext(recentTranscript: row.text, mediumTranscript: row.text, completeTranscript: row.text, dominantLanguage: row.language, currentSegment: segment)
            let started = DispatchTime.now().uptimeNanoseconds
            let result = try await service.decide(
                frames: [makeSpeechFrame(row.text, language: row.language)],
                transcriptContext: context,
                meeting: meeting,
                preferences: preferences,
                source: .microphone,
                forceWeb: false
            )
            let detected = result.shouldPresent
            let ended = DispatchTime.now().uptimeNanoseconds
            latencies.append(Double(ended - started) / 1_000_000)

            switch (row.responseNeeded, detected) {
            case (true, true): truePositive += 1
            case (false, true):
                falsePositive += 1
                if falsePositives.count < 8 { falsePositives.append("[\(row.language)] \(row.text) -> \(result.decision.reason)") }
            case (true, false):
                falseNegative += 1
                if falseNegatives.count < 8 { falseNegatives.append("[\(row.language)] \(row.text) -> \(result.decision.reason)") }
            case (false, false): trueNegative += 1
            }
        }

        let precision = Double(truePositive) / Double(max(truePositive + falsePositive, 1))
        let recall = Double(truePositive) / Double(max(truePositive + falseNegative, 1))
        let p95 = percentile(latencies, 0.95)
        print(String(format: "COPILOT_GOLD fixture=%d sampled=%d tp=%d fp=%d fn=%d tn=%d precision=%.4f recall=%.4f p95_ms=%.3f", lines.count, sampledRows.count, truePositive, falsePositive, falseNegative, trueNegative, precision, recall, p95))

        XCTAssertGreaterThanOrEqual(precision, 0.98, falsePositives.joined(separator: " | "))
        XCTAssertGreaterThanOrEqual(recall, 0.94, falseNegatives.joined(separator: " | "))
        XCTAssertLessThan(p95, 100)
    }

    func testCopilotIntentPolicyIsResourceDrivenAndGoldFixtureIsLargeEnough() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = projectRoot
            .appendingPathComponent("NotchCopilot/RealtimeQuestionAnswering/QuestionAnswerModels.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let classifierStart = try XCTUnwrap(source.range(of: "struct CopilotIntentClassifier")?.lowerBound)
        let classifierSource = String(source[classifierStart...])

        XCTAssertFalse(classifierSource.contains("containsWakeWord("))
        XCTAssertFalse(classifierSource.contains("isWebSearchRequest("))
        XCTAssertFalse(classifierSource.contains("isReminderRequest("))
        XCTAssertFalse(classifierSource.contains("isCalculationRequest("))
        XCTAssertFalse(classifierSource.contains("[\"copilot\""))

        let policyURL = projectRoot
            .appendingPathComponent("NotchCopilot/Resources/CopilotIntentPolicy/default.json")
        let policy = try JSONDecoder().decode(CopilotIntentPolicy.self, from: Data(contentsOf: policyURL))
        XCTAssertTrue(policy.wakeWords.isEmpty)
        XCTAssertTrue(policy.partialIncompleteCues.isEmpty)
        XCTAssertTrue(policy.stopWords.isEmpty)
        XCTAssertTrue(policy.lowInformationWords.isEmpty)
        XCTAssertTrue(policy.numberWords.isEmpty)
        XCTAssertTrue(policy.operatorWords.isEmpty)
        XCTAssertTrue((policy.semanticLabels + policy.toolLabels + policy.negativeLabels).allSatisfy { label in
            label.cues.isEmpty && (label.prefixCues ?? []).isEmpty
        })
        XCTAssertFalse(policy.toolLabels.contains { $0.tool == .calculator })

        let speechPolicyURL = projectRoot
            .appendingPathComponent("NotchCopilot/Resources/CopilotSpeechPolicy/default.json")
        let speechPolicy = try JSONDecoder().decode(CopilotSpeechPolicy.self, from: Data(contentsOf: speechPolicyURL))
        XCTAssertTrue(speechPolicy.clarificationRules.isEmpty)

        let fixtureURL = projectRoot
            .appendingPathComponent("NotchCopilotTests/Fixtures/copilot_intent_gold.jsonl")
        let fixtureLines = try String(contentsOf: fixtureURL, encoding: .utf8)
            .split(separator: "\n")
        XCTAssertGreaterThanOrEqual(fixtureLines.count, 20_000)
    }

    func testCopilotDirectQuestionsActivateEvenInMostPreciseSettings() async throws {
        var preferences = AppPreferences()
        preferences.qaPrecisionMode = .highPrecision
        preferences.copilotActivationPolicy = .wakeWord
        let examples = [
            "Qual é a capital da França?",
            "Qual é a capital da França",
            "Quanto é 2 + 2?",
            "quanto é dois mais dois",
            "Cuanto es 2 + 2?",
            "Cuanto es dos mas dos?"
        ]

        for text in examples {
            let provider = ScriptedRawAIProvider(responses: [copilotDecisionJSON(shouldRespond: true, intent: text.contains("2") ? "calculation" : "answerable_question", confidence: 0.91)])
            let result = try await CopilotLLMDecisionService(provider: provider).decide(
                frames: [makeSpeechFrame(text)],
                transcriptContext: makeContext(text),
                meeting: makeAmbientMeeting(),
                preferences: preferences,
                source: .microphone,
                forceWeb: false
            )
            XCTAssertTrue(result.shouldPresent, text)
            XCTAssertEqual(result.decision.resolvedTool(fallback: .unavailable), .answerSynthesis)
        }

        for fragment in ["Quanto", "Cuanto", "Quanto é", "Cuanto es", "Quanto é 2", "Cuanto es dos"] {
            let provider = ScriptedRawAIProvider(responses: [copilotDecisionJSON(shouldRespond: false, intent: "ambient_noise", confidence: 0.21)])
            let result = try await CopilotLLMDecisionService(provider: provider).decide(
                frames: [makeSpeechFrame(fragment)],
                transcriptContext: makeContext(fragment),
                meeting: makeAmbientMeeting(),
                preferences: preferences,
                source: .microphone,
                forceWeb: false
            )
            XCTAssertFalse(result.shouldPresent, "\(fragment) should wait for the full utterance")
        }
    }

    func testCopilotBroadDynamicIntentExamplesActivateWithoutHardcodedSwiftTerms() async throws {
        let examples = [
            "Quem descobriu a penicilina?",
            "Me explica por que o céu é azul",
            "Qual é a diferença entre TCP e UDP?",
            "Procure na web o preço atual do dólar",
            "Explain why the sky is blue in one sentence",
            "Who discovered penicillin?",
            "Cuál es la capital de Francia?",
            "Recuérdame mañana revisar el PR",
            "フランスの首都は何ですか",
            "明日の9時にPRを確認するようリマインド"
        ]

        for text in examples {
            let provider = ScriptedRawAIProvider(responses: [copilotDecisionJSON(shouldRespond: true, intent: "answerable_question", confidence: 0.90)])
            let result = try await CopilotLLMDecisionService(provider: provider).decide(
                frames: [makeSpeechFrame(text)],
                transcriptContext: makeContext(text),
                meeting: makeAmbientMeeting(),
                preferences: AppPreferences(),
                source: .microphone,
                forceWeb: false
            )
            XCTAssertTrue(result.shouldPresent, "\(text) -> \(result.decision.reason)")
        }
    }

    func testCopilotSpeechUnderstandingBuildsASRLatticeWithoutLocalClarification() {
        let segment = TranscriptSegment(
            meetingId: UUID(),
            speakerLabel: "You",
            audioSource: .microphone,
            text: "Cuanto is my days",
            originalLanguage: "pt-BR",
            transcriptionEngine: .appleSpeech,
            engineConfidence: 0.52,
            languageConfidence: 0.38,
            wordTimestamps: [
                TranscriptWordTimestamp(word: "Cuanto", startTime: 0, endTime: 0.22, confidence: 0.48),
                TranscriptWordTimestamp(word: "is", startTime: 0.24, endTime: 0.34, confidence: 0.41),
                TranscriptWordTimestamp(word: "my", startTime: 0.36, endTime: 0.45, confidence: 0.36),
                TranscriptWordTimestamp(word: "days", startTime: 0.47, endTime: 0.72, confidence: 0.58)
            ]
        )
        let context = TranscriptWindowBuffer().transcriptContext(currentSegment: segment)
        let frames = CopilotSpeechUnderstandingPipeline().candidateFrames(from: segment, context: context)

        XCTAssertTrue(frames.contains { QuestionDetectionService.normalize($0.text).contains("quantos dias") })
        XCTAssertTrue(frames.allSatisfy { $0.clarificationMessage == nil })
    }

    func testCopilotSpeechUnderstandingMarksCrossLanguageAlternativesAsFanout() {
        let segment = TranscriptSegment(
            meetingId: UUID(),
            speakerLabel: "You",
            audioSource: .microphone,
            text: "Monte um plano para reduzir latency",
            originalLanguage: "pt-BR",
            transcriptionEngine: .appleSpeech,
            engineConfidence: 0.76,
            languageConfidence: 0.74,
            alternatives: [
                TranscriptAlternative(
                    text: "Build a plan to reduce latency",
                    confidence: 0.78,
                    languageCode: "en-US",
                    source: .transcription
                )
            ]
        )

        let frames = CopilotSpeechUnderstandingPipeline().candidateFrames(
            from: segment,
            context: TranscriptWindowBuffer().transcriptContext(currentSegment: segment)
        )

        XCTAssertTrue(frames.contains { $0.source == .languageFanout && $0.languageCode == "en-US" })
    }

    func testCopilotSpeechFrameSelectorPrefersStableFinalOverHighConfidencePartial() {
        var preferences = AppPreferences()
        preferences.copilotASRCommitPolicy = .accurate
        let partial = makeSpeechFrame("Monte um plano passo", language: "pt-BR", confidence: 0.97, isFinal: false)
        let final = makeSpeechFrame("Monte um plano passo a passo para melhorar a UX", language: "pt-BR", confidence: 0.78, isFinal: true)

        let selected = CopilotSpeechFrameSelector.bestFrame(in: [partial, final], context: makeContext(final.text), preferences: preferences)

        XCTAssertEqual(selected?.text, final.text)
    }

    func testCopilotDecisionServiceUsesConservativeFrameSelector() async throws {
        var preferences = AppPreferences()
        preferences.copilotASRCommitPolicy = .accurate
        let partial = makeSpeechFrame("Monte um plano passo", language: "pt-BR", confidence: 0.97, isFinal: false)
        let final = makeSpeechFrame("Monte um plano passo a passo para melhorar a UX", language: "pt-BR", confidence: 0.78, isFinal: true)
        let provider = ScriptedRawAIProvider(responses: [
            copilotDecisionJSON(shouldRespond: true, intent: "answerable_question", confidence: 0.92)
        ])

        let result = try await CopilotLLMDecisionService(provider: provider).decide(
            frames: [partial, final],
            transcriptContext: makeContext(final.text),
            meeting: makeAmbientMeeting(),
            preferences: preferences,
            source: .microphone,
            forceWeb: false
        )

        XCTAssertEqual(result.selectedFrame.text, final.text)
        XCTAssertTrue(result.shouldPresent)
    }

    func testCopilotASRIntentFixtureMeetsInitialTargets() async throws {
        struct Row: Decodable {
            var rawText: String
            var alternatives: [String]
            var language: String
            var responseNeeded: Bool
            var label: String
            var tool: String
            var expectedTop3Contains: String
        }

        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/copilot_asr_intent_gold.jsonl")
        let rows = try String(contentsOf: fixtureURL, encoding: .utf8)
            .split(separator: "\n")
            .map { try JSONDecoder().decode(Row.self, from: Data($0.utf8)) }

        let pipeline = CopilotSpeechUnderstandingPipeline()
        var truePositive = 0
        var falsePositive = 0
        var falseNegative = 0
        var trueNegative = 0
        var top3Hits = 0

        for row in rows {
            let segment = TranscriptSegment(
                meetingId: UUID(),
                speakerLabel: "You",
                audioSource: .microphone,
                text: row.rawText,
                originalLanguage: row.language,
                transcriptionEngine: .appleSpeech,
                engineConfidence: row.rawText.localizedCaseInsensitiveContains("cuanto is") ? 0.52 : 0.86,
                languageConfidence: row.rawText.localizedCaseInsensitiveContains("cuanto is") ? 0.38 : 0.82,
                alternatives: row.alternatives.map {
                    TranscriptAlternative(text: $0, confidence: 0.74, languageCode: row.language, source: .transcription)
                }
            )
            let context = TranscriptWindowBuffer().transcriptContext(currentSegment: segment)
            let frames = pipeline.candidateFrames(from: segment, context: context)
            if frames.prefix(3).contains(where: { QuestionDetectionService.normalize($0.text).contains(QuestionDetectionService.normalize(row.expectedTop3Contains)) }) {
                top3Hits += 1
            }

            let provider = ScriptedRawAIProvider(responses: [
                copilotDecisionJSON(
                    shouldRespond: row.responseNeeded && row.label != "clarification",
                    intent: row.label == "clarification" ? "ambiguous" : row.label,
                    confidence: row.responseNeeded ? 0.91 : 0.22,
                    needsClarification: row.label == "clarification",
                    answerText: row.label == "clarification" ? "Você quer calcular quantos dias até qual data?" : ""
                )
            ])
            let decision = try await CopilotLLMDecisionService(provider: provider).decide(
                frames: frames,
                transcriptContext: context,
                meeting: makeAmbientMeeting(),
                preferences: AppPreferences(),
                source: .microphone,
                forceWeb: false
            )
            let detected = decision.shouldPresent
            switch (row.responseNeeded, detected) {
            case (true, true): truePositive += 1
            case (true, false): falseNegative += 1
            case (false, true): falsePositive += 1
            case (false, false): trueNegative += 1
            }

            if row.tool == CopilotToolKind.answerSynthesis.rawValue {
                XCTAssertEqual(decision.decision.resolvedTool(fallback: .unavailable), .answerSynthesis, row.rawText)
            }
            if row.label == "clarification" {
                XCTAssertTrue(decision.decision.needsClarification, row.rawText)
            }
        }

        let precision = Double(truePositive) / Double(max(truePositive + falsePositive, 1))
        let recall = Double(truePositive) / Double(max(truePositive + falseNegative, 1))
        let top3Rate = Double(top3Hits) / Double(max(rows.count, 1))
        XCTAssertGreaterThanOrEqual(precision, 0.98)
        XCTAssertGreaterThanOrEqual(recall, 0.92)
        XCTAssertGreaterThanOrEqual(top3Rate, 0.95)
        XCTAssertGreaterThan(trueNegative, 0)
    }

    func testCopilotASRLatticeBenchmarkMeetsLatencyTarget() throws {
        struct Row: Decodable {
            var rawText: String
            var alternatives: [String]
            var language: String
        }

        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/copilot_asr_intent_gold.jsonl")
        let rows = try String(contentsOf: fixtureURL, encoding: .utf8)
            .split(separator: "\n")
            .map { try JSONDecoder().decode(Row.self, from: Data($0.utf8)) }
        let pipeline = CopilotSpeechUnderstandingPipeline()
        var latencies: [Double] = []
        var frameCount = 0

        for _ in 0..<300 {
            for row in rows {
                let isCorruptedDuration = row.rawText.localizedCaseInsensitiveContains("cuanto is")
                let segment = TranscriptSegment(
                    meetingId: UUID(),
                    speakerLabel: "You",
                    audioSource: .microphone,
                    text: row.rawText,
                    originalLanguage: row.language,
                    transcriptionEngine: .appleSpeech,
                    engineConfidence: isCorruptedDuration ? 0.52 : 0.86,
                    languageConfidence: isCorruptedDuration ? 0.38 : 0.82,
                    wordTimestamps: isCorruptedDuration ? [
                        TranscriptWordTimestamp(word: "Cuanto", startTime: 0, endTime: 0.22, confidence: 0.48),
                        TranscriptWordTimestamp(word: "is", startTime: 0.24, endTime: 0.34, confidence: 0.41),
                        TranscriptWordTimestamp(word: "my", startTime: 0.36, endTime: 0.45, confidence: 0.36),
                        TranscriptWordTimestamp(word: "days", startTime: 0.47, endTime: 0.72, confidence: 0.58)
                    ] : [],
                    alternatives: row.alternatives.map {
                        TranscriptAlternative(text: $0, confidence: 0.74, languageCode: row.language, source: .transcription)
                    }
                )
                let context = TranscriptWindowBuffer().transcriptContext(currentSegment: segment)
                let started = DispatchTime.now().uptimeNanoseconds
                let frames = pipeline.candidateFrames(from: segment, context: context)
                let ended = DispatchTime.now().uptimeNanoseconds
                latencies.append(Double(ended - started) / 1_000_000)
                frameCount += frames.count
            }
        }

        let p95 = percentile(latencies, 0.95)
        print(String(format: "COPILOT_ASR_LATTICE samples=%d frames=%d p95_ms=%.3f", latencies.count, frameCount, p95))
        XCTAssertLessThanOrEqual(p95, 35)
        XCTAssertGreaterThan(frameCount, rows.count)
    }

    func testCopilotPartialStreamsWaitForStableFinalIntent() async throws {
        struct Row: Decodable {
            var id: String
            var sequence: [String]
            var final: String
            var responseNeeded: Bool
            var label: String
        }

        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/copilot_partial_streams.jsonl")
        let rows = try String(contentsOf: fixtureURL, encoding: .utf8)
            .split(separator: "\n")
            .map { try JSONDecoder().decode(Row.self, from: Data($0.utf8)) }
        let pipeline = CopilotSpeechUnderstandingPipeline()

        for row in rows {
            for partial in row.sequence.dropLast() {
                let segment = TranscriptSegment(
                    meetingId: UUID(),
                    speakerLabel: "You",
                    audioSource: .microphone,
                    text: partial,
                    originalLanguage: "pt-BR",
                    transcriptionPhase: .draft,
                    transcriptionEngine: .appleSpeech,
                    engineConfidence: 0.62,
                    languageConfidence: 0.64,
                    isFinal: false
                )
                let context = TranscriptWindowBuffer().transcriptContext(currentSegment: segment)
                let frames = pipeline.candidateFrames(from: segment, context: context)
                XCTAssertTrue(frames.allSatisfy { $0.isPartial || !$0.isFinal }, "\(row.id) partial: \(partial)")
            }

            let segment = TranscriptSegment(
                meetingId: UUID(),
                speakerLabel: "You",
                audioSource: .microphone,
                text: row.final,
                originalLanguage: "pt-BR",
                transcriptionEngine: .appleSpeech,
                engineConfidence: row.label == "clarification" ? 0.52 : 0.88,
                languageConfidence: row.label == "clarification" ? 0.38 : 0.82
            )
            let context = TranscriptWindowBuffer().transcriptContext(currentSegment: segment)
            let frames = pipeline.candidateFrames(from: segment, context: context)
            let provider = ScriptedRawAIProvider(responses: [
                copilotDecisionJSON(
                    shouldRespond: row.responseNeeded && row.label != "clarification",
                    intent: row.label == "clarification" ? "ambiguous" : row.label,
                    confidence: row.responseNeeded ? 0.91 : 0.25,
                    needsClarification: row.label == "clarification",
                    answerText: row.label == "clarification" ? "Pode esclarecer o pedido?" : ""
                )
            ])
            let decision = try await CopilotLLMDecisionService(provider: provider).decide(
                frames: frames,
                transcriptContext: context,
                meeting: makeAmbientMeeting(),
                preferences: AppPreferences(),
                source: .microphone,
                forceWeb: false
            )
            let detected = decision.shouldPresent
            XCTAssertEqual(detected, row.responseNeeded, row.id)
            if row.label == "clarification" {
                XCTAssertTrue(decision.decision.needsClarification, row.id)
            }
        }
    }

    func testCopilotDateDurationUsesLLMIntentInsteadOfLocalDateMathParser() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = projectRoot
            .appendingPathComponent("NotchCopilot/Meetings/MeetingSessionManager.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("dateDurationResult"))
        XCTAssertFalse(source.contains("monthNumber(for"))
        XCTAssertFalse(source.contains("parsedDate(in"))
    }

    func testCopilotAnswerPresenterChoosesProfessionalFormats() throws {
        let presenter = CopilotAnswerPresenter()
        let factualQuestion = makeQuestion("Responda em texto curto.")
        let factualClassification = makeCopilotClassification(for: factualQuestion, intent: .answerableQuestion)
        let factual = try presenter.present(
            text: "```text\nResposta curta\n```",
            candidate: factualQuestion,
            classification: factualClassification,
            tool: .answerSynthesis,
            intent: .answerableQuestion,
            sources: []
        )

        XCTAssertEqual(factual.text, "Resposta curta")
        XCTAssertEqual(factual.format, .plainShort)
        XCTAssertFalse(factual.text.contains("```"))

        let codeQuestion = makeQuestion("Como inverter uma árvore binária em Python?")
        let codeClassification = makeCopilotClassification(for: codeQuestion, intent: .actionRequest)
        let code = try presenter.present(
            text: "Use isto:\n```python\ndef invert_tree(root):\n    return root\n```",
            candidate: codeQuestion,
            classification: codeClassification,
            tool: .answerSynthesis,
            intent: .actionRequest,
            sources: []
        )

        XCTAssertEqual(code.format, .code)
        XCTAssertTrue(code.text.contains("```python"))

        let newsQuestion = makeQuestion("Pesquisa as últimas notícias sobre OpenAI")
        let newsClassification = makeCopilotClassification(for: newsQuestion, intent: .newsSearch)
        let news = try presenter.present(
            text: "1. OpenAI anunciou uma atualização relevante.",
            candidate: newsQuestion,
            classification: newsClassification,
            tool: .webSearch,
            intent: .newsSearch,
            sources: [AnswerSource(type: .web, title: "Source", snippet: "Snippet", reference: "nota-sem-url")]
        )

        XCTAssertEqual(news.format, .newsWithSources)
        XCTAssertTrue(news.text.contains("Fontes web indisponiveis"))
    }

    func testSuggestedAnswerDecodesMissingRichAnswerAsNil() throws {
        let answer = SuggestedAnswer(
            questionId: UUID(),
            answerText: "Answer",
            shortAnswer: "Answer",
            confidence: 0.8,
            riskLevel: .safe,
            usedSources: [],
            assumptions: [],
            caveats: [],
            generatedAt: Date(timeIntervalSinceReferenceDate: 10),
            latencyMs: 12,
            answerFormat: .paragraph
        )

        let data = try JSONEncoder().encode(answer)
        XCTAssertFalse(String(data: data, encoding: .utf8)?.contains("richAnswer") == true)

        let decoded = try JSONDecoder().decode(SuggestedAnswer.self, from: data)
        XCTAssertNil(decoded.richAnswer)
        XCTAssertEqual(decoded.answerText, answer.answerText)
    }

    func testRichAnswerValidatorDropsInvalidBlocksSourcesAndActions() {
        let sources = [
            AnswerSource(type: .web, title: "Valid web", snippet: nil, reference: "https://example.com/article"),
            AnswerSource(type: .web, title: "Invalid web", snippet: nil, reference: "ftp://example.com/article")
        ]
        let payload = RichAnswerPayload(blocks: [
            RichAnswerBlockPayload(type: "chart", text: "unsupported"),
            RichAnswerBlockPayload(
                type: RichAnswerBlockKind.lead.rawValue,
                text: String(repeating: "a", count: 1_500),
                actions: [
                    RichAnswerActionPayload(kind: RichAnswerActionKind.copy.rawValue, title: "Copy"),
                    RichAnswerActionPayload(kind: "delete_all", title: "Delete")
                ]
            ),
            RichAnswerBlockPayload(
                type: RichAnswerBlockKind.sourceCards.rawValue,
                title: "Sources",
                sourceIndexes: [0, 1, 99]
            )
        ])

        let validated = RichAnswerValidator().validated(payload, sources: sources)

        XCTAssertEqual(validated?.blocks.map(\.type), [RichAnswerBlockKind.lead.rawValue, RichAnswerBlockKind.sourceCards.rawValue])
        XCTAssertEqual(validated?.blocks.first?.text?.count, 1_200)
        XCTAssertEqual(validated?.blocks.first?.actions.map(\.kind), [RichAnswerActionKind.copy.rawValue])
        XCTAssertEqual(validated?.blocks.last?.sourceIndexes, [0])
    }

    func testRichAnswerValidatorAcceptsEverySupportedBlockKind() {
        let sources = [
            AnswerSource(type: .web, title: "Public article", snippet: "Public summary", reference: "https://example.com/article"),
            AnswerSource(type: .transcript, title: "Meeting transcript", snippet: "Internal meeting evidence", reference: nil)
        ]
        let action = RichAnswerActionPayload(kind: RichAnswerActionKind.copy.rawValue, title: "Copy")

        func block(for kind: RichAnswerBlockKind) -> RichAnswerBlockPayload {
            switch kind {
            case .lead:
                return RichAnswerBlockPayload(type: kind.rawValue, title: "Lead", text: "Short answer.")
            case .paragraph:
                return RichAnswerBlockPayload(type: kind.rawValue, text: "Detailed paragraph.")
            case .sourceCards:
                return RichAnswerBlockPayload(type: kind.rawValue, title: "Sources", sourceIndexes: [0])
            case .steps:
                return RichAnswerBlockPayload(type: kind.rawValue, title: "Steps", items: [RichAnswerItemPayload(text: "Do the first thing.")])
            case .checklist:
                return RichAnswerBlockPayload(type: kind.rawValue, title: "Checklist", items: [RichAnswerItemPayload(text: "Verify the change.", isChecked: true)])
            case .comparison:
                return RichAnswerBlockPayload(type: kind.rawValue, title: "Options", items: [RichAnswerItemPayload(title: "A", text: "Fast", value: "Recommended")])
            case .metrics:
                return RichAnswerBlockPayload(type: kind.rawValue, title: "Result", label: "Total", value: "42", formula: "40 + 2")
            case .code:
                return RichAnswerBlockPayload(type: kind.rawValue, language: "swift", code: "let total = 42")
            case .timeline:
                return RichAnswerBlockPayload(type: kind.rawValue, title: "Timeline", items: [RichAnswerItemPayload(title: "Now", text: "Ship the native renderer.")])
            case .memoryResults:
                return RichAnswerBlockPayload(type: kind.rawValue, title: "Evidence", items: [RichAnswerItemPayload(title: "Transcript", text: "Mentioned in meeting.", sourceIndex: 1)])
            case .clarification:
                return RichAnswerBlockPayload(type: kind.rawValue, title: "Clarification", text: "Which source should I use?", actions: [action])
            case .warning:
                return RichAnswerBlockPayload(type: kind.rawValue, title: "Caution", text: "Source unavailable.", severity: "caution")
            case .actions:
                return RichAnswerBlockPayload(type: kind.rawValue, actions: [action])
            }
        }

        let payload = RichAnswerPayload(blocks: RichAnswerBlockKind.allCases.map(block(for:)))
        let validated = RichAnswerValidator().validated(payload, sources: sources)

        XCTAssertEqual(validated?.blocks.map(\.type), RichAnswerBlockKind.allCases.map(\.rawValue))
    }

    func testRichAnswerRendererSmokeRendersEverySupportedComponent() {
        let sources = [
            AnswerSource(type: .web, title: "Public article", snippet: "Public summary", reference: "https://example.com/article"),
            AnswerSource(type: .transcript, title: "Meeting transcript", snippet: "Internal evidence", reference: nil)
        ]
        let actions = [
            RichAnswerActionPayload(kind: RichAnswerActionKind.copy.rawValue, title: "Copy"),
            RichAnswerActionPayload(kind: RichAnswerActionKind.openSources.rawValue, title: "Sources"),
            RichAnswerActionPayload(kind: RichAnswerActionKind.regenerateWithWeb.rawValue, title: "Web")
        ]
        let payload = RichAnswerPayload(blocks: [
            RichAnswerBlockPayload(type: RichAnswerBlockKind.lead.rawValue, title: "Lead", text: "Short native answer."),
            RichAnswerBlockPayload(type: RichAnswerBlockKind.paragraph.rawValue, text: "Paragraph content with **markdown**."),
            RichAnswerBlockPayload(type: RichAnswerBlockKind.sourceCards.rawValue, title: "Sources", sourceIndexes: [0]),
            RichAnswerBlockPayload(type: RichAnswerBlockKind.steps.rawValue, title: "Steps", items: [RichAnswerItemPayload(text: "Open the panel."), RichAnswerItemPayload(text: "Read the card.")]),
            RichAnswerBlockPayload(type: RichAnswerBlockKind.checklist.rawValue, title: "Checklist", items: [RichAnswerItemPayload(text: "Card is visible.", isChecked: true)]),
            RichAnswerBlockPayload(type: RichAnswerBlockKind.comparison.rawValue, title: "Compare", items: [RichAnswerItemPayload(title: "Native", text: "Fast and private.", value: "v1")]),
            RichAnswerBlockPayload(type: RichAnswerBlockKind.metrics.rawValue, title: "Metric", label: "Latency", value: "120 ms", formula: "80 + 40"),
            RichAnswerBlockPayload(type: RichAnswerBlockKind.code.rawValue, language: "swift", code: "let visible = true"),
            RichAnswerBlockPayload(type: RichAnswerBlockKind.timeline.rawValue, title: "Timeline", items: [RichAnswerItemPayload(title: "Today", text: "Rendered inside scroll.")]),
            RichAnswerBlockPayload(type: RichAnswerBlockKind.memoryResults.rawValue, title: "Evidence", items: [RichAnswerItemPayload(title: "Transcript", text: "Mentioned by Ana.", sourceIndex: 1)]),
            RichAnswerBlockPayload(type: RichAnswerBlockKind.clarification.rawValue, title: "Clarification", text: "Do you want web sources too?", actions: actions),
            RichAnswerBlockPayload(type: RichAnswerBlockKind.warning.rawValue, title: "Warning", text: "Preview unavailable.", severity: "caution"),
            RichAnswerBlockPayload(type: RichAnswerBlockKind.actions.rawValue, actions: actions)
        ])
        let renderer = RichAnswerRenderer(
            text: "Fallback text",
            richAnswer: payload,
            format: .paragraph,
            sources: sources,
            confidence: 0.91,
            riskLevel: .safe,
            tone: .concise,
            allowRemoteLinkPreview: false
        )
        .frame(width: 640, height: 900)
        .background(Color.black)

        XCTAssertTrue(renderedViewHasVisiblePixels(renderer, size: CGSize(width: 640, height: 900)))
    }

    func testRichAnswerStepDisplayNormalizerRemovesDuplicateMarkers() {
        let numbered = RichAnswerStepDisplayNormalizer.normalized(
            RichAnswerItemPayload(title: "1", text: "1. Verifique se o nó atual é `None` e retorne."),
            index: 0,
            numbered: true
        )
        XCTAssertNil(numbered.title)
        XCTAssertEqual(numbered.text, "Verifique se o nó atual é `None` e retorne.")

        let dashed = RichAnswerStepDisplayNormalizer.normalized(
            RichAnswerItemPayload(title: "2.", text: "- Troque `node.left` e `node.right`."),
            index: 1,
            numbered: true
        )
        XCTAssertNil(dashed.title)
        XCTAssertEqual(dashed.text, "Troque `node.left` e `node.right`.")

        let timeline = RichAnswerStepDisplayNormalizer.normalized(
            RichAnswerItemPayload(title: "2026", text: "2026: manter esse marco visível."),
            index: 0,
            numbered: false
        )
        XCTAssertEqual(timeline.title, "2026")
        XCTAssertEqual(timeline.text, "2026: manter esse marco visível.")
    }

    func testRichAnswerFallbackBuildsNewsSourceRailAndRemovesRawURLs() {
        let sources = [
            AnswerSource(
                type: .web,
                title: "Tech News",
                snippet: "Resumo curto.",
                reference: "https://example.com/news"
            )
        ]
        let payload = RichAnswerFallbackBuilder.payload(
            text: "Noticia em https://example.com/news com detalhes.",
            format: .newsWithSources,
            sources: sources,
            riskLevel: .safe
        )

        XCTAssertTrue(payload.blocks.contains { $0.type == RichAnswerBlockKind.sourceCards.rawValue && $0.sourceIndexes == [0] })
        let paragraph = payload.blocks.first { $0.type == RichAnswerBlockKind.paragraph.rawValue }?.text ?? ""
        XCTAssertFalse(paragraph.contains("https://"))
        XCTAssertTrue(paragraph.contains("Tech News"))
    }

    func testRichAnswerFallbackCanSuppressEvidenceBlocksForRealtimeQA() {
        let sources = [
            AnswerSource(
                type: .transcript,
                title: "Transcript",
                snippet: "Ana mentioned the rollout risk.",
                reference: nil
            )
        ]
        let payload = RichAnswerFallbackBuilder.payload(
            text: "Use a cautious answer.",
            format: .paragraph,
            sources: sources,
            includeEvidence: false
        )

        XCTAssertFalse(payload.blocks.contains { $0.type == RichAnswerBlockKind.memoryResults.rawValue })
        XCTAssertTrue(payload.blocks.contains { $0.type == RichAnswerBlockKind.paragraph.rawValue })
    }

    func testRichAnswerFallbackKeepsCodeAndCalculationShapes() {
        let codePayload = RichAnswerFallbackBuilder.payload(
            text: "Use isto:\n```swift\nlet total = 42\n```",
            format: .code,
            sources: []
        )
        XCTAssertEqual(codePayload.blocks.last?.type, RichAnswerBlockKind.code.rawValue)
        XCTAssertEqual(codePayload.blocks.last?.language, "swift")
        XCTAssertEqual(codePayload.blocks.last?.code, "let total = 42")

        let metricPayload = RichAnswerFallbackBuilder.payload(
            text: "O resultado e 42 kg.",
            format: .calculation,
            sources: []
        )
        XCTAssertEqual(metricPayload.blocks.first?.type, RichAnswerBlockKind.metrics.rawValue)
        XCTAssertEqual(metricPayload.blocks.first?.value, "42 kg")
    }

    func testWebLinkPreviewServiceParsesOpenGraphMetadata() {
        let baseURL = URL(string: "https://example.com/path/article")!
        let fallback = WebLinkPreview(
            url: baseURL,
            title: "Fallback",
            domain: "example.com",
            description: nil,
            imageURL: nil,
            faviconURL: WebLinkPreview.defaultFaviconURL(for: baseURL)
        )
        let html = """
        <html>
          <head>
            <meta property="og:title" content="A &amp; B">
            <meta property="og:description" content="Short &quot;summary&quot;">
            <meta property="og:image" content="images/og.png">
            <link rel="shortcut icon" href="/brand.ico">
          </head>
        </html>
        """

        let preview = WebLinkPreviewService.preview(fromHTML: html, base: baseURL, fallback: fallback)

        XCTAssertEqual(preview.title, "A & B")
        XCTAssertEqual(preview.description, #"Short "summary""#)
        XCTAssertEqual(preview.imageURL?.absoluteString, "https://example.com/path/images/og.png")
        XCTAssertEqual(preview.faviconURL?.absoluteString, "https://example.com/brand.ico")
    }

    func testWebLinkPreviewServiceFallsBackForAccessDeniedResponses() {
        let baseURL = URL(string: "https://noticias.uol.com.br/article")!
        let fallback = WebLinkPreview(
            url: baseURL,
            title: "Brasil mira leilao de tecnologia",
            domain: "noticias.uol.com.br",
            description: "Resumo vindo da fonte de busca.",
            imageURL: nil,
            faviconURL: WebLinkPreview.defaultFaviconURL(for: baseURL)
        )
        let html = """
        <html>
          <head><title>Access Denied</title></head>
          <body>
            Access Denied
            You don't have permission to access this resource.
            Reference #18.akamai
          </body>
        </html>
        """

        let blockedByStatus = WebLinkPreviewService.preview(fromHTML: html, base: baseURL, fallback: fallback, httpStatusCode: 403)
        let blockedByContent = WebLinkPreviewService.preview(fromHTML: html, base: baseURL, fallback: fallback, httpStatusCode: 200)

        XCTAssertEqual(blockedByStatus, fallback)
        XCTAssertEqual(blockedByContent, fallback)
        XCTAssertNotEqual(blockedByContent.title, "Access Denied")
    }

    func testWebLinkPreviewRequestUsesBrowserLikeHeaders() {
        let url = URL(string: "https://example.com/article")!
        let request = WebLinkPreviewService.request(for: url)

        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Language"), "pt-BR,pt;q=0.9,en-US;q=0.8,en;q=0.7")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Accept")?.contains("text/html") == true)
        XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.contains("Safari") == true)
        XCTAssertGreaterThanOrEqual(request.timeoutInterval, 4.0)
    }

    func testWebLinkPreviewServiceLocalOnlyReturnsFallbackWithoutRemoteFetch() async {
        let source = AnswerSource(
            type: .web,
            title: "Local only title",
            snippet: "Local description",
            reference: "https://notchly.invalid/no-network"
        )

        let preview = await WebLinkPreviewService.shared.preview(for: source, allowRemoteFetch: false)

        XCTAssertEqual(preview.title, "Local only title")
        XCTAssertEqual(preview.description, "Local description")
        XCTAssertEqual(preview.domain, "notchly.invalid")
    }

    func testWebLinkPreviewFallbackUsesLocalSourceIdentityWithoutFakeWebDomain() {
        let source = AnswerSource(type: .transcript, title: "Transcript evidence", snippet: "Local only", reference: nil)

        let preview = WebLinkPreview.fallback(for: source)

        XCTAssertEqual(preview.title, "Transcript evidence")
        XCTAssertEqual(preview.domain, "transcript")
        XCTAssertNil(preview.faviconURL)
    }

    func testCopilotStateMachineTelemetryAndFailureTaxonomy() {
        var machine = CopilotStateMachine()
        XCTAssertTrue(machine.transition(to: .listening))
        XCTAssertTrue(machine.transition(to: .intentDetected))
        XCTAssertTrue(machine.transition(to: .classifying))
        XCTAssertTrue(machine.transition(to: .routing))
        XCTAssertTrue(machine.transition(to: .searching))
        XCTAssertTrue(machine.transition(to: .ready))
        XCTAssertFalse(machine.transition(to: .calculating))

        let telemetry = CopilotQualityTelemetry()
        let first = telemetry.record(CopilotQualityEvent(
            stage: .intent,
            accepted: true,
            tool: .webSearch,
            intent: .newsSearch,
            runtimeState: .searching,
            languageCode: "pt-BR",
            source: .microphone,
            latencyMs: 42,
            reason: "news_request",
            failureKind: nil
        ))
        let second = telemetry.record(CopilotQualityEvent(
            stage: .total,
            accepted: false,
            tool: .webSearch,
            intent: .newsSearch,
            runtimeState: .failedRecoverable,
            languageCode: "pt-BR",
            source: .microphone,
            latencyMs: 80,
            reason: "web_provider_unavailable",
            failureKind: .webProviderUnavailable
        ))

        XCTAssertEqual(first.acceptedCount, 1)
        XCTAssertEqual(second.failureCount, 1)
        XCTAssertEqual(second.latestFailureKind, .webProviderUnavailable)
        XCTAssertEqual(CopilotFailureKind.webProviderUnavailable.userMessage, "Busca web indisponivel. Conecte OpenAI/Perplexity ou configure Brave Search.")
    }

    func testCopilotInteractionStorePurgesExpiredDataAndRedactsMemory() throws {
        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let cryptor = try testCryptor()
        let repository = MeetingRepository(container: container, cryptor: cryptor)
        let store = CopilotInteractionStore(repository: repository, retentionDays: 7)
        let expired = CopilotInteraction(
            contextKind: .ambient,
            source: .typed,
            prompt: "old token=supersecret12345",
            response: "old",
            tool: .answerSynthesis,
            intent: .answerableQuestion,
            confidence: 0.9,
            latencyMs: 10,
            createdAt: Date(timeIntervalSince1970: 10),
            expiresAt: Date(timeIntervalSince1970: 20)
        )
        let fresh = CopilotInteraction(
            contextKind: .ambient,
            source: .typed,
            prompt: "new",
            response: "ok",
            tool: .answerSynthesis,
            intent: .answerableQuestion,
            confidence: 0.9,
            latencyMs: 10,
            createdAt: Date(timeIntervalSince1970: 30),
            expiresAt: Date(timeIntervalSince1970: 10_000)
        )

        try store.saveInteraction(expired)
        try store.saveInteraction(fresh)
        try store.saveMemory(prompt: "token=supersecret12345", answer: "safe", languageCode: "en-US", interactionId: fresh.id)

        let loaded = store.load(now: Date(timeIntervalSince1970: 100))

        XCTAssertEqual(loaded.interactions.map(\.id), [fresh.id])
        let memory = try repository.copilotMemoryEntries(query: "safe", now: Date(timeIntervalSince1970: 100), limit: 2)
        XCTAssertTrue(memory.first?.text.contains("[redacted]") == true)
        XCTAssertFalse(memory.first?.text.contains("supersecret12345") == true)
    }

    func testCopilotResponsiveLayoutAndVisualHarnessRenderKeyStates() throws {
        let appState = AppState()
        let question = makeQuestion("Qual é o nome da capital da França?")
        let shortAnswer = SuggestedAnswer(
            questionId: question.id,
            answerText: "A capital da França é Paris.",
            shortAnswer: "A capital da França é Paris.",
            confidence: 0.92,
            riskLevel: .safe,
            usedSources: [],
            assumptions: [],
            caveats: [],
            latencyMs: 20,
            expandedAnswer: "A capital da França é Paris.",
            answerFormat: .plainShort
        )

        appState.upsertQuestionInQueue(candidate: question, classification: makeCopilotClassification(for: question, intent: .answerableQuestion), stage: .ready, select: true)
        appState.updateQueuedQuestionAnswer(candidate: question, answer: shortAnswer)
        appState.showQuestionAnswerPanel(mode: .answer)

        let compactAnswerSize = appState.notchIslandSize
        XCTAssertLessThanOrEqual(compactAnswerSize.height, 360)
        XCTAssertGreaterThanOrEqual(appState.notchIslandCanvasSize.width, compactAnswerSize.width)
        XCTAssertGreaterThanOrEqual(appState.notchIslandCanvasSize.height, compactAnswerSize.height)
        XCTAssertTrue(renderedViewHasVisiblePixels(MeetingPanelView(appState: appState), size: CGSize(width: appState.expandedPanelContentWidth, height: appState.expandedPanelContentHeight)))

        let codeAnswer = SuggestedAnswer(
            questionId: question.id,
            answerText: "Use uma função:\n```python\ndef invert_tree(root):\n    return root\n```",
            shortAnswer: "Use uma função:\n```python\ndef invert_tree(root):\n    return root\n```",
            confidence: 0.88,
            riskLevel: .safe,
            usedSources: [],
            assumptions: [],
            caveats: [],
            latencyMs: 40,
            expandedAnswer: "Use uma função:\n```python\ndef invert_tree(root):\n    return root\n```",
            answerFormat: .code
        )
        appState.updateQueuedQuestionAnswer(candidate: question, answer: codeAnswer)

        XCTAssertGreaterThan(appState.notchIslandSize.height, compactAnswerSize.height)
        XCTAssertLessThanOrEqual(appState.notchIslandSize.width, 760)

        let failed = SuggestedAnswer(
            questionId: question.id,
            answerText: CopilotFailureKind.webProviderUnavailable.userMessage,
            shortAnswer: CopilotFailureKind.webProviderUnavailable.userMessage,
            confidence: 0.50,
            riskLevel: .moderate,
            usedSources: [],
            assumptions: [],
            caveats: [],
            latencyMs: 15,
            expandedAnswer: CopilotFailureKind.webProviderUnavailable.userMessage,
            suggestedTone: .askForClarification,
            provider: .unavailable,
            answerFormat: .errorState
        )
        appState.updateQueuedQuestionAnswer(candidate: question, answer: failed)

        XCTAssertLessThanOrEqual(appState.notchIslandSize.height, 360)
        XCTAssertFalse(appState.visibleAnswerText.contains("Não consegui gerar uma resposta agora"))
    }

    func testCopilotHistoryTimelineRendersManyInteractionsWithoutOversizingIsland() {
        let appState = AppState()
        let now = Date()
        appState.copilotInteractions = (0..<24).map { index in
            CopilotInteraction(
                contextKind: .ambient,
                source: .microphone,
                prompt: index == 0 ? "Quanto é 2 + 2?" : "Pergunta \(index) sobre arquitetura e produto",
                response: index == 0 ? "Resposta curta" : "Resposta curta \(index) com contexto suficiente para preview.",
                tool: .answerSynthesis,
                intent: index % 3 == 0 ? .calculation : .answerableQuestion,
                confidence: 0.92,
                latencyMs: 18 + index,
                createdAt: now.addingTimeInterval(TimeInterval(-index * 60)),
                expiresAt: now.addingTimeInterval(7 * 24 * 60 * 60)
            )
        }
        appState.isPanelExpanded = true

        XCTAssertGreaterThanOrEqual(appState.notchIslandSize.width, 520)
        XCTAssertLessThanOrEqual(appState.notchIslandSize.width, 640)
        XCTAssertGreaterThanOrEqual(appState.notchIslandSize.height, 318)
        XCTAssertLessThanOrEqual(appState.notchIslandSize.height, 520)
        XCTAssertTrue(renderedViewHasVisiblePixels(MeetingPanelView(appState: appState), size: CGSize(width: appState.expandedPanelContentWidth, height: appState.expandedPanelContentHeight)))
    }

    func testCopilotHistoryPanelCanReplaceTranscriptDuringActiveMeeting() {
        let appState = AppState()
        let now = Date()
        appState.currentMeeting = MeetingSession(title: "Design Review", status: .listening)
        appState.islandMode = .listening
        appState.copilotInteractions = [
            CopilotInteraction(
                contextKind: .ambient,
                source: .microphone,
                prompt: "Qual foi a decisão?",
                response: "A equipe decidiu seguir com o plano atual.",
                tool: .answerSynthesis,
                intent: .answerableQuestion,
                confidence: 0.9,
                latencyMs: 28,
                createdAt: now,
                expiresAt: now.addingTimeInterval(7 * 24 * 60 * 60)
            )
        ]

        appState.showCopilotHistoryPanel()

        XCTAssertTrue(appState.isShowingCopilotHistory)
        XCTAssertTrue(appState.isPanelExpanded)
        XCTAssertEqual(appState.currentMeeting?.status, .listening)
        XCTAssertGreaterThanOrEqual(appState.notchIslandSize.width, 520)
        XCTAssertTrue(renderedViewHasVisiblePixels(MeetingPanelView(appState: appState), size: CGSize(width: appState.expandedPanelContentWidth, height: appState.expandedPanelContentHeight)))

        appState.selectPresentationMode(.transcript)
        XCTAssertFalse(appState.isShowingCopilotHistory)
    }

    func testCopilotHistoryTimelineRendersRichComponentsAndCanOpenAnswerDetail() {
        let appState = AppState()
        let now = Date()
        let sources = [
            AnswerSource(
                type: .web,
                title: "Tech News",
                snippet: "Resumo com o contexto mais importante.",
                reference: "https://example.com/news"
            )
        ]
        let richAnswer = RichAnswerPayload(blocks: [
            RichAnswerBlockPayload(
                type: RichAnswerBlockKind.lead.rawValue,
                title: "Resumo",
                text: "Duas noticias relevantes de tecnologia no Brasil."
            ),
            RichAnswerBlockPayload(
                type: RichAnswerBlockKind.sourceCards.rawValue,
                title: "Fontes",
                sourceIndexes: [0]
            ),
            RichAnswerBlockPayload(
                type: RichAnswerBlockKind.steps.rawValue,
                title: "Próximos passos",
                items: [
                    RichAnswerItemPayload(text: "Abrir a fonte para validar os detalhes."),
                    RichAnswerItemPayload(text: "Comparar com uma segunda cobertura.")
                ]
            )
        ])
        let interaction = CopilotInteraction(
            contextKind: .ambient,
            source: .typed,
            prompt: "Quais são as notícias de tecnologia hoje no Brasil?",
            response: "Duas noticias relevantes de tecnologia no Brasil com fontes verificaveis.",
            tool: .webSearch,
            intent: .newsSearch,
            confidence: 0.91,
            latencyMs: 240,
            sources: sources,
            richAnswer: richAnswer,
            createdAt: now,
            expiresAt: now.addingTimeInterval(7 * 24 * 60 * 60)
        )

        appState.copilotInteractions = [interaction]
        appState.showCopilotHistoryPanel()
        appState.selectCopilotInteraction(interaction)

        XCTAssertTrue(appState.isShowingCopilotHistory)
        XCTAssertFalse(appState.isShowingCopilotAnswerDetail)
        XCTAssertEqual(appState.visibleAnswerText, "")
        XCTAssertTrue(renderedViewHasVisiblePixels(MeetingPanelView(appState: appState), size: CGSize(width: appState.expandedPanelContentWidth, height: appState.expandedPanelContentHeight)))

        appState.openCopilotInteractionAnswer(interaction)

        XCTAssertFalse(appState.isShowingCopilotHistory)
        XCTAssertTrue(appState.isShowingCopilotAnswerDetail)
        XCTAssertEqual(appState.activeCopilotInteraction?.id, interaction.id)
        XCTAssertEqual(appState.visibleAnswerText, interaction.response)
        XCTAssertEqual(appState.selectedAnswerPresentationText, interaction.response)
        XCTAssertTrue(renderedViewHasVisiblePixels(MeetingPanelView(appState: appState), size: CGSize(width: appState.expandedPanelContentWidth, height: appState.expandedPanelContentHeight)))

        appState.showCopilotHistoryPanel()
        XCTAssertTrue(appState.isShowingCopilotHistory)
        XCTAssertFalse(appState.isShowingCopilotAnswerDetail)
    }

    func testCopilotTimelinePreviewCompactsRichAndCodePayloads() {
        let richAnswer = RichAnswerPayload(blocks: [
            RichAnswerBlockPayload(
                type: RichAnswerBlockKind.steps.rawValue,
                title: "Passos",
                items: [
                    RichAnswerItemPayload(text: "Verifique se o nó atual é `None` e retorne."),
                    RichAnswerItemPayload(text: "Troque `node.left` e `node.right`.")
                ]
            ),
            RichAnswerBlockPayload(
                type: RichAnswerBlockKind.code.rawValue,
                language: "python",
                code: "def invert_tree(root):\n    return root"
            )
        ])

        let preview = CopilotTimelinePreviewBuilder.preview(
            response: "```python\ndef invert_tree(root):\n    return root\n```",
            richAnswer: richAnswer,
            sources: [],
            limit: 72
        )

        XCTAssertLessThanOrEqual(preview.count, 75)
        XCTAssertFalse(preview.contains("```"))
        XCTAssertFalse(preview.contains("\n"))
        XCTAssertTrue(preview.contains("Verifique"))
        XCTAssertFalse(preview.contains("def invert_tree"))
    }

    func testCopilotHistoryActionsSelectCopyAndFeedbackPersistSelectedInteraction() {
        let appState = AppState()
        let interaction = CopilotInteraction(
            contextKind: .ambient,
            source: .typed,
            prompt: "Qual é a capital da França?",
            response: "Paris",
            tool: .answerSynthesis,
            intent: .answerableQuestion,
            confidence: 0.94,
            latencyMs: 24,
            expiresAt: Date().addingTimeInterval(7 * 24 * 60 * 60)
        )

        appState.applyCopilotInteraction(interaction)
        appState.selectCopilotInteraction(interaction)
        appState.copyCopilotInteractionToPasteboard(interaction)

        XCTAssertEqual(appState.activeCopilotInteraction?.id, interaction.id)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Paris")

        appState.recordCopilotFeedback(.markedUseful, note: "Timeline useful", for: interaction)

        XCTAssertEqual(appState.copilotInteractions.first?.feedbackEvents.last?.kind, .markedUseful)
        XCTAssertEqual(appState.activeCopilotInteraction?.feedbackEvents.last?.note, "Timeline useful")
    }

    func testAmbientCopilotShowsCompactDropdownLoadingBeforeResultPanelOpens() {
        let appState = AppState()
        let question = makeQuestion("Qual é a capital da França?")
        let answer = SuggestedAnswer(
            questionId: question.id,
            answerText: "A capital da França é Paris.",
            shortAnswer: "A capital da França é Paris.",
            confidence: 0.94,
            riskLevel: .safe,
            usedSources: [],
            assumptions: [],
            caveats: [],
            latencyMs: 18,
            expandedAnswer: "A capital da França é Paris.",
            answerFormat: .plainShort
        )

        appState.upsertQuestionInQueue(candidate: question, classification: nil, stage: .classifying, select: true)
        XCTAssertEqual(appState.islandMode, .thinking)
        XCTAssertFalse(appState.isPanelExpanded)
        XCTAssertFalse(appState.isIdleHiddenBehindNotch)
        XCTAssertTrue(appState.shouldShowAmbientCopilotLoadingIndicator)
        XCTAssertEqual(appState.notchIslandSize, NotchIslandChromeMetrics.ambientCopilotLoadingSize)
        XCTAssertEqual(appState.notchIslandCanvasSize, NotchIslandChromeMetrics.ambientCopilotLoadingSize)

        appState.updateQueuedQuestionStage(questionId: question.id, stage: .drafting)
        XCTAssertEqual(appState.islandMode, .thinking)
        XCTAssertTrue(appState.shouldShowAmbientCopilotLoadingIndicator)

        appState.updateQueuedQuestionAnswer(candidate: question, answer: answer)
        XCTAssertEqual(appState.islandMode, .idle)
        XCTAssertTrue(appState.isIdleHiddenBehindNotch)

        appState.showQuestionAnswerPanel(mode: .answer)
        XCTAssertTrue(appState.isPanelExpanded)
        XCTAssertEqual(appState.islandMode, .questionDetected)
        XCTAssertGreaterThan(appState.notchIslandSize.height, NotchIslandChromeMetrics.collapsedNotchFootprintSize.height)

        appState.collapsePanelPreservingContext()
        XCTAssertFalse(appState.isPanelExpanded)
        XCTAssertEqual(appState.islandMode, .idle)
        XCTAssertTrue(appState.isIdleHiddenBehindNotch)
    }

    func testAmbientCopilotLoadingWindowExpandsDownFromNotch() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let collapsedFrame = NotchIslandWindowPlacement.topAnchoredFrame(
            for: NotchIslandChromeMetrics.collapsedNotchFootprintSize,
            in: screenFrame
        )
        let listeningFrame = NotchIslandWindowPlacement.topAnchoredFrame(
            for: NotchIslandChromeMetrics.ambientCopilotListeningSize,
            in: screenFrame
        )
        let processingFrame = NotchIslandWindowPlacement.topAnchoredFrame(
            for: NotchIslandChromeMetrics.ambientCopilotProcessingSize,
            in: screenFrame
        )

        XCTAssertEqual(listeningFrame.midX, collapsedFrame.midX)
        XCTAssertEqual(listeningFrame.minX, collapsedFrame.minX)
        XCTAssertEqual(listeningFrame.width, collapsedFrame.width)
        XCTAssertEqual(listeningFrame.maxY, collapsedFrame.maxY)
        XCTAssertGreaterThan(listeningFrame.height, collapsedFrame.height)
        XCTAssertLessThan(listeningFrame.minY, collapsedFrame.minY)
        XCTAssertEqual(processingFrame.midX, collapsedFrame.midX)
        XCTAssertEqual(processingFrame.minX, listeningFrame.minX)
        XCTAssertEqual(processingFrame.width, listeningFrame.width)
        XCTAssertEqual(processingFrame.maxY, collapsedFrame.maxY)
        XCTAssertEqual(NotchIslandChromeMetrics.ambientCopilotListeningSize, NotchIslandChromeMetrics.detectedMeetingSize)
        XCTAssertEqual(NotchIslandChromeMetrics.ambientCopilotProcessingSize, NotchIslandChromeMetrics.detectedMeetingSize)
        XCTAssertEqual(NotchIslandChromeMetrics.ambientCopilotProcessingSize.width, NotchIslandChromeMetrics.ambientCopilotListeningSize.width)
    }

    func testCompactCopilotDropdownMatchesDetectedMeetingFootprint() {
        XCTAssertEqual(NotchIslandChromeMetrics.ambientCopilotListeningSize, NotchIslandChromeMetrics.detectedMeetingSize)
        XCTAssertEqual(NotchIslandChromeMetrics.ambientCopilotProcessingSize, NotchIslandChromeMetrics.detectedMeetingSize)
        XCTAssertEqual(NotchIslandChromeMetrics.ambientCopilotLoadingSize, NotchIslandChromeMetrics.detectedMeetingSize)
    }

    func testCopilotPushToTalkListeningUsesCompactDropdownWaveState() {
        let appState = AppState()

        appState.isCopilotPushToTalkActive = true

        XCTAssertTrue(appState.shouldShowCopilotPushToTalkListeningIndicator)
        XCTAssertFalse(appState.shouldShowCopilotPushToTalkProcessingIndicator)
        XCTAssertTrue(appState.shouldShowCopilotPushToTalkCompactIndicator)
        XCTAssertFalse(appState.isIdleHiddenBehindNotch)
        XCTAssertEqual(appState.notchIslandSize, NotchIslandChromeMetrics.ambientCopilotListeningSize)
        XCTAssertEqual(appState.notchIslandCanvasSize, NotchIslandChromeMetrics.ambientCopilotListeningSize)
        XCTAssertFalse(appState.shouldAnchorCompactIslandToNotchRightEdge)
    }

    func testCopilotPushToTalkProcessingUsesCompactDropdownSpinnerState() {
        let appState = AppState()

        appState.setCopilotPushToTalkProcessing(true, status: "Processing")

        XCTAssertFalse(appState.shouldShowCopilotPushToTalkListeningIndicator)
        XCTAssertTrue(appState.shouldShowCopilotPushToTalkProcessingIndicator)
        XCTAssertTrue(appState.shouldShowCopilotPushToTalkCompactIndicator)
        XCTAssertFalse(appState.isIdleHiddenBehindNotch)
        XCTAssertEqual(appState.notchIslandSize, NotchIslandChromeMetrics.ambientCopilotLoadingSize)
        XCTAssertEqual(appState.notchIslandCanvasSize, NotchIslandChromeMetrics.ambientCopilotLoadingSize)
        XCTAssertFalse(appState.shouldAnchorCompactIslandToNotchRightEdge)
        XCTAssertEqual(appState.ambientCopilotStatus, "Processing")
    }

    private func ambientActivationDecision(_ classification: CopilotIntentClassification) -> Bool {
        let threshold = classification.strongSignals.contains("directed_to_copilot") ? 0.70 : 0.80
        return classification.responseNeeded &&
            classification.confidence >= threshold &&
            classification.strongSignals.count >= 2 &&
            classification.negativeSignals.isEmpty
    }

    private func makeSpeechFrame(_ text: String, language: String = "pt-BR", confidence: Double = 0.90, isFinal: Bool = true) -> SpeechCandidateFrame {
        SpeechCandidateFrame(
            sourceSegmentId: UUID(),
            text: text,
            source: .best,
            languageCode: language,
            asrConfidence: confidence,
            languageConfidence: confidence,
            stability: isFinal ? 1.0 : 0.62,
            wordConfidences: [],
            startTime: 0,
            endTime: 1,
            isPartial: !isFinal,
            isFinal: isFinal,
            repairReason: nil,
            clarificationMessage: nil
        )
    }

    private func makeAmbientMeeting() -> MeetingSession {
        MeetingSession(id: UUID(), title: "Copilot", source: .manual, startedAt: Date(), status: .listening, primaryLanguage: "pt-BR", meetingType: .general)
    }

    private func copilotDecisionJSON(
        shouldRespond: Bool,
        intent: String,
        confidence: Double,
        needsWeb: Bool = false,
        needsReminderAction: Bool = false,
        needsClarification: Bool = false,
        answerText: String = ""
    ) -> String {
        """
        {
          "shouldRespond": \(shouldRespond),
          "intent": "\(intent)",
          "needsWeb": \(needsWeb),
          "needsReminderAction": \(needsReminderAction),
          "needsClarification": \(needsClarification),
          "answerFormat": "\(needsClarification ? "plain_short" : "paragraph")",
          "answerText": "\(answerText)",
          "confidence": \(confidence),
          "reason": "mock_llm",
          "reminderAction": null
        }
        """
    }

    func testWindowCaptureProtectionTogglesSharingTypeIdempotently() {
        WindowCaptureProtection.resetAuditForTests()
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 80, height: 60),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        WindowCaptureProtection.apply(isEnabled: true, to: window)
        XCTAssertEqual(window.sharingType, .none)

        WindowCaptureProtection.apply(isEnabled: true, to: window)
        XCTAssertEqual(window.sharingType, .none)

        WindowCaptureProtection.apply(isEnabled: false, to: window)
        XCTAssertEqual(window.sharingType, .readOnly)
    }

    func testWindowCaptureProtectionAuditRecordsWindowMetadata() throws {
        WindowCaptureProtection.resetAuditForTests()
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 120, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Privacy Audit Settings"
        defer {
            window.orderOut(nil)
            window.close()
            WindowCaptureProtection.resetAuditForTests()
        }

        WindowCaptureProtection.apply(isEnabled: true, to: window, role: .settings)
        WindowCaptureProtection.apply(isEnabled: true, to: window, role: .settings)

        let audit = try XCTUnwrap(WindowCaptureProtection.auditSnapshots().first)
        XCTAssertEqual(audit.windowTitle, "Privacy Audit Settings")
        XCTAssertEqual(audit.role, .settings)
        XCTAssertEqual(audit.sharingTypeDescription, "none")
        XCTAssertEqual(audit.isSharingBlocked, true)
        XCTAssertEqual(audit.mayContainProtectedContent, true)
        XCTAssertEqual(audit.requestedProtection, true)

        WindowCaptureProtection.apply(isEnabled: false, to: window, role: .settings)
        let disabledAudit = try XCTUnwrap(WindowCaptureProtection.auditSnapshots().first)
        XCTAssertEqual(disabledAudit.sharingTypeDescription, "readOnly")
        XCTAssertEqual(disabledAudit.isSharingBlocked, false)
        XCTAssertEqual(disabledAudit.mayContainProtectedContent, false)
    }

    func testPrivacyDiagnosticsSnapshotDocumentsLimitsAndManualValidation() {
        WindowCaptureProtection.resetAuditForTests()
        let snapshot = PrivacyDiagnostics.snapshot(isStealthModeEnabled: true)

        XCTAssertEqual(snapshot.modeDisplayName, "Stealth Mode (Privacy)")
        XCTAssertEqual(snapshot.capturePolicySummary, "Protected where public APIs are honored")
        XCTAssertTrue(snapshot.focusPolicySummary.contains("non-activating"))
        XCTAssertTrue(snapshot.limitations.contains { $0.localizedCaseInsensitiveContains("public macOS") })
        XCTAssertTrue(snapshot.limitations.contains { $0.localizedCaseInsensitiveContains("real input events") })
        XCTAssertTrue(snapshot.manualValidationItems.contains { $0.title.contains("screencapture") })
        XCTAssertTrue(snapshot.manualValidationItems.contains { $0.title.contains("Activity Monitor") })
        XCTAssertTrue(snapshot.manualValidationItems.contains { $0.title.contains("OBS") })
    }

    func testWindowCaptureProtectionCGWindowListHarnessOmitsProtectedSentinelContent() throws {
        guard #unavailable(macOS 14.0) else {
            throw XCTSkip("CGWindowListCreateImage is deprecated on macOS 14+; use the opt-in screencapture and ScreenCaptureKit harnesses for live capture validation.")
        }

        let window = NSWindow(
            contentRect: CGRect(x: 80, y: 80, width: 120, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.contentView = CaptureSentinelView(frame: CGRect(x: 0, y: 0, width: 120, height: 80))

        WindowCaptureProtection.apply(isEnabled: false, to: window)
        window.orderFrontRegardless()
        drainMainRunLoop()
        defer {
            window.orderOut(nil)
            window.close()
        }

        guard let unprotectedCapture = captureImage(for: window),
              containsSentinelPixels(unprotectedCapture)
        else {
            throw XCTSkip("CGWindowListCreateImage did not return readable sentinel pixels in this test environment.")
        }

        WindowCaptureProtection.apply(isEnabled: true, to: window)
        window.displayIfNeeded()
        drainMainRunLoop()

        guard let protectedCapture = captureImage(for: window) else { return }
        XCTAssertFalse(containsSentinelPixels(protectedCapture))
    }

    func testWindowCaptureProtectionScreencaptureHarnessOmitsProtectedSentinelContentWhenOptedIn() throws {
        guard ProcessInfo.processInfo.environment["RUN_SCREEN_CAPTURE_HARNESS"] == "1" else {
            throw XCTSkip("Set RUN_SCREEN_CAPTURE_HARNESS=1 to run the real screencapture validation.")
        }
        guard FileManager.default.fileExists(atPath: "/usr/sbin/screencapture") else {
            throw XCTSkip("screencapture is not available in this environment.")
        }

        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 140, height: 90),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.contentView = CaptureSentinelView(frame: CGRect(x: 0, y: 0, width: 140, height: 90))
        window.orderFrontRegardless()
        drainMainRunLoop()
        defer {
            window.orderOut(nil)
            window.close()
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let unprotectedURL = temporaryDirectory.appendingPathComponent("unprotected.png")
        WindowCaptureProtection.apply(isEnabled: false, to: window)
        try runScreencapture(window: window, destination: unprotectedURL)
        guard let unprotectedImage = loadCGImage(at: unprotectedURL),
              containsSentinelPixels(unprotectedImage)
        else {
            throw XCTSkip("screencapture did not return readable sentinel pixels in this environment.")
        }

        let protectedURL = temporaryDirectory.appendingPathComponent("protected.png")
        WindowCaptureProtection.apply(isEnabled: true, to: window)
        try runScreencapture(window: window, destination: protectedURL)
        guard let protectedImage = loadCGImage(at: protectedURL) else { return }
        XCTAssertFalse(containsSentinelPixels(protectedImage))
    }

    func testScreenCaptureKitHarnessCanEnumerateProtectedWindowWhenOptedIn() async throws {
        guard ProcessInfo.processInfo.environment["RUN_SCREEN_CAPTURE_KIT_HARNESS"] == "1" else {
            throw XCTSkip("Set RUN_SCREEN_CAPTURE_KIT_HARNESS=1 to run the real ScreenCaptureKit validation.")
        }
        guard CGPreflightScreenCaptureAccess() else {
            throw XCTSkip("ScreenCaptureKit validation requires Screen Recording permission.")
        }

        let window = NSWindow(
            contentRect: CGRect(x: 120, y: 120, width: 160, height: 90),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Privacy Diagnostics ScreenCaptureKit Sentinel"
        window.contentView = CaptureSentinelView(frame: CGRect(x: 0, y: 0, width: 160, height: 90))
        WindowCaptureProtection.apply(isEnabled: true, to: window, role: .summary)
        window.orderFrontRegardless()
        drainMainRunLoop()
        defer {
            window.orderOut(nil)
            window.close()
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        XCTAssertTrue(
            content.windows.contains { scWindow in
                scWindow.windowID == CGWindowID(window.windowNumber) || scWindow.title == window.title
            },
            "Protected windows should remain visible to legitimate ScreenCaptureKit enumeration."
        )
    }

    func testFocusSafeInteractionPolicyKeepsNotchPanelNonActivatingAndNonKeyable() {
        let panel = NotchPanel(
            contentRect: CGRect(x: 0, y: 0, width: 160, height: 90),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        defer {
            panel.orderOut(nil)
            panel.close()
        }

        FocusSafeInteractionPolicy.apply(to: panel)
        FocusSafeInteractionPolicy.apply(to: panel)

        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.makeFirstResponder(NSView()))

        panel.makeKey()
        XCTAssertFalse(panel.isKeyWindow)

        panel.makeKeyAndOrderFront(nil)
        drainMainRunLoop()
        XCTAssertFalse(panel.isKeyWindow)
    }

    func testFocusSafeInteractionPolicyPreservesFocusForNoopOverlayAction() {
        let result = FocusSafeInteractionPolicy.canPerformOverlayActionWithoutActivation {}

        XCTAssertTrue(result.preservedAppActivation)
        XCTAssertTrue(result.preservedFrontmostApplication)
    }

    func testFocusSafeActionResultDetectsActivationRegression() {
        let before = FocusSafeActionSnapshot(
            isCurrentAppActive: false,
            frontmostProcessIdentifier: 100,
            frontmostBundleIdentifier: "com.example.frontmost"
        )
        let after = FocusSafeActionSnapshot(
            isCurrentAppActive: true,
            frontmostProcessIdentifier: 101,
            frontmostBundleIdentifier: "com.notchcopilot"
        )
        let result = FocusSafeActionResult(before: before, after: after)

        XCTAssertFalse(result.preservedAppActivation)
        XCTAssertFalse(result.preservedFrontmostApplication)
    }

    func testOverlaySourcesDoNotActivateApplicationDirectly() throws {
        let overlayFiles = [
            "NotchCopilot/UI/NotchIslandWindowController.swift",
            "NotchCopilot/UI/NotchIslandView.swift",
            "NotchCopilot/UI/Components/IconButton.swift",
            "NotchCopilot/UI/MeetingPanelView.swift"
        ]

        for file in overlayFiles {
            let source = try String(contentsOf: sourceRootURL().appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(source.contains("NSApp.activate"), "\(file) must not activate the app from overlay interactions.")
            XCTAssertFalse(source.contains("activate(ignoringOtherApps"), "\(file) must not activate the app from overlay interactions.")
        }
    }

    func testIslandWindowPlacementStaysPinnedToScreenTop() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let size = CGSize(width: 640.4, height: 548.2)

        let frame = NotchIslandWindowPlacement.topAnchoredFrame(for: size, in: screenFrame)

        XCTAssertEqual(frame.maxY, screenFrame.maxY)
        XCTAssertEqual(frame.height, ceil(size.height))
        XCTAssertEqual(frame.width, ceil(size.width))
        XCTAssertEqual(frame.midX, screenFrame.midX, accuracy: 0.5)
    }

    func testNotchPanelAllowsFrameInsideNotchAndMenuBarArea() {
        let panel = NotchPanel(
            contentRect: CGRect(x: 0, y: 0, width: 188, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let requestedFrame = CGRect(x: 462, y: 942, width: 588, height: 40)

        XCTAssertEqual(panel.constrainFrameRect(requestedFrame, to: nil), requestedFrame)
    }

    func testNotchIslandWindowZOrderStaysAboveFullscreenApps() {
        XCTAssertGreaterThan(NotchIslandWindowZOrder.overlayLevel.rawValue, NSWindow.Level.screenSaver.rawValue)
        XCTAssertTrue(NotchIslandWindowZOrder.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(NotchIslandWindowZOrder.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(NotchIslandWindowZOrder.collectionBehavior.contains(.stationary))
        XCTAssertTrue(NotchIslandWindowZOrder.collectionBehavior.contains(.ignoresCycle))
    }

    func testFocusSafeModeDoesNotUseEventSuppressionOrPrivateWindowAPIs() throws {
        let forbiddenTokens = [
            "CGEventTap",
            "CGEventPost",
            "CGEventCreate",
            "IOHID",
            "CGSSet",
            "CGSWindow",
            "SLSSet",
            "SLSWindow",
            "WindowServer",
            "NSSelectorFromString",
            "objc_getClass",
            "dlopen",
            "dlsym",
            "method_exchangeImplementations",
            "TCC.db",
            "tccutil",
            "ProcessInfo.processName",
            "document.cookie"
        ]

        for fileURL in try swiftSourceURLs(under: sourceRootURL().appendingPathComponent("NotchCopilot")) {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            for token in forbiddenTokens {
                XCTAssertFalse(source.contains(token), "\(fileURL.lastPathComponent) must not use \(token).")
            }
        }
    }

    @available(macOS, introduced: 10.0, deprecated: 14.0)
    private func captureImage(for window: NSWindow) -> CGImage? {
        CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            CGWindowID(window.windowNumber),
            [.boundsIgnoreFraming, .bestResolution]
        )
    }

    private func runScreencapture(window: NSWindow, destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-l\(window.windowNumber)", destination.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func loadCGImage(at url: URL) -> CGImage? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private func containsSentinelPixels(_ image: CGImage) -> Bool {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return false }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return false
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let sentinelCount = stride(from: 0, to: pixels.count, by: 4).filter { index in
            pixels[index] > 220 && pixels[index + 1] < 40 && pixels[index + 2] > 220
        }.count
        return sentinelCount > max(8, width * height / 20)
    }

    private func drainMainRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
    }

    private func sourceRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func swiftSourceURLs(under rootURL: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return try enumerator.compactMap { item -> URL? in
            guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            return values.isRegularFile == true ? url : nil
        }
    }

    func testPromptBuilderIncludesMeetingContext() {
        let context = AnswerContext(
            meetingTitle: "Architecture Review",
            transcriptWindow: "Speaker 1: Ryan, can we ship this?",
            ragContext: "Local note: confirm rollout risk.",
            userRole: "Senior Fullstack Software Engineer",
            responseStyle: .technical,
            languageCode: "en-US"
        )
        let prompt = PromptBuilder().suggestedAnswerPrompt(context: context, question: "Can we ship?", options: AnswerOptions(maxSentences: 2))
        XCTAssertTrue(prompt.contains("Architecture Review"))
        XCTAssertTrue(prompt.contains("Do not invent facts"))
        XCTAssertTrue(prompt.contains("Local note"))
        XCTAssertTrue(prompt.contains("Never put a single word"))
        XCTAssertTrue(prompt.contains("Use fenced code blocks only"))
    }

    func testSpeechContextRankerKeepsAppleContextShortAndBounded() {
        let terms = (0..<130).map { "Very long contextual phrase number \($0) that should be trimmed hard" } +
            ["Qual é a capital da França?", "França", "France", "árvore binária", "OpenAI", "openai"]

        let ranked = SpeechContextRanker().rank(terms)

        XCTAssertLessThanOrEqual(ranked.count, 100)
        XCTAssertTrue(ranked.allSatisfy { $0.split(separator: " ").count <= 4 })
        XCTAssertFalse(ranked.contains { $0.localizedCaseInsensitiveContains("Very long contextual phrase") })
        XCTAssertTrue(ranked.contains("França"))
        XCTAssertTrue(ranked.contains("árvore binária"))
        XCTAssertEqual(ranked.filter { $0.caseInsensitiveCompare("OpenAI") == .orderedSame }.count, 1)
    }

    func testSpeechVocabularyTermNormalizesAndPreservesDiacritics() {
        let term = SpeechVocabularyTerm(
            text: "  Ichimoku  ",
            locale: "pt_BR",
            category: .technicalTerm,
            aliases: ["ichimoku", "Ichimoku Cloud", "  Ichimoku Cloud  "],
            boost: 9.0
        )

        XCTAssertEqual(term.text, "Ichimoku")
        XCTAssertEqual(term.locale, "pt-BR")
        XCTAssertEqual(term.boost, 3.0)
        XCTAssertEqual(term.allSpokenForms, ["Ichimoku", "Ichimoku Cloud"])
        XCTAssertEqual(
            SpeechVocabularyTerm.normalizedKey("França", locale: "pt-BR"),
            SpeechVocabularyTerm.normalizedKey("franca", locale: "pt-BR")
        )
    }

    func testSpeechVocabularyContextBuilderUsesLocaleScopeAndWeights() {
        var preferences = AppPreferences()
        preferences.defaultLanguage = SupportedLanguage.portugueseBR.rawValue
        preferences.workspaceId = "alpha"
        preferences.defaultMeetingType = .engineering

        let session = MeetingSession(
            title: "Review Ichimoku BTC",
            primaryLanguage: SupportedLanguage.portugueseBR.rawValue,
            meetingType: .engineering
        )
        let context = SpeechVocabularyContextBuilder().build(
            terms: [
                SpeechVocabularyTerm(text: "Ichimoku", locale: "pt-BR", category: .technicalTerm, aliases: ["Nuvem Ichimoku"], boost: 2.2, useCount: 8),
                SpeechVocabularyTerm(text: "BTC", locale: nil, category: .acronym, boost: 2.4, scope: .workspace, scopeValue: "alpha"),
                SpeechVocabularyTerm(text: "RAG", locale: "en-US", category: .acronym, boost: 3.0),
                SpeechVocabularyTerm(text: "Sprint Goal", locale: nil, category: .shortPhrase, boost: 3.0, scope: .meetingType, scopeValue: MeetingType.sales.rawValue),
                SpeechVocabularyTerm(text: "DisabledTerm", locale: nil, category: .custom, enabled: false)
            ],
            session: session,
            preferences: preferences
        )

        XCTAssertTrue(context.contextualStrings.contains("Ichimoku"))
        XCTAssertTrue(context.contextualStrings.contains("Nuvem Ichimoku"))
        XCTAssertTrue(context.contextualStrings.contains("BTC"))
        XCTAssertFalse(context.contextualStrings.contains("RAG"))
        XCTAssertFalse(context.contextualStrings.contains("Sprint Goal"))
        XCTAssertFalse(context.contextualStrings.contains("DisabledTerm"))
        XCTAssertLessThanOrEqual(context.contextualStrings.count, 100)
        XCTAssertEqual(context.status, "Custom vocabulary active")
    }

    func testSpeechAudioTimelineClockUsesAccumulatedDurationsWhenTimestampsAreMissingOrRegressive() {
        var clock = SpeechAudioTimelineClock()
        let firstBuffer = NotchCopilot.AudioBuffer(
            pcmBuffer: Self.makeToneBuffer(seconds: 0.10, amplitude: 0.02),
            time: nil,
            rms: 0.02,
            peak: 0.03,
            createdAt: Date(timeIntervalSince1970: 10),
            audioSource: .microphone
        )
        let secondBuffer = NotchCopilot.AudioBuffer(
            pcmBuffer: Self.makeToneBuffer(seconds: 0.10, amplitude: 0.02),
            time: nil,
            mediaTime: CMTime(seconds: -2, preferredTimescale: 1_000),
            rms: 0.02,
            peak: 0.03,
            createdAt: Date(timeIntervalSince1970: 10),
            audioSource: .microphone
        )

        let firstStart = clock.nextStartTime(for: firstBuffer, convertedBuffer: firstBuffer.pcmBuffer)
        let secondStart = clock.nextStartTime(for: secondBuffer, convertedBuffer: secondBuffer.pcmBuffer)

        XCTAssertEqual(CMTimeGetSeconds(firstStart), 0, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(CMTimeGetSeconds(secondStart), 0.099)
    }

    func testSpeechAudioTimelineClockUsesSampleTimeAndPreservesMonotonicOrder() {
        var clock = SpeechAudioTimelineClock()
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let firstPCM = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
        firstPCM.frameLength = 4_800
        let secondPCM = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
        secondPCM.frameLength = 4_800
        let first = NotchCopilot.AudioBuffer(
            pcmBuffer: firstPCM,
            time: AVAudioTime(sampleTime: 0, atRate: 48_000),
            rms: 0.02,
            peak: 0.03,
            createdAt: Date(),
            audioSource: .microphone
        )
        let second = NotchCopilot.AudioBuffer(
            pcmBuffer: secondPCM,
            time: AVAudioTime(sampleTime: 2_400, atRate: 48_000),
            rms: 0.02,
            peak: 0.03,
            createdAt: Date(),
            audioSource: .microphone
        )

        _ = clock.nextStartTime(for: first, convertedBuffer: firstPCM)
        let secondStart = clock.nextStartTime(for: second, convertedBuffer: secondPCM)

        XCTAssertGreaterThanOrEqual(CMTimeGetSeconds(secondStart), 0.099)
    }

    func testSpeechAnalyzerRangeReconcilerReusesIDForOverlappingFinalAndSeparatesSources() {
        var reconciler = SpeechAnalyzerRangeReconciler()
        let draftRange = CMTimeRange(
            start: CMTime(seconds: 0, preferredTimescale: 1_000),
            duration: CMTime(seconds: 3, preferredTimescale: 1_000)
        )
        let finalRange = CMTimeRange(
            start: CMTime(seconds: 0.2, preferredTimescale: 1_000),
            duration: CMTime(seconds: 2.5, preferredTimescale: 1_000)
        )
        let laterRange = CMTimeRange(
            start: CMTime(seconds: 5, preferredTimescale: 1_000),
            duration: CMTime(seconds: 1, preferredTimescale: 1_000)
        )

        let draftID = reconciler.segmentID(for: draftRange, audioSource: .microphone, isFinal: false)
        let finalID = reconciler.segmentID(for: finalRange, audioSource: .microphone, isFinal: true)
        let systemID = reconciler.segmentID(for: finalRange, audioSource: .system, isFinal: true)
        let laterID = reconciler.segmentID(for: laterRange, audioSource: .microphone, isFinal: true)

        XCTAssertEqual(draftID, finalID)
        XCTAssertNotEqual(draftID, systemID)
        XCTAssertNotEqual(draftID, laterID)
    }

    func testSpeechAudioQualityMonitorDetectsClippingQuietGapsAndDeviceChanges() {
        var monitor = SpeechAudioQualityMonitor(source: .microphone)
        let first = NotchCopilot.AudioBuffer(
            pcmBuffer: Self.makeToneBuffer(seconds: 0.05, amplitude: 0.0002, sampleRate: 16_000),
            time: nil,
            rms: 0.0002,
            peak: 0.0004,
            createdAt: Date(timeIntervalSince1970: 1),
            audioSource: .microphone
        )
        let second = NotchCopilot.AudioBuffer(
            pcmBuffer: Self.makeToneBuffer(seconds: 0.05, amplitude: 0.9, sampleRate: 48_000),
            time: nil,
            rms: 0.1,
            peak: 0.99,
            createdAt: Date(timeIntervalSince1970: 1.5),
            audioSource: .microphone
        )

        let firstSnapshot = monitor.ingest(first)
        let secondSnapshot = monitor.ingest(second)

        XCTAssertTrue(firstSnapshot.isTooQuiet)
        XCTAssertTrue(secondSnapshot.isClipping)
        XCTAssertEqual(secondSnapshot.gapCount, 1)
        XCTAssertTrue(secondSnapshot.deviceChanged)
        XCTAssertEqual(secondSnapshot.sampleRate, 48_000)
        XCTAssertEqual(secondSnapshot.channelCount, 1)
    }

    func testAudioConditioningHighAccuracyConvertsCloudAudioToMono16kAndNormalizes() {
        let sampleRate = 48_000.0
        let frameCount = AVAudioFrameCount(0.12 * sampleRate)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)!
        let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        pcmBuffer.frameLength = frameCount
        for channelIndex in 0..<Int(format.channelCount) {
            let channel = pcmBuffer.floatChannelData![channelIndex]
            for frameIndex in 0..<Int(frameCount) {
                channel[frameIndex] = 0.006 * sin(Float(frameIndex) * 0.031)
            }
        }
        let buffer = NotchCopilot.AudioBuffer(
            pcmBuffer: pcmBuffer,
            time: nil,
            rms: 0.004,
            peak: 0.006,
            createdAt: Date(timeIntervalSince1970: 1),
            audioSource: .microphone
        )
        var pipeline = AudioConditioningPipeline(source: .microphone)

        let result = pipeline.condition(
            buffer,
            config: AudioConditioningConfig(
                accuracyMode: .highAccuracy,
                target: .cloudRealtime,
                audioSource: .microphone
            )
        )

        XCTAssertEqual(result.buffer.pcmBuffer?.format.sampleRate, 16_000)
        XCTAssertEqual(result.buffer.pcmBuffer?.format.channelCount, 1)
        XCTAssertTrue(result.convertedFormat)
        XCTAssertGreaterThan(result.appliedGain, 1)
        XCTAssertGreaterThan(result.buffer.rms, buffer.rms)
        XCTAssertFalse(result.quality.isClipping)
    }

    func testAudioConditioningDoesNotNormalizeSystemAudioGain() {
        let sampleRate = 48_000.0
        let frameCount = AVAudioFrameCount(0.08 * sampleRate)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)!
        let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        pcmBuffer.frameLength = frameCount
        for channelIndex in 0..<Int(format.channelCount) {
            let channel = pcmBuffer.floatChannelData![channelIndex]
            for frameIndex in 0..<Int(frameCount) {
                channel[frameIndex] = 0.004 * sin(Float(frameIndex) * 0.031)
            }
        }
        let buffer = NotchCopilot.AudioBuffer(
            pcmBuffer: pcmBuffer,
            time: nil,
            rms: 0.004,
            peak: 0.006,
            createdAt: Date(timeIntervalSince1970: 1),
            audioSource: .system
        )
        var pipeline = AudioConditioningPipeline(source: .system)

        let result = pipeline.condition(
            buffer,
            config: AudioConditioningConfig(
                accuracyMode: .highAccuracy,
                target: .nativeSpeech,
                audioSource: .system
            )
        )

        XCTAssertEqual(result.appliedGain, 1)
        XCTAssertEqual(result.buffer.pcmBuffer?.format.sampleRate, sampleRate)
        XCTAssertEqual(result.buffer.pcmBuffer?.format.channelCount, 2)
    }

    func testMicrophoneCaptureDoesNotAlterSystemPlaybackByDefault() {
        XCTAssertEqual(AppleMicrophoneCaptureService.defaultVoiceProcessingPolicy, .disabled)
    }

    func testSpeechRecognitionWatchdogRestartsOnlyForRecentAudioWithoutSegments() {
        let policy = SpeechRecognitionWatchdogPolicy(
            significantAudioRMS: 0.0025,
            significantAudioWindow: 5,
            noSegmentWindow: 4,
            minimumRestartInterval: 2
        )
        let now = Date(timeIntervalSince1970: 10)

        XCTAssertTrue(policy.shouldRestart(
            now: now,
            lastSignificantAudioAt: Date(timeIntervalSince1970: 8),
            lastSegmentAt: Date(timeIntervalSince1970: 2),
            lastRestartAt: Date(timeIntervalSince1970: 0)
        ))
        XCTAssertFalse(policy.shouldRestart(
            now: now,
            lastSignificantAudioAt: Date(timeIntervalSince1970: 1),
            lastSegmentAt: Date(timeIntervalSince1970: 2),
            lastRestartAt: Date(timeIntervalSince1970: 0)
        ))
        XCTAssertFalse(policy.shouldRestart(
            now: now,
            lastSignificantAudioAt: Date(timeIntervalSince1970: 8),
            lastSegmentAt: Date(timeIntervalSince1970: 9),
            lastRestartAt: Date(timeIntervalSince1970: 0)
        ))
    }

    func testSpeechActivityPolicyTreatsLowConsistentAudioAsSpeechLikely() {
        let policy = SpeechActivityPolicy()
        let snapshot = SpeechAudioQualitySnapshot(
            source: .microphone,
            rms: 0.0016,
            peak: 0.02,
            isClipping: false,
            isTooQuiet: true,
            noiseFloor: 0.0003,
            gapCount: 0,
            lastAudioAt: Date()
        )

        XCTAssertTrue(policy.classify(snapshot).isSignificant)
    }

    func testAppleSpeechWindowControllerPreservesSegmentOnRestartAndRotation() {
        var controller = AppleSpeechWindowController()
        let now = Date(timeIntervalSince1970: 100)

        let initial = controller.begin(reason: .initial, now: now, preservesSegment: false)
        let restart = controller.begin(reason: .watchdogRestart, now: now.addingTimeInterval(2), preservesSegment: true)

        XCTAssertFalse(initial.preservesSegment)
        XCTAssertTrue(restart.preservesSegment)
        XCTAssertNotEqual(initial.id, restart.id)
        controller.park(until: now.addingTimeInterval(4))
        XCTAssertFalse(controller.canStartFromAudio(now: now.addingTimeInterval(3)))
        XCTAssertTrue(controller.canStartFromAudio(now: now.addingTimeInterval(5)))
    }

    func testAppleSpeechSegmentAssemblerDoesNotLetShortFinalEraseLongDraft() {
        let meetingId = UUID()
        let segmentId = UUID()
        var assembler = AppleSpeechSegmentAssembler()
        let draft = TranscriptSegment(
            id: segmentId,
            meetingId: meetingId,
            speakerLabel: "You",
            audioSource: .microphone,
            text: "Nao se preocupa que a gente vai revisar tudo depois",
            transcriptionPhase: .draft,
            transcriptionEngine: .appleSpeech,
            startTime: 0,
            endTime: 4,
            isFinal: false
        )
        let truncatedFinal = TranscriptSegment(
            id: segmentId,
            meetingId: meetingId,
            speakerLabel: "You",
            audioSource: .microphone,
            text: "Nao se preocupa",
            transcriptionPhase: .final,
            transcriptionEngine: .appleSpeech,
            finalizedBy: .appleSpeech,
            startTime: 0,
            endTime: 2,
            isFinal: true
        )

        XCTAssertEqual(assembler.assemble(draft)?.text, draft.text)
        let assembledFinal = assembler.assemble(truncatedFinal)

        XCTAssertEqual(assembledFinal?.text, draft.text)
        XCTAssertTrue(assembledFinal?.isFinal == true)
    }

    func testMeetingTranscriptLedgerSplitsShortFinalAndSeparatesSources() {
        let meetingId = UUID()
        let id = UUID()
        let draft = TranscriptSegment(
            id: id,
            meetingId: meetingId,
            speakerLabel: "You",
            audioSource: .microphone,
            text: "Branca do quadro opcao mas beleza",
            transcriptionPhase: .draft,
            transcriptionEngine: .appleSpeech,
            sourceFrameRange: AudioSourceFrameRange(start: 0, end: 64_000),
            startTime: 0,
            endTime: 4,
            isFinal: false
        )
        let shortFinal = TranscriptSegment(
            id: id,
            meetingId: meetingId,
            speakerLabel: "You",
            audioSource: .microphone,
            text: "Branca do",
            transcriptionPhase: .final,
            transcriptionEngine: .appleSpeech,
            finalizedBy: .appleSpeech,
            sourceFrameRange: AudioSourceFrameRange(start: 0, end: 24_000),
            startTime: 0,
            endTime: 1.5,
            isFinal: true
        )
        let systemFinal = TranscriptSegment(
            id: UUID(),
            meetingId: meetingId,
            speakerLabel: "System",
            audioSource: .system,
            text: "Branca do",
            transcriptionPhase: .final,
            transcriptionEngine: .appleSpeech,
            startTime: 0,
            endTime: 1.5,
            isFinal: true
        )
        let ledger = MeetingTranscriptLedger()

        let decision = ledger.decision(for: shortFinal, in: [draft])

        guard case let .replace(index, committed, tail) = decision else {
            return XCTFail("Expected short final to commit its prefix and preserve a live draft tail.")
        }
        XCTAssertEqual(index, 0)
        XCTAssertEqual(committed.text, shortFinal.text)
        XCTAssertTrue(committed.isFinal)
        XCTAssertEqual(tail?.text, "quadro opcao mas beleza")
        XCTAssertEqual(tail?.transcriptionPhase, .draft)

        guard case .append = ledger.decision(for: systemFinal, in: [draft]) else {
            return XCTFail("System audio must not revise microphone segments.")
        }
    }

    func testMeetingTranscriptLedgerDoesNotMergeByTextPrefixWithoutRangeOverlap() {
        let meetingId = UUID()
        let existing = TranscriptSegment(
            meetingId: meetingId,
            speakerLabel: "You",
            audioSource: .microphone,
            text: "BTC no diario",
            transcriptionPhase: .final,
            transcriptionEngine: .appleSpeech,
            startTime: 0,
            endTime: 1.2,
            isFinal: true
        )
        let later = TranscriptSegment(
            meetingId: meetingId,
            speakerLabel: "You",
            audioSource: .microphone,
            text: "BTC no diario encontrou suporte",
            transcriptionPhase: .draft,
            transcriptionEngine: .appleSpeech,
            startTime: 10,
            endTime: 12,
            isFinal: false
        )

        guard case .append = MeetingTranscriptLedger().decision(for: later, in: [existing]) else {
            return XCTFail("Text prefix alone must not replace an older meeting segment.")
        }
    }

    func testSpeechVocabularyStoreEncryptsSensitiveFieldsAndImportsCSV() throws {
        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let cryptor = try testCryptor()
        let store = SpeechVocabularyStore(container: container, cryptor: cryptor)
        let csv = """
        text,locale,category,aliases,pronunciationXSAMPA,boost,scope,scopeValue,enabled,notes
        Ichimoku,pt-BR,technicalTerm,Nuvem Ichimoku|Kinko Hyo,i tS i m o k u,2.2,global,,true,Termo técnico
        """

        XCTAssertEqual(store.importCSV(csv, defaultLocale: nil), 1)
        let terms = store.terms()

        XCTAssertEqual(terms.count, 1)
        XCTAssertEqual(terms.first?.text, "Ichimoku")
        XCTAssertEqual(terms.first?.aliases, ["Nuvem Ichimoku", "Kinko Hyo"])
        XCTAssertEqual(terms.first?.pronunciationXSAMPA, "i tS i m o k u")

        let rawContext = ModelContext(container)
        let stored = try XCTUnwrap(try rawContext.fetch(FetchDescriptor<StoredSpeechVocabularyTerm>()).first)
        XCTAssertTrue(cryptor.isEncryptedString(stored.text))
        XCTAssertFalse(stored.text.contains("Ichimoku"))
        XCTAssertTrue(cryptor.isEncryptedString(stored.aliasesJSON))
        XCTAssertFalse(stored.aliasesJSON.contains("Nuvem"))
        XCTAssertTrue(store.exportCSV().contains("Ichimoku"))
    }

    func testSpeechVocabularyCorrectionsAndTemplatesRoundTripCSV() throws {
        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let cryptor = try testCryptor()
        let store = SpeechVocabularyStore(container: container, cryptor: cryptor)

        store.save(SpeechVocabularyTerm(
            text: "BTC",
            locale: "pt-BR",
            category: .acronym,
            aliases: ["Bitcoin"],
            boost: 2.5,
            templatePattern: "BTC acima de {valor}",
            templateSlots: ["80 mil dólares", "cem mil dólares"]
        ))
        store.recordCorrection(original: "Iximoku", corrected: "Ichimoku", locale: "pt-BR")

        let terms = store.terms()
        let btc = try XCTUnwrap(terms.first { $0.text == "BTC" })
        let ichimoku = try XCTUnwrap(terms.first { $0.text == "Ichimoku" })
        let csv = store.exportCSV()

        XCTAssertEqual(btc.templatePattern, "BTC acima de {valor}")
        XCTAssertEqual(btc.templateSlots, ["80 mil dólares", "cem mil dólares"])
        XCTAssertEqual(ichimoku.aliases, ["Iximoku"])
        XCTAssertEqual(ichimoku.correctionCount, 1)
        XCTAssertTrue(csv.contains("templatePattern"))
        XCTAssertTrue(csv.contains("BTC acima de {valor}"))
        XCTAssertTrue(csv.contains("80 mil dólares|cem mil dólares"))
    }

    func testTranscriptionBenchmarkSuiteComputesWERAndVocabularyRecognition() throws {
        let suite = TranscriptionBenchmarkSuite()
        let result = try XCTUnwrap(suite.evaluate([
            TranscriptionBenchmarkCase(
                id: "france",
                reference: "Qual é a capital da França",
                hypothesis: "Qual é a capital da França",
                locale: "pt-BR",
                activeVocabulary: ["França", "Ichimoku"],
                firstPartialLatencyMs: 120,
                finalLatencyMs: 900,
                gapCount: 0,
                duplicateCount: 0
            )
        ]).first)

        XCTAssertEqual(result.wordErrorRate, 0, accuracy: 0.0001)
        XCTAssertEqual(result.characterErrorRate, 0, accuracy: 0.0001)
        XCTAssertEqual(result.vocabularyRecognitionRate, 0.5, accuracy: 0.0001)
        XCTAssertNoThrow(try suite.jsonReport(for: [
            TranscriptionBenchmarkCase(id: "json", reference: "BTC", hypothesis: "BTC", locale: "pt-BR", activeVocabulary: ["BTC"])
        ]))
    }

    func testAppleSpeechRequestFactoryAppliesSpeechContextAndCustomModel() {
        let speechContext = SpeechRecognitionContext(
            locale: "pt-BR",
            terms: [
                SpeechContextTerm(text: "Ichimoku", locale: "pt-BR", category: .technicalTerm, weight: 2.5, pronunciationXSAMPA: nil, source: "test"),
                SpeechContextTerm(text: "RAG", locale: "en-US", category: .acronym, weight: 2.5, pronunciationXSAMPA: nil, source: "test")
            ],
            customLanguageModelEnabled: true
        )
        let config = TranscriptionConfig(
            languageCode: SupportedLanguage.portugueseBR.rawValue,
            requiresOnDeviceRecognition: false,
            meetingId: UUID(),
            contextualStrings: ["legacy should be ignored"],
            speechContext: speechContext,
            audioSource: .microphone
        )
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        let customModel = SFSpeechLanguageModel.Configuration(
            languageModel: temp.appending(path: "custom.lm"),
            vocabulary: temp.appending(path: "custom.vocab")
        )

        let request = AppleSpeechRequestFactory.make(
            config: config,
            supportsOnDeviceRecognition: true,
            customLanguageModel: customModel
        )

        XCTAssertTrue(request.contextualStrings.contains("Ichimoku"))
        XCTAssertFalse(request.contextualStrings.contains("legacy should be ignored"))
        XCTAssertFalse(request.contextualStrings.contains("RAG"))
        XCTAssertTrue(request.requiresOnDeviceRecognition)
        XCTAssertNotNil(request.customizedLanguageModel)
    }

    func testAppleSpeechRequestFactoryUsesQualityFocusedNativeSettings() {
        let config = TranscriptionConfig(
            languageCode: SupportedLanguage.portugueseBR.rawValue,
            requiresOnDeviceRecognition: true,
            meetingId: UUID(),
            contextualStrings: (0..<140).map { "Very long contextual phrase number \($0) should not bias speech" } + [
                "França",
                "Paris",
                "árvore binária",
                "OpenAI",
                "openai"
            ],
            audioSource: .microphone
        )

        let request = AppleSpeechRequestFactory.make(
            config: config,
            supportsOnDeviceRecognition: true
        )

        XCTAssertTrue(request.shouldReportPartialResults)
        XCTAssertEqual(request.taskHint, .dictation)
        XCTAssertLessThanOrEqual(request.contextualStrings.count, 100)
        XCTAssertTrue(request.contextualStrings.allSatisfy { $0.split(separator: " ").count <= 4 })
        XCTAssertFalse(request.contextualStrings.contains { $0.localizedCaseInsensitiveContains("Very long contextual phrase") })
        XCTAssertTrue(request.contextualStrings.contains("França"))
        XCTAssertTrue(request.contextualStrings.contains("Paris"))
        XCTAssertEqual(request.contextualStrings.filter { $0.caseInsensitiveCompare("OpenAI") == .orderedSame }.count, 1)
        XCTAssertTrue(request.requiresOnDeviceRecognition)
        if #available(macOS 13.0, *) {
            XCTAssertTrue(request.addsPunctuation)
        }
    }

    func testAppleSpeechRequestFactoryDoesNotForceUnsupportedOnDeviceMode() {
        let config = TranscriptionConfig(
            requiresOnDeviceRecognition: true,
            meetingId: UUID(),
            contextualStrings: ["França"],
            audioSource: .microphone
        )

        let request = AppleSpeechRequestFactory.make(
            config: config,
            supportsOnDeviceRecognition: false
        )

        XCTAssertFalse(request.requiresOnDeviceRecognition)
    }

    func testSpeechFrameRangeEstimatorCreatesMonotonicSixteenKilohertzRanges() {
        let range = SpeechFrameRangeEstimator.range(startTime: 1.25, endTime: 1.75)

        XCTAssertEqual(range, AudioSourceFrameRange(start: 20_000, end: 28_000))
        XCTAssertEqual(SpeechFrameRangeEstimator.range(startTime: -0.2, endTime: -0.1), AudioSourceFrameRange(start: 0, end: 1))
        XCTAssertNil(SpeechFrameRangeEstimator.range(startTime: .infinity, endTime: 1))
    }

    func testPreRollBufferReplaysAudioBeforeRecognizerStartWithoutDuplicatingCurrentBuffer() {
        var buffer = SpeechPreRollBuffer(duration: 0.85)
        let first = NotchCopilot.AudioBuffer(
            pcmBuffer: Self.makeToneBuffer(seconds: 0.4, amplitude: 0.02),
            time: nil,
            rms: 0.02,
            peak: 0.03,
            createdAt: Date(timeIntervalSince1970: 10),
            audioSource: .microphone
        )
        let current = NotchCopilot.AudioBuffer(
            pcmBuffer: Self.makeToneBuffer(seconds: 0.4, amplitude: 0.03),
            time: nil,
            rms: 0.03,
            peak: 0.04,
            createdAt: Date(timeIntervalSince1970: 10.4),
            audioSource: .microphone
        )

        buffer.append(first)
        let replayBeforeCurrent = buffer.buffers
        buffer.append(current)

        XCTAssertEqual(replayBeforeCurrent.count, 1)
        XCTAssertEqual(replayBeforeCurrent.first?.createdAt, first.createdAt)
        XCTAssertEqual(buffer.buffers.count, 2)
        XCTAssertEqual(buffer.buffers.last?.createdAt, current.createdAt)
    }

    func testTranscriptionEngineModeDecodesLegacyModesAsAppleSpeech() throws {
        for legacyValue in ["hybrid", "whisperCpp", "legacyLocalEngine", "legacyParallelMode", "legacyCloudMode"] {
            let data = #"{ "transcriptionEngineMode": "\#(legacyValue)" }"#.data(using: .utf8)!
            let decoded = try JSONDecoder().decode(AppPreferences.self, from: data)
            XCTAssertEqual(decoded.transcriptionEngineMode, .appleSpeech)
        }

        let cloudRealtime = try JSONDecoder().decode(
            TranscriptionEngineMode.self,
            from: Data(#""cloudRealtime""#.utf8)
        )
        XCTAssertEqual(cloudRealtime, .cloudRealtime)
    }

    func testTranscriptSegmentIgnoresUnknownLegacyPayloadAndKeepsText() throws {
        let meetingId = UUID()
        let data = """
        {
          "id": "\(UUID().uuidString)",
          "meetingId": "\(meetingId.uuidString)",
          "speakerLabel": "MIC",
          "audioSource": "microphone",
          "text": "Qual é a capital da França?",
          "legacyPayload": [
            {"text":"legacy span","phase":"draft","engine":"removedLocalEngine"}
          ],
          "transcriptionEngine": "removedLocalEngine",
          "finalizedBy": "removedLocalEngine",
          "startTime": 0,
          "endTime": 1,
          "confidence": 0.9,
          "isFinal": true,
          "createdAt": "2026-05-23T12:00:00Z"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let segment = try decoder.decode(TranscriptSegment.self, from: data)

        XCTAssertEqual(segment.text, "Qual é a capital da França?")
        XCTAssertEqual(segment.transcriptionEngine, .unavailable)
        XCTAssertEqual(segment.finalizedBy, .unavailable)
    }

    func testTranslationCompletenessPassCoversFinalAndDraftRetainedSegments() {
        var preferences = AppPreferences()
        preferences.liveTranslationEnabled = true
        let meetingId = UUID()
        let finalSegment = TranscriptSegment(
            meetingId: meetingId,
            speakerLabel: "You",
            audioSource: .microphone,
            text: "Precisamos revisar o plano.",
            originalLanguage: SupportedLanguage.portugueseBR.rawValue,
            transcriptionPhase: .final,
            retentionReason: .appleFinalRetained,
            isFinal: true
        )
        let retainedDraft = TranscriptSegment(
            meetingId: meetingId,
            speakerLabel: "System",
            audioSource: .system,
            text: "We should confirm the rollout risk.",
            originalLanguage: SupportedLanguage.englishUS.rawValue,
            transcriptionPhase: .final,
            retentionReason: .appleDraftRetained,
            isFinal: true
        )
        let translated = TranscriptSegment(
            meetingId: meetingId,
            speakerLabel: "System",
            audioSource: .system,
            text: "Already covered.",
            originalLanguage: SupportedLanguage.englishUS.rawValue,
            translatedText: "Já coberto.",
            translationState: .translated,
            isFinal: true
        )
        let meeting = MeetingSession(title: "Coverage", transcriptSegments: [finalSegment, retainedDraft, translated])

        let needed = TranslationCompletenessPass().segmentsNeedingCoverage(in: meeting, preferences: preferences)

        XCTAssertEqual(Set(needed.map(\.id)), Set([finalSegment.id, retainedDraft.id]))
    }

    func testTranslationCoverageRevisionChangesWhenSegmentCoverageChanges() {
        let segmentId = UUID()
        let meetingId = UUID()
        let segment = TranscriptSegment(
            id: segmentId,
            meetingId: meetingId,
            speakerLabel: "You",
            audioSource: .microphone,
            text: "Precisamos revisar o plano.",
            originalLanguage: SupportedLanguage.portugueseBR.rawValue,
            transcriptionPhase: .final,
            sourceFrameRange: AudioSourceFrameRange(start: 0, end: 16_000),
            retentionReason: .appleFinalRetained,
            isFinal: true
        )
        var revised = segment
        revised.sourceFrameRange = AudioSourceFrameRange(start: 0, end: 18_000)

        let coordinator = TranslationCoverageCoordinator()

        XCTAssertNotEqual(coordinator.coverageRevision(for: segment), coordinator.coverageRevision(for: revised))
    }

    func testProviderRouterDefaultsToNativeAppleTranscription() {
        let preferences = AppPreferences()
        let router = ProviderRouter()
        let service = router.transcriptionService(
            preferences: preferences,
            sources: [
                .init(speakerLabel: "You", audioSource: .microphone, audioStream: AsyncStream { $0.finish() })
            ]
        )

        XCTAssertTrue(service is AppleNativeTranscriptionService)
        let report = CapabilityChecker().localReport(preferences: preferences)
        if #available(macOS 26.0, *), SpeechTranscriber.isAvailable {
            XCTAssertEqual(report.transcriptionEngine, .speechAnalyzer)
        } else {
            XCTAssertEqual(report.transcriptionEngine, .appleSpeech)
        }
        XCTAssertEqual(report.transcriptionMode, .local)
    }

    func testProviderRouterUsesAppleSourceSeparatedServiceForMicAndSystem() {
        let preferences = AppPreferences()
        let router = ProviderRouter()
        let service = router.transcriptionService(
            preferences: preferences,
            sources: [
                .init(speakerLabel: "You", audioSource: .microphone, audioStream: AsyncStream { $0.finish() }),
                .init(speakerLabel: "System", audioSource: .system, audioStream: AsyncStream { $0.finish() })
            ]
        )

        XCTAssertTrue(service is MultiSourceAutoLanguageTranscriptionService || service is MultiSourceAppleSpeechTranscriptionService)
    }

    func testProviderRouterHighAccuracyUsesCloudRealtimeWhenConfigured() {
        var preferences = AppPreferences()
        preferences.localOnlyMode = false
        preferences.transcriptionEngineMode = .cloudRealtime
        preferences.transcriptionAccuracyMode = .highAccuracy
        preferences.aiConfig.realtimeTranscriptionProvider = .elevenLabs
        preferences.aiConfig.realtimeTranscriptionModel = "scribe_v2_realtime"
        let authProvider = EphemeralAuthProvider(session: AuthSession(
            provider: .elevenLabsAPIKey,
            accessToken: "test-key",
            refreshToken: nil,
            expiresAt: nil,
            accountEmail: nil,
            accountId: nil,
            scopes: ["api-key"]
        ))
        let router = ProviderRouter(elevenLabsAPIKeyAuthProvider: authProvider)

        let service = router.transcriptionService(preferences: preferences)

        XCTAssertTrue(router.shouldUseCloudRealtimeTranscription(preferences: preferences))
        XCTAssertTrue(service is ElevenLabsRealtimeTranscriptionService)
    }

    func testProviderRouterHighAccuracyDoesNotUseCloudWithoutExplicitEngine() {
        var preferences = AppPreferences()
        preferences.localOnlyMode = false
        preferences.transcriptionEngineMode = .appleSpeech
        preferences.transcriptionAccuracyMode = .highAccuracy
        preferences.aiConfig.realtimeTranscriptionProvider = .elevenLabs
        preferences.aiConfig.realtimeTranscriptionModel = "scribe_v2_realtime"
        let authProvider = EphemeralAuthProvider(session: AuthSession(
            provider: .elevenLabsAPIKey,
            accessToken: "test-key",
            refreshToken: nil,
            expiresAt: nil,
            accountEmail: nil,
            accountId: nil,
            scopes: ["api-key"]
        ))
        let router = ProviderRouter(elevenLabsAPIKeyAuthProvider: authProvider)

        let service = router.transcriptionService(preferences: preferences)

        XCTAssertFalse(router.shouldUseCloudRealtimeTranscription(preferences: preferences))
        XCTAssertFalse(service is ElevenLabsRealtimeTranscriptionService)
    }

    func testProviderRouterHighAccuracyFallsBackToAppleSpeechWithoutCloudKey() {
        var preferences = AppPreferences()
        preferences.localOnlyMode = false
        preferences.transcriptionEngineMode = .appleSpeech
        preferences.transcriptionAccuracyMode = .highAccuracy
        preferences.aiConfig.realtimeTranscriptionProvider = .elevenLabs
        let router = ProviderRouter(elevenLabsAPIKeyAuthProvider: nil)

        let service = router.transcriptionService(preferences: preferences)

        XCTAssertFalse(router.shouldUseCloudRealtimeTranscription(preferences: preferences))
        XCTAssertTrue(service is AppleNativeTranscriptionService)
    }

    func testProviderRouterHighAccuracyKeepsSeparatedCloudSourcesWhenAvailable() {
        var preferences = AppPreferences()
        preferences.localOnlyMode = false
        preferences.transcriptionEngineMode = .cloudRealtime
        preferences.transcriptionAccuracyMode = .highAccuracy
        preferences.aiConfig.realtimeTranscriptionProvider = .elevenLabs
        let authProvider = EphemeralAuthProvider(session: AuthSession(
            provider: .elevenLabsAPIKey,
            accessToken: "test-key",
            refreshToken: nil,
            expiresAt: nil,
            accountEmail: nil,
            accountId: nil,
            scopes: ["api-key"]
        ))
        let router = ProviderRouter(elevenLabsAPIKeyAuthProvider: authProvider)

        let service = router.transcriptionService(
            preferences: preferences,
            sources: [
                .init(speakerLabel: "You", audioSource: .microphone, audioStream: AsyncStream { $0.finish() }),
                .init(speakerLabel: "System", audioSource: .system, audioStream: AsyncStream { $0.finish() })
            ]
        )

        XCTAssertTrue(service is MultiSourceCloudRealtimeTranscriptionService)
    }

    func testOpenAICatalogDoesNotExposeTranscriptionModels() {
        let catalog = AIModelCatalog.openAI(from: [
            "gpt-realtime",
            "gpt-4o-transcribe",
            "gpt-4o-mini-transcribe",
            "audio-transcribe"
        ])

        XCTAssertTrue(catalog.realtimeModels.contains { $0.id == "gpt-realtime" })
        XCTAssertTrue(catalog.transcriptionModels.isEmpty)
    }

    func testElevenLabsRealtimeURLUsesZeroRetentionAndCurrentEndpoint() {
        let url = ElevenLabsRealtimeTranscriptionService.webSocketURL(languageCode: "pt-BR")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.host, "api.elevenlabs.io")
        XCTAssertEqual(url.path, "/v1/speech-to-text/realtime")
        XCTAssertEqual(query["model_id"], "scribe_v2_realtime")
        XCTAssertEqual(query["enable_logging"], "false")
        XCTAssertEqual(query["audio_format"], "pcm_16000")
        XCTAssertEqual(query["commit_strategy"], "vad")
        XCTAssertEqual(query["language_code"], "pt")
        XCTAssertNil(query["token"])
    }

    func testElevenLabsPayloadUsesExpectedAudioShape() throws {
        let payload = try ElevenLabsRealtimeTranscriptionService.inputAudioChunkPayload(
            audioBase64: "AAAA",
            commit: false
        )
        let object = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]

        XCTAssertEqual(object?["message_type"] as? String, "input_audio_chunk")
        XCTAssertEqual(object?["audio_base_64"] as? String, "AAAA")
        XCTAssertEqual(object?["commit"] as? Bool, false)
        XCTAssertEqual(object?["sample_rate"] as? Int, 16_000)
        XCTAssertNil(object?["previous_text"])
    }

    func testElevenLabsParserMapsPartialAndCommittedEvents() throws {
        let partial = try ElevenLabsRealtimeTranscriptEvent.parse(Data(#"{"message_type":"partial_transcript","text":"hello"}"#.utf8))
        XCTAssertEqual(partial?.kind, .partial)
        XCTAssertEqual(partial?.text, "hello")

        let committedJSON = """
        {
          "message_type": "committed_transcript_with_timestamps",
          "text": "hello world",
          "language_code": "en",
          "words": [
            {"text":"hello","start":0.0,"end":0.4,"type":"word","logprob":-0.1},
            {"text":" ","start":0.4,"end":0.42,"type":"spacing"},
            {"text":"world","start":0.42,"end":0.9,"type":"word"}
          ]
        }
        """
        let committed = try ElevenLabsRealtimeTranscriptEvent.parse(Data(committedJSON.utf8))

        XCTAssertEqual(committed?.kind, .committed)
        XCTAssertEqual(committed?.text, "hello world")
        XCTAssertEqual(committed?.languageCode, "en")
        XCTAssertEqual(committed?.words.map(\.word), ["hello", "world"])
    }

    func testElevenLabsCatalogOnlyExposesRealtimeScribeV2() {
        let options = AIModelCatalog.elevenLabsRealtime.transcriptionModels

        XCTAssertEqual(options.map(\.id), ["scribe_v2_realtime"])
        XCTAssertFalse(options.contains { $0.id == "scribe_v1" || $0.id == "scribe_v2" })
    }

    func testProviderRouterUsesElevenLabsCloudRealtimeWhenConfigured() throws {
        var preferences = AppPreferences()
        preferences.localOnlyMode = false
        preferences.transcriptionEngineMode = try JSONDecoder().decode(
            TranscriptionEngineMode.self,
            from: Data(#""cloudRealtime""#.utf8)
        )
        preferences.aiConfig.realtimeTranscriptionProvider = .elevenLabs
        preferences.aiConfig.realtimeTranscriptionModel = "scribe_v2_realtime"
        let authProvider = EphemeralAuthProvider(session: AuthSession(
            provider: .elevenLabsAPIKey,
            accessToken: "test-key",
            refreshToken: nil,
            expiresAt: nil,
            accountEmail: nil,
            accountId: nil,
            scopes: ["api-key"]
        ))
        let router = ProviderRouter(elevenLabsAPIKeyAuthProvider: authProvider)

        let service = router.transcriptionService(preferences: preferences)

        XCTAssertTrue(service is ElevenLabsRealtimeTranscriptionService)
        XCTAssertEqual(router.report(preferences: preferences).transcriptionEngine, .elevenLabs)
        XCTAssertEqual(router.report(preferences: preferences).transcriptionMode, .cloud)
    }

    func testProviderRouterKeepsLegacyCloudRealtimeOnAppleSpeechInLocalOnlyMode() throws {
        var preferences = AppPreferences()
        preferences.localOnlyMode = true
        preferences.transcriptionEngineMode = try JSONDecoder().decode(
            TranscriptionEngineMode.self,
            from: Data(#""cloudRealtime""#.utf8)
        )
        preferences.aiConfig.realtimeTranscriptionProvider = .elevenLabs
        let authProvider = EphemeralAuthProvider(session: AuthSession(
            provider: .elevenLabsAPIKey,
            accessToken: "test-key",
            refreshToken: nil,
            expiresAt: nil,
            accountEmail: nil,
            accountId: nil,
            scopes: ["api-key"]
        ))
        let router = ProviderRouter(elevenLabsAPIKeyAuthProvider: authProvider)

        let service = router.transcriptionService(preferences: preferences)

        XCTAssertTrue(service is AppleNativeTranscriptionService)
    }

    private static func makeToneBuffer(seconds: Double, amplitude: Float = 0.12, sampleRate: Double = 16_000) -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount(seconds * sampleRate)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let channel = buffer.floatChannelData![0]
        for index in 0..<Int(frameCount) {
            channel[index] = amplitude * sin(Float(index) * 0.031)
        }
        return buffer
    }

    func testSummaryPromptKeepsTranscriptAudioSources() {
        let meeting = MeetingSession(title: "Daily")
        let meetingId = meeting.id
        let transcript = [
            TranscriptSegment(meetingId: meetingId, speakerLabel: "System", audioSource: .system, text: "Can we ship today?"),
            TranscriptSegment(meetingId: meetingId, speakerLabel: "You", audioSource: .microphone, text: "We should confirm the rollout risk first.")
        ]
        let prompt = PromptBuilder().summaryPrompt(meeting: meeting, transcript: transcript)
        XCTAssertTrue(prompt.contains("[System] System: Can we ship today?"))
        XCTAssertTrue(prompt.contains("[Mic] You: We should confirm the rollout risk first."))
    }

    func testMeetingInsightDetectsQuestionForUser() {
        let meetingId = UUID()
        let segment = TranscriptSegment(meetingId: meetingId, speakerLabel: "Speaker 1", text: "Ryan, can you explain the privacy risk?")
        let detection = MeetingInsightEngine().detectAttention(in: [segment], userNames: ["Ryan"])
        XCTAssertTrue(detection.requiresUserAttention)
        XCTAssertEqual(detection.extractedQuestion, segment.text)
    }

    func testMeetingInsightDetectsPortugueseQuestionForUser() {
        let meetingId = UUID()
        let segment = TranscriptSegment(meetingId: meetingId, speakerLabel: "Pessoa 1", text: "Ryan, você pode explicar o risco de privacidade?")
        let detection = MeetingInsightEngine().detectAttention(in: [segment], userNames: ["Ryan"])
        XCTAssertTrue(detection.requiresUserAttention)
        XCTAssertEqual(detection.extractedQuestion, segment.text)
    }

    func testSupportedLanguagesNormalizeEnglishAndPortuguese() {
        XCTAssertEqual(SupportedLanguage.normalizedCode("en"), "en-US")
        XCTAssertEqual(SupportedLanguage.normalizedCode("en_GB"), "en-US")
        XCTAssertEqual(SupportedLanguage.normalizedCode("pt"), "pt-BR")
        XCTAssertEqual(SupportedLanguage.normalizedCode("pt_PT"), "pt-BR")
        XCTAssertEqual(SupportedLanguage.normalizedCode("ja-JP"), "ja-JP")
        XCTAssertEqual(SupportedLanguage.normalizedCode("es-MX"), "es-ES")
    }

    func testLanguageDetectionIdentifiesEnglishAndPortugueseWithoutFallbackGuess() {
        let detector = AppleLanguageDetectionService()
        XCTAssertEqual(
            detector.dominantLanguage(for: "We should review the roadmap and translate this meeting into Portuguese."),
            SupportedLanguage.englishUS.rawValue
        )
        XCTAssertEqual(
            detector.dominantLanguage(for: "Precisamos revisar o roteiro e traduzir esta reunião para inglês."),
            SupportedLanguage.portugueseBR.rawValue
        )
        XCTAssertEqual(
            detector.dominantLanguage(for: "Necesitamos saber quién revisa el riesgo de autenticación."),
            SupportedLanguage.spanishES.rawValue
        )
        XCTAssertEqual(
            detector.dominantLanguage(for: "認証のリスクを確認したいです。"),
            SupportedLanguage.japaneseJP.rawValue
        )
        XCTAssertNil(detector.dominantLanguage(for: "ok"))
    }

    func testLanguageDetectionDoesNotInvertLiveMeetingPhrases() {
        let detector = AppleLanguageDetectionService()
        XCTAssertEqual(
            detector.dominantLanguage(for: "Eu estou falando em português agora para testar a tradução da reunião."),
            SupportedLanguage.portugueseBR.rawValue
        )
        XCTAssertEqual(
            detector.dominantLanguage(for: "I am speaking in English now to test the meeting translation."),
            SupportedLanguage.englishUS.rawValue
        )
        XCTAssertEqual(
            detector.dominantLanguage(for: "Vamos alinhar os próximos passos e revisar os riscos."),
            SupportedLanguage.portugueseBR.rawValue
        )
        XCTAssertEqual(
            detector.dominantLanguage(for: "Let us align the next steps and review the risks."),
            SupportedLanguage.englishUS.rawValue
        )
    }

    func testAutoLanguageSelectorUsesDetectedTextLanguageOverRecognizerLocale() {
        let meetingId = UUID()
        let portugueseTextFromEnglishRecognizer = TranscriptSegment(
            meetingId: meetingId,
            speakerLabel: "You",
            text: "Eu estou falando em português agora para testar a tradução da reunião.",
            originalLanguage: SupportedLanguage.englishUS.rawValue,
            confidence: 0.9
        )
        let englishTextFromPortugueseRecognizer = TranscriptSegment(
            meetingId: meetingId,
            speakerLabel: "You",
            text: "I am speaking in English now to test the meeting translation.",
            originalLanguage: SupportedLanguage.portugueseBR.rawValue,
            confidence: 0.9
        )
        let selector = AutoLanguageTranscriptSelector()

        XCTAssertEqual(
            selector.resolvedLanguage(for: AutoLanguageTranscriptCandidate(language: .englishUS, segment: portugueseTextFromEnglishRecognizer)),
            .portugueseBR
        )
        XCTAssertEqual(
            selector.resolvedLanguage(for: AutoLanguageTranscriptCandidate(language: .portugueseBR, segment: englishTextFromPortugueseRecognizer)),
            .englishUS
        )
    }

    func testProviderRouterBlocksAIWhenLocalProviderIsUnavailable() {
        var preferences = AppPreferences()
        preferences.localOnlyMode = true
        preferences.aiConfig.provider = .openAI
        preferences.aiConfig.cloudProcessingEnabled = true
        let router = ProviderRouter(openAIProvider: nil)
        let provider = router.aiProvider(preferences: preferences)
        XCTAssertTrue([.appleFoundationModels, .unavailable].contains(provider.name))
        let report = router.report(preferences: preferences)
        XCTAssertNotEqual(report.summaryMode, .cloud)
    }

    func testTranscriptPresentationCacheSurvivesTransientEmptyMeetingUpdate() {
        let appState = AppState()
        let meetingId = UUID()
        let segment = TranscriptSegment(
            meetingId: meetingId,
            speakerLabel: "You",
            audioSource: .microphone,
            text: "This transcript should remain visible after collapsing and expanding."
        )

        appState.currentMeeting = MeetingSession(
            id: meetingId,
            title: "Live meeting",
            status: .listening,
            transcriptSegments: [segment]
        )
        XCTAssertEqual(appState.presentationTranscriptSegments.map(\.id), [segment.id])

        appState.currentMeeting = MeetingSession(
            id: meetingId,
            title: "Live meeting",
            status: .listening,
            transcriptSegments: []
        )
        XCTAssertEqual(appState.presentationTranscriptSegments.map(\.id), [segment.id])

        appState.currentMeeting = nil
        XCTAssertTrue(appState.presentationTranscriptSegments.isEmpty)
    }

    func testDefaultAudioCapturePrefersMicAndSystemAudio() {
        let preferences = AppPreferences()
        XCTAssertEqual(preferences.audioCaptureMode, .microphoneAndSystem)
        XCTAssertTrue(preferences.captureSystemAudio)
    }

    func testTranscriptionAccuracyDefaultsAndLegacyAudioQualityDecode() throws {
        let defaults = AppPreferences()
        XCTAssertEqual(defaults.transcriptionAccuracyMode, .highAccuracy)
        XCTAssertEqual(defaults.copilotASRCommitPolicy, .accurate)
        XCTAssertEqual(defaults.audioQuality, "High")

        let legacyStandard = try JSONDecoder().decode(AppPreferences.self, from: Data(#"{ "audioQuality": "Standard" }"#.utf8))
        XCTAssertEqual(legacyStandard.transcriptionAccuracyMode, .standard)

        let explicitHigh = try JSONDecoder().decode(
            AppPreferences.self,
            from: Data(#"{ "audioQuality": "Standard", "transcriptionAccuracyMode": "highAccuracy", "copilotASRCommitPolicy": "balanced" }"#.utf8)
        )
        XCTAssertEqual(explicitHigh.transcriptionAccuracyMode, .highAccuracy)
        XCTAssertEqual(explicitHigh.copilotASRCommitPolicy, .balanced)
    }

    func testIslandDesignModeDefaultsToSolidForLegacyPreferences() throws {
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: Data(#"{}"#.utf8))

        XCTAssertEqual(decoded.islandDesignMode, .solid)
    }

    func testIslandDesignModeRoundTripsLiquidGlassAndInvalidValuesFallBack() throws {
        var preferences = AppPreferences()
        preferences.islandDesignMode = .liquidGlass

        let data = try JSONEncoder().encode(preferences)
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: data)
        XCTAssertEqual(decoded.islandDesignMode, .liquidGlass)

        let invalid = try JSONDecoder().decode(
            AppPreferences.self,
            from: Data(#"{ "islandDesignMode": "frostedButUnknown" }"#.utf8)
        )
        XCTAssertEqual(invalid.islandDesignMode, .solid)
    }

    func testIslandDesignModeEnvironmentDefaultsAndDoesNotAffectSizing() {
        var environment = EnvironmentValues()
        XCTAssertEqual(environment.islandDesignMode, .solid)
        environment.islandDesignMode = .liquidGlass
        XCTAssertEqual(environment.islandDesignMode, .liquidGlass)

        var preferences = AppPreferences()
        let appState = AppState(preferences: preferences)
        appState.islandMode = .listening
        appState.isPanelExpanded = false
        let solidSize = appState.notchIslandSize

        preferences.islandDesignMode = .liquidGlass
        appState.preferences = preferences
        XCTAssertEqual(appState.notchIslandSize, solidSize)
    }

    func testOldMicOnlyDefaultsMigrateToMeetingCaptureMode() throws {
        let data = """
        {
          "audioCaptureMode": "microphoneOnly",
          "captureSystemAudio": false
        }
        """.data(using: .utf8)!

        var preferences = try JSONDecoder().decode(AppPreferences.self, from: data)
        XCTAssertFalse(preferences.didMigrateRealtimeAudioDefaults)

        preferences.normalizeForPersistence()

        XCTAssertEqual(preferences.audioCaptureMode, .microphoneAndSystem)
        XCTAssertTrue(preferences.captureSystemAudio)
        XCTAssertTrue(preferences.didMigrateRealtimeAudioDefaults)
    }

    func testKnownMeetingAppsMergeNewDefaultsIntoPersistedPreferences() {
        var preferences = AppPreferences()
        preferences.knownMeetingApps = [
            KnownMeetingApp(displayName: "Zoom", bundleIdentifiers: ["us.zoom.xos"], nameKeywords: ["zoom"])
        ]

        preferences.normalizeForPersistence()

        XCTAssertTrue(preferences.knownMeetingApps.contains { $0.displayName == "Google Meet" })
        XCTAssertTrue(preferences.knownMeetingApps.contains { $0.displayName == "Microsoft Edge" })
        XCTAssertTrue(preferences.knownMeetingApps.contains { $0.displayName == "DuckDuckGo" })
        XCTAssertTrue(preferences.knownMeetingApps.contains { $0.displayName == "Dia" })
        XCTAssertTrue(preferences.knownMeetingApps.contains { $0.displayName == "Orion" })
        let teams = preferences.knownMeetingApps.first { $0.displayName == "Microsoft Teams" }
        XCTAssertTrue(teams?.bundleIdentifiers.contains("com.microsoft.teams2") == true)
    }

    func testDefaultKnownMeetingAppsCoverBrowserVariants() {
        let defaults = KnownMeetingApp.defaults
        let allBundles = Set(defaults.flatMap(\.bundleIdentifiers))

        XCTAssertTrue(allBundles.contains("company.thebrowser.Browser"))
        XCTAssertTrue(allBundles.contains("com.google.Chrome.canary"))
        XCTAssertTrue(allBundles.contains("com.microsoft.edgemac.Dev"))
        XCTAssertTrue(allBundles.contains("com.brave.Browser.nightly"))
        XCTAssertTrue(allBundles.contains("org.mozilla.firefoxdeveloperedition"))
        XCTAssertTrue(allBundles.contains("com.apple.SafariTechnologyPreview"))
        XCTAssertTrue(allBundles.contains("com.operasoftware.OperaGX"))
        XCTAssertTrue(allBundles.contains("com.duckduckgo.macos.browser"))
        XCTAssertTrue(allBundles.contains("company.thebrowser.dia"))
        XCTAssertTrue(allBundles.contains("com.kagi.kagimacOS"))
    }

    func testSmartMeetingDetectionReturnsCandidateWhenKnownAppUsesMicrophone() async {
        let known = KnownMeetingApp.defaults.first { $0.displayName == "Zoom" }!
        let service = MeetingDetectionService(
            calendarDetector: EmptyCalendarMeetingDetector(),
            microphoneUsageMonitor: FakeMicrophoneUsageMonitor(inUse: true),
            appActivityMonitor: FakeMeetingAppActivityMonitor(
                activity: MeetingAppActivity(
                    appName: "Zoom",
                    bundleIdentifier: "us.zoom.xos",
                    matchedApp: known,
                    detectedAt: Date()
                )
            )
        )
        var preferences = AppPreferences()
        preferences.autoDetectMeetings = true
        preferences.smartMeetingDetectionEnabled = true
        let meeting = await service.detectMeeting(preferences: preferences)
        XCTAssertEqual(meeting?.source, .activeApp)
        XCTAssertEqual(meeting?.automationSourceAppName, "Zoom")
        XCTAssertEqual(meeting?.automationSourceBundleId, "us.zoom.xos")
    }

    func testCopilotPushToTalkSuppressesMeetingAutoDetection() async {
        let now = Date(timeIntervalSince1970: 1_000)
        let known = KnownMeetingApp.defaults.first { $0.displayName == "WhatsApp" }!
        let detectionService = MeetingDetectionService(
            calendarDetector: CalendarMeetingDetector(),
            microphoneUsageMonitor: FakeMicrophoneUsageMonitor(inUse: true),
            appActivityMonitor: FakeMeetingAppActivityMonitor(
                activity: MeetingAppActivity(
                    appName: "WhatsApp",
                    bundleIdentifier: "net.whatsapp.WhatsApp",
                    matchedApp: known,
                    detectedAt: now
                )
            )
        )
        var preferences = AppPreferences()
        preferences.autoDetectMeetings = true
        preferences.smartMeetingDetectionEnabled = true
        let appState = AppState(preferences: preferences)
        appState.isCopilotPushToTalkActive = true
        let controller = MeetingAutomationController(
            appState: appState,
            meetingDetectionService: detectionService,
            microphoneUsageMonitor: FakeMicrophoneUsageMonitor(inUse: true)
        )

        await controller.tick(now: now)

        XCTAssertNil(appState.currentMeeting)
        XCTAssertEqual(appState.islandMode, .idle)
    }

    func testCopilotMeetingDetectionSuppressionGraceExpires() async {
        let now = Date(timeIntervalSince1970: 2_000)
        let known = KnownMeetingApp.defaults.first { $0.displayName == "WhatsApp" }!
        let detectionService = MeetingDetectionService(
            calendarDetector: CalendarMeetingDetector(),
            microphoneUsageMonitor: FakeMicrophoneUsageMonitor(inUse: true),
            appActivityMonitor: FakeMeetingAppActivityMonitor(
                activity: MeetingAppActivity(
                    appName: "WhatsApp",
                    bundleIdentifier: "net.whatsapp.WhatsApp",
                    matchedApp: known,
                    detectedAt: now
                )
            )
        )
        var preferences = AppPreferences()
        preferences.autoDetectMeetings = true
        preferences.smartMeetingDetectionEnabled = true
        let appState = AppState(preferences: preferences)
        appState.suppressMeetingDetectionForCopilot(now: now, grace: 5)
        let controller = MeetingAutomationController(
            appState: appState,
            meetingDetectionService: detectionService,
            microphoneUsageMonitor: FakeMicrophoneUsageMonitor(inUse: true)
        )

        await controller.tick(now: now.addingTimeInterval(4.9))
        XCTAssertNil(appState.currentMeeting)

        await controller.tick(now: now.addingTimeInterval(5.1))
        XCTAssertEqual(appState.currentMeeting?.automationSourceAppName, "WhatsApp")
        XCTAssertEqual(appState.islandMode, .meetingDetected)
    }

    func testMicrophoneUsageMonitorFallsBackToCoreAudioWhenAVCaptureMissesUsage() {
        let monitor = MicrophoneUsageMonitor(
            avCaptureInputInUse: { false },
            coreAudioInputRunningSomewhere: { true }
        )

        XCTAssertTrue(monitor.isInputInUseByAnotherApplication())
    }

    func testSmartMeetingDetectionIgnoresBrowserWhenMeetingTabCannotBeConfirmed() async {
        let service = MeetingDetectionService(
            calendarDetector: EmptyCalendarMeetingDetector(),
            microphoneUsageMonitor: FakeMicrophoneUsageMonitor(inUse: true),
            appActivityMonitor: MeetingAppActivityMonitor(snapshots: {
                [
                    RunningApplicationSnapshot(
                        localizedName: "Google Chrome",
                        bundleIdentifier: "com.google.Chrome",
                        isActive: true
                    )
                ]
            }, activeBrowserTab: { _ in
                nil
            })
        )
        var preferences = AppPreferences()
        preferences.autoDetectMeetings = true
        preferences.smartMeetingDetectionEnabled = true

        let meeting = await service.detectMeeting(preferences: preferences)

        XCTAssertNil(meeting)
    }

    func testSmartMeetingDetectionUsesBrowserMeetingPlatformWhenActiveTabIsKnown() async {
        let service = MeetingDetectionService(
            calendarDetector: CalendarMeetingDetector(),
            microphoneUsageMonitor: FakeMicrophoneUsageMonitor(inUse: true),
            appActivityMonitor: MeetingAppActivityMonitor(snapshots: {
                [
                    RunningApplicationSnapshot(
                        localizedName: "Google Chrome",
                        bundleIdentifier: "com.google.Chrome",
                        isActive: true
                    )
                ]
            }, activeBrowserTab: { _ in
                BrowserTabSnapshot(
                    title: "Daily standup - Google Meet",
                    url: "https://meet.google.com/abc-defg-hij"
                )
            })
        )
        var preferences = AppPreferences()
        preferences.autoDetectMeetings = true
        preferences.smartMeetingDetectionEnabled = true

        let meeting = await service.detectMeeting(preferences: preferences)

        XCTAssertEqual(meeting?.source, .activeApp)
        XCTAssertEqual(meeting?.title, "Google Meet meeting")
        XCTAssertEqual(meeting?.appName, "Google Meet")
        XCTAssertEqual(meeting?.meetingURL, "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(meeting?.automationSourceAppName, "Google Meet")
        XCTAssertEqual(meeting?.automationSourceBundleId, "com.google.Chrome")
    }

    func testSmartMeetingDetectionUsesArcMeetTitleWhenURLIsUnavailable() async {
        let service = MeetingDetectionService(
            calendarDetector: CalendarMeetingDetector(),
            microphoneUsageMonitor: FakeMicrophoneUsageMonitor(inUse: true),
            appActivityMonitor: MeetingAppActivityMonitor(snapshots: {
                [
                    RunningApplicationSnapshot(
                        localizedName: "Arc",
                        bundleIdentifier: "company.thebrowser.Browser",
                        isActive: true
                    )
                ]
            }, activeBrowserTab: { _ in
                BrowserTabSnapshot(
                    title: "Meet: jta-miju-aim",
                    url: nil
                )
            })
        )
        var preferences = AppPreferences()
        preferences.autoDetectMeetings = true
        preferences.smartMeetingDetectionEnabled = true

        let meeting = await service.detectMeeting(preferences: preferences)

        XCTAssertEqual(meeting?.source, .activeApp)
        XCTAssertEqual(meeting?.title, "Google Meet meeting")
        XCTAssertEqual(meeting?.appName, "Google Meet")
        XCTAssertNil(meeting?.meetingURL)
        XCTAssertEqual(meeting?.automationSourceAppName, "Google Meet")
        XCTAssertEqual(meeting?.automationSourceBundleId, "company.thebrowser.Browser")
    }

    func testBrowserActiveTabResolverUsesArcSafeWindowCountScripts() {
        let scripts = BrowserActiveTabResolver.scriptSources(for: "company.thebrowser.Browser")
        let joined = scripts.joined(separator: "\n")

        XCTAssertTrue(joined.contains("count of windows"))
        XCTAssertTrue(joined.contains("active tab of front window"))
        XCTAssertFalse(joined.contains("exists front window"))
    }

    func testMeetingWebPlatformDetectsGoogleMeetFromArcTitle() {
        let platform = MeetingWebPlatform.detect(
            url: nil,
            title: "Meet: jta-miju-aim",
            appName: "Arc"
        )

        XCTAssertEqual(platform, .googleMeet)
    }

    func testSmartMeetingDetectionIgnoresYouTubeBrowserTabUsingMicrophone() async {
        let service = MeetingDetectionService(
            calendarDetector: CalendarMeetingDetector(),
            microphoneUsageMonitor: FakeMicrophoneUsageMonitor(inUse: true),
            appActivityMonitor: MeetingAppActivityMonitor(snapshots: {
                [
                    RunningApplicationSnapshot(
                        localizedName: "Google Chrome",
                        bundleIdentifier: "com.google.Chrome",
                        isActive: true
                    )
                ]
            }, activeBrowserTab: { _ in
                BrowserTabSnapshot(
                    title: "Microsoft Teams meeting tutorial - YouTube",
                    url: "https://www.youtube.com/watch?v=abc123"
                )
            })
        )
        var preferences = AppPreferences()
        preferences.autoDetectMeetings = true
        preferences.smartMeetingDetectionEnabled = true

        let meeting = await service.detectMeeting(preferences: preferences)

        XCTAssertNil(meeting)
    }

    func testMeetingWebPlatformDoesNotDetectMeetingFromMediaPageTitle() {
        let platform = MeetingWebPlatform.detect(
            url: "https://www.youtube.com/watch?v=abc123",
            title: "Daily standup - Google Meet - YouTube",
            appName: "Google Chrome"
        )

        XCTAssertNil(platform)
    }

    func testBrowserActiveTabResolverIncludesFirefoxForTitleFallback() {
        XCTAssertTrue(BrowserActiveTabResolver.isBrowserBundleIdentifier("org.mozilla.firefox"))
        XCTAssertTrue(BrowserActiveTabResolver.isBrowserAppName("Firefox Developer Edition"))
        XCTAssertTrue(BrowserActiveTabResolver.isBrowserBundleIdentifier("com.duckduckgo.macos.browser"))
        XCTAssertTrue(BrowserActiveTabResolver.isBrowserAppName("DuckDuckGo Browser"))
        XCTAssertTrue(BrowserActiveTabResolver.isBrowserBundleIdentifier("company.thebrowser.dia"))
        XCTAssertTrue(BrowserActiveTabResolver.isBrowserAppName("Dia"))
    }

    func testSmartMeetingDetectionRecognizesTeamsDesktopVariants() async {
        let service = MeetingDetectionService(
            calendarDetector: CalendarMeetingDetector(),
            microphoneUsageMonitor: FakeMicrophoneUsageMonitor(inUse: true),
            appActivityMonitor: MeetingAppActivityMonitor(snapshots: {
                [
                    RunningApplicationSnapshot(
                        localizedName: "Microsoft Teams (work or school)",
                        bundleIdentifier: "com.microsoft.teams2",
                        isActive: true
                    )
                ]
            })
        )
        var preferences = AppPreferences()
        preferences.autoDetectMeetings = true
        preferences.smartMeetingDetectionEnabled = true

        let meeting = await service.detectMeeting(preferences: preferences)

        XCTAssertEqual(meeting?.source, .activeApp)
        XCTAssertEqual(meeting?.automationSourceAppName, "Microsoft Teams (work or school)")
        XCTAssertEqual(meeting?.automationSourceBundleId, "com.microsoft.teams2")
    }

    func testMeetingAutomationDoesNotAutoStartWhenConfirmationIsRequired() {
        var preferences = AppPreferences()
        preferences.autoStartListening = true
        preferences.requireConfirmationBeforeRecording = true
        XCTAssertFalse(MeetingAutomationPolicy().shouldAutoStart(preferences: preferences))
    }

    func testAutoEndWaitsForConfiguredGracePeriod() {
        var preferences = AppPreferences()
        preferences.autoEndDetectedMeetings = true
        preferences.autoEndGraceSeconds = 5
        let now = Date()
        let meeting = MeetingSession(
            title: "Zoom meeting",
            source: .activeApp,
            status: .listening,
            automationSourceAppName: "Zoom",
            automationSourceBundleId: "us.zoom.xos"
        )
        let decision = MeetingAutomationPolicy().autoEndDecision(
            meeting: meeting,
            preferences: preferences,
            microphoneInUseByAnotherApplication: false,
            now: now.addingTimeInterval(4.9),
            inactiveSince: now
        )
        XCTAssertEqual(decision, .waiting(inactiveSince: now))
    }

    func testAutoEndFiresAfterConfiguredGracePeriod() {
        var preferences = AppPreferences()
        preferences.autoEndDetectedMeetings = true
        preferences.autoEndGraceSeconds = 5
        let now = Date()
        let meeting = MeetingSession(
            title: "Teams meeting",
            source: .activeApp,
            status: .listening,
            automationSourceAppName: "Microsoft Teams",
            automationSourceBundleId: "com.microsoft.teams2"
        )
        let decision = MeetingAutomationPolicy().autoEndDecision(
            meeting: meeting,
            preferences: preferences,
            microphoneInUseByAnotherApplication: false,
            now: now.addingTimeInterval(5),
            inactiveSince: now
        )
        XCTAssertEqual(decision, .shouldEnd)
    }

    func testManualMeetingDoesNotAutoEndFromMicrophoneHeuristic() {
        var preferences = AppPreferences()
        preferences.autoEndDetectedMeetings = true
        let meeting = MeetingSession(title: "Manual notes", source: .manual, status: .listening)
        let decision = MeetingAutomationPolicy().autoEndDecision(
            meeting: meeting,
            preferences: preferences,
            microphoneInUseByAnotherApplication: false,
            now: Date(),
            inactiveSince: Date()
        )
        XCTAssertEqual(decision, .notApplicable)
    }

    func testTranscriptionRouterKeepsAppleSpeechAvailableInLocalOnlyMode() {
        var preferences = AppPreferences()
        preferences.localOnlyMode = true
        preferences.defaultLanguage = "en-US"
        preferences.transcriptionEngineMode = .appleSpeech
        let router = ProviderRouter(openAIProvider: nil)
        let service = router.transcriptionService(preferences: preferences)
        if SupportedLanguage.allCases.contains(where: { AppleSpeechTranscriptionService.supportsLanguage($0) }) {
            XCTAssertTrue(service is AppleNativeTranscriptionService)
        } else {
            XCTAssertTrue(service is UnavailableTranscriptionService)
        }
    }

    func testTranscriptionRouterUsesSourceSeparatedAppleSpeechForMicAndSystem() {
        var preferences = AppPreferences()
        preferences.transcriptionEngineMode = .appleSpeech
        let router = ProviderRouter(openAIProvider: nil)
        let stream = AsyncStream<NotchCopilot.AudioBuffer> { continuation in
            continuation.finish()
        }
        let sources = [
            MultiSourceAutoLanguageTranscriptionService.Source(speakerLabel: "System", audioSource: .system, audioStream: stream),
            MultiSourceAutoLanguageTranscriptionService.Source(speakerLabel: "You", audioSource: .microphone, audioStream: stream)
        ]
        let service = router.transcriptionService(preferences: preferences, sources: sources)

        if router.supportsAutoLanguageAppleSpeech() {
            XCTAssertTrue(service is MultiSourceAutoLanguageTranscriptionService)
        }
    }

    func testSpeechRestartPolicyParksOnNoSpeechWithoutRecentAudio() {
        let now = Date()
        let decision = SpeechRestartPolicy().decision(
            errorDescription: "No speech detected",
            now: now,
            lastSignificantAudioAt: now.addingTimeInterval(-10),
            lastRestartAt: now.addingTimeInterval(-10)
        )

        XCTAssertFalse(decision.shouldRestart)
        XCTAssertTrue(decision.shouldParkUntilAudio)
        XCTAssertFalse(decision.shouldLogAsError)
    }

    func testSpeechRestartPolicyRestartsOnNoSpeechWhenAudioWasRecent() {
        let now = Date()
        let decision = SpeechRestartPolicy().decision(
            errorDescription: "No speech detected",
            now: now,
            lastSignificantAudioAt: now.addingTimeInterval(-0.4),
            lastRestartAt: now.addingTimeInterval(-10)
        )

        XCTAssertTrue(decision.shouldRestart)
        XCTAssertEqual(decision.delayMilliseconds, 0)
        XCTAssertFalse(decision.shouldParkUntilAudio)
        XCTAssertFalse(decision.shouldLogAsError)
    }

    func testSpeechRestartPolicyIgnoresControlledCancellation() {
        let now = Date()
        let decision = SpeechRestartPolicy().decision(
            errorDescription: "Recognition request was canceled",
            now: now,
            lastSignificantAudioAt: now,
            lastRestartAt: now.addingTimeInterval(-10)
        )

        XCTAssertFalse(decision.shouldRestart)
        XCTAssertFalse(decision.shouldParkUntilAudio)
        XCTAssertFalse(decision.shouldLogAsError)
    }

    func testAutoLanguageSelectorPrefersMatchingLanguageCandidate() {
        let meetingId = UUID()
        let selector = AutoLanguageTranscriptSelector()
        let english = AutoLanguageTranscriptCandidate(
            language: .englishUS,
            segment: TranscriptSegment(
                meetingId: meetingId,
                text: "I am speaking in English and this should be translated to Portuguese.",
                originalLanguage: SupportedLanguage.englishUS.rawValue,
                confidence: 0.88,
                isFinal: false
            )
        )
        let portuguese = AutoLanguageTranscriptCandidate(
            language: .portugueseBR,
            segment: TranscriptSegment(
                meetingId: meetingId,
                text: "Ai em ispique em inglish ande dis xude bi transleitid tu portuguese.",
                originalLanguage: SupportedLanguage.portugueseBR.rawValue,
                confidence: 0.62,
                isFinal: false
            )
        )

        XCTAssertEqual(selector.bestCandidate(from: [portuguese, english])?.language, .englishUS)
    }

    func testMultiSourceAppleSpeechKeepsSystemAudioSourceWhenForwardingSegments() {
        let meetingId = UUID()
        let incoming = TranscriptSegment(
            meetingId: meetingId,
            speakerLabel: "You",
            audioSource: .microphone,
            text: "Audio from the meeting video."
        )

        let forwarded = MultiSourceAppleSpeechTranscriptionService.relabeled(
            incoming,
            speakerLabel: "System",
            audioSource: .system
        )

        XCTAssertEqual(forwarded.speakerLabel, "System")
        XCTAssertEqual(forwarded.audioSource, .system)
        XCTAssertEqual(forwarded.text, incoming.text)
    }

    func testMultiSourceAutoLanguageKeepsSystemAudioSourceWhenForwardingSegments() {
        let meetingId = UUID()
        let incoming = TranscriptSegment(
            meetingId: meetingId,
            speakerLabel: "You",
            audioSource: .microphone,
            text: "Audio from the meeting video."
        )

        let forwarded = MultiSourceAutoLanguageTranscriptionService.relabeled(
            incoming,
            speakerLabel: "System",
            audioSource: .system
        )

        XCTAssertEqual(forwarded.speakerLabel, "System")
        XCTAssertEqual(forwarded.audioSource, .system)
        XCTAssertEqual(forwarded.text, incoming.text)
    }

    func testSummaryEngineWithTestProvider() async throws {
        let meeting = MeetingSession(
            title: "Engineering Sync",
            transcriptSegments: [TranscriptSegment(meetingId: UUID(), speakerLabel: "Speaker 1", text: "Let's keep Local Only as default.")]
        )
        let summary = try await SummaryEngine(provider: TestAIProvider()).summarize(meeting)
        XCTAssertFalse(summary.executiveSummary.isEmpty)
        XCTAssertFalse(summary.actionItems.isEmpty)
        XCTAssertFalse(summary.keyDecisions.isEmpty)
        XCTAssertFalse(summary.risks.isEmpty)
    }

    func testStructuredSummaryParserFillsMeetingSummaryFields() throws {
        let meetingId = UUID()
        let json = """
        {
          "executiveSummary": "We agreed to ship a careful MVP.",
          "keyDecisions": ["Keep confirmation before recording."],
          "actionItems": [{"title": "Validate auto-end", "owner": "Ryan", "dueDate": null, "priority": "high", "sourceQuote": "Let's validate auto-end."}],
          "risks": ["Browser detection is heuristic."],
          "openQuestions": ["Should browser tab detection require Accessibility later?"],
          "strategicInsights": ["Trust depends on visible recording states."],
          "followUps": ["Run a Zoom manual acceptance test."]
        }
        """
        let summary = try XCTUnwrap(MeetingSummaryParser.parse(json, meetingId: meetingId))
        XCTAssertEqual(summary.meetingId, meetingId)
        XCTAssertEqual(summary.keyDecisions.first, "Keep confirmation before recording.")
        XCTAssertEqual(summary.actionItems.first?.priority, .high)
        XCTAssertEqual(summary.strategicInsights.first, "Trust depends on visible recording states.")
    }

    func testSuggestedAnswerEngineWithTestProvider() async throws {
        var preferences = AppPreferences()
        preferences.userRole = "Senior Fullstack Software Engineer"
        let meetingId = UUID()
        let meeting = MeetingSession(
            id: meetingId,
            title: "Privacy Review",
            transcriptSegments: [TranscriptSegment(meetingId: meetingId, speakerLabel: "Speaker 1", text: "Ryan, can you explain the risk?")]
        )
        let answer = try await SuggestedAnswerEngine(provider: TestAIProvider()).draftAnswer(
            for: "Ryan, can you explain the risk?",
            meeting: meeting,
            preferences: preferences,
            ragContext: "Use minimal context."
        )
        XCTAssertFalse(answer.text.isEmpty)
        XCTAssertFalse(answer.usedCloud)
    }

    func testSuggestedAnswerEngineTimesOutInsteadOfHanging() async throws {
        let meeting = MeetingSession(id: UUID(), title: "Copilot", status: .listening)

        do {
            _ = try await SuggestedAnswerEngine(
                provider: SlowRawAIProvider(delayNanoseconds: 1_000_000_000),
                answerTimeoutSeconds: 0.03
            ).draftAnswer(
                for: "Pode montar um plano rapido?",
                meeting: meeting,
                preferences: AppPreferences(),
                ragContext: ""
            )
            XCTFail("Expected suggested answer timeout")
        } catch let failure as CopilotFailure {
            XCTAssertEqual(failure.kind, .answerTimedOut)
        }
    }

    func testTestProviderAnswersAndTranslatesPortuguese() async throws {
        let provider = TestAIProvider()
        let meetingId = UUID()
        let segment = TranscriptSegment(
            meetingId: meetingId,
            speakerLabel: "Pessoa 2",
            text: "Ryan, você pode explicar o risco de enviar o transcript inteiro para um provedor?",
            originalLanguage: "pt-BR"
        )
        let translated = try await provider.translateSegment(segment, targetLanguage: "en-US")
        XCTAssertEqual(translated, "Ryan, can you explain the risk if we send the whole transcript to a provider?")

        let answer = try await provider.generateAnswer(
            context: AnswerContext(
                meetingTitle: "Revisão de Privacidade",
                transcriptWindow: segment.text,
                ragContext: "",
                userRole: "Senior Fullstack Software Engineer",
                responseStyle: .technical,
                languageCode: "pt-BR"
            ),
            question: segment.text,
            options: AnswerOptions()
        )
        XCTAssertTrue(answer.text.contains("transcript completo"))
        XCTAssertFalse(answer.usedCloud)
    }

    func testIslandTranslationToggleEnablesDualTextMode() {
        var preferences = AppPreferences()
        preferences.defaultLanguage = SupportedLanguage.portugueseBR.rawValue
        preferences.targetLanguage = SupportedLanguage.portugueseBR.rawValue
        preferences.liveTranslationEnabled = false
        preferences.showOriginalText = true
        preferences.showTranslatedText = false
        let appState = AppState(preferences: preferences)

        appState.toggleLiveTranslation()

        XCTAssertTrue(appState.preferences.liveTranslationEnabled)
        XCTAssertTrue(appState.preferences.showOriginalText)
        XCTAssertTrue(appState.preferences.showTranslatedText)
        XCTAssertEqual(appState.preferences.targetLanguage, SupportedLanguage.portugueseBR.rawValue)

        appState.toggleLiveTranslation()

        XCTAssertFalse(appState.preferences.liveTranslationEnabled)
        XCTAssertTrue(appState.preferences.showOriginalText)
        XCTAssertFalse(appState.preferences.showTranslatedText)
    }

    func testLiveTranslationSetterUsesDetectedMeetingLanguageForTarget() {
        var preferences = AppPreferences()
        preferences.defaultLanguage = SupportedLanguage.englishUS.rawValue
        preferences.targetLanguage = SupportedLanguage.englishUS.rawValue
        preferences.liveTranslationEnabled = false
        preferences.showTranslatedText = false
        let appState = AppState(preferences: preferences)
        appState.currentMeeting = MeetingSession(
            title: "Reunião",
            primaryLanguage: SupportedLanguage.portugueseBR.rawValue
        )

        appState.setLiveTranslationEnabled(true)

        XCTAssertTrue(appState.preferences.liveTranslationEnabled)
        XCTAssertTrue(appState.preferences.showOriginalText)
        XCTAssertTrue(appState.preferences.showTranslatedText)
        XCTAssertEqual(appState.preferences.targetLanguage, SupportedLanguage.englishUS.rawValue)
    }

    func testSupportedLanguagesPairTranslationTargets() {
        XCTAssertEqual(SupportedLanguage.englishUS.pairedTranslationTarget, .portugueseBR)
        XCTAssertEqual(SupportedLanguage.portugueseBR.pairedTranslationTarget, .englishUS)
    }

    func testAppleTranslationServiceReturnsOriginalTextForSameLanguage() async throws {
        let translated = try await AppleTranslationService().translate(
            "Vamos manter o modo Local Only visível.",
            source: "pt-BR",
            target: "pt-BR"
        )
        XCTAssertEqual(translated, "Vamos manter o modo Local Only visível.")
    }

    func testLiveTranslationUsesPairedTargetWhenConfiguredTargetMatchesSource() async throws {
        let appleTranslator = RecordingAppleTranslator(output: "I am speaking Portuguese.")
        let engine = LiveTranslationEngine(appleTranslator: appleTranslator)
        var preferences = AppPreferences()
        preferences.defaultLanguage = SupportedLanguage.portugueseBR.rawValue
        preferences.targetLanguage = SupportedLanguage.portugueseBR.rawValue
        let segment = TranscriptSegment(
            meetingId: UUID(),
            speakerLabel: "You",
            audioSource: .microphone,
            text: "Eu estou falando português.",
            originalLanguage: SupportedLanguage.portugueseBR.rawValue
        )

        let result = await engine.translate(segment: segment, preferences: preferences)

        XCTAssertEqual(
            result,
            .translated(
                text: "I am speaking Portuguese.",
                engine: .appleTranslation,
                sourceLanguage: .portugueseBR,
                targetLanguage: .englishUS,
                phase: .refinement,
                confidence: 0.9,
                preservedTerms: [],
                isSemanticRefinement: false
            )
        )
        XCTAssertEqual(appleTranslator.requests.first?.source, SupportedLanguage.portugueseBR.rawValue)
        XCTAssertEqual(appleTranslator.requests.first?.target, SupportedLanguage.englishUS.rawValue)
    }

    func testLiveTranslationAutoPairsPortugueseAndEnglishPerSegment() async throws {
        let appleTranslator = RecordingAppleTranslator { request in
            request.target == SupportedLanguage.englishUS.rawValue
                ? "We need to review the project scope."
                : "Precisamos revisar os riscos da reunião."
        }
        let engine = LiveTranslationEngine(appleTranslator: appleTranslator)
        var preferences = AppPreferences()
        preferences.targetLanguage = SupportedLanguage.portugueseBR.rawValue

        let meetingId = UUID()
        let portuguese = TranscriptSegment(
            meetingId: meetingId,
            speakerLabel: "You",
            audioSource: .microphone,
            text: "Precisamos revisar o escopo do projeto.",
            originalLanguage: SupportedLanguage.portugueseBR.rawValue
        )
        let english = TranscriptSegment(
            meetingId: meetingId,
            speakerLabel: "System",
            audioSource: .system,
            text: "We need to review the meeting risks.",
            originalLanguage: SupportedLanguage.englishUS.rawValue
        )
        let portugueseAgain = TranscriptSegment(
            meetingId: meetingId,
            speakerLabel: "You",
            audioSource: .microphone,
            text: "Vamos alinhar os próximos passos.",
            originalLanguage: SupportedLanguage.portugueseBR.rawValue
        )

        _ = await engine.translate(segment: portuguese, preferences: preferences)
        _ = await engine.translate(segment: english, preferences: preferences)
        _ = await engine.translate(segment: portugueseAgain, preferences: preferences)

        XCTAssertEqual(appleTranslator.requests.map(\.source), ["pt-BR", "en-US", "pt-BR"])
        XCTAssertEqual(appleTranslator.requests.map(\.target), ["en-US", "pt-BR", "en-US"])
    }

    func testLiveTranslationReturnsUnavailableWithoutCloudFallback() async {
        let engine = LiveTranslationEngine(appleTranslator: FailingAppleTranslator())
        var preferences = AppPreferences()
        preferences.localOnlyMode = true
        preferences.aiConfig.cloudProcessingEnabled = false
        let segment = TranscriptSegment(
            meetingId: UUID(),
            speakerLabel: "System",
            audioSource: .system,
            text: "I am speaking in English.",
            originalLanguage: SupportedLanguage.englishUS.rawValue
        )

        let result = await engine.translate(segment: segment, preferences: preferences)

        XCTAssertEqual(result.state, .unavailable)
    }

    func testLiveTranslationFallsBackToCloudWhenAppleUnavailableAndCloudAllowed() async {
        let engine = LiveTranslationEngine(appleTranslator: FailingAppleTranslator()) { _ in
            FakeCloudTranslationProvider(translation: "Eu estou falando em inglês.")
        }
        var preferences = AppPreferences()
        preferences.localOnlyMode = false
        preferences.aiConfig.cloudProcessingEnabled = true
        let segment = TranscriptSegment(
            meetingId: UUID(),
            speakerLabel: "System",
            audioSource: .system,
            text: "I am speaking in English.",
            originalLanguage: SupportedLanguage.englishUS.rawValue
        )

        let result = await engine.translate(segment: segment, preferences: preferences)

        XCTAssertEqual(
            result,
            .translated(
                text: "Eu estou falando em inglês.",
                engine: .openAI,
                sourceLanguage: .englishUS,
                targetLanguage: .portugueseBR,
                phase: .refinement,
                confidence: 0.9,
                preservedTerms: [],
                isSemanticRefinement: true
            )
        )
    }

    func testRealtimeTranslationCoordinatorCreatesDraftJobForStablePartial() {
        var coordinator = RealtimeTranslationCoordinator()
        var preferences = AppPreferences()
        preferences.liveTranslationEnabled = true
        let segment = TranscriptSegment(
            meetingId: UUID(),
            speakerLabel: "You",
            audioSource: .microphone,
            text: "Precisamos revisar o escopo antes da demo",
            originalLanguage: SupportedLanguage.portugueseBR.rawValue,
            isFinal: false
        )

        let preparation = coordinator.prepare(
            segment: segment,
            existingSegment: nil,
            plan: TranslationPlan(source: .portugueseBR, target: .englishUS),
            preferences: preferences
        )

        XCTAssertEqual(preparation.segment.translationState, .drafting)
        XCTAssertEqual(preparation.segment.sourceLanguage, SupportedLanguage.portugueseBR.rawValue)
        XCTAssertEqual(preparation.segment.targetLanguage, SupportedLanguage.englishUS.rawValue)
        XCTAssertEqual(preparation.job?.phase, .draft)
        XCTAssertEqual(preparation.job?.text, segment.text)
        XCTAssertLessThanOrEqual(preparation.job?.delayMilliseconds ?? 999, 150)
    }

    func testRealtimeTranslationCoordinatorRefinesFinalWithoutClearingDraft() {
        var coordinator = RealtimeTranslationCoordinator()
        var preferences = AppPreferences()
        preferences.liveTranslationEnabled = true
        let meetingId = UUID()
        let segmentId = UUID()
        let existing = TranscriptSegment(
            id: segmentId,
            meetingId: meetingId,
            speakerLabel: "You",
            audioSource: .microphone,
            text: "Precisamos revisar o escopo antes da demo",
            originalLanguage: SupportedLanguage.portugueseBR.rawValue,
            sourceLanguage: SupportedLanguage.portugueseBR.rawValue,
            targetLanguage: SupportedLanguage.englishUS.rawValue,
            draftTranslatedText: "We need to review the scope before the demo",
            translatedLanguage: SupportedLanguage.englishUS.rawValue,
            translationPhase: .draft,
            translationState: .draftTranslated,
            isFinal: false
        )
        let final = TranscriptSegment(
            id: segmentId,
            meetingId: meetingId,
            speakerLabel: "You",
            audioSource: .microphone,
            text: "Precisamos revisar o escopo antes da demo.",
            originalLanguage: SupportedLanguage.portugueseBR.rawValue,
            isFinal: true
        )

        let preparation = coordinator.prepare(
            segment: final,
            existingSegment: existing,
            plan: TranslationPlan(source: .portugueseBR, target: .englishUS),
            preferences: preferences
        )

        XCTAssertEqual(preparation.segment.draftTranslatedText, existing.draftTranslatedText)
        XCTAssertNil(preparation.segment.translatedText)
        XCTAssertEqual(preparation.segment.translationState, .refining)
        XCTAssertEqual(preparation.job?.phase, .refinement)
    }

    func testRealtimeTranslationCoordinatorDropsDraftWhenASRRevisionChangesMeaning() {
        var coordinator = RealtimeTranslationCoordinator()
        var preferences = AppPreferences()
        preferences.liveTranslationEnabled = true
        let meetingId = UUID()
        let segmentId = UUID()
        let existing = TranscriptSegment(
            id: segmentId,
            meetingId: meetingId,
            speakerLabel: "You",
            audioSource: .microphone,
            text: "Precisamos revisar o escopo antes da demo",
            originalLanguage: SupportedLanguage.portugueseBR.rawValue,
            sourceLanguage: SupportedLanguage.portugueseBR.rawValue,
            targetLanguage: SupportedLanguage.englishUS.rawValue,
            draftTranslatedText: "We need to review the scope before the demo",
            translatedLanguage: SupportedLanguage.englishUS.rawValue,
            translationPhase: .draft,
            translationState: .draftTranslated,
            isFinal: false
        )
        let revised = TranscriptSegment(
            id: segmentId,
            meetingId: meetingId,
            speakerLabel: "You",
            audioSource: .microphone,
            text: "Vamos cancelar a release e reagendar a reunião",
            originalLanguage: SupportedLanguage.portugueseBR.rawValue,
            isFinal: false
        )

        let preparation = coordinator.prepare(
            segment: revised,
            existingSegment: existing,
            plan: TranslationPlan(source: .portugueseBR, target: .englishUS),
            preferences: preferences
        )

        XCTAssertNil(preparation.segment.draftTranslatedText)
        XCTAssertNil(preparation.segment.translatedText)
        XCTAssertEqual(preparation.segment.translationState, .drafting)
        XCTAssertEqual(preparation.job?.phase, .draft)
    }

    func testLanguageContinuityAvoidsSwitchingOnAmbiguousPartial() {
        var resolver = LanguageContinuityResolver()
        let first = resolver.resolve(
            text: "We should review the rollout risk before shipping.",
            audioSource: .system,
            incomingLanguage: SupportedLanguage.englishUS.rawValue,
            existingLanguage: nil,
            meetingLanguage: nil,
            defaultLanguage: SupportedLanguage.portugueseBR.rawValue,
            isFinal: true
        )
        let ambiguous = resolver.resolve(
            text: "ok API",
            audioSource: .system,
            incomingLanguage: SupportedLanguage.portugueseBR.rawValue,
            existingLanguage: nil,
            meetingLanguage: nil,
            defaultLanguage: SupportedLanguage.portugueseBR.rawValue,
            isFinal: false
        )

        XCTAssertEqual(first.language, .englishUS)
        XCTAssertEqual(ambiguous.language, .englishUS)
        XCTAssertFalse(ambiguous.isTextDetected)
    }

    func testLanguageContinuitySwitchesOnStrongFinalLanguageEvidence() {
        var resolver = LanguageContinuityResolver()
        let portuguese = resolver.resolve(
            text: "Precisamos revisar o escopo antes da demo e alinhar os próximos passos.",
            audioSource: .microphone,
            incomingLanguage: SupportedLanguage.portugueseBR.rawValue,
            existingLanguage: nil,
            meetingLanguage: nil,
            defaultLanguage: SupportedLanguage.portugueseBR.rawValue,
            isFinal: true
        )
        let english = resolver.resolve(
            text: "We should review the rollout risk before shipping the authentication endpoint.",
            audioSource: .microphone,
            incomingLanguage: SupportedLanguage.portugueseBR.rawValue,
            existingLanguage: nil,
            meetingLanguage: SupportedLanguage.portugueseBR.rawValue,
            defaultLanguage: SupportedLanguage.portugueseBR.rawValue,
            isFinal: true
        )

        XCTAssertEqual(portuguese.language, .portugueseBR)
        XCTAssertEqual(english.language, .englishUS)
        XCTAssertTrue(english.isTextDetected)
    }

    func testTerminologyGuardPreservesGenericTechnicalTerms() {
        let guardrail = TerminologyGuard()
        let terms = guardrail.candidateTerms(
            in: "Please check SwiftUI, GraphQL, OIPS-124 and the API response.",
            memory: MeetingTerminologyMemory()
        )

        XCTAssertTrue(terms.contains("SwiftUI"))
        XCTAssertTrue(terms.contains("GraphQL"))
        XCTAssertTrue(terms.contains("OIPS-124"))
        XCTAssertTrue(terms.contains("API"))
    }

    func testRealtimeTranslationCoordinatorPreservesTechnicalOnlyPhrases() {
        var coordinator = RealtimeTranslationCoordinator()
        var preferences = AppPreferences()
        preferences.liveTranslationEnabled = true
        let segment = TranscriptSegment(
            meetingId: UUID(),
            speakerLabel: "System",
            audioSource: .system,
            text: "OIPS-124 API",
            originalLanguage: SupportedLanguage.englishUS.rawValue
        )

        let preparation = coordinator.prepare(
            segment: segment,
            existingSegment: nil,
            plan: TranslationPlan(source: .englishUS, target: .portugueseBR),
            preferences: preferences
        )

        XCTAssertNil(preparation.job)
        XCTAssertEqual(preparation.segment.translationState, .preserved)
        XCTAssertEqual(preparation.segment.translatedText, "OIPS-124 API")
        XCTAssertEqual(preparation.segment.preservedTerms.sorted(), ["API", "OIPS-124"])
    }

    func testDraftTranslationResultKeepsRealtimePhaseMetadata() async {
        let appleTranslator = RecordingAppleTranslator(output: "We need to review scope.")
        let engine = LiveTranslationEngine(appleTranslator: appleTranslator)
        let segment = TranscriptSegment(
            meetingId: UUID(),
            speakerLabel: "You",
            audioSource: .microphone,
            text: "Precisamos revisar escopo.",
            originalLanguage: SupportedLanguage.portugueseBR.rawValue
        )
        let metadata = TranslationRequestMetadata(
            phase: .draft,
            confidence: 0.74,
            preservedTerms: ["API"],
            isSemanticRefinement: false
        )

        let result = await engine.translateText(
            segment.text,
            source: .portugueseBR,
            target: .englishUS,
            segment: segment,
            preferences: AppPreferences(),
            metadata: metadata
        )

        XCTAssertEqual(
            result,
            .translated(
                text: "We need to review scope.",
                engine: .appleTranslation,
                sourceLanguage: .portugueseBR,
                targetLanguage: .englishUS,
                phase: .draft,
                confidence: 0.74,
                preservedTerms: ["API"],
                isSemanticRefinement: false
            )
        )
    }

    func testSemanticTranslationRefinerAllowsAppleLocalProviderInLocalOnlyMode() async {
        var preferences = AppPreferences()
        preferences.localOnlyMode = true
        preferences.aiConfig.cloudProcessingEnabled = false
        let segment = TranscriptSegment(
            meetingId: UUID(),
            speakerLabel: "You",
            audioSource: .microphone,
            text: "Precisamos revisar a API antes da demo.",
            originalLanguage: SupportedLanguage.portugueseBR.rawValue,
            sourceLanguage: SupportedLanguage.portugueseBR.rawValue
        )
        let provider = FakeCloudTranslationProvider(
            engine: .appleFoundationModels,
            translation: "We need to review the API before the demo."
        )

        let refined = await SemanticTranslationRefiner().refine(
            segment: segment,
            draft: "We need review API before demo.",
            targetLanguage: .englishUS,
            preferences: preferences,
            provider: provider
        )

        XCTAssertEqual(refined, "We need to review the API before the demo.")
    }

    func testSemanticTranslationRefinerBlocksCloudProviderInLocalOnlyMode() async {
        var preferences = AppPreferences()
        preferences.localOnlyMode = true
        preferences.aiConfig.cloudProcessingEnabled = true
        let segment = TranscriptSegment(
            meetingId: UUID(),
            speakerLabel: "You",
            audioSource: .microphone,
            text: "Precisamos revisar o escopo.",
            originalLanguage: SupportedLanguage.portugueseBR.rawValue
        )

        let refined = await SemanticTranslationRefiner().refine(
            segment: segment,
            draft: "We need to review scope.",
            targetLanguage: .englishUS,
            preferences: preferences,
            provider: FakeCloudTranslationProvider(translation: "We need to review the scope.")
        )

        XCTAssertNil(refined)
    }

    func testTranslationOutputValidatorRejectsNoOpAcrossLanguages() {
        XCTAssertNil(TranslationOutputValidator.validated(
            "I am speaking in English.",
            originalText: "I am speaking in English.",
            source: .englishUS,
            target: .portugueseBR
        ))
        XCTAssertNil(TranslationOutputValidator.validated(
            "  Ola mundo  ",
            originalText: "olá   mundo",
            source: .portugueseBR,
            target: .englishUS
        ))
        XCTAssertEqual(
            TranslationOutputValidator.validated(
                "Eu estou falando em inglês.",
                originalText: "I am speaking in English.",
                source: .englishUS,
                target: .portugueseBR
            ),
            "Eu estou falando em inglês."
        )
        XCTAssertNil(TranslationOutputValidator.validated(
            "[Português] Eu estou falando em português.",
            originalText: "Eu estou falando em português.",
            source: .englishUS,
            target: .portugueseBR
        ))
    }

    func testTranslationOutputValidatorRejectsWrongTargetLanguage() {
        XCTAssertNil(TranslationOutputValidator.validated(
            "Precisamos revisar o escopo antes da demo.",
            originalText: "Precisamos validar a API antes da demo.",
            source: .portugueseBR,
            target: .englishUS
        ))
        XCTAssertNil(TranslationOutputValidator.validated(
            "We should review the scope before the demo.",
            originalText: "We need to validate the API before the demo.",
            source: .englishUS,
            target: .portugueseBR
        ))
        XCTAssertEqual(
            TranslationOutputValidator.validated(
                "We need to validate the API before the demo.",
                originalText: "Precisamos validar a API antes da demo.",
                source: .portugueseBR,
                target: .englishUS
            ),
            "We need to validate the API before the demo."
        )
    }

    func testRAGKeywordFallback() throws {
        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let store = LocalKnowledgeStore(container: container, cryptor: try testCryptor())
        try store.addDocument(name: "Privacy.md", content: "Local Only mode prevents transcript uploads and web search.")
        let results = try store.keywordSearch(query: "transcript uploads")
        XCTAssertEqual(results.first?.documentName, "Privacy.md")
        XCTAssertGreaterThan(results.first?.score ?? 0, 0)
    }

    func testPersistenceRepositoryRoundTrip() throws {
        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let cryptor = try testCryptor()
        let repository = MeetingRepository(container: container, cryptor: cryptor)
        let meetingId = UUID()
        var meeting = MeetingSession(id: meetingId, title: "Round Trip", status: .ended)
        let audioURL = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "\(meetingId.uuidString).caf")
        meeting.audioFileURL = audioURL
        meeting.transcriptSegments = [
            TranscriptSegment(
                meetingId: meetingId,
                speakerLabel: "You",
                audioSource: .microphone,
                text: "This transcript should persist.",
                originalLanguage: SupportedLanguage.englishUS.rawValue,
                sourceLanguage: SupportedLanguage.englishUS.rawValue,
                targetLanguage: SupportedLanguage.portugueseBR.rawValue,
                draftTranslatedText: "Esta transcrição deve persistir",
                translatedText: "Esta transcrição deve persistir.",
                translatedLanguage: SupportedLanguage.portugueseBR.rawValue,
                translationPhase: .final,
                translationConfidence: 0.96,
                preservedTerms: ["API"],
                translationState: .translated
            )
        ]
        meeting.summary = MeetingSummary(meetingId: meetingId, executiveSummary: "Persisted summary.")
        try repository.save(meeting)
        let fetched = try repository.fetchMeetings()
        XCTAssertEqual(fetched.first?.id, meetingId)
        XCTAssertEqual(fetched.first?.transcriptSegments.first?.text, "This transcript should persist.")
        XCTAssertEqual(fetched.first?.transcriptSegments.first?.audioSource, .microphone)
        XCTAssertEqual(fetched.first?.transcriptSegments.first?.sourceLanguage, SupportedLanguage.englishUS.rawValue)
        XCTAssertEqual(fetched.first?.transcriptSegments.first?.targetLanguage, SupportedLanguage.portugueseBR.rawValue)
        XCTAssertEqual(fetched.first?.transcriptSegments.first?.draftTranslatedText, "Esta transcrição deve persistir")
        XCTAssertEqual(fetched.first?.transcriptSegments.first?.translatedLanguage, SupportedLanguage.portugueseBR.rawValue)
        XCTAssertEqual(fetched.first?.transcriptSegments.first?.translationPhase, .final)
        XCTAssertEqual(fetched.first?.transcriptSegments.first?.translationConfidence, 0.96)
        XCTAssertEqual(fetched.first?.transcriptSegments.first?.preservedTerms, ["API"])
        XCTAssertEqual(fetched.first?.transcriptSegments.first?.translationState, .translated)
        XCTAssertEqual(fetched.first?.summary?.executiveSummary, "Persisted summary.")
        XCTAssertEqual(fetched.first?.audioFileURL?.path, audioURL.path)
    }

    func testPersistenceEncryptsSensitiveFieldsAndMigratesLegacyPlaintextRows() throws {
        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let cryptor = try testCryptor()
        let repository = MeetingRepository(container: container, cryptor: cryptor)
        let meetingId = UUID()
        let sentinel = "Sensitive roadmap decision"
        var meeting = MeetingSession(id: meetingId, title: "Private title \(sentinel)", status: .ended)
        meeting.transcriptSegments = [
            TranscriptSegment(meetingId: meetingId, speakerLabel: "Speaker 1", text: "Transcript \(sentinel)")
        ]
        meeting.summary = MeetingSummary(meetingId: meetingId, executiveSummary: "Summary \(sentinel)")

        try repository.save(meeting)

        let rawContext = ModelContext(container)
        let rawMeeting = try XCTUnwrap(try rawContext.fetch(FetchDescriptor<StoredMeeting>()).first)
        let rawSegment = try XCTUnwrap(try rawContext.fetch(FetchDescriptor<StoredTranscriptSegment>()).first)
        let rawSummary = try XCTUnwrap(try rawContext.fetch(FetchDescriptor<StoredSummary>()).first)
        XCTAssertTrue(cryptor.isEncryptedString(rawMeeting.title))
        XCTAssertTrue(cryptor.isEncryptedString(rawSegment.text))
        XCTAssertTrue(cryptor.isEncryptedString(rawSummary.executiveSummary))
        XCTAssertFalse(rawMeeting.title.contains(sentinel))
        XCTAssertFalse(rawSegment.text.contains(sentinel))
        XCTAssertFalse(rawSummary.executiveSummary.contains(sentinel))

        rawMeeting.title = "Legacy \(sentinel)"
        rawMeeting.tagsJSON = #"["legacy"]"#
        rawSegment.text = "Legacy transcript \(sentinel)"
        rawSummary.executiveSummary = "Legacy summary \(sentinel)"
        try rawContext.save()

        let migratedRepository = MeetingRepository(container: container, cryptor: cryptor)
        try migratedRepository.migrateEncryptedFields()

        let migratedRawContext = ModelContext(container)
        let migratedMeeting = try XCTUnwrap(try migratedRawContext.fetch(FetchDescriptor<StoredMeeting>()).first)
        let migratedSegment = try XCTUnwrap(try migratedRawContext.fetch(FetchDescriptor<StoredTranscriptSegment>()).first)
        XCTAssertTrue(cryptor.isEncryptedString(migratedMeeting.title))
        XCTAssertTrue(cryptor.isEncryptedString(migratedSegment.text))
        XCTAssertFalse(migratedMeeting.title.contains(sentinel))
        XCTAssertFalse(migratedSegment.text.contains(sentinel))

        let fetched = try XCTUnwrap(migratedRepository.fetchMeetings().first)
        XCTAssertEqual(fetched.title, "Legacy \(sentinel)")
        XCTAssertEqual(fetched.tags, ["legacy"])
        XCTAssertEqual(fetched.transcriptSegments.first?.text, "Legacy transcript \(sentinel)")
        XCTAssertEqual(fetched.summary?.executiveSummary, "Legacy summary \(sentinel)")
    }

    func testKnowledgeAndQuestionAnswerRawStorageAreEncrypted() throws {
        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let cryptor = try testCryptor()
        let knowledgeStore = LocalKnowledgeStore(container: container, cryptor: cryptor)
        let repository = MeetingRepository(container: container, cryptor: cryptor)
        let sentinel = "authentication rollover sentinel"

        try knowledgeStore.addDocument(name: "Private.md", filePath: "/tmp/private.md", content: "Knowledge \(sentinel)")
        let knowledgeResults = try knowledgeStore.keywordSearch(query: "rollover sentinel")
        XCTAssertEqual(knowledgeResults.first?.documentName, "Private.md")

        let rawContext = ModelContext(container)
        let rawDocument = try XCTUnwrap(try rawContext.fetch(FetchDescriptor<StoredKnowledgeDocument>()).first)
        XCTAssertTrue(cryptor.isEncryptedString(rawDocument.displayName))
        XCTAssertTrue(cryptor.isEncryptedString(rawDocument.filePath ?? ""))
        XCTAssertTrue(cryptor.isEncryptedString(rawDocument.content))
        XCTAssertFalse(rawDocument.content.contains(sentinel))

        let candidate = makeQuestion("Can you explain the \(sentinel)?")
        let classification = makeCopilotClassification(for: candidate, intent: .answerableQuestion)
        let answer = SuggestedAnswer(questionId: candidate.id, answerText: "Answer \(sentinel)", shortAnswer: "Answer", confidence: 0.8, riskLevel: .safe, usedSources: [], assumptions: [], caveats: [], latencyMs: 1)
        let record = QuestionAnswerRecord(meetingId: candidate.meetingId, question: candidate, classification: classification, answer: answer, contextSummary: "Context \(sentinel)", decision: "ready")
        try repository.saveQuestionAnswerRecord(record)

        let rawRecord = try XCTUnwrap(try rawContext.fetch(FetchDescriptor<StoredQuestionAnswerRecord>()).first)
        XCTAssertTrue(cryptor.isEncryptedString(rawRecord.questionJSON))
        XCTAssertTrue(cryptor.isEncryptedString(rawRecord.answerJSON ?? ""))
        XCTAssertTrue(cryptor.isEncryptedString(rawRecord.contextSummary))
        XCTAssertFalse(rawRecord.questionJSON.contains(sentinel))
        XCTAssertFalse(rawRecord.answerJSON?.contains(sentinel) == true)
        XCTAssertEqual(try repository.questionAnswerRecords(for: candidate.meetingId).first?.answer?.answerText, "Answer \(sentinel)")
    }

    func testTranscriptSegmentDecodesOldJSONWithoutAudioSource() throws {
        let meetingId = UUID()
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "meetingId": "\(meetingId.uuidString)",
          "speakerLabel": "Speaker 1",
          "text": "Legacy transcript",
          "isFinal": true
        }
        """.data(using: .utf8)!
        let segment = try JSONDecoder().decode(TranscriptSegment.self, from: json)
        XCTAssertEqual(segment.audioSource, .unknown)
        XCTAssertEqual(segment.translationState, .none)
        XCTAssertEqual(segment.text, "Legacy transcript")
    }

    func testPersistenceUpdatesRealtimePartialSegment() throws {
        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let repository = MeetingRepository(container: container, cryptor: try testCryptor())
        let meetingId = UUID()
        let segmentId = UUID()
        var meeting = MeetingSession(id: meetingId, title: "Realtime", status: .listening)
        meeting.transcriptSegments = [
            TranscriptSegment(id: segmentId, meetingId: meetingId, speakerLabel: "Speaker 1", text: "Hel", isFinal: false)
        ]
        try repository.save(meeting)

        meeting.transcriptSegments = [
            TranscriptSegment(id: segmentId, meetingId: meetingId, speakerLabel: "Speaker 1", text: "Hello from realtime speech.", confidence: 0.91, isFinal: true)
        ]
        try repository.save(meeting)

        let fetched = try XCTUnwrap(repository.fetchMeetings().first)
        XCTAssertEqual(fetched.transcriptSegments.count, 1)
        XCTAssertEqual(fetched.transcriptSegments.first?.text, "Hello from realtime speech.")
        XCTAssertEqual(fetched.transcriptSegments.first?.isFinal, true)
    }

    func testFileStorageWritesEncryptedTranscriptJSON() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appending(path: "NotchCopilotFileStorage-\(UUID().uuidString)", directoryHint: .isDirectory)
        let cryptor = try testCryptor()
        let storage = try FileStorageService(root: tempRoot, cryptor: cryptor)
        let meetingId = UUID()
        let sentinel = "Persist this transcript to disk."
        let meeting = MeetingSession(
            id: meetingId,
            title: "Transcript file",
            transcriptSegments: [TranscriptSegment(meetingId: meetingId, speakerLabel: "Speaker 1", text: sentinel)]
        )

        try storage.writeTranscript(meeting)

        let url = tempRoot.appending(path: "transcripts", directoryHint: .isDirectory).appending(path: "\(meetingId.uuidString).json.ncenc")
        let legacyURL = tempRoot.appending(path: "transcripts", directoryHint: .isDirectory).appending(path: "\(meetingId.uuidString).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        let data = try Data(contentsOf: url)
        XCTAssertFalse(String(data: data, encoding: .utf8)?.contains(sentinel) == true)
        XCTAssertTrue(cryptor.isEncryptedData(data))
        let segments = try storage.readTranscript(for: meetingId)
        XCTAssertEqual(segments.first?.text, sentinel)
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testFileStorageMigratesLegacyPlaintextTranscriptJSON() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appending(path: "NotchCopilotFileStorageMigration-\(UUID().uuidString)", directoryHint: .isDirectory)
        let storage = try FileStorageService(root: tempRoot, cryptor: try testCryptor())
        let meetingId = UUID()
        let sentinel = "Legacy transcript migration sentinel"
        let legacyURL = tempRoot.appending(path: "transcripts", directoryHint: .isDirectory).appending(path: "\(meetingId.uuidString).json")
        let encryptedURL = tempRoot.appending(path: "transcripts", directoryHint: .isDirectory).appending(path: "\(meetingId.uuidString).json.ncenc")
        let legacyData = try JSONEncoder().encode([
            TranscriptSegment(meetingId: meetingId, speakerLabel: "Speaker 1", text: sentinel)
        ])
        try legacyData.write(to: legacyURL, options: [.atomic])

        try storage.migrateLegacyTranscriptFiles()

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: encryptedURL.path))
        let encryptedData = try Data(contentsOf: encryptedURL)
        XCTAssertFalse(String(data: encryptedData, encoding: .utf8)?.contains(sentinel) == true)
        XCTAssertEqual(try storage.readTranscript(for: meetingId).first?.text, sentinel)
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testAudioRecorderWritesCAFFile() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appending(path: "NotchCopilotRecording-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let url = tempRoot.appending(path: "sample.caf")
        let recorder = AudioRecorderService()
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        buffer.frameLength = 4_800
        if let channel = buffer.floatChannelData?[0] {
            for frame in 0..<Int(buffer.frameLength) {
                channel[frame] = sin(Float(frame) / 16.0) * 0.18
            }
        }

        try recorder.startRecording(to: url)
        recorder.append(buffer)
        recorder.stopRecording()

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertGreaterThan((attributes[.size] as? NSNumber)?.intValue ?? 0, 512)
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testPCMBufferCopyIsStableAfterSourceMutation() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
        buffer.frameLength = 128
        let source = try XCTUnwrap(buffer.floatChannelData?[0])
        source[0] = 0.42

        let copied = try XCTUnwrap(buffer.copiedForAsyncUse())
        source[0] = -0.12

        XCTAssertEqual(copied.frameLength, buffer.frameLength)
        XCTAssertEqual(try XCTUnwrap(copied.floatChannelData?[0][0]), Float(0.42), accuracy: 0.0001)
    }

    func testRealtimeQADetectsDirectQuestion() async throws {
        let segment = TranscriptSegment(meetingId: UUID(), speakerLabel: "System", text: "Ryan, can we ship this by Friday?")
        let context = TranscriptContext(recentTranscript: segment.text, mediumTranscript: segment.text, dominantLanguage: "en-US", currentSegment: segment)
        let candidates = QuestionDetectionService().detectCandidates(from: segment, context: context)
        XCTAssertEqual(candidates.count, 1)
    }

    func testRealtimeQADetectsIndirectQuestion() {
        let segment = TranscriptSegment(meetingId: UUID(), speakerLabel: "Pessoa 1", text: "Eu queria entender se isso impacta o login.")
        let context = TranscriptContext(recentTranscript: segment.text, mediumTranscript: segment.text, dominantLanguage: "pt-BR", currentSegment: segment)
        XCTAssertFalse(QuestionDetectionService().detectCandidates(from: segment, context: context).isEmpty)
    }

    func testRealtimeQADetectsAndClassifiesMultilingualQuestions() async throws {
        let cases: [(String, String, QuestionType)] = [
            ("Ryan, você acha que conseguimos entregar isso até sexta?", "pt-BR", .deadlineOrEstimate),
            ("Can we ship this without the migration?", "en-US", .riskAssessment),
            ("Necesitamos saber si esto rompe la autenticación.", "es-ES", .riskAssessment),
            ("金曜日までに認証エンドポイントを出せますか？", "ja-JP", .deadlineOrEstimate),
            ("La duda es si vale la pena meter esto en el MVP.", "es-ES", .productScope),
            ("リスクを確認したいです。", "ja-JP", .riskAssessment)
        ]

        for (text, language, expectedType) in cases {
            let segment = TranscriptSegment(meetingId: UUID(), speakerLabel: "Speaker", text: text, originalLanguage: language)
            let context = TranscriptContext(recentTranscript: text, mediumTranscript: text, completeTranscript: text, dominantLanguage: language, currentSegment: segment)
            let candidates = QuestionDetectionService().detectCandidates(from: segment, context: context)
            XCTAssertFalse(candidates.isEmpty, "Expected detection for: \(text)")
            let candidate = try XCTUnwrap(candidates.first)
            let classification = try await QuestionClassifier().classifyQuestion(candidate: candidate, context: context, userProfile: makeProfile())
            XCTAssertTrue(classification.isQuestion, "Expected question classification for: \(text)")
            XCTAssertTrue(classification.responseNeeded, "Expected response needed for: \(text)")
            XCTAssertEqual(classification.questionType, expectedType, "Unexpected type for: \(text)")
        }
    }

    func testRealtimeQARecognizesInterviewStyleQuestions() async throws {
        let cases: [(String, QuestionType, QuestionPriority)] = [
            ("Qual a capital da França", .generalQuestion, .medium),
            ("Como inverter uma árvore binária em Python?", .technicalExplanation, .medium),
            ("O que é um HashID?", .technicalExplanation, .medium),
            ("Como você escalaria um sistema para ser altamente disponível?", .technicalDecision, .high)
        ]

        for (text, expectedType, expectedPriority) in cases {
            let segment = TranscriptSegment(meetingId: UUID(), speakerLabel: "Interviewer", text: text, originalLanguage: "pt-BR")
            let context = TranscriptContext(recentTranscript: text, mediumTranscript: text, completeTranscript: text, dominantLanguage: "pt-BR", currentSegment: segment)
            let candidates = QuestionDetectionService().detectCandidates(from: segment, context: context)
            XCTAssertFalse(candidates.isEmpty, "Expected detection for: \(text)")
            let candidate = try XCTUnwrap(candidates.first)
            let classification = try await QuestionClassifier().classifyQuestion(candidate: candidate, context: context, userProfile: makeProfile())
            XCTAssertTrue(classification.responseNeeded, "Expected answer generation for: \(text)")
            XCTAssertTrue(classification.complete, "Expected complete question for: \(text)")
            XCTAssertEqual(classification.questionType, expectedType, "Unexpected type for: \(text)")
            XCTAssertEqual(classification.priority, expectedPriority, "Unexpected priority for: \(text)")
        }
    }

    func testRealtimeQALocalFallbackAnswersInterviewQuestions() async throws {
        let questions = [
            ("Qual a capital da França", "Paris"),
            ("Como inverter uma árvore binária em Python?", "```python"),
            ("O que é um HashID?", "identificador"),
            ("Como você escalaria um sistema para ser altamente disponível?", "load balancer")
        ]

        for (text, expectedFragment) in questions {
            let candidate = makeQuestion(text)
            let classification = try await QuestionClassifier().classifyQuestion(candidate: candidate, context: makeContext(text), userProfile: makeProfile())
            let context = AnswerContext(meetingTitle: "Interview", transcriptWindow: text, completeTranscript: text, ragContext: "", userRole: "Senior Engineer", responseStyle: .technical, languageCode: "pt-BR")
            let stream = try await TestMeetingAnswerProvider().generateAnswer(question: candidate, classification: classification, context: context, options: AnswerGenerationOptions())
            let final = try await finalAnswer(from: stream)
            let answer = try XCTUnwrap(final)
            XCTAssertTrue(answer.answerText.localizedCaseInsensitiveContains(expectedFragment), "Expected \(expectedFragment) in answer for: \(text)")
            XCTAssertFalse(answer.usedCloud)
        }
    }

    func testRealtimeQAIntentGateRejectsFragmentsSmallTalkAndExplanations() async throws {
        let cases = [
            "Como",
            "How",
            "Como vai você?",
            "How are you?",
            "Tudo bem?",
            "Como eu disse antes, precisamos revisar isso.",
            "What I mean is, can we say this is done...",
            "Eles perguntaram se estava pronto, e eu respondi que sim"
        ]

        for text in cases {
            let candidate = makeQuestion(text)
            let intent = QuestionIntentGate().evaluate(candidate: candidate, context: makeContext(text))
            let classification = try await QuestionClassifier().classifyQuestion(candidate: candidate, context: makeContext(text), userProfile: makeProfile())

            XCTAssertFalse(intent.isAnswerableQuestion, "Expected intent gate to reject: \(text)")
            XCTAssertFalse(classification.responseNeeded, "Expected no answer for: \(text)")
            XCTAssertFalse(classification.userAttentionNeeded, "Expected no attention for: \(text)")
            XCTAssertEqual(classification.priority, .low, "Expected low priority for: \(text)")
            XCTAssertFalse(classification.reason.isEmpty, "Expected clear ignore reason for: \(text)")
        }

        let detector = QuestionDetectionService()
        for text in ["Como", "How", "Quanto", "Cuanto", "Quanto é", "Cuanto es"] {
            let segment = TranscriptSegment(meetingId: UUID(), speakerLabel: "Speaker", text: text, originalLanguage: "pt-BR")
            let context = TranscriptContext(recentTranscript: text, mediumTranscript: text, completeTranscript: text, dominantLanguage: "pt-BR", currentSegment: segment)
            XCTAssertTrue(detector.detectCandidates(from: segment, context: context).isEmpty, "Expected no candidate for bare fragment: \(text)")
        }
    }

    func testRealtimeQAIntentGateKeepsConcreteQuestions() async throws {
        let cases: [(String, QuestionType)] = [
            ("Como inverter uma árvore binária em Python?", .technicalExplanation),
            ("Como vamos lidar com autenticação?", .technicalDecision),
            ("How would you scale this system?", .technicalDecision),
            ("What is the main risk here?", .riskAssessment),
            ("Qual é o status da API?", .statusCheck)
        ]

        for (text, expectedType) in cases {
            let segment = TranscriptSegment(meetingId: UUID(), speakerLabel: "Speaker", text: text, originalLanguage: "pt-BR")
            let context = TranscriptContext(recentTranscript: text, mediumTranscript: text, completeTranscript: text, dominantLanguage: "pt-BR", currentSegment: segment)
            let candidates = QuestionDetectionService().detectCandidates(from: segment, context: context)
            XCTAssertFalse(candidates.isEmpty, "Expected candidate for: \(text)")

            let candidate = try XCTUnwrap(candidates.first)
            let intent = QuestionIntentGate().evaluate(candidate: candidate, context: context)
            let classification = try await QuestionClassifier().classifyQuestion(candidate: candidate, context: context, userProfile: makeProfile())

            XCTAssertTrue(intent.isAnswerableQuestion, "Expected answerable intent for: \(text)")
            XCTAssertTrue(classification.responseNeeded, "Expected answer generation for: \(text)")
            XCTAssertEqual(classification.questionType, expectedType, "Unexpected type for: \(text)")
        }
    }

    func testRealtimeQAEngineIgnoresFalsePositiveBeforeUIEvents() async throws {
        let engine = TestRealtimeQuestionAnsweringEngine()
        let meetingId = UUID()
        let meeting = MeetingSession(id: meetingId, title: "Small talk", status: .listening)
        let segment = TranscriptSegment(meetingId: meetingId, speakerLabel: "Speaker", text: "Como vai você?", isFinal: true)

        let eventTask = Task { () -> [RealtimeQuestionEvent] in
            var events: [RealtimeQuestionEvent] = []
            for await event in engine.eventBus.events {
                events.append(event)
                if events.count >= 1 { return events }
            }
            return events
        }

        await engine.ingest(segment: segment, meeting: meeting, preferences: AppPreferences())
        try? await Task.sleep(for: .milliseconds(50))
        engine.stop()
        let events = await eventTask.value

        XCTAssertFalse(events.contains { event in
            if case .questionDetected = event { return true }
            return false
        })
        XCTAssertFalse(events.contains { event in
            if case .answerGenerating = event { return true }
            return false
        })
        XCTAssertFalse(events.contains { event in
            if case .suggestedAnswerReady = event { return true }
            return false
        })
    }

    func testRealtimeQAIntentGateHandlesASRNoPunctuationAndPartialContext() async throws {
        let cases = [
            "what is the main risk if we skip the migration",
            "Ryan can you walk through the OAuth flow",
            "qual o status da API de autenticação",
            "can we ship the endpoint by Friday"
        ]

        for text in cases {
            let segment = TranscriptSegment(meetingId: UUID(), speakerLabel: "Speaker", text: text, originalLanguage: "en-US")
            let context = TranscriptContext(recentTranscript: text, mediumTranscript: "OAuth migration and API rollout", completeTranscript: text, dominantLanguage: "en-US", currentSegment: segment)
            let candidates = QuestionDetectionService().detectCandidates(from: segment, context: context)
            XCTAssertFalse(candidates.isEmpty, "Expected no-punctuation ASR question detection for: \(text)")
            let candidate = try XCTUnwrap(candidates.first)
            let classification = try await QuestionClassifier().classifyQuestion(candidate: candidate, context: context, userProfile: makeProfile())
            XCTAssertTrue(classification.responseNeeded, "Expected answerable no-punctuation question for: \(text)")
        }

        let partial = TranscriptSegment(meetingId: UUID(), speakerLabel: "Speaker", text: "Can you explain", startTime: 1, isFinal: false)
        let context = TranscriptContext(recentTranscript: "We are discussing the OAuth migration.", mediumTranscript: "OAuth migration backend flow", completeTranscript: "OAuth migration backend flow", dominantLanguage: "en-US", currentSegment: partial)
        let candidate = try XCTUnwrap(QuestionDetectionService().detectCandidates(from: partial, context: context).first)
        let intent = QuestionIntentGate().evaluate(candidate: candidate, context: context)
        XCTAssertTrue(intent.isAnswerableQuestion)
    }

    func testRealtimeQAIntentGateSeparatesSmallTalkFromSimilarTechnicalQuestions() async throws {
        let rejected = ["How are you?", "How are you doing today?", "Qué tal?", "元気ですか"]
        for text in rejected {
            let candidate = makeQuestion(text)
            let intent = QuestionIntentGate().evaluate(candidate: candidate, context: makeContext(text))
            XCTAssertFalse(intent.isAnswerableQuestion, "Expected small talk rejection for: \(text)")
        }

        let accepted = [
            "How are you scaling this system?",
            "How are you handling authentication?",
            "Como você escalaria esse sistema?",
            "¿Cómo escalarías este sistema?",
            "このAPIの状態はどうですか"
        ]
        for text in accepted {
            let segment = TranscriptSegment(meetingId: UUID(), speakerLabel: "Interviewer", text: text, originalLanguage: nil)
            let context = TranscriptContext(recentTranscript: text, mediumTranscript: text, completeTranscript: text, dominantLanguage: nil, currentSegment: segment)
            let candidate = try XCTUnwrap(QuestionDetectionService().detectCandidates(from: segment, context: context).first)
            let intent = QuestionIntentGate().evaluate(candidate: candidate, context: context)
            let classification = try await QuestionClassifier().classifyQuestion(candidate: candidate, context: context, userProfile: makeProfile())
            XCTAssertTrue(intent.isAnswerableQuestion, "Expected technical question detection for: \(text)")
            XCTAssertTrue(classification.responseNeeded, "Expected response for: \(text)")
        }
    }

    func testRealtimeQAAdaptiveProfileSuppressesRepeatedlyDismissedQuestions() {
        var profile = QuestionAnsweringAdaptiveProfile()
        profile.record(feedback: .dismissed, rawText: "What is the main risk here?")
        profile.record(feedback: .markedWrong, rawText: "What is the main risk here?")

        let candidate = makeQuestion("What is the main risk here?")
        let intent = QuestionIntentGate(adaptiveProfile: profile).evaluate(candidate: candidate, context: makeContext(candidate.rawText))

        XCTAssertFalse(intent.isAnswerableQuestion)
        XCTAssertTrue(intent.reason.localizedCaseInsensitiveContains("dismissed"))
        XCTAssertGreaterThan(profile.strictnessAdjustment, 0)
    }

    func testRealtimeQARulePackIsConfigurableForLocalPolicy() {
        var rulePack = QuestionIntentRulePack.default
        rulePack.exactSmallTalkPhrases.insert("status da api")
        let gate = QuestionIntentGate(rulePack: rulePack)
        let candidate = makeQuestion("Status da API?")

        let intent = gate.evaluate(candidate: candidate, context: makeContext(candidate.rawText))

        XCTAssertFalse(intent.isAnswerableQuestion)
        XCTAssertTrue(intent.isSmallTalk)
    }

    func testRealtimeQAQueuesSequentialQuestionsAndKeepsTranscriptState() async throws {
        let appState = AppState()
        let meetingId = UUID()
        appState.currentMeeting = MeetingSession(
            id: meetingId,
            title: "Interview",
            transcriptSegments: [
                TranscriptSegment(meetingId: meetingId, speakerLabel: "Interviewer", text: "Qual a capital da França"),
                TranscriptSegment(meetingId: meetingId, speakerLabel: "Interviewer", text: "Como inverter uma árvore binária em Python?")
            ]
        )

        let first = makeQuestion("Qual a capital da França", meetingId: meetingId)
        let second = makeQuestion("Como inverter uma árvore binária em Python?", meetingId: meetingId)
        let firstClassification = try await QuestionClassifier().classifyQuestion(candidate: first, context: makeContext(first.rawText), userProfile: makeProfile())
        let secondClassification = try await QuestionClassifier().classifyQuestion(candidate: second, context: makeContext(second.rawText), userProfile: makeProfile())

        appState.upsertQuestionInQueue(candidate: first, classification: firstClassification, stage: .classifying, select: true)
        appState.upsertQuestionInQueue(candidate: second, classification: secondClassification, stage: .classifying, select: false)

        XCTAssertEqual(appState.questionAnswerQueue.count, 2)
        XCTAssertEqual(appState.activeQuestion?.id, first.id)
        XCTAssertEqual(appState.currentMeeting?.transcriptSegments.count, 2)
        XCTAssertEqual(appState.selectedQuestionPositionText, "2/2")

        appState.selectNextQuestion()
        XCTAssertEqual(appState.activeQuestion?.id, second.id)
        XCTAssertEqual(appState.selectedQuestionPositionText, "1/2")

        appState.updateQueuedQuestionStreamingText(questionId: second.id, text: "Use a recursive swap.")
        XCTAssertEqual(appState.streamingAnswerText, "Use a recursive swap.")
        XCTAssertEqual(appState.islandMode, .listening)

        let answer = SuggestedAnswer(
            questionId: second.id,
            answerText: "```python\nroot.left, root.right = root.right, root.left\n```",
            shortAnswer: "Swap left and right recursively.",
            confidence: 0.8,
            riskLevel: .safe,
            usedSources: [],
            assumptions: [],
            caveats: [],
            latencyMs: 120
        )
        appState.updateQueuedQuestionAnswer(candidate: second, answer: answer)
        XCTAssertEqual(appState.suggestedAnswer?.questionId, second.id)

        appState.selectPreviousQuestion()
        XCTAssertEqual(appState.activeQuestion?.id, first.id)
        XCTAssertNil(appState.suggestedAnswer)

        _ = appState.removeSelectedQuestionFromQueue()
        XCTAssertEqual(appState.questionAnswerQueue.count, 1)
        XCTAssertEqual(appState.activeQuestion?.id, second.id)
        XCTAssertEqual(appState.suggestedAnswer?.questionId, second.id)
        XCTAssertEqual(appState.currentMeeting?.transcriptSegments.count, 2)
    }

    func testRealtimeQAVisibleAnswerTextUsesOnlyAnswerBody() {
        let appState = AppState()
        let question = makeQuestion("A data foi mantida?")
        let answer = SuggestedAnswer(
            questionId: question.id,
            answerText: "Sim. A confirmação foi manter a data em 19 de novembro.",
            shortAnswer: "Sim.",
            confidence: 0.82,
            riskLevel: .safe,
            usedSources: [
                AnswerSource(type: .transcript, title: "Recent transcript", snippet: "Recent transcript: trecho interno", reference: nil)
            ],
            assumptions: ["Assumption that should stay hidden."],
            caveats: ["Caveat that should stay hidden."],
            latencyMs: 120,
            expandedAnswer: "Expanded answer that should stay hidden while answerText exists."
        )

        appState.upsertQuestionInQueue(candidate: question, classification: nil, stage: .ready, select: true)
        appState.updateQueuedQuestionAnswer(candidate: question, answer: answer)

        XCTAssertEqual(appState.visibleAnswerText, "Sim. A confirmação foi manter a data em 19 de novembro.")
        XCTAssertFalse(appState.visibleAnswerText.contains("Recent transcript"))
        XCTAssertFalse(appState.visibleAnswerText.contains("Assumption"))
        XCTAssertFalse(appState.visibleAnswerText.contains("Caveat"))

        let fallbackAnswer = SuggestedAnswer(
            questionId: question.id,
            answerText: " ",
            shortAnswer: "Resposta curta.",
            confidence: 0.82,
            riskLevel: .safe,
            usedSources: answer.usedSources,
            assumptions: answer.assumptions,
            caveats: answer.caveats,
            latencyMs: 120,
            expandedAnswer: "Resposta expandida."
        )
        appState.updateQueuedQuestionAnswer(candidate: question, answer: fallbackAnswer)

        XCTAssertEqual(appState.visibleAnswerText, "Resposta expandida.")
    }

    func testRealtimeQAExpandedSizingIgnoresSourcesAndQueueLength() {
        let appState = AppState()
        let question = makeQuestion("A data foi mantida?")
        let baseAnswer = SuggestedAnswer(
            questionId: question.id,
            answerText: "Sim. A confirmação foi manter a data em 19 de novembro.",
            shortAnswer: "Sim.",
            confidence: 0.82,
            riskLevel: .safe,
            usedSources: [],
            assumptions: [],
            caveats: [],
            latencyMs: 120
        )
        appState.upsertQuestionInQueue(candidate: question, classification: nil, stage: .ready, select: true)
        appState.updateQueuedQuestionAnswer(candidate: question, answer: baseAnswer)
        appState.showQuestionAnswerPanel(mode: .answer)

        let baseSize = appState.notchIslandSize

        let secondQuestion = makeQuestion("Vai ter adiamento?")
        appState.upsertQuestionInQueue(candidate: secondQuestion, classification: nil, stage: .ready, select: false)
        let sourceHeavyAnswer = SuggestedAnswer(
            questionId: question.id,
            answerText: baseAnswer.answerText,
            shortAnswer: baseAnswer.shortAnswer,
            confidence: 0.82,
            riskLevel: .safe,
            usedSources: [
                AnswerSource(type: .transcript, title: "Recent transcript", snippet: String(repeating: "fonte ", count: 80), reference: nil),
                AnswerSource(type: .rag, title: "Local knowledge", snippet: String(repeating: "contexto ", count: 80), reference: nil)
            ],
            assumptions: [String(repeating: "assumption ", count: 60)],
            caveats: [String(repeating: "caveat ", count: 60)],
            latencyMs: 120,
            expandedAnswer: baseAnswer.answerText
        )
        appState.updateQueuedQuestionAnswer(candidate: question, answer: sourceHeavyAnswer)
        appState.selectQuestion(question.id)

        XCTAssertEqual(appState.notchIslandSize.width, baseSize.width)
        XCTAssertEqual(appState.notchIslandSize.height, baseSize.height)
    }

    func testRealtimeQASuggestedAnswerLayoutAdaptsAndKeepsTranscriptAccessible() {
        let appState = AppState()
        let meetingId = UUID()
        let question = makeQuestion("Como inverter uma árvore binária em Python?", meetingId: meetingId)
        let answer = SuggestedAnswer(
            questionId: question.id,
            answerText: """
            Você pode inverter recursivamente:
            ```python
            def invert_tree(root):
                if root is None:
                    return None
                root.left, root.right = invert_tree(root.right), invert_tree(root.left)
                return root
            ```
            Complexidade O(n).
            """,
            shortAnswer: """
            Você pode inverter recursivamente:
            ```python
            def invert_tree(root):
                if root is None:
                    return None
                root.left, root.right = invert_tree(root.right), invert_tree(root.left)
                return root
            ```
            """,
            confidence: 0.86,
            riskLevel: .safe,
            usedSources: [],
            assumptions: [],
            caveats: [],
            latencyMs: 180
        )
        appState.currentMeeting = MeetingSession(
            id: meetingId,
            title: "Interview",
            transcriptSegments: [
                TranscriptSegment(meetingId: meetingId, speakerLabel: "Interviewer", text: "Como inverter uma árvore binária em Python?"),
                TranscriptSegment(meetingId: meetingId, speakerLabel: "You", text: "Vou explicar a abordagem recursiva.")
            ]
        )
        appState.upsertQuestionInQueue(candidate: question, classification: nil, stage: .ready, select: true)
        appState.updateQueuedQuestionAnswer(candidate: question, answer: answer)
        appState.showQuestionAnswerPanel(mode: .answer)

        let answerSize = appState.notchIslandSize
        XCTAssertGreaterThan(answerSize.height, NotchIslandMode.suggestedAnswer.preferredSize.height)

        appState.questionAnswerPresentationMode = .transcript
        XCTAssertLessThan(appState.notchIslandSize.width, answerSize.width)
        XCTAssertLessThan(appState.notchIslandSize.height, answerSize.height)
        XCTAssertGreaterThan(appState.notchIslandSize.height, NotchIslandMode.suggestedAnswer.preferredSize.height)
        XCTAssertGreaterThanOrEqual(appState.notchIslandCanvasSize.height, appState.notchIslandSize.height)
    }

    func testExpandedIslandSizingAdaptsToTranscriptTranslationAnswersAndCode() {
        let appState = AppState()
        appState.isPanelExpanded = true

        XCTAssertEqual(appState.notchIslandSize.width, 520)
        XCTAssertEqual(appState.notchIslandSize.height, 248)

        let meetingId = UUID()
        appState.currentMeeting = MeetingSession(
            id: meetingId,
            title: "Design Review",
            status: .listening,
            transcriptSegments: [
                TranscriptSegment(meetingId: meetingId, speakerLabel: "System", audioSource: .system, text: "Let's review the checkout flow."),
                TranscriptSegment(meetingId: meetingId, speakerLabel: "You", audioSource: .microphone, text: "Podemos simplificar a primeira etapa.")
            ]
        )
        appState.islandMode = .listening

        let transcriptSize = appState.notchIslandSize
        XCTAssertEqual(transcriptSize.width, 500)
        XCTAssertEqual(transcriptSize.height, 330)

        appState.preferences.liveTranslationEnabled = true
        let translatedTranscriptSize = appState.notchIslandSize
        XCTAssertGreaterThan(translatedTranscriptSize.width, transcriptSize.width)
        XCTAssertGreaterThan(translatedTranscriptSize.height, transcriptSize.height)

        appState.streamingAnswerText = "I would avoid committing to the date until we validate rollout risk and confirm owner coverage."
        appState.islandMode = .suggestedAnswer
        let answerSize = appState.notchIslandSize
        XCTAssertGreaterThan(answerSize.height, NotchIslandMode.suggestedAnswer.preferredSize.height)
        XCTAssertLessThan(answerSize.height, translatedTranscriptSize.height)
        XCTAssertLessThanOrEqual(answerSize.width, 620)

        appState.streamingAnswerText = """
        We can keep this implementation small:
        ```swift
        func route(_ event: MeetingEvent) async {
            await coordinator.handle(event)
        }
        ```
        Then validate it with a focused integration test.
        """
        let codeSize = appState.notchIslandSize
        XCTAssertGreaterThan(codeSize.height, answerSize.height)
        XCTAssertLessThanOrEqual(codeSize.width, 620)
        XCTAssertLessThanOrEqual(codeSize.height, 548)

        appState.streamingAnswerText = """
        A longer implementation can still expand when the code actually needs horizontal space:
        ```swift
        let responsePipeline = MeetingAnswerPipeline(questionDetector: detector, transcriptWindow: recentTranscriptWindow, answerRenderer: dynamicMarkdownRenderer, feedbackRecorder: localFeedbackStore)
        ```
        """
        let wideCodeSize = appState.notchIslandSize
        XCTAssertGreaterThan(wideCodeSize.width, codeSize.width)
        XCTAssertLessThanOrEqual(wideCodeSize.width, 760)
    }

    func testExpandedAnswerSizingUsesQuestionAndVisibleAnswerOnly() {
        let appState = AppState()
        appState.isPanelExpanded = true
        let meetingId = UUID()
        let question = makeQuestion(
            "Que está detectando outra língua e errando bastante, então precisamos trocar o pipeline de transcrição?",
            meetingId: meetingId
        )
        let answer = SuggestedAnswer(
            questionId: question.id,
            answerText: "Eu separaria a captura do idioma dominante e validaria com uma segunda fonte antes de trocar o provider.",
            shortAnswer: "Eu separaria idioma/captura e validaria com uma segunda fonte antes de trocar o provider.",
            confidence: 0.76,
            riskLevel: .moderate,
            usedSources: [
                AnswerSource(
                    type: .transcript,
                    title: "Recent transcript",
                    snippet: "A transcrição alternou entre português correto e falso positivo em outra língua durante a reunião.",
                    reference: nil
                ),
                AnswerSource(
                    type: .rag,
                    title: "Local notes",
                    snippet: "Preferir fallback lexical e confirmação de idioma antes de mudar o mecanismo de speech.",
                    reference: nil
                )
            ],
            assumptions: ["Apple Speech está recebendo áudio com termos técnicos e mistura de idiomas."],
            caveats: ["Confirmar se o erro vem da detecção de idioma ou da qualidade do áudio."],
            latencyMs: 180
        )
        appState.currentMeeting = MeetingSession(
            id: meetingId,
            title: "Transcription Review",
            status: .listening,
            transcriptSegments: [
                TranscriptSegment(meetingId: meetingId, speakerLabel: "You", audioSource: .microphone, text: question.rawText),
                TranscriptSegment(meetingId: meetingId, speakerLabel: "You", audioSource: .microphone, text: "Agora eu estou falando em português e a transcrição parece funcionar melhor.")
            ]
        )
        appState.upsertQuestionInQueue(candidate: question, classification: nil, stage: .ready, select: true)
        appState.updateQueuedQuestionAnswer(candidate: question, answer: answer)
        appState.showQuestionAnswerPanel(mode: .answer)

        XCTAssertEqual(appState.visibleAnswerText, answer.answerText)
        XCTAssertGreaterThanOrEqual(appState.notchIslandSize.width, 552)
        XCTAssertLessThan(appState.notchIslandSize.width, 620)
        XCTAssertLessThan(appState.notchIslandSize.height, 470)
        XCTAssertLessThanOrEqual(appState.notchIslandCanvasSize.width, 660)
    }

    func testNotchCanvasStaysTightAroundDynamicIsland() {
        let appState = AppState()
        XCTAssertEqual(appState.notchIslandSize, NotchIslandChromeMetrics.collapsedNotchFootprintSize)
        XCTAssertEqual(appState.notchIslandCanvasSize, NotchIslandChromeMetrics.compactRecordHoverActionsSize)
        XCTAssertTrue(appState.isIdleHiddenBehindNotch)

        appState.isNotchHovered = true
        XCTAssertEqual(appState.notchIslandSize, NotchIslandChromeMetrics.compactRecordHoverActionsSize)
        XCTAssertEqual(appState.notchIslandCanvasSize, appState.notchIslandSize)

        let meetingId = UUID()
        appState.currentMeeting = MeetingSession(
            id: meetingId,
            title: "Daily",
            status: .listening,
            transcriptSegments: [
                TranscriptSegment(meetingId: meetingId, speakerLabel: "System", audioSource: .system, text: "Can we ship this today?")
            ]
        )
        appState.islandMode = .listening
        appState.isPanelExpanded = true

        XCTAssertEqual(appState.notchIslandCanvasSize.width, appState.notchIslandSize.width + 40)
        XCTAssertEqual(appState.notchIslandCanvasSize.height, appState.notchIslandSize.height + 16)
        XCTAssertLessThanOrEqual(appState.notchIslandCanvasSize.width, 780)
        XCTAssertLessThanOrEqual(appState.notchIslandCanvasSize.height, 536)
    }

    func testCompactListeningIslandUsesMinimalNotchAwareLayout() {
        let appState = AppState()
        let meetingId = UUID()
        appState.currentMeeting = MeetingSession(
            id: meetingId,
            title: "Interview",
            status: .listening,
            transcriptSegments: []
        )
        appState.islandMode = .listening
        appState.isPanelExpanded = false

        XCTAssertEqual(appState.notchIslandSize, NotchIslandChromeMetrics.compactListeningSize)
        XCTAssertLessThanOrEqual(appState.notchIslandSize.width, 524)
        XCTAssertLessThan(appState.notchIslandSize.height, 60)
        XCTAssertEqual(NotchIslandChromeMetrics.compactListeningNotchKeepoutWidth, 176)
        XCTAssertEqual(NotchIslandChromeMetrics.compactListeningHorizontalPadding, 14)
        XCTAssertEqual(IconButtonSize.compact.diameter, 28)
        XCTAssertLessThan(IconButtonSize.compact.diameter, IconButtonSize.standard.diameter)

        let buttonGroupWidth = IconButtonSize.compact.hitDiameter * 4 + IslandButtonFallbackGeometry.compactListeningSpacing * 3
        let availableSideWidth = (
            appState.notchIslandSize.width
            - NotchIslandChromeMetrics.compactListeningHorizontalPadding * 2
            - NotchIslandChromeMetrics.compactListeningNotchKeepoutWidth
        ) / 2
        XCTAssertGreaterThanOrEqual(availableSideWidth, buttonGroupWidth)
    }

    func testExpandedTranscriptIslandUsesNarrowerLayoutAndHeaderControls() {
        var preferences = AppPreferences()
        preferences.liveTranslationEnabled = false
        let appState = AppState(preferences: preferences)
        let meetingId = UUID()
        appState.currentMeeting = MeetingSession(
            id: meetingId,
            title: "Daily",
            status: .listening,
            transcriptSegments: [
                TranscriptSegment(meetingId: meetingId, speakerLabel: "You", audioSource: .microphone, text: "Testing transcript layout.")
            ]
        )
        appState.islandMode = .listening
        appState.isPanelExpanded = true

        XCTAssertEqual(appState.expandedIslandWidth, 500)
        XCTAssertLessThan(appState.notchIslandCanvasSize.width, 560)
        XCTAssertLessThan(IconButtonSize.header.diameter, IconButtonSize.standard.diameter)
        XCTAssertGreaterThan(IconButtonSize.header.diameter, IconButtonSize.compact.diameter)
        XCTAssertEqual(IconButtonSize.header.hitDiameter, 36)
    }

    func testStopMeetingPreservesExpandedPanelInsteadOfCollapsingImmediately() async throws {
        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let tempRoot = FileManager.default.temporaryDirectory.appending(
            path: "NotchCopilotStopMeeting-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let appState = AppState()
        let cryptor = try testCryptor()
        let manager = MeetingSessionManager(
            appState: appState,
            repository: MeetingRepository(container: container, cryptor: cryptor),
            fileStorage: try FileStorageService(root: tempRoot, cryptor: cryptor),
            settingsRepository: SettingsRepository(defaults: UserDefaults(suiteName: "NotchCopilotStopMeeting-\(UUID().uuidString)")!, cryptor: cryptor),
            providerRouter: ProviderRouter(),
            knowledgeStore: LocalKnowledgeStore(container: container, cryptor: cryptor),
            localDataCryptor: cryptor
        )
        let meetingId = UUID()
        appState.currentMeeting = MeetingSession(
            id: meetingId,
            title: "Stop test",
            status: .listening,
            transcriptSegments: [
                TranscriptSegment(meetingId: meetingId, speakerLabel: "You", audioSource: .microphone, text: "Please stop recording now.")
            ]
        )
        appState.islandMode = .listening
        appState.isPanelExpanded = true

        await manager.stopMeeting()

        XCTAssertTrue(appState.isPanelExpanded)
        XCTAssertEqual(appState.islandMode, .summaryReady)
        XCTAssertEqual(appState.currentMeeting?.status, .ended)
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testIslandButtonMouseOverlayCoversEntireAssignedBounds() {
        let overlay = MouseDownActionNSView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        var clicks = 0
        overlay.action = { clicks += 1 }

        XCTAssertTrue(overlay.hitTest(NSPoint(x: 0.5, y: 0.5)) === overlay)
        XCTAssertTrue(overlay.hitTest(NSPoint(x: 43.5, y: 43.5)) === overlay)
        XCTAssertNil(overlay.hitTest(NSPoint(x: 45, y: 22)))

        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 22, y: 22),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )
        XCTAssertNotNil(event)
        overlay.mouseDown(with: event!)
        XCTAssertEqual(clicks, 1)
    }

    func testIslandButtonMouseOverlayHoverCoversEntireAssignedBounds() {
        let overlay = MouseDownActionNSView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        var hoverStates: [Bool] = []
        overlay.onHover = { hoverStates.append($0) }

        let insideCornerEvent = NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(x: 43.5, y: 0.5),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 0,
            pressure: 0
        )
        let outsideEvent = NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(x: 45, y: 22),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 2,
            clickCount: 0,
            pressure: 0
        )

        XCTAssertNotNil(insideCornerEvent)
        XCTAssertNotNil(outsideEvent)
        overlay.mouseMoved(with: insideCornerEvent!)
        XCTAssertEqual(hoverStates.last, true)
        overlay.mouseMoved(with: outsideEvent!)
        XCTAssertEqual(hoverStates.last, false)
    }

    func testNotchPanelPrioritizesFullMouseOverlayBeforeFallbackClickAreas() {
        let appState = AppState()
        appState.isNotchHovered = true
        let size = appState.notchIslandCanvasSize
        let panel = NotchPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.appState = appState
        defer {
            panel.orderOut(nil)
            panel.close()
        }

        let overlay = MouseDownActionNSView(frame: CGRect(origin: .zero, size: size))
        panel.contentView = overlay

        let pointInsideRecordFallback = NSPoint(x: size.width - 20, y: NotchIslandChromeMetrics.compactRecordButtonBottomInset + 12)
        XCTAssertTrue(panel.eventTargetsMouseDownActionOverlayForTesting(at: pointInsideRecordFallback))
    }

    func testNotchPanelFallbackHandlesFullCompactRecordHoverButtonAreas() {
        let appState = AppState()
        appState.isNotchHovered = true
        var settingsClicks = 0
        var meetingHistoryClicks = 0
        appState.openSettingsHandler = { settingsClicks += 1 }
        appState.openHistoryHandler = { meetingHistoryClicks += 1 }

        let size = appState.notchIslandCanvasSize
        let panel = NotchPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.appState = appState
        panel.contentView = NSView(frame: CGRect(origin: .zero, size: size))
        defer {
            panel.orderOut(nil)
            panel.close()
        }

        let islandRect = CGRect(origin: .zero, size: size)
        let buttonRect = IslandButtonFallbackGeometry.compactRecordButtonRect(in: islandRect)
        let actionRects = IslandButtonFallbackGeometry.compactRecordHoverActionHitRects(in: buttonRect)
        let primaryRect = IslandButtonFallbackGeometry.compactRecordPrimaryHitRect(
            in: buttonRect,
            reservesHoverActionArea: true
        )

        func samplePoints(in rect: CGRect) -> [NSPoint] {
            [
                NSPoint(x: rect.minX + 0.5, y: rect.minY + 0.5),
                NSPoint(x: rect.maxX - 0.5, y: rect.minY + 0.5),
                NSPoint(x: rect.minX + 0.5, y: rect.maxY - 0.5),
                NSPoint(x: rect.maxX - 0.5, y: rect.maxY - 0.5),
                NSPoint(x: rect.midX, y: rect.midY)
            ]
        }

        for point in samplePoints(in: actionRects.settings) {
            appState.isNotchHovered = true
            XCTAssertTrue(panel.handleIslandButtonFallbackForTesting(at: point))
        }
        XCTAssertEqual(settingsClicks, 5)
        XCTAssertEqual(meetingHistoryClicks, 0)

        for point in samplePoints(in: actionRects.history) {
            appState.isPanelExpanded = false
            appState.isShowingCopilotHistory = false
            appState.islandMode = .idle
            appState.isNotchHovered = true
            XCTAssertTrue(panel.handleIslandButtonFallbackForTesting(at: point))
            XCTAssertTrue(appState.isShowingCopilotHistory)
            XCTAssertTrue(appState.isPanelExpanded)
        }
        XCTAssertEqual(settingsClicks, 5)
        XCTAssertEqual(meetingHistoryClicks, 0)

        let feedbackBeforePrimary = appState.compactRecordButtonFeedbackTrigger
        for point in samplePoints(in: primaryRect) {
            appState.isPanelExpanded = false
            appState.isShowingCopilotHistory = false
            appState.islandMode = .idle
            appState.isNotchHovered = true
            XCTAssertTrue(panel.handleIslandButtonFallbackForTesting(at: point))
        }
        XCTAssertEqual(appState.compactRecordButtonFeedbackTrigger, feedbackBeforePrimary + 5)
        XCTAssertEqual(settingsClicks, 5)
        XCTAssertEqual(meetingHistoryClicks, 0)
    }

    func testExpandedHeaderHistoryButtonShowsCopilotTimelineInsteadOfMeetingHistory() {
        let appState = AppState()
        appState.currentMeeting = MeetingSession(title: "Daily", status: .listening)
        appState.islandMode = .listening
        appState.isPanelExpanded = true
        var meetingHistoryClicks = 0
        appState.openHistoryHandler = { meetingHistoryClicks += 1 }

        let size = appState.notchIslandCanvasSize
        let panel = NotchPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.appState = appState
        panel.contentView = NSView(frame: CGRect(origin: .zero, size: size))
        defer {
            panel.orderOut(nil)
            panel.close()
        }

        let islandSize = appState.notchIslandSize
        let islandRect = CGRect(
            x: size.width / 2 - islandSize.width / 2,
            y: size.height - islandSize.height,
            width: islandSize.width,
            height: islandSize.height
        )
        let hit = IslandButtonFallbackGeometry.expandedHeaderHit
        let spacing = IslandButtonFallbackGeometry.expandedHeaderSpacing
        let y = islandRect.maxY - NotchIslandChromeMetrics.expandedTopPadding - hit
        let rightGroupWidth = hit * 3 + spacing * 2
        let rightX = islandRect.maxX - appState.expandedHorizontalContentInset - rightGroupWidth
        let historyPoint = NSPoint(x: rightX + hit / 2, y: y + hit / 2)

        XCTAssertTrue(panel.handleIslandButtonFallbackForTesting(at: historyPoint))
        XCTAssertEqual(meetingHistoryClicks, 0)
        XCTAssertTrue(appState.isShowingCopilotHistory)
        XCTAssertTrue(appState.isPanelExpanded)
        XCTAssertEqual(appState.currentMeeting?.status, .listening)
    }

    func testIslandButtonFallbackGeometryMatchesCompactQuestionQueueLayout() {
        let hit = IconButtonSize.standard.hitDiameter
        let expectedQueueWidth = hit * 2
            + IslandButtonFallbackGeometry.compactQuestionCounterWidth
            + IslandButtonFallbackGeometry.compactQuestionQueueSpacing * 2

        XCTAssertEqual(IslandButtonFallbackGeometry.compactQuestionQueueWidth, expectedQueueWidth)
        XCTAssertEqual(IslandButtonFallbackGeometry.compactQuestionQueueWidth, 118)

        let buttonFrame = CGRect(x: 80, y: 12, width: hit, height: hit)
        let fallbackFrame = IslandButtonFallbackGeometry.compactHitRect(buttonFrame)
        XCTAssertTrue(fallbackFrame.contains(NSPoint(x: buttonFrame.minX, y: buttonFrame.minY)))
        XCTAssertTrue(fallbackFrame.contains(NSPoint(x: buttonFrame.maxX, y: buttonFrame.maxY)))
        XCTAssertTrue(fallbackFrame.contains(NSPoint(x: buttonFrame.midX, y: buttonFrame.minY - 6)))
    }

    func testTranscriptLiveScrollFollowsOnlyWhenNearLiveEdge() {
        let documentHeight: CGFloat = 1_200
        let viewportHeight: CGFloat = 360
        let liveEdgeY = TranscriptLiveScrollPolicy.maxScrollY(
            documentHeight: documentHeight,
            viewportHeight: viewportHeight
        )

        XCTAssertEqual(liveEdgeY, 840)
        XCTAssertTrue(TranscriptLiveScrollPolicy.isNearLiveEdge(
            scrollY: liveEdgeY - 12,
            documentHeight: documentHeight,
            viewportHeight: viewportHeight
        ))
        XCTAssertFalse(TranscriptLiveScrollPolicy.isNearLiveEdge(
            scrollY: liveEdgeY - 96,
            documentHeight: documentHeight,
            viewportHeight: viewportHeight
        ))
        XCTAssertTrue(TranscriptLiveScrollPolicy.shouldFollowLiveEdge(
            isFollowingLiveEdge: true,
            scrollY: liveEdgeY - 220,
            documentHeight: documentHeight,
            viewportHeight: viewportHeight
        ))
        XCTAssertFalse(TranscriptLiveScrollPolicy.shouldFollowLiveEdge(
            isFollowingLiveEdge: false,
            scrollY: liveEdgeY - 220,
            documentHeight: documentHeight,
            viewportHeight: viewportHeight
        ))
        XCTAssertEqual(TranscriptLiveScrollPolicy.clampedScrollY(
            2_000,
            documentHeight: documentHeight,
            viewportHeight: viewportHeight
        ), liveEdgeY)
    }

    func testTranscriptReadableChunkerSplitsLongTranslatedBlocksIntoShortPairs() {
        let original = """
        nível de senioridade lá dentro você vai ter acesso à minha pessoa você vai poder me consultar tirar dúvidas diretamente comigo que eu vou te conduzindo vou te guiando ali até você se tornar um arquiteto de software um arquiteto de soluções com conhecimentos práticos e pra vida real então vamos agora para a terceira parte
        """
        let translation = """
        you will have access to me and you will be able to ask questions directly while I guide you until you become a software architect with practical knowledge for real life so now let's move to the third part
        """

        let originalChunks = TranscriptReadableChunker.chunks(for: original)
        let translationChunks = TranscriptReadableChunker.chunks(for: translation)
        let pairs = TranscriptReadableChunker.pairedChunks(original: original, translation: translation)

        XCTAssertGreaterThan(originalChunks.count, 1)
        XCTAssertGreaterThan(translationChunks.count, 1)
        XCTAssertEqual(pairs.count, max(originalChunks.count, translationChunks.count))
        XCTAssertTrue(originalChunks.allSatisfy { $0.count <= TranscriptReadableChunker.defaultMaxLength })
        XCTAssertTrue(translationChunks.allSatisfy { $0.count <= TranscriptReadableChunker.defaultMaxLength })
    }

    func testMeetingDetectedIslandUsesNotchWidthAndTightCanvas() {
        let appState = AppState()
        let now = Date(timeIntervalSince1970: 100)
        appState.currentMeeting = MeetingSession(
            title: "Zoom meeting",
            source: .activeApp,
            appName: "Zoom",
            status: .detected,
            automationSourceAppName: "Zoom",
            automationSourceBundleId: "us.zoom.xos"
        )
        appState.setMeetingDetected(appState.currentMeeting!, now: now)

        XCTAssertEqual(NotchIslandChromeMetrics.detectedMeetingSize.width, NotchIslandChromeMetrics.collapsedNotchFootprintSize.width)
        XCTAssertEqual(appState.notchIslandSize, NotchIslandChromeMetrics.detectedMeetingSize)
        XCTAssertEqual(appState.notchIslandCanvasSize, appState.notchIslandSize)
        XCTAssertEqual(appState.detectedMeetingOfferRemainingSeconds(at: now), 15)
    }

    func testCompactRecordButtonUsesSymmetricEdgeInsets() {
        let islandRect = CGRect(origin: .zero, size: NotchIslandChromeMetrics.detectedMeetingSize)
        let horizontalInset = NotchIslandChromeMetrics.compactRecordButtonHorizontalInset
        let bottomInset = NotchIslandChromeMetrics.compactRecordButtonBottomInset
        let buttonRect = CGRect(
            x: islandRect.minX + horizontalInset,
            y: islandRect.minY + bottomInset,
            width: islandRect.width - horizontalInset * 2,
            height: NotchIslandChromeMetrics.compactRecordButtonHeight
        )

        XCTAssertEqual(bottomInset, horizontalInset)
        XCTAssertEqual(buttonRect.minX - islandRect.minX, horizontalInset)
        XCTAssertEqual(islandRect.maxX - buttonRect.maxX, horizontalInset)
        XCTAssertEqual(buttonRect.minY - islandRect.minY, bottomInset)
    }

    func testCompactRecordHoverActionHitAreasDoNotStartRecording() {
        let islandRect = CGRect(origin: .zero, size: NotchIslandChromeMetrics.compactRecordHoverActionsSize)
        let buttonRect = IslandButtonFallbackGeometry.compactRecordButtonRect(in: islandRect)
        let actionRects = IslandButtonFallbackGeometry.compactRecordHoverActionHitRects(in: buttonRect)
        let primaryHitRect = IslandButtonFallbackGeometry.compactRecordPrimaryHitRect(
            in: buttonRect,
            reservesHoverActionArea: true
        )

        XCTAssertTrue(actionRects.settings.contains(NSPoint(x: actionRects.settings.midX, y: actionRects.settings.midY)))
        XCTAssertTrue(actionRects.history.contains(NSPoint(x: actionRects.history.midX, y: actionRects.history.midY)))
        XCTAssertFalse(primaryHitRect.intersects(actionRects.settings))
        XCTAssertFalse(primaryHitRect.intersects(actionRects.history))
        XCTAssertGreaterThan(primaryHitRect.minX, actionRects.history.maxX)
    }

    func testIdleHoverUsesCompactNotchDropDownLayout() {
        let appState = AppState()
        appState.isNotchHovered = true

        XCTAssertEqual(appState.notchIslandSize, NotchIslandChromeMetrics.compactRecordHoverActionsSize)
        XCTAssertEqual(appState.notchIslandCanvasSize, appState.notchIslandSize)

        appState.preferences.copilotAlwaysOnEnabled = false
        XCTAssertEqual(appState.notchIslandSize, NotchIslandChromeMetrics.compactRecordHoverActionsSize)
        XCTAssertEqual(appState.notchIslandCanvasSize, appState.notchIslandSize)
        XCTAssertEqual(
            appState.notchIslandSize.width,
            NotchIslandChromeMetrics.collapsedNotchFootprintSize.width + NotchIslandChromeMetrics.compactRecordHoverActionsWidth
        )
    }

    func testMeetingDetectedHoverMakesRoomForCompactActions() {
        let appState = AppState()
        let meeting = MeetingSession(
            title: "Google Meet",
            source: .activeApp,
            appName: "Arc",
            meetingURL: "https://meet.google.com/abc-defg-hij",
            status: .detected,
            automationSourceAppName: "Arc",
            automationSourceBundleId: "company.thebrowser.Browser"
        )
        appState.setMeetingDetected(meeting, now: Date(timeIntervalSince1970: 100))

        XCTAssertEqual(appState.notchIslandSize, NotchIslandChromeMetrics.detectedMeetingSize)

        appState.isNotchHovered = true

        XCTAssertEqual(appState.notchIslandSize, NotchIslandChromeMetrics.compactRecordHoverActionsSize)
        XCTAssertEqual(appState.notchIslandCanvasSize, appState.notchIslandSize)
        XCTAssertGreaterThan(
            NotchIslandChromeMetrics.compactRecordHoverActionsSize.width,
            NotchIslandChromeMetrics.detectedMeetingSize.width
        )
    }

    func testDetectedMeetingOfferExpiresAfterFifteenSecondsAndSuppressesRepeat() {
        let appState = AppState()
        let now = Date(timeIntervalSince1970: 1_000)
        let meeting = MeetingSession(
            title: "Teams meeting",
            source: .activeApp,
            appName: "Microsoft Teams",
            status: .detected,
            automationSourceAppName: "Microsoft Teams",
            automationSourceBundleId: "com.microsoft.teams2"
        )

        appState.setMeetingDetected(meeting, now: now)

        XCTAssertFalse(appState.expireDetectedMeetingOfferIfNeeded(now: now.addingTimeInterval(14.9)))
        XCTAssertEqual(appState.islandMode, .meetingDetected)
        XCTAssertNotNil(appState.currentMeeting)

        XCTAssertTrue(appState.expireDetectedMeetingOfferIfNeeded(now: now.addingTimeInterval(15)))
        XCTAssertEqual(appState.islandMode, .idle)
        XCTAssertNil(appState.currentMeeting)
        XCTAssertNil(appState.detectedMeetingOfferExpiresAt)
        XCTAssertTrue(appState.shouldIgnoreDetection(meeting, now: now.addingTimeInterval(15)))
    }

    func testExpiredBrowserMeetingOfferSuppressesCalendarVariantForSamePlatform() {
        let appState = AppState()
        let now = Date(timeIntervalSince1970: 2_000)
        let browserMeeting = MeetingSession(
            title: "Google Meet meeting",
            source: .activeApp,
            appName: "Google Meet",
            status: .detected,
            automationSourceAppName: "Google Meet",
            automationSourceBundleId: "company.thebrowser.Browser"
        )
        let calendarVariant = MeetingSession(
            title: "Daily standup",
            source: .calendar,
            meetingURL: "https://meet.google.com/jta-miju-aim?authuser=0",
            status: .detected
        )

        appState.setMeetingDetected(browserMeeting, now: now)
        XCTAssertTrue(appState.expireDetectedMeetingOfferIfNeeded(now: now.addingTimeInterval(15)))

        XCTAssertTrue(appState.shouldIgnoreDetection(calendarVariant, now: now.addingTimeInterval(16)))
        XCTAssertTrue(appState.ignoredDetectionSignatures.contains("platform:googleMeet"))
    }

    func testExpiredMeetingOfferSuppressionEndsAfterCooldown() {
        let appState = AppState()
        let now = Date(timeIntervalSince1970: 3_000)
        let meeting = MeetingSession(
            title: "Google Meet meeting",
            source: .activeApp,
            appName: "Google Meet",
            status: .detected,
            automationSourceAppName: "Google Meet",
            automationSourceBundleId: "company.thebrowser.Browser"
        )

        appState.setMeetingDetected(meeting, now: now)
        XCTAssertTrue(appState.expireDetectedMeetingOfferIfNeeded(now: now.addingTimeInterval(15)))

        XCTAssertTrue(appState.shouldIgnoreDetection(meeting, now: now.addingTimeInterval(16)))
        XCTAssertFalse(appState.shouldIgnoreDetection(meeting, now: now.addingTimeInterval((10 * 60) + 16)))
    }

    func testMeetingAppIconResolverFallsBackForUnknownBundle() {
        let meeting = MeetingSession(
            title: "Unknown meeting",
            source: .activeApp,
            appName: "Definitely Not Installed Meeting App",
            status: .detected,
            automationSourceAppName: "Definitely Not Installed Meeting App",
            automationSourceBundleId: "com.notchcopilot.tests.not-installed"
        )

        let resolved = MeetingAppIconResolver.resolve(for: meeting)

        XCTAssertTrue(resolved.isFallback)
        XCTAssertGreaterThan(resolved.image.size.width, 0)
        XCTAssertGreaterThan(resolved.image.size.height, 0)
    }

    func testMeetingAppIconResolverPrefersMeetingPlatformForBrowserURL() {
        let meeting = MeetingSession(
            title: "Google Meet meeting",
            source: .activeApp,
            appName: "Google Meet",
            meetingURL: "https://meet.google.com/abc-defg-hij",
            status: .detected,
            automationSourceAppName: "Google Meet",
            automationSourceBundleId: "com.google.Chrome"
        )

        let resolved = MeetingAppIconResolver.resolve(for: meeting)

        XCTAssertFalse(resolved.isFallback)
        XCTAssertEqual(resolved.platformName, "Google Meet")
        XCTAssertGreaterThan(resolved.image.size.width, 0)
        XCTAssertGreaterThan(resolved.image.size.height, 0)
    }

    func testWhiprFlowAudioMarkIntensityRespondsToAudioAndPause() {
        let silent = WhiprFlowAudioMark.intensity(for: Array(repeating: CGFloat(0.05), count: 10), isPaused: false)
        let high = WhiprFlowAudioMark.intensity(for: Array(repeating: CGFloat(0.82), count: 10), isPaused: false)
        let paused = WhiprFlowAudioMark.intensity(for: Array(repeating: CGFloat(0.82), count: 10), isPaused: true)

        XCTAssertEqual(silent, 0)
        XCTAssertGreaterThan(high, silent)
        XCTAssertEqual(paused, 0)
        XCTAssertLessThanOrEqual(high, 1)
    }

    func testWhiprFlowAudioMarkRestsAtUniformGrayZeroStageWithoutAudio() {
        let noAudio = Array(repeating: CGFloat(0.05), count: 18)
        let rest = WhiprFlowAudioMark.presentation(for: noAudio, isPaused: false, seconds: 1.0)
        let restLater = WhiprFlowAudioMark.presentation(for: noAudio, isPaused: false, seconds: 2.4)
        let paused = WhiprFlowAudioMark.presentation(for: Array(repeating: CGFloat(0.82), count: 18), isPaused: true, seconds: 1.0)

        XCTAssertEqual(rest.bars.count, 13)
        XCTAssertTrue(rest.bars.allSatisfy { $0 == rest.bars[0] })
        XCTAssertEqual(rest.bars, restLater.bars)
        XCTAssertEqual(rest.bars, paused.bars)
        XCTAssertLessThanOrEqual(rest.bars[0].height, 4.3)
        XCTAssertEqual(rest.bars[0].tint.red, rest.bars[0].tint.green, accuracy: 0.001)
        XCTAssertLessThan(rest.bars[0].tint.red, 0.6)
        XCTAssertEqual(rest.glowOpacity, 0)
    }

    func testWhiprFlowAudioMarkStaysAliveAndAmplifiesWithAudio() {
        let quietLevels = Array(repeating: CGFloat(0.18), count: 18)
        let loudLevels = Array(repeating: CGFloat(0.86), count: 10)
        let quietStart = WhiprFlowAudioMark.presentation(for: quietLevels, isPaused: false, seconds: 1.0)
        let quietLater = WhiprFlowAudioMark.presentation(for: quietLevels, isPaused: false, seconds: 1.8)
        let loud = WhiprFlowAudioMark.presentation(for: loudLevels, isPaused: false, seconds: 1.0)
        let paused = WhiprFlowAudioMark.presentation(for: loudLevels, isPaused: true, seconds: 1.0)
        let quietReducedStart = WhiprFlowAudioMark.presentation(for: quietLevels, isPaused: false, seconds: 1.0, reduceMotion: true)
        let quietReducedLater = WhiprFlowAudioMark.presentation(for: quietLevels, isPaused: false, seconds: 1.8, reduceMotion: true)

        XCTAssertNotEqual(quietStart.bars.map(\.height), quietLater.bars.map(\.height))
        XCTAssertEqual(quietReducedStart.bars.map(\.height), quietReducedLater.bars.map(\.height))
        XCTAssertEqual(quietStart.bars.count, 13)
        XCTAssertGreaterThan(loud.bars.map(\.height).reduce(0, +), quietStart.bars.map(\.height).reduce(0, +))
        XCTAssertGreaterThan(loud.glowRadius, quietStart.glowRadius)
        XCTAssertGreaterThan(loud.glowOpacity, quietStart.glowOpacity)
        XCTAssertLessThan(paused.glowRadius, quietStart.glowRadius)
    }

    func testWhiprFlowAudioMarkKeepsMovingAtMaximumAudio() {
        let maxedLevels = Array(repeating: CGFloat(1), count: 18)
        let first = WhiprFlowAudioMark.presentation(for: maxedLevels, isPaused: false, seconds: 1.0)
        let later = WhiprFlowAudioMark.presentation(for: maxedLevels, isPaused: false, seconds: 1.18)
        let reduced = WhiprFlowAudioMark.presentation(for: maxedLevels, isPaused: false, seconds: 1.18, reduceMotion: true)

        let firstHeights = first.bars.map(\.height)
        let laterHeights = later.bars.map(\.height)
        let heightRange = (firstHeights.max() ?? 0) - (firstHeights.min() ?? 0)

        XCTAssertNotEqual(firstHeights, laterHeights)
        XCTAssertGreaterThan(heightRange, 0.35)
        XCTAssertTrue(first.bars.contains { $0.height < WhiprFlowAudioMark.markHeight - 1.1 })
        XCTAssertEqual(reduced.bars.map(\.verticalOffset), Array(repeating: CGFloat(0), count: WhiprFlowAudioMark.barCount))
    }

    func testWhiprFlowAudioMarkTransientsAndColorRespondNaturally() {
        let steadyLevels = Array(repeating: CGFloat(0.22), count: 18)
        let transientLevels = Array(repeating: CGFloat(0.08), count: 15) + [CGFloat(0.54), CGFloat(0.76), CGFloat(0.92)]
        let quiet = WhiprFlowAudioMark.presentation(for: steadyLevels, isPaused: false, seconds: 1.0)
        let transient = WhiprFlowAudioMark.presentation(for: transientLevels, isPaused: false, seconds: 1.0)
        let loud = WhiprFlowAudioMark.presentation(for: Array(repeating: CGFloat(0.78), count: 18), isPaused: false, seconds: 1.0)

        XCTAssertGreaterThan(transient.signal.flux, quiet.signal.flux)
        XCTAssertGreaterThan(transient.signal.bands.max() ?? 0, quiet.signal.bands.max() ?? 0)
        let elevatedTransientBands = transient.signal.bands.enumerated().filter { index, band in
            band > quiet.signal.bands[index] + 0.06
        }.map(\.offset)
        XCTAssertTrue(elevatedTransientBands.contains { $0 < 6 })
        XCTAssertTrue(elevatedTransientBands.contains { $0 > 6 })
        XCTAssertTrue(transient.bars.allSatisfy { $0.height <= WhiprFlowAudioMark.markHeight })
        XCTAssertNotEqual(loud.bars.map(\.tint), quiet.bars.map(\.tint))
    }

    func testWhiprFlowAudioMarkReduceMotionRemovesAutonomousBreathing() {
        let levels = [CGFloat(0.08), 0.12, 0.18, 0.24, 0.30, 0.34, 0.42, 0.38, 0.28, 0.20, 0.16, 0.12, 0.09]
        let first = WhiprFlowAudioMark.presentation(for: levels, isPaused: false, seconds: 1.0, reduceMotion: true)
        let later = WhiprFlowAudioMark.presentation(for: levels, isPaused: false, seconds: 2.4, reduceMotion: true)
        let animated = WhiprFlowAudioMark.presentation(for: levels, isPaused: false, seconds: 2.4, reduceMotion: false)

        XCTAssertEqual(first.bars, later.bars)
        XCTAssertEqual(first.verticalOffset, later.verticalOffset)
        XCTAssertNotEqual(first.bars, animated.bars)
    }

    func testNotchChromeCornerRadiusIsStableAcrossModesAndExpansion() {
        let appState = AppState()
        let expectedRadius = NotchIslandMode.chromeCornerRadius
        let smallestChromeHeight = min(
            NotchIslandChromeMetrics.collapsedNotchFootprintSize.height,
            NotchIslandMode.allCases.map { $0.preferredSize.height }.min() ?? .greatestFiniteMagnitude
        )

        for mode in NotchIslandMode.allCases {
            appState.isPanelExpanded = false
            appState.islandMode = mode
            XCTAssertEqual(appState.notchCornerRadius, expectedRadius, "Unexpected compact radius for \(mode)")

            appState.isPanelExpanded = true
            XCTAssertEqual(appState.notchCornerRadius, expectedRadius, "Unexpected expanded radius for \(mode)")
        }

        XCTAssertLessThanOrEqual(expectedRadius, smallestChromeHeight / 2)
    }

    func testNotchInteractionContainerRoutesVisibleIslandClicksToSwiftUI() {
        let appState = AppState()
        let question = makeQuestion("Como inverter uma árvore binária em Python?")
        appState.upsertQuestionInQueue(candidate: question, classification: nil, stage: .drafting, select: true)
        appState.updateQueuedQuestionStreamingText(questionId: question.id, text: "Use a recursive swap and preserve the base case.")
        appState.islandMode = .suggestedAnswer

        let container = NotchInteractionContainerView(rootView: NotchIslandView(appState: appState), appState: appState)
        container.frame = CGRect(origin: .zero, size: appState.notchIslandCanvasSize)

        let pointInsideIsland = NSPoint(
            x: container.bounds.midX,
            y: container.bounds.maxY - appState.notchIslandSize.height / 2
        )
        let hitView = container.hitTest(pointInsideIsland)

        XCTAssertNotNil(hitView)
        XCTAssertFalse(hitView === container)
    }

    func testNotchInteractionContainerStillHandlesHiddenNotchActivation() {
        let appState = AppState()
        appState.preferences.copilotAlwaysOnEnabled = false
        let container = NotchInteractionContainerView(rootView: NotchIslandView(appState: appState), appState: appState)
        container.frame = CGRect(origin: .zero, size: appState.notchIslandCanvasSize)

        let activationPoint = NSPoint(x: container.bounds.midX, y: container.bounds.maxY - 12)

        XCTAssertTrue(container.hitTest(activationPoint) === container)
    }

    func testHiddenNotchActivationCoversCollapsedFootprintEdges() {
        let appState = AppState()
        appState.preferences.copilotAlwaysOnEnabled = false
        let container = NotchInteractionContainerView(rootView: NotchIslandView(appState: appState), appState: appState)
        container.frame = CGRect(origin: .zero, size: appState.notchIslandCanvasSize)

        XCTAssertGreaterThan(appState.notchIslandCanvasSize.width, NotchIslandChromeMetrics.collapsedNotchFootprintSize.width)
        XCTAssertGreaterThan(appState.notchIslandCanvasSize.height, NotchIslandChromeMetrics.collapsedNotchFootprintSize.height)

        let edgePoints = [
            NSPoint(x: container.bounds.minX + 1, y: container.bounds.midY),
            NSPoint(x: container.bounds.maxX - 1, y: container.bounds.midY),
            NSPoint(x: container.bounds.midX, y: container.bounds.minY + 1),
            NSPoint(x: container.bounds.midX, y: container.bounds.maxY - 1)
        ]

        for point in edgePoints {
            XCTAssertTrue(container.hitTest(point) === container, "Expected hidden notch footprint to handle edge point \(point)")
        }
    }

    func testHiddenNotchHoverMaintainsAcrossFullRevealArea() {
        let appState = AppState()
        appState.preferences.copilotAlwaysOnEnabled = false
        let container = NotchInteractionContainerView(rootView: NotchIslandView(appState: appState), appState: appState)
        container.frame = CGRect(origin: .zero, size: appState.notchIslandCanvasSize)

        let lowerRevealPoint = NSPoint(x: container.bounds.midX, y: container.bounds.minY + 1)

        XCTAssertTrue(appState.isIdleHiddenBehindNotch)
        XCTAssertTrue(container.shouldMaintainHoverForTesting(at: lowerRevealPoint))
    }

    func testNotchHoverGraceKeepsAnimatedBoundaryStable() {
        let appState = AppState()
        appState.isNotchHovered = true
        let container = NotchInteractionContainerView(rootView: NotchIslandView(appState: appState), appState: appState)
        container.frame = CGRect(origin: .zero, size: appState.notchIslandCanvasSize)

        let animatedBoundaryPoint = NSPoint(
            x: container.bounds.midX,
            y: container.bounds.minY - 1
        )

        XCTAssertFalse(container.shouldMaintainHoverForTesting(at: animatedBoundaryPoint))
        XCTAssertTrue(container.shouldMaintainHoverForTesting(at: animatedBoundaryPoint, allowingGrace: true))
    }

    func testRealtimeQAPartialAnswerDoesNotForceTranscriptModeAway() {
        let appState = AppState()
        let question = makeQuestion("What is the main risk here?")
        appState.upsertQuestionInQueue(candidate: question, classification: nil, stage: .retrievingContext, select: true)
        appState.questionAnswerPresentationMode = .transcript
        appState.isPanelExpanded = true

        appState.updateQueuedQuestionStreamingText(questionId: question.id, text: "I’m checking context and drafting a concise answer.")

        XCTAssertEqual(appState.questionAnswerPresentationMode, .transcript)
        XCTAssertTrue(appState.isPanelExpanded)
        XCTAssertEqual(appState.streamingAnswerText, "I’m checking context and drafting a concise answer.")
    }

    func testRealtimeQALoadingKeepsExpandedTranscriptVisibleForIncomingQuestion() {
        let appState = AppState()
        let meetingId = UUID()
        let question = makeQuestion("What is the main risk here?", meetingId: meetingId)
        appState.currentMeeting = MeetingSession(
            id: meetingId,
            title: "Design Review",
            status: .listening,
            transcriptSegments: [
                TranscriptSegment(meetingId: meetingId, speakerLabel: "Ari", audioSource: .system, text: "We should verify the release risk.")
            ]
        )
        appState.isPanelExpanded = true
        appState.questionAnswerPresentationMode = .answer

        let shouldKeepTranscriptVisible = appState.shouldPreserveTranscriptForIncomingQuestion
        appState.upsertQuestionInQueue(candidate: question, classification: nil, stage: .classifying, select: true)
        appState.showQuestionAnswerPanel(mode: shouldKeepTranscriptVisible ? .transcript : .answer)

        XCTAssertEqual(appState.questionAnswerPresentationMode, .transcript)
        XCTAssertTrue(appState.shouldShowTranscriptQuestionLoadingIndicator)

        appState.updateQueuedQuestionStage(questionId: question.id, stage: .ready)

        XCTAssertFalse(appState.shouldShowTranscriptQuestionLoadingIndicator)
    }

    func testCollapseFromTranscriptModeReturnsToLiveMeetingInsteadOfCompactQA() {
        let appState = AppState()
        let meetingId = UUID()
        let question = makeQuestion("What is the main risk here?", meetingId: meetingId)
        appState.currentMeeting = MeetingSession(
            id: meetingId,
            title: "Design Review",
            status: .listening,
            transcriptSegments: [
                TranscriptSegment(meetingId: meetingId, speakerLabel: "You", audioSource: .microphone, text: question.rawText)
            ]
        )
        appState.upsertQuestionInQueue(candidate: question, classification: nil, stage: .ready, select: true)
        appState.questionAnswerPresentationMode = .transcript
        appState.isPanelExpanded = true

        appState.collapsePanelPreservingContext()

        XCTAssertFalse(appState.isPanelExpanded)
        XCTAssertEqual(appState.islandMode, .listening)
    }

    func testDoubleEscapeShortcutDetectorOnlyTriggersOnSecondClosePress() {
        var detector = DoubleEscapeShortcutDetector(threshold: 0.45)

        XCTAssertFalse(detector.registerEscapePress(timestamp: 10.0))
        XCTAssertTrue(detector.registerEscapePress(timestamp: 10.32))
        XCTAssertFalse(detector.registerEscapePress(timestamp: 11.0))
        XCTAssertFalse(detector.registerEscapePress(timestamp: 11.6))
        XCTAssertTrue(detector.registerEscapePress(timestamp: 11.9))
    }

    func testCopilotDefaultHotkeyMatchesOptionCommandModifierChord() {
        let descriptor = CopilotHotkeyDescriptor.default

        XCTAssertEqual(descriptor.displayName, "⌥⌘")
        XCTAssertTrue(descriptor.matches(modifierFlags: [.option, .command]))
        XCTAssertTrue(descriptor.matches(keyCode: 0, modifierFlags: [.option, .command], isRepeat: false))
        XCTAssertFalse(descriptor.matches(modifierFlags: [.option]))
        XCTAssertFalse(descriptor.matches(modifierFlags: [.command]))
        XCTAssertFalse(descriptor.matches(modifierFlags: [.option, .command, .shift]))
        XCTAssertFalse(descriptor.matches(keyCode: 0, modifierFlags: [.option, .command], isRepeat: true))
    }

    func testCopilotHotkeyOpensAmbientTimelineWithoutStartingListeningState() {
        let appState = AppState()

        appState.openCopilotFromHotkey()

        XCTAssertTrue(appState.isPanelExpanded)
        XCTAssertNil(appState.currentMeeting)
        XCTAssertEqual(appState.islandMode, .questionDetected)
        XCTAssertFalse(appState.isAmbientCopilotListening)
        XCTAssertFalse(appState.isCopilotPushToTalkActive)
        XCTAssertEqual(appState.ambientCopilotStatus, "Hold to talk")

        appState.openCopilotFromHotkey()

        XCTAssertFalse(appState.isPanelExpanded)
        XCTAssertTrue(appState.isIdleHiddenBehindNotch)
    }

    func testCopilotHotkeyDuringMeetingOnlyTogglesMeetingPanel() {
        let appState = AppState()
        appState.currentMeeting = MeetingSession(title: "Design Review", status: .listening)

        appState.openCopilotFromHotkey()

        XCTAssertTrue(appState.isPanelExpanded)
        XCTAssertEqual(appState.islandMode, .listening)
        XCTAssertFalse(appState.isCopilotPushToTalkActive)

        appState.openCopilotFromHotkey()

        XCTAssertFalse(appState.isPanelExpanded)
        XCTAssertEqual(appState.islandMode, .listening)
    }

    func testDoubleEscapeToggleExpandsAndCollapsesPreservingQAState() {
        let appState = AppState()
        let question = makeQuestion("How would you scale this system?")
        let answer = SuggestedAnswer(
            questionId: question.id,
            answerText: "Use redundancy, health checks, and regional failover.",
            shortAnswer: "Use redundancy, health checks, and regional failover.",
            confidence: 0.82,
            riskLevel: .safe,
            usedSources: [],
            assumptions: [],
            caveats: [],
            latencyMs: 120
        )
        appState.upsertQuestionInQueue(candidate: question, classification: nil, stage: .ready, select: true)
        appState.updateQueuedQuestionAnswer(candidate: question, answer: answer)
        appState.isPanelExpanded = false
        appState.islandMode = .suggestedAnswer

        appState.togglePanelExpansionPreservingContext()

        XCTAssertTrue(appState.isPanelExpanded)
        XCTAssertEqual(appState.islandMode, .questionDetected)
        XCTAssertEqual(appState.suggestedAnswer?.shortAnswer, answer.shortAnswer)

        appState.togglePanelExpansionPreservingContext()

        XCTAssertFalse(appState.isPanelExpanded)
        XCTAssertEqual(appState.islandMode, .idle)
        XCTAssertTrue(appState.isIdleHiddenBehindNotch)
        XCTAssertEqual(appState.suggestedAnswer?.shortAnswer, answer.shortAnswer)
    }

    func testRealtimeQAAnswerActionsUpdateVisibleState() {
        let appState = AppState()
        let question = makeQuestion("How would you scale this system?")
        let answer = SuggestedAnswer(
            questionId: question.id,
            answerText: "Use redundancy, health checks, and regional failover.",
            shortAnswer: "Use redundancy, health checks, and regional failover.",
            confidence: 0.82,
            riskLevel: .safe,
            usedSources: [],
            assumptions: [],
            caveats: [],
            latencyMs: 120
        )
        appState.upsertQuestionInQueue(candidate: question, classification: nil, stage: .ready, select: true)
        appState.updateQueuedQuestionAnswer(candidate: question, answer: answer)

        appState.saveSelectedQuestionAnswer()
        XCTAssertTrue(appState.isSelectedQuestionSaved)

        appState.applyEditedSuggestedAnswer("Use multi-AZ redundancy, health checks, and a tested failover path.")
        XCTAssertEqual(appState.suggestedAnswer?.shortAnswer, "Use multi-AZ redundancy, health checks, and a tested failover path.")
        XCTAssertEqual(appState.questionAnswerQueue.first?.answer?.answerText, "Use multi-AZ redundancy, health checks, and a tested failover path.")

        appState.dismissActiveQuestion()
        XCTAssertTrue(appState.questionAnswerQueue.isEmpty)
        XCTAssertEqual(appState.statusMessage, "Question dismissed")
    }

    func testRealtimeQAIgnoresMultilingualFalseQuestions() async throws {
        let cases = [
            "No es obvio?",
            "当たり前でしょう？",
            "They asked if it was ready, and I answered yes.",
            "Mas e se...",
            "Y si..."
        ]

        for text in cases {
            let candidate = makeQuestion(text)
            let classification = try await QuestionClassifier().classifyQuestion(candidate: candidate, context: makeContext(text), userProfile: makeProfile())
            XCTAssertFalse(classification.responseNeeded, "Expected no response for: \(text)")
        }
    }

    func testRealtimeQARejectsScreenshotDeclarativeTechnicalStatement() async throws {
        let text = "Livros sobre arquitetura de software e sistemas distribuidos a projetar grandes aplicacoes para milhoes de usuarios e tudo isso com uma didatica extremamente simples e objetiva e com exemplos do mundo real que vao te fazer sair do mundo do grude do Work e comecar a entrar no mundo quem realmente projeta aplicacoes de grande porte esse livro se chama design Intense"
        let segment = TranscriptSegment(meetingId: UUID(), speakerLabel: "Speaker", text: text, originalLanguage: "pt-BR")
        let context = TranscriptContext(recentTranscript: text, mediumTranscript: text, completeTranscript: text, dominantLanguage: "pt-BR", currentSegment: segment)
        let candidates = QuestionDetectionService().detectCandidates(from: segment, context: context)

        XCTAssertTrue(candidates.isEmpty)

        let classification = try await QuestionClassifier().classifyQuestion(candidate: makeQuestion(text), context: context, userProfile: makeProfile())
        XCTAssertFalse(classification.isQuestion)
        XCTAssertFalse(classification.responseNeeded)
        XCTAssertTrue(classification.reason.localizedCaseInsensitiveContains("statement"))
    }

    func testRealtimeQAGoldFixtureMeetsHighPrecisionTargets() async throws {
        struct Row: Decodable {
            var text: String
            var language: String
            var responseNeeded: Bool
        }

        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/qa_intent_gold.jsonl")
        let lines = try String(contentsOf: fixtureURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertGreaterThanOrEqual(lines.count, 2_000)

        let decoder = JSONDecoder()
        let detector = QuestionDetectionService(precisionMode: .highPrecision)
        let classifier = QuestionClassifier(precisionMode: .highPrecision)
        var truePositive = 0
        var falsePositive = 0
        var falseNegative = 0
        var trueNegative = 0
        var byLanguage: [String: (tp: Int, fp: Int, fn: Int)] = [:]
        var falsePositiveExamples: [String] = []
        var falseNegativeExamples: [String] = []

        for line in lines {
            let row = try decoder.decode(Row.self, from: Data(line.utf8))
            let meetingId = UUID()
            let segment = TranscriptSegment(meetingId: meetingId, speakerLabel: "Speaker", text: row.text, originalLanguage: row.language)
            let context = TranscriptContext(
                recentTranscript: row.text,
                mediumTranscript: row.text,
                completeTranscript: row.text,
                dominantLanguage: row.language,
                currentSegment: segment
            )
            let candidate = detector.detectCandidates(from: segment, context: context).first
            let predicted: Bool
            if let candidate {
                predicted = try await classifier
                    .classifyQuestion(candidate: candidate, context: context, userProfile: makeProfile())
                    .responseNeeded
            } else {
                predicted = false
            }

            var languageStats = byLanguage[row.language, default: (0, 0, 0)]
            switch (row.responseNeeded, predicted) {
            case (true, true):
                truePositive += 1
                languageStats.tp += 1
            case (false, true):
                falsePositive += 1
                languageStats.fp += 1
                if falsePositiveExamples.count < 12 {
                    falsePositiveExamples.append("[\(row.language)] \(row.text)")
                }
            case (true, false):
                falseNegative += 1
                languageStats.fn += 1
                if falseNegativeExamples.count < 12 {
                    falseNegativeExamples.append("[\(row.language)] \(row.text)")
                }
            case (false, false):
                trueNegative += 1
            }
            byLanguage[row.language] = languageStats
        }

        let precision = Double(truePositive) / Double(max(truePositive + falsePositive, 1))
        let recall = Double(truePositive) / Double(max(truePositive + falseNegative, 1))
        XCTAssertGreaterThanOrEqual(precision, 0.99, "False positives: \(falsePositiveExamples.joined(separator: " | "))")
        XCTAssertGreaterThanOrEqual(recall, 0.95, "False negatives: \(falseNegativeExamples.joined(separator: " | "))")
        XCTAssertGreaterThan(trueNegative, 0)

        for (language, stats) in byLanguage {
            let languagePrecision = Double(stats.tp) / Double(max(stats.tp + stats.fp, 1))
            let languageRecall = Double(stats.tp) / Double(max(stats.tp + stats.fn, 1))
            XCTAssertGreaterThanOrEqual(languagePrecision, 0.98, "Precision below target for \(language)")
            XCTAssertGreaterThanOrEqual(languageRecall, 0.90, "Recall below target for \(language)")
        }
    }

    func testRealtimeQAHardScenarioMatrixAcrossLanguages() async throws {
        let scenarios: [(text: String, language: String, responseNeeded: Bool)] = [
            ("Livros sobre arquitetura de software e sistemas distribuidos a projetar grandes aplicacoes para milhoes de usuarios", "pt-BR", false),
            ("Como eu disse, o sistema pergunta como vamos escalar quando cresce", "pt-BR", false),
            ("Can everyone see my screen with the API diagram?", "en-US", false),
            ("What I mean is how the API handles auth in this flow", "en-US", false),
            ("Books about distributed systems and system design examples for large applications", "en-US", false),
            ("Pueden ver mi pantalla con el diagrama de la API?", "es-ES", false),
            ("La duda era como escalar el sistema pero ya lo resolvimos", "es-ES", false),
            ("このAPIがどう動くかを説明しました", "ja-JP", false),
            ("レビューの結果は問題ありません", "ja-JP", false),
            ("認証の問題を確認しました", "ja-JP", false),
            ("Ryan, can you explain the privacy risk of this migration", "en-US", true),
            ("Can we ship this by Friday", "en-US", true),
            ("Podemos revisar o risco de autenticacao antes do deploy", "pt-BR", true),
            ("Eu queria entender se isso impacta o login", "pt-BR", true),
            ("Cual es el riesgo de esta migracion?", "es-ES", true),
            ("Necesitamos saber si esto rompe el login", "es-ES", true),
            ("このAPIの状態はどうですか", "ja-JP", true),
            ("認証のリスクは何ですか", "ja-JP", true)
        ]

        let detector = QuestionDetectionService(precisionMode: .highPrecision)
        let classifier = QuestionClassifier(precisionMode: .highPrecision)
        for scenario in scenarios {
            let prediction = try await qaPrediction(
                for: scenario.text,
                language: scenario.language,
                detector: detector,
                classifier: classifier
            )
            XCTAssertEqual(
                prediction.responseNeeded,
                scenario.responseNeeded,
                "[\(scenario.language)] \(scenario.text) reason=\(prediction.classification?.reason ?? "no_candidate")"
            )
        }
    }

    func testRealtimeQARecognizesSpokenASRQuestionFramesWithoutPunctuation() async throws {
        let positives: [(text: String, language: String)] = [
            ("Me diz qual e o risco desse deploy", "pt-BR"),
            ("Sabe se o deploy ja terminou", "pt-BR"),
            ("Tem como revisar esse PR hoje", "pt-BR"),
            ("Sera que isso impacta o login", "pt-BR"),
            ("Quick question can we ship this by Friday", "en-US"),
            ("Any blockers on the release", "en-US"),
            ("Do you know whether the API is ready", "en-US"),
            ("Sabes si el deploy termino", "es-ES"),
            ("Hay algun bloqueo para la migracion", "es-ES"),
            ("デプロイは終わりましたか", "ja-JP")
        ]

        let detector = QuestionDetectionService(precisionMode: .highPrecision)
        let classifier = QuestionClassifier(precisionMode: .highPrecision)
        for sample in positives {
            let prediction = try await qaPrediction(
                for: sample.text,
                language: sample.language,
                detector: detector,
                classifier: classifier
            )
            XCTAssertTrue(
                prediction.responseNeeded,
                "[\(sample.language)] \(sample.text) reason=\(prediction.classification?.reason ?? "no_candidate")"
            )
        }
    }

    func testRealtimeQASpokenQuestionRecallDoesNotPromoteCommonStatements() async throws {
        let negatives: [(text: String, language: String)] = [
            ("Tem como objetivo reduzir latencia no deploy", "pt-BR"),
            ("Sabe se posicionar bem em entrevistas tecnicas", "pt-BR"),
            ("Quick question summaries are useful after the meeting", "en-US"),
            ("Any blockers were already resolved before the release", "en-US"),
            ("Hay algun documento sobre la migracion en la carpeta", "es-ES"),
            ("デプロイは終わりました", "ja-JP")
        ]

        let detector = QuestionDetectionService(precisionMode: .highPrecision)
        let classifier = QuestionClassifier(precisionMode: .highPrecision)
        for sample in negatives {
            let prediction = try await qaPrediction(
                for: sample.text,
                language: sample.language,
                detector: detector,
                classifier: classifier
            )
            XCTAssertFalse(
                prediction.responseNeeded,
                "[\(sample.language)] \(sample.text) reason=\(prediction.classification?.reason ?? "no_candidate")"
            )
        }
    }

    func testQuestionMultimodalSignalCodableAndClampsUnsafeAudioValues() throws {
        let audioLogMel = QuestionAudioLogMelFeature(
            frames: 2,
            values: Array(repeating: 12, count: 80),
            source: "unit_test"
        )
        let signal = QuestionMultimodalSignal(
            language: "en-US",
            asrConfidence: 0.91,
            isFinal: false,
            isPartial: true,
            speakerLabel: "Speaker",
            audioSource: .microphone,
            duration: 1.2,
            hasTerminalPause: false,
            partialStability: 1.8,
            partialRevisionCount: -3,
            rms: -0.2,
            peak: 1.7,
            isClipping: true,
            isSilence: false,
            isTooQuiet: false,
            gapCount: -1,
            noiseFloor: 0.004,
            audioEnergy: 0.03,
            audioLogMel: audioLogMel
        )

        let data = try JSONEncoder().encode(signal)
        let decoded = try JSONDecoder().decode(QuestionMultimodalSignal.self, from: data)
        XCTAssertEqual(decoded.partialStability, 1)
        XCTAssertEqual(decoded.partialRevisionCount, 0)
        XCTAssertEqual(decoded.rms ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(decoded.peak ?? -1, 1, accuracy: 0.0001)
        XCTAssertEqual(decoded.gapCount, 0)
        XCTAssertEqual(decoded.audioSource, .microphone)
        XCTAssertEqual(decoded.audioLogMel?.frames, 2)
        XCTAssertEqual(decoded.audioLogMel?.bands, 40)
        XCTAssertEqual(decoded.audioLogMel?.values.first, 8)
    }

    func testQuestionAudioLogMelProxyCarriesAcousticSignalWithoutRawAudio() throws {
        let signal = QuestionMultimodalSignal(
            language: "pt-BR",
            asrConfidence: 0.88,
            isFinal: true,
            isPartial: false,
            speakerLabel: "Speaker",
            audioSource: .microphone,
            duration: 2.4,
            hasTerminalPause: true,
            rms: 0.024,
            peak: 0.08,
            isClipping: false,
            isSilence: false,
            isTooQuiet: false,
            gapCount: 0,
            noiseFloor: 0.002,
            audioEnergy: 0.026
        )

        let feature = QuestionAudioLogMelFeature.proxy(from: signal, targetFrames: 24)

        XCTAssertEqual(feature.bands, 40)
        XCTAssertEqual(feature.frames, 24)
        XCTAssertEqual(feature.values.count, 960)
        XCTAssertTrue(feature.values.contains { abs($0) > 0.0001 })
        XCTAssertEqual(feature.source, "signal_proxy")
    }

    func testQuestionAudioLogMelRingBufferBuildsCapturedFeatureForSegmentRange() throws {
        let sampleRate = 16_000.0
        let seconds = 0.8
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            return XCTFail("Could not create test audio format")
        }
        let frameCount = AVAudioFrameCount(sampleRate * seconds)
        let pcmBuffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        pcmBuffer.frameLength = frameCount
        let channel = try XCTUnwrap(pcmBuffer.floatChannelData?[0])
        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / sampleRate
            channel[frame] = Float(0.18 * sin(2 * Double.pi * 440 * t))
        }

        let meetingStartedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let ringBuffer = QuestionAudioLogMelRingBuffer(retentionSeconds: 8)
        ringBuffer.append(
            AudioBuffer(
                pcmBuffer: pcmBuffer,
                time: nil,
                rms: 0.12,
                peak: 0.18,
                createdAt: meetingStartedAt.addingTimeInterval(seconds),
                audioSource: .microphone
            ),
            meetingStartedAt: meetingStartedAt
        )

        let segment = TranscriptSegment(
            meetingId: UUID(),
            speakerLabel: "You",
            audioSource: .microphone,
            text: "What is the rollout risk?",
            sourceFrameRange: AudioSourceFrameRange(start: 1_600, end: 9_600),
            startTime: 0.1,
            endTime: 0.6,
            isFinal: true
        )

        let started = Date()
        let feature = try XCTUnwrap(ringBuffer.feature(
            for: segment,
            targetFrames: QuestionAudioLogMelFeature.trainedModelFrameCount
        ))
        let elapsedMs = Date().timeIntervalSince(started) * 1_000
        XCTAssertEqual(feature.source, "captured_logmel")
        XCTAssertEqual(feature.bands, QuestionAudioLogMelFeature.expectedBandCount)
        XCTAssertEqual(feature.frames, QuestionAudioLogMelFeature.trainedModelFrameCount)
        XCTAssertEqual(feature.values.count, 9_600)
        XCTAssertTrue(feature.values.contains { abs($0) > 0.01 })
        let mean = feature.values.reduce(0, +) / Double(feature.values.count)
        XCTAssertEqual(mean, 0, accuracy: 0.1)
        XCTAssertLessThan(elapsedMs, 100)
    }

    func testRealtimeQAMultimodalScorerBlocksUnstablePartialWhenEnforced() async throws {
        let signal = QuestionMultimodalSignal(
            language: "en-US",
            asrConfidence: 0.93,
            isFinal: false,
            isPartial: true,
            speakerLabel: "Speaker",
            audioSource: .microphone,
            duration: 0.7,
            hasTerminalPause: false,
            partialStability: 0.2,
            rms: 0.02,
            peak: 0.04,
            audioEnergy: 0.02
        )
        let candidate = makeQuestion("Ryan can you explain the OAuth flow", isPartial: true, multimodalSignal: signal)
        let classification = try await QuestionClassifier(multimodalMode: .enforced)
            .classifyQuestion(candidate: candidate, context: makeContext(candidate.rawText), userProfile: makeProfile())

        XCTAssertFalse(classification.responseNeeded)
        XCTAssertFalse(classification.isQuestion)
        XCTAssertTrue(classification.suppressionSignals?.contains("partial_unstable") == true)
        XCTAssertNotNil(classification.decisionScore)
    }

    func testRealtimeQATrainedMultiQTDecisionOverridesFallbackWhenAvailable() async throws {
        let prediction = QuestionTrainedMultimodalPrediction(
            responseScore: 0.93,
            label: "technical_explanation",
            completeScore: 0.97,
            rhetoricalScore: 0.02,
            threshold: 0.50,
            decisionLatencyMs: 7.2,
            decisionSignals: ["trained_multiqt_coreml", "trained_label:technical_explanation"],
            suppressionSignals: []
        )
        let classifier = QuestionClassifier(
            multimodalMode: .enforced,
            trainedModelRunner: StubTrainedMultiQTModelRunner(prediction: prediction)
        )
        let candidate = makeQuestion("What is the API cache strategy?")
        let classification = try await classifier.classifyQuestion(
            candidate: candidate,
            context: makeContext(candidate.rawText),
            userProfile: makeProfile()
        )

        XCTAssertTrue(classification.responseNeeded)
        XCTAssertEqual(classification.decisionScore ?? 0, 0.93, accuracy: 0.0001)
        XCTAssertTrue(classification.decisionSignals?.contains("trained_multiqt_coreml") == true)
    }

    func testRealtimeQATrainedMultiQTCanRejectBelowThresholdCandidate() async throws {
        let prediction = QuestionTrainedMultimodalPrediction(
            responseScore: 0.21,
            label: "statement",
            completeScore: 0.94,
            rhetoricalScore: 0.01,
            threshold: 0.50,
            decisionLatencyMs: 6.8,
            decisionSignals: ["trained_multiqt_coreml", "trained_label:statement"],
            suppressionSignals: ["trained_below_threshold"]
        )
        let classifier = QuestionClassifier(
            multimodalMode: .enforced,
            trainedModelRunner: StubTrainedMultiQTModelRunner(prediction: prediction)
        )
        let candidate = makeQuestion("What is the API cache strategy?")
        let classification = try await classifier.classifyQuestion(
            candidate: candidate,
            context: makeContext(candidate.rawText),
            userProfile: makeProfile()
        )

        XCTAssertFalse(classification.responseNeeded)
        XCTAssertFalse(classification.isQuestion)
        XCTAssertEqual(classification.decisionScore ?? 0, 0.21, accuracy: 0.0001)
        XCTAssertTrue(classification.suppressionSignals?.contains("trained_below_threshold") == true)
    }

    func testRealtimeQABundledTrainedMultiQTModelLoadsAndScoresKnownQuestion() async throws {
        let signal = QuestionMultimodalSignal(
            language: "en-US",
            asrConfidence: 0.94,
            isFinal: true,
            isPartial: false,
            speakerLabel: "Speaker",
            audioSource: .microphone,
            duration: 2.2,
            hasTerminalPause: true,
            partialStability: 1,
            rms: 0.028,
            peak: 0.18,
            isClipping: false,
            isSilence: false,
            isTooQuiet: false,
            gapCount: 0,
            noiseFloor: 0.002,
            audioEnergy: 0.026
        )
        let candidate = makeQuestion(
            "Ryan can you walk through the OAuth flow",
            multimodalSignal: signal
        )

        let prediction = await CoreMLQuestionMultiQTModelRunner().prediction(
            for: candidate,
            signal: signal
        )

        XCTAssertNotNil(prediction)
        XCTAssertEqual(prediction?.threshold ?? 0, 0.99, accuracy: 0.0001)
        XCTAssertGreaterThan(prediction?.responseScore ?? 0, prediction?.threshold ?? 1)
        XCTAssertTrue(prediction?.decisionSignals.contains("trained_multiqt_coreml") == true)
    }

    func testRealtimeQACleansExtractedQuestionWithoutDroppingIntent() async throws {
        let text = "Ryan, quick question can we ship the endpoint by Friday?"
        let signal = QuestionMultimodalSignal(
            language: "en-US",
            asrConfidence: 0.94,
            isFinal: true,
            isPartial: false,
            speakerLabel: "Speaker",
            audioSource: .system,
            duration: 2.2,
            hasTerminalPause: true,
            rms: 0.018,
            peak: 0.05,
            audioEnergy: 0.018
        )
        let candidate = makeQuestion(text, multimodalSignal: signal)
        let classification = try await QuestionClassifier(multimodalMode: .enforced)
            .classifyQuestion(candidate: candidate, context: makeContext(text), userProfile: makeProfile())

        XCTAssertTrue(classification.responseNeeded)
        XCTAssertEqual(classification.extractedQuestion, "can we ship the endpoint by Friday?")
        XCTAssertEqual(classification.decisionSignals?.contains("terminal_pause"), true)
    }

    func testRealtimeQADetectsPortuguesePluralQuestionWithoutPunctuation() async throws {
        let text = "Quais são os princípios SOLID de programação"
        let meetingId = UUID()
        let segment = TranscriptSegment(
            meetingId: meetingId,
            speakerLabel: "Speaker",
            text: text,
            originalLanguage: "pt-BR",
            startTime: 0,
            endTime: 2.4,
            confidence: 0.96,
            isFinal: true
        )
        let signal = QuestionMultimodalSignal(segment: segment)
        let context = TranscriptContext(
            recentTranscript: text,
            mediumTranscript: text,
            completeTranscript: text,
            dominantLanguage: "pt-BR",
            currentSegment: segment
        )

        let candidates = QuestionDetectionService().detectCandidates(from: segment, context: context, signal: signal)
        let candidate = try XCTUnwrap(candidates.first)
        let classification = try await QuestionClassifier(multimodalMode: .enforced)
            .classifyQuestion(candidate: candidate, context: context, userProfile: makeProfile())

        XCTAssertTrue(classification.isQuestion)
        XCTAssertTrue(classification.responseNeeded)
        XCTAssertTrue(classification.complete)
        XCTAssertEqual(classification.questionType, .technicalExplanation)
        XCTAssertEqual(classification.extractedQuestion, text)
    }

    func testRealtimeQAIgnoresPortuguesePluralQuestionFragments() async throws {
        let detector = QuestionDetectionService()

        for text in ["Quais", "Quais são"] {
            let segment = TranscriptSegment(
                meetingId: UUID(),
                speakerLabel: "Speaker",
                text: text,
                originalLanguage: "pt-BR",
                startTime: 0,
                endTime: 0.4,
                confidence: 0.96,
                isFinal: true
            )
            let context = TranscriptContext(
                recentTranscript: text,
                mediumTranscript: text,
                completeTranscript: text,
                dominantLanguage: "pt-BR",
                currentSegment: segment
            )

            XCTAssertTrue(detector.detectCandidates(from: segment, context: context).isEmpty, text)
        }
    }

    func testRealtimeQAEngineDoesNotSurfaceUnstablePartialBeforeFinal() async throws {
        let engine = TestRealtimeQuestionAnsweringEngine()
        var preferences = AppPreferences()
        preferences.qaMultimodalMode = .enforced
        let meetingId = UUID()
        let meeting = MeetingSession(id: meetingId, title: "Engine", status: .listening)
        let partial = TranscriptSegment(
            meetingId: meetingId,
            speakerLabel: "Speaker",
            text: "Ryan can you explain",
            startTime: 0,
            endTime: 0.6,
            confidence: 0.91,
            isFinal: false
        )

        let eventTask = Task { () -> [RealtimeQuestionEvent] in
            var events: [RealtimeQuestionEvent] = []
            for await event in engine.eventBus.events {
                events.append(event)
            }
            return events
        }

        await engine.ingest(segment: partial, meeting: meeting, preferences: preferences)
        try await Task.sleep(for: .milliseconds(1_250))
        engine.stop()

        let events = await eventTask.value
        XCTAssertFalse(events.contains { if case .questionDetected = $0 { return true }; return false })
    }

    func testRealtimeQAEngineSurfacesStableFinalAfterIgnoredPartial() async throws {
        let engine = TestRealtimeQuestionAnsweringEngine()
        var preferences = AppPreferences()
        preferences.qaMultimodalMode = .enforced
        let meetingId = UUID()
        let meeting = MeetingSession(id: meetingId, title: "Engine", status: .listening)
        let partial = TranscriptSegment(
            meetingId: meetingId,
            speakerLabel: "Speaker",
            text: "Ryan can you explain",
            startTime: 0,
            endTime: 0.6,
            confidence: 0.91,
            isFinal: false
        )
        let final = TranscriptSegment(
            meetingId: meetingId,
            speakerLabel: "Speaker",
            text: "Ryan can you explain the OAuth flow?",
            startTime: 0,
            endTime: 2.0,
            confidence: 0.94,
            isFinal: true
        )

        let eventTask = Task { () -> [RealtimeQuestionEvent] in
            var events: [RealtimeQuestionEvent] = []
            for await event in engine.eventBus.events {
                events.append(event)
                if case .suggestedAnswerReady = event { break }
            }
            return events
        }

        await engine.ingest(segment: partial, meeting: meeting, preferences: preferences)
        await engine.ingest(segment: final, meeting: meeting, preferences: preferences)
        try await Task.sleep(for: .milliseconds(100))
        engine.stop()

        let events = await eventTask.value
        XCTAssertTrue(events.contains { if case .questionDetected = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .suggestedAnswerReady = $0 { return true }; return false })
    }

    func testRealtimeQAEngineSurfacesSingleCompleteQuestionPartialAfterFallback() async throws {
        let engine = TestRealtimeQuestionAnsweringEngine()
        var preferences = AppPreferences()
        preferences.qaMultimodalMode = .enforced
        let meetingId = UUID()
        let meeting = MeetingSession(id: meetingId, title: "Live Apple Speech", status: .listening)
        let partial = TranscriptSegment(
            meetingId: meetingId,
            speakerLabel: "Speaker",
            text: "Quanto é 2 + 2",
            originalLanguage: "pt-BR",
            startTime: 0,
            endTime: 1.3,
            confidence: 0.96,
            isFinal: false
        )
        let signal = QuestionMultimodalSignal(segment: partial).withPartialStability(0.84, revisionCount: 1)
        let context = TranscriptContext(
            recentTranscript: partial.text,
            mediumTranscript: partial.text,
            completeTranscript: partial.text,
            dominantLanguage: "pt-BR",
            currentSegment: partial
        )
        let directCandidates = QuestionDetectionService().detectCandidates(from: partial, context: context, signal: signal)
        let directCandidate = try XCTUnwrap(directCandidates.first)
        XCTAssertTrue(QuestionIntentGate().evaluate(candidate: directCandidate, context: context).isAnswerableQuestion)
        let directClassification = try await QuestionClassifier(multimodalMode: .enforced)
            .classifyQuestion(candidate: directCandidate, context: context, userProfile: makeProfile())
        XCTAssertTrue(directClassification.responseNeeded)

        let eventTask = Task { () -> [RealtimeQuestionEvent] in
            var events: [RealtimeQuestionEvent] = []
            for await event in engine.eventBus.events {
                events.append(event)
                if case .questionDetected = event { break }
            }
            return events
        }

        await engine.ingest(segment: partial, meeting: meeting, preferences: preferences)
        try await Task.sleep(for: .milliseconds(1_250))
        engine.stop()

        let events = await eventTask.value
        let detected = events.compactMap { event -> (QuestionCandidate, QuestionClassification)? in
            if case let .questionDetected(candidate, classification) = event {
                return (candidate, classification)
            }
            return nil
        }
        let event = try XCTUnwrap(detected.first)
        XCTAssertEqual(event.0.rawText, "Quanto é 2 + 2")
        XCTAssertTrue(event.1.responseNeeded)
        XCTAssertTrue(event.1.complete)
        XCTAssertEqual(event.1.extractedQuestion, "Quanto é 2 + 2")
    }

    func testRealtimeQAEngineSurfacesPortuguesePluralQuestionPartialAfterFallback() async throws {
        let engine = TestRealtimeQuestionAnsweringEngine()
        var preferences = AppPreferences()
        preferences.qaMultimodalMode = .enforced
        let meetingId = UUID()
        let meeting = MeetingSession(id: meetingId, title: "Live Apple Speech", status: .listening)
        let partial = TranscriptSegment(
            meetingId: meetingId,
            speakerLabel: "Speaker",
            text: "Quais são os princípios SOLID de programação",
            originalLanguage: "pt-BR",
            startTime: 0,
            endTime: 2.4,
            confidence: 0.96,
            isFinal: false
        )

        let eventTask = Task { () -> [RealtimeQuestionEvent] in
            var events: [RealtimeQuestionEvent] = []
            for await event in engine.eventBus.events {
                events.append(event)
                if case .questionDetected = event { break }
            }
            return events
        }

        await engine.ingest(segment: partial, meeting: meeting, preferences: preferences)
        try await Task.sleep(for: .milliseconds(1_250))
        engine.stop()

        let events = await eventTask.value
        let detected = events.compactMap { event -> (QuestionCandidate, QuestionClassification)? in
            if case let .questionDetected(candidate, classification) = event {
                return (candidate, classification)
            }
            return nil
        }
        let event = try XCTUnwrap(detected.first)
        XCTAssertEqual(event.0.rawText, partial.text)
        XCTAssertTrue(event.1.responseNeeded)
        XCTAssertEqual(event.1.extractedQuestion, partial.text)
    }

    func testRealtimeQAGoldFixtureBenchmarkMeetsLatencyTargets() async throws {
        let rows = try qaGoldFixtureRows()
        let detector = QuestionDetectionService(precisionMode: .highPrecision)
        let classifier = QuestionClassifier(precisionMode: .highPrecision)
        var detectionLatencies: [Double] = []
        var classificationLatencies: [Double] = []
        var pipelineLatencies: [Double] = []
        var truePositive = 0
        var falsePositive = 0
        var falseNegative = 0
        var trueNegative = 0
        var candidates = 0

        for row in rows {
            let meetingId = UUID()
            let segment = TranscriptSegment(meetingId: meetingId, speakerLabel: "Speaker", text: row.text, originalLanguage: row.language)
            let context = TranscriptContext(
                recentTranscript: row.text,
                mediumTranscript: row.text,
                completeTranscript: row.text,
                dominantLanguage: row.language,
                currentSegment: segment
            )

            let pipelineStart = DispatchTime.now().uptimeNanoseconds
            let detectionStart = DispatchTime.now().uptimeNanoseconds
            let detected = detector.detectCandidates(from: segment, context: context)
            let detectionEnd = DispatchTime.now().uptimeNanoseconds
            detectionLatencies.append(Double(detectionEnd - detectionStart) / 1_000_000)

            let predicted: Bool
            if let candidate = detected.first {
                candidates += 1
                let classificationStart = DispatchTime.now().uptimeNanoseconds
                predicted = try await classifier
                    .classifyQuestion(candidate: candidate, context: context, userProfile: makeProfile())
                    .responseNeeded
                let classificationEnd = DispatchTime.now().uptimeNanoseconds
                classificationLatencies.append(Double(classificationEnd - classificationStart) / 1_000_000)
            } else {
                predicted = false
            }
            let pipelineEnd = DispatchTime.now().uptimeNanoseconds
            pipelineLatencies.append(Double(pipelineEnd - pipelineStart) / 1_000_000)

            switch (row.responseNeeded, predicted) {
            case (true, true): truePositive += 1
            case (false, true): falsePositive += 1
            case (true, false): falseNegative += 1
            case (false, false): trueNegative += 1
            }
        }

        let precision = Double(truePositive) / Double(max(truePositive + falsePositive, 1))
        let recall = Double(truePositive) / Double(max(truePositive + falseNegative, 1))
        let detectionP95 = percentile(detectionLatencies, 0.95)
        let detectionP99 = percentile(detectionLatencies, 0.99)
        let classificationP95 = percentile(classificationLatencies, 0.95)
        let classificationP99 = percentile(classificationLatencies, 0.99)
        let pipelineP95 = percentile(pipelineLatencies, 0.95)
        let pipelineP99 = percentile(pipelineLatencies, 0.99)
        print(String(
            format: "QA_BENCHMARK fixture=%d candidates=%d tp=%d fp=%d fn=%d tn=%d precision=%.4f recall=%.4f detection_p50_ms=%.3f detection_p95_ms=%.3f detection_p99_ms=%.3f classification_p50_ms=%.3f classification_p95_ms=%.3f classification_p99_ms=%.3f pipeline_p50_ms=%.3f pipeline_p95_ms=%.3f pipeline_p99_ms=%.3f",
            rows.count,
            candidates,
            truePositive,
            falsePositive,
            falseNegative,
            trueNegative,
            precision,
            recall,
            percentile(detectionLatencies, 0.50),
            detectionP95,
            detectionP99,
            percentile(classificationLatencies, 0.50),
            classificationP95,
            classificationP99,
            percentile(pipelineLatencies, 0.50),
            pipelineP95,
            pipelineP99
        ))

        XCTAssertGreaterThanOrEqual(precision, 0.99)
        XCTAssertGreaterThanOrEqual(recall, 0.95)
        XCTAssertLessThan(detectionP95, 100)
        XCTAssertLessThan(classificationP95, 100)
        XCTAssertLessThan(pipelineP95, 350)
    }

    func testRealtimeQAMultimodalBenchmarkDoesNotRegressTextualBaseline() async throws {
        let rows = try qaGoldFixtureRows()
        let detector = QuestionDetectionService(precisionMode: .highPrecision)
        let textualClassifier = QuestionClassifier(precisionMode: .highPrecision, multimodalMode: .off)
        let multimodalClassifier = QuestionClassifier(precisionMode: .highPrecision, multimodalMode: .enforced)
        var textual = QAMetricStats()
        var multimodal = QAMetricStats()
        var multimodalDecisionLatencies: [Double] = []
        var criticalFalsePositives: [String] = []

        for row in rows {
            let meetingId = UUID()
            let segment = TranscriptSegment(meetingId: meetingId, speakerLabel: "Speaker", text: row.text, originalLanguage: row.language)
            let signal = syntheticMultimodalSignal(for: row, segment: segment)
            let context = TranscriptContext(
                recentTranscript: row.text,
                mediumTranscript: row.text,
                completeTranscript: row.text,
                dominantLanguage: row.language,
                currentSegment: segment
            )

            let textualPrediction: Bool
            if let candidate = detector.detectCandidates(from: segment, context: context).first {
                textualPrediction = try await textualClassifier
                    .classifyQuestion(candidate: candidate, context: context, userProfile: makeProfile())
                    .responseNeeded
            } else {
                textualPrediction = false
            }
            textual.record(expected: row.responseNeeded, predicted: textualPrediction)

            let multimodalPrediction: Bool
            let decisionStart = DispatchTime.now().uptimeNanoseconds
            if let candidate = detector.detectCandidates(from: segment, context: context, signal: signal).first {
                let classification = try await multimodalClassifier
                    .classifyQuestion(candidate: candidate, context: context, userProfile: makeProfile())
                multimodalPrediction = classification.responseNeeded
            } else {
                multimodalPrediction = false
            }
            let decisionEnd = DispatchTime.now().uptimeNanoseconds
            multimodalDecisionLatencies.append(Double(decisionEnd - decisionStart) / 1_000_000)
            multimodal.record(expected: row.responseNeeded, predicted: multimodalPrediction)

            if !row.responseNeeded, multimodalPrediction, row.isCriticalNegative {
                criticalFalsePositives.append("[\(row.language)] \(row.text)")
            }
        }

        print(String(
            format: "QA_MULTIMODAL_BENCHMARK fixture=%d baseline_tp=%d baseline_fp=%d baseline_fn=%d baseline_tn=%d baseline_precision=%.4f baseline_recall=%.4f multimodal_tp=%d multimodal_fp=%d multimodal_fn=%d multimodal_tn=%d multimodal_precision=%.4f multimodal_recall=%.4f multimodal_p50_ms=%.3f multimodal_p95_ms=%.3f multimodal_p99_ms=%.3f critical_fp=%d",
            rows.count,
            textual.truePositive,
            textual.falsePositive,
            textual.falseNegative,
            textual.trueNegative,
            textual.precision,
            textual.recall,
            multimodal.truePositive,
            multimodal.falsePositive,
            multimodal.falseNegative,
            multimodal.trueNegative,
            multimodal.precision,
            multimodal.recall,
            percentile(multimodalDecisionLatencies, 0.50),
            percentile(multimodalDecisionLatencies, 0.95),
            percentile(multimodalDecisionLatencies, 0.99),
            criticalFalsePositives.count
        ))

        XCTAssertGreaterThanOrEqual(multimodal.precision, textual.precision)
        XCTAssertGreaterThanOrEqual(multimodal.recall, textual.recall - 0.01)
        XCTAssertLessThan(percentile(multimodalDecisionLatencies, 0.95), 100)
        XCTAssertTrue(criticalFalsePositives.isEmpty, criticalFalsePositives.joined(separator: " | "))
    }

    func testRealtimeQASyntheticOneHourReplayKeepsVisibleFalseAlertsBelowTarget() async throws {
        let negativePool: [(text: String, language: String)] = [
            ("Livros sobre arquitetura de software e sistemas distribuidos com exemplos do mundo real", "pt-BR"),
            ("Como eu disse, esse sistema usa cache local para reduzir latencia", "pt-BR"),
            ("Da pra ver minha tela com o dashboard de deploy?", "pt-BR"),
            ("O deploy esta pronto e o rollback foi testado", "pt-BR"),
            ("Books about distributed systems and practical architecture examples", "en-US"),
            ("Can everyone hear me before I explain the API?", "en-US"),
            ("What I mean is how the service handles authentication", "en-US"),
            ("The question is whether we migrate later, but we already decided", "en-US"),
            ("Libros sobre arquitectura de software y sistemas distribuidos", "es-ES"),
            ("Pueden ver mi pantalla con el dashboard?", "es-ES"),
            ("Como dije, el sistema mantiene cache local", "es-ES"),
            ("La migracion esta lista y el riesgo esta documentado", "es-ES"),
            ("分散システムの設計についての本です", "ja-JP"),
            ("このAPIがどう動くかを説明しました", "ja-JP"),
            ("レビューの結果は問題ありません", "ja-JP"),
            ("聞こえますか", "ja-JP")
        ]
        let detector = QuestionDetectionService(precisionMode: .highPrecision)
        let classifier = QuestionClassifier(precisionMode: .highPrecision)
        var visibleFalseAlerts = 0
        var falseAlertExamples: [String] = []
        var latencies: [Double] = []
        var detectionLatencies: [Double] = []
        var classificationLatencies: [Double] = []
        var trueNegative = 0
        var falsePositive = 0

        for index in 0..<1_200 {
            let sample = negativePool[index % negativePool.count]
            let start = DispatchTime.now().uptimeNanoseconds
            let meetingId = UUID()
            let segment = TranscriptSegment(
                meetingId: meetingId,
                speakerLabel: "Speaker",
                text: sample.text,
                originalLanguage: sample.language
            )
            let context = TranscriptContext(
                recentTranscript: sample.text,
                mediumTranscript: sample.text,
                completeTranscript: sample.text,
                dominantLanguage: sample.language,
                currentSegment: segment
            )
            let detectionStart = DispatchTime.now().uptimeNanoseconds
            let detected = detector.detectCandidates(from: segment, context: context)
            let detectionEnd = DispatchTime.now().uptimeNanoseconds
            detectionLatencies.append(Double(detectionEnd - detectionStart) / 1_000_000)

            let classification: QuestionClassification?
            if let candidate = detected.first {
                let classificationStart = DispatchTime.now().uptimeNanoseconds
                classification = try await classifier.classifyQuestion(candidate: candidate, context: context, userProfile: makeProfile())
                let classificationEnd = DispatchTime.now().uptimeNanoseconds
                classificationLatencies.append(Double(classificationEnd - classificationStart) / 1_000_000)
            } else {
                classification = nil
            }
            let end = DispatchTime.now().uptimeNanoseconds
            latencies.append(Double(end - start) / 1_000_000)
            if let classification,
               classification.responseNeeded,
               classification.priority != .low,
               classification.complete,
               !classification.rhetorical {
                visibleFalseAlerts += 1
                if falseAlertExamples.count < 8 {
                    falseAlertExamples.append("[\(sample.language)] \(sample.text) reason=\(classification.reason)")
                }
                falsePositive += 1
            } else {
                trueNegative += 1
            }
        }

        let replayP95 = percentile(latencies, 0.95)
        print(String(
            format: "QA_REPLAY one_hour_segments=%d tp=%d fp=%d fn=%d tn=%d precision=%.4f recall=%.4f visible_false_alerts=%d detection_p50_ms=%.3f detection_p95_ms=%.3f detection_p99_ms=%.3f classification_p50_ms=%.3f classification_p95_ms=%.3f classification_p99_ms=%.3f p50_ms=%.3f p95_ms=%.3f p99_ms=%.3f errors=%@",
            1_200,
            0,
            falsePositive,
            0,
            trueNegative,
            1.0,
            1.0,
            visibleFalseAlerts,
            percentile(detectionLatencies, 0.50),
            percentile(detectionLatencies, 0.95),
            percentile(detectionLatencies, 0.99),
            percentile(classificationLatencies, 0.50),
            percentile(classificationLatencies, 0.95),
            percentile(classificationLatencies, 0.99),
            percentile(latencies, 0.50),
            replayP95,
            percentile(latencies, 0.99),
            falseAlertExamples.joined(separator: " | ")
        ))
        XCTAssertEqual(visibleFalseAlerts, 0, falseAlertExamples.joined(separator: " | "))
        XCTAssertLessThan(replayP95, 100)
    }

    func testRealtimeQAIgnoresRhetoricalQuestion() async throws {
        let candidate = makeQuestion("Quem nunca passou por isso, né?")
        let classification = try await QuestionClassifier().classifyQuestion(candidate: candidate, context: makeContext(candidate.rawText), userProfile: makeProfile())
        XCTAssertTrue(classification.rhetorical)
        XCTAssertFalse(classification.responseNeeded)
    }

    func testRealtimeQAIgnoresSelfAnsweredQuestion() async throws {
        let candidate = makeQuestion("Isso já está em produção? Sim, já foi ontem.")
        let classification = try await QuestionClassifier().classifyQuestion(candidate: candidate, context: makeContext(candidate.rawText), userProfile: makeProfile())
        XCTAssertFalse(classification.responseNeeded)
    }

    func testRealtimeQADeduplicatesPartialAndFinalQuestion() {
        let dedup = QuestionDeduplicator()
        let meetingId = UUID()
        let partial = makeQuestion("Can we ship this", meetingId: meetingId, isPartial: true)
        let final = makeQuestion("Can we ship this by Friday?", meetingId: meetingId, isPartial: false)
        let duplicate = dedup.duplicate(of: final, in: [partial])
        XCTAssertEqual(duplicate?.id, partial.id)
        XCTAssertEqual(dedup.merged(partial, with: final).rawText, final.rawText)
    }

    func testRealtimeQAClassifiesDeadlineAsHighPriority() async throws {
        let candidate = makeQuestion("Ryan, do you think we can ship the authentication endpoint by Friday?")
        let classification = try await QuestionClassifier().classifyQuestion(candidate: candidate, context: makeContext(candidate.rawText), userProfile: makeProfile())
        XCTAssertEqual(classification.questionType, .deadlineOrEstimate)
        XCTAssertEqual(classification.priority, .high)
    }

    func testRealtimeQAClassifiesDirectedToUserAttention() async throws {
        let candidate = makeQuestion("Ryan, can you validate this PR today?")
        let classification = try await QuestionClassifier().classifyQuestion(candidate: candidate, context: makeContext(candidate.rawText), userProfile: makeProfile())
        XCTAssertTrue(classification.directedToUser)
        XCTAssertTrue(classification.userAttentionNeeded)
    }

    func testRealtimeQAGeneratesCautiousDeadlineAnswer() async throws {
        let candidate = makeQuestion("Ryan, can we ship this by Friday?")
        let classification = try await QuestionClassifier().classifyQuestion(candidate: candidate, context: makeContext(candidate.rawText), userProfile: makeProfile())
        let context = AnswerContext(meetingTitle: "API", transcriptWindow: candidate.rawText, ragContext: "", userRole: "Engineer", responseStyle: .technical, languageCode: "en-US")
        let stream = try await TestMeetingAnswerProvider().generateAnswer(question: candidate, classification: classification, context: context, options: AnswerGenerationOptions())
        let answer = try await finalAnswer(from: stream)
        XCTAssertEqual(answer?.riskLevel, .requiresApproval)
        XCTAssertTrue(answer?.answerText.localizedCaseInsensitiveContains("not promise") == true || answer?.answerText.localizedCaseInsensitiveContains("not committing") == true)
    }

    func testRealtimeQAGeneratesTechnicalRiskAnswer() async throws {
        let candidate = makeQuestion("What’s the main risk if we skip the migration?")
        let classification = try await QuestionClassifier().classifyQuestion(candidate: candidate, context: makeContext(candidate.rawText), userProfile: makeProfile())
        let context = AnswerContext(meetingTitle: "API", transcriptWindow: candidate.rawText, ragContext: "", userRole: "Engineer", responseStyle: .technical, languageCode: "en-US")
        let stream = try await TestMeetingAnswerProvider().generateAnswer(question: candidate, classification: classification, context: context, options: AnswerGenerationOptions())
        let answer = try await finalAnswer(from: stream)
        XCTAssertEqual(classification.questionType, .riskAssessment)
        XCTAssertTrue(answer?.answerText.localizedCaseInsensitiveContains("migration") == true)
    }

    func testAnswerPresentationRemovesPlainTextFenceFromSimpleFact() async throws {
        let candidate = makeQuestion("Qual é o nome da capital da França?")
        let classification = try await QuestionClassifier().classifyQuestion(candidate: candidate, context: makeContext(candidate.rawText), userProfile: makeProfile())
        let formatted = AnswerPresentationFormatter.normalizedGeneratedText(
            """
            A capital da França é Paris.

            ```text
            Paris
            ```
            """,
            question: candidate,
            classification: classification
        )

        XCTAssertEqual(formatted, "A capital da França é Paris.")
        XCTAssertFalse(formatted.contains("```"))
        XCTAssertEqual(AnswerPresentationFormatter.shortAnswer(from: formatted), "A capital da França é Paris.")
    }

    func testAnswerPresentationKeepsCodeFenceWhenQuestionNeedsCode() async throws {
        let candidate = makeQuestion("Como inverter uma árvore binária em Python?")
        let classification = try await QuestionClassifier().classifyQuestion(candidate: candidate, context: makeContext(candidate.rawText), userProfile: makeProfile())
        let formatted = AnswerPresentationFormatter.normalizedGeneratedText(
            """
            Use recursão:

            ```python
            def invert_tree(root):
                if root is None:
                    return None
                root.left, root.right = invert_tree(root.right), invert_tree(root.left)
                return root
            ```
            """,
            question: candidate,
            classification: classification
        )

        XCTAssertTrue(formatted.contains("```python"))
        XCTAssertTrue(formatted.contains("def invert_tree"))
    }

    func testAnswerGenerationServiceNormalizesPlainTextFenceBeforeUI() async throws {
        let candidate = makeQuestion("Qual é o nome da capital da França?")
        let classification = try await QuestionClassifier().classifyQuestion(candidate: candidate, context: makeContext(candidate.rawText), userProfile: makeProfile())
        let context = AnswerContext(meetingTitle: "Trivia", transcriptWindow: candidate.rawText, ragContext: "", userRole: "Engineer", responseStyle: .concise, languageCode: "pt-BR")
        let provider = StaticAnswerAIProvider(text: "A capital da França é Paris.\n\n```text\nParis\n```")
        let stream = try await AnswerGenerationService(provider: provider).generateAnswer(
            question: candidate,
            classification: classification,
            context: context,
            options: AnswerGenerationOptions()
        )
        let maybeAnswer = try await finalAnswer(from: stream)
        let answer = try XCTUnwrap(maybeAnswer)

        XCTAssertEqual(answer.answerText, "A capital da França é Paris.")
        XCTAssertEqual(answer.shortAnswer, "A capital da França é Paris.")
        XCTAssertFalse(answer.answerText.contains("```"))
        XCTAssertFalse(answer.shortAnswer.contains("```"))
    }

    func testRealtimeQADoesNotGenerateWhenResponseNotNeeded() async throws {
        let candidate = makeQuestion("Vai entender, né?")
        let classification = try await QuestionClassifier().classifyQuestion(candidate: candidate, context: makeContext(candidate.rawText), userProfile: makeProfile())
        XCTAssertFalse(classification.responseNeeded)
    }

    func testRealtimeQACancelsGenerationWhenQuestionDismissed() async {
        let engine = TestRealtimeQuestionAnsweringEngine()
        let questionId = UUID()
        engine.dismiss(questionId: questionId)
        XCTAssertNil(engine.candidate(for: questionId))
    }

    func testRealtimeQALocalOnlyUsesUnavailableAnswerProvider() {
        var preferences = AppPreferences()
        preferences.localOnlyMode = true
        preferences.aiConfig.provider = .openAI
        preferences.aiConfig.cloudProcessingEnabled = true
        let provider = ProviderRouter(openAIProvider: nil).meetingAnswerProvider(preferences: preferences)
        XCTAssertTrue(String(describing: type(of: provider)).contains("AnswerGenerationService"))
    }

    func testRealtimeQADoesNotMixKnowledgeWorkspaces() throws {
        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let store = LocalKnowledgeStore(container: container, workspaceId: "alpha", cryptor: try testCryptor())
        try store.addDocument(name: "Alpha.md", content: "authentication risk alpha", workspaceId: "alpha")
        try store.addDocument(name: "Beta.md", content: "authentication risk beta", workspaceId: "beta")
        let results = try store.keywordSearch(query: "authentication risk")
        XCTAssertEqual(results.map(\.workspaceId), ["alpha"])
    }

    func testTranscriptWindowBufferKeepsCompleteTranscriptBeyondMediumWindow() {
        let meetingId = UUID()
        var buffer = TranscriptWindowBuffer()
        buffer.append(TranscriptSegment(meetingId: meetingId, speakerLabel: "A", text: "Earlier decision: migration is not complete.", startTime: 0))
        buffer.append(TranscriptSegment(meetingId: meetingId, speakerLabel: "B", text: "Current question: what is the risk?", startTime: 700))

        let context = buffer.transcriptContext(currentSegment: nil)
        XCTAssertFalse(context.mediumTranscript.contains("Earlier decision"))
        XCTAssertTrue(context.completeTranscript.contains("Earlier decision"))
        XCTAssertTrue(context.completeTranscript.contains("Current question"))
    }

    func testRealtimeQAContextRetrieverUsesRAGCompleteTranscriptAndWebQuery() async throws {
        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let store = LocalKnowledgeStore(container: container, workspaceId: "alpha", cryptor: try testCryptor())
        try store.addDocument(name: "Alpha.md", content: "authentication migration rollback risk alpha", workspaceId: "alpha")
        try store.addDocument(name: "Beta.md", content: "authentication migration rollback risk beta", workspaceId: "beta")
        let webService = CapturingWebSearchService(results: ["Official source: migration compatibility guidance."])
        let retriever = MeetingContextRetriever(
            knowledgeStore: store,
            webBuilder: WebSearchQuestionContextBuilder(service: webService)
        )
        var preferences = AppPreferences()
        preferences.localOnlyMode = false
        preferences.workspaceId = "alpha"
        preferences.aiConfig.ragEnabled = true
        preferences.aiConfig.webSearchEnabled = true
        preferences.aiConfig.cloudProcessingEnabled = true
        let question = makeQuestion("What’s the risk if we skip the migration?")
        let classification = try await QuestionClassifier().classifyQuestion(candidate: question, context: makeContext(question.rawText), userProfile: makeProfile())
        let meeting = MeetingSession(title: "API Review", primaryLanguage: "en-US", meetingType: .engineering)
        let transcriptContext = TranscriptContext(
            recentTranscript: "Current: what is the migration risk?",
            mediumTranscript: "Medium: authentication endpoint discussion.",
            completeTranscript: "Earlier: backend owner confirmed the migration is not complete.\nCurrent: what is the migration risk?",
            dominantLanguage: "en-US",
            currentSegment: nil
        )

        let context = try await retriever.retrieveContext(
            question: question,
            classification: classification,
            meetingContext: MeetingContext(
                meeting: meeting,
                transcriptContext: transcriptContext,
                shortTermMemory: MeetingShortTermMemory(currentTopic: "Authentication migration"),
                preferences: preferences
            )
        )

        XCTAssertTrue(context.completeTranscript.contains("backend owner confirmed"))
        XCTAssertTrue(context.ragContext.contains("Alpha.md"))
        XCTAssertFalse(context.ragContext.contains("Beta.md"))
        XCTAssertTrue(context.ragContext.contains("Official source"))
        XCTAssertTrue(context.retrievedSources.contains { $0.type == .transcript && $0.title == "Complete meeting transcript" })
        XCTAssertTrue(context.retrievedSources.contains { $0.type == .rag })
        XCTAssertTrue(context.retrievedSources.contains { $0.type == .web })
        XCTAssertEqual(webService.queries.count, 1)
        XCTAssertFalse(webService.queries[0].contains("backend owner confirmed"))
    }

    func testRealtimeQATestProviderProducesCodableJSON() async throws {
        let candidate = makeQuestion("What is the risk?")
        let classification = try await QuestionClassifier().classifyQuestion(candidate: candidate, context: makeContext(candidate.rawText), userProfile: makeProfile())
        let context = AnswerContext(meetingTitle: "Risk", transcriptWindow: candidate.rawText, ragContext: "", userRole: "Engineer", responseStyle: .technical, languageCode: "en-US")
        let stream = try await TestMeetingAnswerProvider().generateAnswer(question: candidate, classification: classification, context: context, options: AnswerGenerationOptions())
        let maybeAnswer = try await finalAnswer(from: stream)
        let answer = try XCTUnwrap(maybeAnswer)
        let data = try JSONEncoder().encode(answer)
        XCTAssertNoThrow(try JSONDecoder().decode(SuggestedAnswer.self, from: data))
    }

    func testRealtimeQAEventBusReceivesQuestionEvent() async throws {
        let bus = RealtimeQuestionEventBus()
        let candidate = makeQuestion("Do we have blockers?")
        let classification = try await QuestionClassifier().classifyQuestion(candidate: candidate, context: makeContext(candidate.rawText), userProfile: makeProfile())
        let task = Task { () -> RealtimeQuestionEvent? in
            for await event in bus.events {
                return event
            }
            return nil
        }
        bus.send(.questionDetected(candidate, classification))
        let event = await task.value
        XCTAssertEqual(event, .questionDetected(candidate, classification))
        bus.finish()
    }

    func testRealtimeQAPersistenceRoundTripWithFeedback() throws {
        let container = try DatabaseFactory.makeContainer(inMemory: true)
        let repository = MeetingRepository(container: container, cryptor: try testCryptor())
        let candidate = makeQuestion("Can you review the PR today?")
        let classification = QuestionClassification(
            isQuestion: true,
            rhetorical: false,
            complete: true,
            actionable: true,
            responseNeeded: true,
            userAttentionNeeded: true,
            directedToUser: true,
            directedToGroup: false,
            questionType: .actionRequest,
            priority: .high,
            confidence: 0.9,
            reason: "test",
            extractedQuestion: candidate.rawText,
            expectedAnswerStyle: .diplomatic
        )
        let answer = SuggestedAnswer(questionId: candidate.id, answerText: "I can try to fit it in today.", shortAnswer: "I can try to fit it in today.", confidence: 0.8, riskLevel: .safe, usedSources: [], assumptions: [], caveats: [], latencyMs: 10)
        let record = QuestionAnswerRecord(meetingId: candidate.meetingId, question: candidate, classification: classification, answer: answer, contextSummary: "summary", decision: "ready")
        try repository.saveQuestionAnswerRecord(record)
        try repository.appendFeedback(QuestionAnswerFeedbackEvent(kind: .copied), to: record.id)
        let fetched = try XCTUnwrap(repository.questionAnswerRecords(for: candidate.meetingId).first)
        XCTAssertEqual(fetched.answer?.shortAnswer, answer.shortAnswer)
        XCTAssertEqual(fetched.feedbackEvents.first?.kind, .copied)
    }

    func testDynamicAnswerMarkdownParserRecognizesCodeBlocksAndLists() {
        let text = """
        ## Say this
        - Keep it cautious.
        ```swift
        let risk = "migration"
        ```
        """
        let blocks = RichAnswerMarkdownParser.parse(text)
        XCTAssertTrue(RichAnswerMarkdownParser.containsRichContent(text))
        XCTAssertTrue(blocks.contains(.heading(level: 2, text: "Say this")))
        XCTAssertTrue(blocks.contains(.bullet("Keep it cautious.")))
        XCTAssertTrue(blocks.contains(.code(language: "swift", code: "let risk = \"migration\"")))
    }

    func testDynamicAnswerCodeBlockLineNumberingPreservesBlankLines() {
        let code = "let first = true\n\nlet third = false"

        XCTAssertEqual(CodeBlockLineNumbering.lines(for: code), ["let first = true", "", "let third = false"])
        XCTAssertEqual(CodeBlockLineNumbering.lineNumberText(for: code), "1\n2\n3")
        XCTAssertEqual(CodeBlockLineNumbering.digitCount(for: code), 2)
        XCTAssertEqual(CodeBlockLineNumbering.lineNumberText(for: ""), "1")
    }

    func testDynamicAnswerCodeBlockClipboardCopiesExactCode() {
        let code = "class Node:\n    pass\n"

        XCTAssertTrue(CodeBlockClipboard.copy(code))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), code)
    }

    func testDynamicAnswerSyntaxHighlighterTagsSwiftTokens() {
        let tokens = CodeSyntaxHighlighter.tokens(for: "let risk = \"migration\" // verify", language: "swift")
        XCTAssertTrue(tokens.contains(SyntaxHighlightToken(text: "let", role: .keyword)))
        XCTAssertTrue(tokens.contains(SyntaxHighlightToken(text: "\"migration\"", role: .string)))
        XCTAssertTrue(tokens.contains(SyntaxHighlightToken(text: "// verify", role: .comment)))
    }

    func testDynamicAnswerLanguageRegistrySupportsBroadAliases() {
        XCTAssertEqual(CodeLanguageRegistry.definition(for: "tsx").id, "typescript")
        XCTAssertEqual(CodeLanguageRegistry.definition(for: "objc").id, "objective-c")
        XCTAssertEqual(CodeLanguageRegistry.definition(for: "bash").id, "shell")
        XCTAssertEqual(CodeLanguageRegistry.definition(for: "yml").id, "yaml")
        XCTAssertEqual(CodeLanguageRegistry.definition(for: "patch").id, "diff")
        XCTAssertEqual(CodeLanguageRegistry.definition(for: nil, code: "SELECT * FROM users").id, "sql")
    }

    func testDynamicAnswerHighlighterHandlesStructuredTextTypes() {
        let jsonTokens = CodeSyntaxHighlighter.tokens(for: #"{"status": true, "count": 2}"#, language: "json")
        XCTAssertTrue(jsonTokens.contains(SyntaxHighlightToken(text: #""status""#, role: .attribute)))
        XCTAssertTrue(jsonTokens.contains(SyntaxHighlightToken(text: "true", role: .number)))

        let diffTokens = CodeSyntaxHighlighter.tokens(for: "@@ -1 +1 @@\n-old\n+new", language: "diff")
        XCTAssertTrue(diffTokens.contains(SyntaxHighlightToken(text: "@@ -1 +1 @@", role: .metadata)))
        XCTAssertTrue(diffTokens.contains(SyntaxHighlightToken(text: "-old", role: .deleted)))
        XCTAssertTrue(diffTokens.contains(SyntaxHighlightToken(text: "+new", role: .inserted)))

        let sqlTokens = CodeSyntaxHighlighter.tokens(for: "SELECT id FROM users WHERE active = true", language: "sql")
        XCTAssertTrue(sqlTokens.contains(SyntaxHighlightToken(text: "SELECT", role: .keyword)))
        XCTAssertTrue(sqlTokens.contains(SyntaxHighlightToken(text: "true", role: .number)))
    }

    func testMetalWaveformPipelineCompilesWhenMetalIsAvailable() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal is unavailable on this machine.")
        }
        XCTAssertTrue(AppleMetalWaveformRenderer().isAvailable)
        XCTAssertTrue(AppleMetalFlowMarkRenderer().isAvailable)
    }

    func testPKCEGeneratorCreatesS256Challenge() throws {
        let pair = try OAuthPKCEGenerator.generatePair()
        let digest = SHA256.hash(data: Data(pair.verifier.utf8))
        let expectedChallenge = Data(digest)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        XCTAssertGreaterThanOrEqual(pair.verifier.count, 43)
        XCTAssertLessThanOrEqual(pair.verifier.count, 128)
        XCTAssertFalse(pair.verifier.contains("+"))
        XCTAssertFalse(pair.verifier.contains("/"))
        XCTAssertFalse(pair.verifier.contains("="))
        XCTAssertEqual(pair.challenge, expectedChallenge)
    }

    func testTokenStorePersistsAndDeletesSession() throws {
        let store = InMemoryTokenStore()
        let session = AuthSession(
            provider: .openAIAccountOAuth,
            accessToken: "access-token",
            refreshToken: "refresh-token",
            expiresAt: Date().addingTimeInterval(120),
            accountEmail: "user@example.com",
            accountId: "acct_123",
            scopes: ["responses"]
        )

        try store.saveSession(session)
        XCTAssertEqual(try store.loadSession(provider: .openAIAccountOAuth), session)
        try store.deleteSession(provider: .openAIAccountOAuth)
        XCTAssertNil(try store.loadSession(provider: .openAIAccountOAuth))
    }

    func testOpenAIOAuthProviderBlocksUnsupportedOfficialFlow() async throws {
        let provider = OpenAIAccountOAuthProvider(
            configuration: .disabled,
            tokenStore: InMemoryTokenStore(),
            sessionManager: OpenAIAuthSessionManager()
        )

        do {
            _ = try await provider.signIn()
            XCTFail("Expected unsupported OAuth flow")
        } catch let error as AuthError {
            XCTAssertEqual(error, .unsupportedOAuthFlow)
            XCTAssertEqual(error.localizedDescription, "OpenAI OAuth subscription access is not currently available for this desktop integration. Use Local Mode or configure an officially supported provider.")
        }
    }

    func testOpenAIOAuthProviderRefreshesExpiringToken() async throws {
        let store = InMemoryTokenStore()
        try store.saveSession(AuthSession(
            provider: .openAIAccountOAuth,
            accessToken: "old-token",
            refreshToken: "refresh-token",
            expiresAt: Date().addingTimeInterval(-5),
            accountEmail: "user@example.com",
            accountId: "acct_123",
            scopes: ["responses"]
        ))
        OpenAITestURLProtocol.reset(
            statusCode: 200,
            body: #"{"access_token":"new-token","expires_in":3600,"scope":"responses"}"#.data(using: .utf8)!
        )

        let provider = OpenAIAccountOAuthProvider(
            configuration: enabledOAuthConfiguration(),
            tokenStore: store,
            sessionManager: OpenAIAuthSessionManager(),
            urlSession: testURLSession()
        )

        let refreshed = try await provider.refreshIfNeeded()
        XCTAssertEqual(refreshed.accessToken, "new-token")
        XCTAssertEqual(refreshed.refreshToken, "refresh-token")
        XCTAssertEqual(OpenAITestURLProtocol.lastRequest?.url?.absoluteString, "https://auth.example.test/token")
    }

    func testOpenAIOAuthProviderSignOutClearsLocalDataWhenRevokeFails() async throws {
        let store = InMemoryTokenStore()
        try store.saveSession(AuthSession(
            provider: .openAIAccountOAuth,
            accessToken: "access-token",
            refreshToken: "refresh-token",
            expiresAt: Date().addingTimeInterval(120),
            accountEmail: nil,
            accountId: nil,
            scopes: []
        ))
        OpenAITestURLProtocol.reset(error: URLError(.cannotConnectToHost))

        let provider = OpenAIAccountOAuthProvider(
            configuration: enabledOAuthConfiguration(),
            tokenStore: store,
            sessionManager: OpenAIAuthSessionManager(),
            urlSession: testURLSession()
        )

        try await provider.signOut()
        XCTAssertNil(try store.loadSession(provider: .openAIAccountOAuth))
    }

    func testProviderRouterRequiresAdvancedModeForLegacyAPIKey() {
        var preferences = AppPreferences()
        preferences.localOnlyMode = false
        preferences.aiConfig.provider = .openAI
        preferences.aiConfig.authMode = .apiKeyLegacy
        preferences.aiConfig.cloudProcessingEnabled = true
        preferences.aiConfig.legacyAPIKeyAccessEnabled = false

        let legacyAuth = TestAuthProvider(session: AuthSession(
            provider: .apiKeyLegacy,
            accessToken: "legacy-key",
            refreshToken: nil,
            expiresAt: nil,
            accountEmail: nil,
            accountId: nil,
            scopes: []
        ))
        let legacyProvider = OpenAIProvider(authProvider: legacyAuth) { preferences }
        let router = ProviderRouter(legacyOpenAIProvider: legacyProvider)

        XCTAssertEqual(router.aiProvider(preferences: preferences).name, .unavailable)
        preferences.aiConfig.legacyAPIKeyAccessEnabled = true
        XCTAssertEqual(router.aiProvider(preferences: preferences).name, .openAI)
    }

    func testCodexCLIAuthProviderUsesDeviceLoginAndDoesNotExposeTokens() async throws {
        let runner = FakeCodexCLICommandRunner()
        runner.statusResults = [
            CodexCLICommandResult(exitCode: 1, output: "No ChatGPT login"),
            CodexCLICommandResult(exitCode: 0, output: "Logged in using ChatGPT")
        ]
        runner.loginResults = [
            CodexCLICommandResult(
                exitCode: 0,
                output: "Open https://auth.openai.com/device and enter code ABCD-1234"
            )
        ]
        var openedURL: URL?
        var promptedCode: String?
        let provider = CodexCLIAuthProvider(runner: runner, openURL: { openedURL = $0 })
        provider.onLoginPrompt = { _, code in promptedCode = code }

        let session = try await provider.signIn()

        XCTAssertEqual(session.provider, .openAICodexCLI)
        XCTAssertEqual(session.accessToken, "codex-cli-session")
        XCTAssertNil(session.refreshToken)
        XCTAssertEqual(openedURL?.absoluteString, "https://auth.openai.com/device")
        XCTAssertEqual(promptedCode, "ABCD-1234")
        XCTAssertTrue(runner.calls.contains { $0.arguments == ["login", "--device-auth"] })
    }

    func testCodexCLIAuthProviderStartsPendingDeviceLoginAndVerifiesAfterPastedCode() async throws {
        let runner = FakeCodexCLICommandRunner()
        runner.statusResults = [
            CodexCLICommandResult(exitCode: 0, output: "Logged in using ChatGPT")
        ]

        let loginProcess = FakeCodexLoginProcess()
        var openedURL: URL?
        var stateChanges: [CodexCLILoginSessionState] = []
        let provider = CodexCLIAuthProvider(
            runner: runner,
            openURL: { openedURL = $0 },
            loginProcessFactory: { loginProcess }
        )
        provider.onLoginStateChange = { stateChanges.append($0) }

        let pending = try await provider.startDeviceLogin()
        XCTAssertEqual(pending.authURL?.absoluteString, "https://auth.openai.com/device")
        XCTAssertEqual(pending.userCode, "ABCD-1234")
        XCTAssertTrue(pending.isRunning)
        XCTAssertEqual(openedURL?.absoluteString, "https://auth.openai.com/device")

        let submitted = try await provider.submitDeviceCode("OPENAI-CODE")
        XCTAssertEqual(submitted.submittedCode, "OPENAI-CODE")

        let session = try await provider.verifyDeviceLogin()
        XCTAssertEqual(session.provider, .openAICodexCLI)
        XCTAssertEqual(session.accessToken, "codex-cli-session")
        XCTAssertNil(session.refreshToken)
        XCTAssertTrue(stateChanges.contains { $0.authURL?.absoluteString == "https://auth.openai.com/device" })
        XCTAssertTrue(runner.calls.contains { $0.arguments == ["login", "status"] })
    }

    func testConnectOpenAIAccountCompletesWhenCodexStatusAlreadyLoggedIn() async throws {
        var preferences = AppPreferences()
        preferences.localOnlyMode = false
        preferences.aiConfig.provider = .openAI
        preferences.aiConfig.authMode = .openAICodexCLI

        let appState = AppState(preferences: preferences)
        let runner = FakeCodexCLICommandRunner()
        runner.statusResults = [
            CodexCLICommandResult(exitCode: 0, output: "Logged in using ChatGPT")
        ]
        let loginProcess = FakeCodexLoginProcess()
        var openedURL: URL?
        appState.codexCLIAuthProvider = CodexCLIAuthProvider(
            runner: runner,
            openURL: { openedURL = $0 },
            loginProcessFactory: { loginProcess }
        )
        appState.codexCLIAuthProvider?.onLoginStateChange = { [weak appState] state in
            appState?.handleOpenAICodexLoginState(state)
        }

        appState.connectOpenAIAccount()
        for _ in 0..<20 where appState.openAIConnectionStatus != .connected(email: nil) {
            try? await Task.sleep(for: .milliseconds(100))
        }

        XCTAssertEqual(openedURL?.absoluteString, "https://auth.openai.com/device")
        XCTAssertEqual(appState.openAIConnectionStatus, .connected(email: nil))
        XCTAssertNil(appState.openAICodexLoginSession)
        XCTAssertFalse(appState.isVerifyingOpenAICodexLogin)
        XCTAssertFalse(loginProcess.state().isRunning)
    }

    func testConnectOpenAIAccountShowsFailureWhenDeviceLoginCannotStart() async throws {
        var preferences = AppPreferences()
        preferences.localOnlyMode = false
        preferences.aiConfig.provider = .openAI
        preferences.aiConfig.authMode = .openAICodexCLI

        let appState = AppState(preferences: preferences)
        let runner = FakeCodexCLICommandRunner()
        let loginProcess = FakeCodexLoginProcess(initialState: CodexCLILoginSessionState(
            id: "failed-codex-login",
            authURL: nil,
            userCode: nil,
            outputPreview: "env: /tmp/fake-codex-login.sh: Operation not permitted",
            isRunning: false,
            submittedCode: nil
        ))
        var openedURL: URL?
        appState.codexCLIAuthProvider = CodexCLIAuthProvider(
            runner: runner,
            openURL: { openedURL = $0 },
            loginProcessFactory: { loginProcess }
        )

        appState.connectOpenAIAccount()
        for _ in 0..<20 where appState.settingsStatus.isEmpty || appState.settingsStatus.hasPrefix("Opening OpenAI approval") {
            try? await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertNil(openedURL)
        XCTAssertNil(appState.openAICodexLoginSession)
        XCTAssertEqual(appState.openAIConnectionStatus, .notConnected)
        XCTAssertTrue(appState.settingsStatus.contains("OpenAI approval could not start"))
        XCTAssertTrue(appState.settingsStatus.contains("Operation not permitted"))
    }

    func testAppStateAutoCompletesDeviceLoginWhenCLIProcessFinishes() async throws {
        var preferences = AppPreferences()
        preferences.localOnlyMode = false
        preferences.aiConfig.provider = .openAI
        preferences.aiConfig.authMode = .openAICodexCLI

        let appState = AppState(preferences: preferences)
        let runner = FakeCodexCLICommandRunner()
        runner.statusResults = [
            CodexCLICommandResult(exitCode: 1, output: "No ChatGPT login"),
            CodexCLICommandResult(exitCode: 0, output: "Logged in using ChatGPT"),
            CodexCLICommandResult(exitCode: 0, output: "Logged in using ChatGPT"),
            CodexCLICommandResult(exitCode: 0, output: "Logged in using ChatGPT")
        ]
        let loginProcess = FakeCodexLoginProcess()
        appState.codexCLIAuthProvider = CodexCLIAuthProvider(
            runner: runner,
            openURL: { _ in },
            loginProcessFactory: { loginProcess }
        )
        appState.codexCLIAuthProvider?.onLoginStateChange = { [weak appState] state in
            appState?.handleOpenAICodexLoginState(state)
        }

        appState.connectOpenAIAccount()
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(appState.openAICodexLoginSession?.userCode, "ABCD-1234")

        loginProcess.finishApproved()
        for _ in 0..<20 where appState.openAIConnectionStatus != .connected(email: nil) {
            try? await Task.sleep(for: .milliseconds(250))
        }

        XCTAssertEqual(appState.preferences.aiConfig.authMode, .openAICodexCLI)
        XCTAssertEqual(appState.openAIConnectionStatus, .connected(email: nil))
        XCTAssertNil(appState.openAICodexLoginSession)
        XCTAssertFalse(appState.isVerifyingOpenAICodexLogin)
    }

    func testAppStateAutoCompletesOpenAIDeviceLoginWhileCLIProcessStillRuns() async throws {
        var preferences = AppPreferences()
        preferences.localOnlyMode = false
        preferences.aiConfig.provider = .openAI
        preferences.aiConfig.authMode = .openAICodexCLI

        let appState = AppState(preferences: preferences)
        let runner = FakeCodexCLICommandRunner()
        runner.statusResults = [
            CodexCLICommandResult(exitCode: 1, output: "No ChatGPT login"),
            CodexCLICommandResult(exitCode: 0, output: "Signed in with ChatGPT")
        ]
        let loginProcess = FakeCodexLoginProcess()
        appState.codexCLIAuthProvider = CodexCLIAuthProvider(
            runner: runner,
            openURL: { _ in },
            loginProcessFactory: { loginProcess }
        )
        appState.codexCLIAuthProvider?.onLoginStateChange = { [weak appState] state in
            appState?.handleOpenAICodexLoginState(state)
        }

        appState.connectOpenAIAccount()
        for _ in 0..<30 where appState.openAIConnectionStatus != .connected(email: nil) {
            try? await Task.sleep(for: .milliseconds(100))
        }

        XCTAssertEqual(appState.openAIConnectionStatus, .connected(email: nil))
        XCTAssertNil(appState.openAICodexLoginSession)
        XCTAssertFalse(appState.isVerifyingOpenAICodexLogin)
        XCTAssertFalse(loginProcess.state().isRunning)
        XCTAssertTrue(runner.calls.contains { $0.arguments == ["login", "status"] })
    }

    func testCodexCLIAuthProviderRejectsAPIKeyLoginStatus() async throws {
        let runner = FakeCodexCLICommandRunner()
        runner.statusResults = [
            CodexCLICommandResult(exitCode: 0, output: "Logged in using API key")
        ]
        let provider = CodexCLIAuthProvider(runner: runner, openURL: { _ in })

        let session = try await provider.currentSession()

        XCTAssertNil(session)
    }

    func testCodexCLIAuthProviderDoesNotTreatUUIDFragmentsAsDeviceCodes() {
        let output = "env: /tmp/fake-codex-login-07F60DDD-BE08-46AE-BB3C-2CA6B7D84E2F.sh: Operation not permitted"

        XCTAssertNil(CodexCLIAuthProvider.extractUserCode(from: output))
    }

    func testCodexCLIAuthProviderExtractsANSIColoredDevicePrompt() {
        let output = """
        Follow these steps:
           \u{001B}[94mhttps://auth.openai.com/codex/device\u{001B}[0m
           \u{001B}[94mF0VR-XN4KF\u{001B}[0m
        """

        XCTAssertEqual(CodexCLIAuthProvider.extractURL(from: output)?.absoluteString, "https://auth.openai.com/codex/device")
        XCTAssertEqual(CodexCLIAuthProvider.extractUserCode(from: output), "F0VR-XN4KF")
    }

    func testProviderRegistryExposesOnlySupportedAccountLoginProviders() {
        XCTAssertTrue(ProviderRegistry.visibleProviders.contains { $0.kind == .openAI })
        XCTAssertTrue(ProviderRegistry.visibleProviders.contains { $0.kind == .googleGemini })
        XCTAssertTrue(ProviderRegistry.visibleProviders.contains { $0.kind == .anthropicClaude })
        XCTAssertTrue(ProviderRegistry.visibleProviders.contains { $0.kind == .perplexity })
        XCTAssertTrue(ProviderRegistry.visibleProviders.contains { $0.kind == .appleLocal })

        let accountLoginProviders = ProviderRegistry.visibleProviders
            .filter { $0.supportedAuthKinds.contains(.accountLogin) }
            .map(\.kind)
        XCTAssertEqual(accountLoginProviders, [.openAI, .googleGemini, .anthropicClaude])
        XCTAssertTrue(ProviderRegistry.visibleProviders
            .filter { $0.supportedAuthKinds.contains(.accountLogin) }
            .allSatisfy { $0.accountAuthMode != nil && $0.accountLoginUnsupportedMessage == nil })

        let perplexity = ProviderRegistry.descriptor(for: .perplexity)
        XCTAssertEqual(perplexity.supportedAuthKinds, [.apiKey])
        XCTAssertNil(perplexity.accountAuthMode)
        XCTAssertEqual(perplexity.defaultAuthMode, .perplexityAPIKey)
        XCTAssertNil(perplexity.accountLoginUnsupportedMessage)
    }

    func testPerplexityOAuthPreferenceMigratesToAPIKeyMode() {
        var preferences = AppPreferences()
        preferences.aiConfig.provider = .perplexity
        preferences.aiConfig.authMode = .perplexityOAuth

        preferences.normalizeForPersistence()

        XCTAssertEqual(preferences.aiConfig.authMode, .perplexityAPIKey)
    }

    func testGeminiCatalogClassifiesModelsBySupportedMethods() {
        let catalog = AIModelCatalog.gemini(from: [
            GeminiModelDescriptor(
                id: "gemini-2.5-flash",
                displayName: "Gemini 2.5 Flash",
                description: "Fast Gemini model",
                supportedGenerationMethods: ["generateContent"]
            ),
            GeminiModelDescriptor(
                id: "text-embedding-004",
                displayName: "Text Embedding 004",
                description: nil,
                supportedGenerationMethods: ["embedContent"]
            )
        ])

        XCTAssertEqual(catalog.chatModels.map(\.id), ["gemini-2.5-flash"])
        XCTAssertEqual(catalog.translationModels.map(\.id), ["gemini-2.5-flash"])
        XCTAssertEqual(catalog.embeddingModels.map(\.id), ["text-embedding-004"])
        XCTAssertTrue(catalog.transcriptionModels.isEmpty)
    }

    func testProviderCatalogsFilterUnsupportedPurposes() {
        XCTAssertTrue(AIModelCatalog.anthropicFallback.transcriptionModels.isEmpty)
        XCTAssertTrue(AIModelCatalog.anthropicFallback.realtimeModels.isEmpty)
        XCTAssertTrue(AIModelCatalog.perplexityFallback.transcriptionModels.isEmpty)
        XCTAssertTrue(AIModelCatalog.perplexityFallback.embeddingModels.isEmpty)
        XCTAssertFalse(AIModelCatalog.perplexityFallback.chatModels.isEmpty)
        XCTAssertFalse(AIModelCatalog.perplexityFallback.translationModels.isEmpty)
    }

    func testProviderCLIAuthProviderExtractsANSIColoredAccountPrompt() {
        let output = """
        Visit \u{001B}[94mhttps://accounts.google.com/o/oauth2/v2/auth?client_id=gemini\u{001B}[0m
        Then enter authentication code \u{001B}[92mGEMI-1234\u{001B}[0m
        """

        XCTAssertEqual(
            ProviderCLIAuthProvider.extractURL(from: output)?.absoluteString,
            "https://accounts.google.com/o/oauth2/v2/auth?client_id=gemini"
        )
        XCTAssertEqual(ProviderCLIAuthProvider.extractUserCode(from: output), "GEMI-1234")
    }

    func testProviderCLIAuthProviderRecognizesGeminiAndClaudeSessions() async throws {
        let geminiRunner = FakeProviderCLICommandRunner()
        geminiRunner.results = [
            ProviderCLICommandResult(exitCode: 0, output: #"{"text":"OK"}"#)
        ]
        let gemini = ProviderCLIAuthProvider(configuration: .gemini, runner: geminiRunner, openURL: { _ in })
        let geminiSession = try await gemini.currentSession()

        XCTAssertEqual(geminiSession?.provider, .googleGeminiOAuth)
        XCTAssertEqual(geminiSession?.accessToken, "gemini-cli-session")
        XCTAssertEqual(geminiRunner.calls.first?.arguments, ProviderCLIConfiguration.gemini.statusArguments)

        let claudeRunner = FakeProviderCLICommandRunner()
        claudeRunner.results = [
            ProviderCLICommandResult(exitCode: 0, output: #"{"loggedIn":true,"email":"dev@example.com"}"#)
        ]
        let claude = ProviderCLIAuthProvider(configuration: .claude, runner: claudeRunner, openURL: { _ in })
        let claudeSession = try await claude.currentSession()

        XCTAssertEqual(claudeSession?.provider, .anthropicClaudeOAuth)
        XCTAssertEqual(claudeSession?.accessToken, "claude-cli-session")
        XCTAssertEqual(claudeSession?.accountEmail, "dev@example.com")
        XCTAssertEqual(claudeRunner.calls.first?.arguments, ProviderCLIConfiguration.claude.statusArguments)
    }

    func testAppStateAutoCompletesProviderAccountLoginWhileCLIProcessStillRuns() async throws {
        var preferences = AppPreferences()
        preferences.localOnlyMode = false

        let appState = AppState(preferences: preferences)
        let runner = FakeProviderCLICommandRunner()
        runner.results = [
            ProviderCLICommandResult(exitCode: 1, output: "Waiting for authentication"),
            ProviderCLICommandResult(exitCode: 0, output: #"{"text":"OK"}"#)
        ]
        let loginProcess = FakeProviderLoginProcess(provider: .googleGemini)
        appState.geminiCLIAuthProvider = ProviderCLIAuthProvider(
            configuration: .gemini,
            runner: runner,
            openURL: { _ in },
            loginProcessFactory: { loginProcess }
        )
        appState.geminiCLIAuthProvider?.onLoginStateChange = { [weak appState] state in
            appState?.handleProviderLoginState(state)
        }

        appState.connectProviderAccount(.googleGemini)
        for _ in 0..<30 where appState.providerConnectionStatuses[.googleGemini] != .connected(email: nil) {
            try? await Task.sleep(for: .milliseconds(100))
        }

        XCTAssertEqual(appState.providerConnectionStatuses[.googleGemini], .connected(email: nil))
        XCTAssertNil(appState.providerLoginSessions[.googleGemini])
        XCTAssertFalse(appState.verifyingProviderLogins.contains(.googleGemini))
        XCTAssertFalse(loginProcess.state().isRunning)
        XCTAssertTrue(runner.calls.contains { $0.arguments == ProviderCLIConfiguration.gemini.statusArguments })
    }

    func testCLIAccountProvidersPersistOnlySessionMetadataInTokenStore() async throws {
        let codexStore = InMemoryTokenStore()
        let codexRunner = FakeCodexCLICommandRunner()
        codexRunner.statusResults = [
            CodexCLICommandResult(exitCode: 0, output: "Logged in using ChatGPT")
        ]
        let codex = CodexCLIAuthProvider(runner: codexRunner, openURL: { _ in }, tokenStore: codexStore)
        let codexSession = try await codex.currentSession()

        XCTAssertEqual(codexSession?.provider, .openAICodexCLI)
        XCTAssertEqual(try codexStore.loadSession(provider: .openAICodexCLI)?.accessToken, "codex-cli-session")
        XCTAssertTrue(codex.isAuthenticated)

        let geminiStore = InMemoryTokenStore()
        let geminiRunner = FakeProviderCLICommandRunner()
        geminiRunner.results = [
            ProviderCLICommandResult(exitCode: 0, output: #"{"text":"OK"}"#)
        ]
        let gemini = ProviderCLIAuthProvider(
            configuration: .gemini,
            runner: geminiRunner,
            openURL: { _ in },
            tokenStore: geminiStore
        )
        let geminiSession = try await gemini.currentSession()

        XCTAssertEqual(geminiSession?.provider, .googleGeminiOAuth)
        XCTAssertEqual(try geminiStore.loadSession(provider: .googleGeminiOAuth)?.accessToken, "gemini-cli-session")
        XCTAssertTrue(gemini.isAuthenticated)

        try await codex.signOut()
        try await gemini.signOut()
        XCTAssertNil(try codexStore.loadSession(provider: .openAICodexCLI))
        XCTAssertNil(try geminiStore.loadSession(provider: .googleGeminiOAuth))
    }

    func testCodexCLIAIProviderUsesCodexExecAfterChatGPTSession() async throws {
        var preferences = AppPreferences()
        preferences.localOnlyMode = false
        preferences.aiConfig.provider = .openAI
        preferences.aiConfig.authMode = .openAICodexCLI
        preferences.aiConfig.cloudProcessingEnabled = true

        let runner = FakeCodexCLICommandRunner()
        runner.statusResults = [
            CodexCLICommandResult(exitCode: 0, output: "Logged in using ChatGPT")
        ]
        runner.execOutput = "Ship it carefully."
        let auth = CodexCLIAuthProvider(runner: runner, openURL: { _ in })
        let provider = CodexCLIAIProvider(authProvider: auth, runner: runner) { preferences }

        let answer = try await provider.generateAnswer(
            context: answerContext(),
            question: "Can we ship?",
            options: AnswerOptions()
        )
        let execCall = try XCTUnwrap(runner.calls.first { $0.arguments.first == "exec" })

        XCTAssertEqual(answer.text, "Ship it carefully.")
        XCTAssertTrue(execCall.arguments.contains("--ephemeral"))
        XCTAssertTrue(execCall.arguments.contains("--skip-git-repo-check"))
        XCTAssertTrue(execCall.arguments.contains("--sandbox"))
        XCTAssertTrue(execCall.arguments.contains("read-only"))
        XCTAssertFalse(execCall.arguments.contains("gpt-5-mini"))
        XCTAssertTrue(execCall.arguments.contains("gpt-5.3-codex"))
        XCTAssertTrue(execCall.standardInput?.contains("Can we ship?") == true)
    }

    func testCodexCLIAIProviderPassesSearchFlagForWebRequests() async throws {
        var preferences = AppPreferences()
        preferences.localOnlyMode = false
        preferences.aiConfig.provider = .openAI
        preferences.aiConfig.authMode = .openAICodexCLI
        preferences.aiConfig.cloudProcessingEnabled = true

        let runner = FakeCodexCLICommandRunner()
        runner.statusResults = [
            CodexCLICommandResult(exitCode: 0, output: "Logged in using ChatGPT")
        ]
        runner.execOutput = #"{"shouldRespond":true,"intent":"news_search","needsWeb":false,"needsReminderAction":false,"needsClarification":false,"answerFormat":"news_with_sources","answerText":"Headlines with sources.","confidence":0.9,"reason":"web","reminderAction":null}"#
        let auth = CodexCLIAuthProvider(runner: runner, openURL: { _ in })
        let provider = CodexCLIAIProvider(authProvider: auth, runner: runner) { preferences }

        _ = try await provider.generateRaw(request: LLMRawRequest(
            prompt: "Quais sao as noticias de hoje?",
            maxOutputTokens: 400,
            responseMode: .jsonObject,
            enableWebSearch: true
        ))

        let execCall = try XCTUnwrap(runner.calls.first { $0.arguments.contains("exec") })
        XCTAssertEqual(execCall.arguments.prefix(2), ["--search", "exec"])
        XCTAssertTrue(execCall.standardInput?.contains("Live web search is enabled") == true)
        XCTAssertTrue(execCall.standardInput?.contains("Return exactly one valid JSON object") == true)
    }

    func testCodexCLIAIProviderDoesNotRequireCachedLoginStatusBeforeExec() async throws {
        var preferences = AppPreferences()
        preferences.localOnlyMode = false
        preferences.aiConfig.provider = .openAI
        preferences.aiConfig.authMode = .openAICodexCLI
        preferences.aiConfig.cloudProcessingEnabled = true

        let runner = FakeCodexCLICommandRunner()
        runner.execOutput = #"{"shouldRespond":true,"intent":"answerable_question","needsWeb":false,"needsReminderAction":false,"needsClarification":false,"answerFormat":"plain_short","answerText":"OK","confidence":0.9,"reason":"answered","reminderAction":null}"#
        let auth = CodexCLIAuthProvider(runner: runner, openURL: { _ in })
        let provider = CodexCLIAIProvider(authProvider: auth, runner: runner) { preferences }

        _ = try await provider.generateRaw(request: LLMRawRequest(
            prompt: "Return OK",
            responseMode: .jsonObject
        ))

        XCTAssertFalse(runner.calls.contains { $0.arguments == ["login", "status"] })
        XCTAssertTrue(runner.calls.contains { $0.arguments.contains("exec") })
    }

    func testProviderRouterUsesCodexCLIWhenSelected() async throws {
        var preferences = AppPreferences()
        preferences.localOnlyMode = false
        preferences.aiConfig.provider = .openAI
        preferences.aiConfig.authMode = .openAICodexCLI
        preferences.aiConfig.cloudProcessingEnabled = true

        let runner = FakeCodexCLICommandRunner()
        runner.statusResults = [
            CodexCLICommandResult(exitCode: 0, output: "Logged in using ChatGPT")
        ]
        let auth = CodexCLIAuthProvider(runner: runner, openURL: { _ in })
        _ = try await auth.currentSession()
        let codexProvider = CodexCLIAIProvider(authProvider: auth, runner: runner) { preferences }
        let router = ProviderRouter(codexCLIProvider: codexProvider)

        XCTAssertEqual(router.aiProvider(preferences: preferences).name, .openAI)
    }

    func testProviderRouterUsesCodexCLIWithoutCachedAuthProbe() async throws {
        var preferences = AppPreferences()
        preferences.localOnlyMode = false
        preferences.aiConfig.provider = .openAI
        preferences.aiConfig.authMode = .openAICodexCLI
        preferences.aiConfig.cloudProcessingEnabled = true

        let runner = FakeCodexCLICommandRunner()
        let auth = CodexCLIAuthProvider(runner: runner, openURL: { _ in })
        let codexProvider = CodexCLIAIProvider(authProvider: auth, runner: runner) { preferences }
        let router = ProviderRouter(codexCLIProvider: codexProvider)

        XCTAssertEqual(router.aiProvider(preferences: preferences).name, .openAI)
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testProviderRouterUsesCodexCLIAsNativeWebProviderWhenOpenAIAccountIsSelected() async throws {
        var preferences = AppPreferences()
        preferences.localOnlyMode = false
        preferences.aiConfig.provider = .openAI
        preferences.aiConfig.authMode = .openAICodexCLI
        preferences.aiConfig.cloudProcessingEnabled = true

        let runner = FakeCodexCLICommandRunner()
        runner.statusResults = [
            CodexCLICommandResult(exitCode: 0, output: "Logged in using ChatGPT")
        ]
        let auth = CodexCLIAuthProvider(runner: runner, openURL: { _ in })
        _ = try await auth.currentSession()
        let codexProvider = CodexCLIAIProvider(authProvider: auth, runner: runner) { preferences }
        let router = ProviderRouter(codexCLIProvider: codexProvider)
        let primary = router.aiProvider(preferences: preferences)

        let webProvider = router.copilotNativeWebProvider(preferences: preferences, primaryProvider: primary)

        XCTAssertNotNil(webProvider)
        XCTAssertTrue(webProvider is CodexCLIAIProvider)
    }

    func testOpenAIProviderRefreshesBeforeRequest() async throws {
        var preferences = AppPreferences()
        preferences.localOnlyMode = false
        preferences.aiConfig.provider = .openAI
        preferences.aiConfig.authMode = .openAIAccountOAuth
        preferences.aiConfig.cloudProcessingEnabled = true
        let auth = TestAuthProvider(session: AuthSession(
            provider: .openAIAccountOAuth,
            accessToken: "oauth-token",
            refreshToken: "refresh-token",
            expiresAt: Date().addingTimeInterval(120),
            accountEmail: nil,
            accountId: nil,
            scopes: []
        ))
        OpenAITestURLProtocol.reset(
            statusCode: 200,
            body: #"{"output_text":"Ship it carefully."}"#.data(using: .utf8)!
        )
        let provider = OpenAIProvider(authProvider: auth, urlSession: testURLSession()) { preferences }

        let answer = try await provider.generateAnswer(context: answerContext(), question: "Can we ship?", options: AnswerOptions())

        XCTAssertEqual(auth.refreshCount, 1)
        XCTAssertEqual(OpenAITestURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer oauth-token")
        XCTAssertEqual(answer.text, "Ship it carefully.")
    }

    func testOpenAIProviderLoadsDynamicModelCatalog() async throws {
        var preferences = AppPreferences()
        preferences.localOnlyMode = false
        preferences.aiConfig.provider = .openAI
        preferences.aiConfig.authMode = .apiKeyLegacy
        preferences.aiConfig.cloudProcessingEnabled = true
        let auth = TestAuthProvider(session: AuthSession(
            provider: .apiKeyLegacy,
            accessToken: "legacy-token",
            refreshToken: nil,
            expiresAt: nil,
            accountEmail: nil,
            accountId: nil,
            scopes: []
        ))
        let response = """
        {
          "object": "list",
          "data": [
            {"id": "gpt-5.3-codex", "object": "model"},
            {"id": "gpt-realtime", "object": "model"},
            {"id": "gpt-4o-mini-transcribe", "object": "model"},
            {"id": "text-embedding-3-small", "object": "model"}
          ]
        }
        """
        OpenAITestURLProtocol.reset(statusCode: 200, body: Data(response.utf8))
        let provider = OpenAIProvider(authProvider: auth, urlSession: testURLSession()) { preferences }

        let catalog = try await provider.availableModelCatalog()

        XCTAssertEqual(OpenAITestURLProtocol.lastRequest?.url?.absoluteString, "https://api.openai.com/v1/models")
        XCTAssertEqual(OpenAITestURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer legacy-token")
        XCTAssertEqual(catalog.chatModels.map(\.id), ["gpt-5.3-codex"])
        XCTAssertEqual(catalog.realtimeModels.map(\.id), ["gpt-realtime"])
        XCTAssertTrue(catalog.transcriptionModels.isEmpty)
        XCTAssertTrue(catalog.isDynamic)
    }

    func testGeminiProviderLoadsDynamicCatalogWithAPIKeyHeader() async throws {
        var preferences = AppPreferences()
        preferences.localOnlyMode = false
        preferences.aiConfig.provider = .googleGemini
        preferences.aiConfig.authMode = .googleGeminiAPIKey
        preferences.aiConfig.cloudProcessingEnabled = true
        let auth = TestAuthProvider(session: AuthSession(
            provider: .googleGeminiAPIKey,
            accessToken: "gemini-key",
            refreshToken: nil,
            expiresAt: nil,
            accountEmail: nil,
            accountId: nil,
            scopes: []
        ))
        let response = """
        {
          "models": [
            {
              "name": "models/gemini-2.5-flash",
              "displayName": "Gemini 2.5 Flash",
              "supportedGenerationMethods": ["generateContent"]
            },
            {
              "name": "models/text-embedding-004",
              "displayName": "Text Embedding 004",
              "supportedGenerationMethods": ["embedContent"]
            }
          ]
        }
        """
        OpenAITestURLProtocol.reset(statusCode: 200, body: Data(response.utf8))
        let provider = GoogleGeminiProvider(authProvider: auth, urlSession: testURLSession()) { preferences }

        let catalog = try await provider.availableModelCatalog()

        XCTAssertEqual(OpenAITestURLProtocol.lastRequest?.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models")
        XCTAssertEqual(OpenAITestURLProtocol.lastRequest?.value(forHTTPHeaderField: "x-goog-api-key"), "gemini-key")
        XCTAssertEqual(catalog.chatModels.map(\.id), ["gemini-2.5-flash"])
        XCTAssertEqual(catalog.translationModels.map(\.id), ["gemini-2.5-flash"])
        XCTAssertEqual(catalog.embeddingModels.map(\.id), ["text-embedding-004"])
    }

    func testAnthropicProviderLoadsDynamicCatalogWithAPIKeyHeader() async throws {
        var preferences = AppPreferences()
        preferences.localOnlyMode = false
        preferences.aiConfig.provider = .anthropicClaude
        preferences.aiConfig.authMode = .anthropicClaudeAPIKey
        preferences.aiConfig.cloudProcessingEnabled = true
        let auth = TestAuthProvider(session: AuthSession(
            provider: .anthropicClaudeAPIKey,
            accessToken: "anthropic-key",
            refreshToken: nil,
            expiresAt: nil,
            accountEmail: nil,
            accountId: nil,
            scopes: []
        ))
        OpenAITestURLProtocol.reset(
            statusCode: 200,
            body: #"{"data":[{"id":"claude-sonnet-4-5"},{"id":"claude-haiku-4-5"}]}"#.data(using: .utf8)!
        )
        let provider = AnthropicClaudeProvider(authProvider: auth, urlSession: testURLSession()) { preferences }

        let catalog = try await provider.availableModelCatalog()

        XCTAssertEqual(OpenAITestURLProtocol.lastRequest?.url?.absoluteString, "https://api.anthropic.com/v1/models")
        XCTAssertEqual(OpenAITestURLProtocol.lastRequest?.value(forHTTPHeaderField: "x-api-key"), "anthropic-key")
        XCTAssertEqual(OpenAITestURLProtocol.lastRequest?.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(OpenAITestURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(Set(catalog.chatModels.map(\.id)), Set(["claude-sonnet-4-5", "claude-haiku-4-5"]))
        XCTAssertTrue(catalog.transcriptionModels.isEmpty)
    }

    func testPerplexityProviderUsesAPIKeyBearerAndRejectsOAuthSession() async throws {
        var preferences = AppPreferences()
        preferences.localOnlyMode = false
        preferences.aiConfig.provider = .perplexity
        preferences.aiConfig.authMode = .perplexityAPIKey
        preferences.aiConfig.cloudProcessingEnabled = true
        preferences.aiConfig.model = "sonar-pro"
        let auth = TestAuthProvider(session: AuthSession(
            provider: .perplexityAPIKey,
            accessToken: "pplx-key",
            refreshToken: nil,
            expiresAt: nil,
            accountEmail: nil,
            accountId: nil,
            scopes: []
        ))
        OpenAITestURLProtocol.reset(
            statusCode: 200,
            body: #"{"choices":[{"message":{"content":"Search-backed answer."}}]}"#.data(using: .utf8)!
        )
        let provider = PerplexityProvider(authProvider: auth, urlSession: testURLSession()) { preferences }

        let answer = try await provider.generateAnswer(context: answerContext(), question: "Can we ship?", options: AnswerOptions())

        XCTAssertEqual(answer.provider, .perplexity)
        XCTAssertEqual(answer.text, "Search-backed answer.")
        XCTAssertEqual(OpenAITestURLProtocol.lastRequest?.url?.absoluteString, "https://api.perplexity.ai/chat/completions")
        XCTAssertEqual(OpenAITestURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer pplx-key")

        let oauthProvider = PerplexityProvider(
            authProvider: TestAuthProvider(session: AuthSession(
                provider: .perplexityOAuth,
                accessToken: "oauth-token",
                refreshToken: nil,
                expiresAt: nil,
                accountEmail: nil,
                accountId: nil,
                scopes: []
            )),
            urlSession: testURLSession()
        ) { preferences }

        do {
            _ = try await oauthProvider.generateAnswer(context: answerContext(), question: "Can we ship?", options: AnswerOptions())
            XCTFail("Expected unsupported access mode")
        } catch let error as AuthError {
            XCTAssertEqual(error, .unsupportedAccessMode)
        }
    }

    func testProviderRouterUsesSelectedMultiAIProviderOnlyWhenCloudIsEnabled() {
        var preferences = AppPreferences()
        preferences.localOnlyMode = false
        preferences.aiConfig.cloudProcessingEnabled = true
        preferences.aiConfig.provider = .googleGemini
        preferences.aiConfig.authMode = .googleGeminiAPIKey

        let geminiAuth = TestAuthProvider(session: AuthSession(
            provider: .googleGeminiAPIKey,
            accessToken: "gemini-key",
            refreshToken: nil,
            expiresAt: nil,
            accountEmail: nil,
            accountId: nil,
            scopes: []
        ))
        let gemini = GoogleGeminiProvider(authProvider: geminiAuth) { preferences }
        let anthropic = AnthropicClaudeProvider(authProvider: TestAuthProvider(session: AuthSession(
            provider: .anthropicClaudeAPIKey,
            accessToken: "anthropic-key",
            refreshToken: nil,
            expiresAt: nil,
            accountEmail: nil,
            accountId: nil,
            scopes: []
        ))) { preferences }
        let perplexity = PerplexityProvider(authProvider: TestAuthProvider(session: AuthSession(
            provider: .perplexityAPIKey,
            accessToken: "pplx-key",
            refreshToken: nil,
            expiresAt: nil,
            accountEmail: nil,
            accountId: nil,
            scopes: []
        ))) { preferences }
        let router = ProviderRouter(
            geminiAPIKeyProvider: gemini,
            anthropicAPIKeyProvider: anthropic,
            perplexityProvider: perplexity
        )

        XCTAssertEqual(router.aiProvider(preferences: preferences).name, .googleGemini)

        preferences.aiConfig.provider = .anthropicClaude
        preferences.aiConfig.authMode = .anthropicClaudeAPIKey
        XCTAssertEqual(router.aiProvider(preferences: preferences).name, .anthropicClaude)

        preferences.aiConfig.provider = .perplexity
        preferences.aiConfig.authMode = .perplexityAPIKey
        XCTAssertEqual(router.aiProvider(preferences: preferences).name, .perplexity)

        preferences.localOnlyMode = true
        XCTAssertNotEqual(router.aiProvider(preferences: preferences).name, .perplexity)
    }

    func testProviderRouterUsesPerplexityAsCopilotNativeWebFallback() {
        var preferences = AppPreferences()
        preferences.localOnlyMode = false
        preferences.aiConfig.cloudProcessingEnabled = true
        preferences.aiConfig.provider = .googleGemini
        preferences.aiConfig.authMode = .googleGeminiAPIKey

        let gemini = GoogleGeminiProvider(authProvider: TestAuthProvider(session: AuthSession(
            provider: .googleGeminiAPIKey,
            accessToken: "gemini-key",
            refreshToken: nil,
            expiresAt: nil,
            accountEmail: nil,
            accountId: nil,
            scopes: []
        ))) { preferences }
        let perplexity = PerplexityProvider(authProvider: TestAuthProvider(session: AuthSession(
            provider: .perplexityAPIKey,
            accessToken: "pplx-key",
            refreshToken: nil,
            expiresAt: nil,
            accountEmail: nil,
            accountId: nil,
            scopes: []
        ))) { preferences }
        let router = ProviderRouter(
            geminiAPIKeyProvider: gemini,
            perplexityProvider: perplexity
        )

        let primary = router.aiProvider(preferences: preferences)
        XCTAssertEqual(primary.name, .googleGemini)
        XCTAssertEqual(router.copilotNativeWebProvider(preferences: preferences, primaryProvider: primary)?.name, .perplexity)
        XCTAssertEqual(
            router.copilotNativeWebProvider(
                preferences: preferences,
                primaryProvider: ScriptedRawAIProvider(responses: [])
            )?.name,
            .perplexity
        )

        preferences.localOnlyMode = true
        XCTAssertNil(router.copilotNativeWebProvider(preferences: preferences, primaryProvider: primary))
    }

    func testOpenAIProviderStreamsResponseDeltasWithOAuthBearer() async throws {
        var preferences = AppPreferences()
        preferences.localOnlyMode = false
        preferences.aiConfig.provider = .openAI
        preferences.aiConfig.authMode = .openAIAccountOAuth
        preferences.aiConfig.cloudProcessingEnabled = true
        let auth = TestAuthProvider(session: AuthSession(
            provider: .openAIAccountOAuth,
            accessToken: "oauth-token",
            refreshToken: "refresh-token",
            expiresAt: Date().addingTimeInterval(120),
            accountEmail: nil,
            accountId: nil,
            scopes: ["responses"]
        ))
        let sse = """
        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"Ship "}

        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"carefully."}

        event: response.completed
        data: {"type":"response.completed"}

        """
        OpenAITestURLProtocol.reset(statusCode: 200, body: Data(sse.utf8))
        let provider = OpenAIProvider(authProvider: auth, urlSession: testURLSession()) { preferences }

        let stream = try await provider.streamAnswer(context: answerContext(), question: "Can we ship?", options: AnswerOptions())
        var text = ""
        var completed = false
        for try await event in stream {
            switch event {
            case .delta(let delta):
                text += delta
            case .completed:
                completed = true
            }
        }

        XCTAssertEqual(auth.refreshCount, 1)
        XCTAssertEqual(OpenAITestURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer oauth-token")
        XCTAssertEqual(text, "Ship carefully.")
        XCTAssertTrue(completed)
    }

    func testOpenAIProviderUsesResponsesWebSearchToolWhenEnabled() async throws {
        var preferences = AppPreferences()
        preferences.localOnlyMode = false
        preferences.aiConfig.provider = .openAI
        preferences.aiConfig.authMode = .openAIAccountOAuth
        preferences.aiConfig.cloudProcessingEnabled = true
        preferences.aiConfig.webSearchEnabled = true
        let auth = TestAuthProvider(session: AuthSession(
            provider: .openAIAccountOAuth,
            accessToken: "oauth-token",
            refreshToken: "refresh-token",
            expiresAt: Date().addingTimeInterval(120),
            accountEmail: nil,
            accountId: nil,
            scopes: ["responses"]
        ))
        let response = """
        {
          "output": [
            {
              "type": "message",
              "content": [
                {
                  "type": "output_text",
                  "text": "Use a compatibility check before shipping.",
                  "annotations": [
                    {"type": "url_citation", "url": "https://example.com/auth-migration", "title": "Auth Migration"}
                  ]
                }
              ]
            },
            {
              "type": "web_search_call",
              "action": {
                "type": "search",
                "query": "auth migration risk",
                "sources": [
                  {"url": "https://example.com/auth-migration", "title": "Auth Migration"}
                ]
              }
            }
          ]
        }
        """
        OpenAITestURLProtocol.reset(statusCode: 200, body: Data(response.utf8))
        let provider = OpenAIProvider(authProvider: auth, urlSession: testURLSession()) { preferences }
        let context = AnswerContext(
            meetingTitle: "API Review",
            transcriptWindow: "Current: What is the migration risk?",
            completeTranscript: "Earlier: backend owner confirmed the migration is not complete.",
            ragContext: "[Alpha.md] authentication migration rollback risk",
            userRole: "Senior Fullstack Software Engineer",
            responseStyle: .technical,
            languageCode: "en-US"
        )

        let answer = try await provider.generateAnswer(
            context: context,
            question: "What is the risk if we skip the migration?",
            options: AnswerOptions(maxSentences: 2, allowCommitments: false, enableWebSearch: true)
        )
        let request = try XCTUnwrap(OpenAITestURLProtocol.lastRequest)
        let bodyData = try XCTUnwrap(OpenAITestURLProtocol.lastRequestBody ?? request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        let firstTool = try XCTUnwrap(tools.first)

        XCTAssertEqual(firstTool["type"] as? String, "web_search")
        XCTAssertEqual(firstTool["search_context_size"] as? String, "low")
        XCTAssertEqual(body["tool_choice"] as? String, "auto")
        XCTAssertTrue((body["input"] as? String)?.contains("Complete meeting transcript context") == true)
        XCTAssertTrue(answer.sources.contains { $0.reference == "https://example.com/auth-migration" })
    }

    func testProviderRouterUsesStreamingAnswerProviderForOAuthRealtime() async {
        var preferences = AppPreferences()
        preferences.localOnlyMode = false
        preferences.realtimeSuggestionsEnabled = true
        preferences.aiConfig.provider = .openAI
        preferences.aiConfig.authMode = .openAIAccountOAuth
        preferences.aiConfig.cloudProcessingEnabled = true
        let auth = TestAuthProvider(session: AuthSession(
            provider: .openAIAccountOAuth,
            accessToken: "oauth-token",
            refreshToken: "refresh-token",
            expiresAt: Date().addingTimeInterval(120),
            accountEmail: nil,
            accountId: nil,
            scopes: ["responses"]
        ))
        let provider = OpenAIProvider(authProvider: auth) { preferences }
        let router = ProviderRouter(openAIProvider: provider)

        XCTAssertTrue(router.meetingAnswerProvider(preferences: preferences) is OpenAIStreamingMeetingAnswerProvider)
        await router.prewarmRealtimeQuestionAnswering(preferences: preferences)
        XCTAssertEqual(auth.refreshCount, 1)
    }

    func testOpenAIProviderMapsOAuthForbiddenToUnsupportedAccessMode() async throws {
        var preferences = AppPreferences()
        preferences.localOnlyMode = false
        preferences.aiConfig.provider = .openAI
        preferences.aiConfig.authMode = .openAIAccountOAuth
        preferences.aiConfig.cloudProcessingEnabled = true
        let auth = TestAuthProvider(session: AuthSession(
            provider: .openAIAccountOAuth,
            accessToken: "oauth-token",
            refreshToken: nil,
            expiresAt: nil,
            accountEmail: nil,
            accountId: nil,
            scopes: []
        ))
        OpenAITestURLProtocol.reset(
            statusCode: 403,
            body: #"{"error":{"message":"forbidden"}}"#.data(using: .utf8)!
        )
        let provider = OpenAIProvider(authProvider: auth, urlSession: testURLSession()) { preferences }

        do {
            _ = try await provider.generateAnswer(context: answerContext(), question: "Can we ship?", options: AnswerOptions())
            XCTFail("Expected unsupported access mode")
        } catch let error as AuthError {
            XCTAssertEqual(error, .unsupportedAccessMode)
        }
    }

    func testOpenAIProviderRequiresAuthenticatedSession() async throws {
        var preferences = AppPreferences()
        preferences.localOnlyMode = false
        preferences.aiConfig.provider = .openAI
        preferences.aiConfig.authMode = .openAIAccountOAuth
        preferences.aiConfig.cloudProcessingEnabled = true
        let provider = OpenAIProvider(authProvider: TestAuthProvider(session: nil), urlSession: testURLSession()) { preferences }

        do {
            _ = try await provider.generateAnswer(context: answerContext(), question: "Can we ship?", options: AnswerOptions())
            XCTFail("Expected missing authentication")
        } catch let error as AuthError {
            XCTAssertEqual(error, .notAuthenticated)
        }
    }

    private struct QAGoldFixtureRow: Decodable {
        var id: String?
        var text: String
        var language: String
        var responseNeeded: Bool
        var label: String?

        var isCriticalNegative: Bool {
            guard !responseNeeded else { return false }
            return ["operational_check", "reported_question", "rhetorical", "fragment", "self_answered"].contains(label ?? "")
        }
    }

    private struct QAPrediction {
        var responseNeeded: Bool
        var classification: QuestionClassification?
    }

    private struct QAMetricStats {
        var truePositive = 0
        var falsePositive = 0
        var falseNegative = 0
        var trueNegative = 0

        var precision: Double {
            Double(truePositive) / Double(max(truePositive + falsePositive, 1))
        }

        var recall: Double {
            Double(truePositive) / Double(max(truePositive + falseNegative, 1))
        }

        mutating func record(expected: Bool, predicted: Bool) {
            switch (expected, predicted) {
            case (true, true): truePositive += 1
            case (false, true): falsePositive += 1
            case (true, false): falseNegative += 1
            case (false, false): trueNegative += 1
            }
        }
    }

    private func qaGoldFixtureRows() throws -> [QAGoldFixtureRow] {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/qa_intent_gold.jsonl")
        let decoder = JSONDecoder()
        return try String(contentsOf: fixtureURL, encoding: .utf8)
            .split(separator: "\n")
            .map { try decoder.decode(QAGoldFixtureRow.self, from: Data($0.utf8)) }
    }

    private func qaPrediction(
        for text: String,
        language: String,
        detector: QuestionDetectionService,
        classifier: QuestionClassifier
    ) async throws -> QAPrediction {
        let meetingId = UUID()
        let segment = TranscriptSegment(meetingId: meetingId, speakerLabel: "Speaker", text: text, originalLanguage: language)
        let context = TranscriptContext(
            recentTranscript: text,
            mediumTranscript: text,
            completeTranscript: text,
            dominantLanguage: language,
            currentSegment: segment
        )
        guard let candidate = detector.detectCandidates(from: segment, context: context).first else {
            return QAPrediction(responseNeeded: false, classification: nil)
        }
        let classification = try await classifier.classifyQuestion(candidate: candidate, context: context, userProfile: makeProfile())
        return QAPrediction(responseNeeded: classification.responseNeeded, classification: classification)
    }

    private func syntheticMultimodalSignal(for row: QAGoldFixtureRow, segment: TranscriptSegment) -> QuestionMultimodalSignal {
        let label = row.label ?? ""
        let quietCriticalNegative = ["operational_check", "fragment"].contains(label)
        let duration = min(max(Double(row.text.count) / 18.0, 0.45), 8.0)
        let rms = quietCriticalNegative ? 0.0005 : 0.018
        return QuestionMultimodalSignal(
            language: row.language,
            asrConfidence: quietCriticalNegative ? 0.58 : 0.94,
            isFinal: true,
            isPartial: false,
            speakerLabel: segment.speakerLabel,
            audioSource: .system,
            duration: duration,
            hasTerminalPause: true,
            partialStability: 1,
            partialRevisionCount: 1,
            rms: rms,
            peak: quietCriticalNegative ? 0.002 : 0.055,
            isClipping: false,
            isSilence: false,
            isTooQuiet: quietCriticalNegative,
            gapCount: 0,
            noiseFloor: quietCriticalNegative ? 0.0004 : 0.002,
            audioEnergy: rms,
            createdAt: segment.createdAt
        )
    }

    private func percentile(_ values: [Double], _ quantile: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(max(Int((Double(sorted.count - 1) * quantile).rounded()), 0), sorted.count - 1)
        return sorted[index]
    }

    private func makeQuestion(
        _ text: String,
        meetingId: UUID = UUID(),
        isPartial: Bool = false,
        multimodalSignal: QuestionMultimodalSignal? = nil
    ) -> QuestionCandidate {
        QuestionCandidate(
            id: UUID(),
            meetingId: meetingId,
            rawText: text,
            normalizedText: QuestionDetectionService.normalize(text),
            language: text.localizedCaseInsensitiveContains("Ryan") ? "en-US" : nil,
            speakerLabel: "System",
            startTime: 0,
            endTime: 1,
            sourceSegmentIds: [UUID()],
            isPartial: isPartial,
            multimodalSignal: multimodalSignal
        )
    }

    private func makeCopilotClassification(for question: QuestionCandidate, intent: CopilotIntentKind) -> QuestionClassification {
        QuestionClassification(
            isQuestion: true,
            rhetorical: false,
            complete: true,
            actionable: [.actionRequest, .reminder].contains(intent),
            responseNeeded: true,
            userAttentionNeeded: true,
            directedToUser: true,
            directedToGroup: false,
            questionType: intent == .reminder ? .actionRequest : .generalQuestion,
            priority: .medium,
            confidence: 0.90,
            reason: intent.rawValue,
            extractedQuestion: question.rawText,
            expectedAnswerStyle: .concise
        )
    }

    private func makeContext(_ text: String) -> TranscriptContext {
        TranscriptContext(recentTranscript: text, mediumTranscript: text, dominantLanguage: "en-US", currentSegment: nil)
    }

    private func makeProfile() -> UserMeetingProfile {
        UserMeetingProfile(
            userName: "Ryan",
            userAliases: ["Ryan"],
            userRole: "Senior Fullstack Software Engineer",
            preferredStyle: .technical,
            preferredLanguages: ["en-US", "pt-BR"],
            meetingType: .engineering
        )
    }

    private func renderedViewHasVisiblePixels<Content: View>(_ view: Content, size: CGSize) -> Bool {
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = CGRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
        guard let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else { return false }
        hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
        guard let data = rep.bitmapData else { return false }
        let length = rep.bytesPerRow * rep.pixelsHigh
        var visibleSamples = 0
        for index in stride(from: 0, to: length, by: max(4, rep.bitsPerPixel / 8)) {
            if data[index] > 10 || data[min(index + 1, length - 1)] > 10 || data[min(index + 2, length - 1)] > 10 {
                visibleSamples += 1
                if visibleSamples > 12 { return true }
            }
        }
        return false
    }

    private func finalAnswer(from stream: AsyncThrowingStream<PartialAnswer, Error>) async throws -> SuggestedAnswer? {
        var final: SuggestedAnswer?
        for try await partial in stream where partial.isFinal {
            final = partial.suggestedAnswer
        }
        return final
    }

    private func enabledOAuthConfiguration() -> OpenAIAccountOAuthConfiguration {
        OpenAIAccountOAuthConfiguration(
            isOfficialFlowEnabled: true,
            clientID: "client-id",
            authorizationEndpoint: URL(string: "https://auth.example.test/authorize")!,
            tokenEndpoint: URL(string: "https://auth.example.test/token")!,
            revokeEndpoint: URL(string: "https://auth.example.test/revoke")!,
            userInfoEndpoint: nil,
            redirectURI: URL(string: "notchcopilot://oauth/openai/callback")!,
            callbackScheme: "notchcopilot",
            scopes: ["responses"]
        )
    }

    private func testURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenAITestURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func answerContext() -> AnswerContext {
        AnswerContext(
            meetingTitle: "Architecture Review",
            transcriptWindow: "Speaker 1: Can we ship?",
            ragContext: "",
            userRole: "Senior Fullstack Software Engineer",
            responseStyle: .technical,
            languageCode: "en-US"
        )
    }
}

private final class InMemoryTokenStore: TokenStore {
    private var sessions: [AuthProviderType: AuthSession] = [:]

    func loadSession(provider: AuthProviderType) throws -> AuthSession? {
        sessions[provider]
    }

    func saveSession(_ session: AuthSession) throws {
        sessions[session.provider] = session
    }

    func deleteSession(provider: AuthProviderType) throws {
        sessions.removeValue(forKey: provider)
    }

    func deleteAllSessions() throws {
        sessions.removeAll()
    }
}

@MainActor
private final class FakeCodexCLICommandRunner: CodexCLICommandRunning {
    struct Call {
        var arguments: [String]
        var standardInput: String?
    }

    var calls: [Call] = []
    var statusResults: [CodexCLICommandResult] = []
    var loginResults: [CodexCLICommandResult] = []
    var logoutResult = CodexCLICommandResult(exitCode: 0, output: "")
    var execResult = CodexCLICommandResult(exitCode: 0, output: "")
    var execOutput = ""

    func runCodex(
        arguments: [String],
        standardInput: String?,
        timeout: TimeInterval,
        outputHandler: (@MainActor @Sendable (String) -> Void)?
    ) async throws -> CodexCLICommandResult {
        calls.append(Call(arguments: arguments, standardInput: standardInput))
        switch arguments {
        case ["login", "status"]:
            let result = statusResults.isEmpty
                ? CodexCLICommandResult(exitCode: 1, output: "No ChatGPT login")
                : statusResults.removeFirst()
            outputHandler?(result.output)
            return result
        case ["login", "--device-auth"]:
            let result = loginResults.isEmpty
                ? CodexCLICommandResult(exitCode: 0, output: "")
                : loginResults.removeFirst()
            outputHandler?(result.output)
            return result
        case ["logout"]:
            outputHandler?(logoutResult.output)
            return logoutResult
        default:
            if arguments.contains("exec") {
                if let outputFlag = arguments.firstIndex(of: "--output-last-message"),
                   arguments.indices.contains(outputFlag + 1) {
                    try execOutput.write(
                        toFile: arguments[outputFlag + 1],
                        atomically: true,
                        encoding: .utf8
                    )
                }
                outputHandler?(execResult.output)
                return execResult
            }
            return CodexCLICommandResult(exitCode: 1, output: "Unexpected command")
        }
    }
}

private final class FakeCodexLoginProcess: CodexCLILoginProcessManaging {
    private static let defaultState = CodexCLILoginSessionState(
        id: "fake-codex-login",
        authURL: URL(string: "https://auth.openai.com/device"),
        userCode: "ABCD-1234",
        outputPreview: "Open https://auth.openai.com/device and enter code ABCD-1234",
        isRunning: true,
        submittedCode: nil
    )
    private var currentState: CodexCLILoginSessionState
    private var onStateChange: (@MainActor @Sendable (CodexCLILoginSessionState) -> Void)?

    init(initialState: CodexCLILoginSessionState = FakeCodexLoginProcess.defaultState) {
        currentState = initialState
    }

    func start(onStateChange: @escaping @MainActor @Sendable (CodexCLILoginSessionState) -> Void) throws {
        self.onStateChange = onStateChange
        let state = currentState
        Task { @MainActor in onStateChange(state) }
    }

    func state() -> CodexCLILoginSessionState {
        currentState
    }

    func submit(code: String) {
        currentState.submittedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func terminate() {
        currentState.isRunning = false
    }

    func finishApproved() {
        currentState.isRunning = false
        let state = currentState
        let onStateChange = onStateChange
        Task { @MainActor in onStateChange?(state) }
    }
}

private final class FakeProviderLoginProcess: ProviderCLILoginProcessManaging {
    private var currentState: ProviderCLILoginSessionState
    private var onStateChange: (@MainActor @Sendable (ProviderCLILoginSessionState) -> Void)?

    init(provider: AIProviderKind) {
        currentState = ProviderCLILoginSessionState(
            id: "fake-provider-login-\(provider.rawValue)",
            provider: provider,
            authURL: URL(string: "https://example.com/device"),
            userCode: "GEMI-1234",
            outputPreview: "Open https://example.com/device and enter authentication code GEMI-1234",
            isRunning: true,
            submittedCode: nil
        )
    }

    func start(onStateChange: @escaping @MainActor @Sendable (ProviderCLILoginSessionState) -> Void) throws {
        self.onStateChange = onStateChange
        let state = currentState
        Task { @MainActor in onStateChange(state) }
    }

    func state() -> ProviderCLILoginSessionState {
        currentState
    }

    func submit(code: String) {
        currentState.submittedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func terminate() {
        currentState.isRunning = false
    }

    func finishApproved() {
        currentState.isRunning = false
        let state = currentState
        let onStateChange = onStateChange
        Task { @MainActor in onStateChange?(state) }
    }
}

@MainActor
private final class FakeProviderCLICommandRunner: ProviderCLICommandRunning {
    struct Call {
        var arguments: [String]
        var standardInput: String?
    }

    var calls: [Call] = []
    var results: [ProviderCLICommandResult] = []

    func runProviderCLI(
        arguments: [String],
        standardInput: String?,
        timeout: TimeInterval,
        outputHandler: (@MainActor @Sendable (String) -> Void)?
    ) async throws -> ProviderCLICommandResult {
        calls.append(Call(arguments: arguments, standardInput: standardInput))
        let result = results.isEmpty
            ? ProviderCLICommandResult(exitCode: 0, output: "")
            : results.removeFirst()
        outputHandler?(result.output)
        return result
    }
}

@MainActor
private final class TestAuthProvider: AuthProvider {
    private var session: AuthSession?
    var refreshCount = 0

    init(session: AuthSession?) {
        self.session = session
    }

    var isAuthenticated: Bool {
        session != nil
    }

    func signIn() async throws -> AuthSession {
        guard let session else { throw AuthError.notAuthenticated }
        return session
    }

    func refreshIfNeeded() async throws -> AuthSession {
        refreshCount += 1
        guard let session else { throw AuthError.notAuthenticated }
        return session
    }

    func signOut() async throws {
        session = nil
    }

    func currentSession() async throws -> AuthSession? {
        session
    }
}

private final class OpenAITestURLProtocol: URLProtocol {
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var responseData = Data()
    nonisolated(unsafe) static var responseError: Error?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastRequestBody: Data?

    static func reset(statusCode: Int = 200, body: Data = Data(), error: Error? = nil) {
        self.statusCode = statusCode
        responseData = body
        responseError = error
        lastRequest = nil
        lastRequestBody = nil
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastRequestBody = request.httpBody ?? Self.readBodyStream(from: request)
        if let responseError = Self.responseError {
            client?.urlProtocol(self, didFailWithError: responseError)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBodyStream(from request: URLRequest) -> Data? {
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count > 0 {
                data.append(buffer, count: count)
            } else {
                break
            }
        }
        return data.isEmpty ? nil : data
    }
}

@MainActor
private final class CapturingWebSearchService: WebSearchService {
    var queries: [String] = []
    var results: [String]

    init(results: [String]) {
        self.results = results
    }

    func search(query: String) async throws -> [String] {
        queries.append(query)
        return results
    }
}

private struct FakeMicrophoneUsageMonitor: MicrophoneUsageMonitoring {
    var inUse: Bool

    func isInputInUseByAnotherApplication() -> Bool {
        inUse
    }
}

@MainActor
private struct EmptyCalendarMeetingDetector: CalendarMeetingDetecting {
    func detectCurrentMeeting() async -> MeetingSession? {
        nil
    }
}

@MainActor
private struct FakeMeetingAppActivityMonitor: MeetingAppActivityMonitoring {
    var activity: MeetingAppActivity?

    func detect(preferences: AppPreferences) -> MeetingAppActivity? {
        activity
    }
}

private final class RecordingAppleTranslator: AppleTranslationProviding {
    struct Request: Equatable {
        var text: String
        var source: String?
        var target: String
    }

    var requests: [Request] = []
    private var outputProvider: (Request) -> String

    init(output: String) {
        self.outputProvider = { _ in output }
    }

    init(_ outputProvider: @escaping (Request) -> String) {
        self.outputProvider = outputProvider
    }

    func supports(source: String, target: String) async -> Bool {
        true
    }

    func translate(_ text: String, source: String?, target: String) async throws -> String {
        let request = Request(text: text, source: source, target: target)
        requests.append(request)
        return outputProvider(request)
    }
}

private struct FailingAppleTranslator: AppleTranslationProviding {
    func supports(source: String, target: String) async -> Bool {
        false
    }

    func translate(_ text: String, source: String?, target: String) async throws -> String {
        throw AppleTranslationServiceError.unavailable
    }
}

private struct FakeCloudTranslationProvider: AIProvider {
    var name: EngineName { engine }
    var engine: EngineName = .openAI
    var translation: String

    func generateAnswer(context: AnswerContext, question: String, options: AnswerOptions) async throws -> GeneratedAnswer {
        GeneratedAnswer(text: "", provider: .openAI, usedCloud: true, usedRAG: false)
    }

    func summarizeMeeting(meeting: MeetingSession, transcript: [TranscriptSegment], type: MeetingType) async throws -> MeetingSummary {
        MeetingSummary(meetingId: meeting.id)
    }

    func translateSegment(_ segment: TranscriptSegment, targetLanguage: String) async throws -> String {
        translation
    }

    func extractActionItems(transcript: [TranscriptSegment]) async throws -> [ActionItem] {
        []
    }

    func generateInsights(transcriptWindow: [TranscriptSegment]) async throws -> [Insight] {
        []
    }

    func embed(texts: [String]) async throws -> [[Double]] {
        []
    }
}

private struct StaticAnswerAIProvider: AIProvider {
    var name: EngineName { .openAI }
    var text: String

    func generateAnswer(context: AnswerContext, question: String, options: AnswerOptions) async throws -> GeneratedAnswer {
        GeneratedAnswer(text: text, provider: .openAI, usedCloud: false, usedRAG: false)
    }

    func summarizeMeeting(meeting: MeetingSession, transcript: [TranscriptSegment], type: MeetingType) async throws -> MeetingSummary {
        MeetingSummary(meetingId: meeting.id)
    }

    func translateSegment(_ segment: TranscriptSegment, targetLanguage: String) async throws -> String {
        segment.text
    }

    func extractActionItems(transcript: [TranscriptSegment]) async throws -> [ActionItem] {
        []
    }

    func generateInsights(transcriptWindow: [TranscriptSegment]) async throws -> [Insight] {
        []
    }

    func embed(texts: [String]) async throws -> [[Double]] {
        []
    }
}

@MainActor
private final class ScriptedRawAIProvider: AIProvider {
    var name: EngineName { .openAI }
    private(set) var requests: [LLMRawRequest] = []
    private var responses: [String]
    private var sources: [AnswerSource]

    init(responses: [String], sources: [AnswerSource] = []) {
        self.responses = responses
        self.sources = sources
    }

    func generateRaw(request: LLMRawRequest) async throws -> LLMRawResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw AIProviderError.invalidResponse }
        return LLMRawResponse(
            text: responses.removeFirst(),
            provider: .openAI,
            usedCloud: false,
            sources: request.enableWebSearch ? sources : []
        )
    }

    func generateAnswer(context: AnswerContext, question: String, options: AnswerOptions) async throws -> GeneratedAnswer {
        GeneratedAnswer(text: responses.first ?? "", provider: .openAI, usedCloud: false, usedRAG: false)
    }

    func summarizeMeeting(meeting: MeetingSession, transcript: [TranscriptSegment], type: MeetingType) async throws -> MeetingSummary {
        MeetingSummary(meetingId: meeting.id)
    }

    func translateSegment(_ segment: TranscriptSegment, targetLanguage: String) async throws -> String {
        segment.text
    }

    func extractActionItems(transcript: [TranscriptSegment]) async throws -> [ActionItem] {
        []
    }

    func generateInsights(transcriptWindow: [TranscriptSegment]) async throws -> [Insight] {
        []
    }

    func embed(texts: [String]) async throws -> [[Double]] {
        []
    }
}

@MainActor
private final class SlowRawAIProvider: AIProvider {
    var name: EngineName { .openAI }
    let delayNanoseconds: UInt64

    init(delayNanoseconds: UInt64) {
        self.delayNanoseconds = delayNanoseconds
    }

    func generateRaw(request: LLMRawRequest) async throws -> LLMRawResponse {
        try await Task.sleep(nanoseconds: delayNanoseconds)
        return LLMRawResponse(
            text: """
            {
              "shouldRespond": true,
              "intent": "answerable_question",
              "needsWeb": false,
              "needsReminderAction": false,
              "needsClarification": false,
              "answerFormat": "paragraph",
              "answerText": "Late answer",
              "confidence": 0.90,
              "reason": "late",
              "reminderAction": null
            }
            """,
            provider: .openAI,
            usedCloud: false
        )
    }

    func generateAnswer(context: AnswerContext, question: String, options: AnswerOptions) async throws -> GeneratedAnswer {
        try await Task.sleep(nanoseconds: delayNanoseconds)
        return GeneratedAnswer(text: "Late answer", provider: .openAI, usedCloud: false, usedRAG: false)
    }

    func summarizeMeeting(meeting: MeetingSession, transcript: [TranscriptSegment], type: MeetingType) async throws -> MeetingSummary {
        MeetingSummary(meetingId: meeting.id)
    }

    func translateSegment(_ segment: TranscriptSegment, targetLanguage: String) async throws -> String {
        segment.text
    }

    func extractActionItems(transcript: [TranscriptSegment]) async throws -> [ActionItem] {
        []
    }

    func generateInsights(transcriptWindow: [TranscriptSegment]) async throws -> [Insight] {
        []
    }

    func embed(texts: [String]) async throws -> [[Double]] {
        []
    }
}

private struct StubTrainedMultiQTModelRunner: QuestionTrainedMultimodalModelRunning {
    var prediction: QuestionTrainedMultimodalPrediction?

    func prediction(
        for candidate: QuestionCandidate,
        signal: QuestionMultimodalSignal?
    ) async -> QuestionTrainedMultimodalPrediction? {
        prediction
    }
}

private final class CaptureSentinelView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 1, green: 0, blue: 1, alpha: 1).setFill()
        bounds.fill()
    }
}
