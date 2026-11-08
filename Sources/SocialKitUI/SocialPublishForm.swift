import SocialKit
import SwiftUI

/// A native composer. The host owns the account selection and any attachment picker.
public struct SocialPublishForm: View {
    @Binding private var text: String
    private let media: [SocialMedia]
    private let capabilities: Set<SocialCapability>
    private let publish: @MainActor (TextPost, [SocialMedia]) async throws -> SocialPost
    @State private var task: Task<Void, Never>?
    @State private var result: SocialOperationResult = .idle
    @State private var needsReconciliation = false

    public init(
        text: Binding<String>,
        media: [SocialMedia] = [],
        capabilities: Set<SocialCapability>,
        publish: @escaping @MainActor (TextPost, [SocialMedia]) async throws -> SocialPost
    ) {
        _text = text
        self.media = media
        self.capabilities = capabilities
        self.publish = publish
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Post text", text: $text, axis: .vertical)
                .lineLimit(3...8)
                .disabled(task != nil)
            HStack {
                Button("Publish", action: submit)
                    .disabled(!canPublish)
                if let task {
                    Button("Cancel") { task.cancel() }
                }
            }
            SocialOperationResultView(result)
            if needsReconciliation {
                Button("I checked the provider") {
                    needsReconciliation = false
                    result = .idle
                }
            }
        }
        .onDisappear { task?.cancel() }
    }

    private var canPublish: Bool {
        guard task == nil, !needsReconciliation else { return false }
        switch media.count {
        case 0:
            return capabilities.contains(.publishText)
                && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case 1:
            return capabilities.contains(.publishMedia)
        default:
            return capabilities.contains(.publishMultipleMedia)
        }
    }

    private func submit() {
        guard canPublish else { return }
        let draft = TextPost(text: text)
        result = .working
        task = Task { @MainActor in
            defer { task = nil }
            do {
                let post = try await publish(draft, media)
                if text == draft.text { text = "" }
                result = .published(post)
            } catch is CancellationError {
                result = .cancelled
            } catch let error as SocialError {
                if case .publishOutcomeUnknown = error { needsReconciliation = true }
                result = .failed(error)
            } catch {
                result = .failed(nil)
            }
        }
    }
}
