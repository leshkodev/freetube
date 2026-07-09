import SwiftUI
import LNPopupUI
import Kingfisher
import OSLog
import UIKit

/// Top-level tabbed shell. CLAUDE.md §8: mini-player sits above the tab bar and persists across tabs.
///
/// Tab layout (5):
/// - Search (search field, recent searches, and the home video feed in one screen)
/// - Library (subsumes the former Account + Subscriptions tabs; includes Favorites/Recents/Playlists/Login)
/// - Link (yt-dlp-powered universal downloader; pastes any link from ~2,000 supported sites)
/// - Downloads (saved videos + live transfer queue with progress)
/// - Settings (preferences, quality, reset-session)
@available(iOS 17.0, *)
struct RootView: View {
    @Environment(PlayerStateManager.self) private var player
    @State private var selectedTab: Tab = .search
    /// Direct observation of the shared download manager — no AsyncStream subscription needed since
    /// `DownloadManager` is itself `@Observable`. Both this view (for the badge) and `DownloadsScreen`
    /// (for the list) read the same source of truth.
    @State private var downloads = DownloadManager.shared
    /// Cached thumbnail for the current video so the mini-player bar shows the actual preview instead
    /// of a placeholder icon. Loaded via Kingfisher's cache when `currentVideo` changes.
    @State private var thumbnail: UIImage?

    enum Tab: Hashable {
        case search, library, link, downloads, settings
    }

    private var activeDownloadsCount: Int {
        downloads.activeTasks.filter { snapshot in
            switch snapshot.state {
            case .queued, .downloading, .paused: return true
            case .completed, .failed: return false
            }
        }.count
    }

