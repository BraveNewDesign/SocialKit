import SocialKit
import SwiftUI

/// Presents connection progress while the host supplies provider configuration and authorization.
public struct SocialConnectionButton: View {
    private let title: LocalizedStringKey
    private let connect: @MainActor () async throws -> SocialAccount
    private let onConnected: @MainActor (SocialAccount) -> Void
    @State private var task: Task<Void, Never>?
    @State private var result: SocialOperationResult = .idle

    public init(
        _ title: LocalizedStringKey = "Connect account",
        connect: @escaping @MainActor () async throws -> SocialAccount,
        onConnected: @escaping @MainActor (SocialAccount) -> Void = { _ in }
    ) {
        self.title = title
        self.connect = connect
        self.onConnected = onConnected
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(title, action: start)
                    .disabled(task != nil)
                if let task {
                    Button("Cancel") { task.cancel() }
                }
            }
            SocialOperationResultView(result)
        }
        .onDisappear { task?.cancel() }
    }

    private func start() {
        guard task == nil else { return }
        result = .working
        task = Task { @MainActor in
            defer { task = nil }
            do {
                let account = try await connect()
                result = .connected(account)
                onConnected(account)
            } catch is CancellationError {
                result = .cancelled
            } catch {
                result = .failed(error as? SocialError)
            }
        }
    }
}
