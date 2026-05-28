import CryptoKit
import Foundation
import Security

struct OAuthPKCEPair: Hashable {
    let verifier: String
    let challenge: String
}

enum OAuthPKCEGenerator {
    static func generatePair() throws -> OAuthPKCEPair {
        let verifier = try randomBase64URLString(byteCount: 32)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = base64URLEncoded(Data(digest))
        return OAuthPKCEPair(verifier: verifier, challenge: challenge)
    }

    static func generateState() throws -> String {
        try randomBase64URLString(byteCount: 32)
    }

    private static func randomBase64URLString(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        return base64URLEncoded(Data(bytes))
    }

    private static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
