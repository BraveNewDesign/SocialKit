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
public struct InstagramAdapter: MetaCheckpointPublishing {
    public typealias Authorization = InstagramAuthorization
    public let platform: SocialPlatform = .instagram
    public let capabilities: Set<SocialCapability> = [
        .readPost, .listPosts, .reply, .readReplies, .deleteReply, .publishMedia, .publishMultipleMedia, .refreshSession
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
        if let session = authorization.exchange as? any SessionBoundMetaOAuthExchange {
            try await session.prepare(platform: .instagram, clientID: authorization.clientID,
                                      redirectURI: authorization.redirectURI, state: transaction.state)
        }
        try Task.checkCancellation()
        let callback = try await authorization.browser(authURL, authorization.redirectURI)
        let code = try transaction.code(from: normalizeMetaOAuthCallback(callback, platform: .instagram))
        let token = try await authorization.exchange.exchange(platform: .instagram, code: code, redirectURI: authorization.redirectURI)
        let account = try await fetchProfile(accessToken: token.accessToken)
        return SocialCredential(account: account, accessToken: token.accessToken,
                                expiresAt: token.expiresAt, grantedScopes: token.grantedScopes,
                                metaLongLivedRefreshEligibleAt: token.metaLongLivedRefreshEligibleAt)
    }

    /// Builds an Instagram credential from an access token supplied by a development token flow.
    public func developmentCredential(_ token: OAuthToken) async throws -> SocialCredential {
        try validateMetaDevelopmentToken(token)
        let account = try await fetchProfile(accessToken: token.accessToken)
        return SocialCredential(account: account, accessToken: token.accessToken,
                                expiresAt: token.expiresAt, grantedScopes: token.grantedScopes,
                                metaLongLivedRefreshEligibleAt: token.metaLongLivedRefreshEligibleAt)
    }

    /// Fetches the authenticated Instagram professional account associated with this credential.
    public func profile(credential: SocialCredential) async throws -> SocialAccount {
        try validate(credential)
        return try await fetchProfile(accessToken: credential.accessToken)
    }

    private func fetchProfile(accessToken: String) async throws -> SocialAccount {
        let api = try MetaHTTP(transport: transport, origin: origin, accessToken: accessToken)
        let profile: InstagramProfile = try await api.get("/me", query: [("fields", "id,user_id,username")])
        guard let userID = profile.user_id ?? profile.id, !userID.isEmpty else { throw SocialError.invalidResponse }
        return SocialAccount(platform: .instagram, server: accountServer, remoteID: userID, username: profile.username,
                             displayName: profile.username,
                             profileURL: URL(string: "https://www.instagram.com/\(profile.username)/"))
    }

