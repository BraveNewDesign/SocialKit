import Foundation

public struct HTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

/// Implementations must preserve HTTP status and avoid redirecting or replaying requests.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

public struct URLSessionTransport: HTTPTransport {
    private final class RejectRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (body, response) = try await session.data(for: request, delegate: RejectRedirects())
        guard let response = response as? HTTPURLResponse else {
            throw SocialError.invalidResponse
        }

        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                headers[key] = value
            }
        }
        return HTTPResponse(statusCode: response.statusCode, headers: headers, body: body)
    }
}

struct HTTPClient: Sendable {
    let transport: any HTTPTransport

    func send(
        _ request: URLRequest,
        publishingKey: UUID? = nil,
        authenticationErrorCodes: Set<String> = []
    ) async throws -> HTTPResponse {
        try Task.checkCancellation()

        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            if let publishingKey {
                throw SocialError.publishOutcomeUnknown(publishingKey)
            }
            try Task.checkCancellation()
            throw SocialError.transportFailure
        }

        switch response.statusCode {
        case 200..<300:
            return response
        case 401:
            throw SocialError.authenticationRequired
        case 400 where !authenticationErrorCodes.isEmpty:
            if let error = try? JSONDecoder().decode(ErrorBody.self, from: response.body),
               authenticationErrorCodes.contains(error.error) {
                throw SocialError.authenticationRequired
            }
            throw SocialError.httpStatus(response.statusCode)
        case 429:
            let retryAfter = response.headers.first {
                $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame
            }?.value
            throw SocialError.rateLimited(retryAfter: retryAfter)
        case 300...399, 408, 500...599:
            if let publishingKey {
                throw SocialError.publishOutcomeUnknown(publishingKey)
            }
            fallthrough
        default:
            throw SocialError.httpStatus(response.statusCode)
        }
    }

    private struct ErrorBody: Decodable {
        let error: String
    }
}

struct HTTPSOrigin: Sendable {
    let url: URL

    init(validating url: URL) throws {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/",
              components.query == nil, components.fragment == nil,
              (1...65535).contains(components.port ?? 443) else {
            throw SocialError.invalidConfiguration
        }

        components.scheme = "https"
        components.host = host
        components.path = ""
        if components.port == 443 { components.port = nil }
        guard let normalized = components.url else { throw SocialError.invalidConfiguration }
        self.url = normalized
    }

    func endpoint(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        guard path.hasPrefix("/"), !path.hasPrefix("//"),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw SocialError.invalidConfiguration
        }
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        guard let endpoint = components.url else { throw SocialError.invalidConfiguration }
        return endpoint
    }
}
