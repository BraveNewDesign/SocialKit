import Foundation

public protocol SocialAdapter: Sendable {
    associatedtype Authorization: Sendable

    var platform: SocialPlatform { get }
    var capabilities: Set<SocialCapability> { get }
    func capabilities(for credential: SocialCredential) -> Set<SocialCapability>

    func connect(_ authorization: Authorization) async throws -> SocialCredential
    func refresh(_ credential: SocialCredential) async throws -> SocialCredential
    func publish(_ draft: TextPost, credential: SocialCredential) async throws -> SocialPost
    func post(id: String, credential: SocialCredential) async throws -> SocialPost
    func setLiked(_ liked: Bool, postID: String, credential: SocialCredential) async throws
    func posts(cursor: String?, credential: SocialCredential) async throws -> SocialPage<SocialPost>
    func reply(_ draft: TextPost, to postID: String, credential: SocialCredential) async throws -> SocialPost
    func replies(to postID: String, cursor: String?, credential: SocialCredential) async throws -> SocialPage<SocialPost>
    func deleteReply(id: String, credential: SocialCredential) async throws
    func publishMedia(_ media: SocialMedia, draft: TextPost, credential: SocialCredential) async throws -> SocialPost
    func setReposted(_ reposted: Bool, postID: String, credential: SocialCredential) async throws
}

public extension SocialAdapter {
    func capabilities(for credential: SocialCredential) -> Set<SocialCapability> { capabilities }

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

    func posts(cursor: String?, credential: SocialCredential) async throws -> SocialPage<SocialPost> {
        throw SocialError.unsupported(.listPosts)
    }

    func reply(_ draft: TextPost, to postID: String, credential: SocialCredential) async throws -> SocialPost {
        throw SocialError.unsupported(.reply)
    }

    func replies(to postID: String, cursor: String?, credential: SocialCredential) async throws -> SocialPage<SocialPost> {
        throw SocialError.unsupported(.readReplies)
    }

    func deleteReply(id: String, credential: SocialCredential) async throws {
        throw SocialError.unsupported(.deleteReply)
    }

    func publishMedia(_ media: SocialMedia, draft: TextPost, credential: SocialCredential) async throws -> SocialPost {
        throw SocialError.unsupported(.publishMedia)
    }

    func setReposted(_ reposted: Bool, postID: String, credential: SocialCredential) async throws {
        throw SocialError.unsupported(reposted ? .repost : .unrepost)
    }
}
