import Foundation
import Security
import SocialKit

#if os(macOS)
/// Uses the user's ordinary macOS login Keychain for the local validation app.
/// This keeps the harness runnable without an Apple provisioning profile while
/// still exercising real Keychain persistence. It is not the production store.
public actor MetaValidationCredentialStore: CredentialStore {
    private let service: String

    public init(service: String) {
        self.service = service
    }

    public func save(_ credential: SocialCredential) throws {
        let query = try itemQuery(credential.account.id)
        let attributes = [kSecValueData as String: try JSONEncoder().encode(credential)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            status = SecItemAdd(item as CFDictionary, nil)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            }
        }
        try check(status)
    }

    public func credential(for id: SocialAccount.ID) throws -> SocialCredential? {
        var query = try itemQuery(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { throw SocialError.invalidResponse }
        let credential = try decode(data)
        guard credential.account.id == id else { throw SocialError.invalidResponse }
        return credential
    }

    public func accounts() throws -> [SocialAccount] {
        var query = try serviceQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        try check(status)
        guard let entries = result as? [[String: Any]] else { throw SocialError.invalidResponse }
        return try entries.compactMap { entry in
            guard let account = entry[kSecAttrAccount as String] as? String else {
                throw SocialError.invalidResponse
            }
            var item = try serviceQuery()
            item[kSecAttrAccount as String] = account
            item[kSecReturnData as String] = true
            item[kSecMatchLimit as String] = kSecMatchLimitOne
            var dataResult: CFTypeRef?
            let itemStatus = SecItemCopyMatching(item as CFDictionary, &dataResult)
            if itemStatus == errSecItemNotFound { return nil }
            try check(itemStatus)
            guard let data = dataResult as? Data else { throw SocialError.invalidResponse }
            return try decode(data).account
        }
    }

    public func remove(_ id: SocialAccount.ID) throws {
        let status = SecItemDelete(try itemQuery(id) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func serviceQuery() throws -> [String: Any] {
        guard !service.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SocialError.invalidConfiguration
        }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
    }

    private func itemQuery(_ id: SocialAccount.ID) throws -> [String: Any] {
        var query = try serviceQuery()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        query[kSecAttrAccount as String] = try encoder.encode(id).base64EncodedString()
        return query
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw SocialError.credentialStorage(status) }
    }

    private func decode(_ data: Data) throws -> SocialCredential {
        guard let credential = try? JSONDecoder().decode(SocialCredential.self, from: data) else {
            throw SocialError.invalidResponse
        }
        return credential
    }
}
#else
public typealias MetaValidationCredentialStore = KeychainCredentialStore
#endif
