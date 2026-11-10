import CryptoKit
import Foundation
import Testing
@testable import SocialKit

@Suite("X adapter")
struct XTests {
    private let redirect = URL(string: "socialkit://oauth/callback")!

    @Test("Connect uses public OAuth PKCE, strict callback state, and verifies user identity")
    @MainActor
    func connectsWithPKCE() async throws {
        let transport = XStubTransport([
            json(#"{"access_token":"access","refresh_token":"refresh","expires_in":7200,"scope":"tweet.read users.read tweet.write like.write offline.access"}"#),
            json(#"{"data":{"id":"12345","username":"alice"}}"#)
        ])
        let adapter = XAdapter(clientID: "public-client-id", transport: transport)
        var authURL: URL?
        let credential = try await adapter.connect(.init(redirectURI: redirect) { url, callbackURL in
            authURL = url
            let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            var callback = try #require(URLComponents(url: callbackURL, resolvingAgainstBaseURL: false))
            callback.queryItems = [
                URLQueryItem(name: "code", value: "mock-code"),
                URLQueryItem(name: "state", value: try #require(query.first(where: { $0.name == "state" })?.value))
            ]
            return try #require(callback.url)
        })

        #expect(credential.account.platform == .x)
        #expect(credential.account.remoteID == "12345")
        #expect(credential.account.username == "alice")
        #expect(credential.accessToken == "access")
        #expect(credential.refreshToken == "refresh")
        #expect(credential.grantedScopes == ["tweet.read", "users.read", "tweet.write", "like.write", "offline.access"])
        let authorization = try #require(authURL)
        #expect(authorization.host == "x.com")
        #expect(authorization.path == "/i/oauth2/authorize")
        let parameters = try #require(URLComponents(url: authorization, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(parameters.first(where: { $0.name == "client_id" })?.value == "public-client-id")
        #expect(parameters.first(where: { $0.name == "code_challenge_method" })?.value == "S256")
        let challenge = try #require(parameters.first(where: { $0.name == "code_challenge" })?.value)
        let tokenForm = try decodeForm(try #require(transport.requests.first))
        #expect(tokenForm["client_id"] == "public-client-id")
        #expect(tokenForm["code"] == "mock-code")
        #expect(tokenForm["code_verifier"].map(Self.challenge) == challenge)
        #expect(transport.requests[1].url?.absoluteString == "https://api.x.com/2/users/me?user.fields=username,name")
        #expect(transport.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer access")
    }

    @Test("OAuth callback state mismatch prevents token exchange")
    @MainActor
    func rejectsStateMismatch() async throws {
        let transport = XStubTransport([])
        let adapter = XAdapter(clientID: "client", transport: transport)
        await #expect(throws: SocialError.authorizationFailed) {
            try await adapter.connect(.init(redirectURI: redirect) { _, callbackURL in
                var callback = try #require(URLComponents(url: callbackURL, resolvingAgainstBaseURL: false))
                callback.queryItems = [URLQueryItem(name: "code", value: "code"), URLQueryItem(name: "state", value: "bad")]
                return try #require(callback.url)
            })
        }
        #expect(transport.requests.isEmpty)
    }

    @Test("Refresh rotates tokens and retains previous refresh token if omitted")
    func refreshesToken() async throws {
        let transport = XStubTransport([json(#"{"access_token":"access-2","expires_in":3600}"#)])
        let adapter = XAdapter(clientID: "client", transport: transport)
        let updated = try await adapter.refresh(credential())
        #expect(updated.accessToken == "access-2")
        #expect(updated.refreshToken == "refresh-token")
        #expect(try decodeForm(try #require(transport.requests.first))["grant_type"] == "refresh_token")
    }

    @Test("An invalid refresh grant requires reconnecting")
    func rejectsInvalidRefreshGrant() async throws {
        let transport = XStubTransport([HTTPResponse(statusCode: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8))])
        let adapter = XAdapter(clientID: "client", transport: transport)
        await #expect(throws: SocialError.authenticationRequired) {
            try await adapter.refresh(credential())
        }
    }

    @Test("Publish, reply, listing, likes, and repost toggles use documented X v2 routes")
    func publishesAndManagesPosts() async throws {
        let transport = XStubTransport([
            json(#"{"data":{"id":"20001","text":"Hello X"}}"#),
            json(#"{"data":{"id":"20002","text":"Reply text"}}"#),
            json(#"{"data":[{"id":"20001","text":"Hello X","created_at":"2026-11-08T12:00:00Z","public_metrics":{"like_count":5}}],"meta":{"next_token":"next-page"}}"#),
            json(#"{"data":{"liked":true}}"#), json(#"{"data":{"liked":false}}"#),
            json(#"{"data":{"retweeted":true}}"#), json(#"{"data":{"retweeted":false}}"#)
        ])
        let adapter = XAdapter(clientID: "client", transport: transport)
        let account = credential()
        let draft = TextPost(text: "Hello X")
        let published = try await adapter.publish(draft, credential: account)
        let reply = try await adapter.reply(TextPost(text: "Reply text"), to: "10001", credential: account)
        let page = try await adapter.posts(cursor: nil, credential: account)
        try await adapter.setLiked(true, postID: "10001", credential: account)
        try await adapter.setLiked(false, postID: "10001", credential: account)
        try await adapter.setReposted(true, postID: "10001", credential: account)
        try await adapter.setReposted(false, postID: "10001", credential: account)

        #expect(published.id == "20001")
        #expect(reply.id == "20002")
        #expect(page.items.first?.likeCount == 5)
        #expect(page.nextCursor == "next-page")
        #expect(transport.requests.map { $0.url?.path } == [
            "/2/tweets", "/2/tweets", "/2/users/12345/tweets", "/2/users/12345/likes",
            "/2/users/12345/likes/10001", "/2/users/12345/retweets", "/2/users/12345/retweets/10001"
        ])
        #expect(transport.requests[0].httpMethod == "POST")
        #expect(transport.requests[4].httpMethod == "DELETE")
    }

    @Test("Rate limiting and billing denial map to actionable provider errors")
    func mapsRateAndBillingErrors() async throws {
        let adapter = XAdapter(clientID: "client", transport: XStubTransport([
            HTTPResponse(statusCode: 429, headers: ["x-rate-limit-reset": "1794160800"]),
            HTTPResponse(statusCode: 402)
        ]))
        await #expect(throws: SocialError.rateLimited(retryAfter: "Sun, 08 Nov 2026 18:00:00 GMT")) {
            try await adapter.post(id: "10001", credential: credential())
        }
        await #expect(throws: SocialError.billingRequired) {
            try await adapter.post(id: "10001", credential: credential())
        }
    }

    @Test("Granted scopes narrow capabilities; missing like.write cannot issue a like")
    func narrowsCapabilitiesToGrant() async throws {
        let adapter = XAdapter(clientID: "client", transport: XStubTransport([]))
        let limited = SocialCredential(
            account: credential().account,
            accessToken: "token",
            grantedScopes: ["tweet.read", "users.read"]
        )
        #expect(adapter.capabilities(for: limited).contains(.listPosts))
        #expect(!adapter.capabilities(for: limited).contains(.like))
        let empty = SocialCredential(account: limited.account, accessToken: "token", grantedScopes: [])
        #expect(adapter.capabilities(for: empty).isEmpty)
        let noRefreshToken = SocialCredential(account: limited.account, accessToken: "token", grantedScopes: ["offline.access"])
        #expect(!adapter.capabilities(for: noRefreshToken).contains(.refreshSession))
        let store = MemoryCredentialStore()
        await store.save(limited)
        await #expect(throws: SocialError.permissionDenied) {
            try await SocialClient(adapter: adapter, store: store).setLiked(true, postID: "10001", as: limited.account.id)
        }
    }

    @Test("Post lookup, recent conversation replies, and owned reply deletion use supported routes")
    func readsAndDeletesReplies() async throws {
        let transport = XStubTransport([
            json(#"{"data":{"id":"10001","text":"Original","created_at":"2026-11-08T12:00:00Z"}}"#),
            json(#"{"meta":{"result_count":0}}"#),
            json(#"{"data":{"deleted":true}}"#)
        ])
        let adapter = XAdapter(clientID: "client", transport: transport)
        let account = credential()
        let original = try await adapter.post(id: "10001", credential: account)
        let replies = try await adapter.replies(to: "10001", cursor: "opaque+cursor", credential: account)
        try await adapter.deleteReply(id: "20002", credential: account)

        #expect(original.text == "Original")
        #expect(replies.items.isEmpty)
        #expect(transport.requests.map { $0.url?.path } == [
            "/2/tweets/10001", "/2/tweets/search/recent", "/2/tweets/20002"
        ])
        #expect(transport.requests[2].httpMethod == "DELETE")
        let searchURL = try #require(transport.requests[1].url)
        let search = try #require(URLComponents(url: searchURL, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(search.first(where: { $0.name == "query" })?.value == "conversation_id:10001 is:reply")
        #expect(search.first(where: { $0.name == "next_token" })?.value == "opaque+cursor")
    }

    @Test("X publish failures preserve the draft key without replaying the request")
    func publishUncertaintyDoesNotReplay() async throws {
        let transport = XStubTransport([
            HTTPResponse(statusCode: 503),
            json(#"{"data":{}}"#)
        ])
        let adapter = XAdapter(clientID: "client", transport: transport)
        let draft = TextPost(text: "Uncertain")
        await #expect(throws: SocialError.publishOutcomeUnknown(draft.idempotencyKey)) {
            try await adapter.publish(draft, credential: credential())
        }
        #expect(transport.requests.count == 1)
        await #expect(throws: SocialError.publishOutcomeUnknown(draft.idempotencyKey)) {
            try await adapter.publish(draft, credential: credential())
        }
        #expect(transport.requests.count == 2)
    }

    @Test("Image publishing uses user-scoped v2 multipart uploads and creates one multi-image post")
    func publishesImages() async throws {
        let transport = XStubTransport([
            json(#"{"data":{"id":"30001"}}"#),
            json(#"{"data":{"id":"30002"}}"#),
            json(#"{"data":{"id":"40001","text":"Two images"}}"#)
        ])
        let adapter = XAdapter(clientID: "client", includeMediaWriteScope: true, transport: transport)
        let account = credential(scopes: ["tweet.read", "users.read", "tweet.write", "media.write"])
        let result = try await adapter.publishMedia([
            .imageData(Data([0x89, 0x50, 0x4e, 0x47]), contentType: "image/png"),
            .imageData(Data([0xff, 0xd8, 0xff]), contentType: "image/jpeg")
        ], draft: TextPost(text: "Two images"), credential: account)

        #expect(result.id == "40001")
        #expect(transport.requests.map { $0.url?.path } == ["/2/media/upload", "/2/media/upload", "/2/tweets"])
        for upload in transport.requests.prefix(2) {
            #expect(upload.httpMethod == "POST")
            #expect(upload.value(forHTTPHeaderField: "Authorization") == "Bearer saved-access-token")
            #expect(upload.value(forHTTPHeaderField: "Content-Type")?.contains("multipart/form-data; boundary=") == true)
            let body = try #require(upload.httpBody)
            #expect(String(data: body, encoding: .isoLatin1)?.contains("tweet_image") == true)
            #expect(String(data: body, encoding: .isoLatin1)?.contains("name=\"media\"") == true)
        }
        let postBody = try #require(transport.requests[2].httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: postBody) as? [String: Any])
        let media = try #require(json["media"] as? [String: [String]])
        #expect(media["media_ids"] == ["30001", "30002"])
        #expect(transport.requests[2].httpMethod == "POST")
    }

    @Test("Image validation and missing media.write scope fail before any request")
    func rejectsInvalidMediaBeforeRequests() async throws {
        let transport = XStubTransport([])
        let adapter = XAdapter(clientID: "client", includeMediaWriteScope: true, transport: transport)
        let account = credential(scopes: ["tweet.read", "users.read", "tweet.write", "media.write"])
        await #expect(throws: SocialError.invalidInput) {
            try await adapter.publishMedia([
                .imageData(Data([1]), contentType: "image/png"),
                .videoURL(URL(string: "https://cdn.example.test/v.mp4")!)
            ], draft: TextPost(text: "Invalid"), credential: account)
        }
        await #expect(throws: SocialError.permissionDenied) {
            try await adapter.publishMedia(
                .imageData(Data([1]), contentType: "image/png"),
                draft: TextPost(text: "No scope"),
                credential: credential(scopes: ["tweet.write"])
            )
        }
        #expect(transport.requests.isEmpty)
    }

    @Test("Media post creation maps ambiguous outcomes and sends the final create once")
    func mediaCreateUncertaintyIsNotRetried() async throws {
        let transport = XStubTransport([
            json(#"{"data":{"id":"30001"}}"#),
            HTTPResponse(statusCode: 503),
            json(#"{"data":{"id":"40001","text":"Image"}}"#)
        ])
        let adapter = XAdapter(clientID: "client", includeMediaWriteScope: true, transport: transport)
        let draft = TextPost(text: "Image")
        await #expect(throws: SocialError.publishOutcomeUnknown(draft.idempotencyKey)) {
            try await adapter.publishMedia(
                .imageData(Data([1]), contentType: "image/png"), draft: draft,
                credential: credential(scopes: ["tweet.read", "users.read", "tweet.write", "media.write"])
            )
        }
        #expect(transport.requests.count == 2)
        #expect(transport.requests.last?.url?.path == "/2/tweets")
    }

    private func credential(scopes: Set<String> = ["tweet.read", "users.read", "tweet.write", "like.write", "offline.access"]) -> SocialCredential {
        SocialCredential(
            account: SocialAccount(platform: .x, server: URL(string: "https://api.x.com")!, remoteID: "12345", username: "alice"),
            accessToken: "saved-access-token", refreshToken: "refresh-token",
            grantedScopes: scopes
        )
    }

    private func json(_ value: String) -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: Data(value.utf8))
    }

    private func decodeForm(_ request: URLRequest) throws -> [String: String] {
        let body = try #require(request.httpBody)
        let encoded = try #require(String(data: body, encoding: .utf8))
        return Dictionary(uniqueKeysWithValues: encoded.split(separator: "&").compactMap { part in
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2,
                  let key = String(pair[0]).removingPercentEncoding,
                  let value = String(pair[1]).removingPercentEncoding else { return nil }
            return (key, value)
        })
    }

    private static func challenge(_ verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private final class XStubTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [HTTPResponse]
    private var recordedRequests: [URLRequest] = []

    init(_ responses: [HTTPResponse]) { self.responses = responses }

    var requests: [URLRequest] { lock.withLock { recordedRequests } }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        guard let response = lock.withLock({ () -> HTTPResponse? in
            recordedRequests.append(request)
            guard !responses.isEmpty else { return nil }
            return responses.removeFirst()
        }) else { throw SocialError.transportFailure }
        return response
    }
}
