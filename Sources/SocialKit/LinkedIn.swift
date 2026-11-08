import Foundation

/// LinkedIn REST adapter for member and organization publishing.
///
/// OAuth code exchange and refresh are delegated to the consuming app's confidential service;
/// this adapter never accepts or stores an app client secret.
public struct LinkedInAdapter: SocialAdapter {
    public struct Authorization: Sendable {
        public let clientID: String
        public let redirectURI: URL
        public let scopes: Set<String>
        public let organizationURN: String?
        public let browser: OAuthBrowser

        public init(
            clientID: String,
            redirectURI: URL,
            scopes: Set<String>? = nil,
            organizationURN: String? = nil,
            browser: @escaping OAuthBrowser
        ) {
            self.clientID = clientID
            self.redirectURI = redirectURI
            self.scopes = scopes ?? (organizationURN == nil
                ? ["openid", "profile", "w_member_social"]
                : ["openid", "profile", "w_organization_social"])
            self.organizationURN = organizationURN
            self.browser = browser
        }
    }

    /// The member is verified through OpenID Connect. When `organizationURN` is supplied, LinkedIn
    /// validates the member's organization role at mutation time; role lookup is not universally
    /// available across LinkedIn app permission tiers.

    public static let currentAPIVersion = "202610"
    public static let apiOrigin = URL(string: "https://api.linkedin.com")!

    public let platform: SocialPlatform = .linkedIn
    public var capabilities: Set<SocialCapability> {
        var supported: Set<SocialCapability> = [
            .publishText, .publishMedia, .readPost, .listPosts, .like, .unlike,
            .reply, .readReplies
        ]
        if oauthBroker != nil { supported.insert(.refreshSession) }
        return supported
    }

    private let transport: any HTTPTransport
    private let apiVersion: String
    private let oauthBroker: (any ConfidentialOAuthExchange)?

    public init(
        transport: any HTTPTransport = URLSessionTransport(),
        apiVersion: String = currentAPIVersion,
        oauthBroker: (any ConfidentialOAuthExchange)? = nil
    ) {
        self.transport = transport
        self.apiVersion = apiVersion
        self.oauthBroker = oauthBroker
    }

    public func capabilities(for credential: SocialCredential) -> Set<SocialCapability> {
        guard credential.account.platform == .linkedIn else { return [] }
        var result = capabilities
        if credential.refreshToken == nil || oauthBroker == nil { result.remove(.refreshSession) }
        guard let scopes = credential.grantedScopes else { return result }
        let authorIsOrganization = credential.account.remoteID.hasPrefix("urn:li:organization:")
        let writeScope = authorIsOrganization ? "w_organization_social" : "w_member_social"
        let readScope = authorIsOrganization ? "r_organization_social" : "r_member_social"
        let feedWriteScope = authorIsOrganization ? "w_organization_social_feed" : "w_member_social_feed"
        let feedReadScope = authorIsOrganization ? "r_organization_social_feed" : "r_member_social_feed"
        if !scopes.contains(writeScope) {
            result.subtract([.publishText, .publishMedia])
        }
        if !scopes.contains(readScope) { result.subtract([.readPost, .listPosts]) }
        if !scopes.contains(feedWriteScope) { result.subtract([.reply, .like, .unlike]) }
        if !scopes.contains(feedReadScope) { result.remove(.readReplies) }
        return result
    }

