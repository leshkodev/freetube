import Foundation

/// Result of probing an arbitrary URL via `yt-dlp --dump-single-json` (yt-dlp's
/// `extract_info(download=False)` under the hood). Source-agnostic — covers YouTube but also
/// every other extractor yt-dlp supports.
///
/// Why this is a separate type from `Video`: `Video` is YouTube-shaped (channelID,
/// channelName, isShort, isLive). Generic media has none of those — just title, uploader,
/// duration, and a flat list of downloadable formats. Mixing the two would invite YouTube
/// assumptions to leak into the generic path.
struct RemoteMedia: Identifiable, Sendable, Hashable {
    /// yt-dlp's `id` for the source's own identifier (YouTube video ID, Vimeo numeric ID, etc.).
    let id: String
    /// Original URL the user pasted, normalised through yt-dlp's `webpage_url`.
    let webpageURL: URL?
    let title: String
    let uploader: String?
    /// Single thumbnail URL chosen as "best" by yt-dlp (largest by area when available).
    let thumbnailURL: URL?
    /// Total duration in seconds. nil for live streams or extractors that don't report it.
    let duration: TimeInterval?
    let isLive: Bool
    /// All formats yt-dlp returned, in the order yt-dlp listed them (worst → best by yt-dlp's
    /// own scoring). Callers usually re-sort by their preferred criterion.
    let formats: [RemoteFormat]
    /// Subtitle tracks indexed by language code. Empty when the extractor didn't return any.
    let subtitles: [RemoteSubtitle]
    /// Free-form description from the page. May be empty/nil.
    let descriptionText: String?
    /// yt-dlp's extractor key (e.g. "Youtube", "Vimeo", "Twitter"). Surfaced in the UI as a
    /// small badge so the user knows where the media is coming from.
    let extractor: String?
}

/// One downloadable variant. Captures the fields the UI renders + the fields the downloader
/// needs to dispatch (URL, protocol, manifest-ness).
struct RemoteFormat: Identifiable, Sendable, Hashable {
    /// yt-dlp's stable `format_id` (e.g. "137", "299+140", "hls-720p"). Used as `Identifiable.id`
    /// and as the `-f` argument when re-handed to yt-dlp would be required (we don't actually
    /// re-invoke yt-dlp — we use `url` directly — but keeping the id around is useful for logs).
    let id: String
    /// Direct downloadable URL. May be a progressive .mp4, an HLS .m3u8 manifest, or a DASH
    /// segment URL depending on `protocolKind`. nil only for cipher-locked or DRM-locked
    /// formats yt-dlp couldn't resolve.
    let url: URL?
    /// File extension yt-dlp would write (mp4, m4a, webm, mp3, opus).
    let ext: String
    let width: Int?
    let height: Int?
    let fps: Double?
    /// "vcodec" from yt-dlp ("avc1.64001f", "vp09.…", "none" for audio-only). nil when the
    /// format is audio-only and yt-dlp returned the sentinel "none" — we normalize that.
    let vcodec: String?
    /// "acodec" from yt-dlp. nil when the format is video-only.
    let acodec: String?
    /// Total video bitrate in kbps (yt-dlp `vbr`).
    let vbr: Double?
    /// Total audio bitrate in kbps (yt-dlp `abr`).
    let abr: Double?
    /// Expected/actual file size in bytes. yt-dlp returns either `filesize` or
    /// `filesize_approx`; we coalesce.
    let filesize: Int64?
    /// Streaming protocol category — drives the download dispatch (URLSession vs ffmpeg HLS
    /// vs ffmpeg DASH). See `RemoteFormat.ProtocolKind` for the recognized values.
    let protocolKind: ProtocolKind
    /// yt-dlp's raw `protocol` string. Kept for diagnostics so future regressions ("yt-dlp
    /// added a new protocol we don't dispatch") are visible in logs.
    let rawProtocol: String

    var hasVideo: Bool { (vcodec ?? "").lowercased() != "none" && vcodec != nil }
    var hasAudio: Bool { (acodec ?? "").lowercased() != "none" && acodec != nil }
    var isVideoOnly: Bool { hasVideo && !hasAudio }
    var isAudioOnly: Bool { hasAudio && !hasVideo }
    var isProgressive: Bool { hasVideo && hasAudio }

    /// Human-readable resolution label ("1080p60", "720p", "audio") used in the UI rows.
    var label: String {
        if isAudioOnly {
            if let abr { return "Audio \(Int(abr))k \(ext)" }
            return "Audio \(ext)"
        }
        if let height {
            if let fps, fps >= 50 {
                return "\(height)p\(Int(fps))"
            }
            return "\(height)p"
        }
        return ext.uppercased()
    }

    enum ProtocolKind: String, Sendable {
        /// Plain HTTP/HTTPS direct download. URLSession.bytes(for:) path.
        case https
        /// HLS — `m3u8`, `m3u8_native`. Dispatched through `FFmpegRunner` which reads the
        /// manifest, fetches segments, and writes a single mp4. yt-dlp's Python-side ffmpeg
        /// merger is disabled (CLAUDE.md §15.3), so this is the only HLS path.
        case hls
        /// DASH — `http_dash_segments`. Same dispatch as HLS (ffmpeg handles it).
        case dash
        /// Anything else (RTMP, F4M, etc.). v1 doesn't support these; the UI greys them out.
        case unsupported
    }
}

/// One subtitle track yt-dlp found. We don't expose these in v1's UI, but the field is in the
/// model so a future "Embed subtitles" toggle has somewhere to read from.
struct RemoteSubtitle: Identifiable, Sendable, Hashable {
    /// "en", "en-auto", "es", etc.
    let id: String
    let langName: String?
    let url: URL?
    let ext: String
}
