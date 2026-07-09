import Foundation
import AVFoundation
import Combine
import Kingfisher
import OSLog
import SwiftData
import UIKit

/// CLAUDE.md §8: single source of truth for playback. Injected via SwiftUI environment.
/// Mini player and full-screen player both observe this object — neither owns its own `AVPlayer`.
///
/// Combine is used **only** here for `AVPlayer` time-observer bridging, per CLAUDE.md §2.9.
@available(iOS 17.0, *)
@MainActor
@Observable
final class PlayerStateManager {
    enum LoadState: Equatable {
        case idle
        case resolving
        /// File is being fetched. `progress` is 0…1 when known, nil during yt-dlp's mux/merge phase.
        /// `phase` labels which stream is in flight ("video", "audio", "stream") so the UI can show
        /// "Downloading video 42%" instead of two confusing identical bars in a row.
        case downloading(progress: Double?, phase: String?)
        case readyToPlay
        case failed(String)
    }

    // MARK: - Published state

    private(set) var currentVideo: Video?
    /// Cached artwork for the current video. Used both to populate `MPNowPlayingInfoCenter`
    /// (lock-screen + Control Center) and (in the future) any in-app UI that wants a UIImage rather
    /// than the SwiftUI `Image`. Refreshed when the current video changes.
    private(set) var currentArtwork: UIImage?
    private(set) var loadState: LoadState = .idle
    private(set) var isPlaying: Bool = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    var miniPlayerVisible: Bool = false
    var fullScreenPresented: Bool = false

    // MARK: - AVPlayer

    /// `AVQueuePlayer` to unlock `advanceToNextItem()` and queue introspection for future preload.
    /// IMPORTANT: don't use `replaceCurrentItem(with:)` to load tracks — it's a no-op on
    /// `AVQueuePlayer` when the internal queue is empty (which is our usual state). Use the
    /// `removeAllItems()` + `insert(_:after:)` pattern via `swap(to:)` below.
    let player = AVQueuePlayer()

    // MARK: - Collaborators

