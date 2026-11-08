import Foundation

public protocol SocialAdapter: Sendable {
    associatedtype Authorization: Sendable

    var platform: SocialPlatform { get }
    var capabilities: Set<SocialCapability> { get }

    func connect(_ authorization: Authorization) async throws -> SocialCredential
    func refresh(_ credential: SocialCredential) async throws -> SocialCredential
    func publish(_ draft: TextPost, credential: SocialCredential) async throws -> SocialPost
    func post(id: String, credential: SocialCredential) async throws -> SocialPost
    func setLiked(_ liked: Bool, postID: String, credential: SocialCredential) async throws
}

public extension SocialAdapter {
    func refresh(_ credential: SocialCredential) async throws -> SocialCredential {
        throw SocialError.unsupported(.refreshSession)
    }

    func publish(_ draft: TextPost, credential: SocialCredential) async throws -> SocialPost {
        throw SocialError.unsupported(.publishText)
    }

    func post(id: String, credential: SocialCredential) async throws -> SocialPost {
        throw SocialError.unsupported(.readPost)
    }

    func setLiked(_ liked: Bool, postID: String, credential: SocialCredential) async throws {
        throw SocialError.unsupported(liked ? .like : .unlike)
    }
}
