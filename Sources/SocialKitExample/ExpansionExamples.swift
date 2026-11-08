import Foundation
import SocialKit

private struct Fixture {
    let method: String
    let path: String
    let response: HTTPResponse

    init(_ method: String, _ path: String, _ json: String, status: Int = 200, headers: [String: String] = [:]) {
        self.method = method
        self.path = path
        response = HTTPResponse(statusCode: status, headers: headers, body: Data(json.utf8))
    }
}

private actor ExampleTransport: HTTPTransport {
    private var remaining: ArraySlice<Fixture>

    init(_ fixtures: [Fixture]) {
        remaining = fixtures[...]
    }

    func send(_ request: URLRequest) throws -> HTTPResponse {
        guard let fixture = remaining.popFirst(),
              request.httpMethod == fixture.method, request.url?.path == fixture.path else {
            throw SocialError.invalidInput
        }
        return fixture.response
    }
}

private struct ExampleExchange: ConfidentialOAuthExchange {
    func exchange(platform: SocialPlatform, code: String, redirectURI: URL) async throws -> OAuthToken {
        guard code == "example-code" else { throw SocialError.authorizationFailed }
        return OAuthToken(accessToken: "example-user-token")
    }
}

private let exampleBrowser: OAuthBrowser = { authorization, redirect in
    guard let state = URLComponents(url: authorization, resolvingAgainstBaseURL: false)?
        .queryItems?.first(where: { $0.name == "state" })?.value,
        var callback = URLComponents(url: redirect, resolvingAgainstBaseURL: false) else {
        throw SocialError.authorizationFailed
    }
    callback.queryItems = [
        URLQueryItem(name: "code", value: "example-code"),
        URLQueryItem(name: "state", value: state)
    ]
    guard let url = callback.url else { throw SocialError.authorizationFailed }
    return url
}

