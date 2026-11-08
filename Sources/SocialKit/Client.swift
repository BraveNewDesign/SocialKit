import Foundation

/// Keep one client per provider and credential store to coordinate account operations.
public actor SocialClient<Adapter: SocialAdapter> {
    private let adapter: Adapter
    private let store: any CredentialStore
    private var busyAccounts: Set<SocialAccount.ID> = []
    private var connecting = false

    public nonisolated var platform: SocialPlatform { adapter.platform }
    public nonisolated var capabilities: Set<SocialCapability> { adapter.capabilities }

    public init(adapter: Adapter, store: any CredentialStore) {
        self.adapter = adapter
        self.store = store
    }

    public func connect(_ authorization: Adapter.Authorization) async throws -> SocialAccount {
        try Task.checkCancellation()
        guard !connecting else { throw SocialError.accountBusy }
        connecting = true
        defer { connecting = false }
        let credential = try await adapter.connect(authorization)
        try Task.checkCancellation()
        guard !credential.accessToken.isEmpty else { throw SocialError.invalidResponse }
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
            guard renewed.account.id == id, !renewed.accessToken.isEmpty else { throw SocialError.invalidResponse }
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

    public func capabilities(for id: SocialAccount.ID) async throws -> Set<SocialCapability> {
        guard id.platform == platform else { throw SocialError.invalidInput }
        guard let credential = try await store.credential(for: id), credential.account.id == id else {
            throw SocialError.authenticationRequired
        }
        return adapter.capabilities(for: credential).intersection(capabilities)
    }

    public func posts(cursor: String? = nil, as id: SocialAccount.ID) async throws -> SocialPage<SocialPost> {
        try await withCredential(id, requiring: .listPosts) { credential in
            try await adapter.posts(cursor: cursor, credential: credential)
        }
    }

    public func reply(_ draft: TextPost, to postID: String, as id: SocialAccount.ID) async throws -> SocialPost {
        try await withCredential(id, requiring: .reply) { credential in
            try await adapter.reply(draft, to: postID, credential: credential)
        }
    }

    public func replies(
        to postID: String, cursor: String? = nil, as id: SocialAccount.ID
    ) async throws -> SocialPage<SocialPost> {
        try await withCredential(id, requiring: .readReplies) { credential in
            try await adapter.replies(to: postID, cursor: cursor, credential: credential)
        }
    }

    public func setReplyHidden(_ hidden: Bool, id replyID: String, as account: SocialAccount.ID) async throws {
        try await withCredential(account, requiring: .moderateReplies) { credential in
            try await adapter.setReplyHidden(hidden, id: replyID, credential: credential)
        }
    }

    public func deleteReply(id replyID: String, as account: SocialAccount.ID) async throws {
        try await withCredential(account, requiring: .deleteReply) { credential in
            try await adapter.deleteReply(id: replyID, credential: credential)
        }
    }

    public func publishMedia(
        _ media: SocialMedia, draft: TextPost, as id: SocialAccount.ID
    ) async throws -> SocialPost {
        try await withCredential(id, requiring: .publishMedia) { credential in
            try await adapter.publishMedia(media, draft: draft, credential: credential)
        }
    }

    public func publishMedia(
        _ media: [SocialMedia], draft: TextPost, as id: SocialAccount.ID
    ) async throws -> SocialPost {
        guard let first = media.first else { throw SocialError.invalidInput }
        if media.count == 1 { return try await publishMedia(first, draft: draft, as: id) }
        return try await withCredential(id, requiring: .publishMultipleMedia) { credential in
            try await adapter.publishMedia(media, draft: draft, credential: credential)
        }
    }

    public func setReposted(_ reposted: Bool, postID: String, as id: SocialAccount.ID) async throws {
        try await withCredential(id, requiring: reposted ? .repost : .unrepost) { credential in
            try await adapter.setReposted(reposted, postID: postID, credential: credential)
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
        try Task.checkCancellation()
        guard capabilities.contains(capability) else { throw SocialError.unsupported(capability) }
        try begin(id)
        defer { busyAccounts.remove(id) }

        guard let credential = try await store.credential(for: id) else {
            throw SocialError.authenticationRequired
        }
        guard credential.account.id == id else { throw SocialError.invalidResponse }
        guard adapter.capabilities(for: credential).contains(capability) else {
            throw SocialError.permissionDenied
        }
        if capability != .refreshSession, let expiresAt = credential.expiresAt, expiresAt <= Date() {
            throw SocialError.authenticationRequired
        }
        try Task.checkCancellation()
        return try await operation(credential)
    }
}
