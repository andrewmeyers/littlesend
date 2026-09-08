import Foundation
import Security

/// Reads and clears secrets left behind by earlier versions, which stored the
/// API key and SMTP password in the Keychain.
///
/// This type deliberately has no write path. It exists only so an upgrade does
/// not silently lose credentials, and so nothing is left behind in the
/// Keychain afterwards. Once you are confident no install still has the old
/// items, the whole file can be deleted.
enum LegacyKeychain {
    private static let service = "com.kindleclip.KindleClip"

    enum Account: String, CaseIterable {
        case instaparserAPIKey = "instaparser-api-key"
        case smtpPassword = "smtp-password"
    }

    /// Returns any stored values and removes them from the Keychain.
    static func drain() -> [Account: String] {
        var found: [Account: String] = [:]
        for account in Account.allCases {
            if let value = read(account), !value.isEmpty {
                found[account] = value
            }
            delete(account)
        }
        return found
    }

    private static func read(_ account: Account) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func delete(_ account: Account) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
