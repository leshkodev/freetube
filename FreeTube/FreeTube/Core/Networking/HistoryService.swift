import Foundation
import OSLog
import YouTubeKit

struct WatchHistoryPage: Sendable {
    let videos: [Video]
    let continuationToken: String?
}

protocol HistoryServicing: Sendable {
    func fetch() async throws -> WatchHistoryPage
    func fetchMore(continuation: String) async throws -> WatchHistoryPage
    func remove(videoID: String) async throws
}

/// Wraps `HistoryResponse` (groups videos by date) and `RemoveVideoFromHistroryResponse`. The
/// raw response splits videos into `HistoryBlock`s keyed by a localized date string; we flatten
/// them into a single `[Video]` here. Day groupings are still available in the response if a
/// future UI needs them, but the current `HistoryScreen` just shows a flat list.
final class HistoryService: HistoryServicing {
    private let client: YouTubeKitClient
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "HistoryService")

    nonisolated init(client: YouTubeKitClient = .shared) {
        self.client = client
    }

    func fetch() async throws -> WatchHistoryPage {
        log.info("Fetching watch history")
        let response: HistoryResponse
        do {
            response = try await HistoryResponse.sendThrowingRequest(
                youtubeModel: client.model,
                data: [:]
            )
        } catch {
            log.error("HistoryResponse failed: \(String(describing: error), privacy: .public)")
            throw YouTubeServiceError.network(error)
        }
        guard !response.isDisconnected else {
            throw YouTubeServiceError.notAuthenticated
        }
        return WatchHistoryPage(
            videos: flatten(response.results),
            continuationToken: response.continuationToken
        )
    }

    func fetchMore(continuation: String) async throws -> WatchHistoryPage {
        let response: HistoryResponse.Continuation
        do {
            response = try await HistoryResponse.Continuation.sendThrowingRequest(
                youtubeModel: client.model,
                data: [.continuation: continuation]
            )
        } catch {
            throw YouTubeServiceError.network(error)
        }
        return WatchHistoryPage(
            videos: flatten(response.results),
            continuationToken: response.continuationToken
        )
    }

    func remove(videoID: String) async throws {
        log.info("Remove from history \(videoID, privacy: .public) — not implemented (needs suppress token)")
        throw YouTubeServiceError.notAuthenticated
    }

    /// Flattens `HistoryBlock` groups into a single video array, preserving the response's
    /// newest-first ordering. Each block carries `videosArray` (regular videos with suppression
    /// tokens for delete) plus shorts blocks; we ignore the shorts groupings here.
    private func flatten(_ blocks: [HistoryResponse.HistoryBlock]) -> [Video] {
        var out: [Video] = []
        for block in blocks {
            for entry in block.videosArray {
                out.append(Mappers.video(from: entry.video))
            }
        }
        return out
    }
}
