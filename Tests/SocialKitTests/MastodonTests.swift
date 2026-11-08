import Foundation
import CryptoKit
import Testing
@testable import SocialKit

@Suite("Mastodon adapter")
struct MastodonTests {
    @Test("Authorization registers scopes, requires S256 PKCE, validates state, then verifies the account")
    @MainActor
    func authorizationFlow() async throws {
        let transport = StubTransport([
            metadata(),
            json(#"{"client_id":"client+1","client_secret":"secret-1"}"#),
            json(#"{"access_token":"user-token"}"#),
            json(#"{"id":"42","acct":"alice@example.social"}"#)
        ])
        let adapter = MastodonAdapter(transport: transport)
        let redirect = try #require(URL(string: "socialkit://oauth/callback"))
        var observedAuthorizationURL: URL?
        let credential = try await adapter.connect(.init(
            server: try #require(URL(string: "https://example.social")),
            redirectURI: redirect,
            applicationName: "SocialKit Tests",
            forceLogin: true,
            browser: { authorizationURL, callbackURL in
                observedAuthorizationURL = authorizationURL
                let authorizationComponents = try #require(URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false))
                let state = try #require(authorizationComponents.queryItems?.first(where: { $0.name == "state" })?.value)
                var callback = try #require(URLComponents(url: callbackURL, resolvingAgainstBaseURL: false))
                callback.queryItems = [URLQueryItem(name: "code", value: "auth-code"), URLQueryItem(name: "state", value: state)]
                return try #require(callback.url)
            }
        ))

        #expect(credential.accessToken == "user-token")
        #expect(credential.account.platform == .mastodon)
        #expect(credential.account.server.absoluteString == "https://example.social")
        #expect(credential.account.remoteID == "42")
        #expect(credential.account.username == "alice@example.social")

        let metadataRequest = try #require(transport.requests.first)
        #expect(metadataRequest.httpMethod == "GET")
        #expect(metadataRequest.url?.path == "/.well-known/oauth-authorization-server")

        let registrationRequest = try #require(transport.requests.dropFirst().first)
        #expect(registrationRequest.httpMethod == "POST")
        #expect(registrationRequest.url?.path == "/api/v1/apps")
        let registrationForm = try decodeForm(registrationRequest)
        #expect(registrationForm["redirect_uris"] == redirect.absoluteString)
        #expect(registrationForm["scopes"] == "read:accounts read:statuses write:statuses write:favourites")

        let authURL = try #require(observedAuthorizationURL)
        let authQuery = try #require(URLComponents(url: authURL, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(authQuery.first(where: { $0.name == "code_challenge_method" })?.value == "S256")
        #expect(authQuery.first(where: { $0.name == "client_id" })?.value == "client+1")
        #expect(authURL.absoluteString.contains("client_id=client%2B1"))
        #expect(authQuery.first(where: { $0.name == "force_login" })?.value == "true")
        #expect(authQuery.first(where: { $0.name == "redirect_uri" })?.value == redirect.absoluteString)
        let challenge = try #require(authQuery.first(where: { $0.name == "code_challenge" })?.value)

        let tokenRequest = try #require(transport.requests.dropFirst(2).first)
        let tokenForm = try decodeForm(tokenRequest)
        #expect(tokenForm["code"] == "auth-code")
        #expect(tokenForm["redirect_uri"] == redirect.absoluteString)
        #expect(tokenForm["code_verifier"].map(Self.pkceChallenge) == challenge)

        let verificationRequest = try #require(transport.requests.last)
        #expect(verificationRequest.url?.path == "/api/v1/accounts/verify_credentials")
        #expect(verificationRequest.value(forHTTPHeaderField: "Authorization") == "Bearer user-token")
    }

    @Test("Authorization rejects a callback with mismatched state before token exchange")
    func rejectsMismatchedState() async throws {
        let transport = StubTransport([metadata(), json(#"{"client_id":"client","client_secret":"secret"}"#)])
        let adapter = MastodonAdapter(transport: transport)
        let redirect = try #require(URL(string: "socialkit://oauth/callback"))
        await #expect(throws: SocialError.authorizationFailed) {
            try await adapter.connect(.init(
                server: try #require(URL(string: "https://example.social")),
                redirectURI: redirect,
                browser: { _, callbackURL in
                    var callback = try #require(URLComponents(url: callbackURL, resolvingAgainstBaseURL: false))
                    callback.queryItems = [URLQueryItem(name: "code", value: "auth-code"), URLQueryItem(name: "state", value: "attacker-state")]
                    return try #require(callback.url)
                }
            ))
        }
        #expect(transport.requests.count == 2)
    }

    @Test("Authorization refuses servers that do not advertise S256 PKCE")
    func refusesMissingPKCE() async throws {
        let response = json(#"{"scopes_supported":["read:accounts","read:statuses","write:statuses","write:favourites"],"code_challenge_methods_supported":["plain"]}"#)
        let transport = StubTransport([response])
        let adapter = MastodonAdapter(transport: transport)
        await #expect(throws: SocialError.invalidConfiguration) {
            try await adapter.connect(.init(
                server: try #require(URL(string: "https://example.social")),
                redirectURI: try #require(URL(string: "socialkit://oauth/callback")),
                browser: { _, _ in throw SocialError.authorizationFailed }
            ))
        }
        #expect(transport.requests.count == 1)
        #expect(transport.requests[0].url?.path == "/.well-known/oauth-authorization-server")
    }

    @Test("Authorization rejects duplicate callback code parameters")
    func rejectsDuplicateCallbackCode() async throws {
        let transport = StubTransport([metadata(), json(#"{"client_id":"client","client_secret":"secret"}"#)])
        let adapter = MastodonAdapter(transport: transport)
        let redirect = try #require(URL(string: "socialkit://oauth/callback"))
        await #expect(throws: SocialError.authorizationFailed) {
            try await adapter.connect(.init(
                server: try #require(URL(string: "https://example.social")),
                redirectURI: redirect,
                browser: { authorizationURL, callbackURL in
                    let components = try #require(URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false))
                    let state = try #require(components.queryItems?.first(where: { $0.name == "state" })?.value)
                    var callback = try #require(URLComponents(url: callbackURL, resolvingAgainstBaseURL: false))
                    callback.queryItems = [
                        URLQueryItem(name: "code", value: "first-code"),
                        URLQueryItem(name: "code", value: "second-code"),
                        URLQueryItem(name: "state", value: state)
                    ]
                    return try #require(callback.url)
                }
            ))
        }
        #expect(transport.requests.count == 2)
    }

    @Test("Publishing preserves text, sends the idempotency key, and marks Mastodon content as HTML")
    func publishesText() async throws {
        let transport = StubTransport([json(#"{"id":"status-7","content":"<p>Hello &amp; goodbye</p>","url":"https://example.social/@alice/7","created_at":"2026-11-08T12:34:56.000Z","favourites_count":3}"#)])
        let adapter = MastodonAdapter(transport: transport)
        let credential = makeCredential()
        let key = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let post = try await adapter.publish(TextPost(text: "Hello & goodbye", idempotencyKey: key), credential: credential)

        #expect(post.id == "status-7")
        #expect(post.text == "<p>Hello &amp; goodbye</p>")
        #expect(post.url?.absoluteString == "https://example.social/@alice/7")
        #expect(post.likeCount == 3)
        #expect(post.textFormat == .html)

        let request = try #require(transport.requests.first)
        #expect(request.url?.path == "/api/v1/statuses")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == key.uuidString)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer saved-token")
        #expect(try decodeForm(request)["status"] == "Hello & goodbye")
    }

    @Test("A malformed successful publish response becomes an ambiguous outcome")
    func malformedPublishResponseIsUnknown() async throws {
        let key = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let adapter = MastodonAdapter(transport: StubTransport([HTTPResponse(statusCode: 200, body: Data("{}".utf8))]))
        await #expect(throws: SocialError.publishOutcomeUnknown(key)) {
            try await adapter.publish(TextPost(text: "hello", idempotencyKey: key), credential: makeCredential())
        }
    }

    @Test("Retrieval and like toggles address the escaped local status ID")
    func readsAndLikesPost() async throws {
        let transport = StubTransport([
            json(#"{"id":"local-id_12","content":"<p>Post</p>","url":null,"created_at":null,"favourites_count":0}"#),
            json(#"{}"#),
            json(#"{}"#)
        ])
        let adapter = MastodonAdapter(transport: transport)
        let credential = makeCredential()
        let post = try await adapter.post(id: "local-id_12", credential: credential)
        try await adapter.setLiked(true, postID: "local-id_12", credential: credential)
        try await adapter.setLiked(false, postID: "local-id_12", credential: credential)

        #expect(post.id == "local-id_12")
        #expect(transport.requests[0].url?.path == "/api/v1/statuses/local-id_12")
        #expect(transport.requests[1].url?.path == "/api/v1/statuses/local-id_12/favourite")
        #expect(transport.requests[2].url?.path == "/api/v1/statuses/local-id_12/unfavourite")
    }

    @Test("A credential from another provider is rejected without sending its token")
    func rejectsForeignCredential() async throws {
        let transport = StubTransport([])
        let adapter = MastodonAdapter(transport: transport)
        let credential = SocialCredential(
            account: SocialAccount(
                platform: .bluesky,
                server: URL(string: "https://pds.example")!,
                remoteID: "did:plc:alice",
                username: "alice.example"
            ),
            accessToken: "do-not-send"
        )
        await #expect(throws: SocialError.invalidConfiguration) {
            try await adapter.post(id: "123", credential: credential)
        }
        #expect(transport.requests.isEmpty)
    }

    private func makeCredential() -> SocialCredential {
        SocialCredential(
            account: SocialAccount(
                platform: .mastodon,
                server: URL(string: "https://example.social")!,
                remoteID: "42",
                username: "alice@example.social"
            ),
            accessToken: "saved-token"
        )
    }

    private func json(_ string: String) -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: Data(string.utf8))
    }

    private func metadata() -> HTTPResponse {
        json(#"{"scopes_supported":["read:accounts","read:statuses","write:statuses","write:favourites"],"code_challenge_methods_supported":["S256"]}"#)
    }

    private func decodeForm(_ request: URLRequest) throws -> [String: String] {
        let body = try #require(request.httpBody)
        let encoded = try #require(body.utf8String)
        return Dictionary(uniqueKeysWithValues: encoded.split(separator: "&").compactMap { part in
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return nil }
            let key = String(pair[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding
            let value = String(pair[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding
            guard let key, let value else { return nil }
            return (key, value)
        })
    }

    private static func pkceChallenge(_ verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private final class StubTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [HTTPResponse]
    private var recordedRequests: [URLRequest] = []

    init(_ responses: [HTTPResponse]) { self.responses = responses }

    var requests: [URLRequest] {
        lock.withLock { recordedRequests }
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        guard let response = lock.withLock({ () -> HTTPResponse? in
            recordedRequests.append(request)
            guard !responses.isEmpty else { return nil }
            return responses.removeFirst()
        }) else { throw SocialError.transportFailure }
        return response
    }
}

private extension Data {
    var utf8String: String? { String(data: self, encoding: .utf8) }
}
