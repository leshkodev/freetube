import SwiftUI
import SwiftData
import UIKit
import OSLog
import Kingfisher

/// Expanded player content presented by `LNPopupUI` when the popup bar is opened. The popup chrome
/// (close button) is provided by the library — this view renders the surface, transport controls,
/// metadata, and the toggleable comments / queue panel below.
@available(iOS 17.0, *)
struct FullScreenPlayer: View {
    @Environment(PlayerStateManager.self) private var player
    @Environment(\.modelContext) private var modelContext
    /// Reactive list of all favorited videos so menu rendering doesn't have to fetch Core Data on
    /// every redraw (which was the bug DownloadsScreen had: per-row SQL on the main queue).
    @Query private var favorites: [FavoriteVideo]

    /// What's shown in the lower panel. Default is `.queue` so the user can see what's coming up
    /// without an extra tap; they can switch to `.comments` via the toggle on the right of the
    /// transport row.
    @State private var panel: Panel = .queue
    /// Async-loaded description / details for the currently-playing video. Fetched on demand when
    /// the user taps "More" under the channel row.
    @State private var details: VideoInfo?
    /// Are we currently fetching `details`? Drives the spinner in the description area.
    @State private var isLoadingDetails = false
    /// True when the user has expanded the description block — shows full text instead of a
    /// truncated preview, and tries to load extended details (tags etc.) if not yet loaded.
    @State private var isDetailsExpanded = false
    /// File URL the user wants to hand off to another app via the system "Open in…" share sheet.
    /// Non-nil → present the activity controller; tapped row sets this, sheet dismissal clears it.
    @State private var shareFileURL: URL?
    /// Currently-pushed channel (nil = panel mode). When non-nil, the lower section swaps the
    /// metadata + comments/queue panel for a NavigationStack rooted at `ChannelScreen`. Keeping
    /// the NavigationStack **conditionally mounted** is what makes the panel-mode background
    /// match the transport row: SwiftUI's NavigationStack container paints opaque under its
    /// content, so any thinMaterial inside it stacks on top of an opaque layer and reads darker
    /// than the rest of the popup. With the stack absent in panel mode, the outer VStack's
    /// thinMaterial paints through cleanly.
    @State private var pushedChannel: ChannelPresentation?
    /// Path for deeper pushes inside the channel flow (e.g. ChannelScreen → ChannelTabScreen).
    /// Only meaningful while `pushedChannel != nil`.
    @State private var channelPath = NavigationPath()
    /// Non-nil when the user picked "Add to playlist" — drives the `AddToPlaylistSheet`
    /// presentation. We capture the whole `Video` (not just the id) so the sheet can show its
    /// title at the top of the picker.
    @State private var addToPlaylistVideo: Video?

    /// Hashable wrapper so `.navigationDestination(for:)` can match the channel id and push
    /// `ChannelScreen` onto `channelPath`.
    struct ChannelPresentation: Identifiable, Hashable {
        let id: String
    }

    enum Panel { case comments, queue }

