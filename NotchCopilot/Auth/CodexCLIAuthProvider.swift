import AppKit
import Darwin
import Foundation

struct CodexCLICommandResult: Equatable, Sendable {
    var exitCode: Int32
    var output: String
}

struct CodexCLILoginSessionState: Equatable, Identifiable, Sendable {
    let id: String
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
protocol CodexCLICommandRunning {
    func runCodex(
        arguments: [String],
        standardInput: String?,
        timeout: TimeInterval,
        outputHandler: (@MainActor @Sendable (String) -> Void)?
    ) async throws -> CodexCLICommandResult
}

protocol CodexCLILoginProcessManaging: AnyObject {
    func start(onStateChange: @escaping @MainActor @Sendable (CodexCLILoginSessionState) -> Void) throws
    func state() -> CodexCLILoginSessionState
    func submit(code: String)
    func terminate()
}

@MainActor
final class ProcessCodexCLICommandRunner: CodexCLICommandRunning {
    private let executable: String
    nonisolated static let stableConfigArguments = ["-c", "service_tier=\"fast\""]

    init(executable: String = ProcessInfo.processInfo.environment["CODEX_BIN"] ?? "codex") {
        self.executable = executable
    }

    func runCodex(
        arguments: [String],
        standardInput: String? = nil,
        timeout: TimeInterval = 120,
        outputHandler: (@MainActor @Sendable (String) -> Void)? = nil
    ) async throws -> CodexCLICommandResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + Self.stableConfigArguments + arguments
            process.environment = Self.sanitizedEnvironment()

            let outputPipe = Pipe()
            let inputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe
            if standardInput != nil {
                process.standardInput = inputPipe
            }

            let runtime = CodexCLIProcessRuntime(
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
                runtime.finish(.success(CodexCLICommandResult(exitCode: process.terminationStatus, output: runtime.output)))
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

    nonisolated static func sanitizedEnvironment() -> [String: String] {
        let source = ProcessInfo.processInfo.environment
        let exactKeys = [
            "PATH", "HOME", "USER", "LOGNAME", "SHELL", "TERM", "LANG",
            "LC_ALL", "TMPDIR", "TMP", "TEMP", "SSH_AUTH_SOCK", "CODEX_HOME"
        ]
        var env: [String: String] = [:]
        for key in exactKeys {
            if let value = source[key] {
                env[key] = value
            }
        }
        if let configured = source["CODEX_BIN"] {
            env["CODEX_BIN"] = configured
        }
        let fallbackSearchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if let currentPath = env["PATH"], !currentPath.isEmpty {
            env["PATH"] = "\(currentPath):\(fallbackSearchPath)"
        } else {
            env["PATH"] = fallbackSearchPath
        }
        env["CODEX_AUTH_MODE"] = "subscription_login"
        env.removeValue(forKey: "OPENAI_API_KEY")
        return env
    }
}

final class CodexCLILoginProcess: CodexCLILoginProcessManaging, @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var capturedOutput = ""
    private var submittedCode: String?
    private var didTerminate = false
    private var masterHandle: FileHandle?

    let id: String

    init(executable: String = ProcessInfo.processInfo.environment["CODEX_BIN"] ?? "codex") {
        id = UUID().uuidString
        process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + ProcessCodexCLICommandRunner.stableConfigArguments + ["login", "--device-auth"]
        process.environment = ProcessCodexCLICommandRunner.sanitizedEnvironment()
    }

    func start(onStateChange: @escaping @MainActor @Sendable (CodexCLILoginSessionState) -> Void) throws {
        var master: Int32 = 0
        var slave: Int32 = 0
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw AuthError.authenticationSessionFailed
        }

        let masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        self.masterHandle = masterHandle

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
        do {
            try process.run()
            try? slaveHandle.close()
        } catch {
            masterHandle.readabilityHandler = nil
            try? masterHandle.close()
            try? slaveHandle.close()
            self.masterHandle = nil
            throw error
        }
    }

    func state() -> CodexCLILoginSessionState {
        lock.lock()
        let output = capturedOutput
        let submittedCode = submittedCode
        let isRunning = process.isRunning && !didTerminate
        lock.unlock()
        return CodexCLILoginSessionState(
            id: id,
            authURL: CodexCLIAuthProvider.extractURL(from: output),
            userCode: CodexCLIAuthProvider.extractUserCode(from: output),
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
        masterHandle = nil
    }

    private static func preview(from output: String) -> String {
        let trimmed = CodexCLIAuthProvider.sanitizedTerminalText(output).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed
            .components(separatedBy: .newlines)
            .suffix(8)
            .joined(separator: "\n")
    }
}

private final class CodexCLIProcessRuntime: @unchecked Sendable {
    private let process: Process
    private let outputPipe: Pipe
    private let continuation: CheckedContinuation<CodexCLICommandResult, Error>
    private let lock = NSLock()
    private var capturedOutput = ""
    private var didFinish = false

