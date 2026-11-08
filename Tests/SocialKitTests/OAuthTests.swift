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
