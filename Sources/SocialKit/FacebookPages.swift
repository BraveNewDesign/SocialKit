import Foundation

public struct FacebookPagesAuthorization: Sendable {
    public let clientID: String
    public let redirectURI: URL
    public let pageID: String?
    public let scopes: Set<String>
    public let browser: OAuthBrowser
    public let exchange: any ConfidentialOAuthExchange

    public init(
        clientID: String,
        redirectURI: URL,
        pageID: String? = nil,
        scopes: Set<String> = ["pages_show_list", "pages_manage_posts", "pages_read_engagement", "pages_manage_engagement", "pages_read_user_content"],
        browser: @escaping OAuthBrowser,
        exchange: any ConfidentialOAuthExchange
    ) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.pageID = pageID
        self.scopes = scopes
        self.browser = browser
        self.exchange = exchange
    }
}

/// Direct publishing and comment access for Facebook Pages. Personal profiles are not supported.
/// Graph API v27.0 and the relevant Page flows were checked 2026-11-08:
/// https://developers.facebook.com/docs/pages-api/getting-started
/// https://developers.facebook.com/docs/pages-api/posts
/// https://developers.facebook.com/docs/graph-api/reference/object/comments
/// https://developers.facebook.com/docs/graph-api/reference/object/likes
public struct FacebookPagesAdapter: SocialAdapter {
    public typealias Authorization = FacebookPagesAuthorization
    public let platform: SocialPlatform = .facebookPages
    public let capabilities: Set<SocialCapability> = [
        .publishText, .readPost, .listPosts, .like, .unlike, .reply, .readReplies, .deleteReply
    ]

    private let transport: any HTTPTransport
    private let origin = URL(string: "https://graph.facebook.com/v27.0")!
    private let accountServer = URL(string: "https://graph.facebook.com")!

    public init(transport: any HTTPTransport = URLSessionTransport()) { self.transport = transport }

    public func connect(_ authorization: FacebookPagesAuthorization) async throws -> SocialCredential {
        guard !authorization.clientID.isEmpty, !authorization.scopes.isEmpty else { throw SocialError.invalidConfiguration }
        let transaction = try OAuthTransaction(redirectURI: authorization.redirectURI)
        let authURL = try OAuthForm.queryURL(URL(string: "https://www.facebook.com/v27.0/dialog/oauth")!, parameters: [
            ("client_id", authorization.clientID),
            ("redirect_uri", authorization.redirectURI.absoluteString),
            ("scope", authorization.scopes.sorted().joined(separator: ",")),
            ("response_type", "code"),
            ("state", transaction.state)
        ])
        let callback = try await authorization.browser(authURL, authorization.redirectURI)
        let code = try transaction.code(from: normalizeMetaOAuthCallback(callback, platform: .facebookPages))
        let userToken = try await authorization.exchange.exchange(platform: .facebookPages, code: code, redirectURI: authorization.redirectURI)
        let userAPI = try MetaHTTP(transport: transport, origin: origin, accessToken: userToken.accessToken)
        var cursor: String?
        var eligible: [FacebookPageChoice] = []
        var found: FacebookPageChoice?
        var matchedPage: FacebookPageChoice?
        var completedScan = false
        var seenCursors = Set<String>()
        for _ in 0..<50 {
            var query = [("fields", "id,name,access_token,tasks"), ("limit", "100")]
            if let cursor { query.append(("after", cursor)) }
            let page: MetaPageResponse<FacebookPageChoice> = try await userAPI.get("/me/accounts", query: query)
            if let selectedID = authorization.pageID,
               let result = page.data.first(where: { $0.id == selectedID }) {
                matchedPage = result
                if result.canPublish { found = result; break }
            }
            eligible.append(contentsOf: page.data.filter(\.canPublish))
            guard page.paging?.next != nil, let after = page.paging?.cursors?.after else {
                completedScan = true
                break
            }
            guard seenCursors.insert(after).inserted else { throw SocialError.invalidResponse }
            cursor = after
        }
        let selected: FacebookPageChoice
        if let found { selected = found }
        else if let pageID = authorization.pageID {
            if let matchedPage, matchedPage.id == pageID { throw SocialError.permissionDenied }
            guard completedScan else { throw SocialError.invalidInput }
            throw SocialError.invalidInput
        } else if !completedScan { throw SocialError.invalidInput }
        else if eligible.count == 1 { selected = eligible[0] }
        else if eligible.isEmpty { throw SocialError.permissionDenied }
        else { throw SocialError.invalidInput } // caller must repeat OAuth with a selected pageID.
        guard !selected.access_token.isEmpty else { throw SocialError.invalidResponse }
        let account = SocialAccount(platform: .facebookPages, server: accountServer, remoteID: selected.id,
                                    username: selected.name.isEmpty ? selected.id : selected.name)
        return SocialCredential(account: account, accessToken: selected.access_token,
                                grantedScopes: userToken.grantedScopes ?? authorization.scopes)
    }

