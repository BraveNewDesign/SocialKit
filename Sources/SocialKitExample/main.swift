import Foundation
import SocialKit

/// A scripted transport exercises the same adapter and client used by a host app.
struct DemoTransport: HTTPTransport {
    let did = "did:plc:example"

    func send(_ request: URLRequest) throws -> HTTPResponse {
        switch request.url?.path {
        case "/xrpc/com.atproto.server.createSession":
            return HTTPResponse(statusCode: 200, body: Data("""
                {"did":"\(did)","handle":"demo.example","accessJwt":"demo-access","refreshJwt":"demo-refresh"}
                """.utf8))
        case "/xrpc/com.atproto.repo.createRecord":
            guard let body = request.httpBody,
                  let fields = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let recordKey = fields["rkey"] as? String else {
                throw SocialError.invalidInput
            }
            return HTTPResponse(statusCode: 200, body: Data("""
                {"uri":"at://\(did)/app.bsky.feed.post/\(recordKey)","cid":"demo-cid"}
                """.utf8))
        default:
            return HTTPResponse(statusCode: 404)
        }
    }
}

let client = SocialClient(
    adapter: BlueskyAdapter(transport: DemoTransport()),
    store: MemoryCredentialStore()
)
let account = try await client.connect(.init(identifier: "demo.example", appPassword: "fixture-only"))
let draft = TextPost(text: "Hello from SocialKit")
let published = try await client.publish(draft, as: account.id)
print("Simulated publish by \(account.username): \(published.id)")

try await runExpansionExamples()
