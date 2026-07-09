import Foundation
import MediaPlayer
import UIKit
import OSLog

/// Keeps `MPNowPlayingInfoCenter.default().nowPlayingInfo` in sync with the player. The
/// `PlayerStateManager` calls `update(...)` and `clear()`.
@MainActor
enum NowPlayingCenter {
    private static let log = AppLog(subsystem: "com.leshko.freetube", category: "NowPlaying")

    static func update(
        title: String,
        artist: String,
        duration: TimeInterval,
        elapsed: TimeInterval,
        rate: Float,
        artwork: UIImage?
    ) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: rate
        ]
        if let artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    static func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        log.info("Now Playing cleared")
    }
}
