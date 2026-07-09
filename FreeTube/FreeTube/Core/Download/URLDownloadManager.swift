import CryptoKit
import Foundation
import OSLog

/// Downloads a chosen `RemoteFormat` (from `YtDlpInfoService.probe`) to a file on disk.
/// Used by the **Link** tab. Independent of the YouTube-specific `DownloadManager` so
/// non-YouTube workflows don't drag along Video / SwiftData / queue-priority concerns.
///
/// **Dispatch by protocol** (CLAUDE.md §15.3 — yt-dlp's Python-side ffmpeg merger hangs):
///   - `.https` (plain HTTP/HTTPS direct file) → `URLSession.bytes(for:)` with real %-progress.
///   - `.hls` (m3u8 manifest) → `FFmpegRunner.run(["-i", url, "-c", "copy", …])`. ffmpeg reads
///     the manifest, fetches segments, writes a single mp4. No incremental progress (FFmpegSupport
///     doesn't surface stderr), so the UI shows an indeterminate spinner with elapsed time.
///   - `.dash` (http_dash_segments) → same as HLS (best-effort; ffmpeg's mpd handling may not
///     match yt-dlp's fragmented-mp4 reconstruction for every site).
///   - `.unsupported` → throws immediately.
///
/// **Adaptive pairing.** When the user picks a video-only format, we transparently also
/// download the best matching audio-only format and mux them with `ffmpeg -c copy`. Same
/// approach the YouTubeKit fallback path in `DownloadManager.runYouTubeKitFallback` uses.
/// Audio-only picks don't pair — they download alone.
///
/// **Output location.** Files land at `Documents/<sanitized title>.<ext>`, alongside
/// YouTube downloads. Visible in the Files app, surfaced by `DownloadsStore`'s scan.
@available(iOS 17.0, *)
@Observable
@MainActor
final class URLDownloadManager {
    static let shared = URLDownloadManager()

    /// In-flight or recently completed downloads keyed by the original URL the user
    /// pasted. Keying by URL (instead of mediaID + formatID like before) lets the
    /// `FetchScreen` queue join cleanly against `RecentFetchURL` entries with the same key —
    /// one row per URL, regardless of how many format combinations the user tried.
    private(set) var jobs: [String: FetchJob] = [:]

    /// Live `Task` handles so `cancel(url:)` can actually stop the in-flight download
    /// (instead of just hiding the row). Cleared on completion/failure/cancellation.
    @ObservationIgnored private var taskHandles: [String: Task<URL, Error>] = [:]

    // `nonisolated` so the off-main execute() chain (downloadDirect's byte loop in
    // particular) can read these without hopping back to the main actor for every log
    // line / cookie peek.
    @ObservationIgnored private nonisolated let log = AppLog(subsystem: "com.leshko.freetube", category: "URLDownloadManager")
    @ObservationIgnored private nonisolated let preferences = UserPreferences()

    private init() {}

    // MARK: - Public surface

