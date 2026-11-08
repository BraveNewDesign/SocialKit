import Foundation
import Testing
@testable import SocialKit

private let testServer = URL(string: "https://social.example")!

private struct MockAdapter: SocialAdapter {
    let platform: SocialPlatform = .mastodon
    let capabilities: Set<SocialCapability> = [.publishText, .refreshSession]
    var onConnect: (@Sendable () async -> Void)? = nil
    var onPublish: (@Sendable (SocialCredential) async -> Void)?

    func connect(_ name: String) async throws -> SocialCredential {
        await onConnect?()
        let account = SocialAccount(platform: platform, server: testServer, remoteID: name, username: name)
        return SocialCredential(account: account, accessToken: "secret-\(name)")
    }

    func refresh(_ credential: SocialCredential) async throws -> SocialCredential {
        SocialCredential(account: credential.account, accessToken: "refreshed")
    }

    func publish(_ draft: TextPost, credential: SocialCredential) async throws -> SocialPost {
        await onPublish?(credential)
        return SocialPost(id: credential.account.remoteID, text: draft.text)
    }
}

@Test func accountMutationIsBlockedWhilePublishing() async throws {
    let started = AsyncStream<Void>.makeStream()
    let resume = AsyncStream<Void>.makeStream()
    let adapter = MockAdapter(onPublish: { credential in
        guard credential.account.remoteID == "alice" else { return }
        started.continuation.finish()
        for await _ in resume.stream {}
    })
    let client = SocialClient(adapter: adapter, store: MemoryCredentialStore())
    let alice = try await client.connect("alice")
    let bob = try await client.connect("bob")
    let draft = TextPost(text: "Hello")

    async let post = client.publish(draft, as: alice.id)
    for await _ in started.stream {}

    await #expect(throws: SocialError.accountBusy) { try await client.disconnect(alice.id) }
    await #expect(throws: SocialError.accountBusy) { try await client.refresh(alice.id) }
    #expect(try await client.publish(draft, as: bob.id).id == "bob")

    resume.continuation.finish()
    let result = try await post
    #expect(result.id == "alice")
    try await client.disconnect(alice.id)
}

@Test func accountsStaySeparateAndCanBeDisconnected() async throws {
    let store = MemoryCredentialStore()
    let client = SocialClient(adapter: MockAdapter(), store: store)
    let alice = try await client.connect("alice")
    let bob = try await client.connect("bob")
    let otherProvider = SocialAccount(platform: .bluesky, server: testServer, remoteID: "alice", username: "alice")
    await store.save(SocialCredential(account: otherProvider, accessToken: "separate"))

    #expect(try await client.accounts() == [alice, bob])
    #expect(try await client.publish(TextPost(text: "Hello"), as: bob.id).id == "bob")
    #expect(try await client.refresh(alice.id) == alice)
    #expect(await store.credential(for: alice.id)?.accessToken == "refreshed")
    #expect(await store.credential(for: bob.id)?.accessToken == "secret-bob")

    try await client.disconnect(alice.id)
    #expect(try await client.accounts() == [bob])
    #expect(await store.credential(for: otherProvider.id)?.accessToken == "separate")
    await #expect(throws: SocialError.authenticationRequired) {
        try await client.publish(TextPost(text: "Hello"), as: alice.id)
    }
}

@Test func unsupportedOperationsFailBeforeCredentialLookup() async {
    let client = SocialClient(adapter: MockAdapter(), store: MemoryCredentialStore())
    let id = SocialAccount.ID(platform: .mastodon, server: testServer, remoteID: "missing")
    await #expect(throws: SocialError.unsupported(.readPost)) {
        try await client.post(id: "1", as: id)
    }
}

@Test func credentialDiagnosticsRedactTokens() async throws {
    let credential = try await MockAdapter().connect("alice")
    #expect(!String(reflecting: credential).contains("secret-alice"))
    #expect(Mirror(reflecting: credential).children.map(\.label) == ["account"])
}

private actor ResponseTransport: HTTPTransport {
    let result: Result<HTTPResponse, URLError>
    private(set) var attempts = 0

    init(_ result: Result<HTTPResponse, URLError>) {
        self.result = result
    }

    func send(_ request: URLRequest) throws -> HTTPResponse {
        attempts += 1
        return try result.get()
    }
}

@Test(arguments: [303, 408, 500, 503])
func uncertainResponsesDoNotReplayPublish(status: Int) async {
    let transport = ResponseTransport(.success(HTTPResponse(statusCode: status)))
    let key = UUID()
    await #expect(throws: SocialError.publishOutcomeUnknown(key)) {
        try await HTTPClient(transport: transport).send(URLRequest(url: testServer), publishingKey: key)
    }
    #expect(await transport.attempts == 1)
}

@Test func timeoutProducesAmbiguousPublish() async {
    let transport = ResponseTransport(.failure(URLError(.timedOut)))
    let key = UUID()
    await #expect(throws: SocialError.publishOutcomeUnknown(key)) {
        try await HTTPClient(transport: transport).send(URLRequest(url: testServer), publishingKey: key)
    }
    #expect(await transport.attempts == 1)
}

@Test func rateLimitPreservesRetryAfter() async {
    let response = HTTPResponse(statusCode: 429, headers: ["retry-after": "45"])
    let transport = ResponseTransport(.success(response))
    await #expect(throws: SocialError.rateLimited(retryAfter: "45")) {
        try await HTTPClient(transport: transport).send(URLRequest(url: testServer), publishingKey: UUID())
    }
    #expect(await transport.attempts == 1)
}

@Test(arguments: [
    "http://social.example", "https://user@social.example", "https://social.example/path",
    "https://social.example?other=1", "https://social.example/#fragment"
])
func rejectsNonHTTPSOrigins(value: String) throws {
    let url = try #require(URL(string: value))
    #expect(throws: SocialError.invalidConfiguration) { try HTTPSOrigin(validating: url) }
}

@Test func normalizesOriginAndPreservesQueryValue() throws {
    let url = try #require(URL(string: "HTTPS://Social.Example:443/"))
    let origin = try HTTPSOrigin(validating: url)
    let endpoint = try origin.endpoint("/post", query: [URLQueryItem(name: "id", value: "a&b/#")])
    let components = try #require(URLComponents(url: endpoint, resolvingAgainstBaseURL: false))
    #expect(origin.url.absoluteString == "https://social.example")
    #expect(components.queryItems == [URLQueryItem(name: "id", value: "a&b/#")])
}

@Test(.timeLimit(.minutes(1))) func cancelledConnectionDoesNotSaveAndConcurrentConnectionIsBlocked() async throws {
    let started = AsyncStream<Void>.makeStream()
    let waiting = AsyncStream<Void>.makeStream()
    let adapter = MockAdapter(onConnect: {
        started.continuation.finish()
        for await _ in waiting.stream {}
    })
    let client = SocialClient(adapter: adapter, store: MemoryCredentialStore())
    let first = Task { try await client.connect("alice") }
    for await _ in started.stream {}
    await #expect(throws: SocialError.accountBusy) { try await client.connect("bob") }
    first.cancel()
    await #expect(throws: CancellationError.self) { try await first.value }
    #expect(try await client.accounts().isEmpty)
}