    let queue: QueueManager
    private let resolver: any PlaybackResolving
    private let preferences: UserPreferences
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "PlayerStateManager")

    /// Sticky "this queue is endless" intent. Set to `true` whenever the user loads a video
    /// without explicitly skipping recommendations (Home / Search / Mini-player / row taps),
    /// and `false` for curated batch actions like playlist's Play all / Shuffle all. Drives:
    ///   1. The per-load `fillQueueWithRecommendations` call in `resolveAndPlay`.
    ///   2. The auto-advance dead-end recovery in `playNext()` — when the queue runs out and
    ///      repeat is off, we fire a fresh recs fetch using the queue's last item as a seed,
    ///      then advance once new items land. That gives the requested "endless queue" feel:
    ///      whenever you reach the latest item, recommendations refill behind it.
    private var queueAcceptsRecommendations = true

    private var timeObserver: Any?
    private var timeControlStatusObservation: NSKeyValueObservation?
    private var statusCancellable: AnyCancellable?
    private var endObserver: NSObjectProtocol?
    private var itemStatusObservation: NSKeyValueObservation?
    private var itemErrorLogObservation: NSObjectProtocol?
    private var playerErrorObservation: NSKeyValueObservation?
    private var defaultRateObservation: NSKeyValueObservation?
    init(
        queue: QueueManager = QueueManager(),
        resolver: any PlaybackResolving = PlaybackResolver(),
        preferences: UserPreferences = UserPreferences()
    ) {
        self.queue = queue
        self.resolver = resolver
        self.preferences = preferences
        // Keep the audio track running when the player view goes off-screen (popup minimize, app
        // backgrounded). Without this, AVPlayer pauses video tracks as soon as their pixel buffer
        // pipeline is no longer visible, which manifests as "audio cuts out the moment you collapse
        // the mini-player." Pairs with the `.playback` AVAudioSession configured at launch.
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        // Restore the last-used playback speed. `defaultRate` is what `AVPlayerViewController`'s
        // speed menu writes, and `AVPlayer.play()` resumes at this rate (not the transient `rate`).
        // Setting it *before* installObservers keeps the KVO from firing back and re-saving the
        // same value during launch.
        player.defaultRate = Float(preferences.playbackRate)
        installObservers()
    }

    /// Tear-down hook for tests / app lifecycle. Call before releasing the manager. We avoid `deinit`
    /// here so we don't have to reach into main-actor-isolated state from a nonisolated context.
    func tearDownObservers() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
    }

    // MARK: - Public commands

    /// Loads a video for playback.
    ///
    /// - Parameter skipRecommendations: when `true`, suppresses the post-play "fill queue with
    ///   YouTube recommendations" call. Pass this from explicit batch actions that already
    ///   populated a curated queue — playlist's Play all / Shuffle all — so the user's queue
    ///   stays exactly what they chose. Default is `false` so single-video taps from Home /
    ///   Search / Mini-player still get the YouTube-app-style autoplay chain.
    /// Play a local file already on disk — used by the **Link** tab's completed downloads.
    ///
    /// **Why a separate entry point and not `load(video:)`:** the YouTube-shaped resolver in
    /// `resolveAndPlay` calls `DownloadManager.ensureDownloaded` which keys off `videoID` and
    /// looks for `Documents/<id>.mp4`. URL-fetched files live under `Documents/<title>.mp4`
    /// and don't have a YouTube `videoID`, so threading them
    /// through the normal path would either crash or silently re-trigger a yt-dlp download.
    /// This method skips resolution entirely — the file is already there, just play it.
    ///
    /// **What we skip vs the normal load path:** watch-history upsert (URL files aren't in
    /// the YouTube `WatchHistoryEntry` schema), queue recommendation fill (no related-video
    /// surface for arbitrary URLs), and `ensureDownloaded` (file is on disk).
    /// **What we keep:** `currentVideo` (synthetic so the mini-player title/subtitle still
    /// render), `miniPlayerVisible` flipped true so LNPopupUI shows the bar, NowPlayingCenter
    /// update for lock-screen artwork, and the standard observe/loadItem flow so errors and
    /// playback state still surface through the existing UI.
    func loadLocalFile(at fileURL: URL, title: String, source: String?, thumbnailURL: URL?) {
        log.info("loadLocalFile path=\(fileURL.path, privacy: .public) title=\"\(title, privacy: .public)\"")
        if isPlaying { pause() }
        if !player.items().isEmpty { player.removeAllItems() }

        // Synthetic Video so the existing mini-player + FullScreenPlayer chrome (which read
        // `currentVideo` everywhere) work without conditional branches. Channel name reuses
        // the extractor ("YouTube", "Vimeo", …) — closest analogue for arbitrary URLs.
        let synthetic = Video(
            id: "fetch-" + UUID().uuidString,
            title: title,
            channelID: "",
            channelName: source ?? "Link",
            channelThumbnailURL: nil,
            thumbnailURL: thumbnailURL,
            duration: nil,
            viewCount: nil,
            publishedAt: nil,
            descriptionSnippet: nil,
            isLive: false,
            isShort: false
        )
        currentVideo = synthetic
        // Bypass the queue's YouTube-related tracking — URL files don't participate in the
        // recommendation chain. setCurrent appends to the queue dataset for upcoming-up UI;
        // we just zero it for arbitrary files.
        queueAcceptsRecommendations = false
        miniPlayerVisible = true
        elapsed = 0
        duration = 0
        refreshArtwork(for: synthetic)

        let item = AVPlayerItem(url: fileURL)
        loadItem(item)
        loadState = .readyToPlay
        updateNowPlaying()
        play()
    }

    func load(_ video: Video, autoplay: Bool = true, skipRecommendations: Bool = false) {
        log.info("load(\(video.id, privacy: .public)) autoplay=\(autoplay, privacy: .public) skipRecs=\(skipRecommendations, privacy: .public)")
        queueAcceptsRecommendations = !skipRecommendations
        // Pause and tear down anything currently playing. Otherwise we'd keep streaming audio from
        // the previous video while the new one's file is downloading — which is what the user kept
        // hearing when they tapped "next" mid-download.
        if isPlaying {
            log.info("load: pausing current playback before resolving new video")
            pause()
        }
        if !player.items().isEmpty {
            log.debug("load: clearing AVQueuePlayer items (\(self.player.items().count, privacy: .public) entries)")
            player.removeAllItems()
        }
        currentVideo = video
        // Keep the queue coherent. Fresh taps from search/home append the video; subsequent calls
        // from `playNext()` / `playPrevious()` find it already there and just update `currentIndex`.
        queue.setCurrent(video)
        miniPlayerVisible = true
        loadState = .resolving
        // Wipe transport state from the previous video so a stray time-observer tick during the
        // transition (the periodic callback can fire AFTER currentVideo flips but BEFORE the new
        // AVPlayerItem is installed) doesn't carry the old item's elapsed/duration into a save —
        // that's what showed phantom progress bars on cells the user never played.
        elapsed = 0
        duration = 0
        recordWatchHistory(video: video)
        refreshArtwork(for: video)
        Task { await resolveAndPlay(video: video, autoplay: autoplay, skipRecommendations: skipRecommendations) }
    }

    private var progressObservationTask: Task<Void, Never>?

    /// Polls `DownloadManager.shared.progressByVideoID` and updates `loadState` so the UI sees a
    /// live progress bar while the file is downloading. The dictionary updates synchronously via
    /// `@Observable`, but we still need an explicit poll loop because `loadState` lives on the
    /// player and SwiftUI views don't observe `DownloadManager` from this file's call site.
    private func startProgressObservation(for videoID: String) {
        progressObservationTask?.cancel()
        progressObservationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let progress = DownloadManager.shared.progressByVideoID[videoID]
                let phase = DownloadManager.shared.phaseByVideoID[videoID]
                if case .downloading = self.loadState {
                    self.loadState = .downloading(progress: progress, phase: phase)
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func stopProgressObservation() {
        progressObservationTask?.cancel()
        progressObservationTask = nil
    }

    /// Upserts a `WatchHistoryEntry` so the Library's "Recents" section reflects what the user
    /// played. Same-id taps just bump `watchedAt` so the row floats to the top. The actor hop keeps
    /// the SQL write off the main thread; @Query observers see the change automatically once the
    /// background context saves.
    private func recordWatchHistory(video: Video) {
        let videoID = video.id
        let title = video.title
        let channelName = video.channelName
        let thumbnailURL = video.thumbnailURL
        Task {
            await PersistenceWriter.shared.upsertWatchHistory(
                videoID: videoID,
                title: title,
                channelName: channelName,
                thumbnailURL: thumbnailURL
            )
        }
    }

    func play() {
        log.info("play()")
        player.play()
        isPlaying = true
    }

    func pause() {
        log.info("pause()")
        player.pause()
        isPlaying = false
    }

    func togglePlayPause() {
        log.info("togglePlayPause() (isPlaying=\(self.isPlaying, privacy: .public))")
        isPlaying ? pause() : play()
    }

    func seek(to seconds: TimeInterval) {
        log.info("seek(to: \(seconds, privacy: .public)s)")
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seekRelative(by delta: TimeInterval) {
        log.info("seekRelative(by: \(delta, privacy: .public)s)")
        seek(to: max(0, min(elapsed + delta, duration)))
    }

    func playNext() {
        log.info("playNext() — queue size=\(self.queue.items.count, privacy: .public) currentIndex=\(self.queue.currentIndex, privacy: .public)")
        if let next = queue.advance() {
            load(next)
            return
        }
        // Queue at end. If this queue accepts recommendations and the user hasn't asked for
        // repeat-all/repeat-one, refill from the last item's recommendations and try advancing
        // again — that's the "endless queue" behavior: every time we hit the bottom, more recs
        // refill behind us.
        guard queueAcceptsRecommendations,
              queue.repeatMode == .off,
              let seed = queue.items.last else {
            log.notice("playNext: queue at end, no recs refill (acceptsRecs=\(self.queueAcceptsRecommendations, privacy: .public), repeat=\(String(describing: self.queue.repeatMode), privacy: .public))")
            return
        }
        log.info("playNext: queue at end, refilling recs from seed=\(seed.id, privacy: .public)")
        Task { [weak self] in
            guard let self else { return }
            let countBefore = self.queue.items.count
            await self.fillQueueWithRecommendations(for: seed)
            guard self.queue.items.count > countBefore else {
                self.log.notice("playNext: refill produced no new items, giving up")
                return
            }
            if let next = self.queue.advance() {
                self.load(next)
            }
        }
    }

    func playPrevious() {
        log.info("playPrevious() — queue size=\(self.queue.items.count, privacy: .public) currentIndex=\(self.queue.currentIndex, privacy: .public)")
        guard let previous = queue.previous() else {
            log.notice("playPrevious: at start of queue, nothing to go back to")
            return
        }
        load(previous)
    }

    func dismiss() {
        log.info("dismiss()")
        pause()
        miniPlayerVisible = false
        fullScreenPresented = false
        currentVideo = nil
        loadState = .idle
        player.removeAllItems()
        NowPlayingCenter.clear()
    }

    // MARK: - Internals

    /// Swap the player to a new item using the `AVQueuePlayer`-correct pattern. `replaceCurrentItem`
    /// is documented to be a no-op when the player's internal queue is empty (which is our usual
    /// state since the playable URL is short-lived and we never preload), so we always tear the
    /// queue down to nothing first and then insert. Also wires KVO so we hear about decode/auth
    /// failures the moment they happen (CoreMedia's `CFByteFlume err=-12939` style messages don't
    /// surface a structured `NSError` otherwise).
    private func loadItem(_ item: AVPlayerItem) {
        let url = (item.asset as? AVURLAsset)?.url.path ?? "(non-URL asset)"
        log.info("loadItem: removeAllItems + insert (asset=\(url, privacy: .public))")
        player.removeAllItems()
        player.insert(item, after: nil)
        log.debug("loadItem: queue size after insert=\(self.player.items().count, privacy: .public)")
        observe(item: item)
    }

    private func observe(item: AVPlayerItem) {
        itemStatusObservation?.invalidate()
        if let token = itemErrorLogObservation { NotificationCenter.default.removeObserver(token) }

        itemStatusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            guard let self else { return }
            Task { @MainActor in
                switch item.status {
                case .unknown:
                    self.log.info("AVPlayerItem status: unknown")
                case .readyToPlay:
                    self.log.info("AVPlayerItem status: readyToPlay (duration=\(item.duration.seconds, privacy: .public)s)")
                case .failed:
                    let err = item.error as NSError?
                    self.log.error("AVPlayerItem status: FAILED domain=\(err?.domain ?? "?", privacy: .public) code=\(err?.code ?? 0, privacy: .public) info=\(String(describing: err?.userInfo), privacy: .public)")
                @unknown default:
                    break
                }
            }
        }

        itemErrorLogObservation = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.newErrorLogEntryNotification,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            guard let entry = item?.errorLog()?.events.last else { return }
            self?.log.error("AVPlayerItem error-log: domain=\(entry.errorDomain, privacy: .public) code=\(entry.errorStatusCode, privacy: .public) comment=\(entry.errorComment ?? "", privacy: .public) URI=\(entry.uri ?? "", privacy: .public)")
        }
    }

    private func resolveAndPlay(video: Video, autoplay: Bool, skipRecommendations: Bool = false) async {
        log.info("resolveAndPlay: start for \(video.id, privacy: .public)")
        // Watch the manager's progress dictionary so the player UI can render a real-time progress
        // bar. Cancelled in `dismiss()` and replaced on each `load`.
        startProgressObservation(for: video.id)

        // Three-tier playback resolution:
        //   1. `ensureDownloaded` — yt-dlp into local file, then YouTubeKit progressive fallback
        //      inside it. Returns a `file://` URL on success.
        //   2. **HLS streaming** — last resort when every download path is blocked (PoT 403s,
        //      cipher-decode broken, etc.). `AVPlayerItem(url:)` accepts an HLS master-playlist
        //      URL identically to a file URL — AVFoundation handles segment fetching itself, so
        //      we get playback without needing to predownload or decode signature ciphers. The
        //      trade-off is no local file ⇒ the video isn't watchable offline, doesn't appear in
        //      Downloads, and doesn't burn cache storage. But it plays.
        let playbackURL: URL
        do {
            loadState = .downloading(progress: 0, phase: nil)
            // `.userInitiated` priority — the user just tapped Play and is actively waiting.
            // If a long background queue (playlist Download All) is in flight, this jumps the
            // line so playback starts as soon as the currently-running yt-dlp finishes, instead
            // of after every queued download.
            playbackURL = try await DownloadManager.shared.ensureDownloaded(
                video: video,
                quality: preferences.preferredQuality,
                priority: .userInitiated
            )
            log.info("resolveAndPlay: local file \(playbackURL.path, privacy: .public)")
        } catch {
            log.error("resolveAndPlay: download path FAILED for \(video.id, privacy: .public): \(String(describing: error), privacy: .public) — trying remote stream")
            if let streamURL = await resolveStreamingURL(videoID: video.id, quality: preferences.preferredQuality) {
                log.info("resolveAndPlay: streaming \(streamURL.absoluteString, privacy: .public)")
                playbackURL = streamURL
            } else {
                log.error("resolveAndPlay: streaming fallback also unavailable for \(video.id, privacy: .public)")
                loadState = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                stopProgressObservation()
                return
            }
        }
        let item = AVPlayerItem(url: playbackURL)
        loadItem(item)
        loadState = .readyToPlay
        updateNowPlaying()
        if autoplay { play() }
        stopProgressObservation()
        log.info("resolveAndPlay: finished happy-path for \(video.id, privacy: .public)")
        // Fire-and-forget queue fill — uses YouTube's `/next` (WEB) endpoint, independent of the
        // resolver's `/player` (IOS) endpoint, so it can't interfere with playback that's already
        // running. Failures are logged but never surface to the user; queue stays as-is on error.
        //
        // Suppressed only when the caller explicitly asks (playlist's Play all / Shuffle all).
        // Every other entry point — single video taps from Home/Search/Mini-player, queue-row
        // taps, Next/Previous, and even tapping an individual playlist video — gets the
        // autoplay-style recommendation fill, so the player keeps advancing past the seed.
        // Background-prefetch the **single** next queue item so it's ready when the user taps Next
        // (or auto-advance kicks in). We deliberately only preload one — `PythonRunner` serializes
        // every yt-dlp invocation and we don't want a long preload chain blocking the user's
        // explicit play taps. The current item is already fully on disk and playing from local
        // file at this point, so kicking off the next download doesn't interrupt anything.
        //
        // **Ordering matters.** For non-playlist taps, the queue starts with just `[currentVideo]`
        // — recommendations haven't arrived yet. If we fire prefetch here unconditionally,
        // `queue.upcomingItems(count: 1)` returns empty and the prefetch silently no-ops. So:
        //   - Playlist Play All / Shuffle All path (`skipRecommendations: true`): the caller has
        //     pre-populated the queue, so prefetch can run immediately.
        //   - Default path (recommendations enabled): defer prefetch to the tail of the
        //     recommendations Task so it sees the freshly-appended "up next".
        if !skipRecommendations {
            Task { [weak self] in
                await self?.fillQueueWithRecommendations(for: video)
                await self?.prefetchNextUpcoming()
            }
        } else {
            prefetchNextUpcoming()
        }
    }

    /// Fires `DownloadManager.ensureDownloaded` for just the next queued video, in the background.
    /// Idempotent: returns instantly if the file is already on disk, and coalesces with any
    /// existing in-flight download for the same ID, so re-prefetching on every successful play is
    /// cheap.
    ///
    /// **User-gated** by `UserPreferences.prefetchNextInQueue`. Off → no background download
    /// is started; Next-tap will then fall into the standard `ensureDownloaded` path with
    /// `.userInitiated` priority (still works, just no head-start).
    private func prefetchNextUpcoming() {
        guard preferences.prefetchNextInQueue else {
            log.debug("prefetch: disabled in settings, skipping")
            return
        }
        guard let next = queue.upcomingItems(count: 1).first else { return }
        log.info("prefetch: queuing \(next.id, privacy: .public) for background download")
        Task { [preferredQuality = preferences.preferredQuality] in
            _ = try? await DownloadManager.shared.ensureDownloaded(
                video: next,
                quality: preferredQuality
            )
        }
    }

    /// Last-ditch URL resolver. Walks four tiers, returning the first one that produces a URL
    /// `AVPlayer` can open directly:
    ///   1. iOS-client HLS manifest (adaptive bitrate, best playback experience)
    ///   2. iOS-client progressive MP4 (muxed audio+video, no n-decoding needed)
    ///   3. TVHTML5 HLS manifest
    ///   4. TVHTML5 progressive MP4
    ///
    /// Why HLS is preferred: HLS chunks use short-lived signatures attached to the manifest
    /// rather than the player.js-derived `n` cipher, and YouTube doesn't typically PoT-stamp
    /// HLS the way it does DASH. When HLS isn't exposed (some kids/family content), the iOS
    /// client's `defaultFormats` still include direct progressive URLs that work without the
    /// player.js scrape — that's our second tier. Returns nil only when all four tiers fail.
    private func resolveStreamingURL(videoID: String, quality: VideoQuality) async -> URL? {
        let service = VideoService()
        if let info = try? await service.fetchInfo(id: videoID) {
            if let hls = info.streamingURL { return hls }
            logFormats(videoID: videoID, source: "IOS", formats: info.formats)
            if let progressive = Self.pickProgressiveURL(from: info.formats, maxHeight: quality.heightCap ?? .max) {
                return progressive
            }
        }
        if let info = try? await service.fetchInfoViaTVHTML5(id: videoID) {
            if let hls = info.streamingURL { return hls }
            logFormats(videoID: videoID, source: "TVHTML5", formats: info.formats)
            if let progressive = Self.pickProgressiveURL(from: info.formats, maxHeight: quality.heightCap ?? .max) {
                return progressive
            }
        }
        return nil
    }

    /// Dumps a one-line digest for each format so we can see what YouTube actually returned for
    /// content where the current heuristics produced no playable URL. Strips the URL down to its
    /// path prefix and the presence/absence of the `n=` cipher parameter — full URLs are sensitive
    /// (time-limited signed) and would leak into logs unredacted otherwise.
    private func logFormats(videoID: String, source: String, formats: [VideoFormat]) {
        log.info("formats[\(source, privacy: .public)] id=\(videoID, privacy: .public) count=\(formats.count, privacy: .public)")
        for f in formats {
            let hasURL = f.url != nil
            let hasN: Bool = {
                guard let q = f.url?.query else { return false }
                return q.contains("&n=") || q.hasPrefix("n=")
            }()
            let kind: String = f.containsBothTracks ? "muxed" : (f.isVideoOnly ? "videoOnly" : (f.isAudioOnly ? "audioOnly" : "?"))
            log.info("  itag=\(f.id, privacy: .public) kind=\(kind, privacy: .public) h=\(f.height ?? -1, privacy: .public) mime=\(f.mimeType, privacy: .public) hasURL=\(hasURL, privacy: .public) hasN=\(hasN, privacy: .public)")
        }
    }

    /// Picks the highest-quality progressive (audio+video muxed) format within the user's
    /// quality ceiling. AVPlayer can play these directly via `AVPlayerItem(url:)`; the audio-only
    /// and video-only adaptive streams would need an AVMutableComposition setup, which we skip
    /// here on purpose — this is the streaming-fallback path, not a full DASH player.
    private static func pickProgressiveURL(from formats: [VideoFormat], maxHeight: Int) -> URL? {
        formats
            .filter { $0.containsBothTracks && $0.url != nil }
            .filter { ($0.height ?? .max) <= maxHeight }
            .sorted { ($0.height ?? 0) > ($1.height ?? 0) }
            .first?
            .url
    }

    /// Fetches `MoreVideoInfosResponse` for the current video and appends the recommended videos to
    /// the queue. This is what makes the player behave like the YouTube app: tap any video and a
    /// fresh "up next" queue is ready to advance when the current track ends.
    private func fillQueueWithRecommendations(for seed: Video) async {
        do {
            let info = try await VideoService().fetchMoreInfo(id: seed.id)
            // Only append recommendations that aren't already queued, preserving the user's own
            // ordering if they came from a "Play all" playlist load.
            let existingIDs = Set(queue.items.map(\.id))
            let toAppend = info.recommended.filter { !existingIDs.contains($0.id) }
            for rec in toAppend {
                queue.append(rec)
            }
            log.info("Queued \(toAppend.count, privacy: .public) recommendations for \(seed.id, privacy: .public)")
        } catch {
            log.notice("Recommendation fetch failed for \(seed.id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private func installObservers() {
        // Periodic time observation via Combine-friendly bridging.
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                self.elapsed = time.seconds.isFinite ? time.seconds : 0
                if let item = self.player.currentItem {
                    let total = item.duration.seconds
                    if total.isFinite { self.duration = total }
                }
                self.updateNowPlaying()
            }
        }

        // Auto-advance on item end.
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                if self.preferences.autoplayNext { self.playNext() }
            }
        }

        // Mirror AVPlayer's transport state into our `isPlaying` flag so the custom transport row
        // under the video title (and the popup-bar play/pause glyph) reflects taps on the native
        // AVPlayerViewController controls. Without this, hitting the native pause button on the
        // video surface left our SwiftUI button showing "Pause" forever.
        // Persist user-driven speed changes from AVPlayerViewController's built-in speed menu.
        // The menu writes to `defaultRate`; KVO catches the write and we save it to prefs so the
        // next app launch starts at the same speed.
        defaultRateObservation = player.observe(\.defaultRate, options: [.new]) { [weak self] _, change in
            guard let self else { return }
            guard let newValue = change.newValue else { return }
            let rate = Double(newValue)
            // Sanity: defaultRate of 0 would mean "paused on play()" which YouTube/AVPlayerViewController
            // never offers as a user option. Ignore any such bogus write.
            guard rate > 0 else { return }
            Task { @MainActor in
                if abs(rate - self.preferences.playbackRate) > 0.001 {
                    self.log.info("playbackRate changed → \(rate, privacy: .public) (persisting)")
                    self.preferences.playbackRate = rate
                }
            }
        }

        timeControlStatusObservation = player.observe(\.timeControlStatus, options: [.new, .initial]) { [weak self] avPlayer, _ in
            guard let self else { return }
            let status = avPlayer.timeControlStatus
            Task { @MainActor in
                switch status {
                case .playing:
                    if !self.isPlaying {
                        self.log.info("KVO timeControlStatus → playing (sync isPlaying=true)")
                        self.isPlaying = true
                    }
                case .paused:
                    if self.isPlaying {
                        self.log.info("KVO timeControlStatus → paused (sync isPlaying=false)")
                        self.isPlaying = false
                    }
                case .waitingToPlayAtSpecifiedRate:
                    // Buffering / stalled. Treat as "playing" so the UI still shows pause icon,
                    // matching what the native AVPlayerViewController shows.
                    if !self.isPlaying {
                        self.isPlaying = true
                    }
                @unknown default:
                    break
                }
            }
        }
    }

    private func updateNowPlaying() {
        guard let video = currentVideo else { return }
        NowPlayingCenter.update(
            title: video.title,
            artist: video.channelName,
            duration: duration,
            elapsed: elapsed,
            rate: isPlaying ? 1.0 : 0.0,
            artwork: currentArtwork
        )
    }

    /// Resolves an artwork image for the given video and stores it in `currentArtwork`. Tries three
    /// sources in order:
    ///  1. Kingfisher's in-memory cache for the video's `thumbnailURL` (synchronous → no flicker).
    ///  2. `DownloadsStore`'s xattr-stored compressed thumbnail (for videos played from the Downloads tab,
    ///     where the constructed `Video` has `thumbnailURL == nil`).
    ///  3. Async network/disk fetch through Kingfisher.
    /// Clears artwork immediately so the previous video's preview doesn't linger on the lock screen.
    private func refreshArtwork(for video: Video) {
        currentArtwork = nil

        if let url = video.thumbnailURL,
           let cached = ImageCache.default.retrieveImageInMemoryCache(forKey: url.cacheKey) {
            currentArtwork = cached
            updateNowPlaying()
            return
        }

        // Xattr fallback for downloaded-only videos. `DownloadsStore.thumbnail(forVideoID:)`
        // is synchronous (the entries snapshot lives in memory) so we can decode + assign
        // inline rather than through a Task / background actor.
        let videoID = video.id
        if let data = DownloadsStore.shared.thumbnail(forVideoID: videoID),
           let image = UIImage(data: data) {
            currentArtwork = image
            updateNowPlaying()
        }

        // Async network/disk fetch as last resort.
        guard let url = video.thumbnailURL else { return }
        KingfisherManager.shared.retrieveImage(with: url) { [weak self, videoID = video.id] result in
            guard case .success(let value) = result else { return }
            Task { @MainActor in
                guard let self else { return }
                // Drop the result if the user switched videos while the fetch was inflight.
                guard self.currentVideo?.id == videoID else { return }
                self.currentArtwork = value.image
                self.updateNowPlaying()
            }
        }
    }
}