    /// Kicks off a download for the user's explicit (video, audio) selection from the
    /// Preview screen. Either format may be nil:
    ///   - `video == nil && audio != nil` → audio-only download (e.g. user picked "None"
    ///     for video).
    ///   - `video != nil && audio == nil` → video as-is (silent if video-only; with embedded
    ///     audio if the picked format is progressive).
    ///   - both non-nil:
    ///     - same `format.id` → single download (the format is progressive — no muxing).
    ///     - different IDs and `video.isVideoOnly` → download both, mux with `ffmpeg -c copy`.
    ///     - different IDs and `video.isProgressive` → download video only, audio choice is
    ///       ignored (the progressive already has audio baked in). We surface this in logs.
    ///   - both nil → throws immediately; the UI's Download button should be disabled in
    ///     that case anyway.
    ///
    /// Returns the job key (the `originalURL`) for the UI to subscribe to `jobs[key]`.
    /// Coalesces concurrent calls — a second tap while a download is already running for
    /// the same URL is a no-op.
    ///
    /// `originalURL` is the string the user typed/pasted (the recents key). We use it as
    /// both the dict key here AND the join key against `UserPreferences.recentFetchURLs`
    /// — that way the queue row in `FetchScreen` finds the live job for a recents entry
    /// just by URL string, no separate index needed.
    @discardableResult
    func startDownload(originalURL: String, media: RemoteMedia, video: RemoteFormat?, audio: RemoteFormat?, conversion: ConversionOptions = ConversionOptions()) -> String {
        let key = originalURL
        if let existing = jobs[key], !existing.state.isTerminal { return key }

        let job = FetchJob(
            key: key,
            mediaTitle: media.title,
            formatLabel: Self.summaryLabel(video: video, audio: audio),
            state: .queued,
            startedAt: .now
        )
        jobs[key] = job

        // **Publish to the shared transfer queue** so the active download shows up in
        // Downloads tab alongside any YouTube downloads. The snapshot id carries a
        // `"fetch-"` prefix so the cancel router in `DownloadsViewModel.cancel` knows to
        // call back into `URLDownloadManager.cancel(url:)` instead of the YouTube path.
        // `videoID` carries the original URL so the router can find the job.
        publishExternalSnapshot(originalURL: originalURL, title: media.title, state: .queued)

        // **Detached** so the worker runs off the main actor. With the class marked
        // `@MainActor`, a plain `Task { }` here would inherit MainActor isolation
        // (CLAUDE.md §15.12), pinning the entire URLSession byte-loop and ffmpeg
        // orchestration to the main thread. `execute` and the helpers it calls are all
        // `nonisolated` — they hop back to main only via `await updateState(...)` for
        // the few `@Observable jobs[key]` writes.
        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { throw FetchError.missingURL }
            return try await self.execute(media: media, video: video, audio: audio, conversion: conversion, key: key)
        }
        taskHandles[key] = task

        // Observer task: awaits the worker and writes the terminal state. Kept off the
        // download task itself so cancellation propagates cleanly without an extra `try`.
        Task { [weak self] in
            guard let self else { return }
            var settled = self.jobs[key]
            do {
                let url = try await task.value
                settled?.state = .completed(url)
                if let job = settled { self.jobs[key] = job }
                self.taskHandles[key] = nil
                self.persistCompletion(originalURL: originalURL, media: media, fileURL: url)
                self.publishExternalSnapshot(originalURL: originalURL, title: media.title, state: .completed(url))
                self.scheduleSnapshotRemoval(originalURL: originalURL)
                self.log.info("[fetch] DONE key=\(key, privacy: .public) → \(url.lastPathComponent, privacy: .public)")
            } catch is CancellationError {
                settled?.state = .failed("Cancelled")
                if let job = settled { self.jobs[key] = job }
                self.taskHandles[key] = nil
                self.publishExternalSnapshot(originalURL: originalURL, title: media.title, state: .failed("Cancelled"))
                self.scheduleSnapshotRemoval(originalURL: originalURL)
                self.log.info("[fetch] CANCELLED key=\(key, privacy: .public)")
            } catch {
                settled?.state = .failed(error.localizedDescription)
                if let job = settled { self.jobs[key] = job }
                self.taskHandles[key] = nil
                self.publishExternalSnapshot(originalURL: originalURL, title: media.title, state: .failed(error.localizedDescription))
                self.scheduleSnapshotRemoval(originalURL: originalURL)
                self.log.error("[fetch] FAILED key=\(key, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        return key
    }

    /// Bridge between `FetchJob.State` and `DownloadTaskSnapshot.State`. Indeterminate
    /// (HLS/DASH) progress is published as 0 since the shared snapshot type doesn't model
    /// it — the transfer queue row shows an empty progress bar; users with HLS downloads
    /// can see the row but not a percent.
    private func publishExternalSnapshot(originalURL: String, title: String, state: FetchJob.State) {
        let snapshotState: DownloadTaskSnapshot.State = {
            switch state {
            case .queued: return .queued
            case .downloading(let p, _): return .downloading(progress: p ?? 0)
            case .processing: return .downloading(progress: 0) // shows spinner-ish bar
            case .completed(let url): return .completed(url)
            case .failed(let msg): return .failed(msg)
            }
        }()
        DownloadManager.shared.publishExternal(snapshot: DownloadTaskSnapshot(
            id: Self.transferSnapshotID(originalURL: originalURL),
            videoID: originalURL, // used as the cancel-routing key in DownloadsViewModel
            title: title,
            state: snapshotState,
            createdAt: .now
        ))
    }

    /// Stable id for a URL's transfer-queue snapshot. Prefix lets `DownloadsViewModel.cancel`
    /// detect URL-sourced snapshots and route cancellation back here.
    nonisolated static func transferSnapshotID(originalURL: String) -> String {
        "fetch-" + originalURL
    }

    /// Match the YouTube flow's "completed → fades after 2s" behavior so the transfer queue
    /// doesn't accumulate finished URL rows. The FetchScreen recents list owns the persistent
    /// "downloaded files" view; the transfer queue is for in-flight only.
    private func scheduleSnapshotRemoval(originalURL: String) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            DownloadManager.shared.removeExternalSnapshot(id: Self.transferSnapshotID(originalURL: originalURL))
        }
    }