    public func refresh(_ credential: SocialCredential) async throws -> SocialCredential {
        try validate(credential)
        let now = Date()
        if let expiry = credential.expiresAt, expiry <= now { throw SocialError.authenticationRequired }
        guard credential.canRefreshMetaLongLivedToken(at: now) else { throw SocialError.unsupported(.refreshSession) }
        let api = try MetaHTTP(transport: transport, origin: accountServer, accessToken: credential.accessToken)
        let value: InstagramRefreshResponse = try await api.get("/refresh_access_token", query: [
            ("grant_type", "ig_refresh_token"), ("access_token", credential.accessToken)
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
        guard scopes.contains("instagram_business_basic") else { return [] }
        if !scopes.contains("instagram_business_content_publish") { result.subtract([.publishMedia, .publishMultipleMedia]) }
        if !scopes.contains("instagram_business_manage_comments") {
            result.remove(.reply); result.remove(.readReplies); result.remove(.deleteReply)
        }
        return result
    }

    public func publish(_ draft: TextPost, credential: SocialCredential) async throws -> SocialPost {
        throw SocialError.unsupported(.publishText)
    }

    public func publishMedia(_ media: SocialMedia, draft: TextPost, credential: SocialCredential) async throws -> SocialPost {
        try await publishSingle(media, draft: draft, credential: credential, checkpoint: nil, save: nil)
    }

    private func publishSingle(
        _ media: SocialMedia, draft: TextPost, credential: SocialCredential,
        checkpoint: MetaPublishingCheckpoint?, save: MetaPublishingCheckpointWriter?
    ) async throws -> SocialPost {
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
        let containerID = try await metaPublishingContainer(checkpoint: checkpoint, draft: draft, save: save) {
            let container: MetaID = try await api.post("/\(accountID)/media", form: form)
            return container.id
        }
        guard try await waitForContainer(containerID, api: api, publishingKey: draft.idempotencyKey) else { throw SocialError.mediaProcessingTimedOut }
        try await beginMetaPublish(containerID, save: save)
        let result: MetaID = try await api.post("/\(accountID)/media_publish", form: [("creation_id", containerID)], key: draft.idempotencyKey)
        let attachment: SocialAttachment
        switch media {
        case .imageURL(let url): attachment = SocialAttachment(kind: .image, url: url)
        case .videoURL(let url): attachment = SocialAttachment(kind: .video, url: url)
        case .imageData: attachment = SocialAttachment(kind: .unknown, url: nil)
        }
        guard (try? metaPathID(result.id)) != nil else { throw SocialError.publishOutcomeUnknown(draft.idempotencyKey) }
        return SocialPost(id: result.id, text: draft.text, media: [attachment])
    }

    /// Publishes an Instagram carousel containing two to ten ordered images and/or videos.
    /// Instagram fetches each source URL directly; this adapter does not download media.
    public func publishMedia(_ media: [SocialMedia], draft: TextPost, credential: SocialCredential) async throws -> SocialPost {
        try await publishAlbumOrSingle(media, draft: draft, credential: credential, checkpoint: nil, save: nil)
    }

    func publishCheckpointed(
        _ media: [SocialMedia], draft: TextPost, credential: SocialCredential,
        checkpoint: MetaPublishingCheckpoint?, save: @escaping MetaPublishingCheckpointWriter
    ) async throws -> SocialPost {
        try await publishAlbumOrSingle(media, draft: draft, credential: credential, checkpoint: checkpoint, save: save)
    }

    private func publishAlbumOrSingle(
        _ media: [SocialMedia], draft: TextPost, credential: SocialCredential,
        checkpoint: MetaPublishingCheckpoint?, save: MetaPublishingCheckpointWriter?
    ) async throws -> SocialPost {
        if media.count == 1, let first = media.first {
            return try await publishSingle(first, draft: draft, credential: credential, checkpoint: checkpoint, save: save)
        }
        guard (2...10).contains(media.count) else { throw SocialError.invalidInput }
        try validate(credential)
        let items = try media.map { item -> (URL, String) in
            switch item {
            case .imageURL(let url):
                try requireHTTPS(url)
                return (url, "IMAGE")
            case .videoURL(let url):
                try requireHTTPS(url)
                return (url, "VIDEO") // Carousel video children use VIDEO; REELS is for standalone reels.
            case .imageData:
                throw SocialError.invalidInput
            }
        }

        let accountID = try metaPathID(credential.account.remoteID)
        let api = try MetaHTTP(transport: transport, origin: origin, accessToken: credential.accessToken)
        let containerID = try await metaPublishingContainer(checkpoint: checkpoint, draft: draft, save: save) {
            var children: [String] = []
            for (url, mediaType) in items {
                let sourceField = mediaType == "IMAGE" ? "image_url" : "video_url"
                let child: MetaID = try await api.post("/\(accountID)/media", form: [
                    (sourceField, url.absoluteString),
                    ("media_type", mediaType),
                    ("is_carousel_item", "true")
                ])
                guard let id = try? metaPathID(child.id) else { throw SocialError.invalidResponse }
                children.append(id)
            }
            for child in children {
                guard try await waitForContainer(child, api: api) else { throw SocialError.mediaProcessingTimedOut }
            }

            var form = [("media_type", "CAROUSEL"), ("children", children.joined(separator: ","))]
            if !draft.text.isEmpty { form.append(("caption", draft.text)) }
            let container: MetaID = try await api.post("/\(accountID)/media", form: form)
            return container.id
        }
        guard try await waitForContainer(containerID, api: api, publishingKey: draft.idempotencyKey) else { throw SocialError.mediaProcessingTimedOut }
        try await beginMetaPublish(containerID, save: save)
        // Publishing is a single, non-retried operation. HTTPClient reports an unknown outcome
        // with the draft key if the request may have reached Meta but no response was confirmed.
        let result: MetaID = try await api.post("/\(accountID)/media_publish", form: [("creation_id", containerID)], key: draft.idempotencyKey)
        let attachments = items.map { url, type in
            SocialAttachment(kind: type == "IMAGE" ? .image : .video, url: url)
        }
        guard (try? metaPathID(result.id)) != nil else { throw SocialError.publishOutcomeUnknown(draft.idempotencyKey) }
        return SocialPost(id: result.id, text: draft.text, media: attachments)
    }

    func wasPublished(_ checkpoint: MetaPublishingCheckpoint, credential: SocialCredential) async throws -> Bool {
        try validate(credential)
        let id = try metaPathID(checkpoint.containerID)
        let api = try MetaHTTP(transport: transport, origin: origin, accessToken: credential.accessToken)
        let status: InstagramContainerStatus = try await api.get("/\(id)", query: [("fields", "id,status_code")])
        guard status.id == id else { throw SocialError.invalidResponse }
        return status.status_code == "PUBLISHED"
    }

    private func waitForContainer(_ id: String, api: MetaHTTP, publishingKey: UUID? = nil) async throws -> Bool {
        let path = "/\(try metaPathID(id))"
        for attempt in 0..<pollAttempts {
            let status: InstagramContainerStatus = try await api.get(path, query: [("fields", "id,status_code,status")])
            guard status.id == id else { throw SocialError.invalidResponse }
            switch status.status_code {
            case "FINISHED": return true
            case "PUBLISHED":
                if let publishingKey { throw SocialError.publishOutcomeUnknown(publishingKey) }
                throw SocialError.invalidResponse
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
        let mediaID = try metaPathID(id)
        let value: InstagramPostRecord = try await api.get("/\(mediaID)", query: [("fields", Self.postFields)])
        let post = value.post
        guard value.media_type?.uppercased() == "CAROUSEL_ALBUM" else { return post }
        let children: InstagramChildrenResponse = try await api.get("/\(mediaID)/children", query: [("fields", "media_type,media_url")])
        return SocialPost(id: post.id, text: post.text, url: post.url, createdAt: post.createdAt,
                          likeCount: post.likeCount, media: children.data.map(\.attachment))
    }

    public func posts(cursor: String?, credential: SocialCredential) async throws -> SocialPage<SocialPost> {
        try validate(credential)
        let api = try MetaHTTP(transport: transport, origin: origin, accessToken: credential.accessToken)
        var query = [("fields", Self.postFields), ("limit", "100")]
        if let cursor { query.append(("after", cursor)) }
        let result: MetaPageResponse<InstagramPostRecord> = try await api.get("/\(try metaPathID(credential.account.remoteID))/media", query: query)
        return SocialPage(items: result.data.map(\.post), nextCursor: result.paging?.next == nil ? nil : result.paging?.cursors?.after)
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
        var query = [("fields", "id,text,username,from,user,timestamp,like_count"), ("limit", "100")]
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

    private static let postFields = "id,caption,username,permalink,timestamp,like_count,media_type,media_url"
}

private struct InstagramProfile: Decodable, Sendable { let id: String?; let user_id: String?; let username: String }
private struct InstagramContainerStatus: Decodable, Sendable { let id: String; let status_code: String }
private struct InstagramRefreshResponse: Decodable, Sendable { let access_token: String; let expires_in: Int }
private struct InstagramChildrenResponse: Decodable, Sendable {
    struct Child: Decodable, Sendable {
        let media_type: String?
        let media_url: URL?
        var attachment: SocialAttachment {
            let kind: SocialAttachment.Kind = media_type?.uppercased() == "IMAGE" ? .image :
                (media_type?.uppercased() == "VIDEO" || media_type?.uppercased() == "REELS" ? .video : .unknown)
            return SocialAttachment(kind: kind, url: media_url)
        }
    }
    let data: [Child]
}
private struct InstagramPostRecord: Decodable, Sendable {
    let id: String
    let caption: String?
    let username: String?
    let permalink: URL?
    let timestamp: String?
    let like_count: Int?
    let media_type: String?
    let media_url: URL?

    var post: SocialPost {
        let kind: SocialAttachment.Kind = media_type?.uppercased() == "IMAGE" ? .image :
            (media_type?.uppercased() == "VIDEO" || media_type?.uppercased() == "REELS" ? .video : .unknown)
        let attachments = media_type == nil ? [] : [SocialAttachment(kind: kind, url: media_url)]
        let createdAt = timestamp.flatMap { ISO8601DateFormatter().date(from: $0) }
        return SocialPost(id: id, text: caption ?? "", url: permalink, createdAt: createdAt,
                          likeCount: like_count, media: attachments, authorHandle: username)
    }
}
