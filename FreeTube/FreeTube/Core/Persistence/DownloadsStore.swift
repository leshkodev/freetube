import AVFoundation
import Foundation
import Observation
import OSLog
import UIKit

/// Replaces the SwiftData `DownloadedVideo` query path with a file-system + xattr scan.
/// **Single source of truth = `Documents/*.{mp4,m4a,mp3,webm,opus}`**; metadata travels
/// with each file as an extended attribute via `FileXattr`. The Documents root is exposed
/// to the user in the Files app (Info.plist keys `UIFileSharingEnabled` +
/// `LSSupportsOpeningDocumentsInPlace`), so they can drag files in/out, AirDrop, etc.
///
/// **Reactivity** = `Notification.Name.downloadsDidChange`. After a download lands (yt-dlp
/// or URL-fetch) or a file is deleted, the writer posts this notification; this store
/// listens and re-runs `refresh()`. Since the store is `@Observable`, any view holding it
/// re-renders when `entries` mutates.
///
/// **No reactivity for external file changes** (user deletes via Files.app). The store
/// only refreshes on app launch and on app-driven mutations. A `DispatchSource` file-system
/// watcher could be added later if that becomes a real complaint.
@available(iOS 17.0, *)
@Observable
@MainActor
final class DownloadsStore {
    static let shared = DownloadsStore()

    /// Name of the notification any code path posts after touching the Downloads folder.
    /// Avoids hardcoded strings sprinkled across writers.
    nonisolated static let didChange = Notification.Name("com.leshko.freetube.downloadsDidChange")

    /// xattr key holding the serialized `DownloadMetadata` for a file. App-prefixed so
    /// other tools (Files.app, Finder) don't show it as plain text.
    nonisolated static let metadataXattrKey = "com.leshko.freetube.downloadMetadata"

    /// JPEG compression target. ~10 KB at 200×112 for typical YouTube thumbnails — fits
    /// comfortably in an xattr value with room to spare.
    nonisolated static let thumbnailMaxWidth: CGFloat = 200
    nonisolated static let thumbnailJpegQuality: CGFloat = 0.55

    /// Current snapshot. `@Observable` re-emits on assignment. Always assigned on the main
    /// actor at the end of a background scan — views observe via SwiftUI's standard
    /// observation tracking.
    private(set) var entries: [DownloadEntry] = []
    /// True while a background scan is in flight. `SettingsScreen` and others can read this
    /// to show a spinner next to the cache-size label on first launch.
    private(set) var isScanning: Bool = false

