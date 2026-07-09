import Foundation

enum PlaybackSource: Sendable, Hashable {
    case direct(URL)
    case localFile(URL)
    /// Separate video-only + audio-only streams that the player must stitch together via
    /// `AVMutableComposition`. This is how YouTube delivers most non-music VOD on the iOS-client
    /// endpoint — combined "progressive" formats and HLS manifests are reserved for a small subset.
    case composite(video: URL, audio: URL)

    var url: URL {
        switch self {
        case .direct(let url): return url
        case .localFile(let url): return url
        case .composite(let video, _): return video
        }
    }
}

protocol PlaybackResolving {
    func resolve(videoID: String, quality: VideoQuality) async throws -> PlaybackSource
}