    public func connect(_ authorization: Authorization) async throws -> SocialCredential {
        guard let oauthBroker, Self.isValidAPIVersion(apiVersion),
              !authorization.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              authorization.scopes.contains("openid"), authorization.scopes.contains("profile"),
              authorization.organizationURN.map(Self.validOrganizationURN) ?? true else {
            throw SocialError.invalidConfiguration
        }
        let transaction = try OAuthTransaction(redirectURI: authorization.redirectURI)
        let scope = authorization.scopes.sorted().joined(separator: " ")
        let authorizationURL = try OAuthForm.queryURL(
            URL(string: "https://www.linkedin.com/oauth/v2/authorization")!,
            parameters: [
                ("response_type", "code"),
                ("client_id", authorization.clientID),
                ("redirect_uri", authorization.redirectURI.absoluteString),
                ("scope", scope),
                ("state", transaction.state)
            ]
        )
        let callback = try await authorization.browser(authorizationURL, authorization.redirectURI)
        let code = try transaction.code(from: callback)
        let token = try await oauthBroker.exchange(
            platform: .linkedIn,
            code: code,
            redirectURI: authorization.redirectURI
        )
        guard !token.accessToken.isEmpty else { throw SocialError.invalidResponse }

        let identity = try await requestJSON(
            Self.endpoint("/v2/userinfo"),
            bearer: token.accessToken,
            versioned: false
        )
        let profile = try Self.decode(UserInfo.self, from: identity.body)
        guard !profile.sub.isEmpty else { throw SocialError.invalidResponse }
        let memberURN = "urn:li:person:\(profile.sub)"
        let author = authorization.organizationURN ?? memberURN
        let granted = token.grantedScopes ?? authorization.scopes
        let credential = SocialCredential(
            account: SocialAccount(
                platform: .linkedIn,
                server: Self.apiOrigin,
                remoteID: author,
                username: profile.name?.isEmpty == false ? profile.name! : profile.sub
            ),
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            expiresAt: token.expiresAt,
            grantedScopes: granted
        )
        // If OAuth returned a scope list, never bind a requested-but-ungranted author.
        if let scopes = token.grantedScopes {
            let needed = authorization.organizationURN == nil ? "w_member_social" : "w_organization_social"
            guard scopes.contains(needed) else { throw SocialError.permissionDenied }
        }
        if let organizationURN = authorization.organizationURN,
           let scopes = credential.grantedScopes,
           scopes.contains("r_organization_admin") || scopes.contains("rw_organization_admin") {
            try await verifyOrganizationRole(
                organizationURN,
                memberURN: memberURN,
                accessToken: credential.accessToken
            )
        }
        // The authorizing member identity was verified; organization eligibility is provider-checked on use.
        return credential
    }

    public func refresh(_ credential: SocialCredential) async throws -> SocialCredential {
        try validate(credential)
        guard credential.refreshToken != nil else { throw SocialError.unsupported(.refreshSession) }
        // Programmatic refresh tokens are issued only to eligible LinkedIn partners. Never assume availability.
        guard let oauthBroker else { throw SocialError.unsupported(.refreshSession) }
        let token = try await oauthBroker.refresh(platform: .linkedIn, token: credential.oauthToken)
        guard !token.accessToken.isEmpty else { throw SocialError.invalidResponse }
        return SocialCredential(
            account: credential.account,
            accessToken: token.accessToken,
            refreshToken: token.refreshToken ?? credential.refreshToken,
            expiresAt: token.expiresAt,
            grantedScopes: token.grantedScopes ?? credential.grantedScopes
        )
    }

    public func publish(_ draft: TextPost, credential: SocialCredential) async throws -> SocialPost {
        try validate(credential)
        try require(.publishText, credential)
        try Self.validateText(draft.text)
        let id = try await createPost(draft, credential: credential, content: nil)
        return SocialPost(id: id, text: draft.text, url: Self.postURL(id), createdAt: .now)
    }

    public func publishMedia(_ media: SocialMedia, draft: TextPost, credential: SocialCredential) async throws -> SocialPost {
        try validate(credential)
        try require(.publishMedia, credential)
        try Self.validateText(draft.text)
        guard case let .imageData(bytes, contentType) = media,
              ["image/jpeg", "image/png", "image/gif"].contains(contentType.lowercased()),
              !bytes.isEmpty, bytes.count <= 20 * 1024 * 1024 else {
            throw SocialError.invalidInput
        }
        let imageURN = try await uploadImage(bytes, contentType: contentType.lowercased(), credential: credential)
        try await verifyImageAvailableIfReadable(imageURN, credential: credential)
        let id = try await createPost(
            draft,
            credential: credential,
            content: ["media": ["id": imageURN]]
        )
        return SocialPost(id: id, text: draft.text, url: Self.postURL(id), createdAt: .now,
                          media: [SocialAttachment(kind: .image, url: nil)])
    }