    init(
        process: Process,
        outputPipe: Pipe,
        continuation: CheckedContinuation<CodexCLICommandResult, Error>
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

    func finish(_ result: Result<CodexCLICommandResult, Error>) {
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

@MainActor
final class CodexCLIAuthProvider: AuthProvider {
    var onLoginPrompt: ((URL, String?) -> Void)?
    var onLoginStateChange: ((CodexCLILoginSessionState) -> Void)?

    private let runner: CodexCLICommandRunning
    private let openURL: (URL) -> Void
    private let loginProcessFactory: () -> CodexCLILoginProcessManaging
    private let tokenStore: TokenStore?
    private var cachedSession: AuthSession?
    private var loginProcess: CodexCLILoginProcessManaging?
    private var openedLoginURL: URL?

    init(
        runner: CodexCLICommandRunning = ProcessCodexCLICommandRunner(),
        openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        loginProcessFactory: @escaping () -> CodexCLILoginProcessManaging = { CodexCLILoginProcess() },
        tokenStore: TokenStore? = nil
    ) {
        self.runner = runner
        self.openURL = openURL
        self.loginProcessFactory = loginProcessFactory
        self.tokenStore = tokenStore
    }

    var isAuthenticated: Bool {
        if cachedSession != nil { return true }
        return ((try? tokenStore?.loadSession(provider: .openAICodexCLI)) ?? nil) != nil
    }

    func signIn() async throws -> AuthSession {
        if let session = try await currentSession() {
            return session
        }

        var openedURL: URL?
        var userCode: String?
        let result = try await runner.runCodex(
            arguments: ["login", "--device-auth"],
            standardInput: nil,
            timeout: 600
        ) { [weak self] chunk in
            guard let self else { return }
            let text = chunk
            if userCode == nil {
                userCode = Self.extractUserCode(from: text)
            }
            if openedURL == nil, let url = Self.extractURL(from: text) {
                openedURL = url
                onLoginPrompt?(url, userCode)
                openURL(url)
            }
        }

        guard result.exitCode == 0 else {
            throw AuthError.authenticationSessionFailed
        }
        guard let session = try await currentSession() else {
            throw AuthError.notAuthenticated
        }
        return session
    }

    func startDeviceLogin() async throws -> CodexCLILoginSessionState {
        if let state = loginProcess?.state(), state.isRunning {
            publishLoginState(state)
            return state
        }

        cancelDeviceLogin()
        openedLoginURL = nil

        let process = loginProcessFactory()
        loginProcess = process
        try process.start { [weak self, weak process] _ in
            guard let self,
                  let process,
                  let activeProcess = self.loginProcess,
                  activeProcess === process
            else { return }
            self.publishLoginState(process.state())
        }
        var state = process.state()
        let deadline = Date().addingTimeInterval(2)
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
        cancelDeviceLogin()
        _ = try await runner.runCodex(arguments: ["logout"], standardInput: nil, timeout: 30, outputHandler: nil)
        cachedSession = nil
        try? tokenStore?.deleteSession(provider: .openAICodexCLI)
    }

    func submitDeviceCode(_ code: String) async throws -> CodexCLILoginSessionState {
        guard let loginProcess else {
            throw AuthError.notAuthenticated
        }
        loginProcess.submit(code: code)
        try? await Task.sleep(nanoseconds: 500_000_000)
        let state = loginProcess.state()
        publishLoginState(state)
        return state
    }

    func verifyDeviceLogin(maxWait: TimeInterval = 5, pollInterval: TimeInterval = 0.5) async throws -> AuthSession {
        let deadline = Date().addingTimeInterval(maxWait)
        repeat {
            try Task.checkCancellation()
            if let session = try await currentSession() {
                cancelDeviceLogin()
                return session
            }
            try await Task.sleep(nanoseconds: UInt64(max(0.1, pollInterval) * 1_000_000_000))
        } while Date() < deadline
        if let state = loginProcess?.state(), !state.isRunning {
            cancelDeviceLogin()
        }
        throw AuthError.notAuthenticated
    }

    func cancelDeviceLogin() {
        loginProcess?.terminate()
        loginProcess = nil
        openedLoginURL = nil
        onLoginStateChange?(CodexCLILoginSessionState(
            id: UUID().uuidString,
            authURL: nil,
            userCode: nil,
            outputPreview: "",
            isRunning: false,
            submittedCode: nil
        ))
    }

    func currentDeviceLoginState() -> CodexCLILoginSessionState? {
        loginProcess?.state()
    }

    func currentSession() async throws -> AuthSession? {
        let result = try await runner.runCodex(
            arguments: ["login", "status"],
            standardInput: nil,
            timeout: 8,
            outputHandler: nil
        )
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isChatGPTAccountLoginStatus(output, exitCode: result.exitCode) else {
            cachedSession = nil
            try? tokenStore?.deleteSession(provider: .openAICodexCLI)
            return nil
        }

        let session = AuthSession(
            provider: .openAICodexCLI,
            accessToken: "codex-cli-session",
            refreshToken: nil,
            expiresAt: nil,
            accountEmail: nil,
            accountId: nil,
            scopes: ["codex-cli", "chatgpt-login"]
        )
        cachedSession = session
        try? tokenStore?.saveSession(session)
        return session
    }

    private static func isChatGPTAccountLoginStatus(_ output: String, exitCode: Int32) -> Bool {
        guard exitCode == 0 else { return false }
        let lower = sanitizedTerminalText(output).lowercased()
        let negativeMarkers = [
            "not logged in",
            "no chatgpt login",
            "login required",
            "not authenticated",
            "authentication required",
            "api key"
        ]
        guard !negativeMarkers.contains(where: lower.contains) else { return false }
        let positiveMarkers = [
            "logged in",
            "signed in",
            "authenticated",
            "chatgpt",
            "subscription"
        ]
        return positiveMarkers.contains(where: lower.contains)
    }

    private func publishLoginState(_ state: CodexCLILoginSessionState) {
        if openedLoginURL == nil, let url = state.authURL {
            openedLoginURL = url
            onLoginPrompt?(url, state.userCode)
            openURL(url)
        } else if let openedLoginURL, state.userCode != nil {
            onLoginPrompt?(openedLoginURL, state.userCode)
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
            #"(?i)(?:code|enter)\s+((?<![A-Z0-9-])[A-Z0-9]{4,}-[A-Z0-9]{4,}(?![A-Z0-9-]))"#,
            #"(?<![A-Z0-9-])([A-Z0-9]{4,}-[A-Z0-9]{4,})(?![A-Z0-9-])"#
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
