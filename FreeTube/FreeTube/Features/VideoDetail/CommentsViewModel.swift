import Foundation
import Observation

@available(iOS 17.0, *)
@Observable
@MainActor
final class CommentsViewModel {
    let videoID: String
    private(set) var comments: [Comment] = []
    private(set) var continuationToken: String?
    private(set) var isLoading: Bool = false
    var errorState: ErrorState?
    var translations: [String: String] = [:]

    private let service: any CommentServicing

    init(videoID: String, service: any CommentServicing = CommentService()) {
        self.videoID = videoID
        self.service = service
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let thread = try await service.fetchComments(videoID: videoID, continuation: nil)
            comments = thread.comments
            continuationToken = thread.continuationToken
        } catch {
            errorState = ErrorState(from: error)
        }
    }

    func loadMore() async {
        guard let token = continuationToken, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let thread = try await service.fetchComments(videoID: videoID, continuation: token)
            comments.append(contentsOf: thread.comments)
            continuationToken = thread.continuationToken
        } catch {
            errorState = ErrorState(from: error)
        }
    }

    func toggleLike(_ comment: Comment) async {
        do {
            if comment.isLikedByUser {
                try await service.removeLike(commentID: comment.id)
            } else {
                try await service.like(commentID: comment.id)
            }
        } catch {
            errorState = ErrorState(from: error)
        }
    }

    func toggleDislike(_ comment: Comment) async {
        do {
            if comment.isDislikedByUser {
                try await service.removeDislike(commentID: comment.id)
            } else {
                try await service.dislike(commentID: comment.id)
            }
        } catch {
            errorState = ErrorState(from: error)
        }
    }

    func reply(to comment: Comment, text: String) async {
        do {
            let new = try await service.reply(commentID: comment.id, text: text)
            comments.insert(new, at: 0)
        } catch {
            errorState = ErrorState(from: error)
        }
    }

    func post(_ text: String) async {
        do {
            let new = try await service.create(videoID: videoID, text: text)
            comments.insert(new, at: 0)
        } catch {
            errorState = ErrorState(from: error)
        }
    }

    func edit(_ comment: Comment, text: String) async {
        do {
            let updated = try await service.edit(commentID: comment.id, text: text)
            if let idx = comments.firstIndex(where: { $0.id == comment.id }) {
                comments[idx] = updated
            }
        } catch {
            errorState = ErrorState(from: error)
        }
    }

    func delete(_ comment: Comment) async {
        do {
            try await service.delete(commentID: comment.id)
            comments.removeAll { $0.id == comment.id }
        } catch {
            errorState = ErrorState(from: error)
        }
    }

    func translate(_ comment: Comment, targetLanguage: String = Locale.current.language.languageCode?.identifier ?? "en") async {
        do {
            translations[comment.id] = try await service.translate(commentID: comment.id, targetLanguage: targetLanguage)
        } catch {
            errorState = ErrorState(from: error)
        }
    }
}
