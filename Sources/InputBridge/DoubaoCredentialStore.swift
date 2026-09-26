import Foundation
import Security

enum DoubaoCredentialStore {
    private static let service = "com.inputbridge.macos.doubao-asr"
    private static let account = "api-key"

    static func load() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else { return "" }
        return key
    }

    @discardableResult
    static func save(_ key: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty { return SecItemDelete(query as CFDictionary) }
        let data = Data(normalized.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status != errSecItemNotFound { return status }
        var add = query
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil)
    }
}