    var body: some View {
        @Bindable var player = player

        TabView(selection: $selectedTab) {
            HomeScreen()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(Tab.search)

            LibraryScreen()
                .tabItem { Label("Library", systemImage: "play.square.stack") }
                .tag(Tab.library)

            FetchScreen()
                .tabItem { Label("Link", systemImage: "link") }
                .tag(Tab.link)

            DownloadsScreen()
                .tabItem {
                    Label("Downloads", systemImage: "arrow.down.circle")
                }
                .badge(activeDownloadsCount > 0 ? activeDownloadsCount : 0)
                .tag(Tab.downloads)

            SettingsScreen()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
        .popup(
            isBarPresented: $player.miniPlayerVisible,
            isPopupOpen: $player.fullScreenPresented
        ) {
            // The popup's content closure is called once and its result is hosted; SwiftUI does NOT
            // re-evaluate the closure on every parent body re-render. So any modifier that takes a
            // captured value (like `.popupProgress(value)`) freezes at the closure-creation time.
            // To get live progress updates we wrap the modifiers in `PopupContentWrapper`, which is
            // itself a `View` observing the player — when `player.elapsed` changes, the wrapper's
            // body re-renders and `.popupProgress(...)` re-applies with the new value.
            PopupContentWrapper(thumbnail: thumbnail)
        }
        // `.drag` enables LNPopupUI's pull-down-from-content gesture for collapsing the
        // expanded player. Previously we had `.snap` here PLUS a hand-rolled `DragGesture` in
        // `FullScreenPlayer.body` — the two raced each other and the visible offset wouldn't
        // track the finger during the drag once playback became interactive. `.drag` alone is
        // what LNPopupUI ships for this exact use case; the popup bar's own tap-to-open still
        // works the same.
        .popupInteractionStyle(UIViewController.PopupInteractionStyle.drag)
        .popupCloseButtonStyle(LNPopupCloseButton.Style.none)
        .popupBarStyle(LNPopupBar.Style.prominent)
        // Explicitly enable the thin progress line at the bottom of the popup bar so playback
        // and download progress are always visible without expanding the player.
        .popupBarProgressViewStyle(.bottom)
        .task {
            await SessionManager.shared.bootstrap()
        }
        // Refresh the cached thumbnail whenever the user picks a new video. The mini-player's
        // `popupImage` reads this so it shows the actual preview instead of a placeholder icon.
        .onChange(of: player.currentVideo?.id, initial: true) {
            loadThumbnailForCurrentVideo()
        }
        // Force a light-content status bar (white glyphs) while the full-screen player is up.
        // SwiftUI's `.preferredColorScheme(.dark)` on the popup content doesn't propagate through
        // LNPopupUI's hosting chain to UIKit's status-bar style, but flipping the window's
        // `overrideUserInterfaceStyle = .dark` does — UIKit recomputes the status bar trait from
        // that, gets `.dark`, and switches the bar to light content. We restore `.unspecified` when
        // the popup collapses so the rest of the app honors the system appearance again.
        .onChange(of: player.fullScreenPresented) { _, presented in
            updateStatusBarOverride(forFullScreenOpen: presented)
        }
        // Menu-bar / keyboard-shortcut driven tab switching from `MacCommands`. The
        // notification is meaningful only on Mac (where the menu bar exists) and on iPad
        // with a hardware keyboard; everywhere else nobody posts it and this is a no-op.
        .onReceive(NotificationCenter.default.publisher(for: .freetubeSelectTab)) { note in
            if let tab = note.object as? Tab {
                selectedTab = tab
            }
        }
    }

    private func updateStatusBarOverride(forFullScreenOpen open: Bool) {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first
        window?.overrideUserInterfaceStyle = open ? .dark : .unspecified
    }

    /// Refreshes `thumbnail` whenever the current video changes. Tries three sources in order:
    ///  1. Kingfisher's in-memory cache for the video's `thumbnailURL` (synchronous → no flash).
    ///  2. `DownloadsStore`'s xattr-stored compressed thumbnail (for videos played from the Downloads tab,
    ///     where the `Video` object the screen built has `thumbnailURL == nil`).
    ///  3. Async Kingfisher fetch from disk/network if neither of the above hit.
    /// Clears `thumbnail` immediately first so we don't show the previous video's preview while
    /// the new one is loading.
    private func loadThumbnailForCurrentVideo() {
        thumbnail = nil

        guard let video = player.currentVideo else { return }

        // 1. Synchronous in-memory cache for the thumbnail URL.
        if let url = video.thumbnailURL,
           let cached = ImageCache.default.retrieveImageInMemoryCache(forKey: url.cacheKey) {
            thumbnail = cached
            return
        }

        // 2. Xattr-stored thumbnail for downloaded videos. `DownloadsStore` keeps the
        // current snapshot in memory, so the lookup is synchronous and the compressed JPEG
        // bytes decode straight to a `UIImage`.
        let videoID = video.id
        if let data = DownloadsStore.shared.thumbnail(forVideoID: videoID),
           let image = UIImage(data: data) {
            self.thumbnail = image
            return
        }

        // 3. Async network/disk-cache fetch (in parallel with the xattr lookup above —
        // whichever completes first and matches the current video wins).
        guard let url = video.thumbnailURL else { return }
        KingfisherManager.shared.retrieveImage(with: url) { [videoID = video.id] result in
            guard case .success(let value) = result else { return }
            Task { @MainActor in
                // Guard against a race: if the user has already switched to another video while
                // this fetch was inflight, don't stomp the new thumbnail with the stale one.
                guard self.player.currentVideo?.id == videoID else { return }
                self.thumbnail = value.image
            }
        }
    }

    /// Mini-player leading image. While downloading we show a fixed glyph (the user can't see a
    /// video they don't have yet); once playback is ready we swap in the real video thumbnail; if
    /// the thumbnail isn't loaded yet (or the video lacks one), fall back to the play-rectangle.
    private var popupImage: Image {
        switch player.loadState {
        case .resolving, .downloading:
            return Image(systemName: popupImageName)
        default:
            if let thumbnail {
                return Image(uiImage: thumbnail)
            }
            return Image(systemName: "play.rectangle.fill")
        }
    }

    private var progressValue: Float {
        PopupContentWrapper.progress(for: player)
    }

    private var popupSubtitle: String {
        switch player.loadState {
        case .resolving:
            return "Preparing…"
        case .downloading(let progress, let phase):
            guard let progress else { return "Processing…" }
            let percent = Int(progress * 100)
            if let phase, phase == "video" || phase == "audio" {
                return "Downloading \(phase) \(percent)%"
            }
            return "Downloading \(percent)%"
        case .failed(let msg):
            return msg
        case .idle, .readyToPlay:
            return player.currentVideo?.channelName ?? ""
        }
    }

    /// Swap the mini-player's leading icon to an arrow.down.circle while we're downloading so it's
    /// obvious the bar isn't ready to play yet.
    private var popupImageName: String {
        switch player.loadState {
        case .resolving, .downloading: return "arrow.down.circle.fill"
        default: return "play.rectangle.fill"
        }
    }
}

/// Hosts the popup's `FullScreenPlayer` and all of its `popup*(...)` metadata modifiers.
///
/// **Why this exists:** `RootView.popup { ... }` calls its content closure once at popup-presentation
/// time, so any captured value (like `progressValue`) freezes there. Wrapping the content in a real
/// `View` makes SwiftUI's observation system re-render the body when the player's state changes.
///
/// **Why state-driven progress and not direct read:** even with @Environment observation, in
/// practice the `.popupProgress(_:)` preference key didn't always re-apply on every body re-render
/// (suspected: LNPopupUI's preference reducer coalesces same-valued updates, and SwiftUI may skip
/// modifier re-application when the captured Float equals the previous one byte-for-byte). Driving
/// it through explicit `@State` mirrors and `.onChange` handlers forces the modifier to see a fresh
/// captured value every time the player ticks.
/// Made non-private so `MacRootView` can reuse the same popup chrome when running on
/// Mac via "Designed for iPad" — same look as the iOS mini-bar, same drag-to-expand
/// behavior, no duplicated styling.
@available(iOS 17.0, *)
struct PopupContentWrapper: View {
    @Environment(PlayerStateManager.self) private var player
    let thumbnail: UIImage?

