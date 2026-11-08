#if os(macOS)
import Foundation
import MetaValidationOAuth
import MetaValidationStorage
import Observation
import SocialKit

enum Provider: String, CaseIterable, Identifiable {
    case facebook = "Facebook Pages"
    case threads = "Threads"
    case instagram = "Instagram"

    var id: Self { self }

    var platform: SocialPlatform {
        switch self {
        case .facebook: .facebookPages
        case .threads: .threads
        case .instagram: .instagram
        }
    }

    var readScopes: Set<String> {
        switch self {
        case .facebook: ["pages_show_list", "pages_read_engagement", "pages_read_user_content"]
        case .threads: ["threads_basic", "threads_read_replies"]
        case .instagram: ["instagram_business_basic", "instagram_business_manage_comments"]
        }
    }

    var publishScope: String {
        switch self {
        case .facebook: "pages_manage_posts"
        case .threads: "threads_content_publish"
        case .instagram: "instagram_business_content_publish"
        }
    }
}

struct PublishIntent: Sendable {
    let account: SocialAccount
    let draft: TextPost
    let image: URL?
}

@MainActor @Observable
final class ValidationModel {
    private let store: any CredentialStore
    private let facebookAdapter = FacebookPagesAdapter()
    private let threadsAdapter = ThreadsAdapter()
    private let instagramAdapter = InstagramAdapter()
    private let facebook: SocialClient<FacebookPagesAdapter>
    private let threads: SocialClient<ThreadsAdapter>
    private let instagram: SocialClient<InstagramAdapter>

    private(set) var accounts: [SocialAccount] = []
    private(set) var discoveredPages: [SocialAccount] = []
    private(set) var scopes: Set<String>?
    private(set) var capabilities: Set<SocialCapability> = []
    private(set) var expiration: Date?
    private(set) var validity = "Connect or select an account."
    private(set) var verifiedAccount: SocialAccount.ID?
    private(set) var status = "Choose Facebook Pages to begin."
    private(set) var posts: [SocialPost] = []
    private(set) var comments: [SocialPost] = []
    private(set) var busy = false
    private(set) var canCancel = false
    private(set) var uncertainAccounts: Set<SocialAccount.ID> = []
    var selected: SocialAccount.ID?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(store: any CredentialStore) {
        self.store = store
        facebook = SocialClient(adapter: facebookAdapter, store: store)
        threads = SocialClient(adapter: threadsAdapter, store: store)
        instagram = SocialClient(adapter: instagramAdapter, store: store)
    }

    var account: SocialAccount? { accounts.first { $0.id == selected } }

    func load(_ provider: Provider) {
        resetAccountDetails()
        discoveredPages = []
        accounts = []
        selected = nil
        run("Loaded local accounts") { try await self.reload(provider, selecting: nil) }
    }

    func selectAccount() {
        resetAccountDetails()
        run("Loaded account details") { try await self.loadDetails() }
    }

    func cancel() { task?.cancel() }

    func clearDiscoveredPages() { discoveredPages = [] }

    func reportInvalidConfiguration() {
        status = "Check the HTTPS callback, bridge URL and bridge credential."
    }

    func discoverPages(_ token: OAuthToken) {
        discoveredPages = []
        run("Discovered Facebook Pages", cancellable: true) {
            self.discoveredPages = try await self.facebookAdapter.discoverPages(token)
            self.status = "Discovered \(self.discoveredPages.count) Facebook Page(s)."
        }
    }

    func importToken(_ token: OAuthToken, provider: Provider, pageID: String) {
        run("Verified profile and saved development credential", cancellable: true) {
            let credential: SocialCredential
            switch provider {
            case .facebook: credential = try await self.facebookAdapter.developmentCredential(token, pageID: pageID)
            case .threads: credential = try await self.threadsAdapter.developmentCredential(token)
            case .instagram: credential = try await self.instagramAdapter.developmentCredential(token)
            }
            try Task.checkCancellation()
            try await self.store.save(credential)
            try await self.reload(provider, selecting: credential.account.id, verified: true)
        }
    }

    func connect(
        _ provider: Provider, clientID: String, pageID: String, redirect: URL,
        exchange: any ConfidentialOAuthExchange, browser: @escaping OAuthBrowser, requestPublishing: Bool
    ) {
        run("Verified profile and saved OAuth credential", cancellable: true) {
            var scopes = provider.readScopes
            if requestPublishing { scopes.insert(provider.publishScope) }
            let account: SocialAccount
            switch provider {
            case .facebook:
                account = try await self.facebook.connect(.init(
                    clientID: clientID, redirectURI: redirect, pageID: pageID,
                    scopes: scopes, browser: browser, exchange: exchange
                ))
            case .threads:
                account = try await self.threads.connect(.init(
                    clientID: clientID, redirectURI: redirect, scopes: scopes, browser: browser, exchange: exchange
                ))
            case .instagram:
                account = try await self.instagram.connect(.init(
                    clientID: clientID, redirectURI: redirect, scopes: scopes, browser: browser, exchange: exchange
                ))
            }
            try await self.reload(provider, selecting: account.id, verified: provider != .facebook)
        }
    }

    func checkProfile() {
        guard let account else { return }
        run("Profile decoded successfully", accountID: account.id) {
            guard let credential = try await self.store.credential(for: account.id),
                  credential.expiresAt.map({ $0 > Date() }) != false else {
                throw SocialError.authenticationRequired
            }
            let profile: SocialAccount
            switch account.platform {
            case .facebookPages: profile = try await self.facebookAdapter.profile(credential: credential)
            case .threads: profile = try await self.threadsAdapter.profile(credential: credential)
            case .instagram: profile = try await self.instagramAdapter.profile(credential: credential)
            default: throw SocialError.invalidInput
            }
            guard profile.id == account.id else { throw SocialError.invalidResponse }
            self.verifiedAccount = account.id
            self.validity = "Accepted by Meta on the latest profile check."
            self.status = "Profile decoded for \(profile.username)."
        }
    }

