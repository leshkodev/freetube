import Foundation
import Observation

@available(iOS 17.0, *)
@Observable
@MainActor
final class SaveToPlaylistViewModel {
    let videoID: String
    private(set) var available: [PlaylistAvailability] = []
    private(set) var isLoading: Bool = false
    var errorState: ErrorState?

    private let service: any PlaylistServicing

    init(videoID: String, service: any PlaylistServicing = PlaylistService()) {
        self.videoID = videoID
        self.service = service
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            available = try await service.fetchHostablePlaylists(videoID: videoID)
        } catch {
            errorState = ErrorState(from: error)
        }
    }

    func toggle(_ playlist: PlaylistAvailability) async {
        do {
            if playlist.containsVideo {
                try await service.removeVideo(byID: videoID, from: playlist.id)
            } else {
                try await service.add(videoID: videoID, to: playlist.id)
            }
            if let idx = available.firstIndex(where: { $0.id == playlist.id }) {
                let updated = PlaylistAvailability(
                    id: playlist.id,
                    title: playlist.title,
                    containsVideo: !playlist.containsVideo,
                    isPrivate: playlist.isPrivate
                )
                available[idx] = updated
            }
        } catch {
            errorState = ErrorState(from: error)
        }
    }

    func createNew(title: String, isPrivate: Bool) async {
        do {
            _ = try await service.create(title: title, isPrivate: isPrivate, seedVideoID: videoID)
            await load()
        } catch {
            errorState = ErrorState(from: error)
        }
    }
}