    /// Cancels a live download. The `URLSession.bytes` loop checks `Task.checkCancellation()`
    /// after every 64KB chunk, so HTTPS downloads stop quickly. The ffmpeg-driven HLS/DASH
    /// path can't be interrupted mid-segment (FFmpegSupport has no cancellation hook), so
    /// HLS downloads finish their current ffmpeg call before the cancel takes effect.
    ///
    /// Idempotent — calling cancel on a job that already terminated is a no-op.
    func cancel(url: String) {
        guard let task = taskHandles[url] else {
            // No live task — still allow dismissing a terminal job from the UI.
            jobs[url] = nil
            return
        }
        log.info("[fetch] cancel requested for url=\(url, privacy: .public)")
        task.cancel()
        // Don't remove the job entry — the observer Task will land in the `is CancellationError`
        // branch above and write a terminal `.failed("Cancelled")` state, which the UI uses
        // to show the "Redownload" button.
    }

    /// Display label for the active job's "what we're downloading" caption.
    private nonisolated static func summaryLabel(video: RemoteFormat?, audio: RemoteFormat?) -> String {
        switch (video, audio) {
        case (let v?, let a?) where v.id != a.id: return "\(v.label) + \(a.label)"
        case (let v?, _): return v.label
        case (_, let a?): return a.label
        case (nil, nil): return "(nothing selected)"
        }
    }

    /// Drops a finished/failed job from the in-memory dict. The file on disk and the
    /// `RecentFetchURL` entry are NOT touched — the recents row keeps showing the result
    /// from its persisted `localFilename`. Used by the row's per-state controls when the
    /// user wants to clear a stale failure message before retrying.
    func dismiss(key: String) {
        jobs[key] = nil
    }

