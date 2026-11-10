import Foundation

public struct ThreadsAuthorization: Sendable {
    public let clientID: String
    public let redirectURI: URL
    public let scopes: Set<String>
    public let browser: OAuthBrowser
    public let exchange: any ConfidentialOAuthExchange

    public init(
        clientID: String,
        redirectURI: URL,
        scopes: Set<String> = ["threads_basic", "threads_content_publish", "threads_read_replies", "threads_manage_replies", "threads_delete"],
        browser: @escaping OAuthBrowser,
        exchange: any ConfidentialOAuthExchange
    ) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scopes = scopes
        self.browser = browser
        self.exchange = exchange
    }
}

/// Meta Threads API adapter. The callback code is exchanged by the host application's trusted service.
/// Endpoints and required scopes checked 2026-11-08 against Meta's official collection and docs:
/// https://developers.facebook.com/documentation/threads/threads-posts
/// https://developers.facebook.com/documentation/threads/retrieve-and-manage-replies/create-replies
/// https://developers.facebook.com/documentation/threads/posts/reposts
/// Long-lived token refresh requires an unexpired token; Meta's documented endpoint takes the
/// token as a query parameter: https://developers.facebook.com/docs/threads/long-lived-tokens/
public struct ThreadsAdapter: MetaCheckpointPublishing {
    public typealias Authorization = ThreadsAuthorization
    public let platform: SocialPlatform = .threads
    public let capabilities: Set<SocialCapability> = [
        .publishText, .readPost, .listPosts, .reply, .readReplies, .deleteReply, .moderateReplies,
        .publishMedia, .repost, .refreshSession
    ]

    private let transport: any HTTPTransport
    private let origin = URL(string: "https://graph.threads.net/v1.0")!
    private let accountServer = URL(string: "https://graph.threads.net")!
    private let pollAttempts: Int
    private let pollIntervalNanoseconds: UInt64

    public init(
        transport: any HTTPTransport = URLSessionTransport(),
        pollAttempts: Int = 5,
        pollIntervalNanoseconds: UInt64 = 60_000_000_000
    ) {
        self.transport = transport
        self.pollAttempts = max(1, pollAttempts)
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
    }

    public func connect(_ authorization: ThreadsAuthorization) async throws -> SocialCredential {
        guard !authorization.clientID.isEmpty, !authorization.scopes.isEmpty else { throw SocialError.invalidConfiguration }
        let transaction = try OAuthTransaction(redirectURI: authorization.redirectURI)
        let authURL = try OAuthForm.queryURL(URL(string: "https://threads.net/oauth/authorize")!, parameters: [
            ("client_id", authorization.clientID),
            ("redirect_uri", authorization.redirectURI.absoluteString),
            ("scope", authorization.scopes.sorted().joined(separator: ",")),
            ("response_type", "code"),
            ("state", transaction.state)
        ])
        if let session = authorization.exchange as? any SessionBoundMetaOAuthExchange {
            try await session.prepare(platform: .threads, clientID: authorization.clientID,
                                      redirectURI: authorization.redirectURI, state: transaction.state)
        }
        try Task.checkCancellation()
        let callback = try await authorization.browser(authURL, authorization.redirectURI)
        let code = try transaction.code(from: callback)
        let token = try await authorization.exchange.exchange(platform: .threads, code: code, redirectURI: authorization.redirectURI)
        let account = try await fetchProfile(accessToken: token.accessToken)
        return SocialCredential(account: account, accessToken: token.accessToken,
                               expiresAt: token.expiresAt, grantedScopes: token.grantedScopes,
                                metaLongLivedRefreshEligibleAt: token.metaLongLivedRefreshEligibleAt)
    }

    /// Builds a Threads credential from an access token supplied by a development token flow.
    public func developmentCredential(_ token: OAuthToken) async throws -> SocialCredential {
        try validateMetaDevelopmentToken(token)
        let account = try await fetchProfile(accessToken: token.accessToken)
        return SocialCredential(account: account, accessToken: token.accessToken,
                                expiresAt: token.expiresAt, grantedScopes: token.grantedScopes,
                                metaLongLivedRefreshEligibleAt: token.metaLongLivedRefreshEligibleAt)
    }