    public func post(id: String, credential: SocialCredential) async throws -> SocialPost {
        try validate(credential)
        try require(.readPost, credential)
        guard Self.validPostURN(id) else { throw SocialError.invalidInput }
        let response = try await requestJSON(Self.endpoint("/rest/posts/\(Self.pathValue(id))"), bearer: credential.accessToken)
        let post = try Self.decode(LinkedInPost.self, from: response.body)
        guard post.id == id, post.author == credential.account.remoteID else { throw SocialError.invalidResponse }
        return Self.socialPost(post)
    }

    public func posts(cursor: String?, credential: SocialCredential) async throws -> SocialPage<SocialPost> {
        try validate(credential)
        try require(.listPosts, credential)
        let start = try Self.offset(from: cursor)
        let query = [URLQueryItem(name: "q", value: "author"),
                     URLQueryItem(name: "author", value: credential.account.remoteID),
                     URLQueryItem(name: "start", value: String(start)),
                     URLQueryItem(name: "count", value: "25"),
                     URLQueryItem(name: "sortBy", value: "LAST_MODIFIED")]
        let response = try await requestJSON(Self.endpoint("/rest/posts", query: query), bearer: credential.accessToken)
        let page = try Self.decode(PostsResponse.self, from: response.body)
        guard page.elements.allSatisfy({ $0.author == credential.account.remoteID }) else { throw SocialError.invalidResponse }
        let next = page.paging?.nextOffset(after: start, itemCount: page.elements.count)
        return SocialPage(items: page.elements.map(Self.socialPost), nextCursor: next.map(String.init))
    }

    public func reply(_ draft: TextPost, to postID: String, credential: SocialCredential) async throws -> SocialPost {
        try validate(credential)
        try require(.reply, credential)
        try Self.validateComment(draft.text)
        guard Self.validPostURN(postID) else { throw SocialError.invalidInput }
        let body: [String: Any] = [
            "actor": credential.account.remoteID, "message": ["text": draft.text], "object": postID
        ]
        let response = try await requestJSON(
            Self.endpoint("/rest/socialActions/\(Self.pathValue(postID))/comments"),
            method: "POST", bearer: credential.accessToken, body: body, publishingKey: draft.idempotencyKey
        )
        guard let id = (try? Self.decode(CommentResponse.self, from: response.body).commentUrn),
              let parts = Self.commentParts(id), response.header("x-restli-id") == parts.id else {
            throw SocialError.publishOutcomeUnknown(draft.idempotencyKey)
        }
        return SocialPost(id: id, text: draft.text, createdAt: .now)
    }

    public func replies(to postID: String, cursor: String?, credential: SocialCredential) async throws -> SocialPage<SocialPost> {
        try validate(credential)
        try require(.readReplies, credential)
        guard Self.validPostURN(postID) else { throw SocialError.invalidInput }
        let start = try Self.offset(from: cursor)
        let query = [URLQueryItem(name: "start", value: String(start)), URLQueryItem(name: "count", value: "25")]
        let response = try await requestJSON(
            Self.endpoint("/rest/socialActions/\(Self.pathValue(postID))/comments", query: query),
            bearer: credential.accessToken
        )
        let page = try Self.decode(CommentsResponse.self, from: response.body)
        guard page.elements.allSatisfy({ Self.validCommentURN($0.commentUrn) }) else { throw SocialError.invalidResponse }
        let next = page.paging?.nextOffset(after: start, itemCount: page.elements.count)
        return SocialPage(items: page.elements.map(Self.socialPost), nextCursor: next.map(String.init))
    }

