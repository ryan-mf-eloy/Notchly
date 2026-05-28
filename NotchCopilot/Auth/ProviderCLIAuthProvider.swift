import AppKit
import Darwin
import Foundation

struct ProviderCLICommandResult: Equatable, Sendable {
    var exitCode: Int32
    var output: String
}

struct ProviderCLILoginSessionState: Equatable, Identifiable, Sendable {
    let id: String
    var provider: AIProviderKind
    var authURL: URL?
    var userCode: String?
    var outputPreview: String
    var isRunning: Bool
    var submittedCode: String?

    var needsBrowserApproval: Bool {
        authURL != nil || userCode != nil || isRunning
    }
}

@MainActor
protocol ProviderCLICommandRunning {
    func runProviderCLI(
        arguments: [String],
        standardInput: String?,
        timeout: TimeInterval,
        outputHandler: (@MainActor @Sendable (String) -> Void)?
    ) async throws -> ProviderCLICommandResult
}

protocol ProviderCLILoginProcessManaging: AnyObject {
    func start(onStateChange: @escaping @MainActor @Sendable (ProviderCLILoginSessionState) -> Void) throws
    func state() -> ProviderCLILoginSessionState
    func submit(code: String)
    func terminate()
}

enum ProviderCLIConfiguration: Hashable {
    case gemini
    case claude

    var providerKind: AIProviderKind {
        switch self {
        case .gemini: .googleGemini
        case .claude: .anthropicClaude
        }
    }

    var authProviderType: AuthProviderType {
        switch self {
        case .gemini: .googleGeminiOAuth
        case .claude: .anthropicClaudeOAuth
        }
    }

    var accountLabel: String {
        switch self {
        case .gemini: "Google account"
        case .claude: "Claude account"
        }
    }

    var configuredExecutableEnvironmentKey: String {
        switch self {
        case .gemini: "GEMINI_BIN"
        case .claude: "CLAUDE_BIN"
        }
    }

    var defaultCommand: [String] {
        switch self {
        case .gemini:
            if ProcessProviderCLICommandRunner.executableExists("gemini") {
                return ["gemini"]
            }
            return ["npx", "-y", "@google/gemini-cli"]
        case .claude:
            return ["claude"]
        }
    }

    var loginArguments: [String] {
        switch self {
        case .gemini: []
        case .claude: ["setup-token"]
        }
    }

    var logoutArguments: [String]? {
        switch self {
        case .gemini: nil
        case .claude: ["auth", "logout"]
        }
    }

    var statusArguments: [String] {
        switch self {
        case .gemini: ["-p", "Reply with OK only.", "--output-format", "json"]
        case .claude: ["auth", "status", "--json"]
        }
    }

    var defaultModel: String {
        switch self {
        case .gemini: "gemini-2.5-flash"
        case .claude: "claude-sonnet-4-5"
        }
    }
}

@MainActor
final class ProcessProviderCLICommandRunner: ProviderCLICommandRunning {
    private let configuration: ProviderCLIConfiguration
    private let command: [String]

    init(configuration: ProviderCLIConfiguration, command: [String]? = nil) {
        self.configuration = configuration
        if let command, !command.isEmpty {
            self.command = command
        } else if let configured = ProcessInfo.processInfo.environment[configuration.configuredExecutableEnvironmentKey], !configured.isEmpty {
            self.command = Self.splitShellWords(configured)
        } else {
            self.command = configuration.defaultCommand
        }
    }

    func runProviderCLI(
        arguments: [String],
        standardInput: String? = nil,
        timeout: TimeInterval = 120,
        outputHandler: (@MainActor @Sendable (String) -> Void)? = nil
    ) async throws -> ProviderCLICommandResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = command + arguments
            process.environment = Self.sanitizedEnvironment(for: configuration)

            let outputPipe = Pipe()
            let inputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe
            if standardInput != nil {
                process.standardInput = inputPipe
            }

