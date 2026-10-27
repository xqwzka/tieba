import Foundation
import Security

// 凭证只存本机 Keychain，不写 UserDefaults、不打日志、不上传服务器。
enum KeychainStore {
    static let bdussAccount = "BDUSS"
    static let stokenAccount = "STOKEN"

    static var bduss: String? { read(account: bdussAccount) }
    static var stoken: String? { read(account: stokenAccount) }
    static var isLoggedIn: Bool { bduss?.isEmpty == false }

    @discardableResult
    static func save(account: String, value: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: "tieba",
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: "tieba",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func clear() {
        for account in [bdussAccount, stokenAccount] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: account,
                kSecAttrService as String: "tieba",
            ]
            SecItemDelete(query as CFDictionary)
        }
    }
}
