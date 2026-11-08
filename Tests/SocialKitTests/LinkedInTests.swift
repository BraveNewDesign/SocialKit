import Foundation
import Testing
@testable import SocialKit

@Suite("LinkedIn adapter")
struct LinkedInTests {
    @Test("Authorization exchanges the callback through the confidential broker and verifies the member")
    @MainActor
    func authorizationUsesBrokerAndOIDCIdentity() async throws {
        let transport = LinkedInTransport([json(#"{"sub":"member-7","name":"Ada Member"}"#)])
        let broker = LinkedInBroker()
        let adapter = LinkedInAdapter(transport: transport, oauthBroker: broker)
        let redirect = try #require(URL(string: "socialkit://oauth/callback"))
        var seenURL: URL?
        let credential = try await adapter.connect(.init(
            clientID: "client+1",
            redirectURI: redirect,
            browser: { authorizationURL, callbackURL in
                seenURL = authorizationURL
                var components = try #require(URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false))
                let state = try #require(components.queryItems?.first(where: { $0.name == "state" })?.value)
                components = try #require(URLComponents(url: callbackURL, resolvingAgainstBaseURL: false))
                components.queryItems = [URLQueryItem(name: "code", value: "code-1"), URLQueryItem(name: "state", value: state)]
                return try #require(components.url)
            }
        ))

        #expect(credential.account.platform == .linkedIn)
        #expect(credential.account.remoteID == "urn:li:person:member-7")
        #expect(credential.account.username == "Ada Member")
        #expect(credential.grantedScopes?.contains("w_member_social") == true)
        #expect(URLComponents(url: try #require(seenURL), resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "client_id" })?.value == "client+1")
        #expect(transport.requests.count == 1)
        #expect(transport.requests[0].url?.path == "/v2/userinfo")
        #expect(transport.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
        #expect(await broker.exchangedCode == "code-1")
    }

    @Test("Text publishing uses the selected member or organization author, version headers, and detects ambiguous success")
    func publishesAndKeepsAmbiguity() async throws {
        let key = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let transport = LinkedInTransport([
            HTTPResponse(statusCode: 201, headers: ["x-restli-id": "urn:li:share:123"]),
            HTTPResponse(statusCode: 201)
        ])
        let adapter = LinkedInAdapter(transport: transport)
        let orgCredential = credential(author: "urn:li:organization:900", scopes: ["w_organization_social"])
        let post = try await adapter.publish(TextPost(text: "A {new} #day", idempotencyKey: key), credential: orgCredential)
        #expect(post.id == "urn:li:share:123")
        let first = try #require(transport.requests.first)
        #expect(first.url?.path == "/rest/posts")
        #expect(first.value(forHTTPHeaderField: "Linkedin-Version") == LinkedInAdapter.currentAPIVersion)
        #expect(first.value(forHTTPHeaderField: "X-Restli-Protocol-Version") == "2.0.0")
        let requestBody = try #require(first.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        #expect(body["author"] as? String == "urn:li:organization:900")
        #expect(body["commentary"] as? String == "A \\{new\\} \\#day")

        await #expect(throws: SocialError.publishOutcomeUnknown(key)) {
            try await adapter.publish(TextPost(text: "Retry carefully", idempotencyKey: key), credential: orgCredential)
        }
    }

    @Test("Post pagination and comments use encoded URNs, returned cursors, and authorized read scopes")
    func readsPostsAndComments() async throws {
        let postURN = "urn:li:ugcPost:777"
        let commentURN = "urn:li:comment:(urn:li:ugcPost:777,888)"
        let transport = LinkedInTransport([
            json(#"{"id":"urn:li:ugcPost:777","author":"urn:li:person:member-7","commentary":"Hello"}"#),
            json(#"{"elements":[{"id":"urn:li:ugcPost:777","author":"urn:li:person:member-7","commentary":"Hello","publishedAt":1800000000000}],"paging":{"total":2}}"#),
            json(#"{"elements":[{"commentUrn":"urn:li:comment:(urn:li:ugcPost:777,888)","message":{"text":"Thanks"},"created":{"time":1800000000000}}],"paging":{"total":2}}"#)
        ])
        let adapter = LinkedInAdapter(transport: transport)
        let readCredential = credential(scopes: ["r_member_social", "r_member_social_feed"])
        let post = try await adapter.post(id: postURN, credential: readCredential)
        #expect(post.text == "Hello")
        #expect(transport.requests[0].url?.absoluteString == "https://api.linkedin.com/rest/posts/urn%3Ali%3AugcPost%3A777")
        let posts = try await adapter.posts(cursor: nil, credential: readCredential)
        let comments = try await adapter.replies(to: postURN, cursor: nil, credential: readCredential)
        #expect(posts.items.first?.id == postURN)
        #expect(posts.nextCursor == "1")
        #expect(comments.items.first?.id == commentURN)
        #expect(comments.nextCursor == "1")
        #expect(transport.requests[1].url?.absoluteString == "https://api.linkedin.com/rest/posts?q=author&author=urn%3Ali%3Aperson%3Amember-7&start=0&count=25&sortBy=LAST_MODIFIED")
        #expect(transport.requests[2].url?.absoluteString == "https://api.linkedin.com/rest/socialActions/urn%3Ali%3AugcPost%3A777/comments?start=0&count=25")

        let restricted = credential(scopes: ["w_member_social"])
        let noNetwork = LinkedInTransport([])
        await #expect(throws: SocialError.permissionDenied) {
            try await LinkedInAdapter(transport: noNetwork).posts(cursor: nil, credential: restricted)
        }
        #expect(noNetwork.requests.isEmpty)
    }

    @Test("Image bytes upload only to the approved LinkedIn host before post creation")
    func uploadsImageBytesThenPublishes() async throws {
        let transport = LinkedInTransport([
            json(#"{"value":{"uploadUrl":"https://www.linkedin.com/dms-uploads/upload-1?sig=ok","image":"urn:li:image:abc123"}}"#),
            HTTPResponse(statusCode: 201),
            HTTPResponse(statusCode: 201, headers: ["x-restli-id": "urn:li:share:444"])
        ])
        let adapter = LinkedInAdapter(transport: transport)
        let post = try await adapter.publishMedia(.imageData(Data([0x89, 0x50, 0x4E, 0x47]), contentType: "image/png"), draft: TextPost(text: "Image"), credential: credential(scopes: ["w_member_social"]))
        #expect(post.id == "urn:li:share:444")
        #expect(transport.requests.count == 3)
        #expect(transport.requests[0].url?.path == "/rest/images")
        #expect(transport.requests[1].url?.host == "www.linkedin.com")
        #expect(transport.requests[1].httpMethod == "PUT")
        #expect(transport.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer token")
        #expect(transport.requests[1].httpBody == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(transport.requests[2].url?.path == "/rest/posts")
    }

    @Test("Organization roles are checked when the granted admin scope permits it")
    @MainActor
    func checksGrantedOrganizationRole() async throws {
        let scopes: Set<String> = ["openid", "profile", "w_organization_social", "r_organization_admin"]
        let transport = LinkedInTransport([
            json(#"{"sub":"member-7","name":"Ada Member"}"#),
            json(#"{"elements":[],"paging":{"count":100,"start":0,"links":[{"rel":"next","href":"/rest/organizationAcls?count=100&start=100"}]}}"#),
            json(#"{"elements":[{"organizationTarget":"urn:li:organization:900","roleAssignee":"urn:li:person:member-7","role":"CONTENT_ADMINISTRATOR","state":"APPROVED"}]}"#)
        ])
        let adapter = LinkedInAdapter(transport: transport, oauthBroker: LinkedInBroker(scopes: scopes))
        let redirect = try #require(URL(string: "socialkit://oauth/callback"))
        let credential = try await adapter.connect(.init(
            clientID: "client", redirectURI: redirect,
            organizationURN: "urn:li:organization:900",
            browser: { authorizationURL, callbackURL in
                let state = try #require(URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "state" })?.value)
                var callback = try #require(URLComponents(url: callbackURL, resolvingAgainstBaseURL: false))
                callback.queryItems = [URLQueryItem(name: "code", value: "code"), URLQueryItem(name: "state", value: state)]
                return try #require(callback.url)
            }
        ))
        #expect(credential.account.remoteID == "urn:li:organization:900")
        #expect(transport.requests[1].url?.absoluteString.contains("/rest/organizationAcls?q=roleAssignee&state=APPROVED&start=0") == true)
        #expect(transport.requests[2].url?.absoluteString.contains("start=100") == true)
    }

    @Test("A media upload that is still processing is polled only with the granted read scope")
    func waitsForReadableImageStatus() async throws {
        let org = "urn:li:organization:900"
        let transport = LinkedInTransport([
            json(#"{"value":{"uploadUrl":"https://www.linkedin.com/dms-uploads/upload-1?sig=ok","image":"urn:li:image:abc123"}}"#),
            HTTPResponse(statusCode: 201),
            json(#"{"id":"urn:li:image:abc123","owner":"urn:li:organization:900","status":"PROCESSING"}"#),
            json(#"{"id":"urn:li:image:abc123","owner":"urn:li:organization:900","status":"AVAILABLE"}"#),
            HTTPResponse(statusCode: 201, headers: ["x-restli-id": "urn:li:share:445"])
        ])
        let post = try await LinkedInAdapter(transport: transport).publishMedia(
            .imageData(Data([1, 2]), contentType: "image/jpeg"), draft: TextPost(text: "Image"),
            credential: credential(author: org, scopes: ["w_organization_social"])
        )
        #expect(post.id == "urn:li:share:445")
        #expect(transport.requests.map(\.url?.path) == [
            "/rest/images", "/dms-uploads/upload-1", "/rest/images/urn:li:image:abc123",
            "/rest/images/urn:li:image:abc123", "/rest/posts"
        ])
    }

    @Test("Replies verify the numeric response ID and likes use LinkedIn Reactions")
    func createsReplyAndTogglesLike() async throws {
        let postID = "urn:li:share:123"
        let replyURN = "urn:li:comment:(urn:li:activity:123,998)"
        let transport = LinkedInTransport([
            HTTPResponse(statusCode: 201, headers: ["x-restli-id": "998"], body: Data(#"{"commentUrn":"urn:li:comment:(urn:li:activity:123,998)"}"#.utf8)),
            HTTPResponse(statusCode: 201), HTTPResponse(statusCode: 204)
        ])
        let adapter = LinkedInAdapter(transport: transport)
        let orgCredential = credential(author: "urn:li:organization:900", scopes: ["w_organization_social_feed"])
        let reply = try await adapter.reply(TextPost(text: "Thanks"), to: postID, credential: orgCredential)
        try await adapter.setLiked(true, postID: postID, credential: orgCredential)
        try await adapter.setLiked(false, postID: postID, credential: orgCredential)
        #expect(reply.id == replyURN)
        let body = try #require(transport.requests[0].httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["actor"] as? String == "urn:li:organization:900")
        #expect(object["object"] as? String == postID)
        #expect(transport.requests[1].url?.absoluteString.contains("actor=urn%3Ali%3Aorganization%3A900") == true)
        #expect(String(decoding: try #require(transport.requests[1].httpBody), as: UTF8.self).contains("\"reactionType\":\"LIKE\""))
        #expect(transport.requests[2].httpMethod == "DELETE")
    }

    @Test("Refresh is available only with a broker and saved refresh token")
    func refreshesOnlyWhenConfigured() async throws {
        let broker = LinkedInBroker()
        let adapter = LinkedInAdapter(transport: LinkedInTransport([]), oauthBroker: broker)
        let original = SocialCredential(
            account: SocialAccount(platform: .linkedIn, server: LinkedInAdapter.apiOrigin, remoteID: "urn:li:person:member-7", username: "Ada"),
            accessToken: "token", refreshToken: "refresh-token", expiresAt: Date(timeIntervalSince1970: 1),
            grantedScopes: ["w_member_social"]
        )
        #expect(adapter.capabilities(for: original).contains(.refreshSession))
        let refreshed = try await adapter.refresh(original)
        #expect(refreshed.accessToken == "refreshed-token")
        #expect(refreshed.refreshToken == "rotated-refresh")
        #expect(refreshed.grantedScopes == original.grantedScopes)
        #expect(refreshed.expiresAt != nil)
        let withoutRefresh = SocialCredential(
            account: original.account, accessToken: "token", grantedScopes: original.grantedScopes
        )
        #expect(!adapter.capabilities(for: withoutRefresh).contains(.refreshSession))
    }

    @Test("Unvalidated upload hosts never receive the bearer token")
    func rejectsUntrustedUploadURL() async throws {
        let transport = LinkedInTransport([
            json(#"{"value":{"uploadUrl":"https://attacker.example/dms-uploads/upload-1?sig=bad","image":"urn:li:image:abc123"}}"#)
        ])
        await #expect(throws: SocialError.invalidResponse) {
            try await LinkedInAdapter(transport: transport).publishMedia(
                .imageData(Data([1]), contentType: "image/jpeg"), draft: TextPost(text: "Image"), credential: credential(scopes: ["w_member_social"])
            )
        }
        #expect(transport.requests.count == 1)
    }

    private func credential(author: String = "urn:li:person:member-7", scopes: Set<String>) -> SocialCredential {
        SocialCredential(
            account: SocialAccount(platform: .linkedIn, server: LinkedInAdapter.apiOrigin, remoteID: author, username: "Ada Member"),
            accessToken: "token", refreshToken: nil, grantedScopes: scopes
        )
    }

    private func json(_ value: String) -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: Data(value.utf8))
    }
}

private actor LinkedInBroker: ConfidentialOAuthExchange {
    private(set) var exchangedCode: String?
    private let scopes: Set<String>

    init(scopes: Set<String> = ["openid", "profile", "w_member_social"]) { self.scopes = scopes }

    func exchange(platform: SocialPlatform, code: String, redirectURI: URL) async throws -> OAuthToken {
        exchangedCode = code
        return OAuthToken(accessToken: "access-token", expiresAt: Date(timeIntervalSince1970: 1_900_000_000), grantedScopes: scopes)
    }

    func refresh(platform: SocialPlatform, token: OAuthToken) async throws -> OAuthToken {
        OAuthToken(accessToken: "refreshed-token", refreshToken: "rotated-refresh", expiresAt: Date(timeIntervalSince1970: 1_900_000_000), grantedScopes: token.grantedScopes)
    }
}

private final class LinkedInTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [HTTPResponse]
    private var storedRequests: [URLRequest] = []

    init(_ responses: [HTTPResponse]) { self.responses = responses }
    var requests: [URLRequest] { lock.withLock { storedRequests } }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        lock.withLock {
            storedRequests.append(request)
            return responses.isEmpty ? HTTPResponse(statusCode: 500) : responses.removeFirst()
        }
    }
}
