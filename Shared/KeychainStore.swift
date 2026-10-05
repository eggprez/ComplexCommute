import Foundation
import Security

/// User-supplied agency API keys. Device-only: they are not synced or included in backups.
/// Kept in the keychain group the app shares with its widgets, so a departures widget can ask an agency for live
/// times too.
nonisolated enum KeychainStore {
    private static let service = "com.complexcommute.apikeys"

    /// Looks in every group this process can read, so a key saved before there were widgets is still found by the app.
    static func string(for account: String) -> String? {
        read(account, group: nil)
    }

    /// Stores `value`, or deletes the item when it is nil or empty.
    static func set(_ value: String?, for account: String) {
        SecItemDelete(baseQuery(account, group: nil) as CFDictionary)
        guard let value, !value.isEmpty else { return }
        // A build without the shared group can still keep the key to itself.
        if !add(value, account, group: AppGroup.id) {
            _ = add(value, account, group: nil)
        }
    }

    /// Moves keys saved before widgets existed to where a widget can read them. The app runs this at launch.
    static func shareWithWidgets(_ accounts: [String]) {
        for account in accounts where read(account, group: AppGroup.id) == nil {
            if let value = read(account, group: nil) { set(value, for: account) }
        }
    }

    private static func read(_ account: String, group: String?) -> String? {
        var query = baseQuery(account, group: group)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func add(_ value: String, _ account: String, group: String?) -> Bool {
        var item = baseQuery(account, group: group)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private static func baseQuery(_ account: String, group: String?) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        if let group { query[kSecAttrAccessGroup as String] = group }
        return query
    }
}
