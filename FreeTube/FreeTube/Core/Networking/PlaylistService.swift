import Foundation
import OSLog
import YouTubeKit

struct PlaylistAvailability: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let containsVideo: Bool
    let isPrivate: Bool
}

protocol PlaylistServicing: Sendable {
    func fetchPlaylist(id: String) async throws -> PlaylistDetails
    func fetchMore(continuation: String) async throws -> PlaylistDetails
    func fetchHostablePlaylists(videoID: String) async throws -> [PlaylistAvailability]
    func add(videoID: String, to playlistID: String) async throws
    func removeVideo(playlistVideoID: String, from playlistID: String) async throws
    func removeVideo(byID videoID: String, from playlistID: String) async throws
    func create(title: String, isPrivate: Bool, seedVideoID: String?) async throws -> Playlist
    func delete(playlistID: String) async throws
    func move(playlistVideoID: String, in playlistID: String, toIndex: Int) async throws
}

/// Wraps:
/// - `PlaylistInfosResponse` (+Continuation)
/// - `AllPossibleHostPlaylistsResponse`
/// - `AddVideoToPlaylistResponse` / `RemoveVideoByIdFromPlaylistResponse` / `RemoveVideoFromPlaylistResponse`
/// - `CreatePlaylistResponse` / `DeletePlaylistResponse` / `MoveVideoInPlaylistResponse`
final class PlaylistService: PlaylistServicing {
    private let client: YouTubeKitClient
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "PlaylistService")

    nonisolated init(client: YouTubeKitClient = .shared) {
        self.client = client
    }

    /// Loads a playlist's header (title, description, owning channel, total view/video counts)
    /// plus its first page of videos. YouTubeKit expects the playlist ID prefixed with `VL` for
    /// browse requests; we add it here if the caller passed the bare ID we get from search/channel
    /// listings.
    func fetchPlaylist(id: String) async throws -> PlaylistDetails {
        log.info("Fetching playlist \(id, privacy: .public)")
        let browseID = id.hasPrefix("VL") ? id : "VL" + id
        let response: PlaylistInfosResponse
        do {
            response = try await PlaylistInfosResponse.sendThrowingRequest(
                youtubeModel: client.model,
                data: [.browseId: browseID]
            )
        } catch {
            log.error("PlaylistInfosResponse failed for \(id, privacy: .public): \(String(describing: error), privacy: .public)")
            throw YouTubeServiceError.network(error)
        }
        return mapDetails(response: response, fallbackID: id)
    }

    func fetchMore(continuation: String) async throws -> PlaylistDetails {
        let response: PlaylistInfosResponse.Continuation
        do {
            response = try await PlaylistInfosResponse.Continuation.sendThrowingRequest(
                youtubeModel: client.model,
                data: [.continuation: continuation]
            )
        } catch {
            throw YouTubeServiceError.network(error)
        }
        let videos = response.results.map(Mappers.video(from:))
        let placeholder = Playlist(id: "", title: "", channelID: nil, channelName: nil, thumbnailURL: nil, videoCount: nil, descriptionText: nil, isOwnedByUser: false)
        return PlaylistDetails(playlist: placeholder, videos: videos, continuationToken: response.continuationToken)
    }

    private func mapDetails(response: PlaylistInfosResponse, fallbackID: String) -> PlaylistDetails {
        let owner = response.channel.first
        let playlist = Playlist(
            id: response.playlistId ?? fallbackID,
            title: response.title ?? "",
            channelID: owner?.channelId,
            channelName: owner?.name,
            thumbnailURL: Mappers.bestThumbnailURL(response.thumbnails),
            videoCount: parseInteger(response.videoCount),
            viewCount: Mappers.parseAbbreviatedCount(response.viewCount),
            descriptionText: response.playlistDescription,
            isOwnedByUser: response.userInteractions.isEditable ?? false
        )
        // Backfill the owning channel's name onto videos that lack one (lockup-decoded items
        // skip the channel field entirely).
        let ownerName = owner?.name ?? ""
        let ownerID = owner?.channelId ?? ""
        let ownerThumb = Mappers.bestThumbnailURL(owner?.thumbnails ?? [])
        let videos: [Video] = response.results.map { yt in
            let v = Mappers.video(from: yt)
            return Video(
                id: v.id,
                title: v.title,
                channelID: v.channelID.isEmpty ? ownerID : v.channelID,
                channelName: v.channelName.isEmpty ? ownerName : v.channelName,
                channelThumbnailURL: v.channelThumbnailURL ?? ownerThumb,
                thumbnailURL: v.thumbnailURL,
                duration: v.duration,
                viewCount: v.viewCount,
                publishedAt: v.publishedAt,
                publishedRelative: v.publishedRelative,
                descriptionSnippet: v.descriptionSnippet,
                isLive: v.isLive,
                isShort: v.isShort
            )
        }
        return PlaylistDetails(playlist: playlist, videos: videos, continuationToken: response.continuationToken)
    }

    private func parseInteger(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        return Int(raw.filter(\.isNumber))
    }

    /// Lists all the user's playlists that a given video can be added to, plus a flag indicating
    /// whether the video is already in each playlist. Backs the "Add to playlist" sheet so we
    /// can show checkmarks next to playlists that already contain the video.
    func fetchHostablePlaylists(videoID: String) async throws -> [PlaylistAvailability] {
        log.info("[playlists] fetchHostable videoID=\(videoID, privacy: .public)")
        do {
            let response = try await AllPossibleHostPlaylistsResponse.sendThrowingRequest(
                youtubeModel: client.model,
                data: [.browseId: videoID]
            )
            if response.isDisconnected {
                log.notice("[playlists] fetchHostable: response isDisconnected=true")
                throw YouTubeServiceError.notAuthenticated
            }
            return response.playlistsAndStatus.map { entry in
                PlaylistAvailability(
                    id: entry.playlist.playlistId,
                    title: entry.playlist.title ?? "",
                    containsVideo: entry.isVideoPresentInside,
                    isPrivate: entry.playlist.privacy == .private
                )
            }
        } catch let error as YouTubeServiceError {
            throw error
        } catch {
            log.error("[playlists] fetchHostable failed: \(String(describing: error), privacy: .public)")
            throw YouTubeServiceError.network(error)
        }
    }

    /// Adds a video to the given playlist. Pass the **bare** playlist id (no `VL` prefix) —
    /// YouTubeKit's validator (`playlistIdWithoutVLPrefixValidator`) requires it.
    func add(videoID: String, to playlistID: String) async throws {
        let bareID = playlistID.hasPrefix("VL") ? String(playlistID.dropFirst(2)) : playlistID
        log.info("[playlists] add videoID=\(videoID, privacy: .public) → playlistID=\(bareID, privacy: .public)")
        do {
            let response = try await AddVideoToPlaylistResponse.sendThrowingRequest(
                youtubeModel: client.model,
                data: [.browseId: bareID, .movingVideoId: videoID]
            )
            if response.isDisconnected {
                throw YouTubeServiceError.notAuthenticated
            }
        } catch let error as YouTubeServiceError {
            throw error
        } catch {
            log.error("[playlists] add failed: \(String(describing: error), privacy: .public)")
            throw YouTubeServiceError.network(error)
        }
    }

    func removeVideo(playlistVideoID: String, from playlistID: String) async throws {
        throw YouTubeServiceError.notAuthenticated
    }

    func removeVideo(byID videoID: String, from playlistID: String) async throws {
        throw YouTubeServiceError.notAuthenticated
    }

    /// Creates a new playlist with `title`, optionally seeding it with one initial video.
    /// `isPrivate` toggles between `PRIVATE` and `PUBLIC` — YouTube also supports `UNLISTED`
    /// but the iOS-app convention is a binary public/private toggle, so we stick with that.
    func create(title: String, isPrivate: Bool, seedVideoID: String?) async throws -> Playlist {
        let privacy = isPrivate ? "PRIVATE" : "PUBLIC"
        log.info("[playlists] create title=\(title, privacy: .public) privacy=\(privacy, privacy: .public) seed=\(seedVideoID ?? "-", privacy: .public)")
        var data: [HeadersList.AddQueryInfo.ContentTypes: String] = [
            .query: title,
            .params: privacy
        ]
        if let seedVideoID { data[.movingVideoId] = seedVideoID }
        do {
            let response = try await CreatePlaylistResponse.sendThrowingRequest(
                youtubeModel: client.model,
                data: data
            )
            if response.isDisconnected {
                throw YouTubeServiceError.notAuthenticated
            }
            let id = response.createdPlaylistId ?? ""
            return Playlist(
                id: id.hasPrefix("VL") ? id : "VL" + id,
                title: title,
                channelID: response.playlistCreatorId,
                channelName: nil,
                thumbnailURL: nil,
                videoCount: seedVideoID != nil ? 1 : 0,
                descriptionText: nil,
                isOwnedByUser: true
            )
        } catch let error as YouTubeServiceError {
            throw error
        } catch {
            log.error("[playlists] create failed: \(String(describing: error), privacy: .public)")
            throw YouTubeServiceError.network(error)
        }
    }

    func delete(playlistID: String) async throws {
        throw YouTubeServiceError.notAuthenticated
    }

    func move(playlistVideoID: String, in playlistID: String, toIndex: Int) async throws {
        throw YouTubeServiceError.notAuthenticated
    }
}
