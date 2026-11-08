import CryptoKit
import Foundation

public typealias OAuthBrowser = @MainActor @Sendable (URL, URL) async throws -> URL

public struct OAuthToken: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let grantedScopes: Set<String>?

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        grantedScopes: Set<String>? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.grantedScopes = grantedScopes
    }

    public var description: String { "OAuthToken(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

/// Bridge to the consuming app's trusted service. Confidential secrets belong on that service.
public protocol ConfidentialOAuthExchange: Sendable {
    func exchange(platform: SocialPlatform, code: String, redirectURI: URL) async throws -> OAuthToken
    func refresh(platform: SocialPlatform, token: OAuthToken) async throws -> OAuthToken
}

public extension ConfidentialOAuthExchange {
    func refresh(platform: SocialPlatform, token: OAuthToken) async throws -> OAuthToken {
        throw SocialError.unsupported(.refreshSession)
    }
}

struct OAuthTransaction: Sendable {
    let state = Self.randomString()
    let verifier = Self.randomString()
    let redirectURI: URL

    var challenge: String {
        Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    init(redirectURI: URL) throws {
        guard let components = URLComponents(url: redirectURI, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              !["http", "file", "data", "javascript", "about", "ftp", "blob"].contains(scheme),
              components.host?.isEmpty == false || !components.path.isEmpty,
              scheme != "https" || components.host?.isEmpty == false,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw SocialError.invalidConfiguration
        }
        self.redirectURI = redirectURI
    }

    func code(from callback: URL, allowsExtraParameters: Bool = true) throws -> String {
        try Task.checkCancellation()
        guard var actual = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              actual.fragment == nil,
              let query = actual.queryItems,
              allowsExtraParameters || query.count == 2 else {
            throw SocialError.authorizationFailed
        }
        actual.query = nil
        guard actual.url?.absoluteString == redirectURI.absoluteString,
              !query.contains(where: { $0.name == "error" }),
              query.filter({ $0.name == "state" }).count == 1,
              query.filter({ $0.name == "code" }).count == 1,
              query.first(where: { $0.name == "state" })?.value == state,
              let code = query.first(where: { $0.name == "code" })?.value,
              !code.isEmpty else {
            throw SocialError.authorizationFailed
        }
        return code
    }

    private static func randomString() -> String {
        base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum OAuthForm {
    static func encode(_ values: [(String, String)]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let fields = values.map { name, value in
            // The ASCII allowlist makes UTF-8 percent encoding total.
            let key = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(key)=\(encodedValue)"
        }
        return Data(fields.joined(separator: "&").utf8)
    }

    static func queryURL(_ url: URL, parameters: [(String, String)]) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.percentEncodedQuery == nil else { throw SocialError.invalidConfiguration }
        components.percentEncodedQuery = String(decoding: encode(parameters), as: UTF8.self)
        guard let url = components.url else { throw SocialError.invalidConfiguration }
        return url
    }
}
