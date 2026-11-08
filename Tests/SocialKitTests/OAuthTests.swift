import CryptoKit
import Foundation
import Testing
@testable import SocialKit

@Test func oauthBindsCallbackAndUsesS256() throws {
    let redirect = try #require(URL(string: "com.example.app:/oauth"))
    let transaction = try OAuthTransaction(redirectURI: redirect)
    let expected = Data(SHA256.hash(data: Data(transaction.verifier.utf8))).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    #expect(transaction.challenge == expected)
    #expect(transaction.verifier.count == 43)
    #expect(transaction.state != transaction.verifier)

    let callback = try OAuthForm.queryURL(redirect, parameters: [("state", transaction.state), ("code", "a+b /")])
    #expect(try transaction.code(from: callback) == "a+b /")
    #expect(callback.absoluteString.contains("a%2Bb%20%2F"))

    let wrongPath = try #require(URL(string: "com.example.app:/different"))
    let forged = try OAuthForm.queryURL(wrongPath, parameters: [("state", transaction.state), ("code", "code")])
    #expect(throws: SocialError.authorizationFailed) { try transaction.code(from: forged) }
}

@Test func oauthRejectsDuplicateStateAndProviderError() throws {
    let redirect = try #require(URL(string: "https://example.com/oauth"))
    let transaction = try OAuthTransaction(redirectURI: redirect)
    let correct = [("state", transaction.state), ("code", "code")]
    for extra in [("state", "wrong"), ("error", "access_denied")] {
        let callback = try OAuthForm.queryURL(redirect, parameters: correct + [extra])
        #expect(throws: SocialError.authorizationFailed) { try transaction.code(from: callback) }
    }
}

@Test func legacyCredentialDecodesWithoutScopeOrExpiry() throws {
    let fixture = Data("""
        {"account":{"id":{"platform":"mastodon","server":"https://social.example","remoteID":"10"},
         "username":"user"},"accessToken":"fixture-token"}
        """.utf8)
    let credential = try JSONDecoder().decode(SocialCredential.self, from: fixture)
    #expect(credential.account.remoteID == "10")
    #expect(credential.grantedScopes == nil)
    #expect(credential.expiresAt == nil)
    #expect(Mirror(reflecting: credential.oauthToken).children.isEmpty)
}

private struct ScopedAdapter: SocialAdapter {
    let platform: SocialPlatform = .x
    let capabilities: Set<SocialCapability> = [.publishText, .refreshSession]

    func connect(_ authorization: SocialCredential) async throws -> SocialCredential { authorization }

    func capabilities(for credential: SocialCredential) -> Set<SocialCapability> {
        credential.grantedScopes?.contains("write") == true ? capabilities : [.refreshSession]
    }

    func publish(_ draft: TextPost, credential: SocialCredential) async throws -> SocialPost {
        SocialPost(id: "new", text: draft.text)
    }

    func refresh(_ credential: SocialCredential) async throws -> SocialCredential {
        SocialCredential(account: credential.account, accessToken: "renewed", grantedScopes: ["write"])
    }
}

@Test func clientChecksGrantedScopesAndAllowsExpiredCredentialsToRefresh() async throws {
    let client = SocialClient(adapter: ScopedAdapter(), store: MemoryCredentialStore())
    let server = try #require(URL(string: "https://api.example"))
    let account = SocialAccount(platform: .x, server: server, remoteID: "123", username: "example")
    let draft = TextPost(text: "Hello")
    _ = try await client.connect(SocialCredential(account: account, accessToken: "fixture", grantedScopes: []))
    #expect(try await client.capabilities(for: account.id) == [.refreshSession])
    await #expect(throws: SocialError.permissionDenied) {
        try await client.publish(draft, as: account.id)
    }

    _ = try await client.connect(SocialCredential(
        account: account, accessToken: "expired", expiresAt: .distantPast, grantedScopes: ["write"]
    ))
    await #expect(throws: SocialError.authenticationRequired) {
        try await client.publish(draft, as: account.id)
    }
    _ = try await client.refresh(account.id)
    #expect(try await client.publish(draft, as: account.id).id == "new")
}