    /// Resolves a persisted relative filename (stored on `RecentFetchURL.localFilename`) to
    /// the absolute path under Documents. Returns nil if the file no longer exists
    /// (e.g. user freed space via Files.app while the app was backgrounded).
    nonisolated static func resolveLocalFile(filename: String) -> URL? {
        let url = fetchDirectory().appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Writes the completed download's metadata to two places:
    ///   1. **`RecentFetchURL` list** in `UserPreferences` — the FetchScreen row reads
    ///      this for thumbnail/title/extractor when the in-memory `FetchJob` is gone
    ///      (cleared on next probe, dropped at next launch).
    ///   2. **File extended attributes** via `DownloadsStore.write` — so the file appears
    ///      in the Downloads-tab "Saved on device" section alongside YouTube downloads.
    ///      `videoID` is the original URL string (acts as the unique source identifier);
    ///      `originalURL` is also stored so `DownloadsScreen` can branch behavior (tap →
    ///      `loadLocalFile` instead of YouTube resolver, Open-in-browser → source page).
    private func persistCompletion(originalURL: String, media: RemoteMedia, fileURL: URL) {
        let filename = fileURL.lastPathComponent

        var list = preferences.recentFetchURLs
        if let idx = list.firstIndex(where: { $0.url == originalURL }) {
            list[idx].localFilename = filename
            list[idx].title = media.title
            list[idx].extractor = media.extractor
            list[idx].thumbnailURL = media.thumbnailURL?.absoluteString
            list[idx].lastUsedAt = .now
        } else {
            list.insert(RecentFetchURL(
                url: originalURL,
                title: media.title,
                extractor: media.extractor,
                thumbnailURL: media.thumbnailURL?.absoluteString,
                localFilename: filename,
                lastUsedAt: .now
            ), at: 0)
        }
        preferences.recentFetchURLs = list

        let extractor = media.extractor ?? media.uploader ?? "Link"
        let thumbURL = media.thumbnailURL
        Task { @MainActor in
            // Fetch the thumbnail bytes (best-effort). `DownloadsStore.write` will
            // downscale + JPEG-compress to ~10 KB before embedding in the xattr.
            let thumbData: Data? = await {
                guard let url = thumbURL else { return nil }
                return try? await URLSession.shared.data(from: url).0
            }()
            DownloadsStore.shared.write(
                videoID: originalURL,
                title: media.title,
                channelName: extractor,
                formatID: "url-fetch",
                originalURL: originalURL,
                rawThumbnail: thumbData,
                at: fileURL
            )
        }
    }

    // MARK: - Execution

    private nonisolated func execute(media: RemoteMedia, video: RemoteFormat?, audio: RemoteFormat?, conversion: ConversionOptions, key: String) async throws -> URL {
        let fetchDir = Self.fetchDirectory()
        try FileManager.default.createDirectory(at: fetchDir, withIntermediateDirectories: true)
        let baseName = Self.uniqueBaseName(media: media, originalURL: key)

        // Resolve the three cases the public-API doc-comment enumerates. After this block,
        // `mode` carries everything `execute` needs to dispatch without re-doing the
        // policy logic at every call site.
        let mode: Mode
        switch (video, audio) {
        case (nil, nil):
            throw FetchError.missingURL
        case (let v?, nil):
            mode = .single(format: v, audioOnly: false)
        case (nil, let a?):
            mode = .single(format: a, audioOnly: true)
        case (let v?, let a?):
            // Same format ID on both → progressive that satisfies both selections, single download.
            // Different IDs but video is progressive → audio is redundant; download video as-is and log a notice.
            // Different IDs and video is video-only → adaptive split, download both + mux.
            if v.id == a.id {
                mode = .single(format: v, audioOnly: false)
            } else if v.isProgressive {
                log.notice("[fetch] video format \(v.id, privacy: .public) is progressive — ignoring separate audio selection \(a.id, privacy: .public)")
                mode = .single(format: v, audioOnly: false)
            } else {
                mode = .adaptive(video: v, audio: a)
            }
        }

        switch mode {
        case .single(let format, let audioOnly):
            return try await downloadSingle(format: format, audioOnly: audioOnly, conversion: conversion, baseName: baseName, fetchDir: fetchDir, key: key)
        case .adaptive(let videoFmt, let audioFmt):
            return try await downloadAdaptive(video: videoFmt, audio: audioFmt, conversion: conversion, baseName: baseName, fetchDir: fetchDir, key: key)
        }
    }

    /// Dispatch the single-source path (progressive, audio-only, or a video-only format the
    /// user explicitly chose without pairing audio). Honors `conversion` — when either
    /// video→H.264 or audio→MP3 is on, we always finish through ffmpeg so the codec/container
    /// can be rewritten in a single pass.
    private nonisolated func downloadSingle(format: RemoteFormat, audioOnly: Bool, conversion: ConversionOptions, baseName: String, fetchDir: URL, key: String) async throws -> URL {
        guard format.protocolKind != .unsupported else {
            throw FetchError.unsupportedProtocol(format.rawProtocol)
        }
        guard let url = format.url else { throw FetchError.missingURL }

        let ext = Self.outputExtension(audioOnly: audioOnly, format: format, conversion: conversion)
        let destination = fetchDir.appendingPathComponent("\(baseName).\(ext)")
        try? FileManager.default.removeItem(at: destination)

        let needsTranscode = conversion.requiresReencode(audioOnly: audioOnly, format: format)
        log.info("[fetch] single start key=\(key, privacy: .public) format=\(format.id, privacy: .public) protocol=\(format.rawProtocol, privacy: .public) audioOnly=\(audioOnly, privacy: .public) transcode=\(needsTranscode, privacy: .public)")

        switch format.protocolKind {
        case .https:
            if needsTranscode {
                // Download to a temp file first, then transcode. Direct URLSession download
                // gives real %-progress; ffmpeg's transcode pass is silent (FFmpegSupport
                // doesn't surface stderr) but typically much faster than the network leg.
                let dlTmp = fetchDir.appendingPathComponent(".\(baseName).source.\(format.ext)")
                defer { try? FileManager.default.removeItem(at: dlTmp) }
                try await downloadDirect(url: url, destination: dlTmp, key: key, totalBytes: format.filesize)
                try await runTranscode(input: dlTmp, destination: destination, conversion: conversion, audioOnly: audioOnly, key: key)
            } else {
                try await downloadDirect(url: url, destination: destination, key: key, totalBytes: format.filesize)
            }
        case .hls, .dash:
            // ffmpeg already drives the HLS/DASH leg; transcoding is just a flag swap on the
            // same invocation (one-pass download+transcode).
            try await downloadViaFfmpeg(url: url, destination: destination, conversion: conversion, key: key, audioOnly: audioOnly)
        case .unsupported:
            throw FetchError.unsupportedProtocol(format.rawProtocol)
        }
        return destination
    }

    /// Dispatch the adaptive (video-only + audio-only) path: download both, then mux with
    /// `ffmpeg` into a single mp4. Codec flags from `conversion` are applied during the mux —
    /// no separate transcode pass. CLAUDE.md §15.3: this is Swift-side, not yt-dlp's merger.
    private nonisolated func downloadAdaptive(video: RemoteFormat, audio: RemoteFormat, conversion: ConversionOptions, baseName: String, fetchDir: URL, key: String) async throws -> URL {
        guard video.protocolKind != .unsupported else { throw FetchError.unsupportedProtocol(video.rawProtocol) }
        guard audio.protocolKind != .unsupported else { throw FetchError.unsupportedProtocol(audio.rawProtocol) }
        guard let vURL = video.url, let aURL = audio.url else { throw FetchError.missingURL }

        let destination = fetchDir.appendingPathComponent("\(baseName).mp4")
        try? FileManager.default.removeItem(at: destination)

        let videoTmp = fetchDir.appendingPathComponent(".\(baseName).video.\(video.ext)")
        let audioTmp = fetchDir.appendingPathComponent(".\(baseName).audio.\(audio.ext)")
        defer {
            try? FileManager.default.removeItem(at: videoTmp)
            try? FileManager.default.removeItem(at: audioTmp)
        }

        log.info("[fetch] adaptive start key=\(key, privacy: .public) video=\(video.id, privacy: .public) audio=\(audio.id, privacy: .public) v2h264=\(conversion.videoToH264, privacy: .public) a2mp3=\(conversion.audioToMP3, privacy: .public)")

        try await downloadAny(format: video, url: vURL, destination: videoTmp, key: key, phaseLabel: "Video")
        try await downloadAny(format: audio, url: aURL, destination: audioTmp, key: key, phaseLabel: "Audio")

        try await updateState(key: key, .processing(conversion.requiresReencode(audioOnly: false, format: video) ? "Converting + combining…" : "Combining video + audio…"))
        var args: [String] = [
            "ffmpeg",
            "-y",
            "-hide_banner",
            "-loglevel", "warning",
            "-i", videoTmp.path,
            "-i", audioTmp.path,
        ]
        args.append(contentsOf: Self.videoCodecArgs(conversion: conversion))
        args.append(contentsOf: Self.audioCodecArgs(conversion: conversion))
        args.append(contentsOf: [
            "-map", "0:v:0",
            "-map", "1:a:0",
            "-movflags", "+faststart",
            destination.path
        ])
        let exit = await FFmpegRunner.shared.run(args)
        guard exit == 0, FileManager.default.fileExists(atPath: destination.path) else {
            log.error("[fetch] mux failed exit=\(exit, privacy: .public)")
            throw FetchError.muxFailed(exit: Int(exit))
        }
        return destination
    }

    /// Post-download transcode pass for the single-source HTTPS path. Reads a local temp
    /// file and writes the final destination with the requested codec/container.
    private nonisolated func runTranscode(input: URL, destination: URL, conversion: ConversionOptions, audioOnly: Bool, key: String) async throws {
        try await updateState(key: key, .processing("Converting…"))
        var args: [String] = [
            "ffmpeg",
            "-y",
            "-hide_banner",
            "-loglevel", "warning",
            "-i", input.path,
        ]
        if audioOnly {
            args.append("-vn")
            args.append(contentsOf: Self.audioCodecArgs(conversion: conversion))
        } else {
            args.append(contentsOf: Self.videoCodecArgs(conversion: conversion))
            args.append(contentsOf: Self.audioCodecArgs(conversion: conversion))
            args.append(contentsOf: ["-movflags", "+faststart"])
        }
        args.append(destination.path)
        log.info("[fetch] transcode argv: \(args.joined(separator: " "), privacy: .public)")
        let exit = await FFmpegRunner.shared.run(args)
        guard exit == 0, FileManager.default.fileExists(atPath: destination.path) else {
            throw FetchError.muxFailed(exit: Int(exit))
        }
    }

    /// Internal dispatch mode resolved from the (video, audio) selection. Keeps `execute`
    /// shallow — each handler only sees what it needs.
    private enum Mode {
        case single(format: RemoteFormat, audioOnly: Bool)
        case adaptive(video: RemoteFormat, audio: RemoteFormat)
    }

    /// Dispatcher used inside the two-source path. Picks URLSession or ffmpeg based on the
    /// per-track format's protocol. The mux step that follows handles all codec rewriting,
    /// so this leg always copies bytes (no `conversion` passed in).
    private nonisolated func downloadAny(format: RemoteFormat, url: URL, destination: URL, key: String, phaseLabel: String) async throws {
        try await updateState(key: key, .downloading(progress: 0, phase: phaseLabel))
        switch format.protocolKind {
        case .https:
            try await downloadDirect(url: url, destination: destination, key: key, totalBytes: format.filesize, phaseLabel: phaseLabel)
        case .hls, .dash:
            // No conversion at this leg — the mux step rewrites codecs as needed.
            try await downloadViaFfmpeg(url: url, destination: destination, conversion: ConversionOptions(), key: key, audioOnly: format.isAudioOnly, phaseLabel: phaseLabel)
        case .unsupported:
            throw FetchError.unsupportedProtocol(format.rawProtocol)
        }
    }

    /// Plain HTTPS download via `URLSession.bytes`. Mirrors `DownloadManager.downloadStream`
    /// — same 64 KB buffered writes, same progress emission via the actor-isolated state map.
    private nonisolated func downloadDirect(url: URL, destination: URL, key: String, totalBytes: Int64?, phaseLabel: String? = nil) async throws {
        var request = URLRequest(url: url)
        // Some CDNs reject default URLSession UA; use a generic browser string. yt-dlp itself
        // does the same. We don't carry cookies — generic URLs are usually unauthenticated.
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.2 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw FetchError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let expected: Int64 = http.expectedContentLength > 0 ? http.expectedContentLength : (totalBytes ?? 0)

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: destination) else {
            throw FetchError.cannotWrite(destination.path)
        }
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(65_536)
        var written: Int64 = 0
        var lastEmit: ContinuousClock.Instant = .now
        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            if buffer.count >= 65_536 {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                // Throttle: emit at most ~5 updates / sec so we don't thrash the @Observable
                // dictionary. Same throttle window `DownloadManager` uses for yt-dlp progress.
                let now = ContinuousClock.now
                if (now - lastEmit) > .milliseconds(200) {
                    lastEmit = now
                    let pct = expected > 0 ? Double(written) / Double(expected) : 0
                    try await updateState(key: key, .downloading(progress: pct, phase: phaseLabel))
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += Int64(buffer.count)
        }
        try handle.close()
        log.info("[fetch] direct OK wrote=\(written, privacy: .public) → \(destination.lastPathComponent, privacy: .public)")
    }

    /// HLS / DASH path. ffmpeg reads the manifest URL directly and writes the output file
    /// (one-pass download + optional transcode). Codec flags from `conversion` are baked
    /// into the same invocation so we avoid a second pass.
    ///
    /// Progress is indeterminate — FFmpegSupport doesn't surface stderr — so the UI
    /// shows "Stream · streaming…" with no percentage.
    private nonisolated func downloadViaFfmpeg(url: URL, destination: URL, conversion: ConversionOptions, key: String, audioOnly: Bool, phaseLabel: String? = nil) async throws {
        try await updateState(key: key, .downloading(progress: nil, phase: phaseLabel ?? (audioOnly ? "Audio stream" : "Stream")))

        var args: [String] = [
            "ffmpeg",
            "-y", "-hide_banner", "-loglevel", "warning",
            "-i", url.absoluteString,
        ]
        if audioOnly {
            args.append("-vn")
            args.append(contentsOf: Self.audioCodecArgs(conversion: conversion))
        } else {
            args.append(contentsOf: Self.videoCodecArgs(conversion: conversion))
            args.append(contentsOf: Self.audioCodecArgs(conversion: conversion))
            args.append(contentsOf: ["-movflags", "+faststart"])
        }
        args.append(destination.path)

        log.info("[fetch] ffmpeg argv: \(args.joined(separator: " "), privacy: .public)")
        let exit = await FFmpegRunner.shared.run(args)
        guard exit == 0, FileManager.default.fileExists(atPath: destination.path) else {
            log.error("[fetch] ffmpeg HLS/DASH failed exit=\(exit, privacy: .public)")
            throw FetchError.muxFailed(exit: Int(exit))
        }
    }

    // MARK: - Codec helpers

    /// Video codec flags. When converting → H.264 via Apple's hardware encoder
    /// (`h264_videotoolbox`); otherwise stream-copy. Bitrate is fixed at 4 Mbps which lands
    /// near visually lossless for 1080p H.264; could be made adaptive later (read source
    /// bitrate, pick a target a notch lower).
    private nonisolated static func videoCodecArgs(conversion: ConversionOptions) -> [String] {
        if conversion.videoToH264 {
            return [
                "-c:v", "h264_videotoolbox",
                "-b:v", "4M",
                "-profile:v", "high",
                "-pix_fmt", "yuv420p"
            ]
        }
        return ["-c:v", "copy"]
    }

    /// Audio codec flags. When converting → MP3 via `libmp3lame`. Otherwise stream-copy
    /// with the AAC-ADTS-to-ASC bitstream filter (a no-op for non-AAC inputs, required for
    /// HLS AAC streams that ship in ADTS frames the MP4 muxer can't accept as-is).
    private nonisolated static func audioCodecArgs(conversion: ConversionOptions) -> [String] {
        if conversion.audioToMP3 {
            return ["-c:a", "libmp3lame", "-b:a", "192k"]
        }
        return ["-c:a", "copy", "-bsf:a", "aac_adtstoasc"]
    }

    /// What extension the final file should land with. Audio-only outputs reuse the source
    /// extension unless the user asked for MP3; video outputs are always mp4.
    private nonisolated static func outputExtension(audioOnly: Bool, format: RemoteFormat, conversion: ConversionOptions) -> String {
        if audioOnly {
            return conversion.audioToMP3 ? "mp3" : format.ext
        }
        return "mp4"
    }

    // MARK: - State helpers

    private func updateState(key: String, _ state: FetchJob.State) async throws {
        try Task.checkCancellation()
        guard var job = jobs[key] else { return }
        job.state = state
        jobs[key] = job
        // Mirror progress into the shared transfer queue so the Downloads-tab row's
        // ProgressView keeps moving alongside the FetchScreen row.
        publishExternalSnapshot(originalURL: key, title: job.mediaTitle, state: state)
    }

    /// Files land at the **Documents root** alongside YouTube downloads so they appear in
    /// the Downloads tab without a parallel folder scan, AND are visible to the user in
    /// the system Files app (Info.plist `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`).
    /// The unique-key collision risk vs YouTube filenames is zero in practice — YouTube
    /// names are `<11-char videoID>.mp4` and URL names are sanitized titles, which won't
    /// be 11 chars of `[A-Za-z0-9_-]`.
    nonisolated static func fetchDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    /// Stable, unique filename stem for a downloaded URL. Combines two stable pieces:
    ///   1. **A sanitized title prefix** for human readability (up to 60 chars). yt-dlp's
    ///      `title` for many sites is generic ("Video by alice", "Twitter Web Video") so
    ///      title alone collides — Instagram in particular loves to title every reel "Video
    ///      by <handle>", which would overwrite the previous reel on every new download.
    ///   2. **The yt-dlp `id`** parsed from the URL path/query (Instagram post code,
    ///      Twitter status id, Vimeo numeric id, YouTube videoID, SoundCloud track slug).
    ///      yt-dlp's extractors do this URL-component parsing for ~2,000 sites, so we
    ///      inherit their handling for free instead of re-implementing per-site.
    ///
    /// Falls back to a SHA-256-derived short hash of the original URL when the extractor
    /// returns neither a meaningful title nor an id (very rare — generic-extractor matches
    /// on plain media URLs). The hash is the same across runs for the same URL, so a
    /// re-download stays in place rather than spawning a duplicate.
    private nonisolated static func uniqueBaseName(media: RemoteMedia, originalURL: String) -> String {
        let trimmedTitle = media.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = sanitizeFilename(trimmedTitle)
        let mediaID = sanitizeFilename(media.id)
        let titleIsGeneric = title.isEmpty || ["video", "untitled"].contains(title.lowercased())

        if !titleIsGeneric && !mediaID.isEmpty {
            let truncatedTitle = String(title.prefix(60)).trimmingCharacters(in: .whitespaces)
            return "\(truncatedTitle)-\(mediaID)"
        }
        if !mediaID.isEmpty {
            return mediaID
        }
        if !title.isEmpty {
            return "\(title)-\(stableShortHash(of: originalURL))"
        }
        return "media-\(stableShortHash(of: originalURL))"
    }

    /// 8-hex-char SHA-256 prefix of the input. Stable across runs so a re-download of the
    /// same URL produces the same filename (overwriting any half-finished sibling).
    private nonisolated static func stableShortHash(of input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// Filename-safe sanitizer. Strips characters that AVFoundation / the user's "Save to
    /// Files" sheet would otherwise complain about. Keeps unicode word chars and spaces.
    private nonisolated static func sanitizeFilename(_ raw: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned = raw.unicodeScalars
            .map { bad.contains($0) ? "_" : Character($0) }
            .reduce(into: "") { $0.append($1) }
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(120))
    }
}

// MARK: - Models

/// One in-flight or recently-completed download. Observed by `FetchProbeView` for live
/// progress updates and by the `FetchScreen` recent-downloads list.
@available(iOS 17.0, *)
struct FetchJob: Identifiable, Sendable, Equatable {
    let key: String
    let mediaTitle: String
    let formatLabel: String
    var state: State
    let startedAt: Date