    /// Fetches the authenticated Threads profile associated with this credential.
    public func profile(credential: SocialCredential) async throws -> SocialAccount {
        try validate(credential)
        return try await fetchProfile(accessToken: credential.accessToken)
    }

    private func fetchProfile(accessToken: String) async throws -> SocialAccount {
        let api = try MetaHTTP(transport: transport, origin: origin, accessToken: accessToken)
        let profile: ThreadsProfile = try await api.get("/me", query: [("fields", "id,username")])
        guard !profile.id.isEmpty else { throw SocialError.invalidResponse }
        return SocialAccount(platform: .threads, server: accountServer, remoteID: profile.id, username: profile.username,
                             displayName: profile.username,
                             profileURL: URL(string: "https://www.threads.net/@\(profile.username)"))
    }

    public func refresh(_ credential: SocialCredential) async throws -> SocialCredential {
        try validate(credential)
        let now = Date()
        if let expiry = credential.expiresAt, expiry <= now { throw SocialError.authenticationRequired }
        guard credential.canRefreshMetaLongLivedToken(at: now) else { throw SocialError.unsupported(.refreshSession) }
        let api = try MetaHTTP(transport: transport, origin: accountServer, accessToken: credential.accessToken)
        let value: MetaRefreshResponse = try await api.get("/refresh_access_token", query: [
            ("grant_type", "th_refresh_token"), ("access_token", credential.accessToken)
        ])
        guard !value.access_token.isEmpty, value.expires_in > 0 else { throw SocialError.invalidResponse }
        return SocialCredential(account: credential.account, accessToken: value.access_token,
                                expiresAt: now.addingTimeInterval(TimeInterval(value.expires_in)),
                                grantedScopes: credential.grantedScopes,
                                metaLongLivedRefreshEligibleAt: now.addingTimeInterval(24 * 60 * 60))
    }

    public func capabilities(for credential: SocialCredential) -> Set<SocialCapability> {
        guard let scopes = credential.grantedScopes else { return capabilities }
        var result = capabilities
        guard scopes.contains("threads_basic") else { return [] }
        if !scopes.contains("threads_content_publish") { result.remove(.publishText); result.remove(.publishMedia); result.remove(.reply); result.remove(.repost) }
        if !scopes.contains("threads_read_replies") { result.remove(.readReplies) }
        if !scopes.contains("threads_manage_replies") { result.subtract([.reply, .moderateReplies]) }
        if !scopes.contains("threads_delete") { result.remove(.deleteReply) }
        return result
    }

    public func publish(_ draft: TextPost, credential: SocialCredential) async throws -> SocialPost {
        try await publishContainer(media: nil, draft: draft, credential: credential)
    }

    public func publishMedia(_ media: SocialMedia, draft: TextPost, credential: SocialCredential) async throws -> SocialPost {
        try await publishContainer(media: media, draft: draft, credential: credential)
    }

    func publishCheckpointed(
        _ media: [SocialMedia], draft: TextPost, credential: SocialCredential,
        checkpoint: MetaPublishingCheckpoint?, save: @escaping MetaPublishingCheckpointWriter
    ) async throws -> SocialPost {
        guard media.count <= 1 else { throw SocialError.unsupported(.publishMultipleMedia) }
        return try await publishContainer(media: media.first, draft: draft, credential: credential, checkpoint: checkpoint, save: save)
    }