            let runtime = ProviderCLIProcessRuntime(
                process: process,
                outputPipe: outputPipe,
                continuation: continuation
            )

            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                runtime.append(chunk)
                Task { @MainActor in outputHandler?(chunk) }
            }

            process.terminationHandler = { process in
                runtime.finish(.success(ProviderCLICommandResult(exitCode: process.terminationStatus, output: runtime.output)))
            }

            do {
                try process.run()
                if let standardInput {
                    inputPipe.fileHandleForWriting.write(Data(standardInput.utf8))
                    try? inputPipe.fileHandleForWriting.close()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    guard !runtime.isFinished else { return }
                    runtime.terminate()
                    runtime.finish(.failure(AuthError.authenticationSessionFailed))
                }
            } catch {
                runtime.finish(.failure(error))
            }
        }
    }

    nonisolated static func executableExists(_ name: String) -> Bool {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return path
            .split(separator: ":")
            .map(String.init)
            .contains { FileManager.default.isExecutableFile(atPath: URL(fileURLWithPath: $0).appendingPathComponent(name).path) }
    }

    nonisolated static func sanitizedEnvironment(for configuration: ProviderCLIConfiguration) -> [String: String] {
        let source = ProcessInfo.processInfo.environment
        let exactKeys = [
            "PATH", "HOME", "USER", "LOGNAME", "SHELL", "TERM", "LANG",
            "LC_ALL", "TMPDIR", "TMP", "TEMP", "SSH_AUTH_SOCK",
            "GEMINI_API_KEY", "GOOGLE_CLOUD_PROJECT", "ANTHROPIC_API_KEY",
            "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CONFIG_DIR", "GEMINI_BIN", "CLAUDE_BIN"
        ]
        var env: [String: String] = [:]
        for key in exactKeys {
            if let value = source[key] {
                env[key] = value
            }
        }
        let fallbackSearchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if let currentPath = env["PATH"], !currentPath.isEmpty {
            env["PATH"] = "\(currentPath):\(fallbackSearchPath)"
        } else {
            env["PATH"] = fallbackSearchPath
        }
        env["TERM"] = env["TERM"] ?? "xterm-256color"
        switch configuration {
        case .gemini:
            env["GEMINI_AUTH_MODE"] = "subscription_login"
            env.removeValue(forKey: "GEMINI_API_KEY")
        case .claude:
            env["CLAUDE_AUTH_MODE"] = "subscription_login"
            env.removeValue(forKey: "ANTHROPIC_API_KEY")
        }
        return env
    }

    nonisolated static func splitShellWords(_ value: String) -> [String] {
        value.split(separator: " ").map(String.init)
    }
}

final class ProviderCLILoginProcess: ProviderCLILoginProcessManaging, @unchecked Sendable {
    private let configuration: ProviderCLIConfiguration
    private let command: [String]
    private let process = Process()
    private let lock = NSLock()
    private var capturedOutput = ""
    private var submittedCode: String?
    private var didTerminate = false
    private var masterHandle: FileHandle?

    let id: String

    init(configuration: ProviderCLIConfiguration, command: [String]? = nil) {
        self.configuration = configuration
        if let command, !command.isEmpty {
            self.command = command
        } else if let configured = ProcessInfo.processInfo.environment[configuration.configuredExecutableEnvironmentKey], !configured.isEmpty {
            self.command = ProcessProviderCLICommandRunner.splitShellWords(configured)
        } else {
            self.command = configuration.defaultCommand
        }
        id = UUID().uuidString
    }

    func start(onStateChange: @escaping @MainActor @Sendable (ProviderCLILoginSessionState) -> Void) throws {
        var master: Int32 = 0
        var slave: Int32 = 0
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw AuthError.authenticationSessionFailed
        }
        let masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        self.masterHandle = masterHandle

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command + configuration.loginArguments
        process.environment = ProcessProviderCLICommandRunner.sanitizedEnvironment(for: configuration)
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle

        masterHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            guard let self else { return }
            self.append(chunk)
            let state = self.state()
            Task { @MainActor in onStateChange(state) }
        }

        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.markTerminated()
            let state = self.state()
            Task { @MainActor in onStateChange(state) }
        }

        try process.run()
        try? slaveHandle.close()
    }

    func state() -> ProviderCLILoginSessionState {
        lock.lock()
        let output = capturedOutput
        let submittedCode = submittedCode
        let isRunning = process.isRunning && !didTerminate
        lock.unlock()
        return ProviderCLILoginSessionState(
            id: id,
            provider: configuration.providerKind,
            authURL: ProviderCLIAuthProvider.extractURL(from: output),
            userCode: ProviderCLIAuthProvider.extractUserCode(from: output),
            outputPreview: Self.preview(from: output),
            isRunning: isRunning,
            submittedCode: submittedCode
        )
    }

    func submit(code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, process.isRunning else { return }
        lock.lock()
        submittedCode = trimmed
        lock.unlock()
        masterHandle?.write(Data((trimmed + "\n").utf8))
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }

    private func append(_ chunk: String) {
        lock.lock()
        capturedOutput += chunk
        lock.unlock()
    }

    private func markTerminated() {
        lock.lock()
        didTerminate = true
        lock.unlock()
        masterHandle?.readabilityHandler = nil
        try? masterHandle?.close()
    }

    private static func preview(from output: String) -> String {
        let trimmed = ProviderCLIAuthProvider.sanitizedTerminalText(output).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed.components(separatedBy: .newlines).suffix(8).joined(separator: "\n")
    }
}

