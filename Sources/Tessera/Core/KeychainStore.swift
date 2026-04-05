//
//  KeychainStore.swift
//  Tessera
//
//  Keychain abstraction for persisting license and trial data.
//

import Foundation
import Security

/// A minimal Keychain wrapper scoped to Tessera's needs.
/// Uses kSecClassGenericPassword with a service prefix to avoid collisions.
struct KeychainStore {
    let servicePrefix: String

    init(appIdentifier: String) {
        self.servicePrefix = "com.tessera.\(appIdentifier)"
    }

    private func service(for key: String) -> String {
        "\(servicePrefix).\(key)"
    }

    // MARK: - String Operations

    func getString(_ key: String) -> String? {
        guard let data = getData(key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setString(_ value: String, for key: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw TesseraError.keychainError("Failed to encode string")
        }
        try setData(data, for: key)
    }

    // MARK: - Data Operations

    func getData(_ key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: key),
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    func setData(_ data: Data, for key: String) throws {
        // Try to update first
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: key),
            kSecAttrAccount as String: key
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if status == errSecItemNotFound {
            // Item doesn't exist — add it
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }

        guard status == errSecSuccess else {
            throw TesseraError.keychainError("Keychain write failed with status \(status)")
        }
    }

    func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: key),
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Convenience

    func getDate(_ key: String) -> Date? {
        guard let string = getString(key),
              let interval = TimeInterval(string) else { return nil }
        return Date(timeIntervalSince1970: interval)
    }

    func setDate(_ date: Date, for key: String) throws {
        try setString(String(date.timeIntervalSince1970), for: key)
    }
}
