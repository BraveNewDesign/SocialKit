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
    case analytics
    case listPosts
    case reply
    case readReplies
    case deleteReply
    case repost
    case unrepost
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
    public var platform: SocialPlatform { id.platform }
    public var server: URL { id.server }
    public var remoteID: String { id.remoteID }

    public init(platform: SocialPlatform, server: URL, remoteID: String, username: String) {
        id = ID(platform: platform, server: server, remoteID: remoteID)
        self.username = username
    }
}

public struct TextPost: Codable, Sendable {
    public let text: String
    public let idempotencyKey: UUID
    public let createdAt: Date

    /// Create once per intended post. Preserve the entire draft if reconciling or retrying.
    public init(text: String, idempotencyKey: UUID = UUID(), createdAt: Date = Date()) {
        self.text = text
        self.idempotencyKey = idempotencyKey
        self.createdAt = createdAt
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

    public init(
        id: String,
        text: String,
        url: URL? = nil,
        createdAt: Date? = nil,
        likeCount: Int? = nil,
        textFormat: TextFormat = .plainText,
        media: [SocialAttachment] = []
    ) {
        self.id = id
        self.text = text
        self.url = url
        self.createdAt = createdAt
        self.likeCount = likeCount
        self.textFormat = textFormat
        self.media = media
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