@MainActor
final class ProviderCLIAuthProvider: AuthProvider {
    var onLoginPrompt: ((AIProviderKind, URL, String?) -> Void)?
    var onLoginStateChange: ((ProviderCLILoginSessionState) -> Void)?

    private let configuration: ProviderCLIConfiguration
    private let runner: ProviderCLICommandRunning
    private let openURL: (URL) -> Void
    private let loginProcessFactory: () -> ProviderCLILoginProcessManaging
    private let tokenStore: TokenStore?
    private var cachedSession: AuthSession?
    private var loginProcess: ProviderCLILoginProcessManaging?
    private var openedLoginURL: URL?

    init(
        configuration: ProviderCLIConfiguration,
        runner: ProviderCLICommandRunning? = nil,
        openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        loginProcessFactory: (() -> ProviderCLILoginProcessManaging)? = nil,
        tokenStore: TokenStore? = nil
    ) {
        self.configuration = configuration
        self.runner = runner ?? ProcessProviderCLICommandRunner(configuration: configuration)
        self.openURL = openURL
        self.loginProcessFactory = loginProcessFactory ?? { ProviderCLILoginProcess(configuration: configuration) }
        self.tokenStore = tokenStore
    }

    var isAuthenticated: Bool {
        if cachedSession != nil { return true }
        return ((try? tokenStore?.loadSession(provider: configuration.authProviderType)) ?? nil) != nil
    }

    func signIn() async throws -> AuthSession {
        if let session = try await currentSession() {
            return session
        }
        _ = try await startAccountLogin()
        throw AuthError.notAuthenticated
    }

