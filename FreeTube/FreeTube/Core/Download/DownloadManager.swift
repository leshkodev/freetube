import AVFoundation
import CoreMedia
import FFmpegSupport
import Foundation
import Network
import OSLog
import PythonKit
import SwiftData
import UIKit
import YoutubeDL

/// Runs every Python / yt-dlp call on a single dedicated background thread, off the main actor.
///
/// **The two failure modes this solves:**
/// 1. **Wrong-thread crash.** PythonKit + CPython assume only one thread touches the interpreter
///    — specifically, the same thread that ran `PythonSupport.initialize()`. A plain `actor` runs
///    its methods on its own cooperative-queue executor, where workers rotate between threads —
///    Python's `_PyInterpreterState_GET` crashes the moment it sees an unrecognized worker. We fix
///    this with a **custom `SerialExecutor`** backed by a serial `DispatchQueue`: GCD reuses the
///    same worker thread back-to-back for serial-queue jobs, so Python sees a stable thread.
/// 2. **Reentrancy interleaving.** Actor methods only guarantee one *body* runs at a time — but
///    when that body suspends at an `await`, the executor is free to pick up the next caller. So
///    even a serial actor can have two `yt_dlp` calls suspended on it simultaneously, tramping
///    each other's interpreter state. We fix this with **strict Task-chaining** through `pending`:
///    new callers don't just `await` to enter the actor, they explicitly wait for the previous
///    Task to fully finish before starting their own yt-dlp.
@available(iOS 17.0, *)
actor PythonRunner {
    static let shared = PythonRunner()

    /// `nonisolated` so we can log from anywhere — including the detached pump task
    /// without an actor hop. Used by every choke point on the Link-probe / YouTube-download
    /// path so a TestFlight log can pinpoint exactly which step stalled.
    @ObservationIgnored private nonisolated let log = AppLog(subsystem: "com.leshko.freetube", category: "PythonRunner")

    /// Priority levels for incoming yt-dlp work. `.high` is reserved for downloads the user is
    /// actively waiting on (e.g. tapping a video in search results — they want playback now).
    /// `.low` is the default for background work (playlist Download All, queue prefetch).
    /// Within the same priority, items are processed FIFO. A high-priority arrival jumps ahead
    /// of every pending low-priority item but **cannot** preempt the currently-running yt-dlp:
    /// Python's interpreter has no safe interrupt point.
    enum Priority {
        case high
        case low
    }

    /// Pins this actor to a dedicated background-thread executor (NOT the main actor's executor and
    /// NOT the cooperative pool). GCD's serial queue gives us thread stability "in practice" —
    /// back-to-back jobs on the same serial queue use the same worker thread, which is what
    /// PythonKit needs.
    private nonisolated let executor = PythonSerialExecutor()
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }

    /// A unit of work runnable on the Python-isolated execution context. Each job handles
    /// its own completion (resuming whatever continuation the public-API call created), so
    /// `pump()` just runs them sequentially without having to know what kind they are.
    /// This unification lets us serialize yt-dlp downloads AND one-off Python operations
    /// (e.g. `YtDlpUpdater`'s version read) through the same FIFO — without it, two paths
    /// calling `Python.attemptImport` from different cooperative-pool workers would race
    /// CPython's interpreter state and crash with `_PyTuple_FromArray` / `init_fs_encoding`.
    private typealias Job = @Sendable () async -> Void

    private var highPriority: [Job] = []
    private var lowPriority: [Job] = []
    /// True while a yt-dlp invocation is in flight. The pump loop sets this on entry and clears
    /// on exit; any reentrant `run(…)` calls that arrive during the `await` see this flag, just
    /// enqueue their ticket, and exit without spawning a parallel pump.
    private var isRunning = false

    private init() {}

    /// Submit a yt-dlp run. The call suspends until this ticket reaches the front of its
    /// priority lane AND any in-flight yt-dlp finishes — guaranteeing strict serialization
    /// (Python interpreter can only host one yt-dlp at a time) while letting `.high` callers
    /// jump ahead of any pending `.low` backlog.
    ///
    /// Default priority is `.low`. Pass `.high` from playback paths where the user is actively
    /// waiting for the video to start (search/home tap, play-next, mini-player resume).
    func run(argv: [String],
             progress: @escaping @Sendable ([String: PythonObject]) -> Void,
             log ytLog: @escaping @Sendable (String, String) -> Void,
             priority: Priority = .low) async throws {
        log.info("[PythonRunner.run] enqueue priority=\(String(describing: priority), privacy: .public) argv0=\(argv.first ?? "?", privacy: .public)")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let log = self.log
            let job: Job = {
                log.info("[PythonRunner.run] job starting freetube_yt_dlp")
                do {
                    try await freetube_yt_dlp(argv: argv, progress: progress, log: ytLog)
                    log.info("[PythonRunner.run] job completed")
                    continuation.resume()
                } catch {
                    log.error("[PythonRunner.run] job threw: \(String(describing: error), privacy: .public)")
                    continuation.resume(throwing: error)
                }
            }
            switch priority {
            case .high: highPriority.append(job)
            case .low:  lowPriority.append(job)
            }
            log.info("[PythonRunner.run] enqueued; spawning pump (queue high=\(self.highPriority.count, privacy: .public) low=\(self.lowPriority.count, privacy: .public) isRunning=\(self.isRunning, privacy: .public))")
            // Spawn a pump task — if one's already running it's a no-op, otherwise it drains
            // the queues sequentially. Detached to keep the priority on the work, not on the
            // caller (a UI-tap-priority caller shouldn't pin the entire download chain to that
            // priority — see `.utility` choice in the pump loop).
            Task { await self.pump() }
        }
    }

    /// Run an arbitrary Python-touching closure serialized through this runner's FIFO.
    /// Use for one-off operations that need a Python interpreter (e.g. `YtDlpUpdater`'s
    /// post-download version read via `Python.attemptImport("yt_dlp")`) so they never
    /// race in-flight yt-dlp work on a different cooperative-pool worker.
    ///
    /// **Always jumps to `.high` priority** — these are short, user-facing operations
    /// (a stuck version read holds up Settings UI feedback). The yt-dlp lane has its own
    /// `.high` for play-now taps, so `runIsolated` work and a play-now tap still interleave
    /// fairly, just both ahead of any background backlog.
    ///
    /// Same execution context as `run(argv:)`: a `Task.detached(priority: .utility)`
    /// inside `pump()`. Don't put SwiftUI / main-actor work in here — only Python.
    func runIsolated<T: Sendable>(_ work: @Sendable @escaping () async throws -> T) async throws -> T {
        log.info("[PythonRunner.runIsolated] enqueue (queue high=\(self.highPriority.count, privacy: .public) low=\(self.lowPriority.count, privacy: .public) isRunning=\(self.isRunning, privacy: .public))")
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let log = self.log
            let job: Job = {
                log.info("[PythonRunner.runIsolated] job starting work closure")
                do {
                    let result = try await work()
                    log.info("[PythonRunner.runIsolated] work returned successfully")
                    continuation.resume(returning: result)
                } catch {
                    log.error("[PythonRunner.runIsolated] work threw: \(String(describing: error), privacy: .public)")
                    continuation.resume(throwing: error)
                }
            }
            highPriority.append(job)
            log.info("[PythonRunner.runIsolated] enqueued; spawning pump")
            Task { await self.pump() }
        }
    }

    /// Drains the queues one ticket at a time. Always pulls from `highPriority` first, so a
    /// `.high` arrival during a long `.low` backlog runs immediately after the currently-executing
    /// item — not at the end of the queue.
    ///
    /// **Why `freetube_yt_dlp(...)` instead of the package's `yt_dlp(...)`:** the package's
    /// function doesn't expose a splice point between `injectFakePopen` (which replaces
    /// `subprocess.Popen` with an ffmpeg-only `Pop`) and `ydl.download`. We need to insert
    /// `PythonJSBridge.install()` at exactly that point so yt-dlp's `deno`-based n-cipher
    /// solver transparently routes through our JavaScriptCore shim. See
    /// `Core/JavaScript/FreeTubeYtDlp.swift` for the longer rationale.
    ///
    /// **Why `Task.detached(priority: .utility) { ... }` and NOT plain `Task { ... }`:** this
    /// project has `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` set. Under that setting, an
    /// unstructured `Task { ... }` closure (with no explicit isolation) is treated as
    /// `@MainActor` — even when created from inside a non-main actor like `PythonRunner`. The
    /// inner `try await freetube_yt_dlp(...)` would then execute on the main thread, dragging
    /// every Python eval, SSL handshake, and yt-dlp extractor call onto main and producing
    /// a long "main thread hung" stack (visible as `_ssl__SSLSocket_do_handshake` → … →
    /// `freetube_yt_dlp` → `closure #1 in PythonRunner.pump()` on Thread 1).
    ///
    /// `Task.detached` is the explicit "do NOT inherit isolation" form — it always runs in a
    /// nonisolated context (cooperative thread pool). That's also the historical behavior the
    /// PythonRunner architecture was designed for: CPython runs on a stable cooperative-pool
    /// worker, off the main thread, off the PythonSerialExecutor queue (so GCD priority
    /// escalation from main awaiting `.utility` doesn't apply either).
    ///
    /// **Don't change this back to plain `Task { ... }` without also turning off
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION` for this file.** Plain `Task` only worked before that
    /// build setting was introduced.
    /// `@_optimize(none)` is intentionally kept here even though the project-level
    /// `SWIFT_OPTIMIZATION_LEVEL = "-Onone"` for Release already disables optimization.
    /// It belongs to the diagnostic-clutter set noted in commit 137ead99 ("All 19 critical
    /// PythonKit dlsym symbols present") that should only be reverted **one at a time,**
    /// after each TestFlight build confirms the previous step still works. Reverting all
    /// three (this annotation + the two pbxproj knobs) at once is what caused the
    /// TestFlight hang where yt-dlp update + Link probe spin forever — Swift's whole-module
    /// optimizer breaks the PythonKit/CPython single-thread interpreter discipline.
    @_optimize(none)
    private func pump() async {
        guard !isRunning else {
            log.info("[PythonRunner.pump] already running, exiting")
            return
        }
        isRunning = true
        defer {
            isRunning = false
            log.info("[PythonRunner.pump] queue drained, exiting")
        }
        log.info("[PythonRunner.pump] entering drain loop (high=\(self.highPriority.count, privacy: .public) low=\(self.lowPriority.count, privacy: .public))")

        var ticketNumber = 0
        while let job = takeNext() {
            ticketNumber += 1
            let n = ticketNumber
            log.info("[PythonRunner.pump] ticket #\(n, privacy: .public) starting on detached .utility task")
            // Each job already owns its continuation and handles its own throwing; we just
            // run it on the cooperative pool and wait for completion before pulling the
            // next item. Strict serialization — never two Python interpreters at once.
            let task = Task.detached(priority: .utility) {
                await job()
            }
            _ = await task.value
            log.info("[PythonRunner.pump] ticket #\(n, privacy: .public) finished; next…")
        }
    }

    private func takeNext() -> Job? {
        if !highPriority.isEmpty { return highPriority.removeFirst() }
        if !lowPriority.isEmpty { return lowPriority.removeFirst() }
        return nil
    }
}

/// Serializes every call into the ffmpeg C library.
///
/// **Why this is necessary:** `FFmpegSupport.ffmpeg(_:)` is a re-entrant entry point into a C
/// library with shared global state — most painfully the `+faststart` post-pass (which calls
/// `ff_format_shift_data` to move the moov atom to the front of the file). That pass walks
/// global I/O buffers and is *not* thread-safe; two concurrent invocations on the cooperative
/// thread pool race on `_platform_memmove` and crash with EXC_BAD_ACCESS. The `Hook.m` shim also
/// uses `setjmp`/`longjmp`, which has undefined behavior across concurrent calls.
///
/// Parallel playlist downloads (Download All firing N `ensureDownloaded` tasks at once) was the
/// trigger that exposed this — each yt-dlp completion fed into its own `Task.detached` ffmpeg
/// call. With this actor, every ffmpeg invocation chains strictly behind the previous one
/// through `pending`, same FIFO pattern `PythonRunner` uses for yt-dlp.
@available(iOS 17.0, *)
actor FFmpegRunner {
    static let shared = FFmpegRunner()

    /// Tail of the in-flight FIFO. New callers await this before invoking ffmpeg, so only one
    /// ffmpeg call is ever in flight at a time even though the actor body itself can suspend.
    private var pending: Task<Void, Never>?

    private init() {}

    /// Runs ffmpeg with the given argv off the main actor and returns its exit code. Concurrent
    /// callers are queued — they don't run until the previous ffmpeg call has fully returned.
    func run(_ args: [String]) async -> Int32 {
        let previous = pending

        // Detach onto a `.utility` worker so the ffmpeg C work doesn't block the actor's own
        // executor *and* doesn't compete with main-thread UI priority. We `await previous?.value`
        // first to enforce the serial-FIFO invariant.
        let task = Task<Int32, Never>.detached(priority: .utility) {
            await previous?.value
            return Int32(ffmpeg(args))
        }

        pending = Task<Void, Never> { _ = await task.value }

        return await task.value
    }
}

/// `SerialExecutor` that dispatches all jobs to a single serial `DispatchQueue`. The queue's
/// worker-thread stability is what makes Python happy — Python's per-thread state was set up
/// on whichever worker handled the first job and stays valid because GCD reuses the same worker
/// for the queue's subsequent jobs.
@available(iOS 17.0, *)
final class PythonSerialExecutor: SerialExecutor, @unchecked Sendable {
    // `.utility` keeps the Python thread off `.userInitiated` priority — downloads are
    // background work, not UI-blocking, so they shouldn't compete with the main thread for
    // CPU. With `.userInitiated`, list scrolling visibly stuttered while yt-dlp was reading
    // SSL data.
    private let queue = DispatchQueue(label: "com.leshko.freetube.python", qos: .utility)

    func enqueue(_ job: UnownedJob) {
        let unowned = asUnownedSerialExecutor()
        queue.async {
            job.runSynchronously(on: unowned)
        }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }
}

/// Owns the on-disk video cache, runs YoutubeDL-iOS to fetch new ones, and surfaces progress so UI
/// can render a live transfer queue.
///
/// **Playback contract (CLAUDE.md §7 amended):**
/// Every play tap calls `ensureDownloaded(video:quality:)`. If `Documents/<id>.mp4` already
/// exists, we return immediately. Otherwise we kick off a yt-dlp run (via `YoutubeDL.yt_dlp(argv:)`),
/// wait for it, write a `DownloadMetadata` xattr to the resulting file, and hand the local URL back to the resolver. This
/// sidesteps every PoT/cookie/HLS edge case in YouTube's CDN — the bytes are on disk before
/// AVPlayer ever sees them.
///
/// **Progress:** the manager publishes a single `AsyncStream<[DownloadTaskSnapshot]>` that any
/// observer can subscribe to. Both the Downloads screen and the per-tab badge read from it.
@available(iOS 17.0, *)
@Observable
@MainActor
final class DownloadManager: TemporaryDownloading {
    static let shared = DownloadManager()

    /// Live snapshots of every in-flight + recently completed download. Both the Downloads screen
    /// and the tab-badge model observe this directly via `@Observable`. Previous design used a
    /// single-consumer `AsyncStream` which silently dropped events for the second subscriber — that
    /// is why the Downloads tab looked empty while the badge was incrementing.
    private(set) var activeTasks: [DownloadTaskSnapshot] = []

    /// Per-video downloaded progress (0…1). The player observes this so the mini-player and the
    /// full-screen player can render a progress overlay while a file is being fetched.
    private(set) var progressByVideoID: [String: Double] = [:]
    /// Per-video human-readable phase label ("video", "audio", "muxing"). yt-dlp downloads multiple
    /// streams sequentially under the same id, so we surface which one is currently in-flight to
    /// avoid the confusing "Downloading 100%" → "Downloading 0%" → "Downloading 100%" sequence.
    private(set) var phaseByVideoID: [String: String] = [:]

    private var tasks: [String: DownloadTaskSnapshot] = [:]

    /// Throttles the progress publish stream. yt-dlp emits progress events 5–10× per second per
    /// active download, and each `publish(snapshot:)` writes to 3 `@Observable` dictionaries plus
    /// rebuilds `activeTasks`. With several parallel downloads (Download All) the main actor was
    /// processing 30+ Observable mutations per second, and SwiftUI's per-mutation diff pass was
    /// what users felt as "scrolling stutters while downloading". We coalesce: if a video's most
    /// recent publish was less than `progressPublishMinInterval` ago, the new event is dropped.
    /// The next event arriving after the window catches up automatically, and terminal events
    /// (`finished` / `error`) bypass throttling entirely so we never miss a completion.
    private var lastProgressPublishedAt: [String: ContinuousClock.Instant] = [:]
    private let progressPublishMinInterval: Duration = .milliseconds(200)

    /// Coalesces concurrent `ensureDownloaded` calls for the same video so we don't start two
    /// downloads in parallel for the same id (which would race on the destination path).
    private var inflight: [String: Task<URL, Error>] = [:]
    private let preferences = UserPreferences()
    @ObservationIgnored private let log = AppLog(subsystem: "com.leshko.freetube", category: "DownloadManager")
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    private var currentPath: NWPath?

    private init() {
        startMonitoringPath()
    }

    // MARK: - Public surface

    /// Returns the local file URL for a downloaded video, or nil if it isn't on disk.
    /// Pure filesystem check — no I/O beyond `fileExists`. Called from SwiftUI bodies, so
    /// no logging here.
    func localFile(for videoID: String) -> URL? {
        let url = Self.fileURL(for: videoID)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Either returns the existing local file URL, or downloads the video via yt-dlp and returns
    /// the freshly-written path. Coalesces parallel callers for the same `videoID`.
    ///
    /// `priority` controls where the download lands in `PythonRunner`'s queue. `.userInitiated`
    /// — the call comes from a play tap, the user is actively waiting — jumps ahead of any
    /// pending `.background` items (playlist Download All, queue prefetch). The currently-running
    /// yt-dlp cannot be preempted, but the new high-priority item runs immediately after it.
    func ensureDownloaded(video: Video, quality: VideoQuality, priority: DownloadPriority = .background) async throws -> URL {
        log.info("ensureDownloaded(\(video.id, privacy: .public)) — title=\"\(video.title, privacy: .public)\" quality=\(quality.rawValue, privacy: .public) priority=\(String(describing: priority), privacy: .public)")
        if let existing = localFile(for: video.id) {
            log.info("ensureDownloaded(\(video.id, privacy: .public)): cache hit, skipping yt-dlp")
            return existing
        }

        if let inflightTask = inflight[video.id] {
            log.info("ensureDownloaded(\(video.id, privacy: .public)): joining inflight task")
            return try await inflightTask.value
        }

        log.info("ensureDownloaded(\(video.id, privacy: .public)): checking network gate (allowCellular=\(self.preferences.allowCellularDownloads, privacy: .public))")
        try await waitForAllowedNetwork()
        log.info("ensureDownloaded(\(video.id, privacy: .public)): network gate passed, spawning download task")

        let task = Task<URL, Error> { @MainActor [weak self] in
            guard let self else { throw YouTubeServiceError.unknown(NSError(domain: "DownloadManager", code: -1)) }
            defer { self.inflight[video.id] = nil }
            return try await self.runYoutubeDLDownload(video: video, quality: quality, priority: priority)
        }
        inflight[video.id] = task
        return try await task.value
    }

    /// Removes the downloaded file (if any) plus its SwiftData row. Safe to call when nothing is on
    /// disk — just no-ops. The `context` parameter is kept for source compatibility but the actual
    /// SwiftData delete now goes through the background `PersistenceWriter` so we don't block the
    /// main thread on the SQL queue.
    func deleteDownloaded(videoID: String, context: ModelContext) {
        let url = Self.fileURL(for: videoID)
        // File-system backed: removing the file drops its xattr too. `DownloadsStore` posts
        // the change notification on our behalf so the Downloads tab refreshes.
        DownloadsStore.shared.delete(at: url)
        log.info("Deleted download \(videoID, privacy: .public)")
    }

    func cancel(taskID: String) {
        guard let snapshot = tasks[taskID] else { return }
        tasks[taskID] = nil
        publishSnapshots()
        if let task = inflight[snapshot.videoID] {
            task.cancel()
            inflight[snapshot.videoID] = nil
        }
    }

    // MARK: - TemporaryDownloading

    /// Legacy path retained to satisfy the resolver protocol. The new resolver calls
    /// `ensureDownloaded(video:quality:)` directly; this is just a thin wrapper.
    func downloadTemporary(videoID: String, format: VideoFormat) async throws -> URL {
        let placeholder = Video(
            id: videoID,
            title: videoID,
            channelID: "",
            channelName: "",
            channelThumbnailURL: nil,
            thumbnailURL: nil,
            duration: nil,
            viewCount: nil,
            publishedAt: nil,
            descriptionSnippet: nil,
            isLive: false,
            isShort: false
        )
        return try await ensureDownloaded(video: placeholder, quality: preferences.preferredQuality)
    }

    // MARK: - yt-dlp execution

    private func runYoutubeDLDownload(video: Video, quality: VideoQuality, priority: DownloadPriority = .background) async throws -> URL {
        let startedAt = Date()
        log.info("yt-dlp[\(video.id, privacy: .public)] runYoutubeDLDownload start quality=\(quality.rawValue, privacy: .public)")
        let snapshotID = UUID().uuidString
        log.debug("yt-dlp[\(video.id, privacy: .public)] snapshotID=\(snapshotID, privacy: .public) → state=queued")
        publish(snapshot: DownloadTaskSnapshot(
            id: snapshotID,
            videoID: video.id,
            title: video.title,
            state: .queued,
            createdAt: .now
        ))

        let destination = Self.fileURL(for: video.id)
        let downloadsDir = destination.deletingLastPathComponent()
        let stem = destination.deletingPathExtension().lastPathComponent
        log.debug("yt-dlp[\(video.id, privacy: .public)] destination=\(destination.path, privacy: .public)")

        // Pre-download filesystem work — creating the dir and scanning for stale siblings — runs
        // on a `.utility` background task instead of blocking the main actor. With several
        // parallel downloads this saves measurable scroll-hitch time on every Download All tap.
        await Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
            } catch {
                // Best-effort — directory probably already exists from a prior download.
            }
            if let siblings = try? FileManager.default.contentsOfDirectory(at: downloadsDir, includingPropertiesForKeys: nil) {
                for url in siblings where url.lastPathComponent.hasPrefix("\(stem).") {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }.value

        // Use `,` (download multiple formats as separate files) instead of `+` (download + merge
        // via ffmpeg). yt-dlp's ffmpeg merger reliably hangs on iOS — once `Popen.communicate`
        // dispatches the merger ffmpeg subprocess we never see Python return. Doing the mux ourselves
        // via AVAssetExportSession is the robust path. We still keep a single-file fallback
        // (`best[ext=mp4]/best`) for the rare case where YouTube serves a combined progressive file.
        let formatString = Self.formatString(for: quality)
        log.debug("yt-dlp[\(video.id, privacy: .public)] format selector=\(formatString, privacy: .public)")
        // Output template includes `%(format_id)s` so individual streams land at predictable paths
        // we can find afterwards. Final destination is set by us after the Swift-side mux.
        let outputTemplate = destination.deletingPathExtension().path + ".%(format_id)s.%(ext)s"

        // yt-dlp argv. We force mp4 output, point `-o` at our canonical Downloads/<id>.mp4 path,
        // skip writing playlist info, and feed the cleanest possible argument set. The package's
        // global yt_dlp(argv:) routes through Python and intercepts subprocess.Popen for ffmpeg/ffprobe,
        // so the in-tree FFmpegSupport library handles muxing transparently.
        //
        // `--no-check-certificates` is required because the embedded Python runtime (Python-iOS)
        // doesn't ship with a CA cert bundle on a path OpenSSL expects, so verification fails with
        // `CERTIFICATE_VERIFY_FAILED` on the first YouTube API request. We accept the trade-off
        // because (a) the only host we talk to is youtube.com / googlevideo.com, (b) this is a
        // sideload/personal app, and (c) the alternative is shipping certifi's cacert.pem and
        // setting `SSL_CERT_FILE` ourselves — that can come later.
        //
        // **No `--cookies` flag** — counter-intuitive, but yt-dlp's safety check
        // ("Skipping client X since it does not support cookies") removes the `tv_simply`,
        // `ios`, and `android_vr` clients from the fallback chain whenever a cookies file is
        // present. Those are exactly the clients that give us the broadest format coverage on
        // PoT-locked content. With cookies the surviving clients (`web_creator`, `mweb`)
        // honestly report "No video formats found" — the bottleneck was never cookie auth, it
        // was the JS-runtime-less n-cipher (CLAUDE.md §15.4). See `makeTemporaryCookiesFile`
        // doc-comment for the longer history of this experiment.
        let argv: [String] = [
            "https://www.youtube.com/watch?v=\(video.id)",
            "-f", formatString,
            "-o", outputTemplate,
            "--no-playlist",
            "--no-progress",
            "--no-check-certificates",
            // **Player-client fallback chain + PoT bypass.** Two interrelated knobs:
            //
            // `player_client=…` — explicit list of YouTube player profiles to try, in fallback
            // order. The default yt-dlp list without a JS runtime is so narrow it commonly
            // hits "This video is not available" on kids / region-locked / age-gated videos.
            // We try clients with different PoT requirements:
            //   - `tv_simply` (TVHTML5 simply-embedded-player) — broadest format coverage.
            //   - `tv_embedded` — TV embedded player, often exempt from PoT enforcement.
            //   - `web_creator` — creator-mode profile, also frequently PoT-exempt.
            //   - `mweb` — mobile web, broad coverage including kids content.
            //   - `web_safari` — desktop Safari, useful for live + premium content.
            //   - `ios` — native iOS app profile.
            //   - `android_vr` — last-resort fallback (was the only default).
            //
            // `formats=missing_pot` — **critical**. As of late-2024 yt-dlp builds, formats that
            // YouTube has marked as requiring a Proof-of-Origin token are *filtered out by
            // default* on the assumption they'll return HTTP 403. With every format filtered,
            // yt-dlp falls through to "no usable formats" → `"This video is not available"`.
            // Setting `formats=missing_pot` tells yt-dlp "keep those formats anyway — I'll try."
            // In practice many still play because YouTube doesn't enforce PoT on every CDN
            // edge; the ones that do 403 fall through to the next client. Without this flag we
            // had `"...formats require a GVS PO Token which was not provided. They will be
            // skipped..."` in the log for every client we tried, leaving zero usable formats.
            "--extractor-args",
            "youtube:player_client=tv_simply,tv_embedded,web_creator,mweb,web_safari,ios,android_vr;formats=missing_pot",
            // **Concurrent fragment downloads.** For HLS/DASH streams yt-dlp downloads each
            // chunk sequentially by default — bumping this lets it fetch N fragments at once
            // over the same HTTP/2 connection. Doesn't change the total bytes pulled but cuts
            // wall-clock time, and is the closest thing to "parallel downloads" we can do
            // (Python/CPython requires single-thread interpreter access, so we can't run two
            // yt-dlp invocations side-by-side).
            //
            // Value is user-controlled via `UserPreferences.concurrentFragments`. We clamp here
            // as a defence-in-depth — `@AppStorage` can technically be poked to any Int.
            "--concurrent-fragments", "\(max(1, min(16, preferences.concurrentFragments)))",
            // Belt-and-braces: point yt-dlp at a nonexistent ffmpeg so even if some edge case tries
            // to add the merger postprocessor, it fails-fast at probe time and yt-dlp skips it
            // instead of hanging in `Popen.communicate`. Our Swift-side AVAssetExportSession mux is
            // the canonical join step now.
            "--ffmpeg-location", "/dev/null/no-ffmpeg"
        ]

        log.info("yt-dlp[\(video.id, privacy: .public)] argv=\(argv.joined(separator: " "), privacy: .public)")
        log.debug("yt-dlp[\(video.id, privacy: .public)] → state=downloading(0)")
        publish(snapshot: DownloadTaskSnapshot(
            id: snapshotID,
            videoID: video.id,
            title: video.title,
            state: .downloading(progress: 0),
            createdAt: .now
        ))

        do {
            log.info("yt-dlp[\(video.id, privacy: .public)] invoking yt_dlp() — first launch triggers Python module download (serialized on dedicated thread via PythonRunner)")
            try await PythonRunner.shared.run(argv: argv, progress: { [weak self] dict in
                guard let self else { return }
                // CRITICAL: PythonKit's `PythonObject` is reference-counted on Python's GIL thread.
                // If we capture the `[String: PythonObject]` dict into a `Task { @MainActor in ... }`
                // closure, the objects get released on a *different* thread when the task ends, and
                // PyReference.deinit crashes inside `_PyInterpreterState_GET`. So we must extract
                // every value we care about into Swift-native primitives RIGHT HERE on the calling
                // thread, then ship only those primitives across the actor boundary.
                let status = String(dict["status"] ?? "") ?? ""
                let downloaded = Int(dict["downloaded_bytes"] ?? 0) ?? 0
                let total = Int(dict["total_bytes"] ?? dict["total_bytes_estimate"] ?? 0) ?? 0
                let speed = Int(dict["speed"] ?? 0) ?? 0
                let eta = Int(dict["eta"] ?? 0) ?? 0
                // `filename` tells us which stream this hook is for: <id>.<itag>.mp4 vs <id>.<itag>.m4a.
                let filename = String(dict["filename"] ?? "") ?? ""
                let phase: String
                let lower = filename.lowercased()
                if lower.hasSuffix(".m4a") || lower.hasSuffix(".webm") && lower.contains("audio") {
                    phase = "audio"
                } else if lower.hasSuffix(".mp4") || lower.hasSuffix(".webm") {
                    phase = "video"
                } else {
                    phase = "stream"
                }
                Task { @MainActor [snapshotID, videoID = video.id, videoTitle = video.title] in
                    self.handleProgress(
                        status: status,
                        downloaded: downloaded,
                        total: total,
                        speed: speed,
                        eta: eta,
                        phase: phase,
                        snapshotID: snapshotID,
                        videoID: videoID,
                        videoTitle: videoTitle
                    )
                }
            }, log: { [weak self, log] level, message in
                // Bridge yt-dlp's Python logger to os_log so its diagnostics show up alongside ours.
                // Levels we get: debug / info / warning / error.
                if level == "error" {
                    log.error("yt-dlp: \(message, privacy: .public)")
                } else if level == "warning" {
                    log.notice("yt-dlp: \(message, privacy: .public)")
                } else {
                    log.info("yt-dlp: \(message, privacy: .public)")
                }
                // The "[Merger]" line is yt-dlp's last visible step before it hands off to ffmpeg.
                // ffmpeg runs CPU-bound on the device for 10–60s and emits no progress, so we flip
                // the progress overlay to a spinner ("Processing…") instead of leaving it at 100%.
                if message.contains("[Merger]") || message.contains("[ExtractAudio]") || message.contains("Fixup") {
                    let id = video.id
                    Task { @MainActor in
                        self?.progressByVideoID.removeValue(forKey: id)
                    }
                }
            }, priority: priority == .userInitiated ? .high : .low)
        } catch {
            log.error("yt-dlp[\(video.id, privacy: .public)] threw: \(String(describing: error), privacy: .public)")
            // **Don't fail yet** — try the YouTubeKit / TVHTML5_SIMPLY_EMBEDDED_PLAYER fallback
            // before giving up. yt-dlp's no-JS-runtime path can produce "This video is not
            // available" for entire classes of videos (kids content, PoT-gated music videos,
            // some live recordings) where YouTubeKit's tvHtmlModel still returns playable URLs
            // because that client profile is exempt from PoT enforcement on the video-info side.
            do {
                try await runYouTubeKitFallback(video: video, quality: quality, destination: destination, snapshotID: snapshotID)
                let dur = Date().timeIntervalSince(startedAt)
                log.info("yt-dlp[\(video.id, privacy: .public)] FALLBACK SUCCESS in \(String(format: "%.1f", dur), privacy: .public)s")
                await persistDownloaded(video: video, fileURL: destination)
                publish(snapshot: DownloadTaskSnapshot(
                    id: snapshotID, videoID: video.id, title: video.title,
                    state: .completed(destination), createdAt: .now
                ))
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    self.tasks[snapshotID] = nil
                    self.publishSnapshots()
                }
                return destination
            } catch {
                log.error("yt-dlp[\(video.id, privacy: .public)] YouTubeKit fallback also failed: \(String(describing: error), privacy: .public)")
                publish(snapshot: DownloadTaskSnapshot(
                    id: snapshotID,
                    videoID: video.id,
                    title: video.title,
                    state: .failed(error.localizedDescription),
                    createdAt: .now
                ))
                throw YouTubeServiceError.streamExtractionFailed
            }
        }

        let elapsed = Date().timeIntervalSince(startedAt)
        log.info("yt-dlp[\(video.id, privacy: .public)] returned after \(String(format: "%.1f", elapsed), privacy: .public)s — locating output files")

        // yt-dlp wrote individual streams to <id>.<format_id>.<ext> (e.g. wh4YepmEtZk.135.mp4 +
        // wh4YepmEtZk.140.m4a). Run the candidate scan off-main since `contentsOfDirectory` on a
        // Downloads folder with hundreds of files becomes a noticeable hitch.
        let intermediates: [URL] = await Task.detached(priority: .utility) {
            let candidates = (try? FileManager.default.contentsOfDirectory(at: downloadsDir, includingPropertiesForKeys: nil))?
                .filter { $0.lastPathComponent.hasPrefix("\(stem).") } ?? []
            // Don't include the canonical destination itself in mux inputs.
            return candidates.filter { $0.path != destination.path }
        }.value
        log.debug("yt-dlp[\(video.id, privacy: .public)] candidate files: \(intermediates.map(\.lastPathComponent).joined(separator: ", "), privacy: .public)")

        let videoFile = intermediates.first { url in
            ["mp4", "webm", "mkv"].contains(url.pathExtension.lowercased()) &&
            !url.lastPathComponent.contains(".\(stem).m4a") &&
            url.pathExtension.lowercased() != "m4a"
        }
        let audioFile = intermediates.first { ["m4a", "mp3", "aac", "opus"].contains($0.pathExtension.lowercased()) }

        if let videoFile, let audioFile {
            log.info("yt-dlp[\(video.id, privacy: .public)] muxing video=\(videoFile.lastPathComponent, privacy: .public) audio=\(audioFile.lastPathComponent, privacy: .public)")
            do {
                try await muxToDestination(video: videoFile, audio: audioFile, destination: destination)
            } catch {
                log.error("yt-dlp[\(video.id, privacy: .public)] Swift-side mux failed: \(String(describing: error), privacy: .public)")
                publish(snapshot: DownloadTaskSnapshot(
                    id: snapshotID,
                    videoID: video.id,
                    title: video.title,
                    state: .failed("Could not combine video + audio"),
                    createdAt: .now
                ))
                throw YouTubeServiceError.streamExtractionFailed
            }
            // Clean up the per-stream intermediates off-main — `removeItem` for each one is sync,
            // and with N parallel downloads finishing back-to-back this can add up.
            let toRemove = intermediates
            await Task.detached(priority: .utility) {
                for url in toRemove {
                    try? FileManager.default.removeItem(at: url)
                }
            }.value
        } else if let single = intermediates.first {
            // Single combined progressive file — just rename it to the destination.
            log.info("yt-dlp[\(video.id, privacy: .public)] single-file mode (no mux needed): \(single.lastPathComponent, privacy: .public)")
            try? FileManager.default.removeItem(at: destination)
            do {
                try FileManager.default.moveItem(at: single, to: destination)
            } catch {
                log.error("yt-dlp[\(video.id, privacy: .public)] could not move \(single.path, privacy: .public) → destination: \(String(describing: error), privacy: .public)")
                throw YouTubeServiceError.streamExtractionFailed
            }
        }

        if !FileManager.default.fileExists(atPath: destination.path) {
            log.notice("yt-dlp[\(video.id, privacy: .public)] post-mux: destination still missing — falling back to YouTubeKit/TVHTML5")
            // Mirror the catch-branch fallback for the "yt-dlp returned without writing"
            // case. Same TVHTML5_SIMPLY_EMBEDDED_PLAYER path — bypasses PoT for video-info,
            // then downloads via plain URLSession.
            do {
                try await runYouTubeKitFallback(video: video, quality: quality, destination: destination, snapshotID: snapshotID)
            } catch {
                log.error("yt-dlp[\(video.id, privacy: .public)] YouTubeKit fallback also failed: \(String(describing: error), privacy: .public)")
                publish(snapshot: DownloadTaskSnapshot(
                    id: snapshotID,
                    videoID: video.id,
                    title: video.title,
                    state: .failed("Download finished but file not found"),
                    createdAt: .now
                ))
                throw YouTubeServiceError.streamExtractionFailed
            }
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
        log.info("yt-dlp[\(video.id, privacy: .public)] file on disk: size=\(fileSize, privacy: .public) bytes path=\(destination.path, privacy: .public)")

        log.debug("yt-dlp[\(video.id, privacy: .public)] writing download metadata xattr")
        await persistDownloaded(video: video, fileURL: destination)

        log.debug("yt-dlp[\(video.id, privacy: .public)] → state=completed")
        publish(snapshot: DownloadTaskSnapshot(
            id: snapshotID,
            videoID: video.id,
            title: video.title,
            state: .completed(destination),
            createdAt: .now
        ))
        // Drop the completed entry from `tasks` after a moment so the in-progress section clears.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self.tasks[snapshotID] = nil
            self.publishSnapshots()
        }

        log.info("yt-dlp[\(video.id, privacy: .public)] SUCCESS in \(String(format: "%.1f", elapsed), privacy: .public)s → \(destination.path, privacy: .public)")
        return destination
    }

    /// Renders a yt-dlp progress event into a snapshot and a log line. Takes Swift primitives —
    /// PythonObject extraction happens upstream on Python's GIL thread, see the progress closure in
    /// `runYoutubeDLDownload`.
    private func handleProgress(
        status: String,
        downloaded: Int,
        total: Int,
        speed: Int,
        eta: Int,
        phase: String,
        snapshotID: String,
        videoID: String,
        videoTitle: String
    ) {
        let progress = total > 0 ? max(0, min(1, Double(downloaded) / Double(total))) : 0

        if status == "downloading" {
            // Throttle: skip if this video's last publish was within the min-interval window. The
            // next callback that arrives outside the window will pick up the latest progress
            // value, so the UI stays accurate, just less twitchy.
            let now = ContinuousClock.now
            if let last = lastProgressPublishedAt[videoID], (now - last) < progressPublishMinInterval {
                return
            }
            lastProgressPublishedAt[videoID] = now

            log.debug("yt-dlp[\(videoID, privacy: .public)] \(phase, privacy: .public) progress: \(String(format: "%.1f", progress * 100), privacy: .public)% (\(downloaded, privacy: .public)/\(total, privacy: .public) B) speed=\(speed, privacy: .public) B/s eta=\(eta, privacy: .public)s")
            // Avoid an Observable write when the phase didn't actually change. SwiftUI's
            // `@Observable` macro fires on every assignment, even to the same value.
            if phaseByVideoID[videoID] != phase {
                phaseByVideoID[videoID] = phase
            }
            publish(snapshot: DownloadTaskSnapshot(
                id: snapshotID,
                videoID: videoID,
                title: videoTitle,
                state: .downloading(progress: progress),
                createdAt: .now
            ))
        } else if status == "finished" {
            log.info("yt-dlp[\(videoID, privacy: .public)] \(phase, privacy: .public) finished — moving to next phase")
            // Clear known progress so the UI overlay flips from "Downloading 100%" to a spinner.
            progressByVideoID.removeValue(forKey: videoID)
            // Reset throttle so the next phase (audio after video, or mux) gets its first event
            // through immediately rather than waiting out the window from the previous phase.
            lastProgressPublishedAt.removeValue(forKey: videoID)
            // Note: don't clear phase here — keep showing the last label until the next downloading
            // event sets it.
        } else if status == "error" {
            log.error("yt-dlp[\(videoID, privacy: .public)] progress hook reports error")
            lastProgressPublishedAt.removeValue(forKey: videoID)
        } else {
            log.debug("yt-dlp[\(videoID, privacy: .public)] progress hook status=\(status, privacy: .public)")
        }
    }

    // MARK: - SwiftData

    private func persistDownloaded(video: Video, fileURL: URL) async {
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        let thumb = await downloadThumbnailData(url: video.thumbnailURL)
        log.debug("persistDownloaded(\(video.id, privacy: .public)) thumb=\(thumb == nil ? "nil" : "\(thumb!.count)B", privacy: .public) size=\(size, privacy: .public)")
        // File-system + xattr backed (no SwiftData): the metadata travels with the file.
        // `DownloadsStore.write` compresses the thumbnail to ~10 KB JPEG and posts the
        // change notification so the Downloads tab re-renders.
        DownloadsStore.shared.write(
            videoID: video.id,
            title: video.title,
            channelName: video.channelName,
            formatID: "ytdl",
            originalURL: nil,
            rawThumbnail: thumb,
            at: fileURL
        )
        log.info("persistDownloaded(\(video.id, privacy: .public)) wrote xattr size=\(size, privacy: .public) bytes")
        enforceCacheLimit()
    }

    /// Runs the LRU eviction sweep against the user's current cache-size preference. The newest
    /// download is preserved (the one we just persisted), so this never sabotages the playback
    /// request that triggered it. Now driven by `DownloadsStore` over the filesystem.
    private func enforceCacheLimit() {
        let limit = UserPreferences().downloadCacheLimit.bytes
        DownloadsStore.shared.enforceCacheLimit(limit)
    }

    private func downloadThumbnailData(url: URL?) async -> Data? {
        guard let url else { return nil }
        return try? await URLSession.shared.data(from: url).0
    }

    // MARK: - YouTubeKit / TVHTML5 fallback

    /// Last-resort path that runs when yt-dlp fails to produce a usable file. Uses
    /// `VideoService.fetchInfoViaTVHTML5` (which goes through `YouTubeKitClient.tvHtmlModel`
    /// — TVHTML5_SIMPLY_EMBEDDED_PLAYER context, the client profile YouTube exempts from PoT
    /// enforcement) to get fresh stream URLs, then downloads the bytes directly via
    /// `URLSession`. If only adaptive (video-only + audio-only) streams are available, the
    /// two pieces are muxed back into a single `.mp4` via the same `FFmpegRunner` we use for
    /// yt-dlp output.
    ///
    /// Why this works when yt-dlp doesn't: yt-dlp's defensive filter strips formats marked as
    /// requiring a Proof-of-Origin token before download even starts. The TVHTML5 client
    /// returns URLs that aren't tagged with that requirement, so YouTubeKit happily hands them
    /// to us and URLSession fetches them like any other HTTPS resource.
    private func runYouTubeKitFallback(video: Video, quality: VideoQuality, destination: URL, snapshotID: String) async throws {
        log.info("yt-dlp[\(video.id, privacy: .public)] fallback: fetching stream info via YouTubeKit")
        publish(snapshot: DownloadTaskSnapshot(
            id: snapshotID, videoID: video.id, title: video.title,
            state: .downloading(progress: 0), createdAt: .now
        ))
        phaseByVideoID[video.id] = "stream"

        let formats = await fetchFallbackFormats(videoID: video.id)
        log.info("yt-dlp[\(video.id, privacy: .public)] fallback: \(formats.count, privacy: .public) usable formats")
        guard !formats.isEmpty else {
            throw YouTubeServiceError.streamExtractionFailed
        }
        let maxHeight = Self.targetHeight(for: quality)

        try? FileManager.default.removeItem(at: destination)

        // **Strategy 1: progressive single-file format.** itag 18 (360p mp4 with both tracks)
        // ships as a single file, no mux step. Always tried first because it's the simplest
        // and fastest path when available.
        if let progressive = pickBestProgressive(formats: formats, maxHeight: maxHeight),
           let url = progressive.url {
            log.info("yt-dlp[\(video.id, privacy: .public)] fallback: progressive height=\(progressive.height ?? 0, privacy: .public)")
            try await downloadStream(from: url, to: destination, videoID: video.id, snapshotID: snapshotID, title: video.title)
            return
        }

        // **Strategy 2: adaptive — separate video-only and audio-only streams.** Required for
        // anything ≥ 720p (YouTube doesn't ship progressive at those resolutions). Download
        // both, then mux with ffmpeg `-c copy` so we get a single playable mp4.
        let videoFormat = pickBestVideoOnly(formats: formats, maxHeight: maxHeight)
        let audioFormat = pickBestAudioOnly(formats: formats)
        guard let videoFormat, let videoURL = videoFormat.url,
              let audioFormat, let audioURL = audioFormat.url else {
            log.error("yt-dlp[\(video.id, privacy: .public)] fallback: no suitable formats found")
            throw YouTubeServiceError.streamExtractionFailed
        }

        let downloadsDir = destination.deletingLastPathComponent()
        let stem = destination.deletingPathExtension().lastPathComponent
        let videoFile = downloadsDir.appendingPathComponent("\(stem).fallback.video.mp4")
        let audioFile = downloadsDir.appendingPathComponent("\(stem).fallback.audio.m4a")
        defer {
            try? FileManager.default.removeItem(at: videoFile)
            try? FileManager.default.removeItem(at: audioFile)
        }

        log.info("yt-dlp[\(video.id, privacy: .public)] fallback: adaptive video height=\(videoFormat.height ?? 0, privacy: .public)")
        phaseByVideoID[video.id] = "video"
        try await downloadStream(from: videoURL, to: videoFile, videoID: video.id, snapshotID: snapshotID, title: video.title)
        phaseByVideoID[video.id] = "audio"
        try await downloadStream(from: audioURL, to: audioFile, videoID: video.id, snapshotID: snapshotID, title: video.title)
        phaseByVideoID[video.id] = "muxing"
        progressByVideoID.removeValue(forKey: video.id)

        try await muxToDestination(video: videoFile, audio: audioFile, destination: destination)
    }

    /// Two-tier format fetch for the fallback path.
    ///
    /// 1. **`fetchInfoViaTVHTML5`** — uses `YouTubeKitClient.tvHtmlModel` (TVHTML5_SIMPLY_
    ///    EMBEDDED_PLAYER context). PoT-exempt on the video-info side. Cheap: one HTTP call, no
    ///    player-JS scrape. Caveat: the response carries `signatureCipher`-protected URLs for
    ///    some videos and YouTubeKit drops those (no JS runtime to decode them on iOS), so on
    ///    cipher-heavy content we get back zero formats.
    ///
    /// 2. **`fetchInfoWithFormats`** — uses `VideoInfosWithDownloadFormatsResponse`, which
    ///    additionally scrapes the YouTube player.js and decodes signature ciphers natively
    ///    in YouTubeKit. Slower (two HTTP calls + JS parsing) but produces direct URLs even
    ///    for cipher-protected formats. Falls through to this tier when TVHTML5 returned
    ///    nothing usable — exactly the case the Baby-Shark video hit.
    ///
    /// Either tier failing silently returns an empty array; the caller treats that as "no
    /// fallback path available" and surfaces `streamExtractionFailed`.
    private func fetchFallbackFormats(videoID: String) async -> [VideoFormat] {
        let service = VideoService()
        do {
            let info = try await service.fetchInfoViaTVHTML5(id: videoID)
            let usable = info.formats.filter { $0.url != nil }
            if !usable.isEmpty {
                log.info("[fallback] TVHTML5 returned \(info.formats.count, privacy: .public) formats, \(usable.count, privacy: .public) with URLs")
                return usable
            }
            log.notice("[fallback] TVHTML5 returned \(info.formats.count, privacy: .public) formats but 0 with direct URLs (cipher-protected); trying player.js scrape")
        } catch {
            log.notice("[fallback] TVHTML5 fetch failed: \(String(describing: error), privacy: .public); trying player.js scrape")
        }
        do {
            let result = try await service.fetchInfoWithFormats(id: videoID)
            let usable = result.formats.filter { $0.url != nil }
            log.info("[fallback] fetchInfoWithFormats returned \(result.formats.count, privacy: .public) formats, \(usable.count, privacy: .public) with URLs")
            return usable
        } catch {
            log.error("[fallback] fetchInfoWithFormats failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Downloads a single stream to `destination` with periodic progress updates fed into
    /// `handleProgress` so the UI's progress bar moves.
    private func downloadStream(from url: URL, to destination: URL, videoID: String, snapshotID: String, title: String) async throws {
        try? FileManager.default.removeItem(at: destination)
        var request = URLRequest(url: url)
        // Match the TVHTML5_SIMPLY_EMBEDDED_PLAYER user-agent we set on `tvHtmlModel`.
        // The CDN occasionally rejects requests whose UA doesn't match the client that minted
        // the URL.
        request.setValue("Mozilla/5.0 (PlayStation; PlayStation 4/12.55) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Safari/605.1.15", forHTTPHeaderField: "User-Agent")

        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw YouTubeServiceError.streamExtractionFailed
        }
        guard (200..<300).contains(http.statusCode) else {
            log.error("[fallback] HTTP \(http.statusCode, privacy: .public) from \(url.host ?? "?", privacy: .public)\(url.path, privacy: .public)")
            throw YouTubeServiceError.streamExtractionFailed
        }
        let expected = http.expectedContentLength
        let total = expected > 0 ? Int(expected) : 0

        // Write the streamed bytes to disk in 64 KB chunks so we don't buffer the entire
        // video in memory. Emit progress on every chunk; `handleProgress` itself throttles
        // the UI publish rate to ~5/sec.
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: destination) else {
            throw YouTubeServiceError.streamExtractionFailed
        }
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(65_536)
        var written = 0
        for try await byte in asyncBytes {
            buffer.append(byte)
            if buffer.count >= 65_536 {
                try handle.write(contentsOf: buffer)
                written += buffer.count
                buffer.removeAll(keepingCapacity: true)
                handleProgress(
                    status: "downloading",
                    downloaded: written,
                    total: total,
                    speed: 0,
                    eta: 0,
                    phase: phaseByVideoID[videoID] ?? "stream",
                    snapshotID: snapshotID,
                    videoID: videoID,
                    videoTitle: title
                )
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += buffer.count
        }
        try handle.close()
        log.info("[fallback] wrote \(written, privacy: .public) bytes to \(destination.lastPathComponent, privacy: .public)")
    }

    /// Picks the highest-resolution progressive (single-file, both-tracks) format whose height
    /// is within the user's quality cap. nil if YouTube didn't return any combined stream.
    private func pickBestProgressive(formats: [VideoFormat], maxHeight: Int) -> VideoFormat? {
        formats
            .filter { $0.containsBothTracks && $0.url != nil }
            .filter { ($0.height ?? Int.max) <= maxHeight }
            .max { ($0.height ?? 0) < ($1.height ?? 0) }
    }

    /// Highest-resolution video-only mp4 within the cap. Prefer mp4 over webm so the downstream
    /// `ffmpeg -c copy` mux works without re-encoding.
    private func pickBestVideoOnly(formats: [VideoFormat], maxHeight: Int) -> VideoFormat? {
        let candidates = formats.filter { $0.isVideoOnly && $0.url != nil && ($0.height ?? Int.max) <= maxHeight }
        let mp4s = candidates.filter { $0.mimeType.lowercased().contains("mp4") }
        let pool = mp4s.isEmpty ? candidates : mp4s
        return pool.max { ($0.height ?? 0) < ($1.height ?? 0) }
    }

    /// Highest-bitrate audio-only m4a/mp4. Same mp4-preference rule as video to keep the mux
    /// in `-c copy` territory.
    private func pickBestAudioOnly(formats: [VideoFormat]) -> VideoFormat? {
        let candidates = formats.filter { $0.isAudioOnly && $0.url != nil }
        let mp4s = candidates.filter { $0.mimeType.lowercased().contains("mp4") || $0.mimeType.lowercased().contains("m4a") }
        let pool = mp4s.isEmpty ? candidates : mp4s
        return pool.max { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }
    }

    private static func targetHeight(for quality: VideoQuality) -> Int {
        // Reuse the existing `heightCap` so the format selector matches yt-dlp's argv logic.
        // `audioOnly` → 0 isn't useful for video downloads, fall back to a reasonable cap.
        let cap = quality.heightCap ?? 1080
        return cap > 0 ? cap : 1080
    }

    // MARK: - Muxing (direct ffmpeg call, no Python)

    /// Combines a video-only mp4 with an audio-only m4a into a single mp4 using `ffmpeg -c copy`.
    ///
    /// **Why ffmpeg:** yt-dlp delivers YouTube's DASH-fragmented mp4. AVFoundation parses these
    /// containers with halved frame rate (per-frame PTS values in the fragmented mp4 read as 2× the
    /// real values), so any AVAssetExportSession/AVAssetReader-based mux produces a doubled-duration
    /// output. `ffmpeg -c copy` is the canonical fixup — it rewrites the moov atom into a regular
    /// (non-fragmented) mp4 with correct timestamps without re-encoding.
    ///
    /// **Why not via yt-dlp's Popen:** the previous hang we hit was Python's `Popen.communicate`
    /// never returning after ffmpeg's `longjmp` tore through the Python interpreter's stack. Calling
    /// `FFmpegSupport.ffmpeg(_:)` *directly* from Swift sidesteps Python entirely — the longjmp
    /// lands at the C `setjmp` inside the library and control returns to Swift cleanly.
    private func muxToDestination(video: URL, audio: URL, destination: URL) async throws {
        log.info("mux via ffmpeg: video=\(video.lastPathComponent, privacy: .public) audio=\(audio.lastPathComponent, privacy: .public)")
        try? FileManager.default.removeItem(at: destination)

        let args: [String] = [
            "ffmpeg",
            "-y",
            "-hide_banner",
            "-loglevel", "warning",
            "-i", video.path,
            "-i", audio.path,
            "-c", "copy",
            "-map", "0:v:0",
            "-map", "1:a:0",
            "-movflags", "+faststart",
            destination.path
        ]
        log.info("ffmpeg argv: \(args.joined(separator: " "), privacy: .public)")

        let startedAt = Date()
        // Route every ffmpeg invocation through the shared `FFmpegRunner` actor. ffmpeg's C
        // library is **not** thread-safe — the `+faststart` post-pass crashes on concurrent
        // calls (see FFmpegRunner doc comment). Plain `Task.detached` here was the bug: each
        // parallel playlist download finishing its yt-dlp step fired its own ffmpeg detach,
        // and two of them stomping global buffers blew up inside `ff_format_shift_data`.
        let exitCode = await FFmpegRunner.shared.run(args)
        let elapsed = Date().timeIntervalSince(startedAt)
        log.info("ffmpeg returned exit=\(exitCode, privacy: .public) in \(String(format: "%.1f", elapsed), privacy: .public)s")

        guard exitCode == 0 else {
            log.error("ffmpeg failed exit=\(exitCode, privacy: .public)")
            throw YouTubeServiceError.streamExtractionFailed
        }
        guard FileManager.default.fileExists(atPath: destination.path) else {
            log.error("ffmpeg returned 0 but output missing at \(destination.path, privacy: .public)")
            throw YouTubeServiceError.streamExtractionFailed
        }

        // Sanity-log the final duration so any future regression is obvious in os_log.
        let asset = AVURLAsset(url: destination)
        if let dur = try? await asset.load(.duration) {
            log.info("ffmpeg-muxed file duration=\(dur.seconds, privacy: .public)s path=\(destination.lastPathComponent, privacy: .public)")
        }
    }

    /// Legacy AVAssetExportSession path — kept private and unused for now. It can't handle YouTube's
    /// DASH-fragmented mp4 correctly (see `muxToDestination` for the gory details).
    @available(*, deprecated)
    private func muxViaAVFoundation(video: URL, audio: URL, destination: URL) async throws {
        log.info("mux: video=\(video.lastPathComponent, privacy: .public) audio=\(audio.lastPathComponent, privacy: .public)")
        let videoAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: audio)

        async let videoTracksTask = videoAsset.loadTracks(withMediaType: .video)
        async let audioTracksTask = audioAsset.loadTracks(withMediaType: .audio)
        async let videoDurationTask = videoAsset.load(.duration)
        async let audioDurationTask = audioAsset.load(.duration)

        let (vTracks, aTracks, videoDur, audioDur) = try await (
            videoTracksTask, audioTracksTask, videoDurationTask, audioDurationTask
        )

        guard let videoTrack = vTracks.first else {
            log.error("mux: no video track in \(video.lastPathComponent, privacy: .public)")
            throw YouTubeServiceError.streamExtractionFailed
        }
        guard let audioTrack = aTracks.first else {
            log.error("mux: no audio track in \(audio.lastPathComponent, privacy: .public)")
            throw YouTubeServiceError.streamExtractionFailed
        }

        let videoTrackRange = try await videoTrack.load(.timeRange)
        let audioTrackRange = try await audioTrack.load(.timeRange)
        let videoSegments = try await videoTrack.load(.segments)
        let audioSegments = try await audioTrack.load(.segments)

        log.info("mux: asset durations video=\(videoDur.seconds, privacy: .public)s audio=\(audioDur.seconds, privacy: .public)s")
        log.info("mux: track ranges video=[start=\(videoTrackRange.start.seconds, privacy: .public), dur=\(videoTrackRange.duration.seconds, privacy: .public)] audio=[start=\(audioTrackRange.start.seconds, privacy: .public), dur=\(audioTrackRange.duration.seconds, privacy: .public)]")
        log.info("mux: segments video=\(videoSegments.count, privacy: .public) audio=\(audioSegments.count, privacy: .public)")
        for (i, seg) in videoSegments.enumerated() {
            log.info("mux:   video.seg[\(i, privacy: .public)] empty=\(seg.isEmpty, privacy: .public) src=[\(seg.timeMapping.source.start.seconds, privacy: .public), dur=\(seg.timeMapping.source.duration.seconds, privacy: .public)] tgt=[\(seg.timeMapping.target.start.seconds, privacy: .public), dur=\(seg.timeMapping.target.duration.seconds, privacy: .public)]")
        }
        for (i, seg) in audioSegments.enumerated() {
            log.info("mux:   audio.seg[\(i, privacy: .public)] empty=\(seg.isEmpty, privacy: .public) src=[\(seg.timeMapping.source.start.seconds, privacy: .public), dur=\(seg.timeMapping.source.duration.seconds, privacy: .public)] tgt=[\(seg.timeMapping.target.start.seconds, privacy: .public), dur=\(seg.timeMapping.target.duration.seconds, privacy: .public)]")
        }

        // The track's *real* media content range is the first non-empty segment's source range.
        // Edit lists can stack multiple identical segments to produce a presentation that plays the
        // same bytes twice; we ignore that and only insert the underlying media data once.
        let firstVideoSegment = videoSegments.first(where: { !$0.isEmpty }).map { $0.timeMapping.source }
        let firstAudioSegment = audioSegments.first(where: { !$0.isEmpty }).map { $0.timeMapping.source }
        let videoMediaRange = firstVideoSegment ?? CMTimeRange(start: .zero, duration: videoDur)
        let audioMediaRange = firstAudioSegment ?? CMTimeRange(start: .zero, duration: audioDur)
        log.info("mux: chosen video media range=[start=\(videoMediaRange.start.seconds, privacy: .public), dur=\(videoMediaRange.duration.seconds, privacy: .public)]")
        log.info("mux: chosen audio media range=[start=\(audioMediaRange.start.seconds, privacy: .public), dur=\(audioMediaRange.duration.seconds, privacy: .public)]")

        let cap = CMTimeMinimum(videoDur, audioDur)
        let mergedDuration = CMTimeMinimum(
            CMTimeMinimum(videoMediaRange.duration, audioMediaRange.duration),
            cap
        )
        log.info("mux: merged target duration=\(mergedDuration.seconds, privacy: .public)s (cap=\(cap.seconds, privacy: .public)s)")

        let composition = AVMutableComposition()
        guard let compVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let compAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            log.error("mux: failed to create composition tracks")
            throw YouTubeServiceError.streamExtractionFailed
        }

        // Read from each segment's media-domain start (which AVFoundation uses to look up samples in
        // the underlying mdat) and clamp to the merged duration so neither track plays past where
        // both have content. Both inserts target composition timeline `.zero` — overlay, not concat.
        let videoInsertRange = CMTimeRange(start: videoMediaRange.start, duration: mergedDuration)
        let audioInsertRange = CMTimeRange(start: audioMediaRange.start, duration: mergedDuration)
        log.info("mux: inserting video range=[\(videoInsertRange.start.seconds, privacy: .public), dur=\(videoInsertRange.duration.seconds, privacy: .public)] audio range=[\(audioInsertRange.start.seconds, privacy: .public), dur=\(audioInsertRange.duration.seconds, privacy: .public)]")
        try compVideo.insertTimeRange(videoInsertRange, of: videoTrack, at: .zero)
        try compAudio.insertTimeRange(audioInsertRange, of: audioTrack, at: .zero)

        log.info("mux: composition built. duration=\(composition.duration.seconds, privacy: .public)s tracks=\(composition.tracks.count, privacy: .public)")
        for (i, track) in composition.tracks.enumerated() {
            log.info("mux:  comp.tracks[\(i, privacy: .public)] mediaType=\(track.mediaType.rawValue, privacy: .public) segments=\(track.segments.count, privacy: .public) timeRange=[start=\(track.timeRange.start.seconds, privacy: .public), dur=\(track.timeRange.duration.seconds, privacy: .public)]")
        }

        // Diagnostic — if the composition is somehow longer than the media-duration cap, the rest of
        // the file would be garbage on playback. Bail rather than ship a broken mp4.
        if composition.duration > CMTimeMultiplyByFloat64(cap, multiplier: 1.05) {
            log.error("mux: composition duration \(composition.duration.seconds, privacy: .public)s exceeds 105%% of media cap \(cap.seconds, privacy: .public)s — refusing to export this would be doubled")
            throw YouTubeServiceError.streamExtractionFailed
        }

        try? FileManager.default.removeItem(at: destination)

        // Passthrough first; only re-encode if passthrough refuses the codec combo.
        if try await runExport(composition: composition, preset: AVAssetExportPresetPassthrough, destination: destination) {
            await logExportedDuration(destination)
            log.info("mux: passthrough export succeeded → \(destination.path, privacy: .public)")
            return
        }
        log.notice("mux: passthrough rejected the codec combo, re-encoding via HighestQuality preset")
        if try await runExport(composition: composition, preset: AVAssetExportPresetHighestQuality, destination: destination) {
            await logExportedDuration(destination)
            log.info("mux: re-encode succeeded → \(destination.path, privacy: .public)")
            return
        }
        throw YouTubeServiceError.streamExtractionFailed
    }

    /// Loads the duration of the exported file and logs it. Helps confirm the mux produced a file
    /// of the expected length — if you ever see "doubled" again, this line catches it.
    private func logExportedDuration(_ url: URL) async {
        let asset = AVURLAsset(url: url)
        if let duration = try? await asset.load(.duration) {
            log.info("mux: exported file duration=\(duration.seconds, privacy: .public)s path=\(url.lastPathComponent, privacy: .public)")
        }
    }

    /// Runs one `AVAssetExportSession` invocation against `composition` with `preset` and writes to
    /// `destination`. Returns true on .completed, false on .cancelled, throws on .failed.
    private func runExport(composition: AVMutableComposition, preset: String, destination: URL) async throws -> Bool {
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            log.error("mux: could not init AVAssetExportSession for preset=\(preset, privacy: .public)")
            return false
        }
        session.outputURL = destination
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true

        log.debug("mux: export start preset=\(preset, privacy: .public)")
        await session.export()

        switch session.status {
        case .completed:
            return true
        case .failed:
            let err = session.error?.localizedDescription ?? "unknown"
            log.error("mux: export failed preset=\(preset, privacy: .public) error=\(err, privacy: .public)")
            return false
        case .cancelled:
            log.notice("mux: export cancelled preset=\(preset, privacy: .public)")
            return false
        default:
            log.error("mux: export ended in unexpected state \(session.status.rawValue, privacy: .public)")
            return false
        }
    }

    // MARK: - File locations + format selection

    /// Canonical on-disk location for a downloaded video. Files land at the **Documents
    /// root** so they're visible in the system Files app under "On My iPhone" /
    /// "On My iPad" (gated by `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`
    /// in Info.plist). Every video gets a fixed `mp4` extension because yt-dlp's merger
    /// produces an mp4 container.
    static func fileURL(for videoID: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("\(videoID).mp4")
    }

    /// Builds a yt-dlp `-f` format string honoring the user's quality preference.
    ///
    /// **yt-dlp evaluates `/` left-to-right and picks the FIRST clause that matches.** So clause
    /// order matters a lot: we want it to prefer a single combined progressive file when one is
    /// available (skips the Swift-side ffmpeg mux entirely), and only fall back to the split
    /// `bestvideo,bestaudio` path when no combined file fits the cap.
    ///
    /// At 360p YouTube ships itag 18 (h264 + aac combined mp4) for nearly every video — so a 360p
    /// preference should always end up as a single-file download. Above 360p YouTube only delivers
    /// DASH-split streams, so the split clause kicks in and our ffmpeg mux joins them.
    ///
    /// Materializes a temporary Netscape-format `cookies.txt` from the user's stored YouTube
    /// cookie header, suitable for yt-dlp's `--cookies <path>` flag.
    ///
    /// **Currently unused.** Kept as a reference because the experiment that called it was
    /// instructive — and someone will probably try it again. Summary of why it's not wired up:
    ///
    /// On 2026-05-19 we briefly added `--cookies <tmpfile>` to the yt-dlp argv in
    /// `runYoutubeDLDownload` on the theory that authenticated requests would get more
    /// permissive PoT enforcement from YouTube and rescue currently-403ing videos. yt-dlp
    /// rejected this combination with the safety check `"Skipping client X since it does not
    /// support cookies"` and dropped three of our seven configured player clients —
    /// specifically `tv_simply`, `ios`, and `android_vr`, which are exactly the clients that
    /// give us the broadest format coverage on PoT-locked content. With cookies the surviving
    /// clients (`web_creator`, `mweb`) honestly reported `"No video formats found!"` for the
    /// same videos that without cookies returned 23+ formats (then 403'd at download). Net
    /// regression — we lost format extraction without gaining playable URLs.
    ///
    /// **The actual bottleneck is the n-cipher (CLAUDE.md §15.4), not auth.** Without a JS
    /// runtime to solve YouTube's n-challenge, every URL we extract is either 403'd at the CDN
    /// or stripped out before extraction. Cookies don't substitute for a PoT token.
    ///
    /// Returns `nil` when there's no stored header (anonymous user). The caller would be
    /// responsible for deleting the file (via `defer`) after the yt-dlp invocation returns;
    /// file lives in `FileManager.default.temporaryDirectory` with `chmod 0600`. Note that
    /// even brief disk presence is a CLAUDE.md §2.5 deviation.
    private static func makeTemporaryCookiesFile() -> URL? {
        guard let header = CookieStore.shared.loadHeader() else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("yt-dlp-cookies-\(UUID().uuidString).txt")
        var lines = [
            "# Netscape HTTP Cookie File",
            "# Generated by FreeTube; deleted on yt-dlp completion.",
        ]
        for pair in header.split(separator: ";") {
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[..<eq])
            let value = String(trimmed[trimmed.index(after: eq)...])
            // domain TAB includeSubdomain TAB path TAB secure TAB expires TAB name TAB value
            lines.append(".youtube.com\tTRUE\t/\tTRUE\t2147483647\t\(name)\t\(value)")
        }
        let content = lines.joined(separator: "\n") + "\n"
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        } catch {
            return nil
        }
    }

    /// We use `,` (download as separate files) instead of `+` (yt-dlp's merger) because yt-dlp's
    /// ffmpeg invocation hangs on iOS — see `muxToDestination` for the Swift-side replacement.
    private static func formatString(for quality: VideoQuality) -> String {
        if quality == .audioOnly {
            return "bestaudio[ext=m4a]/bestaudio"
        }
        if let cap = quality.heightCap, cap > 0 {
            return [
                // 1. Single combined progressive mp4 within the height cap (itag 18 for 360p).
                "best[height<=\(cap)][ext=mp4]",
                // 2. Same but any container (covers rare webm progressive).
                "best[height<=\(cap)]",
                // 3. Fall back to split DASH streams — our Swift-side mux joins them.
                "bestvideo[height<=\(cap)][ext=mp4],bestaudio[ext=m4a]",
                // 4. Whatever yt-dlp considers best as a last resort.
                "best"
            ].joined(separator: "/")
        }
        return "best[ext=mp4]/best/bestvideo[ext=mp4],bestaudio[ext=m4a]"
    }

    // MARK: - Networking gate + snapshots

    private func startMonitoringPath() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            Task { @MainActor in self.currentPath = path }
        }
        pathMonitor.start(queue: DispatchQueue(label: "DownloadManager.path"))
    }

    private func waitForAllowedNetwork() async throws {
        // Permissive default: if the user allows cellular, never block.
        if preferences.allowCellularDownloads { return }
        let path = currentPath ?? pathMonitor.currentPath
        if path.usesInterfaceType(.wifi) { return }
        throw YouTubeServiceError.network(NSError(
            domain: "FreeTube.DownloadManager",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Cellular downloads are disabled in Settings, but Wi-Fi isn't currently available."]
        ))
    }

    private func publish(snapshot: DownloadTaskSnapshot) {
        tasks[snapshot.id] = snapshot
        if case .downloading(let value) = snapshot.state {
            progressByVideoID[snapshot.videoID] = value
        } else if case .completed = snapshot.state {
            progressByVideoID.removeValue(forKey: snapshot.videoID)
        } else if case .failed = snapshot.state {
            progressByVideoID.removeValue(forKey: snapshot.videoID)
        }
        publishSnapshots()
    }

    /// Publish a snapshot owned by a different downloader (currently just `URLDownloadManager`)
    /// into the shared transfer-queue. The convention is that **external snapshots use an
    /// `id` prefixed with `"fetch-"`** so cancel-routing in `DownloadsViewModel.cancel` knows
    /// to delegate back to the originating manager. Removal is handled by the publisher —
    /// when an external download finishes, it calls `removeExternalSnapshot(id:)` after the
    /// usual 2-second auto-dismiss delay (matching the YouTube flow's UX).
    func publishExternal(snapshot: DownloadTaskSnapshot) {
        publish(snapshot: snapshot)
    }

    /// Remove a previously-published external snapshot. Called by the originating downloader
    /// once it's decided the row should disappear from the transfer queue. No-op if the id
    /// is unknown (terminal snapshots may have already been swept).
    func removeExternalSnapshot(id: String) {
        tasks[id] = nil
        publishSnapshots()
    }

    private func publishSnapshots() {
        activeTasks = Array(tasks.values).sorted { $0.createdAt > $1.createdAt }
        log.debug("publishSnapshots: \(self.activeTasks.count, privacy: .public) entries")
    }
}
