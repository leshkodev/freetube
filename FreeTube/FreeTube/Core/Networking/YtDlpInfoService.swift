import Foundation
import OSLog
import PythonKit

/// Probes an arbitrary URL via yt-dlp and returns a `RemoteMedia` describing what's
/// downloadable. Backed by `freetube_yt_dlp_extract_info` (which calls Python's
/// `ydl.extract_info(url, download=False)`), routed through `PythonRunner.runIsolated` so
/// the Python interpreter is only ever touched from its pinned thread (CLAUDE.md §15.1).
///
/// **Important:** every `PythonObject` we touch is extracted to Swift-native primitives
/// *inside* the `runIsolated` closure — that closure runs on the Python thread, which is
/// where PythonKit's reference counting is safe. Returning a `PythonObject` or capturing
/// one in a `Task { @MainActor in ... }` block would release it on the wrong thread and
/// crash inside `_PyInterpreterState_GET`. See `DownloadManager.runYoutubeDLDownload`'s
/// progress closure for the canonical "extract to primitives, ship primitives" pattern.
@available(iOS 17.0, *)
final class YtDlpInfoService: Sendable {
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "YtDlpInfoService")

    func probe(url: String) async throws -> RemoteMedia {
        log.info("[probe] start url=\(url, privacy: .public)")
        let startedAt = Date()
        do {
            log.info("[probe] calling PythonRunner.runIsolated…")
            let media = try await PythonRunner.shared.runIsolated { [log] () -> RemoteMedia in
                log.info("[probe] inside runIsolated; calling freetube_yt_dlp_extract_info")
                let info = try await freetube_yt_dlp_extract_info(url: url)
                log.info("[probe] freetube_yt_dlp_extract_info returned; converting to RemoteMedia")
                // For playlists yt-dlp returns `_type=playlist` with an `entries` array.
                // v1 treats playlists as "pick the first entry" because the UI doesn't render
                // a playlist picker yet. This matches the `--no-playlist` shape used elsewhere.
                //
                // CRITICAL: PythonObject's non-throwing subscript fatal-errors when a key is
                // absent (PythonKit Python.swift:579). For a typical single-video extract_info
                // result, `_type` and `entries` are simply missing — using the plain `info[…]`
                // subscript here would crash with `Could not access PythonObject element`. The
                // `.checking[…]` accessor returns `PythonObject?` instead. Every dict-key read
                // in `convert(...)` / `parseFormat(...)` follows the same pattern.
                let target: PythonObject = {
                    let typeStr = info.checking["_type"].flatMap(String.init) ?? ""
                    if typeStr == "playlist", let entries = info.checking["entries"] {
                        if let first = Array(entries).first { return first }
                    }
                    return info
                }()
                let result = Self.convert(info: target, originalURL: url)
                log.info("[probe] conversion done: title=\"\(result.title, privacy: .public)\" formats=\(result.formats.count, privacy: .public)")
                return result
            }
            let dur = Date().timeIntervalSince(startedAt)
            log.info("[probe] OK in \(String(format: "%.1f", dur), privacy: .public)s — \(media.formats.count, privacy: .public) formats title=\"\(media.title, privacy: .public)\"")
            return media
        } catch {
            log.error("[probe] failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    // MARK: - Python → Swift conversion

    /// Runs on the Python thread. Every value coming out of `info` is converted to a Swift
    /// primitive before the function returns; no PythonObject crosses the actor boundary.
    ///
    /// **Every dict access uses `.checking[key]`** — PythonKit's non-throwing subscript
    /// fatal-errors on missing keys, and yt-dlp's response shape varies wildly by extractor
    /// (a SoundCloud track has no `channel`; a generic image has no `formats`). A single
    /// missing key would crash the whole probe.
    private static func convert(info: PythonObject, originalURL: String) -> RemoteMedia {
        let id = info.checking["id"].flatMap(String.init) ?? UUID().uuidString
        let title = info.checking["title"].flatMap(String.init) ?? "(no title)"
        let uploader: String = {
            if let u = info.checking["uploader"].flatMap(String.init), !u.isEmpty { return u }
            if let u = info.checking["channel"].flatMap(String.init), !u.isEmpty { return u }
            return ""
        }()
        let webpageURLString = info.checking["webpage_url"].flatMap(String.init) ?? originalURL
        let thumbnailURLString = info.checking["thumbnail"].flatMap(String.init) ?? ""
        let duration = info.checking["duration"].flatMap(Double.init) ?? 0
        let isLive = info.checking["is_live"].flatMap(Bool.init) ?? false
        let descriptionText = info.checking["description"].flatMap(String.init) ?? ""
        let extractorKey = info.checking["extractor_key"].flatMap(String.init) ?? ""
        let extractorRaw = info.checking["extractor"].flatMap(String.init) ?? ""
        let extractor = !extractorKey.isEmpty ? extractorKey : extractorRaw

        let formatsRaw: [PythonObject] = {
            guard let raw = info.checking["formats"] else { return [] }
            return Array(raw)
        }()
        var formats: [RemoteFormat] = []
        formats.reserveCapacity(formatsRaw.count)
        for fmt in formatsRaw {
            if let parsed = parseFormat(fmt) {
                formats.append(parsed)
            }
        }
        // Stable sort: video formats by height ascending, audio formats by bitrate ascending,
        // unsupported at the bottom. UI flips this to descending for display.
        formats.sort { lhs, rhs in
            if lhs.protocolKind == RemoteFormat.ProtocolKind.unsupported && rhs.protocolKind != RemoteFormat.ProtocolKind.unsupported { return false }
            if lhs.protocolKind != RemoteFormat.ProtocolKind.unsupported && rhs.protocolKind == RemoteFormat.ProtocolKind.unsupported { return true }
            if lhs.isAudioOnly && !rhs.isAudioOnly { return false }
            if !lhs.isAudioOnly && rhs.isAudioOnly { return true }
            if lhs.isAudioOnly && rhs.isAudioOnly {
                return (lhs.abr ?? 0) < (rhs.abr ?? 0)
            }
            return (lhs.height ?? 0) < (rhs.height ?? 0)
        }

        // Subtitles deferred — model has the slot but v1 UI doesn't render or download them.
        // When we add a subtitle picker, lift this with `subsDict.checking.dictionary`.
        let subtitles: [RemoteSubtitle] = []

        return RemoteMedia(
            id: id,
            webpageURL: URL(string: webpageURLString),
            title: title,
            uploader: uploader.isEmpty ? nil : uploader,
            thumbnailURL: URL(string: thumbnailURLString),
            duration: duration > 0 ? duration : nil,
            isLive: isLive,
            formats: formats,
            subtitles: subtitles,
            descriptionText: descriptionText.isEmpty ? nil : descriptionText,
            extractor: extractor.isEmpty ? nil : extractor
        )
    }

    private static func parseFormat(_ fmt: PythonObject) -> RemoteFormat? {
        let id = fmt.checking["format_id"].flatMap(String.init) ?? ""
        guard !id.isEmpty else { return nil }

        let urlStr = fmt.checking["url"].flatMap(String.init) ?? ""
        let ext = fmt.checking["ext"].flatMap(String.init) ?? ""

        // yt-dlp uses the literal string "none" for absent codecs (audio-only formats have
        // vcodec="none"; video-only have acodec="none"). Normalize to Swift's nil.
        let vcodecRaw = fmt.checking["vcodec"].flatMap(String.init) ?? ""
        let acodecRaw = fmt.checking["acodec"].flatMap(String.init) ?? ""
        let vcodec: String? = (vcodecRaw == "none" || vcodecRaw.isEmpty) ? nil : vcodecRaw
        let acodec: String? = (acodecRaw == "none" || acodecRaw.isEmpty) ? nil : acodecRaw

        let widthRaw = fmt.checking["width"].flatMap(Int.init) ?? 0
        let heightRaw = fmt.checking["height"].flatMap(Int.init) ?? 0
        let fpsRaw = fmt.checking["fps"].flatMap(Double.init) ?? 0
        let vbrRaw = fmt.checking["vbr"].flatMap(Double.init) ?? 0
        let abrRaw = fmt.checking["abr"].flatMap(Double.init) ?? 0

        // `filesize` is preferred; `filesize_approx` is yt-dlp's estimate for streaming
        // formats. We treat either as good enough — the UI labels just say "≈ N MB".
        let sizeInt: Int64 = {
            if let s = fmt.checking["filesize"].flatMap(Int.init), s > 0 { return Int64(s) }
            if let s = fmt.checking["filesize_approx"].flatMap(Int.init), s > 0 { return Int64(s) }
            return 0
        }()

        let protocolStr = (fmt.checking["protocol"].flatMap(String.init) ?? "").lowercased()
        let protocolKind: RemoteFormat.ProtocolKind
        if protocolStr.contains("m3u8") {
            protocolKind = .hls
        } else if protocolStr.contains("dash") {
            protocolKind = .dash
        } else if protocolStr.hasPrefix("http") {
            protocolKind = .https
        } else {
            protocolKind = .unsupported
        }

        return RemoteFormat(
            id: id,
            url: URL(string: urlStr),
            ext: ext,
            width: widthRaw > 0 ? widthRaw : nil,
            height: heightRaw > 0 ? heightRaw : nil,
            fps: fpsRaw > 0 ? fpsRaw : nil,
            vcodec: vcodec,
            acodec: acodec,
            vbr: vbrRaw > 0 ? vbrRaw : nil,
            abr: abrRaw > 0 ? abrRaw : nil,
            filesize: sizeInt > 0 ? sizeInt : nil,
            protocolKind: protocolKind,
            rawProtocol: protocolStr
        )
    }
}
