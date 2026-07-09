import Foundation

struct Comment: Identifiable, Hashable, Sendable {
    let id: String
    let authorName: String
    let authorChannelID: String?
    let authorThumbnailURL: URL?
    let bodyText: String
    let likeCount: Int
    let isLikedByUser: Bool
    let isDislikedByUser: Bool
    let isAuthoredByUser: Bool
    let publishedRelative: String
    let replyCount: Int
    let replyContinuationToken: String?
}

struct CommentThread: Sendable {
    let comments: [Comment]
    let continuationToken: String?
}
