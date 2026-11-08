import Foundation
import SocialKit

/// Exchanges Meta authorization codes through a first-party HTTPS service.
/// The Meta app secret must remain on that service.
public final class MetaValidationOAuthBridge: ConfidentialOAuthExchange, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    private let endpoint: URL
    private let bearerToken: String
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// `endpoint` is the HTTPS base URL of the trusted bridge, for example
    /// `https://oauth.example.com/meta`. Its origin is fixed for this instance.
    public convenience init(endpoint: URL, bearerToken: String) throws {
        try self.init(endpoint: endpoint, bearerToken: bearerToken, configuration: .ephemeral)
    }

    /// Internal injection point for deterministic URLProtocol tests.
    init(endpoint: URL, bearerToken: String, configuration: URLSessionConfiguration) throws {
        guard Self.isValidEndpoint(endpoint), Self.isValidBearerToken(bearerToken) else { throw SocialError.invalidConfiguration }
        self.endpoint = endpoint
        self.bearerToken = bearerToken
        guard let safeConfiguration = configuration.copy() as? URLSessionConfiguration else {
            throw SocialError.invalidConfiguration
        }
        safeConfiguration.httpCookieStorage = nil
        safeConfiguration.httpShouldSetCookies = false
        safeConfiguration.urlCache = nil
        safeConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        safeConfiguration.urlCredentialStorage = nil
        self.session = URLSession(configuration: safeConfiguration, delegate: NoRedirectDelegate(), delegateQueue: nil)
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions.insert(.withFractionalSeconds)
            guard let date = formatter.date(from: value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date")
            }
            return date
        }
    }

    public var description: String { "MetaValidationOAuthBridge(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }

    public func exchange(platform: SocialPlatform, code: String, redirectURI: URL) async throws -> OAuthToken {
        try Task.checkCancellation()
        guard !code.isEmpty, Self.isValidRedirect(redirectURI) else { throw SocialError.authorizationFailed }
        let payload = ExchangeRequest(platform: platform.rawValue, code: code, redirectURI: redirectURI.absoluteString)
        do {
            let token: TokenResponse = try await post("exchange", payload: payload)
            try Task.checkCancellation()
            guard !token.accessToken.isEmpty else { throw SocialError.authorizationFailed }
            return token.token
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw SocialError.authorizationFailed
        }
    }

    public func refresh(platform: SocialPlatform, token: OAuthToken) async throws -> OAuthToken {
        try Task.checkCancellation()
        guard let refreshToken = token.refreshToken, !refreshToken.isEmpty else {
            throw SocialError.unsupported(.refreshSession)
        }
        do {
            let response: TokenResponse = try await post("refresh", payload: RefreshRequest(
                platform: platform.rawValue,
                refreshToken: refreshToken
            ))
            try Task.checkCancellation()
            guard !response.accessToken.isEmpty else { throw SocialError.authorizationFailed }
            return response.token
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw SocialError.authorizationFailed
        }
    }

    private func post<Payload: Encodable, Response: Decodable>(_ operation: String, payload: Payload) async throws -> Response {
        let url = endpoint.appendingPathComponent("oauth", isDirectory: true).appendingPathComponent(operation)
        guard Self.hasSameOrigin(url, endpoint) else { throw SocialError.authorizationFailed }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try encoder.encode(payload)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              response.url.map({ Self.hasSameOrigin($0, endpoint) }) == true,
              data.count <= 64 * 1024 else { throw SocialError.authorizationFailed }
        return try decoder.decode(Response.self, from: data)
    }

    private static func isValidEndpoint(_ url: URL) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme?.lowercased() == "https", c.host?.isEmpty == false,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.port == nil || c.port == 443 else { return false }
        return true
    }

    private static func isValidRedirect(_ url: URL) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme?.lowercased() == "https", c.host?.isEmpty == false,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil else { return false }
        return true
    }

    private static func isValidBearerToken(_ token: String) -> Bool {
        let invalidCharacters = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        return !token.isEmpty && !token.unicodeScalars.contains(where: invalidCharacters.contains)
    }

    private static func hasSameOrigin(_ a: URL, _ b: URL) -> Bool {
        guard let x = URLComponents(url: a, resolvingAgainstBaseURL: false),
              let y = URLComponents(url: b, resolvingAgainstBaseURL: false) else { return false }
        return x.scheme?.lowercased() == "https" &&
            x.scheme?.lowercased() == y.scheme?.lowercased() &&
            x.host?.lowercased() == y.host?.lowercased() &&
            (x.port ?? 443) == (y.port ?? 443) && x.user == nil && x.password == nil
    }

    private struct ExchangeRequest: Encodable {
        let platform: String
        let code: String
        let redirectURI: String
        enum CodingKeys: String, CodingKey { case platform, code; case redirectURI = "redirect_uri" }
    }
    private struct RefreshRequest: Encodable {
        let platform: String
        let refreshToken: String
        enum CodingKeys: String, CodingKey { case platform; case refreshToken = "refresh_token" }
    }
    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date?
        let grantedScopes: Set<String>?
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token", refreshToken = "refresh_token"
            case expiresAt = "expires_at", grantedScopes = "granted_scopes"
        }
        var token: OAuthToken { OAuthToken(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt, grantedScopes: grantedScopes) }
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