    private func publishContainer(
        media: SocialMedia?, draft: TextPost, credential: SocialCredential,
        checkpoint: MetaPublishingCheckpoint? = nil, save: MetaPublishingCheckpointWriter? = nil
    ) async throws -> SocialPost {
        try validate(credential)
        try Self.validateText(draft.text, allowsEmpty: media != nil)
        let id = try metaPathID(credential.account.remoteID)
        let api = try MetaHTTP(transport: transport, origin: origin, accessToken: credential.accessToken)
        var form: [(String, String)] = [("media_type", "TEXT"), ("text", draft.text)]
        switch media {
        case nil: break
        case .imageURL(let url):
            try requireHTTPS(url); form = [("media_type", "IMAGE"), ("image_url", url.absoluteString), ("text", draft.text)]
        case .videoURL(let url):
            try requireHTTPS(url); form = [("media_type", "VIDEO"), ("video_url", url.absoluteString), ("text", draft.text)]
        case .imageData: throw SocialError.invalidInput // Threads fetches public URLs; binary upload is not available in this contract.
        }
        let containerID = try await metaPublishingContainer(checkpoint: checkpoint, draft: draft, save: save) {
            let container: MetaID = try await api.post("/\(id)/threads", form: form)
            return container.id
        }
        guard try await waitForContainer(containerID, api: api, publishingKey: draft.idempotencyKey) else { throw SocialError.mediaProcessingTimedOut }
        try await beginMetaPublish(containerID, save: save)
        let result: MetaID = try await api.post("/\(id)/threads_publish", form: [("creation_id", containerID)], key: draft.idempotencyKey)
        guard (try? metaPathID(result.id)) != nil else { throw SocialError.publishOutcomeUnknown(draft.idempotencyKey) }
        return SocialPost(id: result.id, text: draft.text, media: socialAttachments(for: media))
    }

    func wasPublished(_ checkpoint: MetaPublishingCheckpoint, credential: SocialCredential) async throws -> Bool {
        try validate(credential)
        let id = try metaPathID(checkpoint.containerID)
        let api = try MetaHTTP(transport: transport, origin: origin, accessToken: credential.accessToken)
        let status: ThreadsContainerStatus = try await api.get("/\(id)", query: [("fields", "id,status")])
        guard status.id == id else { throw SocialError.invalidResponse }
        return status.status == "PUBLISHED"
    }

    private func waitForContainer(_ id: String, api: MetaHTTP, publishingKey: UUID) async throws -> Bool {
        let path = "/\(try metaPathID(id))"
        for attempt in 0..<pollAttempts {
            let status: ThreadsContainerStatus = try await api.get(path, query: [("fields", "id,status,error_message")])
            guard status.id == id else { throw SocialError.invalidResponse }
            switch status.status {
            case "FINISHED": return true
            case "PUBLISHED": throw SocialError.publishOutcomeUnknown(publishingKey)
            case "ERROR", "EXPIRED": throw SocialError.mediaProcessingFailed
            case "IN_PROGRESS": break
            default: throw SocialError.invalidResponse
            }
            if attempt + 1 < pollAttempts, pollIntervalNanoseconds > 0 {
                try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            }
        }
        return false
    }

    public func post(id: String, credential: SocialCredential) async throws -> SocialPost {
        try validate(credential)
        let api = try MetaHTTP(transport: transport, origin: origin, accessToken: credential.accessToken)
        let value: MetaPostRecord = try await api.get("/\(try metaPathID(id))", query: [("fields", Self.postFields)])
        return metaPost(value)
    }

    public func posts(cursor: String?, credential: SocialCredential) async throws -> SocialPage<SocialPost> {
        try validate(credential)
        let api = try MetaHTTP(transport: transport, origin: origin, accessToken: credential.accessToken)
        var query = [("fields", Self.postFields)]
        if let cursor { query.append(("after", cursor)) }
        let value: MetaPageResponse<MetaPostRecord> = try await api.get("/\(try metaPathID(credential.account.remoteID))/threads", query: query)
        return SocialPage(items: value.data.map(metaPost), nextCursor: value.paging?.next == nil ? nil : value.paging?.cursors?.after)
    }

