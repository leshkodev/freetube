import Foundation
import OSLog
import YouTubeKit

struct AccountInfo: Sendable {
    let displayName: String
    let handle: String?
    let avatarURL: URL?
    let channelID: String?
}

struct AccountLibrary: Sendable {
    let history: [Video]
    let historyCount: Int?
    let watchLater: [Video]
    let watchLaterCount: Int?
    let likedVideos: [Video]
    let likedCount: Int?
    let playlists: [Playlist]
    /// Best-effort channel ID for the signed-in user, harvested from one of the user's owned
    /// playlists in the library response (`YTPlaylist.channel?.channelId`). YouTubeKit's
    /// `AccountInfosResponse` doesn't expose this directly. Used by the Library screen's
    /// "Your videos" row.
    let userChannelID: String?
}

protocol AccountServicing: Sendable {
    func fetchAccountInfo() async throws -> AccountInfo
    func fetchLibrary() async throws -> AccountLibrary
    func fetchPlaylists() async throws -> [Playlist]
}

/// Wraps YouTubeKit's authenticated `Account*Response` types. All three require cookies on
/// `YouTubeModel`; `SessionManager.bootstrap` / `signIn` is responsible for applying them.
/// Each method throws `YouTubeServiceError.notAuthenticated` when YouTubeKit reports
/// `isDisconnected == true` (no valid session) so the UI can route to the login screen.
final class AccountService: AccountServicing {
    private let client: YouTubeKitClient
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "AccountService")

    nonisolated init(client: YouTubeKitClient = .shared) {
        self.client = client
    }

    func fetchAccountInfo() async throws -> AccountInfo {
        log.info("[account] fetchAccountInfo — model.cookies length=\(self.client.model.cookies.count, privacy: .public) alwaysUseCookies=\(self.client.model.alwaysUseCookies, privacy: .public)")
        let response: AccountInfosResponse
        do {
            response = try await AccountInfosResponse.sendThrowingRequest(
                youtubeModel: client.model,
                data: [:]
            )
        } catch {
            log.error("[account] AccountInfosResponse failed: \(String(describing: error), privacy: .public)")
            throw YouTubeServiceError.network(error)
        }
        guard !response.isDisconnected else {
            log.notice("[account] AccountInfosResponse isDisconnected=true (YouTube says logged out) — has name=\(response.name != nil, privacy: .public) handle=\(response.channelHandle != nil, privacy: .public)")
            throw YouTubeServiceError.notAuthenticated
        }
        log.info("[account] AccountInfosResponse OK: name=\(response.name ?? "?", privacy: .public) handle=\(response.channelHandle ?? "?", privacy: .public)")
        return AccountInfo(
            displayName: response.name ?? "",
            handle: response.channelHandle,
            avatarURL: Mappers.bestThumbnailURL(response.avatar),
            // AccountInfosResponse doesn't expose channelID directly; the library response does.
            // Callers that need it should `fetchLibrary` and read `userChannelID` from there.
            channelID: nil
        )
    }

    func fetchLibrary() async throws -> AccountLibrary {
        log.info("Fetching account library")
        let response: AccountLibraryResponse
        do {
            response = try await AccountLibraryResponse.sendThrowingRequest(
                youtubeModel: client.model,
                data: [:]
            )
        } catch {
            log.error("AccountLibraryResponse failed: \(String(describing: error), privacy: .public)")
            throw YouTubeServiceError.network(error)
        }
        guard !response.isDisconnected else {
            throw YouTubeServiceError.notAuthenticated
        }
        let playlists = response.playlists.map(Mappers.playlist(from:))
        let liked = (response.likes?.frontVideos ?? []).map(Mappers.video(from:))
        let later = (response.watchLater?.frontVideos ?? []).map(Mappers.video(from:))
        let history = (response.history?.frontVideos ?? []).map(Mappers.video(from:))
        // Counts come from YTPlaylist.videoCount which is a human-readable string like "1,234"
        // or "1.2K videos". `Mappers.parseAbbreviatedCount` already handles both forms (built
        // for subscriber counts) so we reuse it here.
        //
        // **Why we fall back to `frontVideos.count` when the parse returns nil:**
        // The library response's `history` block typically carries an annotation like
        // "Last viewed today" (a date string, not a number) instead of "N videos" — so
        // `parseAbbreviatedCount` correctly produces nil there. Same can happen with
        // `likes`/`watchLater` if YouTube's locale-specific annotation doesn't include digits.
        // Falling back to `frontVideos.count` lets the Library menu always show a meaningful
        // number (the count of preview items YouTube returned). It's a lower bound, not a
        // grand total — so we surface it with a `+` suffix in the UI when the response had
        // more pages to fetch via `HistoryResponse` / `PlaylistInfosResponse`.
        let likedCount = Mappers.parseAbbreviatedCount(response.likes?.videoCount) ?? (liked.isEmpty ? nil : liked.count)
        let watchLaterCount = Mappers.parseAbbreviatedCount(response.watchLater?.videoCount) ?? (later.isEmpty ? nil : later.count)
        let historyCount = Mappers.parseAbbreviatedCount(response.history?.videoCount) ?? (history.isEmpty ? nil : history.count)
        // Trace the raw → parsed mapping so we can debug "— shown instead of count" reports
        // without round-tripping through a debugger.
        log.info("[account] library counts — likes raw=\"\(response.likes?.videoCount ?? "nil", privacy: .public)\" preview=\(liked.count, privacy: .public) → \(likedCount.map(String.init) ?? "nil", privacy: .public), watchLater raw=\"\(response.watchLater?.videoCount ?? "nil", privacy: .public)\" preview=\(later.count, privacy: .public) → \(watchLaterCount.map(String.init) ?? "nil", privacy: .public), history raw=\"\(response.history?.videoCount ?? "nil", privacy: .public)\" preview=\(history.count, privacy: .public) → \(historyCount.map(String.init) ?? "nil", privacy: .public)")
        // Pull the user's channel ID off any owned playlist. Every playlist in
        // `AccountLibraryResponse.playlists` is owned by the signed-in user.
        let userChannelID = response.playlists.compactMap { $0.channel?.channelId }.first
        return AccountLibrary(
            history: history,
            historyCount: historyCount,
            watchLater: later,
            watchLaterCount: watchLaterCount,
            likedVideos: liked,
            likedCount: likedCount,
            playlists: playlists,
            userChannelID: userChannelID
        )
    }

    func fetchPlaylists() async throws -> [Playlist] {
        log.info("Fetching account playlists")
        let response: AccountPlaylistsResponse
        do {
            response = try await AccountPlaylistsResponse.sendThrowingRequest(
                youtubeModel: client.model,
                data: [:]
            )
        } catch {
            log.error("AccountPlaylistsResponse failed: \(String(describing: error), privacy: .public)")
            throw YouTubeServiceError.network(error)
        }
        guard !response.isDisconnected else {
            throw YouTubeServiceError.notAuthenticated
        }
        return response.results.map(Mappers.playlist(from:))
    }
}
