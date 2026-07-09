import SwiftUI
import SwimplyPlayIndicator

/// Animated audio-bars indicator (via `SwimplyPlayIndicator`) marking the currently-playing
/// video in lists. Reads `PlayerStateManager` to derive the indicator's `AudioState`:
///   - `.play` — this row's video matches `player.currentVideo` and `isPlaying == true`
///   - `.pause` — this row's video matches but playback is paused (bars freeze mid-animation)
///   - `.stop` — this row isn't the current video (indicator collapses to opacity 0 internally)
///
/// Wrap call sites with a simple identity check so we only mount this view where it's relevant.
/// SwimplyPlayIndicator manages its own animation lifecycle; we just keep the state binding fresh.
@available(iOS 17.0, *)
struct NowPlayingIndicator: View {
    let videoID: String
    @Environment(PlayerStateManager.self) private var player

    /// Local mirror that the library mutates via its `@Binding`. We sync from the player on
    /// every render so taps that play/pause externally are reflected in the bars.
    @State private var audioState: SwimplyPlayIndicator.AudioState = .stop

    var body: some View {
        SwimplyPlayIndicator(
            state: $audioState,
            count: 3,
            color: Color.accentColor,
            style: .modern
        )
        .frame(width: 16, height: 16)
        .onChange(of: player.currentVideo?.id, initial: true) { _, _ in syncState() }
        .onChange(of: player.isPlaying, initial: true) { _, _ in syncState() }
    }

    private func syncState() {
        guard player.currentVideo?.id == videoID else {
            audioState = .stop
            return
        }
        audioState = player.isPlaying ? .play : .pause
    }
}
