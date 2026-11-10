import Foundation
import Testing
@testable import SocialKit

@Suite("Meta publishing checkpoints")
struct MetaCheckpointTests {
    @Test func resumesInstagramContainerWithoutCreatingItAgain() async throws {
        let transport = CheckpointTransport([#"{"id":"container","status_code":"FINISHED"}"#, #"{"id":"post"}"#])
        let adapter = InstagramAdapter(transport: transport, pollIntervalNanoseconds: 0)
        let receipt = try MetaPublishingCheckpoint(containerID: "container")
        let saved = CheckpointRecorder()
        let post = try await adapter.publishCheckpointed(
            [.imageURL(URL(string: "https://example.com/photo.jpg")!)], draft: TextPost(text: "Caption"),
            credential: credential(.instagram, host: "graph.instagram.com"), checkpoint: receipt, save: { await saved.append($0) }
        )
        #expect(post.id == "post")
        #expect(await transport.methods == ["GET", "POST"])
        #expect(await saved.checkpoints.map(\.publishStarted) == [true])
    }

    @Test func uncertainThreadsPublishIsReconciledWithReadOnlyRequest() async throws {
        let transport = CheckpointTransport([
            #"{"id":"container"}"#, #"{"id":"container","status":"FINISHED"}"#,
            #"{}"#, #"{"id":"container","status":"PUBLISHED"}"#
        ])
        let adapter = ThreadsAdapter(transport: transport, pollIntervalNanoseconds: 0)
        let draft = TextPost(text: "Hello")
        let account = credential(.threads, host: "graph.threads.net")
        let saved = CheckpointRecorder()
        await #expect(throws: SocialError.publishOutcomeUnknown(draft.idempotencyKey)) {
            try await adapter.publishCheckpointed([], draft: draft, credential: account, checkpoint: nil, save: { await saved.append($0) })
        }
        let checkpoints = await saved.checkpoints
        #expect(checkpoints.map(\.publishStarted) == [false, true])
        let receipt = try #require(checkpoints.last)
        await #expect(throws: SocialError.publishOutcomeUnknown(draft.idempotencyKey)) {
            try await adapter.publishCheckpointed([], draft: draft, credential: account, checkpoint: receipt, save: { await saved.append($0) })
        }
        #expect(try await adapter.wasPublished(receipt, credential: account))
        #expect(await transport.methods == ["POST", "GET", "POST", "GET"])
        let json = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
        #expect(!json.contains(account.accessToken))
        #expect(!json.contains(draft.text))
    }

    @Test func failureToPersistPublishBoundaryPreventsWrite() async throws {
        let transport = CheckpointTransport([#"{"id":"container","status":"FINISHED"}"#])
        let adapter = ThreadsAdapter(transport: transport, pollIntervalNanoseconds: 0)
        let receipt = try MetaPublishingCheckpoint(containerID: "container")
        await #expect(throws: CancellationError.self) {
            try await adapter.publishCheckpointed([], draft: TextPost(text: "Hello"),
                credential: credential(.threads, host: "graph.threads.net"), checkpoint: receipt
            ) { _ in throw CancellationError() }
        }
        #expect(await transport.methods == ["GET"])
    }

    private func credential(_ platform: SocialPlatform, host: String) -> SocialCredential {
        SocialCredential(account: SocialAccount(platform: platform, server: URL(string: "https://\(host)")!,
                                               remoteID: "account", username: "owner"), accessToken: "fixture-secret")
    }
}

private actor CheckpointRecorder {
    private(set) var checkpoints: [MetaPublishingCheckpoint] = []
    func append(_ checkpoint: MetaPublishingCheckpoint) { checkpoints.append(checkpoint) }
}

private actor CheckpointTransport: HTTPTransport {
    private var bodies: [String]
    private(set) var methods: [String] = []

    init(_ bodies: [String]) { self.bodies = bodies }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        methods.append(request.httpMethod ?? "")
        guard !bodies.isEmpty else { throw SocialError.transportFailure }
        return HTTPResponse(statusCode: 200, headers: [:], body: Data(bodies.removeFirst().utf8))
    }
}
