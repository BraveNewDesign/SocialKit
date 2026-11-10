import Foundation

/// A credential-free receipt for a staged Meta post. Persist it with the original draft and account.
public struct MetaPublishingCheckpoint: Codable, Equatable, Sendable {
    public let containerID: String
    public let publishStarted: Bool

    init(containerID: String, publishStarted: Bool = false) throws {
        self.containerID = try metaPathID(containerID)
        self.publishStarted = publishStarted
    }
}

/// The callback must persist each checkpoint before returning. An error aborts the operation.
public typealias MetaPublishingCheckpointWriter = @Sendable (MetaPublishingCheckpoint) async throws -> Void

protocol MetaCheckpointPublishing: SocialAdapter {
    func publishCheckpointed(
        _ media: [SocialMedia], draft: TextPost, credential: SocialCredential,
        checkpoint: MetaPublishingCheckpoint?, save: @escaping MetaPublishingCheckpointWriter
    ) async throws -> SocialPost

    func wasPublished(_ checkpoint: MetaPublishingCheckpoint, credential: SocialCredential) async throws -> Bool
}

func metaPublishingContainer(
    checkpoint: MetaPublishingCheckpoint?, draft: TextPost,
    save: MetaPublishingCheckpointWriter?, create: () async throws -> String
) async throws -> String {
    if let checkpoint {
        guard !checkpoint.publishStarted else { throw SocialError.publishOutcomeUnknown(draft.idempotencyKey) }
        return try metaPathID(checkpoint.containerID)
    }
    let staged = try await MetaPublishingCheckpoint(containerID: create())
    try await save?(staged)
    return staged.containerID
}

func beginMetaPublish(_ id: String, save: MetaPublishingCheckpointWriter?) async throws {
    try Task.checkCancellation()
    try await save?(MetaPublishingCheckpoint(containerID: id, publishStarted: true))
    try Task.checkCancellation()
}
