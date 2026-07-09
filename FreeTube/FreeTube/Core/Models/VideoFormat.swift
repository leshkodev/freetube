import Foundation

/// Adapted from YouTubeKit's `DownloadFormat`. Service layer translates the YouTubeKit type into this.
struct VideoFormat: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL?
    let mimeType: String
    let height: Int?
    let width: Int?
    let bitrate: Int?
    let audioSampleRate: Int?
    let isVideoOnly: Bool
    let isAudioOnly: Bool
    let containsBothTracks: Bool
}
