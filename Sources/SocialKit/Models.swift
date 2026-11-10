import Foundation

public enum SocialPlatform: String, Codable, Sendable, CaseIterable {
    case bluesky
    case mastodon
    case threads
    case facebookPages
    case instagram
    case linkedIn
    case x
}

public enum SocialCapability: String, Sendable, CaseIterable {
    case publishText
    case readPost
    case like
    case unlike
    case refreshSession
    case publishMedia
    case publishMultipleMedia
    case analytics
    case listPosts
    case reply
    case readReplies
    case deleteReply
    case moderateReplies
    case repost
    case unrepost
    case resolveMentions
}

public struct SocialAccount: Codable, Equatable, Sendable, Identifiable {
    public struct ID: Codable, Hashable, Sendable {
        public let platform: SocialPlatform
        public let server: URL
        public let remoteID: String

        public init(platform: SocialPlatform, server: URL, remoteID: String) {
            self.platform = platform
            self.server = server
            self.remoteID = remoteID
        }
    }

    public let id: ID
    public let username: String
    /// Provider-reported name for the account selected for publishing, when available.
    public let displayName: String?
    /// Name of the authenticated member when the selected publishing identity is an organization or Page.
    public let authenticatedUserName: String?
    public let profileURL: URL?
    public var platform: SocialPlatform { id.platform }
    public var server: URL { id.server }
    public var remoteID: String { id.remoteID }

    public init(platform: SocialPlatform, server: URL, remoteID: String, username: String,
                displayName: String? = nil, authenticatedUserName: String? = nil, profileURL: URL? = nil) {
        id = ID(platform: platform, server: server, remoteID: remoteID)
        self.username = username
        self.displayName = displayName
        self.authenticatedUserName = authenticatedUserName
        self.profileURL = profileURL
    }
}

/// A resolved, provider-native mention. Byte offsets refer to the UTF-8 encoded post text.
public struct SocialMention: Codable, Equatable, Sendable {
    public let byteStart: Int
    public let byteEnd: Int
    public let subjectID: String

    public init(byteStart: Int, byteEnd: Int, subjectID: String) {
        self.byteStart = byteStart
        self.byteEnd = byteEnd
        self.subjectID = subjectID
    }
}

public struct TextPost: Codable, Sendable {
    public let text: String
    public let idempotencyKey: UUID
    public let createdAt: Date
    public let mentions: [SocialMention]

    /// Create once per intended post. Preserve the entire draft if reconciling or retrying.
    public init(text: String, idempotencyKey: UUID = UUID(), createdAt: Date = Date(), mentions: [SocialMention] = []) {
        self.text = text
        self.idempotencyKey = idempotencyKey
        self.createdAt = createdAt
        self.mentions = mentions
    }

    private enum CodingKeys: String, CodingKey { case text, idempotencyKey, createdAt, mentions }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        text = try values.decode(String.self, forKey: .text)
        idempotencyKey = try values.decodeIfPresent(UUID.self, forKey: .idempotencyKey) ?? UUID()
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        mentions = try values.decodeIfPresent([SocialMention].self, forKey: .mentions) ?? []
    }
}

public struct SocialPage<Item: Sendable>: Sendable {
    public let items: [Item]
    /// Opaque provider cursor. Pass it back to the same operation and account.
    public let nextCursor: String?

    public init(items: [Item], nextCursor: String? = nil) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

public enum SocialMedia: Sendable {
    case imageURL(URL)
    case videoURL(URL)
    case imageData(Data, contentType: String)
}

public struct SocialAttachment: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case image
        case video
        case unknown
    }

    public let kind: Kind
    public let url: URL?

    public init(kind: Kind, url: URL?) {
        self.kind = kind
        self.url = url
    }
}

public struct SocialPost: Equatable, Sendable, Identifiable {
    public enum TextFormat: Equatable, Sendable {
        case plainText
        case html
    }

    public let id: String
    public let text: String
    public let url: URL?
    public let createdAt: Date?
    public let likeCount: Int?
    public let textFormat: TextFormat
    public let media: [SocialAttachment]
    public let authorID: String?
    public let authorName: String?
    public let authorHandle: String?
    public let parentID: String?
    public let conversationRootID: String?
    /// Provider-confirmed ownership for reply records when the API exposes it.
    public let isOwnedByAccount: Bool?

    public init(
        id: String,
        text: String,
        url: URL? = nil,
        createdAt: Date? = nil,
        likeCount: Int? = nil,
        textFormat: TextFormat = .plainText,
        media: [SocialAttachment] = [],
        authorID: String? = nil,
        authorName: String? = nil,
        authorHandle: String? = nil,
        parentID: String? = nil,
        conversationRootID: String? = nil,
        isOwnedByAccount: Bool? = nil
    ) {
        self.id = id
        self.text = text
        self.url = url
        self.createdAt = createdAt
        self.likeCount = likeCount
        self.textFormat = textFormat
        self.media = media
        self.authorID = authorID
        self.authorName = authorName
        self.authorHandle = authorHandle
        self.parentID = parentID
        self.conversationRootID = conversationRootID
        self.isOwnedByAccount = isOwnedByAccount
    }
}

public enum SocialError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidResponse
    case invalidInput
    case unsupported(SocialCapability)
    case authenticationRequired
    case authorizationFailed
    case accountBusy
    case rateLimited(retryAfter: String?)
    case httpStatus(Int)
    case transportFailure
    case publishOutcomeUnknown(UUID)
    case credentialStorage(Int32)
    case permissionDenied
    case billingRequired
    case mediaProcessingFailed
    case mediaProcessingTimedOut
}

extension SocialError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "The provider configuration is invalid."
        case .invalidResponse: "The provider response could not be read."
        case .invalidInput: "The supplied input is invalid for this provider."
        case .unsupported(let operation): "This provider does not support \(operation.rawValue)."
        case .authenticationRequired: "The account must be authenticated."
        case .authorizationFailed: "Authorization could not be completed."
        case .accountBusy: "Another operation is in progress for this account."
        case .rateLimited: "The provider rate limit was reached."
        case .httpStatus(let status): "The provider returned HTTP \(status)."
        case .transportFailure: "The provider could not be reached."
        case .publishOutcomeUnknown: "The provider may have accepted the post. Check before retrying."
        case .credentialStorage: "The credential store could not complete the operation."
        case .permissionDenied: "The provider denied permission for this operation."
        case .billingRequired: "The provider requires API billing access or credits."
        case .mediaProcessingFailed: "The provider could not process the media."
        case .mediaProcessingTimedOut: "The media did not finish processing within the polling limit."
        }
    }
}
