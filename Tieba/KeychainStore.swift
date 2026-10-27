import Foundation
import Security

// 凭证只存 Keychain：不写 UserDefaults、不打日志。
enum KeychainStore {
    static let bdussAccount = "BDUSS"
    static let stokenAccount = "STOKEN"
    private static let service = "com.example.tieba"

    static func save(account: String, value: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func deleteAllCredentials() {
        delete(account: bdussAccount)
        delete(account: stokenAccount)
    }

    static var bduss: String? { load(account: bdussAccount) }
    static var stoken: String? { load(account: stokenAccount) }
    static var isLoggedIn: Bool {
        guard let value = bduss else { return false }
        return !value.isEmpty
    }
}
