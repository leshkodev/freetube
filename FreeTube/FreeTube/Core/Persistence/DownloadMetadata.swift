import Foundation

/// Serialized payload written as a single extended attribute on each downloaded file.
/// Replaces the SwiftData `DownloadedVideo` row — the file system is now the source of
/// truth, and any tool that reads the xattr can reconstruct the row.
///
/// **Encoding**: binary property list. Smaller and faster to decode than JSON, and
/// `Date`/`Data` round-trip without manual coding keys.
///
/// **What's NOT stored here**: the file URL itself and the file size are recoverable from
/// the file system at read time, so we don't duplicate them in the xattr — saves bytes
/// and avoids drift when the file is moved.
struct DownloadMetadata: Codable, Sendable {
    /// YouTube videoID for YouTube downloads; the pasted URL string for Link-tab items.
    /// Whatever uniquely identifies the *source* (filename can't, because URL items
    /// sanitise the title into the filename).
    let videoID: String
    let title: String
    /// "YouTube channel name" for YouTube, or the extractor name ("Instagram", "Vimeo")
    /// for Link items. Shown as the row subtitle in the Downloads list.
    let channelName: String
    /// `"ytdl"` for YouTube, `"url-fetch"` for Link tab. Lets the Downloads UI branch
    /// playback behavior without re-checking `originalURL`.
    let formatID: String
    let downloadedAt: Date
    /// Original pasted URL for Link-tab items; `nil` for YouTube (the canonical URL is
    /// recoverable from videoID). Drives the "Open in browser" target.
    let originalURL: String?
    /// Compressed JPEG bytes of the source thumbnail, ~10KB. Inline so the file is fully
    /// self-describing — no sidecar `.thumb.jpg` files cluttering the directory.
    /// `nil` when the source extractor didn't provide a thumbnail or the fetch failed.
    let thumbnailData: Data?
    /// Playback duration in seconds. Read once from `AVURLAsset` at write time (on a
    /// background task) and baked in — saves the Downloads list from doing an `AVAsset`
    /// header read per row on every body re-evaluation, which was the dominant source of
    /// scroll lag with large libraries.
    let duration: TimeInterval?
}