    /// Mirrored progress state so `.popupProgress(_:)` always receives a fresh-captured value.
    @State private var progress: Float = 0
    @State private var subtitleText: String = ""

    private static let log = AppLog(subsystem: "com.leshko.freetube", category: "PopupProgress")

    var body: some View {
        FullScreenPlayer()
            .popupTitle(player.currentVideo?.title ?? "", subtitle: subtitleText)
            .popupImage(image)
            .popupProgress(progress)
            .popupBarButtons {
                ToolbarItemGroup(placement: .popupBar) {
                    Button {
                        player.togglePlayPause()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .foregroundStyle(Color.primary)
                    }
                    Button {
                        player.playNext()
                    } label: {
                        Image(systemName: "forward.fill")
                            .foregroundStyle(Color.primary)
                    }
                }
            }
            // Pump the mirrored state whenever any input changes. iOS 17's @Observable observation
            // makes these `onChange` fire reliably even though SwiftUI's modifier diffing wouldn't.
            .onChange(of: player.elapsed, initial: true) { old, new in
                // Self.log.debug("onChange.elapsed old=\(old, privacy: .public) new=\(new, privacy: .public)")
                refreshProgress(trigger: "elapsed")
            }
            .onChange(of: player.duration) { old, new in
                // Self.log.debug("onChange.duration old=\(old, privacy: .public) new=\(new, privacy: .public)")
                refreshProgress(trigger: "duration")
            }
            .onChange(of: player.loadState, initial: true) { old, new in
                // Self.log.info("onChange.loadState old=\(String(describing: old), privacy: .public) new=\(String(describing: new), privacy: .public)")
                refreshProgress(trigger: "loadState")
                subtitleText = computedSubtitle
            }
            .onChange(of: player.currentVideo?.id, initial: true) { old, new in
                // Self.log.info("onChange.video old=\(old ?? "nil", privacy: .public) new=\(new ?? "nil", privacy: .public)")
                subtitleText = computedSubtitle
            }
    }

    private func refreshProgress(trigger: String) {
        let next = Self.progress(for: player)
        let changed = abs(next - progress) > 0.001
        // Self.log.debug("refreshProgress[\(trigger, privacy: .public)] prev=\(self.progress, privacy: .public) next=\(next, privacy: .public) changed=\(changed, privacy: .public)")
        if changed {
            progress = next
        }
    }

    /// Static helper for the few external callers that still want a snapshot.
    static func progress(for player: PlayerStateManager) -> Float {
        if case .downloading(let progress, _) = player.loadState {
            return Float(progress ?? 0)
        }
        guard player.duration > 0 else { return 0 }
        return Float(min(1, max(0, player.elapsed / player.duration)))
    }

    private var computedSubtitle: String { subtitle }

    private var subtitle: String {
        switch player.loadState {
        case .resolving:
            return "Preparing…"
        case .downloading(let progress, let phase):
            guard let progress else { return "Processing…" }
            let percent = Int(progress * 100)
            if let phase, phase == "video" || phase == "audio" {
                return "Downloading \(phase) \(percent)%"
            }
            return "Downloading \(percent)%"
        case .failed(let msg):
            return msg
        case .idle, .readyToPlay:
            return player.currentVideo?.channelName ?? ""
        }
    }

    private var image: Image {
        switch player.loadState {
        case .resolving, .downloading:
            return Image(systemName: "arrow.down.circle.fill")
        default:
            if let thumbnail {
                return Image(uiImage: thumbnail)
            }
            return Image(systemName: "play.rectangle.fill")
        }
    }
}
