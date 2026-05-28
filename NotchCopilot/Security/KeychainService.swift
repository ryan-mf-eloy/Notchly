import Foundation
import Security

enum KeychainError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status): "Keychain operation failed with status \(status)."
        case .invalidData: "The stored Keychain item is not valid UTF-8."
        }
    }
}

final class AppleKeychainService {
    struct Operations: @unchecked Sendable {
        var update: (_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus
        var add: (_ item: [String: Any]) -> OSStatus
        var copyMatching: (_ query: [String: Any]) -> (OSStatus, Data?)
        var delete: (_ query: [String: Any]) -> OSStatus

        static let live = Operations(
            update: { query, attributes in
                SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            },
            add: { item in
                SecItemAdd(item as CFDictionary, nil)
            },
            copyMatching: { query in
                var item: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &item)
                return (status, item as? Data)
            },
            delete: { query in
                SecItemDelete(query as CFDictionary)
            }
        )
    }

    private enum CacheEntry: Sendable {
        case found(Data)
        case present
        case missing
    }

    private struct CacheKey: Hashable, Sendable {
        var service: String
        var account: String
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [CacheKey: CacheEntry] = [:]

    private let service: String
    private let accessibility = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    private let operations: Operations

    init(
        service: String = "com.notchcopilot.app",
        operations: Operations = .live,
        manageTrustedApplicationAccess: Bool = true
    ) {
        self.service = service
        self.operations = operations
    }

    static func runtimeDefault() -> AppleKeychainService {
        ProcessInfo.processInfo.usesEphemeralSecurityStores ? .inMemory() : AppleKeychainService()
    }

    static func inMemory(
        service: String = "com.notchcopilot.tests.keychain.\(UUID().uuidString)"
    ) -> AppleKeychainService {
        let backend = InMemoryKeychainBackend()
        return AppleKeychainService(
            service: service,
            operations: backend.operations(),
            manageTrustedApplicationAccess: false
        )
    }

    func set(_ value: String, account: String) throws {
        try set(Data(value.utf8), account: account)
    }

    func set(_ data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility
        ]
        let status = operations.update(query, attributes)
        if status == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = data
            newItem[kSecAttrAccessible as String] = accessibility
            let addStatus = operations.add(newItem)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.unexpectedStatus(status)
        }
        cache(.found(data), account: account)
    }

    func get(account: String) throws -> String? {
        guard let data = try getData(account: account) else { return nil }
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        return value
    }

    func getData(account: String) throws -> Data? {
        if let cached = cached(account: account) {
            switch cached {
            case .found(let data):
                return data
            case .present:
                break
            case .missing:
                return nil
            }
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        let (status, item) = operations.copyMatching(query)
        if status == errSecItemNotFound {
            cache(.missing, account: account)
            return nil
        }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = item else {
            throw KeychainError.invalidData
        }
        cache(.found(data), account: account)
        return data
    }

    func contains(account: String) -> Bool {
        if let cached = cached(account: account) {
            switch cached {
            case .found, .present:
                return true
            case .missing:
                return false
            }
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
        ]
        let (status, _) = operations.copyMatching(query)
        if status == errSecSuccess {
            cache(.present, account: account)
            return true
        }
        if status == errSecItemNotFound {
            cache(.missing, account: account)
        }
        return false
    }

    func hasCachedData(account: String) -> Bool {
        if case .found = cached(account: account) {
            return true
        }
        return false
    }

    func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = operations.delete(query)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
        cache(.missing, account: account)
    }

    private func cached(account: String) -> CacheEntry? {
        let key = CacheKey(service: service, account: account)
        Self.cacheLock.lock()
        defer { Self.cacheLock.unlock() }
        return Self.cache[key]
    }

    private func cache(_ entry: CacheEntry, account: String) {
        let key = CacheKey(service: service, account: account)
        Self.cacheLock.lock()
        Self.cache[key] = entry
        Self.cacheLock.unlock()
    }
}

private final class InMemoryKeychainBackend {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    func operations() -> AppleKeychainService.Operations {
        AppleKeychainService.Operations(
            update: { query, attributes in
                guard let account = Self.account(from: query),
                      let data = attributes[kSecValueData as String] as? Data
                else { return errSecParam }

                self.lock.lock()
                defer { self.lock.unlock() }
                guard self.items[account] != nil else { return errSecItemNotFound }
                self.items[account] = data
                return errSecSuccess
            },
            add: { item in
                guard let account = Self.account(from: item),
                      let data = item[kSecValueData as String] as? Data
                else { return errSecParam }

                self.lock.lock()
                defer { self.lock.unlock() }
                guard self.items[account] == nil else { return errSecDuplicateItem }
                self.items[account] = data
                return errSecSuccess
            },
            copyMatching: { query in
                guard let account = Self.account(from: query) else { return (errSecParam, nil) }

                self.lock.lock()
                defer { self.lock.unlock() }
                guard let data = self.items[account] else { return (errSecItemNotFound, nil) }
                return (errSecSuccess, data)
            },
            delete: { query in
                guard let account = Self.account(from: query) else { return errSecParam }

                self.lock.lock()
                defer { self.lock.unlock() }
                if self.items.removeValue(forKey: account) == nil {
                    return errSecItemNotFound
                }
                return errSecSuccess
            }
        )
    }

    private static func account(from item: [String: Any]) -> String? {
        item[kSecAttrAccount as String] as? String
    }
}

extension ProcessInfo {
    var isRunningXCTest: Bool {
        environment["XCTestConfigurationFilePath"] != nil ||
            environment["XCTestBundlePath"] != nil ||
            NSClassFromString("XCTest.XCTestCase") != nil ||
            NSClassFromString("XCTestCase") != nil
    }

    var isQuestionAnsweringUITestHarness: Bool {
        arguments.contains("--qa-ui-harness") ||
            environment["NOTCHCOPILOT_QA_UI_HARNESS"] == "1"
    }

    var usesEphemeralSecurityStores: Bool {
        isRunningXCTest || isQuestionAnsweringUITestHarness
    }
}