    func startAccountLogin() async throws -> ProviderCLILoginSessionState {
        if let state = loginProcess?.state(), state.isRunning {
            publishLoginState(state)
            return state
        }
        cancelAccountLogin()
        openedLoginURL = nil

        let process = loginProcessFactory()
        loginProcess = process
        try process.start { [weak self] state in
            self?.publishLoginState(state)
        }
        var state = process.state()
        let deadline = Date().addingTimeInterval(2.5)
        while state.authURL == nil && state.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
            state = process.state()
        }
        publishLoginState(state)
        return state
    }

    func refreshIfNeeded() async throws -> AuthSession {
        guard let session = try await currentSession() else { throw AuthError.notAuthenticated }
        return session
    }

    func signOut() async throws {
        cancelAccountLogin()
        if let logoutArguments = configuration.logoutArguments {
            _ = try? await runner.runProviderCLI(arguments: logoutArguments, standardInput: nil, timeout: 30, outputHandler: nil)
        }
        cachedSession = nil
        try? tokenStore?.deleteSession(provider: configuration.authProviderType)
    }

    func submitAccountCode(_ code: String) async throws -> ProviderCLILoginSessionState {
        guard let loginProcess else { throw AuthError.notAuthenticated }
        loginProcess.submit(code: code)
        try? await Task.sleep(nanoseconds: 500_000_000)
        let state = loginProcess.state()
        publishLoginState(state)
        return state
    }

    func verifyAccountLogin(maxWait: TimeInterval = 6, pollInterval: TimeInterval = 0.5) async throws -> AuthSession {
        let deadline = Date().addingTimeInterval(maxWait)
        repeat {
            try Task.checkCancellation()
            if let session = try await currentSession() {
                cancelAccountLogin()
                return session
            }
            try await Task.sleep(nanoseconds: UInt64(max(0.1, pollInterval) * 1_000_000_000))
        } while Date() < deadline
        if let state = loginProcess?.state(), !state.isRunning {
            cancelAccountLogin()
        }
        throw AuthError.notAuthenticated
    }

    func cancelAccountLogin() {
        loginProcess?.terminate()
        loginProcess = nil
        openedLoginURL = nil
        onLoginStateChange?(ProviderCLILoginSessionState(
            id: UUID().uuidString,
            provider: configuration.providerKind,
            authURL: nil,
            userCode: nil,
            outputPreview: "",
            isRunning: false,
            submittedCode: nil
        ))
    }

    func currentAccountLoginState() -> ProviderCLILoginSessionState? {
        loginProcess?.state()
    }

    func currentSession() async throws -> AuthSession? {
        let result = try await runner.runProviderCLI(
            arguments: configuration.statusArguments,
            standardInput: nil,
            timeout: configuration == .gemini ? 20 : 8,
            outputHandler: nil
        )
        let output = Self.sanitizedTerminalText(result.output).trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0 else {
            cachedSession = nil
            try? tokenStore?.deleteSession(provider: configuration.authProviderType)
            return nil
        }

        switch configuration {
        case .claude:
            guard let data = output.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (payload["loggedIn"] as? Bool) == true else {
                cachedSession = nil
                return nil
            }
            let label = (payload["email"] as? String) ?? (payload["orgName"] as? String)
            let session = AuthSession(
                provider: configuration.authProviderType,
                accessToken: "claude-cli-session",
                refreshToken: nil,
                expiresAt: nil,
                accountEmail: label,
                accountId: nil,
                scopes: ["claude-cli", "account-login"]
            )
            cachedSession = session
            try? tokenStore?.saveSession(session)
            return session
        case .gemini:
            let lower = output.lowercased()
            guard !lower.contains("opening authentication") &&
                  !lower.contains("waiting for authentication") &&
                  !lower.contains("not authenticated") &&
                  !lower.contains("login required") else {
                cachedSession = nil
                try? tokenStore?.deleteSession(provider: configuration.authProviderType)
                return nil
            }
            let session = AuthSession(
                provider: configuration.authProviderType,
                accessToken: "gemini-cli-session",
                refreshToken: nil,
                expiresAt: nil,
                accountEmail: nil,
                accountId: nil,
                scopes: ["gemini-cli", "account-login"]
            )
            cachedSession = session
            try? tokenStore?.saveSession(session)
            return session
        }
    }

    private func publishLoginState(_ state: ProviderCLILoginSessionState) {
        if openedLoginURL == nil, let url = state.authURL {
            openedLoginURL = url
            onLoginPrompt?(configuration.providerKind, url, state.userCode)
            openURL(url)
        } else if let openedLoginURL, state.userCode != nil {
            onLoginPrompt?(configuration.providerKind, openedLoginURL, state.userCode)
        }
        onLoginStateChange?(state)
    }

    nonisolated static func extractURL(from text: String) -> URL? {
        let sanitized = sanitizedTerminalText(text)
        guard let range = sanitized.range(of: #"https://[^\s\)]+"#, options: .regularExpression) else { return nil }
        let rawURL = String(sanitized[range])
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:)]}>\"'"))
        return URL(string: rawURL)
    }

    nonisolated static func extractUserCode(from text: String) -> String? {
        let text = sanitizedTerminalText(text)
        let patterns = [
            #"(?i)(?:authentication\s+code|code|enter(?:\s+authentication\s+code)?)\s+((?<![A-Z0-9-])[A-Z0-9]{4,}(?:-[A-Z0-9]{4,})*(?![A-Z0-9-]))"#,
            #"(?<![A-Z0-9-])([A-Z0-9]{4,}-[A-Z0-9]{4,}(?:-[A-Z0-9]{4,})*)(?![A-Z0-9-])"#
        ]
        let nsText = text as NSString
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(location: 0, length: nsText.length)
            for match in expression.matches(in: text, range: range) {
                let captureRange = match.numberOfRanges > 1 ? match.range(at: 1) : match.range(at: 0)
                guard captureRange.location != NSNotFound else { continue }
                let candidate = nsText.substring(with: captureRange)
                if !looksLikeUUIDPrefix(candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    private nonisolated static func looksLikeUUIDPrefix(_ value: String) -> Bool {
        let parts = value.split(separator: "-")
        guard parts.count >= 2, parts[0].count == 8, parts[1].count == 4 else {
            return false
        }
        return parts[0].allSatisfy(\.isHexDigit) && parts[1].allSatisfy(\.isHexDigit)
    }

    nonisolated static func sanitizedTerminalText(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\u{001B}\\[[0-9;?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )
    }
}

private final class ProviderCLIProcessRuntime: @unchecked Sendable {
    private let process: Process
    private let outputPipe: Pipe
    private let continuation: CheckedContinuation<ProviderCLICommandResult, Error>
    private let lock = NSLock()
    private var capturedOutput = ""
    private var didFinish = false

    init(
        process: Process,
        outputPipe: Pipe,
        continuation: CheckedContinuation<ProviderCLICommandResult, Error>
    ) {
        self.process = process
        self.outputPipe = outputPipe
        self.continuation = continuation
    }

    var output: String {
        lock.lock()
        defer { lock.unlock() }
        return capturedOutput
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didFinish
    }

    func append(_ chunk: String) {
        lock.lock()
        capturedOutput += chunk
        lock.unlock()
    }

    func terminate() {
        process.terminate()
    }

    func finish(_ result: Result<ProviderCLICommandResult, Error>) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        lock.unlock()
        outputPipe.fileHandleForReading.readabilityHandler = nil
        continuation.resume(with: result)
    }
}
