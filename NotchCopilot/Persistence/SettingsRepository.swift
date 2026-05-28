import Foundation

final class SettingsRepository {
    private let key = "notchCopilot.preferences.v1"
    private let encryptionContext = "SettingsRepository.AppPreferences.v1"
    private let defaults: UserDefaults
    private let cryptor: LocalDataCryptor

    init(defaults: UserDefaults = .standard, cryptor: LocalDataCryptor = .defaultOrCrash()) {
        self.defaults = defaults
        self.cryptor = cryptor
    }

    func load() -> AppPreferences {
        guard let storedData = defaults.data(forKey: key) else {
            return AppPreferences()
        }
        do {
            let data = try cryptor.decryptData(storedData, context: encryptionContext)
            let preferences = try JSONDecoder().decode(AppPreferences.self, from: data)
            return normalized(preferences)
        } catch {
            AppLog.persistence.error("Failed to load encrypted preferences: \(error.localizedDescription, privacy: .public)")
            return AppPreferences()
        }
    }

    func save(_ preferences: AppPreferences) {
        do {
            let data = try JSONEncoder().encode(normalized(preferences))
            let encrypted = try cryptor.encryptData(data, context: encryptionContext)
            defaults.set(encrypted, forKey: key)
            defaults.synchronize()
        } catch {
            AppLog.persistence.error("Failed to save encrypted preferences: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func normalized(_ preferences: AppPreferences) -> AppPreferences {
        preferences.normalizedForPersistence()
    }
}
