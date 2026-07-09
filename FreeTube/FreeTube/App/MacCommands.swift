import SwiftUI

/// Menu-bar entries and keyboard shortcuts. Attached to the root `WindowGroup` in
/// `FreeTubeApp` via `.commands { MacCommands(player:) }`.
///
/// **Why this exists.** On a Mac (whether via "Designed for iPad on Mac" or a future
/// Catalyst build) the system mounts an AppKit menu bar over our SwiftUI scene. Without
/// explicit `Commands`, users get only the OS-provided defaults — no app-level shortcuts.
/// We add three groups:
///
/// 1. **Settings (⌘,)** — `CommandGroup(replacing: .appSettings)` is the standard slot;
///    we post a notification that `RootView` reads to switch its `TabView` selection to
///    the Settings tab. (No separate Settings scene — Settings is one of the five tabs.)
/// 2. **Navigate menu (⌘1 / ⌘F / ⌘2 / ⌘3)** — quick-jump to tab bar entries. ⌘F is the
///    standard "find" shortcut everywhere on Mac, so it maps to Search.
/// 3. **Playback menu (Space, ⌘←/→, ⌘↑/↓)** — transport controls mirroring what
///    `RemoteCommandCenter` wires for the lock screen on iOS.
///
/// **Plumbing.** Tab switches go through `NotificationCenter` because the selected tab
/// lives inside `RootView` (`@State`), which isn't reachable from a `Scene`-level
/// `Commands` builder. Player controls call `PlayerStateManager` directly since it's
/// passed in by reference.
///
/// **iPhone/iPad.** `Commands` produces no visible menu bar on iPhone and only adds
/// keyboard shortcuts on iPad with a hardware keyboard. Harmless to register everywhere.
@available(iOS 17.0, *)
struct MacCommands: Commands {
    /// Can't use `@Environment` inside a `Commands` struct (it's not a `View`), so the
    /// player has to be threaded through from `FreeTubeApp`.
    let player: PlayerStateManager

    var body: some Commands {
        // 1. Replace the standard "App Settings" item (⌘,) with one that selects our
        // in-window Settings tab instead of opening a separate Settings scene.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                postTab(.settings)
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        // 2. Navigate menu — quick-jump to tabs. Search lives inside Home now (folded in
        // from the former dedicated Search tab), so ⌘F also lands on Home — the host's
        // `.searchable` field is in the navigation bar and focus-able on macOS.
        CommandMenu("Navigate") {
            Button("Search") { postTab(.search) }
                .keyboardShortcut("1", modifiers: .command)
            Button("Find…") { postTab(.search) }
                .keyboardShortcut("f", modifiers: .command)
            Button("Library") { postTab(.library) }
                .keyboardShortcut("2", modifiers: .command)
            Button("Link") { postTab(.link) }
                .keyboardShortcut("3", modifiers: .command)
            Button("Downloads") { postTab(.downloads) }
                .keyboardShortcut("4", modifiers: .command)
        }

        // 3. Playback menu — same controls as the lock-screen remote on iOS. Disabled
        // when no video is loaded so the menu doesn't lie about being usable.
        CommandMenu("Playback") {
            Button(player.isPlaying ? "Pause" : "Play") {
                player.togglePlayPause()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(player.currentVideo == nil)

            Divider()

            Button("Skip Forward 15s") {
                player.seekRelative(by: 15)
            }
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .disabled(player.currentVideo == nil)

            Button("Skip Backward 15s") {
                player.seekRelative(by: -15)
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .disabled(player.currentVideo == nil)

            Divider()

            Button("Next") {
                player.playNext()
            }
            .keyboardShortcut(.downArrow, modifiers: .command)
            .disabled(player.currentVideo == nil)

            Button("Previous") {
                player.playPrevious()
            }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(player.currentVideo == nil)
        }
    }

    private func postTab(_ tab: RootView.Tab) {
        NotificationCenter.default.post(name: .freetubeSelectTab, object: tab)
    }
}

extension Notification.Name {
    /// Posted by `MacCommands` when the user picks a tab via menu / shortcut. `RootView`
    /// listens and updates its `@State selectedTab`. The `object` is a `RootView.Tab`.
    static let freetubeSelectTab = Notification.Name("com.leshko.freetube.selectTab")
}
