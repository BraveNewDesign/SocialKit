import SocialKit
import SwiftUI

public enum SocialOperationResult: Sendable {
    case idle
    case working
    case connected(SocialAccount)
    case published(SocialPost)
    case cancelled
    case failed(SocialError?)
}

public struct SocialOperationResultView: View {
    private let result: SocialOperationResult

    public init(_ result: SocialOperationResult) {
        self.result = result
    }

    public var body: some View {
        switch result {
        case .idle:
            EmptyView()
        case .working:
            ProgressView("Working…")
        case .connected(let account):
            Label("Connected as \(account.username)", systemImage: "checkmark.circle")
        case .published(let post):
            if let url = post.url, url.scheme?.lowercased() == "https", url.host != nil,
               url.user == nil, url.password == nil {
                Link(destination: url) {
                    Label("View published post", systemImage: "arrow.up.right.square")
                }
            } else {
                Label("Post published", systemImage: "checkmark.circle")
            }
        case .cancelled:
            Label("Cancelled", systemImage: "xmark.circle")
        case .failed(.publishOutcomeUnknown):
            Label("The provider may have published this post. Check before sending again.",
                  systemImage: "exclamationmark.triangle")
        case .failed(let error):
            Label(error?.errorDescription ?? "The operation could not be completed.",
                  systemImage: "exclamationmark.circle")
        }
    }
}
