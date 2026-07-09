import Foundation
import SwiftData

/// User-saved YouTube playlist. Backs the "Add to favorites" action in the playlist detail
/// screen. Stored in SwiftData so it survives launches and stays in sync with the Library tab.
@available(iOS 17.0, *)
@Model
final class FavoritePlaylist {
    @Attribute(.unique) var playlistID: String
    var title: String
    var channelName: String
    var thumbnailURL: URL?
    var videoCount: Int?
    var savedAt: Date

    init(
        playlistID: String,
        title: String,
        channelName: String,
        thumbnailURL: URL?,
        videoCount: Int?,
        savedAt: Date = .now
    ) {
        self.playlistID = playlistID
        self.title = title
        self.channelName = channelName
        self.thumbnailURL = thumbnailURL
        self.videoCount = videoCount
        self.savedAt = savedAt
    }
}
