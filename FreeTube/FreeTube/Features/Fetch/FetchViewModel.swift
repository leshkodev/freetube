import Foundation
import Observation
import OSLog

/// Drives the "From URL" tab: holds the URL the user is editing, the in-flight probe state,
/// the probed `RemoteMedia` (when successful), and the active download jobs.
///
/// Lives as `@State` on `FetchScreen` so it survives tab switches. Probe + download are
/// kicked off via async `Task`s; cancellation is supported by re-submitting a new URL.
@available(iOS 17.0, *)
@Observable
@MainActor
final class FetchViewModel {
    /// URL text bound to the input field. Trimming + validation happen on `submit()`.
    var query: String = ""

    /// URL string used as the queue key for the active probe. Set when `submit()` or
    /// `reprobe()` kicks off, threaded into `URLDownloadManager.startDownload(originalURL:)`
    /// so the download job lands under the same key the recents list joins on.
    private(set) var activeProbeURL: String?

    /// Currently picked video stream. `nil` means "audio only — no video in the output".
    /// Pre-populated with a sensible default whenever a new probe lands (see `applyDefaults`).
    var selectedVideoFormat: RemoteFormat?
    /// Currently picked audio stream. `nil` means "no separate audio" — which is the right
    /// state when the chosen video format is progressive (audio is already embedded) or when
    /// the user explicitly wants a silent video.
    var selectedAudioFormat: RemoteFormat?

    /// When true, the video stream is re-encoded to H.264 via Apple's hardware encoder
    /// (`h264_videotoolbox`) during download. Use for non-H.264 sources (VP9, AV1) that
    /// `AVPlayer` decodes poorly in MP4. Auto-defaults to true whenever the selected video
    /// format is non-H.264 — see `recomputeConversionDefaults`.
    var convertVideoToH264: Bool = false

    /// When true, audio is re-encoded to MP3 via `libmp3lame` (192 kbps). Off by default;
    /// kept as an opt-in because MP3 is lossy (a second time, since most sources are
    /// already lossy AAC/Opus). Useful for sharing with tools that don't accept m4a/opus.
    var convertAudioToMP3: Bool = false

    /// State machine for the probe phase. The screen renders different content per case —
    /// `idle` shows the URL field + recents, `loading` shows a spinner, `loaded` shows the
    /// format picker, `failed` shows an error retry banner.
    private(set) var probeState: ProbeState = .idle

    /// Recent URL history mirror. Read on init and re-published on `recordRecent(...)` so
    /// the UI's `@Observable` change-tracker picks up additions immediately.
    private(set) var recents: [RecentFetchURL] = []

    private var probeTask: Task<Void, Never>?
    @ObservationIgnored private let infoService = YtDlpInfoService()
    @ObservationIgnored private let preferences = UserPreferences()
    @ObservationIgnored private let log = AppLog(subsystem: "com.leshko.freetube", category: "FetchViewModel")

    init() {
        recents = preferences.recentFetchURLs
    }

    enum ProbeState {
        case idle
        /// Holds the URL being probed so a stale completion can't overwrite a newer one.
        case loading(url: String)
        case loaded(RemoteMedia)
        case failed(message: String, url: String)
    }

