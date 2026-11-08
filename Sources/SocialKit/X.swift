import Foundation

/// X API v2 adapter using a native public-client OAuth 2.0 PKCE flow.
/// No client secret is accepted or embedded in this adapter.
public struct XAdapter: SocialAdapter {
    public struct Authorization: Sendable {
        public let redirectURI: URL
        public let browser: OAuthBrowser

        public init(redirectURI: URL, browser: @escaping OAuthBrowser) {
            self.redirectURI = redirectURI
            self.browser = browser
        }
    }

    public let platform: SocialPlatform = .x
    public let capabilities: Set<SocialCapability> = [
        .publishText, .readPost, .listPosts, .reply, .readReplies, .deleteReply,
        .like, .unlike, .repost, .unrepost, .refreshSession
    ]

    private let transport: any HTTPTransport
    private let clientID: String

    public init(clientID: String, transport: any HTTPTransport = URLSessionTransport()) {
        self.clientID = clientID
        self.transport = transport
    }

    public func connect(_ authorization: Authorization) async throws -> SocialCredential {
        guard !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SocialError.invalidConfiguration
        }
        let transaction = try OAuthTransaction(redirectURI: authorization.redirectURI)
        let authURL = try OAuthForm.queryURL(URL(string: "https://x.com/i/oauth2/authorize")!, parameters: [
            ("response_type", "code"),
            ("client_id", clientID),
            ("redirect_uri", authorization.redirectURI.absoluteString),
            ("scope", Self.scopes.joined(separator: " ")),
            ("state", transaction.state),
            ("code_challenge", transaction.challenge),
            ("code_challenge_method", "S256")
        ])
        let callback = try await authorization.browser(authURL, authorization.redirectURI)
        let code = try transaction.code(from: callback)
        let tokenResponse = try await requestJSON(
            URL(string: "https://api.x.com/2/oauth2/token")!,
            method: "POST",
            form: [
                ("grant_type", "authorization_code"),
                ("code", code),
                ("redirect_uri", authorization.redirectURI.absoluteString),
                ("code_verifier", transaction.verifier),
                ("client_id", clientID)
            ]
        )
        let token = try Self.decode(Token.self, from: tokenResponse.body)
        guard !token.accessToken.isEmpty, token.expiresIn > 0 else { throw SocialError.invalidResponse }
        let meResponse = try await requestJSON(
            URL(string: "https://api.x.com/2/users/me?user.fields=username")!,
            bearer: token.accessToken
        )
        let me = try Self.decode(UserEnvelope.self, from: meResponse.body).data
        guard !me.id.isEmpty, !me.username.isEmpty else { throw SocialError.invalidResponse }
        return SocialCredential(
            account: SocialAccount(
                platform: .x,
                server: Self.apiOrigin,
                remoteID: me.id,
                username: me.username
            ),
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            expiresAt: Date.now.addingTimeInterval(TimeInterval(token.expiresIn)),
            grantedScopes: token.scope.map { Set(Self.parseScopes($0)) } ?? Set(Self.scopes)
        )
    }

    public func refresh(_ credential: SocialCredential) async throws -> SocialCredential {
        try Self.validate(credential)
        guard let refreshToken = credential.refreshToken, !refreshToken.isEmpty else {
            throw SocialError.authenticationRequired
        }
        // X's public-client refresh grant also requires the app's public client ID.
        guard !clientID.isEmpty else {
            throw SocialError.invalidConfiguration
        }
        let response = try await requestJSON(
            URL(string: "https://api.x.com/2/oauth2/token")!,
            method: "POST",
            form: [
                ("grant_type", "refresh_token"),
                ("refresh_token", refreshToken),
                ("client_id", clientID)
            ]
        )
        let token = try Self.decode(Token.self, from: response.body)
        guard !token.accessToken.isEmpty, token.expiresIn > 0 else { throw SocialError.invalidResponse }
        return SocialCredential(
            account: credential.account,
            accessToken: token.accessToken,
            refreshToken: token.refreshToken ?? refreshToken,
            expiresAt: Date.now.addingTimeInterval(TimeInterval(token.expiresIn)),
            grantedScopes: token.scope.map { Set(Self.parseScopes($0)) } ?? credential.grantedScopes
        )
    }

    public func publish(_ draft: TextPost, credential: SocialCredential) async throws -> SocialPost {
        try await createPost(draft, replyTo: nil, credential: credential)
    }

    public func reply(_ draft: TextPost, to postID: String, credential: SocialCredential) async throws -> SocialPost {
        guard Self.validPostID(postID) else { throw SocialError.invalidInput }
        return try await createPost(draft, replyTo: postID, credential: credential)
    }

    private func createPost(_ draft: TextPost, replyTo postID: String?, credential: SocialCredential) async throws -> SocialPost {
        try Self.validate(credential)
        guard !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SocialError.invalidInput
        }
        var payload: [String: Any] = ["text": draft.text]
        if let postID { payload["reply"] = ["in_reply_to_tweet_id": postID] }
        let response = try await requestJSON(
            Self.apiEndpoint("/2/tweets"), method: "POST", bearer: credential.accessToken,
            json: payload, publishingKey: draft.idempotencyKey
        )
        guard let created = try? Self.decode(PostEnvelope.self, from: response.body).data,
              Self.validPostID(created.id) else {
            throw SocialError.publishOutcomeUnknown(draft.idempotencyKey)
        }
        return Self.post(created)
    }

    public func post(id: String, credential: SocialCredential) async throws -> SocialPost {
        try Self.validate(credential)
        guard Self.validPostID(id) else { throw SocialError.invalidInput }
        let url = try OAuthForm.queryURL(Self.apiEndpoint("/2/tweets/\(id)"), parameters: [
            ("tweet.fields", "created_at,public_metrics")
        ])
        let response = try await requestJSON(url, bearer: credential.accessToken)
        let result = try Self.decode(PostEnvelope.self, from: response.body)
        guard result.data.id == id else { throw SocialError.invalidResponse }
        return Self.post(result.data)
    }

    public func posts(cursor: String? = nil, credential: SocialCredential) async throws -> SocialPage<SocialPost> {
        try Self.validate(credential)
        var parameters = [("max_results", "100"), ("tweet.fields", "created_at,public_metrics")]
        if let cursor { parameters.append(("pagination_token", cursor)) }
        let url = try OAuthForm.queryURL(Self.apiEndpoint("/2/users/\(credential.account.remoteID)/tweets"), parameters: parameters)
        let response = try await requestJSON(url, bearer: credential.accessToken)
        let result = try Self.decode(PostPageEnvelope.self, from: response.body)
        guard let posts = result.data ?? (result.meta?.resultCount == 0 ? [] : nil) else { throw SocialError.invalidResponse }
        return SocialPage(items: posts.map(Self.post), nextCursor: result.meta?.nextToken)
    }

    /// Finds replies through recent search. X only searches the last seven days;
    /// older conversation history is unavailable through this endpoint.
    /// Searches for replies in the last seven days. Pass the conversation root post ID.
    public func replies(to postID: String, cursor: String? = nil, credential: SocialCredential) async throws -> SocialPage<SocialPost> {
        try Self.validate(credential)
        guard Self.validPostID(postID) else { throw SocialError.invalidInput }
        var parameters = [("query", "conversation_id:\(postID) is:reply"), ("max_results", "100"), ("tweet.fields", "created_at,public_metrics")]
        if let cursor { parameters.append(("next_token", cursor)) }
        let url = try OAuthForm.queryURL(Self.apiEndpoint("/2/tweets/search/recent"), parameters: parameters)
        let response = try await requestJSON(url, bearer: credential.accessToken)
        let result = try Self.decode(PostPageEnvelope.self, from: response.body)
        guard let posts = result.data ?? (result.meta?.resultCount == 0 ? [] : nil) else { throw SocialError.invalidResponse }
        return SocialPage(items: posts.map(Self.post), nextCursor: result.meta?.nextToken)
    }

    public func deleteReply(id: String, credential: SocialCredential) async throws {
        try Self.validate(credential)
        guard Self.validPostID(id) else { throw SocialError.invalidInput }
        let response = try await requestJSON(
            Self.apiEndpoint("/2/tweets/\(id)"), method: "DELETE", bearer: credential.accessToken
        )
        guard try Self.decode(ActionEnvelope.self, from: response.body).data.deleted == true else {
            throw SocialError.invalidResponse
        }
    }

    public func setLiked(_ liked: Bool, postID: String, credential: SocialCredential) async throws {
        let result = try await setEngagement(liked, postID: postID, action: "likes", credential: credential)
        guard result.liked == liked else { throw SocialError.invalidResponse }
    }

    public func setReposted(_ reposted: Bool, postID: String, credential: SocialCredential) async throws {
        let result = try await setEngagement(reposted, postID: postID, action: "retweets", credential: credential)
        guard result.retweeted == reposted else { throw SocialError.invalidResponse }
    }

    private func setEngagement(
        _ enabled: Bool, postID: String, action: String, credential: SocialCredential
    ) async throws -> ActionResult {
        try Self.validate(credential)
        guard Self.validPostID(postID) else { throw SocialError.invalidInput }
        let path = "/2/users/\(credential.account.remoteID)/\(action)"
        let response = try await requestJSON(
            Self.apiEndpoint(enabled ? path : path + "/" + postID),
            method: enabled ? "POST" : "DELETE", bearer: credential.accessToken,
            json: enabled ? ["tweet_id": postID] : nil
        )
        return try Self.decode(ActionEnvelope.self, from: response.body).data
    }

    private func requestJSON(
        _ url: URL,
        method: String = "GET",
        bearer: String? = nil,
        json: [String: Any]? = nil,
        form: [(String, String)]? = nil,
        publishingKey: UUID? = nil
    ) async throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do { request.httpBody = try JSONSerialization.data(withJSONObject: json) }
            catch { throw SocialError.invalidInput }
        }
        if let form {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = OAuthForm.encode(form)
        }
        let isTokenEndpoint = url.path == "/2/oauth2/token"
        return try await HTTPClient(transport: transport).send(
            request, publishingKey: publishingKey,
            authenticationErrorCodes: isTokenEndpoint ? ["invalid_grant"] : [],
            classifyError: { response in
                if response.statusCode == 402 { return .billingRequired }
                if response.statusCode == 403 { return .permissionDenied }
                if response.statusCode == 429 {
                    let retry = response.header("Retry-After") ?? Self.resetDate(response.header("x-rate-limit-reset"))
                    return .rateLimited(retryAfter: retry)
                }
                return nil
            }
        )
    }

    private static func resetDate(_ value: String?) -> String? {
        guard let value, let seconds = Int64(value), (0...253_402_300_799).contains(seconds) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    private static let scopes = ["tweet.read", "users.read", "tweet.write", "like.write", "offline.access"]
    private static let apiOrigin = URL(string: "https://api.x.com")!

    private static func apiEndpoint(_ path: String) -> URL { URL(string: path, relativeTo: apiOrigin)!.absoluteURL }

    private static func validate(_ credential: SocialCredential) throws {
        guard credential.account.platform == .x, credential.account.server == apiOrigin else {
            throw SocialError.invalidConfiguration
        }
        guard !credential.accessToken.isEmpty, validPostID(credential.account.remoteID) else {
            throw SocialError.authenticationRequired
        }
    }

    private static func validPostID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 19 && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func parseScopes(_ value: String) -> [String] {
        value.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    public func capabilities(for credential: SocialCredential) -> Set<SocialCapability> {
        guard credential.account.platform == .x else { return [] }
        let scopes = credential.grantedScopes ?? Set(Self.scopes)
        var available: Set<SocialCapability> = []
        let canWrite = scopes.isSuperset(of: ["tweet.read", "tweet.write", "users.read"])
        let canLike = scopes.isSuperset(of: ["like.write", "tweet.read", "users.read"])
        if canWrite {
            available.formUnion([.publishText, .reply, .deleteReply, .repost, .unrepost])
        }
        if scopes.contains("tweet.read") {
            available.formUnion([.readPost, .readReplies])
            if scopes.contains("users.read") { available.insert(.listPosts) }
        }
        if canLike { available.formUnion([.like, .unlike]) }
        if scopes.contains("offline.access"), let refreshToken = credential.refreshToken, !refreshToken.isEmpty {
            available.insert(.refreshSession)
        }
        return available
    }

    private static func post(_ value: PostRecord) -> SocialPost {
        SocialPost(id: value.id, text: value.text, url: URL(string: "https://x.com/i/web/status/\(value.id)"),
                   createdAt: value.createdAt, likeCount: value.publicMetrics?.likeCount)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder.x.decode(type, from: data) }
        catch { throw SocialError.invalidResponse }
    }

    private struct Token: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int
        let scope: String?
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in", scope
        }
    }
    private struct UserEnvelope: Decodable { let data: User }
    private struct User: Decodable { let id: String; let username: String }
    private struct ActionEnvelope: Decodable { let data: ActionResult }
    private struct ActionResult: Decodable {
        let liked: Bool?
        let retweeted: Bool?
        let deleted: Bool?
    }
    private struct PostEnvelope: Decodable { let data: PostRecord }
    private struct PostPageEnvelope: Decodable { let data: [PostRecord]?; let meta: Meta? }
    private struct Meta: Decodable {
        let nextToken: String?
        let resultCount: Int?
        enum CodingKeys: String, CodingKey { case nextToken = "next_token", resultCount = "result_count" }
    }
    private struct PostRecord: Decodable {
        let id: String
        let text: String
        let createdAt: Date?
        let publicMetrics: PublicMetrics?
        enum CodingKeys: String, CodingKey { case id, text, createdAt = "created_at", publicMetrics = "public_metrics" }
    }
    private struct PublicMetrics: Decodable {
        let likeCount: Int?
        enum CodingKeys: String, CodingKey { case likeCount = "like_count" }
    }
}

private extension JSONDecoder {
    static var x: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = standard.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid X timestamp")
        }
        return decoder
    }
}