    public func capabilities(for credential: SocialCredential) -> Set<SocialCapability> {
        guard let scopes = credential.grantedScopes else { return capabilities }
        var result = capabilities
        if !scopes.contains("pages_manage_posts") { result.remove(.publishText) }
        if !scopes.contains("pages_manage_engagement") { result.remove(.like); result.remove(.unlike) }
        if !scopes.contains("pages_manage_engagement") { result.remove(.reply); result.remove(.deleteReply) }
        if !scopes.contains("pages_read_user_content") || !scopes.contains("pages_read_engagement") { result.remove(.readReplies) }
        if !scopes.contains("pages_read_engagement") { result.remove(.readPost); result.remove(.listPosts) }
        return result
    }

    public func publish(_ draft: TextPost, credential: SocialCredential) async throws -> SocialPost {
        try validate(credential)
        guard !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SocialError.invalidInput }
        let api = try MetaHTTP(transport: transport, origin: origin, accessToken: credential.accessToken)
        let result: MetaID = try await api.post("/\(try metaPathID(credential.account.remoteID))/feed",
                                                form: [("message", draft.text)], key: draft.idempotencyKey)
        return SocialPost(id: result.id, text: draft.text)
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
        let result: MetaPageResponse<MetaPostRecord> = try await api.get("/\(try metaPathID(credential.account.remoteID))/posts", query: query)
        return SocialPage(items: result.data.map(metaPost), nextCursor: result.paging?.next == nil ? nil : result.paging?.cursors?.after)
    }

    public func setLiked(_ liked: Bool, postID: String, credential: SocialCredential) async throws {
        try validate(credential)
        guard capabilities(for: credential).contains(liked ? .like : .unlike) else {
            throw SocialError.permissionDenied
        }
        let api = try MetaHTTP(transport: transport, origin: origin, accessToken: credential.accessToken)
        let path = "/\(try metaPathID(postID))/likes"
        if liked {
            let result: MetaSuccess = try await api.post(path, form: [])
            guard result.success else { throw SocialError.invalidResponse }
        } else {
            try await api.delete(path)
        }
    }

    /// Adds a comment to a Page post. `postID` is the post whose comments are being managed.
    public func reply(_ draft: TextPost, to postID: String, credential: SocialCredential) async throws -> SocialPost {
        try validate(credential)
        guard !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SocialError.invalidInput }
        let api = try MetaHTTP(transport: transport, origin: origin, accessToken: credential.accessToken)
        let result: MetaID = try await api.post("/\(try metaPathID(postID))/comments", form: [("message", draft.text)], key: draft.idempotencyKey)
        return SocialPost(id: result.id, text: draft.text)
    }

    public func replies(to postID: String, cursor: String?, credential: SocialCredential) async throws -> SocialPage<SocialPost> {
        try validate(credential)
        let api = try MetaHTTP(transport: transport, origin: origin, accessToken: credential.accessToken)
        var query = [("fields", "id,message,from,permalink_url,created_time,like_count"), ("limit", "100")]
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
        guard credential.account.platform == .facebookPages, credential.account.server == accountServer,
              !credential.accessToken.isEmpty else { throw SocialError.invalidConfiguration }
    }

    private static let postFields = "id,message,permalink_url,created_time,likes.limit(0).summary(true),attachments{media_type,media,subattachments}"
}

private struct FacebookPageChoice: Decodable, Sendable {
    let id: String
    let name: String
    let access_token: String
    let tasks: [String]?
    var canPublish: Bool { tasks?.contains("CREATE_CONTENT") == true }
}