    /// Submits the current `query`. Validates as a URL (loose — requires a scheme or "://"
    /// presence), records it in recents, and kicks off the probe.
    func submit() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Loose URL check: yt-dlp accepts many "host/path" shapes without explicit scheme,
        // but we need a real URL for ourselves elsewhere. Default to https:// if missing.
        let normalised = trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
            ? trimmed
            : "https://" + trimmed
        guard URL(string: normalised) != nil else {
            probeState = .failed(message: "That doesn't look like a URL.", url: trimmed)
            return
        }
        probe(url: normalised)
    }

    /// Re-runs the probe for one of the recent entries.
    func reprobe(_ recent: RecentFetchURL) {
        query = recent.url
        probe(url: recent.url)
    }

    func clearResult() {
        probeState = .idle
        activeProbeURL = nil
    }

    // MARK: - Queue-row state

    /// What the queue row in `FetchScreen` should render for a given recents entry.
    /// Computed by joining the persisted `RecentFetchURL` (URL, title, thumbnail, local
    /// filename) with the live `URLDownloadManager.jobs[url]` entry and a filesystem
    /// existence check.
    enum RowState: Equatable {
        /// No download has ever completed for this URL, and no job is running. Default state
        /// for entries that exist only because the user probed but didn't download yet.
        case idle
        /// Active download. `progress == nil` for indeterminate (ffmpeg HLS phase).
        case downloading(progress: Double?, phase: String?)
        /// Post-download muxing or other processing.
        case processing(message: String)
        /// Download finished, file is on disk at `fileURL`. The row should show More menu.
        case completed(fileURL: URL)
        /// Last attempt failed or was cancelled. Row should show Redownload.
        case failed(message: String)
    }

    /// Resolves the current state for a recents row. Called from `FetchScreen` for every
    /// visible row on every body re-render — kept allocation-free.
    func rowState(for entry: RecentFetchURL) -> RowState {
        if let job = URLDownloadManager.shared.jobs[entry.url] {
            switch job.state {
            case .queued:
                return .downloading(progress: 0, phase: "Queued")
            case .downloading(let p, let phase):
                return .downloading(progress: p, phase: phase)
            case .processing(let msg):
                return .processing(message: msg)
            case .completed(let fileURL):
                return .completed(fileURL: fileURL)
            case .failed(let msg):
                return .failed(message: msg)
            }
        }
        // No live job — fall back to the persisted file path if present.
        if let filename = entry.localFilename, let fileURL = URLDownloadManager.resolveLocalFile(filename: filename) {
            return .completed(fileURL: fileURL)
        }
        return .idle
    }

    /// Cancel an in-flight download for a recents row.
    func cancelDownload(for entry: RecentFetchURL) {
        URLDownloadManager.shared.cancel(url: entry.url)
    }

    /// Re-run the probe so the user lands back on the Preview screen with fresh format
    /// URLs (yt-dlp's signed URLs expire). Used for the "Redownload" button on failed rows
    /// and for tapping an idle/non-downloaded recents row.
    func reopenProbe(for entry: RecentFetchURL) {
        query = entry.url
        probe(url: entry.url)
    }

    /// Deletes a recents entry without removing any on-disk download it spawned.
    func deleteRecent(_ recent: RecentFetchURL) {
        recents.removeAll { $0.url == recent.url }
        preferences.recentFetchURLs = recents
    }

    func clearRecents() {
        recents = []
        preferences.recentFetchURLs = []
    }

    // MARK: - Internals

    private func probe(url: String) {
        log.info("[FetchVM] probe() called for url=\(url, privacy: .public); cancelling prior task if any")
        // Cancel any in-flight probe — only the most recent submission matters. The
        // PythonRunner queue itself can't be preempted (CLAUDE.md §15.1), so an old probe
        // will still run on the Python thread to completion; we just discard its result.
        probeTask?.cancel()
        activeProbeURL = url
        probeState = .loading(url: url)
        log.info("[FetchVM] probeState → .loading; spawning probe task")
        let task = Task { [weak self, infoService] in
            guard let self else { return }
            self.log.info("[FetchVM] probe task body starting; calling infoService.probe")
            do {
                let media = try await infoService.probe(url: url)
                self.log.info("[FetchVM] infoService.probe returned with \(media.formats.count, privacy: .public) formats")
                try Task.checkCancellation()
                self.applyDefaults(for: media)
                self.probeState = .loaded(media)
                self.log.info("[FetchVM] probeState → .loaded; expecting FetchScreen to push FetchProbeView")
                self.recordRecent(url: url, media: media)
            } catch is CancellationError {
                self.log.notice("[FetchVM] probe task cancelled (stale)")
                // Stale — don't overwrite the newer probe's state.
            } catch {
                self.log.error("[FetchVM] probe failed surfacing error to UI: \(String(describing: error), privacy: .public)")
                self.probeState = .failed(message: Self.userFacingMessage(for: error), url: url)
                // Still record the URL so the user can re-try from recents without retyping.
                self.recordRecent(url: url, media: nil)
            }
        }
        probeTask = task
    }

    /// Picks the best video + best audio as the initial selection whenever a fresh probe
    /// lands. Tries to deliver "muxed mp4 that AVPlayer can actually decode" by default:
    ///   - Video: prefer H.264 over VP9/AV1, then best resolution, then best fps. Apple's
    ///     `AVPlayer` decodes VP9-in-MP4 unreliably across macOS / iOS versions — Instagram
    ///     in particular serves VP9 reels which play as audio-only on many systems. H.264
    ///     is the universal-compatibility default.
    ///   - Audio: best audio-only when the chosen video is video-only; nil when the chosen
    ///     video already has audio embedded (progressive) so we don't try to mux an
    ///     unrelated audio track over a self-contained file.
    private func applyDefaults(for media: RemoteMedia) {
        let usable = media.formats.filter { $0.url != nil && $0.protocolKind != .unsupported }
        let videoOnly = usable.filter { $0.isVideoOnly }
        let progressive = usable.filter { $0.isProgressive }
        let audioOnly = usable.filter { $0.isAudioOnly }

        let bestVideoOnly = videoOnly.max(by: Self.videoRank)
        let bestProgressive = progressive.max(by: Self.videoRank)
        let bestAudioOnly = audioOnly.max { ($0.abr ?? 0) < ($1.abr ?? 0) }

        if let v = bestVideoOnly {
            selectedVideoFormat = v
            selectedAudioFormat = bestAudioOnly
        } else if let p = bestProgressive {
            selectedVideoFormat = p
            selectedAudioFormat = nil // audio already embedded
        } else {
            // Audio-only source (SoundCloud, podcast, etc.).
            selectedVideoFormat = nil
            selectedAudioFormat = bestAudioOnly
        }
        recomputeConversionDefaults()
    }

    /// Auto-set the "Convert to H.264" toggle when the chosen video codec is something
    /// `AVPlayer` decodes unevenly (VP9, AV1). Audio MP3 conversion stays user-driven —
    /// AAC/Opus are universally playable on Apple platforms, so default off.
    ///
    /// Called on every format selection change so the toggle reflects the current choice.
    func recomputeConversionDefaults() {
        if let codec = selectedVideoFormat?.vcodec?.lowercased() {
            let isAppleFriendly = codec.hasPrefix("avc") || codec.contains("h264")
                || codec.hasPrefix("hev") || codec.hasPrefix("hvc") || codec.contains("hevc") || codec.contains("h265")
            convertVideoToH264 = !isAppleFriendly
        } else {
            convertVideoToH264 = false
        }
    }

    /// Ranking comparator for video formats. Higher = better. Returns `lhs < rhs`, so the
    /// caller writes `.max(by: videoRank)`. Order of importance:
    ///   1. H.264 (avc1 / "h264") is preferred over everything — best AVPlayer compat.
    ///   2. Then HEVC (h265 / hev1) — also natively decoded since iOS 11.
    ///   3. Then everything else (VP9, AV1, …) which AVPlayer handles unevenly.
    ///   4. Within the same codec tier, larger resolution wins, then higher fps.
    static func videoRank(_ lhs: RemoteFormat, _ rhs: RemoteFormat) -> Bool {
        let lhsScore = codecTier(lhs.vcodec)
        let rhsScore = codecTier(rhs.vcodec)
        if lhsScore != rhsScore { return lhsScore < rhsScore }
        if (lhs.height ?? 0) != (rhs.height ?? 0) { return (lhs.height ?? 0) < (rhs.height ?? 0) }
        return (lhs.fps ?? 0) < (rhs.fps ?? 0)
    }

    /// Higher tier = better for AVPlayer compatibility. Used by `videoRank`.
    private static func codecTier(_ vcodec: String?) -> Int {
        guard let raw = vcodec?.lowercased(), !raw.isEmpty else { return 0 }
        if raw.hasPrefix("avc") || raw.contains("h264") || raw.contains("h.264") { return 3 }
        if raw.hasPrefix("hev") || raw.hasPrefix("hvc") || raw.contains("h265") || raw.contains("hevc") { return 2 }
        // VP9, AV1, anything else — playable but unreliable in mp4 container on Apple stacks.
        return 1
    }

    /// Bubbles the entry to the top of recents (or inserts), trims to 20, persists.
    private func recordRecent(url: String, media: RemoteMedia?) {
        var list = preferences.recentFetchURLs
        list.removeAll { $0.url == url }
        list.insert(RecentFetchURL(
            url: url,
            title: media?.title,
            extractor: media?.extractor,
            lastUsedAt: .now
        ), at: 0)
        preferences.recentFetchURLs = list
        recents = preferences.recentFetchURLs
    }

    /// Translates errors into user-readable single-line messages. Most yt-dlp errors land
    /// as `PythonError.exception(_:)`; the embedded Python traceback is too verbose for the
    /// UI, so we strip to the last line.
    private static func userFacingMessage(for error: Error) -> String {
        let raw = String(describing: error)
        // Common pattern: "PythonError.exception(<text>)" with text containing "ERROR: ..."
        if let range = raw.range(of: "ERROR:") {
            let tail = String(raw[range.lowerBound...])
            return tail
                .split(separator: "\n").first.map(String.init)?
                .replacingOccurrences(of: "ERROR: ", with: "") ?? tail
        }
        return raw
            .split(separator: "\n").last.map(String.init) ?? "Couldn't read that URL."
    }
}
