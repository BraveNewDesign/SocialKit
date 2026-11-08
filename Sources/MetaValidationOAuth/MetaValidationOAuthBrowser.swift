#if os(macOS)
import AppKit
import AuthenticationServices
import Foundation
import SocialKit

/// Creates a native system browser flow for HTTPS redirect URIs.
public enum MetaValidationOAuthBrowser {
    /// Suitable for `ThreadsAuthorization`, `FacebookPagesAuthorization`, or `InstagramAuthorization`.
    /// The callback URI must be HTTPS; macOS associates the session with its host and path.
    public static func make() -> OAuthBrowser {
        { authorizationURL, redirectURL in
            try await Self.authenticate(authorizationURL: authorizationURL, redirectURL: redirectURL)
        }
    }

    @MainActor
    private static func authenticate(authorizationURL: URL, redirectURL: URL) async throws -> URL {
        guard #available(macOS 14.4, *),
              let components = URLComponents(url: redirectURL, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw SocialError.authorizationFailed
        }
        let callback = ASWebAuthenticationSession.Callback.https(host: host, path: components.path.isEmpty ? "/" : components.path)

        try Task.checkCancellation()
        let anchorProvider = BrowserAnchorProvider()
        let completion = BrowserCompletion()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                let session = ASWebAuthenticationSession(url: authorizationURL, callback: callback) { url, error in
                    anchorProvider.session = nil
                    if let url {
                        completion.succeed(url)
                    } else {
                        // Never forward Apple's error text or callback URL into a user-visible error.
                        let nsError = error as NSError?
                        if nsError?.domain == ASWebAuthenticationSessionErrorDomain,
                           nsError?.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                            completion.fail(CancellationError())
                        } else {
                            completion.fail(SocialError.authorizationFailed)
                        }
                    }
                }
                session.presentationContextProvider = anchorProvider
                session.prefersEphemeralWebBrowserSession = true
                anchorProvider.session = session
                guard session.start() else {
                    anchorProvider.session = nil
                    completion.fail(SocialError.authorizationFailed)
                    return
                }
            }
        } onCancel: {
            completion.fail(CancellationError())
            Task { @MainActor in anchorProvider.session?.cancel() }
        }
    }
}

private final class BrowserCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var completed = false

    func install(_ continuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        if completed {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func succeed(_ url: URL) { finish(.success(url)) }
    func fail(_ error: Error) { finish(.failure(error)) }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

@MainActor
private final class BrowserAnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    var session: ASWebAuthenticationSession?

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow ?? NSWindow()
    }
}
#endif
