import Foundation

/// Small, dependency-free Graph API transport shared by the Meta adapters.
struct MetaHTTP: Sendable {
    let transport: any HTTPTransport
    let origin: URL
    let accessToken: String

    init(transport: any HTTPTransport, origin: URL, accessToken: String) throws {
        guard origin.scheme == "https", origin.host != nil, !accessToken.isEmpty else {
            throw SocialError.invalidConfiguration
        }
        self.transport = transport
        self.origin = origin
        self.accessToken = accessToken
    }

    func get<T: Decodable>(_ path: String, query: [(String, String)] = []) async throws -> T {
        try await send(path, method: "GET", query: query, publishingKey: nil)
    }

    func post<T: Decodable>(
        _ path: String, form: [(String, String)], key: UUID? = nil, query: [(String, String)] = []
    ) async throws -> T {
        try await send(path, method: "POST", query: query, form: form, publishingKey: key)
    }

    func delete(_ path: String) async throws {
        let result: MetaSuccess = try await send(path, method: "DELETE", publishingKey: nil)
        guard result.success else { throw SocialError.invalidResponse }
    }

    private func send<T: Decodable>(
        _ path: String,
        method: String,
        query: [(String, String)] = [],
        form: [(String, String)] = [],
        publishingKey: UUID?
    ) async throws -> T {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains(".."),
              var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else {
            throw SocialError.invalidConfiguration
        }
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = basePath + path
        components.query = nil
        guard let bareURL = components.url else { throw SocialError.invalidConfiguration }
        let url = query.isEmpty ? bareURL : try OAuthForm.queryURL(bareURL, parameters: query)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if method == "POST" {
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = OAuthForm.encode(form)
        }

        let response = try await HTTPClient(transport: transport).send(
            request,
            publishingKey: publishingKey,
            classifyError: { response in
                let graphError = try? JSONDecoder().decode(MetaGraphError.self, from: response.body).error
                if graphError?.code == 190 { return .authenticationRequired }
                if response.statusCode == 429 || [4, 17, 32, 613].contains(graphError?.code ?? -1) {
                    return .rateLimited(retryAfter: response.header("Retry-After"))
                }
                if response.statusCode == 403 || graphError?.code == 10 || graphError?.code == 200 {
                    return .permissionDenied
                }
                return nil
            }
        )
        guard let decoded = try? JSONDecoder().decode(T.self, from: response.body) else {
            if let publishingKey { throw SocialError.publishOutcomeUnknown(publishingKey) }
            throw SocialError.invalidResponse
        }
        return decoded
    }
}

struct MetaSuccess: Decodable, Sendable { let success: Bool }

func validateMetaDevelopmentToken(_ token: OAuthToken) throws {
    guard !token.accessToken.isEmpty else { throw SocialError.authenticationRequired }
    let hasWhitespaceOrControl = token.accessToken.unicodeScalars.contains {
        CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
    }
    guard !hasWhitespaceOrControl else { throw SocialError.invalidInput }
    if let expiry = token.expiresAt, expiry <= .now { throw SocialError.authenticationRequired }
}

struct MetaGraphError: Decodable, Sendable {
    struct Detail: Decodable, Sendable {
        let code: Int?
    }
    let error: Detail
}

struct MetaID: Decodable, Sendable {
    let id: String
}

struct MetaPageResponse<Item: Decodable & Sendable>: Decodable, Sendable {
    struct Paging: Decodable, Sendable {
        struct Cursors: Decodable, Sendable { let after: String? }
        let cursors: Cursors?
        let next: String?
    }
    let data: [Item]
    let paging: Paging?
}

struct MetaPostRecord: Decodable, Sendable {
    let id: String
    let text: String?
    let message: String?
    let caption: String?
    let permalink: URL?
    let permalink_url: URL?
    let timestamp: String?
    let created_time: String?
    let like_count: Int?
    let likes: MetaCount?
    let media_type: String?
    let media_url: URL?
    let attachments: MetaAttachments?

    var normalizedText: String { text ?? message ?? caption ?? "" }
    var normalizedURL: URL? { permalink ?? permalink_url }
    var normalizedDate: Date? {
        let value = timestamp ?? created_time
        guard let value else { return nil }
        return metaDate(value)
    }
    var normalizedLikes: Int? { like_count ?? likes?.summary?.total_count }
}

struct MetaCommentRecord: Decodable, Sendable {
    let id: String
    let text: String?
    let message: String?
    let username: String?
    let from: From?
    let permalink_url: URL?
    let created_time: String?
    let timestamp: String?
    let like_count: Int?

    struct From: Decodable, Sendable { let name: String?; let username: String? }
    var normalizedText: String { text ?? message ?? "" }
    var normalizedDate: Date? {
        guard let value = timestamp ?? created_time else { return nil }
        return metaDate(value)
    }
}

func metaDate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value)
}

func metaComment(_ value: MetaCommentRecord) -> SocialPost {
    SocialPost(id: value.id, text: value.normalizedText, url: value.permalink_url,
               createdAt: value.normalizedDate, likeCount: value.like_count)
}

struct MetaCount: Decodable, Sendable {
    struct Summary: Decodable, Sendable { let total_count: Int? }
    let summary: Summary?
}

struct MetaAttachments: Decodable, Sendable {
    struct DataRecord: Decodable, Sendable {
        struct Media: Decodable, Sendable { let image: Image?; struct Image: Decodable, Sendable { let src: URL? } }
        let media_type: String?
        let media: Media?
        let target: Target?
        struct Target: Decodable, Sendable { let url: URL? }
    }
    let data: [DataRecord]?
}

func metaPost(_ value: MetaPostRecord) -> SocialPost {
    let kind: SocialAttachment.Kind
    let mediaType = value.media_type ?? value.attachments?.data?.first?.media_type
    let attachmentURL = value.media_url ?? value.attachments?.data?.first?.media?.image?.src
        ?? value.attachments?.data?.first?.target?.url
    switch mediaType?.uppercased() {
    case "VIDEO", "REELS": kind = .video
    case "IMAGE", "PHOTO": kind = .image
    case "CAROUSEL_ALBUM", "ALBUM": kind = .unknown
    default: kind = .unknown
    }
    let hasMediaType = mediaType.map { !["TEXT", "TEXT_POST"].contains($0.uppercased()) } ?? false
    let media = hasMediaType || attachmentURL != nil ? [SocialAttachment(kind: kind, url: attachmentURL)] : []
    return SocialPost(id: value.id, text: value.normalizedText, url: value.normalizedURL,
                      createdAt: value.normalizedDate, likeCount: value.normalizedLikes,
                      media: media)
}

func metaPathID(_ id: String) throws -> String {
    guard !id.isEmpty, id.utf8.allSatisfy({
        ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 95
    }) else { throw SocialError.invalidInput }
    return id
}

/// Facebook and Instagram may append these inert legacy fragments to a valid OAuth redirect.
/// Only the exact documented shapes are removed; every other fragment still fails state validation.
func normalizeMetaOAuthCallback(_ url: URL, platform: SocialPlatform) throws -> URL {
    guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        throw SocialError.authorizationFailed
    }
    guard let fragment = parts.fragment else { return url }
    let allowed: String?
    switch platform {
    case .facebookPages: allowed = "_=_"
    case .instagram: allowed = "_"
    default: allowed = nil
    }
    guard fragment == allowed else { throw SocialError.authorizationFailed }
    parts.fragment = nil
    guard let normalized = parts.url else { throw SocialError.authorizationFailed }
    return normalized
}
