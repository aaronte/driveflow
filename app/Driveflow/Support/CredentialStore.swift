import Foundation
import Security

/// Persists auth secrets for Driveflow.
///
/// Strategy:
/// 1. The Application Support file store is the primary source of truth. Ad-hoc
///    builds run from changing paths, so the login keychain treats every rebuild
///    as a different app and throws password prompts for each item read.
/// 2. The keychain is a silent best-effort mirror: all SecItem calls run with
///    process keychain UI disabled, so an ACL denial fails quietly
///    (errSecInteractionNotAllowed) instead of prompting the user.
enum CredentialStore {
    private static let service = AppConfig.bundleID
    /// errSecMissingEntitlement — Data Protection / restricted keychain without entitlements.
    private static let missingEntitlement: OSStatus = -34018

    static func set(_ value: String, account: String) throws {
        try setFile(value, account: account)
        // Best-effort keychain; never fail the sign-in solely because of ACL/entitlements.
        withoutKeychainUI {
            try? setKeychain(value, account: account)
        }
    }

    static func get(account: String) throws -> String? {
        // File first: reading it never triggers a keychain password prompt.
        if let value = try getFile(account: account), !value.isEmpty {
            return value
        }
        // Migration path for sessions saved by older builds — silent only.
        let migrated = withoutKeychainUI {
            try? getKeychain(account: account)
        }
        if let migrated, !migrated.isEmpty {
            try? setFile(migrated, account: account)
            return migrated
        }
        return nil
    }

    static func delete(account: String) {
        deleteFile(account: account)
        withoutKeychainUI {
            SecItemDelete(baseQuery(account: account) as CFDictionary)
        }
    }

    /// Runs keychain calls with UI suppressed so ACL mismatches (ad-hoc builds
    /// launched from changing paths) fail with errSecInteractionNotAllowed
    /// instead of prompting for the login keychain password.
    @discardableResult
    private static func withoutKeychainUI<T>(_ body: () -> T) -> T {
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(true) }
        return body()
    }

    // MARK: - Keychain (best-effort mirror)

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
            // Intentionally NOT using kSecUseDataProtectionKeychain — that requires
            // keychain-access-groups entitlements unavailable under ad-hoc signing.
        ]
    }

    // MARK: - Application Support (primary)

    private static var storeURL: URL {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Driveflow", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("session.tokens")
    }

    private static func loadFileStore() -> [String: String] {
        guard let data = try? Data(contentsOf: storeURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return json
    }

    private static func saveFileStore(_ values: [String: String]) throws {
        let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted])
        try data.write(to: storeURL, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: storeURL.path
        )
    }

    private static func setFile(_ value: String, account: String) throws {
        var values = loadFileStore()
        values[account] = value
        try saveFileStore(values)
    }

    private static func getFile(account: String) throws -> String? {
        loadFileStore()[account]
    }

    private static func deleteFile(account: String) {
        var values = loadFileStore()
        values.removeValue(forKey: account)
        try? saveFileStore(values)
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
