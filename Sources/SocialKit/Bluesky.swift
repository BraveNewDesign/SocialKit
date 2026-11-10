import CryptoKit
import Foundation

/// App-password based XRPC adapter for Bluesky and compatible AT Protocol PDSes.
/// The PDS is explicitly selected and is never inferred from an account handle.
public struct BlueskyAdapter: SocialAdapter {
    public struct Authorization: Sendable, CustomDebugStringConvertible, CustomStringConvertible, CustomReflectable {
        public let identifier: String
        public let appPassword: String
        public let server: URL

        public init(
            identifier: String,
            appPassword: String,
            server: URL = URL(string: "https://bsky.social")!
        ) {
            self.identifier = identifier
            self.appPassword = appPassword
            self.server = server
        }
        public var description: String { "BlueskyAdapter.Authorization([REDACTED])" }
        public var debugDescription: String { description }
        public var customMirror: Mirror {
            Mirror(self, children: ["identifier": "[REDACTED]", "appPassword": "[REDACTED]", "server": "[REDACTED]"])
        }
    }

    public let platform: SocialPlatform = .bluesky
    public let capabilities: Set<SocialCapability> = [.publishText, .readPost, .listPosts, .like, .refreshSession, .resolveMentions]

    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    public func connect(_ authorization: Authorization) async throws -> SocialCredential {
        let origin = try HTTPSOrigin(validating: authorization.server)
        guard !authorization.identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !authorization.appPassword.isEmpty else {
            throw SocialError.invalidConfiguration
        }
        let response: HTTPResponse
        do {
            response = try await requestJSON(
                origin.endpoint("/xrpc/com.atproto.server.createSession"),
                method: "POST",
                json: ["identifier": authorization.identifier, "password": authorization.appPassword]
            )
        } catch SocialError.httpStatus(400) {
            throw SocialError.authorizationFailed
        }
        let session = try Self.decode(Session.self, from: response.body)
        guard !session.accessJwt.isEmpty, !session.refreshJwt.isEmpty,
              !session.did.isEmpty, !session.handle.isEmpty else {
            throw SocialError.invalidResponse
        }
        return Self.credential(session, origin: origin)
    }

    public func refresh(_ credential: SocialCredential) async throws -> SocialCredential {
        let origin = try Self.origin(for: credential)
        guard let refreshToken = credential.refreshToken, !refreshToken.isEmpty else {
            throw SocialError.authenticationRequired
        }
        let response = try await requestJSON(
            origin.endpoint("/xrpc/com.atproto.server.refreshSession"),
            method: "POST",
            bearer: refreshToken
        )
        let session = try Self.decode(Session.self, from: response.body)
        guard !session.accessJwt.isEmpty, !session.refreshJwt.isEmpty,
              !session.did.isEmpty, !session.handle.isEmpty,
              session.did == credential.account.remoteID else {
            throw SocialError.invalidResponse
        }
        return Self.credential(session, origin: origin)
    }

    /// The URI is stable for the idempotency key and creation timestamp. Keep
    /// the original draft to reconcile or retry an ambiguous `createRecord`.
    /// A conflict alone does not prove that the record contains this draft.
    public static func postID(for idempotencyKey: UUID, createdAt: Date, accountDID: String) throws -> String {
        "at://\(accountDID)/\(Self.postCollection)/\(try Self.recordKey(for: idempotencyKey, createdAt: createdAt))"
    }

    /// Compute the URI used by SocialKit versions before the wider same-second
    /// record-key distribution. Use only to reconcile an older ambiguous write.
    public static func legacyPostID(for idempotencyKey: UUID, createdAt: Date, accountDID: String) throws -> String {
        "at://\(accountDID)/\(Self.postCollection)/\(try Self.legacyRecordKey(for: idempotencyKey, createdAt: createdAt))"
    }

