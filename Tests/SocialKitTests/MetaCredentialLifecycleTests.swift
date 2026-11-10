import Foundation
import Testing
@testable import SocialKit

@Suite("Meta credential lifecycle")
struct MetaCredentialLifecycleTests {
    @Test func legacyRecordsDecodeWithoutInventingExpiryOrEligibility() throws {
        struct LegacyCredential: Codable {
            let account: SocialAccount
            let accessToken: String
            let refreshToken: String?
            let expiresAt: Date?
        }

        let data = try JSONEncoder().encode(LegacyCredential(account: account(.instagram), accessToken: "legacy",
                                                             refreshToken: "generic-refresh", expiresAt: nil))
        let credential = try JSONDecoder().decode(SocialCredential.self, from: data)
        #expect(credential.expiresAt == nil)
        #expect(credential.facebookPageSourceGrant == nil)
        #expect(credential.metaLongLivedRefreshEligibleAt == nil)
        #expect(!credential.canRefreshMetaLongLivedToken())
        #expect(credential.refreshToken == "generic-refresh")
    }

    @Test func refreshRequiresConfirmedMatureUnexpiredToken() async {
        let transport = LifecycleTransport([])
        let threads = ThreadsAdapter(transport: transport)
        let account = account(.threads)
        let now = Date()
        let unknown = SocialCredential(account: account, accessToken: "unknown")
        let fresh = SocialCredential(account: account, accessToken: "fresh", expiresAt: .distantFuture,
                                     metaLongLivedRefreshEligibleAt: .distantFuture)
        let expired = SocialCredential(account: account, accessToken: "expired", expiresAt: now,
                                       metaLongLivedRefreshEligibleAt: .distantPast)

        for credential in [unknown, fresh] {
            await #expect(throws: SocialError.unsupported(.refreshSession)) {
                try await threads.refresh(credential)
            }
        }
        await #expect(throws: SocialError.authenticationRequired) { try await threads.refresh(expired) }
        #expect(await transport.calls == 0)
    }

    @Test func pageCanBeRecoveredWithoutInventingItsExpiryOrLeakingSourceGrant() async throws {
        let transport = LifecycleTransport([
            response(#"{"data":[{"permission":"pages_manage_posts","status":"granted"}]}"#),
            response(#"{"data":[{"id":"page1","name":"Page","access_token":"renewed-page","tasks":["CREATE_CONTENT"]}]}"#),
            response(#"{"id":"page1","name":"Page"}"#)
        ])
        let adapter = FacebookPagesAdapter(transport: transport)
        let previous = SocialCredential(account: account(.facebookPages), accessToken: "existing-page",
                                        facebookPageSourceGrant: OAuthToken(accessToken: "source-grant",
                                                                            expiresAt: .distantFuture))
        let store = MemoryCredentialStore()
        let client = SocialClient(adapter: adapter, store: store)
        try await client.saveVerifiedCredential(previous)
        _ = try await client.refresh(previous.account.id)
        let renewed = try #require(await store.credential(for: previous.account.id))
        #expect(renewed.account.id == previous.account.id)
        #expect(renewed.accessToken == "renewed-page")
        #expect(renewed.expiresAt == nil)
        #expect(renewed.facebookPageSourceGrant?.expiresAt == .distantFuture)
        #expect(!String(reflecting: renewed).contains("source-grant"))
        #expect(!String(describing: renewed).contains("renewed-page"))
        #expect(renewed.customMirror.children.map(\.label) == ["account"])
    }

    @Test func expiredSourceGrantCannotRecoverPageAndDoesNotChangePageExpiry() async {
        let transport = LifecycleTransport([])
        let credential = SocialCredential(account: account(.facebookPages), accessToken: "page-token",
                                          facebookPageSourceGrant: OAuthToken(accessToken: "expired-user",
                                                                              expiresAt: .distantPast))
        #expect(credential.expiresAt == nil)
        await #expect(throws: SocialError.authenticationRequired) {
            try await FacebookPagesAdapter(transport: transport).refresh(credential)
        }
        #expect(await transport.calls == 0)
    }

    @Test func refreshKeepsTheExistingCredentialOnTransientOrRevokedResponses() async throws {
        let transport = LifecycleTransport([
            response(#"{"error":{"code":4}}"#, status: 429),
            response(#"{"error":{"code":190,"message":"do not expose credential details"}}"#, status: 400)
        ])
        let store = MemoryCredentialStore()
        let client = SocialClient(adapter: InstagramAdapter(transport: transport), store: store)
        let credential = SocialCredential(account: account(.instagram), accessToken: "existing-token",
                                          expiresAt: .distantFuture, metaLongLivedRefreshEligibleAt: .distantPast)
        try await client.saveVerifiedCredential(credential)
        await #expect(throws: SocialError.rateLimited(retryAfter: nil)) {
            try await client.refresh(credential.account.id)
        }
        #expect(await store.credential(for: credential.account.id)?.accessToken == "existing-token")
        await #expect(throws: SocialError.authenticationRequired) {
            try await client.refresh(credential.account.id)
        }
        #expect(await store.credential(for: credential.account.id)?.accessToken == "existing-token")
    }

    private func account(_ platform: SocialPlatform) -> SocialAccount {
        let server: String
        switch platform {
        case .facebookPages: server = "https://graph.facebook.com"
        case .threads: server = "https://graph.threads.net"
        default: server = "https://graph.instagram.com"
        }
        return SocialAccount(platform: platform, server: URL(string: server)!, remoteID: "page1", username: "Page")
    }

    private func response(_ json: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(statusCode: status, body: Data(json.utf8))
    }
}

private actor LifecycleTransport: HTTPTransport {
    private var responses: [HTTPResponse]
    private(set) var calls = 0

    init(_ responses: [HTTPResponse]) { self.responses = responses }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        calls += 1
        guard !responses.isEmpty else { throw SocialError.transportFailure }
        return responses.removeFirst()
    }
}
