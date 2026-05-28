import Foundation

@MainActor
protocol AuthProvider {
    var isAuthenticated: Bool { get }
    func signIn() async throws -> AuthSession
    func refreshIfNeeded() async throws -> AuthSession
    func signOut() async throws
    func currentSession() async throws -> AuthSession?
}
