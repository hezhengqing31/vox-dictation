import Foundation
import Security

/// API keys live in the login keychain, never in UserDefaults — the app is open source and
/// preferences get copied around in backups and screenshots.
enum Keychain {
    private static let service = "app.voxdictation.keys"

    /// Account name per slot, e.g. "llm.deepseek" or "asr.openai".
    static func set(_ value: String?, account: String) {
        guard let value, !value.isEmpty else { remove(account: account); return }
        let data = Data(value.utf8)
        // Replace whatever is stored: delete first so the add cannot fail with errSecDuplicateItem.
        SecItemDelete(baseQuery(account: account) as CFDictionary)
        var query = baseQuery(account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }

    static func get(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func remove(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
