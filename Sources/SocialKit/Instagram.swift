import Foundation

public struct InstagramAuthorization: Sendable {
    public let clientID: String
    public let redirectURI: URL
    public let scopes: Set<String>
    public let browser: OAuthBrowser
    public let exchange: any ConfidentialOAuthExchange

    public init(
        clientID: String,
        redirectURI: URL,
        scopes: Set<String> = ["instagram_business_basic", "instagram_business_content_publish", "instagram_business_manage_comments"],
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

/// Instagram Login adapter for professional accounts. The user-facing access token is exchanged
/// by the host's trusted service; Instagram fetches published media from public HTTPS URLs.
/// Endpoints and scopes checked 2026-11-08 against Meta's Instagram Login docs:
/// https://developers.facebook.com/docs/instagram-platform/content-publishing
/// https://developers.facebook.com/docs/instagram-platform/instagram-api-with-instagram-login/comment-moderation
public struct InstagramAdapter: SocialAdapter {
    public typealias Authorization = InstagramAuthorization
    public let platform: SocialPlatform = .instagram
    public let capabilities: Set<SocialCapability> = [
        .readPost, .listPosts, .reply, .readReplies, .deleteReply, .publishMedia, .refreshSession
    ]

    private let transport: any HTTPTransport
    private let origin = URL(string: "https://graph.instagram.com/v27.0")!
    private let accountServer = URL(string: "https://graph.instagram.com")!
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

    public func connect(_ authorization: InstagramAuthorization) async throws -> SocialCredential {
        guard !authorization.clientID.isEmpty, !authorization.scopes.isEmpty else { throw SocialError.invalidConfiguration }
        let transaction = try OAuthTransaction(redirectURI: authorization.redirectURI)
        let authURL = try OAuthForm.queryURL(URL(string: "https://www.instagram.com/oauth/authorize")!, parameters: [
            ("client_id", authorization.clientID),
            ("redirect_uri", authorization.redirectURI.absoluteString),
            ("scope", authorization.scopes.sorted().joined(separator: ",")),
            ("response_type", "code"),
            ("state", transaction.state)
        ])
        let callback = try await authorization.browser(authURL, authorization.redirectURI)
        let code = try transaction.code(from: normalizeMetaOAuthCallback(callback, platform: .instagram))
        let token = try await authorization.exchange.exchange(platform: .instagram, code: code, redirectURI: authorization.redirectURI)
        let api = try MetaHTTP(transport: transport, origin: origin, accessToken: token.accessToken)
        let profile: InstagramProfile = try await api.get("/me", query: [("fields", "id,user_id,username")])
        guard let userID = profile.user_id ?? profile.id, !userID.isEmpty else { throw SocialError.invalidResponse }
        let account = SocialAccount(platform: .instagram, server: accountServer, remoteID: userID, username: profile.username)
        return SocialCredential(account: account, accessToken: token.accessToken, refreshToken: token.refreshToken,
                                expiresAt: token.expiresAt, grantedScopes: token.grantedScopes ?? authorization.scopes)
    }

    public func refresh(_ credential: SocialCredential) async throws -> SocialCredential {
        try validate(credential)
        if let expiry = credential.expiresAt, expiry <= Date() { throw SocialError.authenticationRequired }
        let api = try MetaHTTP(transport: transport, origin: accountServer, accessToken: credential.accessToken)
        let value: InstagramRefreshResponse = try await api.get("/refresh_access_token", query: [
            ("grant_type", "ig_refresh_token"), ("access_token", credential.accessToken)
        ])
        guard !value.access_token.isEmpty, value.expires_in > 0 else { throw SocialError.invalidResponse }
        return SocialCredential(account: credential.account, accessToken: value.access_token,
                                refreshToken: credential.refreshToken,
                                expiresAt: Date().addingTimeInterval(TimeInterval(value.expires_in)),
                                grantedScopes: credential.grantedScopes)
    }

    public func capabilities(for credential: SocialCredential) -> Set<SocialCapability> {
        guard let scopes = credential.grantedScopes else { return capabilities }
        var result = capabilities
        guard scopes.contains("instagram_business_basic") else { return [] }
        if !scopes.contains("instagram_business_content_publish") { result.remove(.publishMedia) }
        if !scopes.contains("instagram_business_manage_comments") {
            result.remove(.reply); result.remove(.readReplies); result.remove(.deleteReply)
        }
        return result
    }

    public func publish(_ draft: TextPost, credential: SocialCredential) async throws -> SocialPost {
        throw SocialError.unsupported(.publishText)
    }

    public func publishMedia(_ media: SocialMedia, draft: TextPost, credential: SocialCredential) async throws -> SocialPost {
        try validate(credential)
        let accountID = try metaPathID(credential.account.remoteID)
        let api = try MetaHTTP(transport: transport, origin: origin, accessToken: credential.accessToken)
        var form: [(String, String)]
        switch media {
        case .imageURL(let url):
            try requireHTTPS(url)
            form = [("image_url", url.absoluteString)]
            if !draft.text.isEmpty { form.append(("caption", draft.text)) }
        case .videoURL(let url):
            try requireHTTPS(url)
            form = [("video_url", url.absoluteString), ("media_type", "REELS")]
            if !draft.text.isEmpty { form.append(("caption", draft.text)) }
        case .imageData:
            throw SocialError.invalidInput // Instagram's container API fetches public media URLs.
        }
        let container: MetaID = try await api.post("/\(accountID)/media", form: form, key: draft.idempotencyKey)
        guard try await waitForContainer(container.id, api: api) else { throw SocialError.mediaProcessingTimedOut }
        let result: MetaID = try await api.post("/\(accountID)/media_publish", form: [("creation_id", container.id)], key: draft.idempotencyKey)
        let attachment: SocialAttachment
        switch media {
        case .imageURL(let url): attachment = SocialAttachment(kind: .image, url: url)
        case .videoURL(let url): attachment = SocialAttachment(kind: .video, url: url)
        case .imageData: attachment = SocialAttachment(kind: .unknown, url: nil)
        }
        return SocialPost(id: result.id, text: draft.text, media: [attachment])
    }

    private func waitForContainer(_ id: String, api: MetaHTTP) async throws -> Bool {
        let path = "/\(try metaPathID(id))"
        for attempt in 0..<pollAttempts {
            let status: InstagramContainerStatus = try await api.get(path, query: [("fields", "id,status_code,status")])
            switch status.status_code {
            case "FINISHED": return true
            case "ERROR", "EXPIRED": throw SocialError.mediaProcessingFailed
            default: break
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
        var query = [("fields", Self.postFields), ("limit", "100")]
        if let cursor { query.append(("after", cursor)) }
        let result: MetaPageResponse<MetaPostRecord> = try await api.get("/\(try metaPathID(credential.account.remoteID))/media", query: query)
        return SocialPage(items: result.data.map(metaPost), nextCursor: result.paging?.next == nil ? nil : result.paging?.cursors?.after)
    }

    /// Creates a reply to an existing Instagram comment (not a new top-level media comment).
    public func reply(_ draft: TextPost, to postID: String, credential: SocialCredential) async throws -> SocialPost {
        try validate(credential)
        guard !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SocialError.invalidInput }
        let api = try MetaHTTP(transport: transport, origin: origin, accessToken: credential.accessToken)
        let result: MetaID = try await api.post("/\(try metaPathID(postID))/replies", form: [("message", draft.text)], key: draft.idempotencyKey)
        return SocialPost(id: result.id, text: draft.text)
    }

    /// Lists comments on an Instagram media object. Meta exposes comment replies as a separate edge.
    public func replies(to postID: String, cursor: String?, credential: SocialCredential) async throws -> SocialPage<SocialPost> {
        try validate(credential)
        let api = try MetaHTTP(transport: transport, origin: origin, accessToken: credential.accessToken)
        var query = [("fields", "id,text,username,timestamp,like_count"), ("limit", "100")]
        if let cursor { query.append(("after", cursor)) }
        let result: MetaPageResponse<MetaCommentRecord> = try await api.get("/\(try metaPathID(postID))/comments", query: query)
        return SocialPage(items: result.data.map(metaComment), nextCursor: result.paging?.next == nil ? nil : result.paging?.cursors?.after)
    }

    public func deleteReply(id: String, credential: SocialCredential) async throws {
        try validate(credential)
        let api = try MetaHTTP(transport: transport, origin: origin, accessToken: credential.accessToken)
        try await api.delete("/\(try metaPathID(id))")
    }

    private func validate(_ credential: SocialCredential) throws {
        guard credential.account.platform == .instagram, credential.account.server == accountServer else { throw SocialError.invalidConfiguration }
        guard !credential.accessToken.isEmpty else { throw SocialError.authenticationRequired }
    }

    private func requireHTTPS(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else {
            throw SocialError.invalidInput
        }
    }

    private static let postFields = "id,caption,permalink,timestamp,like_count,media_type,media_url"
}

private struct InstagramProfile: Decodable, Sendable { let id: String?; let user_id: String?; let username: String }
private struct InstagramContainerStatus: Decodable, Sendable { let id: String; let status_code: String }
private struct InstagramRefreshResponse: Decodable, Sendable { let access_token: String; let expires_in: Int }
