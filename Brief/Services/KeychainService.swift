import Foundation
import Security

/// Minimal Keychain wrapper for AI provider API keys. Each provider gets
/// its own slot so Brief can hold both an OpenRouter and a Bazaarlink key
/// at once and fail over between them.
enum KeychainService {
    private static let service = "com.jerry.brief"

    enum APIKeyKind: String {
        // Kept as "openrouter-api-key" for backward compatibility with
        // keys already saved before Bazaarlink support existed.
        case openRouter = "openrouter-api-key"
        case bazaarlink = "bazaarlink-api-key"
    }

    enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)
        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                return "Keychain error (\(status))."
            }
        }
    }

    static func loadAPIKey(_ kind: APIKeyKind) -> String? {
        var query = baseQuery(account: kind.rawValue)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        let key = String(decoding: data, as: UTF8.self)
        return key.isEmpty ? nil : key
    }

    static func saveAPIKey(_ key: String, kind: APIKeyKind) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try deleteAPIKey(kind)
            return
        }
        let data = Data(trimmed.utf8)
        var query = baseQuery(account: kind.rawValue)
        let update: [String: Any] = [kSecValueData as String: data]

        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    static func deleteAPIKey(_ kind: APIKeyKind) throws {
        let status = SecItemDelete(baseQuery(account: kind.rawValue) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// True when at least one provider has a saved key - used to gate
    /// whether generation can run at all.
    static func hasAnyAPIKey() -> Bool {
        loadAPIKey(.openRouter) != nil || loadAPIKey(.bazaarlink) != nil
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
