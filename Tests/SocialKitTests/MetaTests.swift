import Foundation
import Testing
@testable import SocialKit

@Suite("Meta adapters")
struct MetaTests {
    @Test("Threads OAuth verifies state, then text publishing polls its container and preserves the confirmed ID")
    @MainActor
    func threadsAuthorizationAndPublishing() async throws {
        let transport = MetaStubTransport([
            json(#"{"id":"threaduser","username":"alice"}"#),
            json(#"{"id":"container1"}"#),
            json(#"{"id":"container1","status":"FINISHED"}"#),
            json(#"{"id":"threadpost"}"#)
        ])
        let adapter = ThreadsAdapter(transport: transport, pollIntervalNanoseconds: 0)
        var seenAuthorizationURL: URL?
        let credential = try await adapter.connect(ThreadsAuthorization(
            clientID: "threads-app",
            redirectURI: URL(string: "socialkit://oauth/threads")!,
            browser: { url, callbackURL in
                seenAuthorizationURL = url
                return try callback(url: url, callbackURL: callbackURL)
            },
            exchange: MockOAuthExchange()
        ))

        #expect(credential.account.platform == .threads)
        #expect(credential.account.server == URL(string: "https://graph.threads.net"))
        #expect(credential.account.remoteID == "threaduser")
        let post = try await adapter.publish(TextPost(text: "Hello Threads"), credential: credential)
        #expect(post.id == "threadpost")
        #expect(post.text == "Hello Threads")
        let requests = await transport.requests
        #expect(requests.count == 4)
        #expect(requests[0].url?.path == "/v1.0/me")
        #expect(requests[1].url?.path == "/v1.0/threaduser/threads")
        #expect(form(requests[1]) == ["media_type": "TEXT", "text": "Hello Threads"])
        #expect(requests[2].url?.path == "/v1.0/container1")
        #expect(requests[3].url?.path == "/v1.0/threaduser/threads_publish")
        #expect(form(requests[3]) == ["creation_id": "container1"])
        #expect(seenAuthorizationURL?.host == "threads.net")
    }

    @Test("Threads rejects mismatched OAuth state before confidential exchange")
    @MainActor
    func threadsRejectsInvalidState() async throws {
        let transport = MetaStubTransport([])
        let exchange = MockOAuthExchange()
        let adapter = ThreadsAdapter(transport: transport)
        await #expect(throws: SocialError.authorizationFailed) {
            try await adapter.connect(ThreadsAuthorization(
                clientID: "app",
                redirectURI: URL(string: "socialkit://oauth/threads")!,
                browser: { _, callbackURL in
                    var parts = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)!
                    parts.queryItems = [URLQueryItem(name: "code", value: "code"), URLQueryItem(name: "state", value: "wrong")]
                    return parts.url!
                },
                exchange: exchange
            ))
        }
        #expect(await exchange.exchangeCount == 0)
        #expect(await transport.requests.isEmpty)
    }

    @Test("Threads paginates posts with the opaque after cursor")
    func threadsPagination() async throws {
        let transport = MetaStubTransport([
            json(#"{"data":[{"id":"post1","text":"one","permalink":"https://threads.com/@a/post1","timestamp":"2026-11-08T10:00:00Z"}],"paging":{"cursors":{"after":"opaque+cursor"},"next":"https://graph.threads.net/next"}}"#),
            json(#"{"data":[],"paging":{}}"#)
        ])
        let adapter = ThreadsAdapter(transport: transport)
        let page = try await adapter.posts(cursor: nil, credential: threadsCredential())
        #expect(page.items.map(\.id) == ["post1"])
        #expect(page.nextCursor == "opaque+cursor")
        let next = try await adapter.posts(cursor: page.nextCursor, credential: threadsCredential())
        #expect(next.items.isEmpty)
        let requests = await transport.requests
        #expect(requests[1].url?.absoluteString.contains("after=opaque%2Bcursor") == true)
    }

    @Test("Facebook Pages discovers Page tokens, publishes text and toggles Page likes")
    @MainActor
    func facebookPageConnectPublishAndLike() async throws {
        let transport = MetaStubTransport([
            json(#"{"data":[{"id":"page42","name":"Page 42","access_token":"page-token","tasks":["CREATE_CONTENT"]}],"paging":{}}"#),
            json(#"{"id":"page42_9"}"#),
            json(#"{"success":true}"#),
            json(#"{"success":true}"#)
        ])
        let adapter = FacebookPagesAdapter(transport: transport)
        let credential = try await adapter.connect(FacebookPagesAuthorization(
            clientID: "meta-app", redirectURI: URL(string: "socialkit://oauth/facebook")!,
            browser: { url, callbackURL in try callback(url: url, callbackURL: callbackURL) },
            exchange: MockOAuthExchange()
        ))
        #expect(credential.accessToken == "page-token")
        #expect(credential.account.remoteID == "page42")
        let post = try await adapter.publish(TextPost(text: "Page update"), credential: credential)
        #expect(post.id == "page42_9")
        try await adapter.setLiked(true, postID: post.id, credential: credential)
        try await adapter.setLiked(false, postID: post.id, credential: credential)
        let requests = await transport.requests
        #expect(requests[0].url?.path == "/v27.0/me/accounts")
        #expect(requests[1].url?.path == "/v27.0/page42/feed")
        #expect(form(requests[1]) == ["message": "Page update"])
        #expect(requests[2].url?.path == "/v27.0/page42_9/likes")
        #expect(requests[2].httpMethod == "POST")
        #expect(requests[3].httpMethod == "DELETE")
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer user-token")
        #expect(requests.dropFirst().allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer page-token" })
    }

    @Test("Facebook Page comment writes, comment pages and deletion use the Page token")
    func facebookPageComments() async throws {
        let transport = MetaStubTransport([
            json(#"{"id":"comment1"}"#),
            json(#"{"data":[{"id":"comment1","message":"A reply","from":{"name":"Alice"},"created_time":"2026-11-08T10:00:00Z","like_count":2}],"paging":{"cursors":{"after":"next"},"next":"https://graph.facebook.com/next"}}"#),
            json(#"{"success":true}"#)
        ])
        let adapter = FacebookPagesAdapter(transport: transport)
        let credential = pageCredential()
        let created = try await adapter.reply(TextPost(text: "A reply"), to: "page42_9", credential: credential)
        #expect(created.id == "comment1")
        let comments = try await adapter.replies(to: "page42_9", cursor: nil, credential: credential)
        #expect(comments.items.first?.text == "A reply")
        #expect(comments.items.first?.likeCount == 2)
        #expect(comments.nextCursor == "next")
        try await adapter.deleteReply(id: "comment1", credential: credential)
        let requests = await transport.requests
        #expect(requests[0].url?.path == "/v27.0/page42_9/comments")
        #expect(requests[1].url?.path == "/v27.0/page42_9/comments")
        #expect(requests[2].url?.path == "/v27.0/comment1")
        #expect(requests[2].httpMethod == "DELETE")
    }

    @Test("Facebook requires explicit Page selection if discovery returns multiple publishable Pages")
    @MainActor
    func facebookRejectsAmbiguousPage() async throws {
        let transport = MetaStubTransport([
            json(#"{"data":[{"id":"one","name":"One","access_token":"token-1","tasks":["CREATE_CONTENT"]},{"id":"two","name":"Two","access_token":"token-2","tasks":["CREATE_CONTENT"]}],"paging":{}}"#)
        ])
        let adapter = FacebookPagesAdapter(transport: transport)
        await #expect(throws: SocialError.invalidInput) {
            try await adapter.connect(FacebookPagesAuthorization(
                clientID: "app", redirectURI: URL(string: "socialkit://oauth/facebook")!,
                browser: { url, callbackURL in try callback(url: url, callbackURL: callbackURL) },
                exchange: MockOAuthExchange()
            ))
        }
    }

    @Test("Instagram Login creates an image container, polls it, publishes and returns media without a read-after-write")
    @MainActor
    func instagramMediaPublishing() async throws {
        let transport = MetaStubTransport([
            json(#"{"id":"appscoped","user_id":"iguser","username":"studio"}"#),
            json(#"{"id":"container"}"#),
            json(#"{"id":"container","status_code":"FINISHED"}"#),
            json(#"{"id":"media9"}"#)
        ])
        let adapter = InstagramAdapter(transport: transport, pollIntervalNanoseconds: 0)
        let credential = try await adapter.connect(InstagramAuthorization(
            clientID: "ig-app", redirectURI: URL(string: "socialkit://oauth/instagram")!,
            browser: { url, callbackURL in try callback(url: url, callbackURL: callbackURL) },
            exchange: MockOAuthExchange()
        ))
        #expect(credential.account.remoteID == "iguser")
        let mediaURL = URL(string: "https://cdn.example.test/photo.jpg")!
        let post = try await adapter.publishMedia(.imageURL(mediaURL), draft: TextPost(text: "Caption"), credential: credential)
        #expect(post.id == "media9")
        #expect(post.media == [SocialAttachment(kind: .image, url: mediaURL)])
        let requests = await transport.requests
        #expect(requests.count == 4)
        #expect(requests[0].url?.path == "/v27.0/me")
        #expect(requests[1].url?.path == "/v27.0/iguser/media")
        #expect(form(requests[1]) == ["image_url": mediaURL.absoluteString, "caption": "Caption"])
        #expect(requests[2].url?.path == "/v27.0/container")
        #expect(requests[3].url?.path == "/v27.0/iguser/media_publish")
    }

    @Test("Instagram comment replies use the comment replies edge and list media comments")
    func instagramComments() async throws {
        let transport = MetaStubTransport([
            json(#"{"id":"reply1"}"#),
            json(#"{"data":[{"id":"comment1","text":"Looks good","username":"alice","timestamp":"2026-11-08T10:00:00Z","like_count":1}],"paging":{"cursors":{"after":"cursor"},"next":"https://graph.instagram.com/next"}}"#)
        ])
        let adapter = InstagramAdapter(transport: transport)
        let credential = instagramCredential()
        let reply = try await adapter.reply(TextPost(text: "Thanks"), to: "comment1", credential: credential)
        #expect(reply.id == "reply1")
        #expect(reply.text == "Thanks")
        let comments = try await adapter.replies(to: "media1", cursor: nil, credential: credential)
        #expect(comments.items.first?.id == "comment1")
        #expect(comments.items.first?.text == "Looks good")
        let requests = await transport.requests
        #expect(requests[0].url?.path == "/v27.0/comment1/replies")
        #expect(form(requests[0]) == ["message": "Thanks"])
        #expect(requests[1].url?.path == "/v27.0/media1/comments")
    }

    @Test("Instagram timeout does not publish an unfinished media container")
    func instagramPollTimeout() async throws {
        let transport = MetaStubTransport([
            json(#"{"id":"container"}"#),
            json(#"{"id":"container","status_code":"IN_PROGRESS"}"#)
        ])
        let adapter = InstagramAdapter(transport: transport, pollAttempts: 1, pollIntervalNanoseconds: 0)
        await #expect(throws: SocialError.mediaProcessingTimedOut) {
            try await adapter.publishMedia(.imageURL(URL(string: "https://cdn.example.test/p.jpg")!),
                                           draft: TextPost(text: ""), credential: instagramCredential())
        }
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.url?.path != "/v27.0/iguser/media_publish" })
    }

    @Test("Threads reply creation and repost use their distinct Graph endpoints")
    func threadsReplyAndRepost() async throws {
        let transport = MetaStubTransport([
            json(#"{"id":"container"}"#),
            json(#"{"id":"container","status":"FINISHED"}"#),
            json(#"{"id":"reply1"}"#),
            json(#"{"id":"repost1"}"#)
        ])
        let adapter = ThreadsAdapter(transport: transport, pollIntervalNanoseconds: 0)
        let credential = threadsCredential()
        let reply = try await adapter.reply(TextPost(text: "Reply"), to: "post1", credential: credential)
        #expect(reply.id == "reply1")
        try await adapter.setReposted(true, postID: "post1", credential: credential)
        let requests = await transport.requests
        #expect(requests[0].url?.path == "/v1.0/threaduser/threads")
        #expect(form(requests[0])["reply_to_id"] == "post1")
        #expect(requests[2].url?.path == "/v1.0/threaduser/threads_publish")
        #expect(requests[3].url?.path == "/v1.0/post1/repost")
    }

    @Test("Threads moderates replies and uses cursors without following paging links")
    func moderatesThreadsReplies() async throws {
        let transport = MetaStubTransport([
            json(#"{"data":[{"id":"r1","text":"Reply"}],"paging":{"cursors":{"after":"older"}}}"#),
            json(#"{"success":true}"#), json(#"{"success":true}"#)
        ])
        let adapter = ThreadsAdapter(transport: transport)
        let credential = threadsCredential()
        let page = try await adapter.replies(to: "t1", cursor: nil, credential: credential)
        #expect(page.nextCursor == "older")
        try await adapter.setReplyHidden(true, id: "r1", credential: credential)
        try await adapter.setReplyHidden(false, id: "r1", credential: credential)
        let requests = await transport.requests
        #expect(requests.dropFirst().allSatisfy { $0.url?.path == "/v1.0/r1/manage_reply" })
        #expect(requests.dropFirst().map { $0.url?.query } == ["hide=true", "hide=false"])
    }

    @Test("Long-lived Threads tokens refresh without losing account or scope metadata")
    func threadsRefresh() async throws {
        let transport = MetaStubTransport([json(#"{"access_token":"renewed-token","expires_in":5184000}"#)])
        let adapter = ThreadsAdapter(transport: transport)
        let credential = threadsCredential()
        let refreshed = try await adapter.refresh(credential)
        #expect(refreshed.accessToken == "renewed-token")
        #expect(refreshed.account == credential.account)
        #expect(refreshed.expiresAt != nil)
        #expect(await transport.requests.first?.url?.path == "/refresh_access_token")
    }

    @Test("Long-lived Instagram tokens refresh and preserve the professional account identity")
    func instagramRefresh() async throws {
        let transport = MetaStubTransport([json(#"{"access_token":"renewed-ig","expires_in":5184000}"#)])
        let adapter = InstagramAdapter(transport: transport)
        let credential = instagramCredential()
        let refreshed = try await adapter.refresh(credential)
        #expect(refreshed.accessToken == "renewed-ig")
        #expect(refreshed.account == credential.account)
        #expect(await transport.requests.first?.url?.path == "/refresh_access_token")
    }

    @Test("Meta permission errors are classified and never retried as writes")
    func mapsMetaPermissionError() async throws {
        let transport = MetaStubTransport([
            HTTPResponse(statusCode: 400, body: Data(#"{"error":{"message":"denied","type":"OAuthException","code":200}}"#.utf8))
        ])
        let adapter = FacebookPagesAdapter(transport: transport)
        await #expect(throws: SocialError.permissionDenied) {
            try await adapter.publish(TextPost(text: "test"), credential: pageCredential())
        }
        #expect(await transport.requests.count == 1)
    }

    @Test("Meta Graph authentication and throttle codes map to stable adapter errors")
    func mapsMetaAuthAndRateErrors() async throws {
        let auth = MetaStubTransport([HTTPResponse(statusCode: 400, body: Data(#"{"error":{"code":190}}"#.utf8))])
        await #expect(throws: SocialError.authenticationRequired) {
            try await ThreadsAdapter(transport: auth).post(id: "post1", credential: threadsCredential())
        }
        let throttled = MetaStubTransport([HTTPResponse(statusCode: 400, body: Data(#"{"error":{"code":17}}"#.utf8))])
        await #expect(throws: SocialError.rateLimited(retryAfter: nil)) {
            try await FacebookPagesAdapter(transport: throttled).post(id: "post1", credential: pageCredential())
        }
    }
}

private actor MockOAuthExchange: ConfidentialOAuthExchange {
    private(set) var exchangeCount = 0

    func exchange(platform: SocialPlatform, code: String, redirectURI: URL) async throws -> OAuthToken {
        exchangeCount += 1
        return OAuthToken(accessToken: "user-token", grantedScopes: [
            "threads_basic", "threads_content_publish", "threads_read_replies", "threads_manage_replies", "threads_delete",
            "pages_show_list", "pages_manage_posts", "pages_read_engagement", "pages_manage_engagement", "pages_read_user_content",
            "instagram_business_basic", "instagram_business_content_publish", "instagram_business_manage_comments"
        ])
    }
}

private actor MetaStubTransport: HTTPTransport {
    private var responses: [HTTPResponse]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [HTTPResponse]) { self.responses = responses }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw SocialError.transportFailure }
        return responses.removeFirst()
    }
}

@MainActor
private func callback(url: URL, callbackURL: URL) throws -> URL {
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    guard let state = query.first(where: { $0.name == "state" })?.value,
          var parts = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
        throw SocialError.authorizationFailed
    }
    parts.queryItems = [URLQueryItem(name: "code", value: "one-time-code"), URLQueryItem(name: "state", value: state)]
    guard let result = parts.url else { throw SocialError.authorizationFailed }
    return result
}

private func json(_ value: String) -> HTTPResponse {
    HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: Data(value.utf8))
}

private func form(_ request: URLRequest) -> [String: String] {
    guard let body = request.httpBody, let value = String(data: body, encoding: .utf8) else { return [:] }
    var result: [String: String] = [:]
    for pair in value.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let key = String(parts[0]).removingPercentEncoding,
              let val = String(parts[1]).removingPercentEncoding else { continue }
        result[key] = val
    }
    return result
}

private func threadsCredential() -> SocialCredential {
    SocialCredential(account: SocialAccount(platform: .threads, server: URL(string: "https://graph.threads.net")!, remoteID: "threaduser", username: "alice"), accessToken: "thread-token")
}

private func pageCredential() -> SocialCredential {
    SocialCredential(account: SocialAccount(platform: .facebookPages, server: URL(string: "https://graph.facebook.com")!, remoteID: "page42", username: "Page 42"), accessToken: "page-token")
}

private func instagramCredential() -> SocialCredential {
    SocialCredential(account: SocialAccount(platform: .instagram, server: URL(string: "https://graph.instagram.com")!, remoteID: "iguser", username: "studio"), accessToken: "ig-token")
}
