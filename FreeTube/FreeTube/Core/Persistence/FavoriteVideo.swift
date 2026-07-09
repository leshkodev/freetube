import Foundation
import SwiftData

@available(iOS 17.0, *)
@Model
final class FavoriteVideo {
    @Attribute(.unique) var videoID: String
    var title: String
    var channelName: String
    var thumbnailURL: URL?
    var savedAt: Date

    init(
        videoID: String,
        title: String,
        channelName: String,
        thumbnailURL: URL?,
        savedAt: Date = .now
    ) {
        self.videoID = videoID
        self.title = title
        self.channelName = channelName
        self.thumbnailURL = thumbnailURL
        self.savedAt = savedAt
    }
}
