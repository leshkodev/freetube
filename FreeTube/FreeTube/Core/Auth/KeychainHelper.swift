import Foundation
import Security

/// Tiny `Security`-framework Keychain wrapper. Used until/unless the project adopts `KeychainAccess`
/// as listed in the locked stack. Once `KeychainAccess` is added via SPM, swap the body of these
/// methods to call into `Keychain(service:)`. The call sites in this app do not change.
enum KeychainHelper {
    static let service = "com.leshko.freetube"

    static func set(_ data: Data, for key: String) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
    }

    static func set(_ string: String, for key: String) throws {
        guard let data = string.data(using: .utf8) else { throw KeychainError.invalidUTF8 }
        try set(data, for: key)
    }

    static func data(for key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    static func string(for key: String) -> String? {
        guard let data = data(for: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum KeychainError: Error {
    case osStatus(OSStatus)
    case invalidUTF8
}
