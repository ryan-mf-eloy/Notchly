import CryptoKit
import Foundation
import Security

enum LocalDataCryptorError: LocalizedError {
    case invalidKeyLength(Int)
    case randomGenerationFailed(OSStatus)
    case invalidEnvelope
    case invalidCiphertext
    case missingCombinedBox
    case invalidPlaintext

    var errorDescription: String? {
        switch self {
        case .invalidKeyLength(let length):
            "Local encryption key must be 32 bytes, got \(length)."
        case .randomGenerationFailed(let status):
            "Local encryption key generation failed with status \(status)."
        case .invalidEnvelope:
            "Encrypted local data has an invalid envelope."
        case .invalidCiphertext:
            "Encrypted local data could not be decrypted."
        case .missingCombinedBox:
            "Encrypted local data could not be serialized."
        case .invalidPlaintext:
            "Decrypted local data is not valid UTF-8."
        }
    }
}

final class LocalDataCryptor {
    static let keychainAccount = "local-encryption.master-key.v1"
    static let stringPrefix = "ncenc:v1:"
    private static let fileHeader = Data("NCENC1\n".utf8)
    private static let keySize = 32

    private let keychain: AppleKeychainService?
    private var key: SymmetricKey
    private let deterministicNonceSeed: UInt8?
    private let deterministicNonceLock = NSLock()
    private var deterministicNonceCounter: UInt64 = 0

    init(keychain: AppleKeychainService) throws {
        self.keychain = keychain
        self.deterministicNonceSeed = nil
        if let keyData = try keychain.getData(account: Self.keychainAccount) {
            self.key = try Self.symmetricKey(from: keyData)
        } else {
            let keyData = try Self.generateKeyData()
            try keychain.set(keyData, account: Self.keychainAccount)
            self.key = try Self.symmetricKey(from: keyData)
        }
    }

    init(keyData: Data, deterministicNonceSeed: UInt8? = nil) throws {
        self.keychain = nil
        self.deterministicNonceSeed = deterministicNonceSeed
        self.key = try Self.symmetricKey(from: keyData)
    }

    static func defaultOrCrash() -> LocalDataCryptor {
        do {
            return try LocalDataCryptor(keychain: AppleKeychainService.runtimeDefault())
        } catch {
            fatalError("Local encryption key unavailable: \(error.localizedDescription)")
        }
    }

    static func ephemeralForTests(byte: UInt8 = 0xA7) throws -> LocalDataCryptor {
        try LocalDataCryptor(keyData: Data(repeating: byte, count: keySize), deterministicNonceSeed: byte)
    }

    func resetStoredKey() throws {
        let keyData = try Self.generateKeyData()
        if let keychain {
            try keychain.set(keyData, account: Self.keychainAccount)
        }
        key = try Self.symmetricKey(from: keyData)
    }

    func deleteStoredKey() throws {
        try keychain?.delete(account: Self.keychainAccount)
    }

    func isEncryptedString(_ value: String) -> Bool {
        Self.isEncryptedString(value)
    }

    static func isEncryptedString(_ value: String) -> Bool {
        value.hasPrefix(stringPrefix)
    }

    func encryptString(_ value: String, context: String) throws -> String {
        let data = Data(value.utf8)
        let encrypted = try seal(data, context: context)
        return Self.stringPrefix + encrypted.base64EncodedString()
    }

    func encryptStringIfNeeded(_ value: String, context: String) throws -> String {
        guard !Self.isEncryptedString(value) else { return value }
        return try encryptString(value, context: context)
    }

    func decryptString(_ value: String, context: String) throws -> String {
        guard Self.isEncryptedString(value) else { return value }
        let encoded = String(value.dropFirst(Self.stringPrefix.count))
        guard let encrypted = Data(base64Encoded: encoded) else {
            throw LocalDataCryptorError.invalidEnvelope
        }
        let data = try open(encrypted, context: context)
        guard let plaintext = String(data: data, encoding: .utf8) else {
            throw LocalDataCryptorError.invalidPlaintext
        }
        return plaintext
    }

    func encryptOptionalString(_ value: String?, context: String) throws -> String? {
        guard let value else { return nil }
        return try encryptString(value, context: context)
    }

    func encryptOptionalStringIfNeeded(_ value: String?, context: String) throws -> String? {
        guard let value else { return nil }
        return try encryptStringIfNeeded(value, context: context)
    }

    func decryptOptionalString(_ value: String?, context: String) throws -> String? {
        guard let value else { return nil }
        return try decryptString(value, context: context)
    }

    func isEncryptedData(_ data: Data) -> Bool {
        Self.isEncryptedData(data)
    }

    static func isEncryptedData(_ data: Data) -> Bool {
        data.count >= fileHeader.count && data.prefix(fileHeader.count).elementsEqual(fileHeader)
    }

    func encryptData(_ data: Data, context: String) throws -> Data {
        let encrypted = try seal(data, context: context)
        var output = Self.fileHeader
        output.append(encrypted)
        return output
    }

    func encryptDataIfNeeded(_ data: Data, context: String) throws -> Data {
        guard !Self.isEncryptedData(data) else { return data }
        return try encryptData(data, context: context)
    }

    func decryptData(_ data: Data, context: String) throws -> Data {
        guard Self.isEncryptedData(data) else { return data }
        return try open(data.dropFirst(Self.fileHeader.count), context: context)
    }

    private func seal(_ data: Data, context: String) throws -> Data {
        let sealed: AES.GCM.SealedBox
        if deterministicNonceSeed != nil {
            sealed = try AES.GCM.seal(data, using: key, nonce: nextDeterministicNonce(), authenticating: Data(context.utf8))
        } else {
            sealed = try AES.GCM.seal(data, using: key, authenticating: Data(context.utf8))
        }
        guard let combined = sealed.combined else {
            throw LocalDataCryptorError.missingCombinedBox
        }
        return combined
    }

    private func nextDeterministicNonce() throws -> AES.GCM.Nonce {
        deterministicNonceLock.lock()
        let counter = deterministicNonceCounter
        deterministicNonceCounter += 1
        deterministicNonceLock.unlock()

        var bytes = [UInt8](repeating: deterministicNonceSeed ?? 0, count: 12)
        for index in 0..<8 {
            let shift = UInt64((7 - index) * 8)
            bytes[4 + index] = UInt8((counter >> shift) & 0xff)
        }
        return try AES.GCM.Nonce(data: bytes)
    }

    private func open(_ encrypted: Data.SubSequence, context: String) throws -> Data {
        do {
            let sealed = try AES.GCM.SealedBox(combined: Data(encrypted))
            return try AES.GCM.open(sealed, using: key, authenticating: Data(context.utf8))
        } catch {
            throw LocalDataCryptorError.invalidCiphertext
        }
    }

    private static func symmetricKey(from keyData: Data) throws -> SymmetricKey {
        guard keyData.count == keySize else {
            throw LocalDataCryptorError.invalidKeyLength(keyData.count)
        }
        return SymmetricKey(data: keyData)
    }

    private static func generateKeyData() throws -> Data {
        var keyData = Data(count: keySize)
        let status = keyData.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, keySize, baseAddress)
        }
        guard status == errSecSuccess else {
            throw LocalDataCryptorError.randomGenerationFailed(status)
        }
        return keyData
    }
}
