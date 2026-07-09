import Foundation
import Observation
import OSLog

@available(iOS 17.0, *)
@Observable
@MainActor
final class VideoDetailViewModel {
    let videoID: String
    private(set) var info: VideoInfo?
    private(set) var isLoading: Bool = false
    var errorState: ErrorState?

    private let videoService: any VideoServicing
    private let actions: any VideoActionsServicing
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "VideoDetailViewModel")

    init(
        videoID: String,
        videoService: any VideoServicing = VideoService(),
        actions: any VideoActionsServicing = VideoActionsService()
    ) {
        self.videoID = videoID
        self.videoService = videoService
        self.actions = actions
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            info = try await videoService.fetchInfo(id: videoID)
        } catch {
            errorState = ErrorState(from: error)
        }
    }

    func toggleLike() async {
        guard var info else { return }
        do {
            if info.isLikedByUser {
                try await actions.removeRating(videoID: videoID)
            } else {
                try await actions.like(videoID: videoID)
            }
            info = VideoInfo(
                video: info.video,
                descriptionText: info.descriptionText,
                likeCount: info.likeCount,
                isLikedByUser: !info.isLikedByUser,
                isDislikedByUser: false,
                recommended: info.recommended,
                streamingURL: info.streamingURL,
                formats: info.formats
            )
            self.info = info
        } catch {
            errorState = ErrorState(from: error)
        }
    }

    func toggleDislike() async {
        guard var info else { return }
        do {
            if info.isDislikedByUser {
                try await actions.removeRating(videoID: videoID)
            } else {
                try await actions.dislike(videoID: videoID)
            }
            info = VideoInfo(
                video: info.video,
                descriptionText: info.descriptionText,
                likeCount: info.likeCount,
                isLikedByUser: false,
                isDislikedByUser: !info.isDislikedByUser,
                recommended: info.recommended,
                streamingURL: info.streamingURL,
                formats: info.formats
            )
            self.info = info
        } catch {
            errorState = ErrorState(from: error)
        }
    }
}
