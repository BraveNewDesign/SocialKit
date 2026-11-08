import Foundation
import Security

public struct SocialCredential: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    public let account: SocialAccount
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let grantedScopes: Set<String>?

    public init(
        account: SocialAccount,
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        grantedScopes: Set<String>? = nil
    ) {
        self.account = account
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.grantedScopes = grantedScopes
    }

    public var oauthToken: OAuthToken {
        OAuthToken(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt, grantedScopes: grantedScopes)
    }

    public var description: String { "SocialCredential(\(account.platform.rawValue), redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["account": account]) }
}

public protocol CredentialStore: Sendable {
    func save(_ credential: SocialCredential) async throws
    func credential(for id: SocialAccount.ID) async throws -> SocialCredential?
    func accounts() async throws -> [SocialAccount]
    func remove(_ id: SocialAccount.ID) async throws
}

public actor MemoryCredentialStore: CredentialStore {
    private var credentials: [SocialAccount.ID: SocialCredential] = [:]

    public init() {}

    public func save(_ credential: SocialCredential) {
        credentials[credential.account.id] = credential
    }

    public func credential(for id: SocialAccount.ID) -> SocialCredential? {
        credentials[id]
    }

    public func accounts() -> [SocialAccount] {
        credentials.values.map(\.account)
    }

    public func remove(_ id: SocialAccount.ID) {
        credentials.removeValue(forKey: id)
    }
}

/// Use an app-specific service name and share one store between provider clients.
public actor KeychainCredentialStore: CredentialStore {
    private let service: String

    public init(service: String) {
        self.service = service
    }

    public func save(_ credential: SocialCredential) throws {
        let query = try itemQuery(credential.account.id)
        let attributes = [kSecValueData as String: try JSONEncoder().encode(credential)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(attributes) { _, value in value }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
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
        return try decode(data)
    }

    public func accounts() throws -> [SocialAccount] {
        var query = try serviceQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        try check(status)
        guard let entries = result as? [Data] else { throw SocialError.invalidResponse }
        return try entries.map { try decode($0).account }
    }

    public func remove(_ id: SocialAccount.ID) throws {
        let status = SecItemDelete(try itemQuery(id) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func serviceQuery() throws -> [String: Any] {
        guard !service.isEmpty else { throw SocialError.invalidConfiguration }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false
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