    @ObservationIgnored private let log = AppLog(subsystem: "com.leshko.freetube", category: "DownloadsStore")
    @ObservationIgnored private var notificationObserver: NSObjectProtocol?
    /// Most recent in-flight scan. Cancelled before starting a new one so back-to-back
    /// `didChange` notifications can't pile up several stale scans whose late completions
    /// would overwrite each other in arbitrary order.
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    private init() {
        Self.migrateLegacyDownloadsFolder()
        notificationObserver = NotificationCenter.default.addObserver(
            forName: Self.didChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    /// One-shot migration of any `Documents/Downloads/` files left over from before we
    /// flattened the layout. Moves every file inside up to the Documents root and removes
    /// the empty `Downloads/` subdirectory. Idempotent — second launch finds no legacy
    /// folder and is a no-op.
    ///
    /// **Runs synchronously on init** because it's a few `rename(2)` syscalls (same
    /// filesystem = inode pointer swap, no actual byte copying) and the scan that follows
    /// needs the files in their final location to surface them. Even with hundreds of
    /// files this is ~1ms.
    private nonisolated static func migrateLegacyDownloadsFolder() {
        let docs = downloadsDirectory()
        let legacy = docs.appendingPathComponent("Downloads", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: legacy.path, isDirectory: &isDir), isDir.boolValue else { return }
        let contents = (try? FileManager.default.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)) ?? []
        for url in contents {
            let dest = docs.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.moveItem(at: url, to: dest)
        }
        try? FileManager.default.removeItem(at: legacy)
    }

    deinit {
        scanTask?.cancel()
        if let token = notificationObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - Read

    /// Kicks off an asynchronous scan of the Documents root. The directory listing,
    /// per-file `attributesOfItem`, and per-file xattr reads all run on a detached
    /// `.utility` task — never on the main thread. Result lands back via assignment to
    /// `entries`, which triggers SwiftUI to re-render any observing view.
    ///
    /// **Cancellation:** if another `refresh()` arrives before this one finishes (e.g.
    /// rapid `didChange` posts during a Download All batch), we cancel the previous task
    /// so only the latest scan's result lands in `entries`. Otherwise late completions
    /// would race and the final state could reflect an older directory snapshot.
    func refresh() {
        scanTask?.cancel()
        isScanning = true
        scanTask = Task.detached(priority: .utility) { [weak self] in
            let scanned = Self.scanDirectory()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.entries = scanned
                self.isScanning = false
                self.log.debug("refresh: \(scanned.count, privacy: .public) entries from \(Self.downloadsDirectory().path, privacy: .public)")
            }
        }
    }

    /// Pure file-system scan + xattr decode. `nonisolated static` so it can run from any
    /// thread (the detached scan task in particular). Returns the sorted entry list.
    /// Newest first by `downloadedAt` if metadata is present, else by file mtime.
    private nonisolated static func scanDirectory() -> [DownloadEntry] {
        let dir = downloadsDirectory()
        let fileURLs = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let mediaURLs = fileURLs.filter { ["mp4", "m4a", "mp3", "webm", "opus"].contains($0.pathExtension.lowercased()) }
        return mediaURLs.compactMap(makeEntry(from:)).sorted { $0.sortDate > $1.sortDate }
    }

    /// Returns the compressed JPEG thumbnail bytes for a given videoID (or nil).
    /// Used by `RootView` to populate the mini-player image when playing a locally-saved
    /// download whose `Video.thumbnailURL` was nil.
    func thumbnail(forVideoID videoID: String) -> Data? {
        entries.first { $0.metadata?.videoID == videoID }?.metadata?.thumbnailData
    }

    /// Direct lookup by file URL — useful when a caller already has a path and wants the
    /// associated metadata without scanning the list.
    func metadata(at fileURL: URL) -> DownloadMetadata? {
        if let cached = entries.first(where: { $0.fileURL == fileURL }) {
            return cached.metadata
        }
        return Self.readMetadata(at: fileURL)
    }

    // MARK: - Write

    /// Encode + write the metadata xattr to the file, then notify. The caller is
    /// responsible for having already moved the bytes to `fileURL`. **All heavy work
    /// happens on a detached `.utility` task** so the calling actor (typically main, via
    /// `DownloadManager.persistDownloaded` / `URLDownloadManager.persistCompletion`) isn't
    /// blocked by:
    ///   - JPEG decode + downscale + re-encode for the thumbnail (`UIGraphicsImageRenderer`
    ///     is documented thread-safe since iOS 10)
    ///   - `AVURLAsset` duration probe (file header read; ~few KB)
    ///   - PropertyList encode + `setxattr(2)` syscall
    /// Returns immediately; the `didChange` notification posts once the xattr is on disk,
    /// triggering the DownloadsStore refresh.
    func write(
        videoID: String,
        title: String,
        channelName: String,
        formatID: String,
        originalURL: String?,
        rawThumbnail: Data?,
        at fileURL: URL
    ) {
        // Capture all inputs by value (they're all Sendable types) so the detached task
        // doesn't pin any actor-isolated reference.
        Task.detached(priority: .utility) {
            let thumb = rawThumbnail.flatMap(Self.compressedThumbnail(_:))
            let duration = Self.readDuration(at: fileURL)
            let metadata = DownloadMetadata(
                videoID: videoID,
                title: title,
                channelName: channelName,
                formatID: formatID,
                downloadedAt: .now,
                originalURL: originalURL,
                thumbnailData: thumb,
                duration: duration
            )
            do {
                let blob = try PropertyListEncoder().encode(metadata)
                try FileXattr.write(blob, key: Self.metadataXattrKey, at: fileURL)
            } catch {
                // Logging happens on main below — only if needed.
            }
            await MainActor.run {
                NotificationCenter.default.post(name: Self.didChange, object: nil)
            }
        }
    }

    /// Delete the underlying mp4 (the xattr goes with it). Posts a change notification so
    /// other observers (`DownloadsScreen`) refresh.
    func delete(at fileURL: URL) {
        do {
            try FileManager.default.removeItem(at: fileURL)
            log.info("deleted \(fileURL.lastPathComponent, privacy: .public)")
        } catch {
            log.error("delete failed for \(fileURL.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    // MARK: - Cache eviction

    /// Drop the oldest files until total size fits under `limitBytes`. The most-recent
    /// file is always preserved — never sabotage the play request that triggered the
    /// eviction sweep. `nil` limit → no-op. Runs the actual `FileManager.removeItem`
    /// calls on a `.utility` detached task because deleting tens of files can take
    /// noticeable wall-clock time and shouldn't block the main thread.
    func enforceCacheLimit(_ limitBytes: Int64?) {
        guard let limitBytes else { return }
        var total: Int64 = 0
        var evict: [URL] = []
        // entries is already newest-first; walk and accumulate. Capture URLs only —
        // DownloadEntry isn't Sendable across the detached boundary, and we don't need
        // anything else off the entry to delete the file.
        for (index, entry) in entries.enumerated() {
            total += entry.fileSize
            // Always keep the newest (index 0) regardless of its size — otherwise a
            // single large download with a tiny cap would immediately self-evict.
            if index > 0 && total > limitBytes {
                evict.append(entry.fileURL)
            }
        }
        guard !evict.isEmpty else { return }
        let urls = evict
        log.info("cache eviction removing \(urls.count, privacy: .public) files to fit \(limitBytes, privacy: .public) B")
        Task.detached(priority: .utility) {
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
            await MainActor.run {
                NotificationCenter.default.post(name: Self.didChange, object: nil)
            }
        }
    }

    // MARK: - Internals

    /// The directory we scan for downloads. **Documents root** — exposed to the user via
    /// the Files app (see Info.plist `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`).
    /// Other app data (SwiftData store, yt-dlp Python module) lives in
    /// `Application Support/`, not Documents, so the user only sees their media files.
    nonisolated static func downloadsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    /// Reads file attributes + xattr metadata for one file. Returns nil only when basic
    /// stat fails (file vanished mid-scan). Metadata missing → `entry.metadata == nil`,
    /// which the UI treats as an "orphan" row with filename-as-title.
    ///
    /// **Duration resolution**: prefer the value baked into the xattr (new downloads carry
    /// it; saves a disk read). Fall back to an `AVURLAsset` header read for orphans and
    /// older files. Both paths run on whatever thread is calling — always the scan's
    /// detached `.utility` task in practice — never on main.
    private nonisolated static func makeEntry(from url: URL) -> DownloadEntry? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs?[.modificationDate] as? Date) ?? .distantPast
        let metadata = readMetadata(at: url)
        let duration = metadata?.duration ?? readDuration(at: url)
        return DownloadEntry(
            fileURL: url,
            metadata: metadata,
            fileSize: size,
            modifiedAt: mtime,
            duration: duration
        )
    }

    private nonisolated static func readMetadata(at url: URL) -> DownloadMetadata? {
        guard let blob = FileXattr.read(key: metadataXattrKey, at: url) else { return nil }
        return try? PropertyListDecoder().decode(DownloadMetadata.self, from: blob)
    }

    /// One-shot synchronous `AVURLAsset.duration` read. Deprecated API but appropriate here:
    /// the file is local mp4, the call only walks the moov atom (a few KB of header), and
    /// it's invoked from detached `.utility` tasks (scan + write) — never on main.
    nonisolated static func readDuration(at url: URL) -> TimeInterval? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let asset = AVURLAsset(url: url)
        let seconds = asset.duration.seconds
        return (seconds.isFinite && seconds > 0) ? seconds : nil
    }

    /// Downscale + JPEG-compress the source thumbnail so it fits comfortably in an xattr
    /// value. Target ~10 KB at `thumbnailMaxWidth`. Returns nil if the input isn't a
    /// decodable image (rare but defensive).
    private nonisolated static func compressedThumbnail(_ raw: Data) -> Data? {
        guard let image = UIImage(data: raw) else { return nil }
        let maxW = thumbnailMaxWidth
        let scale = min(1, maxW / max(image.size.width, 1))
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        return resized.jpegData(compressionQuality: thumbnailJpegQuality)
    }
}

/// One row from the filesystem scan. `metadata == nil` means the file has no xattr we
/// recognise — surface it as an "orphan" with sensible defaults (filename-as-title).
@available(iOS 17.0, *)
struct DownloadEntry: Identifiable, Sendable {
    let fileURL: URL
    let metadata: DownloadMetadata?
    let fileSize: Int64
    let modifiedAt: Date
    /// Playback duration (seconds). Pre-resolved off-main during the scan — either from
    /// the file's xattr metadata (new downloads bake it in at write time) or via a
    /// one-shot `AVURLAsset` header read for orphans / older files. Either way, by the
    /// time SwiftUI renders a row, this is already a cached `TimeInterval` — no sync
    /// `AVURLAsset` calls during list body evaluation.
    let duration: TimeInterval?

    var id: String { fileURL.path }

    /// Date used for the newest-first sort. Prefer metadata when available (matches the
    /// previous SwiftData behavior), fall back to file modification time for orphans.
    var sortDate: Date { metadata?.downloadedAt ?? modifiedAt }
}
