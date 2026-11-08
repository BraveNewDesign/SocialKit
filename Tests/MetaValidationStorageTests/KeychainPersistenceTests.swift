import Foundation
import Testing
import MetaValidationStorage
import SocialKit

@Suite("Meta validation Keychain storage")
struct KeychainPersistenceTests {
    @Test("credentials persist across store instances and can be removed")
    func persistenceAndRemoval() async throws {
        // A unique service keeps this synthetic fixture separate from real app data.
        let service = "com.bravenewdesign.socialkit.metavalidation.tests.\(UUID().uuidString)"
        let firstStore = MetaValidationCredentialStore(service: service)
        let account = SocialAccount(
            platform: .threads,
            server: URL(string: "https://graph.threads.net")!,
            remoteID: "synthetic-user",
            username: "synthetic"
        )
        let fixture = SocialCredential(
            account: account,
            accessToken: "synthetic-access-token",
            refreshToken: "synthetic-refresh-token"
        )

        try await firstStore.save(fixture)
        do {
            let secondStore = MetaValidationCredentialStore(service: service)
            let restored = try await secondStore.credential(for: account.id)
            #expect(restored?.account == account)
            #expect(restored?.accessToken == "synthetic-access-token")
            #expect(restored?.refreshToken == "synthetic-refresh-token")
            #expect(try await secondStore.accounts() == [account])

            try await secondStore.remove(account.id)
            #expect(try await firstStore.credential(for: account.id) == nil)
            #expect(try await firstStore.accounts().isEmpty)
        } catch {
            try? await firstStore.remove(account.id)
            throw error
        }
    }
}
