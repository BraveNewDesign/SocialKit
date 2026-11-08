import Foundation

/// Mastodon implementation of the provider-neutral social adapter.
public struct MastodonAdapter: SocialAdapter {
    public struct Authorization: Sendable {
        public let server: URL
        public let redirectURI: URL
        public let applicationName: String
        public let website: URL?
        public let forceLogin: Bool
        public let browser: OAuthBrowser

        public init(
            server: URL,
            redirectURI: URL,
            applicationName: String = "SocialKit",
            website: URL? = nil,
            forceLogin: Bool = false,
            browser: @escaping OAuthBrowser
        ) {
            self.server = server
            self.redirectURI = redirectURI
            self.applicationName = applicationName
            self.website = website
            self.forceLogin = forceLogin
            self.browser = browser
        }
    }

    public let platform: SocialPlatform = .mastodon
    public let capabilities: Set<SocialCapability> = [.publishText, .readPost, .like, .unlike]

    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    public func connect(_ authorization: Authorization) async throws -> SocialCredential {
        let origin = try HTTPSOrigin(validating: authorization.server)
        let transaction = try OAuthTransaction(redirectURI: authorization.redirectURI)
        guard !authorization.applicationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SocialError.invalidConfiguration
        }

        let scopes = "read:accounts read:statuses write:statuses write:favourites"
        let metadataResponse = try await requestJSON(origin.endpoint("/.well-known/oauth-authorization-server"))
        let metadata = try Self.decode(OAuthMetadata.self, from: metadataResponse.body)
        guard metadata.codeChallengeMethodsSupported.contains("S256"),
              Set(scopes.split(separator: " ").map(String.init)).isSubset(of: Set(metadata.scopesSupported)) else {
            throw SocialError.invalidConfiguration
        }

        var registrationForm = [
            ("client_name", authorization.applicationName),
            ("redirect_uris", authorization.redirectURI.absoluteString),
            ("scopes", scopes)
        ]
        if let website = authorization.website {
            registrationForm.append(("website", website.absoluteString))
        }
        let registration = try await requestJSON(
            origin.endpoint("/api/v1/apps"),
            method: "POST",
            form: registrationForm
        )
        let app = try Self.decode(Application.self, from: registration.body)
        guard !app.clientID.isEmpty, !app.clientSecret.isEmpty else {
            throw SocialError.invalidResponse
        }

        let authorizationURL = try OAuthForm.queryURL(origin.endpoint("/oauth/authorize"), parameters: [
            ("response_type", "code"),
            ("client_id", app.clientID),
            ("redirect_uri", authorization.redirectURI.absoluteString),
            ("scope", scopes),
            ("state", transaction.state),
            ("code_challenge", transaction.challenge),
            ("code_challenge_method", "S256"),
            ("force_login", authorization.forceLogin ? "true" : "false")
        ])
        let callback = try await authorization.browser(authorizationURL, authorization.redirectURI)
        let code = try transaction.code(from: callback, allowsExtraParameters: false)

        let tokenResponse = try await requestJSON(
            origin.endpoint("/oauth/token"),
            method: "POST",
            form: [
                ("grant_type", "authorization_code"),
                ("code", code),
                ("client_id", app.clientID),
                ("client_secret", app.clientSecret),
                ("redirect_uri", authorization.redirectURI.absoluteString),
                ("code_verifier", transaction.verifier)
            ]
        )
        let token = try Self.decode(Token.self, from: tokenResponse.body)
        guard !token.accessToken.isEmpty else { throw SocialError.invalidResponse }