    public func setLiked(_ liked: Bool, postID: String, credential: SocialCredential) async throws {
        try validate(credential)
        try require(liked ? .like : .unlike, credential)
        guard Self.validPostURN(postID) else { throw SocialError.invalidInput }
        let actor = credential.account.remoteID
        let entity = postID
        let url = Self.endpoint("/rest/reactions/(actor:\(Self.pathValue(actor)),entity:\(Self.pathValue(entity)))")
        if liked {
            _ = try await requestJSON(
                Self.endpoint("/rest/reactions", query: [URLQueryItem(name: "actor", value: actor)]),
                method: "POST", bearer: credential.accessToken,
                body: ["root": postID, "reactionType": "LIKE"], publishingKey: nil
            )
        } else {
            _ = try await requestJSON(url, method: "DELETE", bearer: credential.accessToken)
        }
    }

    private func createPost(_ draft: TextPost, credential: SocialCredential, content: [String: Any]?) async throws -> String {
        var body: [String: Any] = [
            "author": credential.account.remoteID,
            "commentary": Self.escapeLittleText(draft.text),
            "visibility": "PUBLIC",
            "distribution": ["feedDistribution": "MAIN_FEED", "targetEntities": [], "thirdPartyDistributionChannels": []],
            "lifecycleState": "PUBLISHED",
            "isReshareDisabledByAuthor": false
        ]
        if let content { body["content"] = content }
        let response = try await requestJSON(
            Self.endpoint("/rest/posts"), method: "POST", bearer: credential.accessToken,
            body: body, publishingKey: draft.idempotencyKey
        )
        guard let id = response.header("x-restli-id"), Self.validPostURN(id) else {
            throw SocialError.publishOutcomeUnknown(draft.idempotencyKey)
        }
        return id
    }

