import Foundation
import Security

/// Login Keychain is the only token store.
///
/// Older builds kept the same accounts in `session.tokens`. The first read or
/// write copies those values into the Keychain and deletes the file.
enum CredentialStore {
    private static let service = AppConfig.bundleID
    /// errSecMissingEntitlement — Data Protection / restricted keychain without entitlements.
    private static let missingEntitlement: OSStatus = -34018
    private static var didMigrate = false

    static func set(_ value: String, account: String) throws {
        migrateFromFileIfNeeded()
        try withoutKeychainUI {
            try setKeychain(value, account: account)
        }
    }

    static func get(account: String) throws -> String? {
        migrateFromFileIfNeeded()
        return try withoutKeychainUI {
            try getKeychain(account: account)
        }
    }

    static func delete(account: String) {
        migrateFromFileIfNeeded()
        withoutKeychainUI {
            SecItemDelete(baseQuery(account: account) as CFDictionary)
        }
    }

    /// Keychain UI stays off so an ad-hoc ACL denial fails the call instead of prompting.
    @discardableResult
    private static func withoutKeychainUI<T>(_ body: () throws -> T) rethrows -> T {
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(true) }
        return try body()
    }

    private static func migrateFromFileIfNeeded() {
        guard !didMigrate else { return }
        let url = legacyFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            didMigrate = true
            return
        }
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else {
            try? FileManager.default.removeItem(at: url)
            didMigrate = true
            return
        }
        for (account, value) in json where !value.isEmpty {
            do {
                try withoutKeychainUI {
                    try setKeychain(value, account: account)
                }
            } catch {
                return
            }
        }
        try? FileManager.default.removeItem(at: url)
        didMigrate = true
    }

    private static var legacyFileURL: URL {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Driveflow", isDirectory: true)
        return directory.appendingPathComponent("session.tokens")
    }

    private static func setKeychain(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            break
        case missingEntitlement:
            throw CredentialStoreError.unhandled(updateStatus)
        default:
            SecItemDelete(query as CFDictionary)
        }

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus == errSecSuccess { return }

        if addStatus == errSecDuplicateItem {
            SecItemDelete(query as CFDictionary)
            let retry = SecItemAdd(add as CFDictionary, nil)
            guard retry == errSecSuccess else { throw CredentialStoreError.unhandled(retry) }
            return
        }

        throw CredentialStoreError.unhandled(addStatus)
    }

    private static func getKeychain(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        if status == missingEntitlement { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw CredentialStoreError.unhandled(status)
        }
        return String(data: data, encoding: .utf8)
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

enum CredentialStoreError: LocalizedError {
    case unhandled(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unhandled(let status):
            if status == errSecDuplicateItem {
                return "Credentials already saved for this sign-in. Try signing in again."
            }
            if status == -34018 {
                return "macOS blocked credential access for this unsigned build."
            }
            return "Credential store error (\(status)). Try signing in again."
        }
    }
}