        let accountResponse = try await requestJSON(
            origin.endpoint("/api/v1/accounts/verify_credentials"),
            bearer: token.accessToken
        )
        let account = try Self.decode(Account.self, from: accountResponse.body)
        guard !account.id.isEmpty, !account.acct.isEmpty else { throw SocialError.invalidResponse }
        return SocialCredential(
            account: SocialAccount(
                platform: .mastodon,
                server: origin.url,
                remoteID: account.id,
                username: account.acct
            ),
            accessToken: token.accessToken
        )
    }

    public func publish(_ draft: TextPost, credential: SocialCredential) async throws -> SocialPost {
        let origin = try Self.origin(for: credential)
        guard !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SocialError.invalidInput
        }
        let endpoint = try origin.endpoint("/api/v1/statuses")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(draft.idempotencyKey.uuidString, forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = OAuthForm.encode([("status", draft.text)])

        let response = try await HTTPClient(transport: transport).send(request, publishingKey: draft.idempotencyKey)
        do {
            let status = try Self.decode(Status.self, from: response.body)
            guard !status.id.isEmpty else { throw SocialError.invalidResponse }
            return Self.post(status)
        } catch {
            throw SocialError.publishOutcomeUnknown(draft.idempotencyKey)
        }
    }

    public func post(id: String, credential: SocialCredential) async throws -> SocialPost {
        let origin = try Self.origin(for: credential)
        let response = try await requestJSON(
            origin.endpoint("/api/v1/statuses/\(try Self.pathComponent(id))"),
            bearer: credential.accessToken
        )
        let status = try Self.decode(Status.self, from: response.body)
        guard status.id == id else { throw SocialError.invalidResponse }
        return Self.post(status)
    }

    public func setLiked(_ liked: Bool, postID: String, credential: SocialCredential) async throws {
        let origin = try Self.origin(for: credential)
        let action = liked ? "favourite" : "unfavourite"
        _ = try await requestJSON(
            origin.endpoint("/api/v1/statuses/\(try Self.pathComponent(postID))/\(action)"),
            method: "POST",
            bearer: credential.accessToken
        )
    }

    private func requestJSON(
        _ url: URL,
        method: String = "GET",
        bearer: String? = nil,
        form: [(String, String)]? = nil
    ) async throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let form {
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = OAuthForm.encode(form)
        }
        return try await HTTPClient(transport: transport).send(request)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder.mastodon.decode(type, from: data) }
        catch { throw SocialError.invalidResponse }
    }

    private static func post(_ status: Status) -> SocialPost {
        SocialPost(
            id: status.id,
            text: status.content,
            url: status.url.flatMap(URL.init(string:)),
            createdAt: status.createdAt,
            likeCount: status.favouritesCount,
            textFormat: .html
        )
    }

    private static func origin(for credential: SocialCredential) throws -> HTTPSOrigin {
        guard credential.account.platform == .mastodon else { throw SocialError.invalidConfiguration }
        guard !credential.accessToken.isEmpty else { throw SocialError.authenticationRequired }
        return try HTTPSOrigin(validating: credential.account.server)
    }

    private static func pathComponent(_ value: String) throws -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard !value.isEmpty, value.unicodeScalars.allSatisfy(allowed.contains), value != ".", value != ".." else {
            throw SocialError.invalidInput
        }
        return value
    }

    private struct Application: Decodable {
        let clientID: String
        let clientSecret: String
        enum CodingKeys: String, CodingKey { case clientID = "client_id", clientSecret = "client_secret" }
    }

    private struct OAuthMetadata: Decodable {
        let scopesSupported: [String]
        let codeChallengeMethodsSupported: [String]
        enum CodingKeys: String, CodingKey {
            case scopesSupported = "scopes_supported"
            case codeChallengeMethodsSupported = "code_challenge_methods_supported"
        }
    }

    private struct Token: Decodable {
        let accessToken: String
        enum CodingKeys: String, CodingKey { case accessToken = "access_token" }
    }

    private struct Account: Decodable { let id: String; let acct: String }

    private struct Status: Decodable {
        let id: String
        let content: String
        let url: String?
        let createdAt: Date?
        let favouritesCount: Int?
        enum CodingKeys: String, CodingKey {
            case id, content, url
            case createdAt = "created_at"
            case favouritesCount = "favourites_count"
        }
    }
}

private extension JSONDecoder {
    static var mastodon: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid Mastodon timestamp")
        }
        return decoder
    }
}