    private func uploadImage(_ bytes: Data, contentType: String, credential: SocialCredential) async throws -> String {
        let initialized = try await requestJSON(
            Self.endpoint("/rest/images", query: [URLQueryItem(name: "action", value: "initializeUpload")]), method: "POST", bearer: credential.accessToken,
            body: ["initializeUploadRequest": ["owner": credential.account.remoteID]]
        )
        let upload = try Self.decode(UploadEnvelope.self, from: initialized.body).value
        guard Self.validImageURN(upload.image), let url = URL(string: upload.uploadUrl), Self.validUploadURL(url) else {
            throw SocialError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = bytes
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        _ = try await HTTPClient(transport: transport).send(request)
        return upload.image
    }

    /// Image processing is asynchronous. Read status only when the credential includes the
    /// corresponding approved read scope; member write-only access cannot inspect it reliably.
    private func verifyImageAvailableIfReadable(_ imageURN: String, credential: SocialCredential) async throws {
        let isOrganization = credential.account.remoteID.hasPrefix("urn:li:organization:")
        let readScope = isOrganization ? "w_organization_social" : "r_member_social"
        guard credential.grantedScopes?.contains(readScope) == true else { return }
        for attempt in 0..<5 {
            let response: HTTPResponse
            do {
                response = try await requestJSON(
                    Self.endpoint("/rest/images/\(Self.pathValue(imageURN))"), bearer: credential.accessToken
                )
            } catch SocialError.permissionDenied where credential.account.remoteID.hasPrefix("urn:li:person:") {
                // Member read products are restricted for some apps; proceed with LinkedIn's
                // documented write flow and let post creation report readiness.
                return
            }
            let image = try Self.decode(ImageStatus.self, from: response.body)
            guard image.id == imageURN, image.owner == nil || image.owner == credential.account.remoteID else {
                throw SocialError.invalidResponse
            }
            switch image.status {
            case "AVAILABLE": return
            case "PROCESSING", "WAITING_UPLOAD":
                guard attempt < 4 else { throw SocialError.mediaProcessingTimedOut }
                try await Task.sleep(for: .seconds(1))
            case "PROCESSING_FAILED": throw SocialError.mediaProcessingFailed
            default: throw SocialError.mediaProcessingFailed
            }
        }
        throw SocialError.mediaProcessingTimedOut
    }

    private func verifyOrganizationRole(_ organizationURN: String, memberURN: String, accessToken: String) async throws {
        var start = 0
        for _ in 0..<50 {
            let query = [
                URLQueryItem(name: "q", value: "roleAssignee"),
                URLQueryItem(name: "state", value: "APPROVED"),
                URLQueryItem(name: "start", value: String(start)),
                URLQueryItem(name: "count", value: "100")
            ]
            let response = try await requestJSON(Self.endpoint("/rest/organizationAcls", query: query), bearer: accessToken)
            let result = try Self.decode(OrganizationACLResponse.self, from: response.body)
            if result.elements.contains(where: { acl in
                (acl.organization ?? acl.organizationTarget) == organizationURN &&
                    acl.roleAssignee == memberURN && acl.state == "APPROVED" &&
                    ["ADMINISTRATOR", "DIRECT_SPONSORED_CONTENT_POSTER", "CONTENT_ADMINISTRATOR"].contains(acl.role)
            }) { return }
            guard let next = result.paging?.nextOffset(after: start, itemCount: result.elements.count) else {
                throw SocialError.permissionDenied
            }
            start = next
        }
        throw SocialError.invalidResponse
    }

    private func requestJSON(
        _ url: URL,
        method: String = "GET",
        bearer: String,
        body: [String: Any]? = nil,
        publishingKey: UUID? = nil,
        versioned: Bool = true
    ) async throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if versioned {
            guard Self.isValidAPIVersion(apiVersion) else { throw SocialError.invalidConfiguration }
            request.setValue(apiVersion, forHTTPHeaderField: "Linkedin-Version")
            request.setValue("2.0.0", forHTTPHeaderField: "X-Restli-Protocol-Version")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        return try await HTTPClient(transport: transport).send(
            request,
            publishingKey: publishingKey,
            classifyError: { response in Self.classify(response) }
        )
    }

    private func validate(_ credential: SocialCredential) throws {
        guard credential.account.platform == .linkedIn, credential.account.server == Self.apiOrigin,
              Self.validAuthorURN(credential.account.remoteID) else { throw SocialError.invalidConfiguration }
        guard !credential.accessToken.isEmpty else { throw SocialError.authenticationRequired }
    }

    private func require(_ capability: SocialCapability, _ credential: SocialCredential) throws {
        guard capabilities(for: credential).contains(capability) else { throw SocialError.permissionDenied }
    }

    private static func endpoint(_ path: String, query: [URLQueryItem] = []) -> URL {
        // URNs in path have already been validated and percent-encoded. Setting `path` would
        // encode the percent signs again, so preserve it as `percentEncodedPath`.
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("?") else {
            preconditionFailure("Invalid internal LinkedIn API path")
        }
        var components = URLComponents(url: apiOrigin, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = path
        components.percentEncodedQuery = query.isEmpty
            ? nil
            : String(decoding: OAuthForm.encode(query.map { ($0.name, $0.value ?? "") }), as: UTF8.self)
        return components.url!
    }

    private static func pathValue(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? ""
    }

    private static func validAuthorURN(_ value: String) -> Bool {
        validMemberURN(value) || validOrganizationURN(value)
    }
    private static func validMemberURN(_ value: String) -> Bool {
        value.range(of: #"^urn:li:person:[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
    }
    private static func validOrganizationURN(_ value: String) -> Bool {
        value.range(of: #"^urn:li:organization:[0-9]+$"#, options: .regularExpression) != nil
    }
    private static func validPostURN(_ value: String) -> Bool {
        value.range(of: #"^urn:li:(?:share|ugcPost|activity):[0-9]+$"#, options: .regularExpression) != nil
    }
    private static func validCommentURN(_ value: String) -> Bool { commentParts(value) != nil }
    private static func validImageURN(_ value: String) -> Bool {
        value.range(of: #"^urn:li:image:[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
    }
    private static func validUploadURL(_ url: URL) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return c.scheme?.lowercased() == "https" && c.host?.lowercased() == "www.linkedin.com" &&
            c.port == nil && c.user == nil && c.password == nil && c.fragment == nil &&
            c.path.hasPrefix("/dms-uploads/") && c.query != nil
    }
    private static func offset(from cursor: String?) throws -> Int {
        guard let cursor else { return 0 }
        guard cursor.range(of: #"^(?:0|[1-9][0-9]{0,8})$"#, options: .regularExpression) != nil,
              let value = Int(cursor) else { throw SocialError.invalidInput }
        return value
    }
    private static func validateText(_ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 3000 else { throw SocialError.invalidInput }
    }
    private static func validateComment(_ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 1250 else { throw SocialError.invalidInput }
    }
    private static func escapeLittleText(_ text: String) -> String {
        let reserved = CharacterSet(charactersIn: "|{}@[]()<>#\\*_~")
        return text.unicodeScalars.map { reserved.contains($0) ? "\\" + String($0) : String($0) }.joined()
    }
    private static func postURL(_ urn: String) -> URL? {
        URL(string: "https://www.linkedin.com/feed/update/\(urn)/")
    }
    private static func commentParts(_ value: String) -> (post: String, id: String)? {
        guard let match = value.range(of: #"^urn:li:comment:\((urn:li:(?:activity|share|ugcPost):[0-9]+),([0-9]+)\)$"#, options: .regularExpression) else { return nil }
        let pieces = String(value[match]).dropFirst("urn:li:comment:(".count).dropLast()
        let pair = pieces.split(separator: ",", maxSplits: 1).map(String.init)
        guard pair.count == 2 else { return nil }
        return (pair[0], pair[1])
    }
    private static func socialPost(_ post: LinkedInPost) -> SocialPost {
        SocialPost(id: post.id, text: post.commentary ?? "", url: postURL(post.id),
                   createdAt: post.publishedAt.map { Date(timeIntervalSince1970: $0 / 1_000) }, likeCount: nil)
    }
    private static func socialPost(_ comment: LinkedInComment) -> SocialPost {
        SocialPost(id: comment.commentUrn, text: comment.message.text,
                   createdAt: comment.created.map { Date(timeIntervalSince1970: $0.time / 1_000) })
    }
    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw SocialError.invalidResponse }
    }
    private static func classify(_ response: HTTPResponse) -> SocialError? {
        switch response.statusCode {
        case 402: .billingRequired
        case 403: .permissionDenied
        default: nil
        }
    }

    private static func isValidAPIVersion(_ value: String) -> Bool {
        guard value.utf8.count == 6, value.utf8.allSatisfy({ (48...57).contains($0) }), let month = Int(value.suffix(2)) else { return false }
        return (1...12).contains(month)
    }
}

private struct UserInfo: Decodable { let sub: String; let name: String? }
private struct LinkedInPost: Decodable { let id: String; let author: String; let commentary: String?; let publishedAt: Double? }
private struct PostsResponse: Decodable { let elements: [LinkedInPost]; let paging: Paging? }
private struct Paging: Decodable {
    struct Link: Decodable {
        let rel: String
        let href: String
    }

    let total: Int?
    let count: Int?
    let links: [Link]?

    func nextOffset(after start: Int, itemCount: Int) -> Int? {
        if let href = links?.first(where: { $0.rel == "next" })?.href,
           let value = URLComponents(string: href)?.queryItems?.first(where: { $0.name == "start" })?.value,
           let offset = Int(value), offset > start, offset < 1_000_000_000 {
            return offset
        }
        let step = count ?? itemCount
        guard let total, step > 0, step < 1_000_000_000,
              start + step < total, start + step < 1_000_000_000 else { return nil }
        return start + step
    }
}
private struct UploadEnvelope: Decodable { let value: UploadValue }
private struct UploadValue: Decodable { let uploadUrl: String; let image: String }
private struct ImageStatus: Decodable { let id: String; let owner: String?; let status: String }
private struct CommentResponse: Decodable { let commentUrn: String }
private struct OrganizationACLResponse: Decodable { let elements: [OrganizationACL]; let paging: Paging? }
private struct OrganizationACL: Decodable {
    let organization: String?
    let organizationTarget: String?
    let roleAssignee: String
    let state: String
    let role: String
}
private struct CommentsResponse: Decodable { let elements: [LinkedInComment]; let paging: Paging? }
private struct LinkedInComment: Decodable {
    let commentUrn: String
    let message: CommentMessage
    let created: AuditStamp?
}
private struct CommentMessage: Decodable { let text: String }
private struct AuditStamp: Decodable { let time: Double }
