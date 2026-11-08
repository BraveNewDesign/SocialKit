import Foundation
import Testing
@testable import SocialKit

@Suite("Bluesky adapter")
struct BlueskyTests {
    private let did = "did:plc:alice123"
    private let server = URL(string: "https://pds.example")!

    @Test("App password is exchanged for a session at the selected PDS")
    func connectsWithoutRetainingPassword() async throws {
        let transport = StubTransport([json(#"{"accessJwt":"access-1","refreshJwt":"refresh-1","did":"did:plc:alice123","handle":"alice.example"}"#)])
        let adapter = BlueskyAdapter(transport: transport)
        let credential = try await adapter.connect(.init(identifier: "alice.example", appPassword: "app-password-only", server: server))

        #expect(credential.accessToken == "access-1")
        #expect(credential.refreshToken == "refresh-1")
        #expect(credential.account.platform == .bluesky)
        #expect(credential.account.server == server)
        #expect(credential.account.remoteID == did)
        #expect(credential.account.username == "alice.example")

        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://pds.example/xrpc/com.atproto.server.createSession")
        #expect(request.httpMethod == "POST")
        let bodyData = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: String])
        #expect(body["identifier"] == "alice.example")
        #expect(body["password"] == "app-password-only")
        #expect(!credential.accessToken.contains("app-password-only"))
        #expect(!credential.refreshToken!.contains("app-password-only"))
        #expect(String(describing: BlueskyAdapter.Authorization(identifier: "private-handle", appPassword: "app-password-only", server: server)) == "BlueskyAdapter.Authorization([REDACTED])")
        #expect(String(reflecting: BlueskyAdapter.Authorization(identifier: "private-handle", appPassword: "app-password-only", server: server)).contains("app-password-only") == false)
    }

    @Test("Refresh uses the saved refresh token and returns rotated credentials")
    func refreshesSession() async throws {
        let transport = StubTransport([json(#"{"accessJwt":"access-2","refreshJwt":"refresh-2","did":"did:plc:alice123","handle":"alice.example"}"#)])
        let adapter = BlueskyAdapter(transport: transport)
        let refreshed = try await adapter.refresh(makeCredential())

        #expect(refreshed.accessToken == "access-2")
        #expect(refreshed.refreshToken == "refresh-2")
        let request = try #require(transport.requests.first)
        #expect(request.url?.path == "/xrpc/com.atproto.server.refreshSession")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer refresh-token")
    }

    @Test("Publish uses a deterministic create-only record key and supports re-fetch")
    func publishesWithStableRecordURI() async throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let key = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let responseURI = try Self.postURI(key: key, date: date, did: did)
        let transport = StubTransport([json("{\"uri\":\"\(responseURI)\",\"cid\":\"bafy-post\"}")])
        let adapter = BlueskyAdapter(transport: transport)
        let credential = makeCredential()
        let draft = TextPost(text: "Hello, Bluesky", idempotencyKey: key, createdAt: date)
        let post = try await adapter.publish(draft, credential: credential)

        let expectedURI = try Self.postURI(key: key, date: date, did: did)
        #expect(try BlueskyAdapter.postID(for: key, createdAt: date, accountDID: did) == expectedURI)
        #expect(post.id == expectedURI)
        #expect(post.text == "Hello, Bluesky")
        #expect(post.url?.absoluteString == "https://bsky.app/profile/did:plc:alice123/post/\(expectedURI.split(separator: "/").last!)")

        let request = try #require(transport.requests.first)
        #expect(request.url?.path == "/xrpc/com.atproto.repo.createRecord")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
        let bodyData = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["repo"] as? String == did)
        #expect(body["collection"] as? String == "app.bsky.feed.post")
        #expect(body["rkey"] as? String == expectedURI.split(separator: "/").last.map(String.init))
        #expect(body["validate"] as? Bool == true)
        let record = try #require(body["record"] as? [String: String])
        #expect(record["text"] == "Hello, Bluesky")
        #expect(record["$type"] == "app.bsky.feed.post")
        #expect(record["createdAt"] == "2027-01-15T08:00:00.000Z")
    }

    @Test("A duplicate create response remains ambiguous; caller can re-fetch the same URI")
    func duplicateCreateNeedsReconciliation() async throws {
        let key = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let uri = try Self.postURI(key: key, date: date, did: did)
        let transport = StubTransport([
            HTTPResponse(statusCode: 409, body: Data(#"{"error":"RecordAlreadyExists"}"#.utf8)),
            json("{\"uri\":\"\(uri)\",\"cid\":\"bafy-post\",\"value\":{\"text\":\"possibly original\",\"createdAt\":\"2027-01-15T08:00:00.000Z\"}}")
        ])
        let adapter = BlueskyAdapter(transport: transport)

        await #expect(throws: SocialError.publishOutcomeUnknown(key)) {
            try await adapter.publish(TextPost(text: "possibly original", idempotencyKey: key, createdAt: date), credential: makeCredential())
        }
        let fetched = try await adapter.post(id: uri, credential: makeCredential())
        #expect(fetched.text == "possibly original")
        #expect(transport.requests.count == 2)
        #expect(transport.requests[1].url?.path == "/xrpc/com.atproto.repo.getRecord")
    }

    @Test("Successful but malformed publish replies are ambiguous")
    func malformedPublishReplyIsUnknown() async throws {
        let key = UUID(uuidString: "99999999-aaaa-bbbb-cccc-dddddddddddd")!
        let adapter = BlueskyAdapter(transport: StubTransport([json("{}")]))
        await #expect(throws: SocialError.publishOutcomeUnknown(key)) {
            try await adapter.publish(TextPost(text: "hello", idempotencyKey: key), credential: makeCredential())
        }
    }

    @Test("Expired XRPC tokens are reported as authentication errors")
    func expiredTokenErrorMapsToAuthenticationRequired() async throws {
        let key = UUID(uuidString: "99999999-aaaa-bbbb-cccc-dddddddddddd")!
        let transport = StubTransport([HTTPResponse(statusCode: 400, body: Data(#"{"error":"ExpiredToken","message":"do not surface this provider detail"}"#.utf8))])
        let adapter = BlueskyAdapter(transport: transport)
        await #expect(throws: SocialError.authenticationRequired) {
            try await adapter.publish(TextPost(text: "hello", idempotencyKey: key), credential: makeCredential())
        }
    }

    @Test("Like resolves a public target without sending its token to AppView")
    func likesAndRejectsUnlike() async throws {
        let targetURI = "at://did:plc:remote/app.bsky.feed.post/3jzfcijpj2z2a"
        let transport = StubTransport([
            json(#"{"posts":[{"uri":"at://did:plc:remote/app.bsky.feed.post/3jzfcijpj2z2a","cid":"bafy-target","record":{"text":"target","createdAt":"2026-11-08T12:00:00.000Z"}}]}"#),
            json(#"{"uri":"at://did:plc:alice123/app.bsky.feed.like/sk-aaaa","cid":"bafy-like"}"#)
        ])
        let adapter = BlueskyAdapter(transport: transport)
        try await adapter.setLiked(true, postID: targetURI, credential: makeCredential())
        await #expect(throws: SocialError.unsupported(.unlike)) {
            try await adapter.setLiked(false, postID: targetURI, credential: makeCredential())
        }

        #expect(transport.requests.count == 2)
        #expect(transport.requests[0].url?.host == "public.api.bsky.app")
        #expect(transport.requests[0].value(forHTTPHeaderField: "Authorization") == nil)
        #expect(transport.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer access-token")

        let likeRequest = try #require(transport.requests.last)
        #expect(likeRequest.url?.path == "/xrpc/com.atproto.repo.createRecord")
        let bodyData = try #require(likeRequest.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["collection"] as? String == "app.bsky.feed.like")
        let record = try #require(body["record"] as? [String: Any])
        let subject = try #require(record["subject"] as? [String: String])
        #expect(subject["uri"] == targetURI)
        #expect(subject["cid"] == "bafy-target")
        #expect(body["rkey"] == nil)
    }

    @Test("Posts above Bluesky text limits are rejected before a request")
    func rejectsOversizedText() async throws {
        let transport = StubTransport([])
        let adapter = BlueskyAdapter(transport: transport)
        await #expect(throws: SocialError.invalidInput) {
            try await adapter.publish(TextPost(text: String(repeating: "x", count: 301)), credential: makeCredential())
        }
        #expect(transport.requests.isEmpty)
    }

    @Test("Credentials from another platform are rejected before sending a request")
    func refusesForeignCredentials() async throws {
        let transport = StubTransport([])
        let adapter = BlueskyAdapter(transport: transport)
        let foreign = SocialCredential(
            account: SocialAccount(platform: .mastodon, server: server, remoteID: "1", username: "alice"),
            accessToken: "mastodon-secret"
        )
        await #expect(throws: SocialError.invalidConfiguration) {
            try await adapter.post(id: "at://did:plc:alice123/app.bsky.feed.post/sk-1", credential: foreign)
        }
        #expect(transport.requests.isEmpty)
    }

    private func makeCredential() -> SocialCredential {
        SocialCredential(
            account: SocialAccount(platform: .bluesky, server: server, remoteID: did, username: "alice.example"),
            accessToken: "access-token",
            refreshToken: "refresh-token"
        )
    }

    private static func postURI(key: UUID, date: Date, did: String) throws -> String {
        try BlueskyAdapter.postID(for: key, createdAt: date, accountDID: did)
    }

    private func json(_ string: String) -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: Data(string.utf8))
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
        try lock.withLock {
            recordedRequests.append(request)
            guard !responses.isEmpty else { throw SocialError.transportFailure }
            return responses.removeFirst()
        }
    }
}