    public func publish(_ draft: TextPost, credential: SocialCredential) async throws -> SocialPost {
        let origin = try Self.origin(for: credential)
        guard !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              draft.text.count <= 300,
              draft.text.utf8.count <= 3_000 else {
            throw SocialError.invalidInput
        }
        let uri = try Self.postID(for: draft.idempotencyKey, createdAt: draft.createdAt, accountDID: credential.account.remoteID)
        let key = try Self.recordKey(for: draft.idempotencyKey, createdAt: draft.createdAt)
        let facets = try Self.mentionFacets(draft.mentions, in: draft.text)
        var record: [String: Any] = [
            "$type": Self.postCollection,
            "text": draft.text,
            "createdAt": Self.timestamp(draft.createdAt)
        ]
        if !facets.isEmpty { record["facets"] = facets }
        let response: HTTPResponse
        do {
            response = try await requestJSON(
                origin.endpoint("/xrpc/com.atproto.repo.createRecord"),
                method: "POST",
                bearer: credential.accessToken,
                json: ["repo": credential.account.remoteID,
                       "collection": Self.postCollection,
                       "rkey": key,
                       "validate": true,
                       "record": record],
                publishingKey: draft.idempotencyKey
            )
        } catch SocialError.httpStatus(409) {
            throw SocialError.publishOutcomeUnknown(draft.idempotencyKey)
        }

        do {
            let created = try Self.decode(RecordResponse.self, from: response.body)
            guard created.uri == uri, !created.cid.isEmpty else {
                throw SocialError.invalidResponse
            }
            return SocialPost(
                id: created.uri,
                text: draft.text,
                url: Self.webURL(did: credential.account.remoteID, rkey: key),
                createdAt: draft.createdAt
            )
        } catch {
            throw SocialError.publishOutcomeUnknown(draft.idempotencyKey)
        }
    }

    /// Resolves an account handle to its stable DID for a native mention facet.
    public func resolveMention(_ handle: String, credential: SocialCredential) async throws -> String {
        let origin = try Self.origin(for: credential)
        let normalized = handle.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        guard !normalized.isEmpty, !normalized.contains(where: \.isWhitespace), normalized.utf8.count <= 253 else {
            throw SocialError.invalidInput
        }
        let url = try OAuthForm.queryURL(origin.endpoint("/xrpc/com.atproto.identity.resolveHandle"),
                                          parameters: [("handle", normalized)])
        let response = try await requestJSON(url)
        let value = try Self.decode(ResolveHandleResponse.self, from: response.body)
        guard value.did.hasPrefix("did:") else { throw SocialError.invalidResponse }
        return value.did
    }

    public func post(id: String, credential: SocialCredential) async throws -> SocialPost {
        let origin = try Self.origin(for: credential)
        let reference = try Self.postReference(id, expectedDID: nil)
        let text: String
        let createdAt: String
        let likeCount: Int?
        let author: AppViewPost.Author?
        if reference.did == credential.account.remoteID {
            let record = try await getPostRecord(reference, origin: origin, credential: credential)
            text = record.value.text
            createdAt = record.value.createdAt
            likeCount = nil
            author = nil
        } else {
            let record = try await getPublicPost(reference.uri)
            text = record.record.text
            createdAt = record.record.createdAt
            likeCount = record.likeCount
            author = record.author
        }
        return SocialPost(
            id: reference.uri,
            text: text,
            url: Self.webURL(did: reference.did, rkey: reference.rkey),
            createdAt: Self.parseTimestamp(createdAt),
            likeCount: likeCount,
            authorID: reference.did,
            authorName: author?.displayName,
            authorHandle: author?.handle
        )
    }

    /// Lists the account’s publicly indexed posts. AppView can lag behind the PDS.
    public func posts(cursor: String?, credential: SocialCredential) async throws -> SocialPage<SocialPost> {
        _ = try Self.origin(for: credential)
        let appView = try HTTPSOrigin(validating: URL(string: "https://public.api.bsky.app")!)
        var query = [("actor", credential.account.remoteID), ("filter", "posts_with_replies")]
        if let cursor { query.append(("cursor", cursor)) }
        let url = try OAuthForm.queryURL(appView.endpoint("/xrpc/app.bsky.feed.getAuthorFeed"), parameters: query)
        let response = try await requestJSON(url)
        let page = try Self.decode(AuthorFeed.self, from: response.body)
        let items = page.feed.compactMap { entry -> SocialPost? in
            let post = entry.post
            guard let reference = try? Self.postReference(post.uri, expectedDID: credential.account.remoteID) else {
                return nil
            }
            return SocialPost(
                id: post.uri, text: post.record.text,
                url: Self.webURL(did: reference.did, rkey: reference.rkey),
                createdAt: Self.parseTimestamp(post.record.createdAt), likeCount: post.likeCount,
                authorID: post.author?.did ?? reference.did,
                authorName: post.author?.displayName,
                authorHandle: post.author?.handle
            )
        }
        return SocialPage(items: items, nextCursor: page.cursor == cursor ? nil : page.cursor)
    }

