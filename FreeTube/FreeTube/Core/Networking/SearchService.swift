import Foundation
import OSLog
import YouTubeKit

struct SearchResult: Sendable {
    let videos: [Video]
    let channels: [Channel]
    let playlists: [Playlist]
    let continuationToken: String?
}

protocol SearchServicing: Sendable {
    func search(query: String, restricted: Bool) async throws -> SearchResult
    func fetchMore(continuation: String) async throws -> SearchResult
    func autocomplete(query: String) async throws -> [SearchSuggestion]
}

/// Wraps `SearchResponse` (+Continuation, +Restricted) and `AutoCompletionResponse`.
final class SearchService: SearchServicing {
    private let client: YouTubeKitClient
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "SearchService")

    nonisolated init(client: YouTubeKitClient = .shared) {
        self.client = client
    }

    func search(query: String, restricted: Bool) async throws -> SearchResult {
        log.info("Search query=\(query, privacy: .public) restricted=\(restricted, privacy: .public)")
        do {
            if restricted {
                let response = try await SearchResponse.Restricted.sendThrowingRequest(
                    youtubeModel: client.model,
                    data: [.query: query]
                )
                return mapResults(response.results, continuation: response.continuationToken)
            } else {
                let response = try await SearchResponse.sendThrowingRequest(
                    youtubeModel: client.model,
                    data: [.query: query]
                )
                return mapResults(response.results, continuation: response.continuationToken)
            }
        } catch {
            throw YouTubeServiceError.network(error)
        }
    }

    func fetchMore(continuation: String) async throws -> SearchResult {
        do {
            let response = try await SearchResponse.Continuation.sendThrowingRequest(
                youtubeModel: client.model,
                data: [.continuation: continuation]
            )
            return mapResults(response.results, continuation: response.continuationToken)
        } catch {
            throw YouTubeServiceError.network(error)
        }
    }

    func autocomplete(query: String) async throws -> [SearchSuggestion] {
        do {
            let response = try await AutoCompletionResponse.sendThrowingRequest(
                youtubeModel: client.model,
                data: [.query: query]
            )
            return response.autoCompletionEntries.map { SearchSuggestion(text: $0) }
        } catch {
            throw YouTubeServiceError.network(error)
        }
    }

    private func mapResults(_ results: [any YTSearchResult], continuation: String?) -> SearchResult {
        var videos: [Video] = []
        var channels: [Channel] = []
        var playlists: [Playlist] = []
        for result in results {
            if let yt = result as? YTVideo {
                videos.append(Mappers.video(from: yt))
            } else if let yt = result as? YTChannel {
                channels.append(Mappers.channel(from: yt))
            } else if let yt = result as? YTPlaylist {
                playlists.append(Mappers.playlist(from: yt))
            }
        }
        return SearchResult(videos: videos, channels: channels, playlists: playlists, continuationToken: continuation)
    }
}
