import Foundation
import MediaPlayer
import OSLog

/// Wires `MPRemoteCommandCenter` to the active `PlayerStateManager`. Call `wire(to:)` once at launch
/// after constructing the player state manager. The targets retain weak refs to avoid retain cycles.
@MainActor
enum RemoteCommandCenter {
    private static let log = AppLog(subsystem: "com.leshko.freetube", category: "RemoteCommands")
    private static let skipInterval: TimeInterval = 15

    static func wire(to player: PlayerStateManager) {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)

        center.skipForwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]

        center.playCommand.addTarget { [weak player] _ in
            player?.play()
            return .success
        }
        center.pauseCommand.addTarget { [weak player] _ in
            player?.pause()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak player] _ in
            player?.togglePlayPause()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak player] _ in
            player?.playNext()
            return .success
        }
        center.previousTrackCommand.addTarget { [weak player] _ in
            player?.playPrevious()
            return .success
        }
        center.skipForwardCommand.addTarget { [weak player] _ in
            player?.seekRelative(by: skipInterval)
            return .success
        }
        center.skipBackwardCommand.addTarget { [weak player] _ in
            player?.seekRelative(by: -skipInterval)
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak player] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            player?.seek(to: event.positionTime)
            return .success
        }

        log.info("Remote command center wired")
    }
}