func runExpansionExamples(platform: SocialPlatform?) async throws {
    let store = MemoryCredentialStore()
    let draft = TextPost(text: "Hello from SocialKit")
    let redirect = URL(string: "https://app.example/oauth/callback")!
    let exchange = ExampleExchange()

    if platform == nil || platform == .mastodon {
        try await runMastodonExample(store: store, draft: draft)
    }

    if platform == nil || platform == .threads {
        let threads = SocialClient(adapter: ThreadsAdapter(transport: ExampleTransport([
            Fixture("GET", "/v1.0/me", #"{"id":"101","username":"demo"}"#),
            Fixture("POST", "/v1.0/101/threads", #"{"id":"102"}"#),
            Fixture("GET", "/v1.0/102", #"{"id":"102","status":"FINISHED"}"#),
            Fixture("POST", "/v1.0/101/threads_publish", #"{"id":"103"}"#)
        ])), store: store)
        let threadAccount = try await threads.connect(ThreadsAuthorization(
            clientID: "example-client", redirectURI: redirect, browser: exampleBrowser, exchange: exchange
        ))
        let thread = try await threads.publish(draft, as: threadAccount.id)
        print("Simulated Threads publish: \(thread.id)")
    }

    if platform == nil || platform == .facebookPages {
        let facebook = SocialClient(adapter: FacebookPagesAdapter(transport: ExampleTransport([
            Fixture("GET", "/v27.0/me/permissions", #"{"data":[{"permission":"pages_manage_posts","status":"granted"},{"permission":"pages_show_list","status":"granted"}]}"#),
            Fixture("GET", "/v27.0/me/accounts", #"{"data":[{"id":"201","name":"Demo Page","access_token":"page-token","tasks":["CREATE_CONTENT"]}]}"#),
            Fixture("POST", "/v27.0/201/feed", #"{"id":"201_202"}"#)
        ])), store: store)
        let page = try await facebook.connect(FacebookPagesAuthorization(
            clientID: "example-client", redirectURI: redirect, browser: exampleBrowser, exchange: exchange
        ))
        let pagePost = try await facebook.publish(draft, as: page.id)
        print("Simulated Facebook Page publish: \(pagePost.id)")
    }

    if platform == nil || platform == .instagram {
        let instagram = SocialClient(adapter: InstagramAdapter(transport: ExampleTransport([
            Fixture("GET", "/v27.0/me", #"{"id":"301","user_id":"301","username":"demo"}"#),
            Fixture("POST", "/v27.0/301/media", #"{"id":"302"}"#),
            Fixture("POST", "/v27.0/301/media", #"{"id":"304"}"#),
            Fixture("GET", "/v27.0/302", #"{"id":"302","status_code":"FINISHED"}"#),
            Fixture("GET", "/v27.0/304", #"{"id":"304","status_code":"FINISHED"}"#),
            Fixture("POST", "/v27.0/301/media", #"{"id":"305"}"#),
            Fixture("GET", "/v27.0/305", #"{"id":"305","status_code":"FINISHED"}"#),
            Fixture("POST", "/v27.0/301/media_publish", #"{"id":"303"}"#)
        ])), store: store)
        let professional = try await instagram.connect(InstagramAuthorization(
            clientID: "example-client", redirectURI: redirect, browser: exampleBrowser, exchange: exchange
        ))
        let photos = ["first", "second"].map { SocialMedia.imageURL(URL(string: "https://media.example/\($0).jpg")!) }
        let imagePost = try await instagram.publishMedia(photos, draft: draft, as: professional.id)
        print("Simulated Instagram carousel publish: \(imagePost.id)")
    }

    if platform == nil || platform == .linkedIn {
        let linkedin = SocialClient(adapter: LinkedInAdapter(transport: ExampleTransport([
            Fixture("GET", "/v2/userinfo", #"{"sub":"demo","name":"Demo Member"}"#),
            Fixture("POST", "/rest/images", #"{"value":{"image":"urn:li:image:a","uploadUrl":"https://www.linkedin.com/dms-uploads/a?fixture=1","uploadUrlExpiresAt":4102444800000}}"#),
            Fixture("PUT", "/dms-uploads/a", "", status: 201),
            Fixture("POST", "/rest/images", #"{"value":{"image":"urn:li:image:b","uploadUrl":"https://www.linkedin.com/dms-uploads/b?fixture=1","uploadUrlExpiresAt":4102444800000}}"#),
            Fixture("PUT", "/dms-uploads/b", "", status: 201),
            Fixture("POST", "/rest/posts", "", status: 201, headers: ["x-restli-id": "urn:li:share:401"])
        ]), oauthBroker: exchange), store: store)
        let member = try await linkedin.connect(.init(
            clientID: "example-client", redirectURI: redirect, browser: exampleBrowser
        ))
        let memberPost = try await linkedin.publishMedia([fixtureImage, fixtureImage], draft: draft, as: member.id)
        print("Simulated LinkedIn multi-image publish: \(memberPost.id)")
    }

    if platform == nil || platform == .x {
        let x = SocialClient(adapter: XAdapter(clientID: "example-client", includeMediaWriteScope: true, transport: ExampleTransport([
            Fixture("POST", "/2/oauth2/token", #"{"token_type":"bearer","expires_in":7200,"access_token":"example-access","refresh_token":"example-refresh","scope":"tweet.read users.read tweet.write like.write offline.access media.write"}"#),
            Fixture("GET", "/2/users/me", #"{"data":{"id":"501","username":"demo"}}"#),
            Fixture("POST", "/2/media/upload", #"{"data":{"id":"511"}}"#),
            Fixture("POST", "/2/tweets", #"{"data":{"id":"502","text":"Hello from SocialKit"}}"#)
        ])), store: store)
        let xAccount = try await x.connect(.init(redirectURI: redirect, browser: exampleBrowser))
        let xPost = try await x.publishMedia(fixtureImage, draft: draft, as: xAccount.id)
        print("Simulated X image publish: \(xPost.id)")
    }
}

// These bytes are fixture input. No adapter or provider decodes them during the example.
private let fixtureImage = SocialMedia.imageData(Data([0x89, 0x50, 0x4E, 0x47]), contentType: "image/png")

private func runMastodonExample(store: MemoryCredentialStore, draft: TextPost) async throws {
    func authorizationFixtures(id: String, name: String) -> [Fixture] {
        [
            Fixture("GET", "/.well-known/oauth-authorization-server",
                    #"{"scopes_supported":["profile","read:statuses","write:statuses","write:favourites"],"code_challenge_methods_supported":["S256"]}"#),
            Fixture("POST", "/api/v1/apps", #"{"client_id":"example-client","client_secret":"fixture-registration-secret"}"#),
            Fixture("POST", "/oauth/token", #"{"access_token":"fixture-\#(id)","token_type":"Bearer"}"#),
            Fixture("GET", "/api/v1/accounts/verify_credentials", #"{"id":"\#(id)","acct":"\#(name)"}"#)
        ]
    }
    let transport = ExampleTransport(authorizationFixtures(id: "601", name: "alice")
        + authorizationFixtures(id: "602", name: "bob") + [
            Fixture("POST", "/api/v1/statuses", #"{"id":"603","content":"<p>Hello from SocialKit</p>"}"#),
            Fixture("GET", "/api/v1/accounts/602/statuses", #"[{"id":"603","content":"<p>Hello from SocialKit</p>"}]"#)
        ])
    let client = SocialClient(adapter: MastodonAdapter(transport: transport), store: store)
    let authorization = MastodonAdapter.Authorization(
        server: URL(string: "https://mastodon.example")!,
        redirectURI: URL(string: "com.example.socialkit:/oauth/mastodon")!,
        forceLogin: true, browser: exampleBrowser
    )
    let alice = try await client.connect(authorization)
    let bob = try await client.connect(authorization)
    let selected = try await client.publish(draft, as: bob.id)
    let page = try await client.posts(as: bob.id)
    print("Simulated Mastodon switch from \(alice.username) to \(bob.username): \(selected.id), \(page.items.count) listed")
}