    public func reply(_ draft: TextPost, to postID: String, credential: SocialCredential) async throws -> SocialPost {
        try validate(credential)
        try Self.validateText(draft.text, allowsEmpty: false)
        let owner = try metaPathID(credential.account.remoteID)
        let target = try metaPathID(postID)
        let api = try MetaHTTP(transport: transport, origin: origin, accessToken: credential.accessToken)
        let container: MetaID = try await api.post("/\(owner)/threads", form: [
            ("media_type", "TEXT"), ("text", draft.text), ("reply_to_id", target)
        ])
        guard try await waitForContainer(container.id, api: api, publishingKey: draft.idempotencyKey) else { throw SocialError.mediaProcessingTimedOut }
        let result: MetaID = try await api.post("/\(owner)/threads_publish", form: [("creation_id", container.id)], key: draft.idempotencyKey)
        guard (try? metaPathID(result.id)) != nil else { throw SocialError.publishOutcomeUnknown(draft.idempotencyKey) }
        return SocialPost(id: result.id, text: draft.text)
    }

    public func replies(to postID: String, cursor: String?, credential: SocialCredential) async throws -> SocialPage<SocialPost> {
        try validate(credential)
        let api = try MetaHTTP(transport: transport, origin: origin, accessToken: credential.accessToken)
        var query = [("fields", "id,text,username,is_reply_owned_by_me,is_reply,root_post,replied_to,timestamp,permalink,media_type,media_url")]
        if let cursor { query.append(("after", cursor)) }
        let value: MetaPageResponse<MetaPostRecord> = try await api.get("/\(try metaPathID(postID))/replies", query: query)
        let after = value.paging?.cursors?.after
        let next = value.data.isEmpty || after == cursor ? nil : after
        return SocialPage(items: value.data.map(metaPost), nextCursor: next)
    }

    public func setReplyHidden(_ hidden: Bool, id: String, credential: SocialCredential) async throws {
        try validate(credential)
        guard capabilities(for: credential).contains(.moderateReplies) else { throw SocialError.permissionDenied }
        let api = try MetaHTTP(transport: transport, origin: origin, accessToken: credential.accessToken)
        let result: MetaSuccess = try await api.post(
            "/\(try metaPathID(id))/manage_reply", form: [], query: [("hide", String(hidden))]
        )
        guard result.success else { throw SocialError.invalidResponse }
    }

    public func deleteReply(id: String, credential: SocialCredential) async throws {
        try validate(credential)
        let api = try MetaHTTP(transport: transport, origin: origin, accessToken: credential.accessToken)
        try await api.delete("/\(try metaPathID(id))")
    }

    public func setReposted(_ reposted: Bool, postID: String, credential: SocialCredential) async throws {
        guard reposted else { throw SocialError.unsupported(.unrepost) }
        try validate(credential)
        let api = try MetaHTTP(transport: transport, origin: origin, accessToken: credential.accessToken)
        let result: MetaID = try await api.post("/\(try metaPathID(postID))/repost", form: [])
        guard !result.id.isEmpty else { throw SocialError.invalidResponse }
    }

    private func validate(_ credential: SocialCredential) throws {
        guard credential.account.platform == .threads, credential.account.server == accountServer else { throw SocialError.invalidConfiguration }
        guard !credential.accessToken.isEmpty else { throw SocialError.authenticationRequired }
    }

    private static func validateText(_ text: String, allowsEmpty: Bool) throws {
        let length = text.unicodeScalars.reduce(0) { $0 + ($1.value > 0xFFFF ? 4 : 1) }
        guard length <= 500, allowsEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SocialError.invalidInput
        }
    }

    private func requireHTTPS(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else {
            throw SocialError.invalidInput
        }
    }

    private static let postFields = "id,text,username,is_reply_owned_by_me,is_reply,root_post,replied_to,permalink,timestamp,media_type,media_url"
}

private struct ThreadsProfile: Decodable, Sendable { let id: String; let username: String }
private struct ThreadsContainerStatus: Decodable, Sendable { let id: String; let status: String }
private struct MetaRefreshResponse: Decodable, Sendable { let access_token: String; let expires_in: Int }

private func socialAttachments(for media: SocialMedia?) -> [SocialAttachment] {
    switch media {
    case nil: return []
    case .imageURL(let url): return [SocialAttachment(kind: .image, url: url)]
    case .videoURL(let url): return [SocialAttachment(kind: .video, url: url)]
    case .imageData: return []
    }
}
