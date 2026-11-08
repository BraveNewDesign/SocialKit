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

func runExpansionExamples() async throws {
    let store = MemoryCredentialStore()
    let draft = TextPost(text: "Hello from SocialKit")
    let redirect = URL(string: "https://app.example/oauth/callback")!
    let exchange = ExampleExchange()

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

    let facebook = SocialClient(adapter: FacebookPagesAdapter(transport: ExampleTransport([
        Fixture("GET", "/v27.0/me/accounts", #"{"data":[{"id":"201","name":"Demo Page","access_token":"page-token","tasks":["CREATE_CONTENT"]}]}"#),
        Fixture("POST", "/v27.0/201/feed", #"{"id":"201_202"}"#)
    ])), store: store)
    let page = try await facebook.connect(FacebookPagesAuthorization(
        clientID: "example-client", redirectURI: redirect, browser: exampleBrowser, exchange: exchange
    ))
    let pagePost = try await facebook.publish(draft, as: page.id)
    print("Simulated Facebook Page publish: \(pagePost.id)")

    let instagram = SocialClient(adapter: InstagramAdapter(transport: ExampleTransport([
        Fixture("GET", "/v27.0/me", #"{"id":"301","user_id":"301","username":"demo"}"#),
        Fixture("POST", "/v27.0/301/media", #"{"id":"302"}"#),
        Fixture("GET", "/v27.0/302", #"{"id":"302","status_code":"FINISHED"}"#),
        Fixture("POST", "/v27.0/301/media_publish", #"{"id":"303"}"#)
    ])), store: store)
    let professional = try await instagram.connect(InstagramAuthorization(
        clientID: "example-client", redirectURI: redirect, browser: exampleBrowser, exchange: exchange
    ))
    let image = SocialMedia.imageURL(URL(string: "https://media.example/photo.jpg")!)
    let imagePost = try await instagram.publishMedia(image, draft: draft, as: professional.id)
    print("Simulated Instagram image publish: \(imagePost.id)")

    let linkedin = SocialClient(adapter: LinkedInAdapter(transport: ExampleTransport([
        Fixture("GET", "/v2/userinfo", #"{"sub":"demo","name":"Demo Member"}"#),
        Fixture("POST", "/rest/posts", "", status: 201, headers: ["x-restli-id": "urn:li:share:401"])
    ]), oauthBroker: exchange), store: store)
    let member = try await linkedin.connect(.init(
        clientID: "example-client", redirectURI: redirect, browser: exampleBrowser
    ))
    let memberPost = try await linkedin.publish(draft, as: member.id)
    print("Simulated LinkedIn publish: \(memberPost.id)")

    let x = SocialClient(adapter: XAdapter(clientID: "example-client", transport: ExampleTransport([
        Fixture("POST", "/2/oauth2/token", #"{"token_type":"bearer","expires_in":7200,"access_token":"example-access","refresh_token":"example-refresh","scope":"tweet.read users.read tweet.write like.write offline.access"}"#),
        Fixture("GET", "/2/users/me", #"{"data":{"id":"501","username":"demo"}}"#),
        Fixture("POST", "/2/tweets", #"{"data":{"id":"502","text":"Hello from SocialKit"}}"#)
    ])), store: store)
    let xAccount = try await x.connect(.init(redirectURI: redirect, browser: exampleBrowser))
    let xPost = try await x.publish(draft, as: xAccount.id)
    print("Simulated X publish: \(xPost.id)")
}
