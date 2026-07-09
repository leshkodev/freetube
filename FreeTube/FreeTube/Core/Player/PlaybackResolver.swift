import Foundation
import OSLog

/// CLAUDE.md §7 (amended): every play tap routes through `DownloadManager.ensureDownloaded` so the
/// resolver always returns a `.localFile` URL. There's no more direct/HLS/composite path because
/// YouTube's PoT-protected URLs 403 against AVPlayer's segment requests — we'd rather wait for the
/// download than ship a broken playback experience.
///
/// The resolver still takes a `videoID` for API stability with the playback pipeline. To enrich
/// the `DownloadMetadata` xattr we'd want the full `Video` (title, channel, thumbnail) — that's
/// passed in by `PlayerStateManager.load(_:)` via the `resolveDownload(video:quality:)` entry.
final class PlaybackResolver: PlaybackResolving {
    private let downloads: DownloadManagerLike
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "PlaybackResolver")

    init(downloads: DownloadManagerLike = DownloadManager.shared) {
        self.downloads = downloads
    }

    func resolve(videoID: String, quality: VideoQuality) async throws -> PlaybackSource {
        log.info("resolve(\(videoID, privacy: .public)) — checking cache")
        if let local = downloads.localFile(for: videoID) {
            log.info("resolve: cache hit → \(local.path, privacy: .public)")
            return .localFile(local)
        }
        // No cache hit and the caller didn't give us the full Video. Build a stub so the SwiftData
        // row at least has the videoID; PlayerStateManager.resolveDownload(video:) is the rich path.
        let stub = Video(
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
        let url = try await downloads.ensureDownloaded(video: stub, quality: quality, priority: .userInitiated)
        return .localFile(url)
    }
}

/// Subset of `DownloadManager` the resolver depends on. Allows tests to swap a mock.
protocol DownloadManagerLike: Sendable {
    func localFile(for videoID: String) -> URL?
    func ensureDownloaded(video: Video, quality: VideoQuality, priority: DownloadPriority) async throws -> URL
}

@available(iOS 17.0, *)
extension DownloadManager: DownloadManagerLike {}

/// Subset of `DownloadManager` that older call sites depend on. Retained so the build graph stays
/// stable while we transition off `downloadTemporary` — new code should call `ensureDownloaded`.
protocol TemporaryDownloading: Sendable {
    func downloadTemporary(videoID: String, format: VideoFormat) async throws -> URL
}
