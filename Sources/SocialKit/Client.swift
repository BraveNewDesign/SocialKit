import Foundation

/// Keep one client per provider and credential store to coordinate account operations.
public actor SocialClient<Adapter: SocialAdapter> {
    private let adapter: Adapter
    private let store: any CredentialStore
    private var busyAccounts: Set<SocialAccount.ID> = []

    public nonisolated var platform: SocialPlatform { adapter.platform }
    public nonisolated var capabilities: Set<SocialCapability> { adapter.capabilities }

    public init(adapter: Adapter, store: any CredentialStore) {
        self.adapter = adapter
        self.store = store
    }

    public func connect(_ authorization: Adapter.Authorization) async throws -> SocialAccount {
        let credential = try await adapter.connect(authorization)
        let id = credential.account.id
        try begin(id)
        defer { busyAccounts.remove(id) }
        try await store.save(credential)
        return credential.account
    }

    public func accounts() async throws -> [SocialAccount] {
        try await store.accounts().filter { $0.platform == platform }.sorted {
            ($0.server.absoluteString, $0.remoteID) < ($1.server.absoluteString, $1.remoteID)
        }
    }

    /// Remove the local credential. Provider-side revocation is a separate action.
    public func disconnect(_ id: SocialAccount.ID) async throws {
        try begin(id)
        defer { busyAccounts.remove(id) }
        try await store.remove(id)
    }

    public func refresh(_ id: SocialAccount.ID) async throws -> SocialAccount {
        try await withCredential(id, requiring: .refreshSession) { credential in
            let renewed = try await adapter.refresh(credential)
            guard renewed.account.id == id else { throw SocialError.invalidResponse }
            try await store.save(renewed)
            return renewed.account
        }
    }

    public func publish(_ draft: TextPost, as id: SocialAccount.ID) async throws -> SocialPost {
        try await withCredential(id, requiring: .publishText) { credential in
            try await adapter.publish(draft, credential: credential)
        }
    }

    public func post(id postID: String, as account: SocialAccount.ID) async throws -> SocialPost {
        try await withCredential(account, requiring: .readPost) { credential in
            try await adapter.post(id: postID, credential: credential)
        }
    }

    public func setLiked(_ liked: Bool, postID: String, as id: SocialAccount.ID) async throws {
        try await withCredential(id, requiring: liked ? .like : .unlike) { credential in
            try await adapter.setLiked(liked, postID: postID, credential: credential)
        }
    }

    private func begin(_ id: SocialAccount.ID) throws {
        guard id.platform == platform else { throw SocialError.invalidInput }
        guard busyAccounts.insert(id).inserted else { throw SocialError.accountBusy }
    }

    private func withCredential<Result: Sendable>(
        _ id: SocialAccount.ID,
        requiring capability: SocialCapability,
        operation: @Sendable (SocialCredential) async throws -> Result
    ) async throws -> Result {
        guard capabilities.contains(capability) else { throw SocialError.unsupported(capability) }
        try begin(id)
        defer { busyAccounts.remove(id) }

        guard let credential = try await store.credential(for: id) else {
            throw SocialError.authenticationRequired
        }
        guard credential.account.id == id else { throw SocialError.invalidResponse }
        return try await operation(credential)
    }
}