    public func setLiked(_ liked: Bool, postID: String, credential: SocialCredential) async throws {
        guard liked else { throw SocialError.unsupported(.unlike) }
        let origin = try Self.origin(for: credential)
        let reference = try Self.postReference(postID, expectedDID: nil)
        let target = try await getPublicPost(reference.uri)
        let body: [String: Any] = [
            "$type": "app.bsky.feed.like",
            "subject": ["uri": reference.uri, "cid": target.cid],
            "createdAt": Self.timestamp(Date())
        ]
        // Omitting rkey lets the PDS allocate a schema-valid TID. The PDS's
        // validated like-subject backlink makes repeated likes idempotent.
        _ = try await requestJSON(
            origin.endpoint("/xrpc/com.atproto.repo.createRecord"),
            method: "POST",
            bearer: credential.accessToken,
            json: ["repo": credential.account.remoteID,
                  "collection": "app.bsky.feed.like",
                  "validate": true,
                  "record": body]
        )
    }

    private static let postCollection = "app.bsky.feed.post"

    private static func mentionFacets(_ mentions: [SocialMention], in text: String) throws -> [[String: Any]] {
        let bytes = Array(text.utf8)
        var previousEnd = 0
        return try mentions.sorted { $0.byteStart < $1.byteStart }.map { mention in
            guard mention.byteStart >= previousEnd, mention.byteStart >= 0,
                  mention.byteEnd > mention.byteStart, mention.byteEnd <= bytes.count,
                  mention.subjectID.hasPrefix("did:") else { throw SocialError.invalidInput }
            let segment = String(decoding: bytes[mention.byteStart..<mention.byteEnd], as: UTF8.self)
            guard segment.first == "@", !segment.dropFirst().contains(where: \.isWhitespace) else {
                throw SocialError.invalidInput
            }
            previousEnd = mention.byteEnd
            return ["index": ["byteStart": mention.byteStart, "byteEnd": mention.byteEnd],
                    "features": [["$type": "app.bsky.richtext.facet#mention", "did": mention.subjectID]]]
        }
    }

    private static func recordKey(for uuid: UUID, createdAt: Date) throws -> String {
        // A TID has 53 timestamp bits and only 10 clock bits. Spread drafts
        // across all microseconds in their creation second so concurrent drafts
        // do not compete for just 1,024 clock values. The full UUID is hashed
        // before reducing it to the available TID space.
        let second = createdAt.timeIntervalSince1970.rounded(.down)
        let baseMicros = second * 1_000_000
        guard baseMicros.isFinite, baseMicros >= 0,
              baseMicros <= Double((1 << 53) - 1 - 999_999) else { throw SocialError.invalidInput }
        let digest = SHA256.hash(data: Data(uuid.uuidString.utf8))
        let hash = digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let slot = hash % (1_000_000 * 1_024)
        let micros = UInt64(baseMicros) + slot / 1_024
        let clock = slot % 1_024
        return Self.tid((micros << 10) | clock)
    }

    private static func legacyRecordKey(for uuid: UUID, createdAt: Date) throws -> String {
        let micros = createdAt.timeIntervalSince1970 * 1_000_000
        guard micros.isFinite, micros >= 0, micros < Double(1 << 53) else { throw SocialError.invalidInput }
        let bytes = uuid.uuid
        let clock = (UInt16(bytes.14) << 8 | UInt16(bytes.15)) & 0x03ff
        return Self.tid((UInt64(micros.rounded(.down)) << 10) | UInt64(clock))
    }

    private static func tid(_ value: UInt64) -> String {
        let alphabet = Array("234567abcdefghijklmnopqrstuvwxyz")
        var remainder = value
        var characters = Array(repeating: Character("2"), count: 13)
        for index in stride(from: 12, through: 0, by: -1) {
            characters[index] = alphabet[Int(remainder & 31)]
            remainder >>= 5
        }
        return String(characters)
    }

    private func getPostRecord(
        _ reference: PostReference,
        origin: HTTPSOrigin,
        credential: SocialCredential
    ) async throws -> GetRecordResponse {
        let response = try await requestJSON(
            origin.endpoint("/xrpc/com.atproto.repo.getRecord", query: [
                URLQueryItem(name: "repo", value: reference.did),
                URLQueryItem(name: "collection", value: Self.postCollection),
                URLQueryItem(name: "rkey", value: reference.rkey)
            ]),
            bearer: credential.accessToken
        )
        let record = try Self.decode(GetRecordResponse.self, from: response.body)
        guard record.uri == reference.uri, !record.cid.isEmpty else { throw SocialError.invalidResponse }
        return record
    }

