import Foundation
import SocialKit
import XCTest
@testable import MetaValidationOAuth

final class MetaValidationOAuthBridgeTests: XCTestCase {
    override func tearDown() {
        BridgeURLProtocol.setHandler(nil)
        super.tearDown()
    }

    func testExchangeUsesRawPlatformAndReturnsToken() async throws {
        BridgeURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.absoluteString, "https://bridge.example/meta/oauth/exchange")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer bridge-secret")
            let body = try XCTUnwrap(BridgeURLProtocol.bodyData(from: request))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(object["platform"], "threads")
            XCTAssertEqual(object["code"], "authorization-code")
            XCTAssertEqual(object["redirect_uri"], "https://client.example/oauth/callback")
            return (200, Data(#"{"access_token":"secret-token","refresh_token":"refresh","expires_at":"2030-01-02T03:04:05Z","granted_scopes":["threads_basic"]}"#.utf8), [:])
        }
        let bridge = try makeBridge()
        let token = try await bridge.exchange(
            platform: .threads,
            code: "authorization-code",
            redirectURI: URL(string: "https://client.example/oauth/callback")!
        )
        XCTAssertEqual(token.accessToken, "secret-token")
        XCTAssertEqual(token.refreshToken, "refresh")
        XCTAssertEqual(token.grantedScopes, ["threads_basic"])
        XCTAssertEqual(token.expiresAt, ISO8601DateFormatter().date(from: "2030-01-02T03:04:05Z"))
        XCTAssertEqual(String(describing: token), "OAuthToken(redacted)")
    }

    func testRefreshUsesRefreshTokenAndPlatform() async throws {
        BridgeURLProtocol.setHandler { request in
            let body = try XCTUnwrap(BridgeURLProtocol.bodyData(from: request))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(request.url?.lastPathComponent, "refresh")
            XCTAssertEqual(object["platform"], "instagram")
            XCTAssertEqual(object["refresh_token"], "refresh-value")
            return (200, Data(#"{"access_token":"new-access"}"#.utf8), [:])
        }
        let bridge = try makeBridge()
        let renewed = try await bridge.refresh(platform: .instagram, token: OAuthToken(accessToken: "old", refreshToken: "refresh-value"))
        XCTAssertEqual(renewed.accessToken, "new-access")
    }

    func testRejectsInsecureEndpointAndRedactsServiceFailures() async throws {
        XCTAssertThrowsError(try MetaValidationOAuthBridge(endpoint: URL(string: "http://bridge.example")!, bearerToken: "bridge-secret"))
        XCTAssertThrowsError(try MetaValidationOAuthBridge(endpoint: URL(string: "https://bridge.example")!, bearerToken: "bad token"))
        BridgeURLProtocol.setHandler { _ in (500, Data("sensitive diagnostic body".utf8), [:]) }
        let bridge = try makeBridge()
        XCTAssertEqual(String(describing: bridge), "MetaValidationOAuthBridge(redacted)")
        do {
            _ = try await bridge.exchange(platform: .threads, code: "code", redirectURI: URL(string: "https://client.example/callback")!)
            XCTFail("Expected exchange failure")
        } catch {
            XCTAssertEqual(error as? SocialError, .authorizationFailed)
            XCTAssertFalse(String(describing: error).contains("sensitive"))
        }
    }

    func testDoesNotFollowRedirect() async throws {
        BridgeURLProtocol.setHandler { _ in (302, Data(), ["Location": "https://attacker.example/collect"]) }
        let bridge = try makeBridge()
        do {
            _ = try await bridge.exchange(platform: .threads, code: "secret-code", redirectURI: URL(string: "https://client.example/callback")!)
            XCTFail("Expected redirect to be rejected")
        } catch {
            XCTAssertEqual(error as? SocialError, .authorizationFailed)
        }
    }

    private func makeBridge() throws -> MetaValidationOAuthBridge {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BridgeURLProtocol.self]
        return try MetaValidationOAuthBridge(endpoint: URL(string: "https://bridge.example/meta")!, bearerToken: "bridge-secret", configuration: configuration)
    }
}

private final class BridgeURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (Int, Data, [String: String])
    private final class HandlerStorage: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Handler?
        func set(_ handler: Handler?) { lock.lock(); value = handler; lock.unlock() }
        func get() -> Handler? { lock.lock(); defer { lock.unlock() }; return value }
    }
    private static let storage = HandlerStorage()
    static func setHandler(_ handler: Handler?) { storage.set(handler) }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.storage.get())
            let (status, data, headers) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4096)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
