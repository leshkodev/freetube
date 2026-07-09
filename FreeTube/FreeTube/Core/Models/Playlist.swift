import Foundation

struct Playlist: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let channelID: String?
    let channelName: String?
    let thumbnailURL: URL?
    let videoCount: Int?
    /// Total view count for the playlist (sum of plays across all videos in it). Only populated
    /// by `PlaylistService.fetchPlaylist` — search/channel listings don't carry this number.
    let viewCount: Int?
    let descriptionText: String?
    let isOwnedByUser: Bool
}

extension Playlist {
    /// Convenience initializer that defaults `viewCount` to nil so existing call sites
    /// (mappers from search results, channel tabs, etc.) keep compiling without each one
    /// being updated to pass an unknown view count.
    init(
        id: String,
        title: String,
        channelID: String?,
        channelName: String?,
        thumbnailURL: URL?,
        videoCount: Int?,
        descriptionText: String?,
        isOwnedByUser: Bool
    ) {
        self.init(
            id: id,
            title: title,
            channelID: channelID,
            channelName: channelName,
            thumbnailURL: thumbnailURL,
            videoCount: videoCount,
            viewCount: nil,
            descriptionText: descriptionText,
            isOwnedByUser: isOwnedByUser
        )
    }
}

struct PlaylistDetails: Sendable {
    let playlist: Playlist
    let videos: [Video]
    let continuationToken: String?
}