    private func getPublicPost(_ uri: String) async throws -> AppViewPost {
        let appView = try HTTPSOrigin(validating: URL(string: "https://public.api.bsky.app")!)
        let response = try await requestJSON(
            appView.endpoint("/xrpc/app.bsky.feed.getPosts", query: [URLQueryItem(name: "uris", value: uri)])
        )
        let result = try Self.decode(AppViewResponse.self, from: response.body)
        guard let post = result.posts.first, post.uri == uri, !post.cid.isEmpty else {
            throw SocialError.invalidResponse
        }
        return post
    }

    private func requestJSON(
        _ url: URL,
        method: String = "GET",
        bearer: String? = nil,
        json: [String: Any]? = nil,
        publishingKey: UUID? = nil
    ) async throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do { request.httpBody = try JSONSerialization.data(withJSONObject: json) }
            catch { throw SocialError.invalidInput }
        }
        return try await HTTPClient(transport: transport).send(
            request,
            publishingKey: publishingKey,
            authenticationErrorCodes: bearer == nil ? [] : ["ExpiredToken", "InvalidToken", "AuthenticationRequired"]
        )
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw SocialError.invalidResponse }
    }

    private static func credential(_ session: Session, origin: HTTPSOrigin) -> SocialCredential {
        SocialCredential(
            account: SocialAccount(platform: .bluesky, server: origin.url, remoteID: session.did, username: session.handle,
                                   displayName: session.handle,
                                   profileURL: URL(string: "https://bsky.app/profile/\(session.handle)")),
            accessToken: session.accessJwt,
            refreshToken: session.refreshJwt
        )
    }

    private static func origin(for credential: SocialCredential) throws -> HTTPSOrigin {
        guard credential.account.platform == .bluesky else { throw SocialError.invalidConfiguration }
        return try HTTPSOrigin(validating: credential.account.server)
    }

    private struct PostReference {
        let uri: String
        let did: String
        let rkey: String
    }

    private static func postReference(_ uri: String, expectedDID: String?) throws -> PostReference {
        let parts = uri.split(separator: "/", omittingEmptySubsequences: false)
        let did = parts.count > 2 ? String(parts[2]) : ""
        let rkey = parts.count > 4 ? String(parts[4]) : ""
        let validDID = did.split(separator: ":").count >= 3
            && did.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:.-_").contains($0) }
        let tidAlphabet = Set("234567abcdefghijklmnopqrstuvwxyz")
        let validTID = rkey.count == 13
            && rkey.first.map { "234567abcdefghij".contains($0) } == true
            && rkey.allSatisfy { tidAlphabet.contains($0) }
        guard parts.count == 5, parts[0] == "at:", parts[1].isEmpty,
              parts[3] == Substring(postCollection),
              validDID, validTID,
              expectedDID == nil || String(parts[2]) == expectedDID else {
            throw SocialError.invalidInput
        }
        return PostReference(uri: uri, did: did, rkey: rkey)
    }

    private static func webURL(did: String, rkey: String) -> URL? {
        var components = URLComponents(string: "https://bsky.app")
        components?.path = "/profile/\(did)/post/\(rkey)"
        return components?.url
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }

    private struct Session: Decodable {
        let accessJwt: String
        let refreshJwt: String
        let did: String
        let handle: String
    }
    private struct ResolveHandleResponse: Decodable { let did: String }

    private struct RecordResponse: Decodable { let uri: String; let cid: String }
    private struct GetRecordResponse: Decodable {
        let uri: String
        let cid: String
        let value: PostRecord
    }
    private struct PostRecord: Decodable { let text: String; let createdAt: String }
    private struct AuthorFeed: Decodable {
        struct Entry: Decodable { let post: AppViewPost }
        let feed: [Entry]
        let cursor: String?
    }
    private struct AppViewResponse: Decodable { let posts: [AppViewPost] }
    private struct AppViewPost: Decodable {
        let uri: String
        let cid: String
        let record: PostRecord
        let likeCount: Int?
        let author: Author?

        struct Author: Decodable {
            let did: String
            let handle: String?
            let displayName: String?
        }
    }
}
