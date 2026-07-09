import Foundation
import Observation

@available(iOS 17.0, *)
@Observable
@MainActor
final class PlaylistViewModel {
    let playlistID: String
    private(set) var details: PlaylistDetails?
    private(set) var isLoading: Bool = false
    /// Separate flag so the row-level prefetch trigger doesn't fire while a previous
    /// `loadMore` is still in flight.
    private(set) var isLoadingMore: Bool = false
    var errorState: ErrorState?

    private let service: any PlaylistServicing

    init(playlistID: String, service: any PlaylistServicing = PlaylistService()) {
        self.playlistID = playlistID
        self.service = service
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            details = try await service.fetchPlaylist(id: playlistID)
        } catch {
            errorState = ErrorState(from: error)
        }
    }

    /// True when the current page has a continuation token and no fetch is in flight.
    var canLoadMore: Bool {
        details?.continuationToken != nil && !isLoadingMore && !isLoading
    }

    /// Appends the next page of videos from the playlist's continuation. Replaces `details`
    /// with a new value (so `@Observable` notices), preserving the playlist header and the
    /// already-loaded videos.
    func loadMore() async {
        guard let current = details, let token = current.continuationToken, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await service.fetchMore(continuation: token)
            details = PlaylistDetails(
                playlist: current.playlist,
                videos: current.videos + page.videos,
                continuationToken: page.continuationToken
            )
        } catch {
            errorState = ErrorState(from: error)
        }
    }

    func move(from source: IndexSet, to destination: Int) async {
        guard
            let details,
            let sourceIndex = source.first
        else { return }
        let item = details.videos[sourceIndex]
        do {
            try await service.move(playlistVideoID: item.id, in: playlistID, toIndex: destination)
            await load()
        } catch {
            errorState = ErrorState(from: error)
        }
    }

    func delete(_ video: Video) async {
        do {
            try await service.removeVideo(byID: video.id, from: playlistID)
            await load()
        } catch {
            errorState = ErrorState(from: error)
        }
    }
}