    var id: String { key }

    enum State: Sendable, Equatable {
        case queued
        /// `progress == nil` means "indeterminate" (used during ffmpeg HLS/DASH).
        case downloading(progress: Double?, phase: String?)
        case processing(String)
        case completed(URL)
        case failed(String)

        var isTerminal: Bool {
            switch self {
            case .completed, .failed: return true
            case .queued, .downloading, .processing: return false
            }
        }
    }
}

/// Post-download codec/container conversion knobs. Both default to off — the caller (the
/// Preview screen on the From URL tab) flips them based on source codec compatibility.
///
/// **Encoder availability** (bundled `ffmpeg-ios-lame` variant):
///   - `h264_videotoolbox` for video → H.264 (Apple hardware, GPL-free)
///   - `libmp3lame` for audio → MP3
struct ConversionOptions: Sendable {
    var videoToH264: Bool = false
    var audioToMP3: Bool = false

    /// True when the chosen options imply at least one ffmpeg encode pass for this download.
    /// HTTPS sources avoid the temp-file dance when this is false.
    func requiresReencode(audioOnly: Bool, format: RemoteFormat) -> Bool {
        if audioOnly { return audioToMP3 }
        return videoToH264 || audioToMP3
    }
}

@available(iOS 17.0, *)
enum FetchError: Error, LocalizedError {
    case noAudioFormat
    case missingURL
    case unsupportedProtocol(String)
    case httpStatus(Int)
    case cannotWrite(String)
    case muxFailed(exit: Int)

    var errorDescription: String? {
        switch self {
        case .noAudioFormat: return "No audio track found in this URL."
        case .missingURL: return "yt-dlp didn't return a usable URL for the selected format."
        case .unsupportedProtocol(let proto): return "Streaming protocol '\(proto)' isn't supported yet."
        case .httpStatus(let code): return "Server returned HTTP \(code)."
        case .cannotWrite(let path): return "Couldn't write to \(path)."
        case .muxFailed(let exit): return "ffmpeg failed (exit \(exit)). The stream may be DRM-protected."
        }
    }
}
