import Foundation
import SwiftData

@available(iOS 17.0, *)
@Model
final class WatchHistoryEntry {
    @Attribute(.unique) var videoID: String
    var title: String
    var channelName: String
    var thumbnailURL: URL?
    var watchedAt: Date
    var lastPosition: TimeInterval
    /// Total duration of the video at the moment `lastPosition` was last written. Stored so we
    /// can render a progress bar on cards without re-fetching duration from YouTube, and so
    /// resume-on-tap can skip entries that already reached the end. Default 0 — SwiftData
    /// lightweight migration fills existing rows with this on first read after the upgrade.
    var duration: TimeInterval = 0

    init(
        videoID: String,
        title: String,
        channelName: String,
        thumbnailURL: URL?,
        watchedAt: Date = .now,
        lastPosition: TimeInterval = 0,
        duration: TimeInterval = 0
    ) {
        self.videoID = videoID
        self.title = title
        self.channelName = channelName
        self.thumbnailURL = thumbnailURL
        self.watchedAt = watchedAt
        self.lastPosition = lastPosition
        self.duration = duration
    }
}