    var body: some View {
        // Single dark-blur material under EVERYTHING — status bar inset, video chrome, transport,
        // comments, queue. Removing per-section backgrounds and using one full-screen material lets
        // the popup read as one continuous translucent surface instead of three stacked tones.
        //
        // **Why the outer `GeometryReader`:** we want the video to always be full-width
        // regardless of how wide vs tall the popup is. `.aspectRatio(16/9, .fit)` clamps the
        // video to whichever dimension is tighter — on iPhone portrait that's always width
        // (the screen is much taller than 16:9), but on Mac (Designed-for-iPad) and iPad
        // landscape the window is wider than 16:9 so `.fit` height-clamps and the video sits
        // letterboxed inside black side bars. Reading the available width via
        // `GeometryReader` and sizing the ZStack to `proxy.size.width × width*9/16`
        // explicitly removes the clamp — full-width on every idiom.
        GeometryReader { proxy in
            VStack(spacing: 0) {
                // Pinning the ZStack to width × width*9/16 keeps the surface a stable height
                // across .resolving → .downloading → .readyToPlay (the underlying
                // AVPlayerViewController has zero intrinsic size while loading; the explicit
                // frame here is what stops the layout from jumping when the user taps a queue
                // item).
                ZStack {
                    Color.black
                    PlayerSurface(player: player.player)
                    DownloadProgressOverlay(state: player.loadState)
                }
                .frame(width: proxy.size.width, height: proxy.size.width * 9 / 16)
            // Pull-down-to-dismiss starting from the video surface.
            //
            // `AVPlayerViewController`'s internal `UIPanGestureRecognizer`s (scrubber, system
            // controls) consume touches before they can reach LNPopupUI's outer pan, so the
            // library's `.popupInteractionStyle(.drag)` only works when the gesture starts on
            // SwiftUI views below the video (comments / queue). `.simultaneousGesture` is the
            // escape hatch: SwiftUI composes this `DragGesture` with the UIKit recognizers
            // underneath instead of arbitrating between them, so AVPlayerViewController's
            // controls keep working AND we can detect a downward pull and dismiss the popup
            // imperatively. LNPopupUI animates the collapse — we just flip the binding.
            .simultaneousGesture(
                DragGesture(minimumDistance: 30, coordinateSpace: .global)
                    .onEnded { value in
                        let mostlyDown = value.translation.height > 90
                            && abs(value.translation.width) < value.translation.height
                        let fastFlick = value.predictedEndTranslation.height > 180
                        if mostlyDown || fastFlick {
                            @Bindable var p = player
                            p.fullScreenPresented = false
                        }
                    }
            )

            transportRow
                .padding(.vertical, 10)

            Divider()

            if let video = player.currentVideo {
                // **Two render modes for the lower section, picked by `pushedChannel`:**
                //
                // 1. **Panel mode (default, channel == nil):** plain ScrollView, NO
                //    NavigationStack. The outer VStack's `.background { thinMaterial }` paints
                //    behind it directly — exactly the same backdrop the transport row above
                //    shows. This is what makes the visual treatment consistent.
                //
                // 2. **Channel-pushed mode (channel != nil):** NavigationStack rooted at
                //    `ChannelScreen`, with its own thinMaterial inside since the stack's UIKit
                //    container paints opaque. Channel's own internal NavigationLinks (to
                //    ChannelTabScreen / PlaylistScreen) push further into this stack.
                //
                // The previous version kept the NavigationStack mounted in both modes — that
                // forced us to paint an inner thinMaterial under the comments/queue panel,
                // which stacked on top of the stack's opaque container and read noticeably
                // darker than the transport row. Mounting the stack only when needed fixes it.
                Group {
                    if let channel = pushedChannel {
                        channelStack(channel)
                    } else {
                        panel(video)
                    }
                }
                // Reset description state, (best-effort) prefetch the snippet, AND pop any
                // pushed channel screen whenever the user picks a new video — otherwise tapping
                // the next video in the queue would leave a stale channel push on screen.
                .onChange(of: video.id, initial: true) { _, _ in
                    details = nil
                    isDetailsExpanded = false
                    pushedChannel = nil
                    channelPath = NavigationPath()
                    prefetchDescriptionIfAvailable(for: video)
                }
            }
        }
        // One continuous material under EVERYTHING, including the top safe-area inset (status bar).
        // VStack content still respects safe area; only the material extends behind the inset.
        .background {
            Rectangle()
                .fill(.thinMaterial)
                .ignoresSafeArea()
        }
        // Ensure the system status bar stays visible and gets light-content (white) glyphs against
        // the dark material. LNPopupUI's `LNPopupContentHostingController` is a UIHostingController
        // subclass that doesn't override status bar style, so SwiftUI's colorScheme drives it.
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
        // Presents UIActivityViewController for the "Open in…" menu action. Wrapping shareFileURL
        // in a `Binding<Bool>` that flips when the URL is set/cleared so the sheet lifecycle
        // matches the user's intent.
        .sheet(isPresented: Binding(
            get: { shareFileURL != nil },
            set: { if !$0 { shareFileURL = nil } }
        )) {
            if let url = shareFileURL {
                ActivityShareSheet(activityItems: [url])
            }
        }
        // "Add to playlist" sheet, presented when the menu sets `addToPlaylistVideo`. The sheet
        // owns its own playlist fetch + "Create new playlist" form — we just hand it the video.
        .sheet(item: $addToPlaylistVideo) { video in
            AddToPlaylistSheet(videoID: video.id, videoTitle: video.title)
        }
        // Pull-down-to-dismiss is handled by LNPopupUI via `.popupInteractionStyle(...)` in
        // RootView. We don't install a custom DragGesture here — it would race with the system
        // gesture arbitration the popup hosts (and with AVPlayerViewController's own touch
        // handling once the video surface goes interactive). That was the bug where the
        // expanded player wouldn't visibly follow the finger during a downward swipe once
        // playback started; the close was only happening on touch-up.

        // Make the VStack fill the GeometryReader's bounds. Without this, the VStack only
        // claims the natural content height (video + transport + divider + panel intrinsic
        // height) and the `.background { thinMaterial }` doesn't extend below that. On
        // smaller-than-content windows (Mac shrunk) this is invisible; on larger ones
        // (Mac maximized) you'd see an unfilled gap below the panel.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Bottom-anchored Close button. The button itself is the glass surface
        // (`.buttonStyle(.glass)` on iOS 26), centered with transparent space around it so
        // the popup's `thinMaterial` background reads through on either side. `.safeAreaInset`
        // pushes the panel's ScrollView content up so nothing gets stuck behind the button,
        // and the inset respects the bottom home-indicator / window safe area automatically.
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                closeFullScreenButton
                Spacer()
            }
            .padding(.bottom, 8)
        }
        }
    }

    // MARK: - Close button

    /// Bottom-bar Close pill. iOS 26 ships `.buttonStyle(.glass)` which renders a real
    /// glass-material capsule — that's what gives it the visual weight that matches the
    /// `prominentClearGlass` close button LNPopupUI shows in the popup chrome. Pre-iOS-26
    /// fallback uses `.bordered` with `.regularMaterial` Capsule background — visually
    /// close but not the same liquid-glass effect.
    @ViewBuilder
    private var closeFullScreenButton: some View {
        let label = Label("Close", systemImage: "chevron.down")
            .labelStyle(.titleAndIcon)
            .font(.body.weight(.semibold))
            .padding(.horizontal, 24)
            .padding(.vertical, 10)

        if #available(iOS 26.0, *) {
            Button {
                @Bindable var p = player
                p.fullScreenPresented = false
            } label: {
                label
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .tint(.primary)
            .accessibilityLabel("Close full screen player")
        } else {
            Button {
                @Bindable var p = player
                p.fullScreenPresented = false
            } label: {
                label
                    .background(.regularMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close full screen player")
        }
    }

    // MARK: - Lower section: panel vs channel-push

    /// Default panel mode. No NavigationStack wrapping — the outer popup's `.thinMaterial`
    /// shows through directly, giving the same backdrop as the transport row above.
    @ViewBuilder
    private func panel(_ video: Video) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                metadata(video)
                detailsSection(video: video)
                switch self.panel {
                case .comments:
                    CommentsSection(videoID: video.id)
                case .queue:
                    queuePanel
                }
            }
            .padding(.vertical)
        }
        .scrollContentBackground(.hidden)
    }

    /// NavigationStack rooted at `ChannelScreen`. Mounted only when `pushedChannel != nil`.
    /// Internal `NavigationLink`s inside `ChannelScreen` push onto `channelPath`; popping the
    /// last item via our back button returns to panel mode.
    @ViewBuilder
    private func channelStack(_ root: ChannelPresentation) -> some View {
        NavigationStack(path: $channelPath) {
            channelDestination(root, isRoot: true)
                .navigationDestination(for: ChannelPresentation.self) { channel in
                    channelDestination(channel, isRoot: false)
                }
        }
    }

    /// Single channel destination — used for both the root channel (pushed from the player) and
    /// any further pushes via NavigationLink. The back button pops `channelPath` when there's
    /// something on it, otherwise clears `pushedChannel` to return to panel mode.
    @ViewBuilder
    private func channelDestination(_ channel: ChannelPresentation, isRoot: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            ChannelScreen(channelID: channel.id)
                .toolbar(.hidden, for: .navigationBar)
                // Solid black, matching the playlist push inside this same NavigationStack.
                // We deliberately don't use `.thinMaterial` here — pushed destinations inside
                // the popup body use opaque black for visual consistency with PlaylistScreen,
                // while the panel-mode comments/queue area keeps the popup's outer thinMaterial.
                .background {
                    Color.black.ignoresSafeArea()
                }
                // Reserve room for the player's outer bottom Close button so the last
                // ChannelScreen row isn't hidden behind the glass capsule. The outer
                // `.safeAreaInset(edge: .bottom)` (line ~193) reserves it on the outermost
                // container, but the NavigationStack inside `channelStack` creates a fresh
                // UIHostingController whose internal `List` ignores that ancestor inset
                // — same propagation gap the playback-queue panel hit. Mirroring the inset
                // here lifts the List's content above the Close button.
                .safeAreaInset(edge: .bottom) {
                    Color.clear.frame(height: Self.closeButtonReserveHeight)
                }

            Button {
                if !channelPath.isEmpty {
                    channelPath.removeLast()
                } else {
                    pushedChannel = nil
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .padding(.leading, 12)
            .padding(.top, 8)
        }
    }

    // MARK: - Metadata

    @ViewBuilder
    private func metadata(_ video: Video) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(video.title)
                .font(.title3.weight(.semibold))
            // Tapping anywhere on the channel row pushes the channel detail screen onto the
            // popup's internal NavigationStack — banner, subscribe button, latest videos,
            // shorts, playlists. Pushing (rather than presenting) keeps the video surface and
            // transport controls visible at the top; only the panel area below is replaced.
            if !video.channelID.isEmpty {
                Button {
                    pushedChannel = ChannelPresentation(id: video.channelID)
                } label: {
                    channelRow(video)
                }
                .buttonStyle(.plain)
            } else {
                channelRow(video)
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private func channelRow(_ video: Video) -> some View {
        HStack(spacing: 12) {
            KFImage(video.channelThumbnailURL)
                .thumbnail(size: CGSize(width: 32, height: 32)) {
                    Circle().fill(.gray.opacity(0.2))
                }
                .resizable()
                .scaledToFill()
                .frame(width: 32, height: 32)
                .clipShape(Circle())

            Text(video.channelName).font(.subheadline)
            Spacer()
        }
    }

    // MARK: - Description / details (between channel row and comments)

    /// Shows the video description in a YouTube-like collapsed-by-default block. Snippet first
    /// (if the model has one), with a "More" button under the channel row that expands the block
    /// and fetches the full details payload (description text + view count + tags etc.).
    @ViewBuilder
    private func detailsSection(video: Video) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if isDetailsExpanded {
                expandedDetailsBody(video: video)
            } else {
                collapsedDetailsBody(video: video)
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private func collapsedDetailsBody(video: Video) -> some View {
        if let snippet = inlineDescriptionSnippet(video: video) {
            Text(snippet)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        Button {
            isDetailsExpanded = true
            loadDetailsIfNeeded(for: video)
        } label: {
            HStack(spacing: 6) {
                Text("More")
                Image(systemName: "chevron.down")
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func expandedDetailsBody(video: Video) -> some View {
        // Full description text (from the loaded details, falling back to the search-result snippet).
        if let text = details?.descriptionText ?? video.descriptionSnippet, !text.isEmpty {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
        } else if isLoadingDetails {
            HStack {
                ProgressView().controlSize(.small)
                Text("Loading details…").font(.caption).foregroundStyle(.secondary)
            }
        }

        // Quick stats line: views • published date • duration.
        let statsRow = detailsStatsRow(video: video)
        if !statsRow.isEmpty {
            Text(statsRow)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        // Like count if we got it from the details payload.
        if let likes = details?.likeCount, likes > 0 {
            Text("\(formatCount(likes)) likes")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Button {
            isDetailsExpanded = false
        } label: {
            HStack(spacing: 6) {
                Text("Show less")
                Image(systemName: "chevron.up")
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Picks the description text to render in the 2-line collapsed preview. Prefer the loaded
    /// details (more complete), fall back to the search-result snippet.
    private func inlineDescriptionSnippet(video: Video) -> String? {
        let raw = details?.descriptionText ?? video.descriptionSnippet
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }

    /// `42K views • 3 days ago • 4:32`, omitting any pieces we don't have.
    private func detailsStatsRow(video: Video) -> String {
        var parts: [String] = []
        if let views = video.viewCount, views > 0 {
            parts.append("\(formatCount(views)) views")
        }
        if let published = video.publishedAt {
            let relative = RelativeDateTimeFormatter()
            relative.unitsStyle = .short
            parts.append(relative.localizedString(for: published, relativeTo: .now))
        }
        if !video.durationString.isEmpty {
            parts.append(video.durationString)
        }
        return parts.joined(separator: " • ")
    }

    private func formatCount(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format: "%.1fB", Double(n) / 1_000_000_000) }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }

    /// Best-effort: if `descriptionSnippet` is already on the `Video` (from search/home), we have
    /// something to show without hitting the network. Don't preemptively fetch the full details —
    /// the user might never tap "More".
    private func prefetchDescriptionIfAvailable(for video: Video) {
        // Intentional no-op. The fetch happens on the user's first "More" tap.
        _ = video
    }

    /// Lazy fetch invoked when the user expands the description. One `VideoService.fetchInfo`
    /// call per video; subsequent expansions reuse the cached result in `details`.
    private func loadDetailsIfNeeded(for video: Video) {
        guard details == nil, !isLoadingDetails else { return }
        isLoadingDetails = true
        Task { [videoID = video.id] in
            defer { Task { @MainActor in isLoadingDetails = false } }
            do {
                let info = try await VideoService().fetchInfo(id: videoID)
                await MainActor.run {
                    // Drop the result if the user switched videos before this returned.
                    guard player.currentVideo?.id == videoID else { return }
                    details = info
                }
            } catch {
                // Network failure is non-fatal — collapsed view still shows the snippet if any.
            }
        }
    }

    // MARK: - Transport

    @ViewBuilder
    private var transportRow: some View {
        // Flexible `Spacer()`s on both outer ends AND between every adjacent pair so every gap
        // — edge-to-button and button-to-button — sizes itself to the same width. Keeps the
        // optical rhythm even across device widths instead of the previous mixed model (fixed
        // 24pt between the 5 center buttons + flexible to the side buttons).
        HStack(spacing: 0) {
            Spacer(minLength: 0)

            moreActionsMenu

            Spacer(minLength: 0)

            Button { player.playPrevious() } label: {
                Image(systemName: "backward.fill").font(.title3)
            }
            .disabled(!hasPrevious)

            Spacer(minLength: 0)

            Button { player.seekRelative(by: -15) } label: {
                Image(systemName: "gobackward.15").font(.title3)
            }

            Spacer(minLength: 0)

            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 48))
            }

            Spacer(minLength: 0)

            Button { player.seekRelative(by: 15) } label: {
                Image(systemName: "goforward.15").font(.title3)
            }

            Spacer(minLength: 0)

            Button { player.playNext() } label: {
                Image(systemName: "forward.fill").font(.title3)
            }
            .disabled(!hasNext)

            Spacer(minLength: 0)

            queueToggleButton

            Spacer(minLength: 0)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
    }

    private var hasPrevious: Bool {
        guard let current = player.queue.current else { return false }
        return player.queue.items.firstIndex(of: current).map { $0 > 0 } ?? false
    }

    private var hasNext: Bool {
        guard let current = player.queue.current else { return false }
        return player.queue.items.firstIndex(of: current).map { $0 + 1 < player.queue.items.count } ?? false
    }

    // MARK: - More-actions menu (three dots)

    @ViewBuilder
    private var moreActionsMenu: some View {
        Menu {
            if let video = player.currentVideo {
                Button {
                    if let url = watchURL(video) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Open in browser", systemImage: "safari")
                }
                // System "Open in…" share sheet for the downloaded mp4 — only shown when the file
                // is already on disk. We avoid `ShareLink` here because for `file://` URLs inside
                // a `Menu` it sometimes serializes the URL as text and the share sheet doesn't
                // show the apps that handle the mp4 UTType. Going through `UIActivityViewController`
                // directly is the reliable path for file activity items.
                if let localFile = DownloadManager.shared.localFile(for: video.id) {
                    Button {
                        shareFileURL = localFile
                    } label: {
                        Label("Open in…", systemImage: "square.and.arrow.up")
                    }
                }
                Button {
                    if let url = watchURL(video) {
                        UIPasteboard.general.string = url.absoluteString
                    }
                } label: {
                    Label("Copy URL", systemImage: "link")
                }
                Button {
                    UIPasteboard.general.string = watchURLAtCurrentTime(video).absoluteString
                } label: {
                    Label("Copy URL at current time", systemImage: "clock")
                }
                // Favorites + add-to-playlist are auth-gated. When signed out, both actions
                // are hidden — the YouTube endpoints they call would just throw
                // `.notAuthenticated` and the user would see a useless error toast.
                if isSignedIn {
                    Divider()
                    Button {
                        toggleFavorite(video)
                    } label: {
                        if isFavorite(video) {
                            Label("Remove from favorites", systemImage: "hand.thumbsup.fill")
                        } else {
                            Label("Add to favorites", systemImage: "hand.thumbsup")
                        }
                    }
                    Button {
                        addToPlaylistVideo = video
                    } label: {
                        Label("Add to playlist", systemImage: "text.badge.plus")
                    }
                }
                if DownloadManager.shared.localFile(for: video.id) != nil {
                    Divider()
                    Button(role: .destructive) {
                        DownloadManager.shared.deleteDownloaded(videoID: video.id, context: modelContext)
                    } label: {
                        Label("Remove downloaded file", systemImage: "trash")
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title2)
        }
    }

    /// True when `AuthState` reports a logged-in session. Drives auth-gated visibility of the
    /// "Add to favorites" and "Add to playlist" menu items.
    private var isSignedIn: Bool {
        if case .loggedIn = AuthState.shared.status { return true }
        return false
    }

    private func watchURL(_ video: Video) -> URL? {
        URL(string: "https://www.youtube.com/watch?v=\(video.id)")
    }

    /// `youtu.be/<id>?t=<seconds>` is the canonical share-with-timestamp URL YouTube understands.
    private func watchURLAtCurrentTime(_ video: Video) -> URL {
        let seconds = Int(player.elapsed)
        return URL(string: "https://youtu.be/\(video.id)?t=\(seconds)")
            ?? URL(string: "https://youtu.be/\(video.id)")!
    }

    /// O(N) check against the already-loaded `favorites` array — no Core Data per call. With
    /// reasonable favorite counts this is effectively free, and avoids the per-menu-render SQL hit
    /// that was lagging the UI elsewhere.
    private func isFavorite(_ video: Video) -> Bool {
        favorites.contains(where: { $0.videoID == video.id })
    }

    /// Toggles the video in the local SwiftData favorites table AND, when signed in, syncs the
    /// change to YouTube via `LikeVideoResponse` / `RemoveLikeFromVideoResponse`. The local
    /// store doubles as the "Liked Videos" cache for offline browsing — even after sign-out the
    /// user can still see what they liked while signed in.
    private func toggleFavorite(_ video: Video) {
        let wasFavorite = favorites.contains(where: { $0.videoID == video.id })
        if wasFavorite {
            for existing in favorites where existing.videoID == video.id {
                modelContext.delete(existing)
            }
        } else {
            modelContext.insert(FavoriteVideo(
                videoID: video.id,
                title: video.title,
                channelName: video.channelName,
                thumbnailURL: video.thumbnailURL
            ))
        }
        try? modelContext.save()

        // Mirror to YouTube when signed in. Fire-and-forget — the local store is the source of
        // truth for UI state, and a network failure on the YouTube side shouldn't undo the
        // user's intent. We do log the failure for diagnostics.
        if isSignedIn {
            let log = AppLog(subsystem: "com.leshko.freetube", category: "FullScreenPlayer")
            Task {
                do {
                    let actions: any VideoActionsServicing = VideoActionsService()
                    if wasFavorite {
                        try await actions.removeRating(videoID: video.id)
                    } else {
                        try await actions.like(videoID: video.id)
                    }
                } catch {
                    log.error("[favorites] YouTube sync failed for \(video.id, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    // MARK: - Queue toggle (right of transport)

    @ViewBuilder
    private var queueToggleButton: some View {
        // Apple Music style: when active, draw a soft capsule highlight behind the icon. We
        // intentionally do NOT recolor the glyph itself — the user's eye is drawn by the
        // capsule shape, the icon stays the same color so it doesn't look like a different button.
        Button {
            withAnimation(.snappy) {
                panel = (panel == .queue) ? .comments : .queue
            }
        } label: {
            Image(systemName: "list.bullet")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 44, height: 28)
                .background {
                    if panel == .queue {
                        Capsule().fill(.ultraThinMaterial)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Queue controls (shuffle + repeat)

    /// Shuffle pill — active = capsule highlight behind the glyph, same icon color. Tap toggles
    /// `QueueManager.isShuffleOn` which rebuilds the play order on the queue manager itself.
    @ViewBuilder
    private var shuffleButton: some View {
        Button {
            player.queue.isShuffleOn.toggle()
        } label: {
            Image(systemName: "shuffle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 36, height: 28)
                .background {
                    if player.queue.isShuffleOn {
                        Capsule().fill(.ultraThinMaterial)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    /// Repeat pill — cycles through .off → .all → .one → .off. Active states (.all and .one) get
    /// the capsule highlight; `.one` swaps to the `repeat.1` SF Symbol so the user can see the
    /// single-track variant at a glance.
    @ViewBuilder
    private var repeatButton: some View {
        Button {
            switch player.queue.repeatMode {
            case .off: player.queue.repeatMode = .all
            case .all: player.queue.repeatMode = .one
            case .one: player.queue.repeatMode = .off
            }
        } label: {
            Image(systemName: player.queue.repeatMode == .one ? "repeat.1" : "repeat")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 36, height: 28)
                .background {
                    if player.queue.repeatMode != .off {
                        Capsule().fill(.ultraThinMaterial)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Queue panel sizing

    /// Fixed height of one queue row's content area. 56pt accommodates the 80×45 thumbnail with
    /// a hair of breathing room. Combined with our `.listRowInsets(top: 4, bottom: 4)` each row
    /// occupies 64pt of vertical space in the List.
    private static let queueRowHeight: CGFloat = 56

    /// Approximate bottom footprint of the player's Close button (label vertical padding +
    /// glass-button chrome + the wrapping HStack's `.padding(.bottom, 8)`). Used to inset
    /// any pushed channel/playlist content via `.safeAreaInset(edge: .bottom)` so the last
    /// row isn't hidden behind the close pill. SwiftUI adds the home-indicator safe area
    /// on top of this automatically — we only need to reserve the button height itself.
    private static let closeButtonReserveHeight: CGFloat = 56
    /// Per-row footprint including insets, used by `queueListHeight` below.
    private static let queueRowFootprint: CGFloat = queueRowHeight + 8 // 4pt top + 4pt bottom insets

    /// Total height we hand to the queue `List`. Sized for the actual number of items + a 32pt
    /// bottom margin so the last row's edit-handle / swipe affordance isn't truncated.
    private var queueListHeight: CGFloat {
        let count = max(1, player.queue.items.count)
        return CGFloat(count) * Self.queueRowFootprint + 32
    }

    // MARK: - Queue panel

    @ViewBuilder
    private var queuePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(title: "Up next")
                Spacer()
                shuffleButton
                repeatButton
            }
            .padding(.horizontal)
            // `List` is the cleanest source of drag-to-reorder + swipe-to-delete in SwiftUI. We're
            // already inside a ScrollView, so we cap the list with a generous fixed height so it
            // doesn't try to consume the outer scroll's gesture space.
            List {
                ForEach(player.queue.items) { video in
                    queueRow(video)
                        .listRowBackground(Color.clear)
                        // Pin a deterministic row height so the outer `.frame(height:)` below can
                        // calculate the exact List size — otherwise iOS's auto-sized rows end up
                        // slightly taller than our estimate and the last row gets clipped.
                        .frame(height: Self.queueRowHeight)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
                .onMove { source, destination in
                    let from = source.first ?? 0
                    player.queue.move(from: from, to: destination)
                }
                .onDelete { offsets in
                    for index in offsets.sorted(by: >) {
                        player.queue.remove(at: index)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(.active))
            .scrollDisabled(true)
            // Row height (`queueRowHeight`) + insets (`4+4`) + a tail margin so the last row's
            // bottom edge isn't flush with the next sibling view in the outer scroll.
            .frame(height: queueListHeight)
        }
    }

    @ViewBuilder
    private func queueRow(_ video: Video) -> some View {
        HStack(spacing: 0) {
            Button {
                player.load(video)
            } label: {
                HStack(spacing: 12) {
                    // Thumbnail with duration badge in the bottom-right corner — same affordance
                    // YouTube uses on its own video tiles. Costs no extra row height.
                    ZStack(alignment: .bottomTrailing) {
                        KFImage(video.thumbnailURL)
                            .thumbnail(size: CGSize(width: 80, height: 45)) {
                                Color.gray.opacity(0.2)
                            }
                            .resizable()
                            .scaledToFill()
                            .frame(width: 80, height: 45)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 4))

                        if !video.durationString.isEmpty {
                            Text(video.durationString)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 3))
                                .padding(3)
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(video.title)
                            .font(.subheadline)
                            .lineLimit(2)
                        // Channel name + playback count joined by a middle dot. Either piece can be
                        // empty (older listings sometimes omit view count), filter before joining so
                        // there are no stray separators.
                        Text(queueRowMetadata(for: video))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if video.id == player.currentVideo?.id {
                        // Animated audio bars instead of the static speaker glyph. Animates only
                        // for the matched row; other rows render nothing because the parent `if`
                        // gates mounting.
                        NowPlayingIndicator(videoID: video.id)
                    }
                }
            }
            .buttonStyle(.plain)

            // Sibling of the load-button so taps land in the Menu instead of the row's
            // play handler. Same actions as the row would get in search/history/library.
            VideoMoreActionsMenu(video: video)
        }
    }

    /// "Channel • 1.2M views" for the queue row's second line. Drops the dot if either side is
    /// missing so we never render a dangling separator.
    private func queueRowMetadata(for video: Video) -> String {
        [video.channelName, video.viewCountString]
            .filter { !$0.isEmpty }
            .joined(separator: " • ")
    }
}
