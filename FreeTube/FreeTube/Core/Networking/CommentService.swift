import Foundation
import OSLog
import YouTubeKit

protocol CommentServicing: Sendable {
    func fetchComments(videoID: String, continuation: String?) async throws -> CommentThread
    func fetchReplies(continuation: String) async throws -> CommentThread

    func create(videoID: String, text: String) async throws -> Comment
    func edit(commentID: String, text: String) async throws -> Comment
    func delete(commentID: String) async throws

    func reply(commentID: String, text: String) async throws -> Comment
    func editReply(replyID: String, text: String) async throws -> Comment

    func like(commentID: String) async throws
    func dislike(commentID: String) async throws
    func removeLike(commentID: String) async throws
    func removeDislike(commentID: String) async throws

    func translate(commentID: String, targetLanguage: String) async throws -> String
}

/// Wraps the comment family:
/// `CreateCommentResponse`, `EditCommentResponse`, `DeleteCommentResponse`,
/// `ReplyCommentResponse`, `EditReplyCommandResponse`,
/// `LikeCommentResponse`, `DislikeCommentResponse`, `RemoveLikeCommentResponse`, `RemoveDislikeCommentResponse`,
/// `CommentTranslationResponse`.
/// TODO(YouTubeKit): wire each method to its response type. All require cookies.
final class CommentService: CommentServicing {
    private let client: YouTubeKitClient
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "CommentService")

    nonisolated init(client: YouTubeKitClient = .shared) {
        self.client = client
    }

    // MARK: - Read

    /// First call (no continuation): fetches `MoreVideoInfosResponse` to obtain the comments
    /// continuation token, then resolves the actual comments via `VideoCommentsResponse`.
    /// Subsequent pages use the continuation token directly.
    func fetchComments(videoID: String, continuation: String?) async throws -> CommentThread {
        let token: String
        if let continuation {
            token = continuation
        } else {
            do {
                let info = try await MoreVideoInfosResponse.sendThrowingRequest(
                    youtubeModel: client.model,
                    data: [.query: videoID]
                )
                guard let initial = info.commentsContinuationToken else {
                    log.notice("MoreVideoInfosResponse returned no commentsContinuationToken")
                    return CommentThread(comments: [], continuationToken: nil)
                }
                token = initial
            } catch {
                throw YouTubeServiceError.network(error)
            }
        }

        do {
            let response = try await VideoCommentsResponse.sendThrowingRequest(
                youtubeModel: client.model,
                data: [.continuation: token]
            )
            let comments = response.results.map { Mappers.comment(from: $0) }
            return CommentThread(comments: comments, continuationToken: response.continuationToken)
        } catch {
            throw YouTubeServiceError.network(error)
        }
    }

    func fetchReplies(continuation: String) async throws -> CommentThread {
        do {
            let response = try await VideoCommentsResponse.Continuation.sendThrowingRequest(
                youtubeModel: client.model,
                data: [.continuation: continuation]
            )
            let comments = response.results.map { Mappers.comment(from: $0) }
            return CommentThread(comments: comments, continuationToken: response.continuationToken)
        } catch {
            throw YouTubeServiceError.network(error)
        }
    }

    // MARK: - Author-side mutation

    func create(videoID: String, text: String) async throws -> Comment {
        log.info("Create comment on \(videoID, privacy: .public)")
        throw YouTubeServiceError.notAuthenticated
    }

    func edit(commentID: String, text: String) async throws -> Comment {
        throw YouTubeServiceError.notAuthenticated
    }

    func delete(commentID: String) async throws {
        throw YouTubeServiceError.notAuthenticated
    }

    func reply(commentID: String, text: String) async throws -> Comment {
        throw YouTubeServiceError.notAuthenticated
    }

    func editReply(replyID: String, text: String) async throws -> Comment {
        throw YouTubeServiceError.notAuthenticated
    }

    // MARK: - Reactions

    func like(commentID: String) async throws {
        throw YouTubeServiceError.notAuthenticated
    }

    func dislike(commentID: String) async throws {
        throw YouTubeServiceError.notAuthenticated
    }

    func removeLike(commentID: String) async throws {
        throw YouTubeServiceError.notAuthenticated
    }

    func removeDislike(commentID: String) async throws {
        throw YouTubeServiceError.notAuthenticated
    }

    // MARK: - Translation

    func translate(commentID: String, targetLanguage: String) async throws -> String {
        throw YouTubeServiceError.notAuthenticated
    }
}
