import SwiftUI
import AVKit

/// CLAUDE.md §8: "Use `AVPlayerViewController` wrapped in `UIViewControllerRepresentable` for the
/// video surface. Get free system controls, AirPlay, PiP."
@available(iOS 17.0, *)
struct PlayerSurface: UIViewControllerRepresentable {
    let player: AVPlayer
    var showsControls: Bool = true
    /// **PiP must be triggered explicitly by the user via the AVPlayerViewController PiP button**
    /// — never on app backgrounding. The auto-on-background behavior was disorienting (audio
    /// would continue with a tiny floating window appearing the moment the user switched apps)
    /// and burned battery. The PiP button itself still works because `allowsPictureInPicturePlayback`
    /// stays on. Default is `false` for `entersPiPAutomatically`.
    var entersPiPAutomatically: Bool = false

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = showsControls
        controller.canStartPictureInPictureAutomaticallyFromInline = entersPiPAutomatically
        controller.allowsPictureInPicturePlayback = true
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        controller.player = player
        controller.showsPlaybackControls = showsControls
        controller.canStartPictureInPictureAutomaticallyFromInline = entersPiPAutomatically
    }
}
