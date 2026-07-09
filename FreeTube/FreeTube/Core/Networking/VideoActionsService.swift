import Foundation
import OSLog
import YouTubeKit

protocol VideoActionsServicing: Sendable {
    func like(videoID: String) async throws
    func dislike(videoID: String) async throws
    func removeRating(videoID: String) async throws
}

/// Wraps `LikeVideoResponse`, `DislikeVideoResponse`, `RemoveLikeFromVideoResponse`. All three
/// require cookies; throw `.notAuthenticated` when YouTubeKit reports `isDisconnected=true`.
/// Liking a video adds it to YouTube's "Liked videos" playlist (VLLL) automatically, so the
/// app's "Add to favorites" action delegates here when signed in.
final class VideoActionsService: VideoActionsServicing {
    private let client: YouTubeKitClient
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "VideoActionsService")

    nonisolated init(client: YouTubeKitClient = .shared) {
        self.client = client
    }

    func like(videoID: String) async throws {
        log.info("[video] like videoID=\(videoID, privacy: .public)")
        do {
            let response = try await LikeVideoResponse.sendThrowingRequest(
                youtubeModel: client.model,
                data: [.query: videoID]
            )
            if response.isDisconnected {
                log.notice("[video] like: response isDisconnected=true")
                throw YouTubeServiceError.notAuthenticated
            }
        } catch let error as YouTubeServiceError {
            throw error
        } catch {
            log.error("[video] like failed: \(String(describing: error), privacy: .public)")
            throw YouTubeServiceError.network(error)
        }
    }

    func dislike(videoID: String) async throws {
        log.info("[video] dislike videoID=\(videoID, privacy: .public)")
        do {
            let response = try await DislikeVideoResponse.sendThrowingRequest(
                youtubeModel: client.model,
                data: [.query: videoID]
            )
            if response.isDisconnected {
                throw YouTubeServiceError.notAuthenticated
            }
        } catch let error as YouTubeServiceError {
            throw error
        } catch {
            log.error("[video] dislike failed: \(String(describing: error), privacy: .public)")
            throw YouTubeServiceError.network(error)
        }
    }

    func removeRating(videoID: String) async throws {
        log.info("[video] removeRating videoID=\(videoID, privacy: .public)")
        do {
            let response = try await RemoveLikeFromVideoResponse.sendThrowingRequest(
                youtubeModel: client.model,
                data: [.query: videoID]
            )
            if response.isDisconnected {
                throw YouTubeServiceError.notAuthenticated
            }
        } catch let error as YouTubeServiceError {
            throw error
        } catch {
            log.error("[video] removeRating failed: \(String(describing: error), privacy: .public)")
            throw YouTubeServiceError.network(error)
        }
    }
}