    func listPosts() {
        guard let id = selected else { return }
        posts = []
        comments = []
        run("Posts decoded", accountID: id) {
            let page: SocialPage<SocialPost>
            switch id.platform {
            case .facebookPages: page = try await self.facebook.posts(as: id)
            case .threads: page = try await self.threads.posts(as: id)
            case .instagram: page = try await self.instagram.posts(as: id)
            default: throw SocialError.invalidInput
            }
            self.posts = page.items
            self.status = "Decoded \(page.items.count) post(s). More pages: \(page.nextCursor != nil ? "yes" : "no")."
        }
    }

    func fetchPost(_ postID: String) {
        guard let id = selected else { return }
        run("Post decoded", accountID: id) {
            let post: SocialPost
            switch id.platform {
            case .facebookPages: post = try await self.facebook.post(id: postID, as: id)
            case .threads: post = try await self.threads.post(id: postID, as: id)
            case .instagram: post = try await self.instagram.post(id: postID, as: id)
            default: throw SocialError.invalidInput
            }
            self.status = "Post \(post.id) decoded with \(post.text.count) character(s) and \(post.media.count) attachment(s)."
        }
    }

    func listComments(_ postID: String) {
        guard let id = selected else { return }
        comments = []
        run("Comments decoded", accountID: id) {
            let page: SocialPage<SocialPost>
            switch id.platform {
            case .facebookPages: page = try await self.facebook.replies(to: postID, as: id)
            case .threads: page = try await self.threads.replies(to: postID, as: id)
            case .instagram: page = try await self.instagram.replies(to: postID, as: id)
            default: throw SocialError.invalidInput
            }
            self.comments = page.items
            self.status = "Decoded \(page.items.count) comment(s) or replies. More pages: \(page.nextCursor != nil ? "yes" : "no")."
        }
    }

    func disconnect(_ provider: Provider) {
        guard let id = selected else { return }
        run("Removed local Keychain credential") {
            switch provider {
            case .facebook: try await self.facebook.disconnect(id)
            case .threads: try await self.threads.disconnect(id)
            case .instagram: try await self.instagram.disconnect(id)
            }
            try await self.reload(provider, selecting: nil)
        }
    }

    func publish(_ intent: PublishIntent) {
        let id = intent.account.id
        guard selected == id, verifiedAccount == id, !uncertainAccounts.contains(id),
              let provider = Provider.allCases.first(where: { $0.platform == id.platform }),
              scopes?.contains(provider.publishScope) == true else { return }
        run("Post published", accountID: id) {
            let post: SocialPost
            switch id.platform {
            case .facebookPages: post = try await self.facebook.publish(intent.draft, as: id)
            case .threads: post = try await self.threads.publish(intent.draft, as: id)
            case .instagram:
                guard let image = intent.image else { throw SocialError.invalidInput }
                post = try await self.instagram.publishMedia(.imageURL(image), draft: intent.draft, as: id)
            default: throw SocialError.invalidInput
            }
            self.status = "Meta returned published post ID \(post.id). Check the provider feed."
        }
    }

    func acknowledgeReconciliation() {
        guard let selected else { return }
        uncertainAccounts.remove(selected)
        status = "Reconciliation acknowledged."
    }

    private func reload(_ provider: Provider, selecting id: SocialAccount.ID?, verified: Bool = false) async throws {
        accounts = try await store.accounts().filter { $0.platform == provider.platform }.sorted {
            ($0.username, $0.remoteID) < ($1.username, $1.remoteID)
        }
        resetAccountDetails()
        selected = accounts.first { $0.id == id }?.id ?? accounts.first?.id
        try await loadDetails()
        if verified, selected == id {
            verifiedAccount = id
            validity = "Accepted by Meta during connection."
        }
    }

    private func loadDetails() async throws {
        guard let id = selected, let credential = try await store.credential(for: id) else { return }
        scopes = credential.grantedScopes
        expiration = credential.expiresAt
        validity = expiration.map { $0 <= Date() } == true
            ? "Expired locally. Reconnect with a fresh credential."
            : "Stored in Keychain. Run Check Profile to verify with Meta."
        capabilities = switch id.platform {
        case .facebookPages: try await facebook.capabilities(for: id)
        case .threads: try await threads.capabilities(for: id)
        case .instagram: try await instagram.capabilities(for: id)
        default: []
        }
    }

    private func resetAccountDetails() {
        scopes = nil
        capabilities = []
        expiration = nil
        verifiedAccount = nil
        validity = "Connect or select an account."
        posts = []
        comments = []
    }

    private func run(
        _ success: String, accountID: SocialAccount.ID? = nil, cancellable: Bool = false,
        action: @escaping @MainActor () async throws -> Void
    ) {
        guard !busy else { return }
        busy = true
        canCancel = cancellable
        status = "Working…"
        task = Task {
            defer {
                busy = false
                canCancel = false
                task = nil
            }
            do {
                try await action()
                if status == "Working…" { status = success + "." }
            } catch is CancellationError {
                status = "Cancelled."
            } catch let error as SocialError {
                if error == .authenticationRequired, accountID == selected, accountID != nil {
                    verifiedAccount = nil
                    validity = "Credential expired, revoked, or rejected by Meta."
                }
                if case .publishOutcomeUnknown = error, let accountID { uncertainAccounts.insert(accountID) }
                status = error.errorDescription ?? "Operation failed."
            } catch {
                status = "Operation failed."
            }
        }
    }
}
#endif
