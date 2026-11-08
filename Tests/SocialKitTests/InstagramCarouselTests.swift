import Foundation
import Testing
@testable import SocialKit

@Suite("Instagram carousel publishing")
struct InstagramCarouselTests {
    @Test("Creates ordered image and video children, then one carousel and publishes it")
    func publishesOrderedCarousel() async throws {
        let transport = CarouselStub([
            response(#"{"id":"child_image"}"#),
            response(#"{"id":"child_video"}"#),
            response(#"{"id":"child_image","status_code":"FINISHED"}"#),
            response(#"{"id":"child_video","status_code":"FINISHED"}"#),
            response(#"{"id":"carousel"}"#),
            response(#"{"id":"carousel","status_code":"FINISHED"}"#),
            response(#"{"id":"published"}"#)
        ])
        let adapter = InstagramAdapter(transport: transport, pollIntervalNanoseconds: 0)
        let image = URL(string: "https://cdn.example.test/first.jpg")!
        let video = URL(string: "https://cdn.example.test/second.mp4")!
        let store = MemoryCredentialStore()
        let account = credential()
        await store.save(account)
        let client = SocialClient(adapter: adapter, store: store)
        #expect(try await client.capabilities(for: account.account.id).contains(.publishMultipleMedia))
        let post = try await client.publishMedia(
            [.imageURL(image), .videoURL(video)], draft: TextPost(text: "Two moments"), as: account.account.id
        )

        #expect(post.id == "published")
        #expect(post.text == "Two moments")
        #expect(post.media == [SocialAttachment(kind: .image, url: image), SocialAttachment(kind: .video, url: video)])
        let requests = await transport.requests
        #expect(requests.map { $0.url?.path } == [
            "/v27.0/iguser/media", "/v27.0/iguser/media", "/v27.0/child_image", "/v27.0/child_video",
            "/v27.0/iguser/media", "/v27.0/carousel", "/v27.0/iguser/media_publish"
        ])
        #expect(form(requests[0]) == ["image_url": image.absoluteString, "media_type": "IMAGE", "is_carousel_item": "true"])
        #expect(form(requests[1]) == ["video_url": video.absoluteString, "media_type": "VIDEO", "is_carousel_item": "true"])
        #expect(form(requests[4]) == ["media_type": "CAROUSEL", "children": "child_image,child_video", "caption": "Two moments"])
        #expect(form(requests[6]) == ["creation_id": "carousel"])
        #expect(requests.count == 7) // No read-after-write request follows media_publish.
    }

    @Test("Rejects invalid carousel sizes and non-HTTPS media before sending requests")
    func rejectsInvalidInputs() async throws {
        let transport = CarouselStub([])
        let adapter = InstagramAdapter(transport: transport)
        await #expect(throws: SocialError.invalidInput) {
            try await adapter.publishMedia([],
                                           draft: TextPost(text: ""), credential: credential())
        }
        await #expect(throws: SocialError.invalidInput) {
            try await adapter.publishMedia([
                .imageURL(URL(string: "https://cdn.example.test/a.jpg")!),
                .imageURL(URL(string: "http://cdn.example.test/b.jpg")!)
            ], draft: TextPost(text: ""), credential: credential())
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test("A failed child never creates or publishes a carousel")
    func stopsAfterChildFailure() async throws {
        let transport = CarouselStub([
            response(#"{"id":"child_image"}"#),
            HTTPResponse(statusCode: 400, body: Data(#"{"error":{"message":"invalid video"}}"#.utf8))
        ])
        await #expect(throws: Error.self) {
            try await InstagramAdapter(transport: transport, pollIntervalNanoseconds: 0).publishMedia(
                [.imageURL(URL(string: "https://cdn.example.test/a.jpg")!),
                 .videoURL(URL(string: "https://cdn.example.test/b.mp4")!)],
                draft: TextPost(text: ""), credential: credential()
            )
        }
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.url?.path == "/v27.0/iguser/media" })
    }

    @Test("Only an ambiguous media_publish failure is reported as an unknown publish outcome")
    func ambiguousPublishOutcome() async throws {
        let key = UUID()
        let transport = CarouselStub([
            response(#"{"id":"child_a"}"#), response(#"{"id":"child_b"}"#),
            response(#"{"id":"child_a","status_code":"FINISHED"}"#), response(#"{"id":"child_b","status_code":"FINISHED"}"#),
            response(#"{"id":"carousel"}"#), response(#"{"id":"carousel","status_code":"FINISHED"}"#),
            HTTPResponse(statusCode: 500, body: Data())
        ])
        await #expect(throws: SocialError.publishOutcomeUnknown(key)) {
            try await InstagramAdapter(transport: transport, pollIntervalNanoseconds: 0).publishMedia(
                [.imageURL(URL(string: "https://cdn.example.test/a.jpg")!),
                 .imageURL(URL(string: "https://cdn.example.test/b.jpg")!)],
                draft: TextPost(text: "", idempotencyKey: key), credential: credential()
            )
        }
        #expect(await transport.requests.count == 7)
    }

    @Test("Retrieves carousel child attachments in provider order")
    func retrievesCarouselChildren() async throws {
        let transport = CarouselStub([
            response(#"{"id":"carousel","caption":"A set","media_type":"CAROUSEL_ALBUM"}"#),
            response(#"{"data":[{"media_type":"IMAGE","media_url":"https://cdn.example.test/a.jpg"},{"media_type":"VIDEO","media_url":"https://cdn.example.test/b.mp4"}]}"#)
        ])
        let post = try await InstagramAdapter(transport: transport).post(id: "carousel", credential: credential())
        #expect(post.media == [
            SocialAttachment(kind: .image, url: URL(string: "https://cdn.example.test/a.jpg")!),
            SocialAttachment(kind: .video, url: URL(string: "https://cdn.example.test/b.mp4")!)
        ])
        let requests = await transport.requests
        #expect(requests[1].url?.path == "/v27.0/carousel/children")
        #expect(requests[1].url?.absoluteString.contains("fields=media_type%2Cmedia_url") == true)
    }

    @Test("Cancellation while waiting for Meta processing never dispatches media_publish")
    func cancellationDuringPolling() async throws {
        let arrivals = AsyncStream<Int>.makeStream()
        let transport = CarouselStub([
            response(#"{"id":"child_a"}"#), response(#"{"id":"child_b"}"#),
            response(#"{"id":"child_a","status_code":"FINISHED"}"#), response(#"{"id":"child_b","status_code":"FINISHED"}"#),
            response(#"{"id":"carousel"}"#), response(#"{"id":"carousel","status_code":"IN_PROGRESS"}"#)
        ], arrivals: arrivals.continuation)
        let adapter = InstagramAdapter(transport: transport, pollAttempts: 3, pollIntervalNanoseconds: 20_000_000_000)
        let task = Task {
            try await adapter.publishMedia(
                [.imageURL(URL(string: "https://cdn.example.test/a.jpg")!),
                 .imageURL(URL(string: "https://cdn.example.test/b.jpg")!)],
                draft: TextPost(text: ""), credential: credential()
            )
        }
        for await count in arrivals.stream {
            if count == 6 { break }
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await transport.requests.count == 6)
    }
}

private actor CarouselStub: HTTPTransport {
    private var responses: [HTTPResponse]
    private(set) var requests: [URLRequest] = []
    let arrivals: AsyncStream<Int>.Continuation?
    init(_ responses: [HTTPResponse], arrivals: AsyncStream<Int>.Continuation? = nil) {
        self.responses = responses
        self.arrivals = arrivals
    }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        arrivals?.yield(requests.count)
        guard !responses.isEmpty else { throw SocialError.transportFailure }
        return responses.removeFirst()
    }
}

private func response(_ body: String) -> HTTPResponse {
    HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
}

private func credential() -> SocialCredential {
    SocialCredential(account: SocialAccount(platform: .instagram, server: URL(string: "https://graph.instagram.com")!, remoteID: "iguser", username: "studio"), accessToken: "test-token")
}

private func form(_ request: URLRequest) -> [String: String] {
    guard let body = request.httpBody, let value = String(data: body, encoding: .utf8) else { return [:] }
    var result: [String: String] = [:]
    for pair in value.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let key = String(parts[0]).removingPercentEncoding,
              let fieldValue = String(parts[1]).removingPercentEncoding else { continue }
        result[key] = fieldValue
    }
    return result
}
