import Foundation
import AVFoundation
import OSLog

/// `AVAssetResourceLoaderDelegate` that proxies every HLS request (manifest + variant playlists +
/// every .ts/.mp4 segment) through a `URLSession` we control, so we can attach a consistent
/// `User-Agent` (and any other headers) to *all* of them.
///
/// Why this exists: `AVURLAssetHTTPHeaderFieldsKey` only applies to the initial manifest request.
/// `AVPlayer`'s internal URLSession issues segment requests with the system default UA
/// (`AppleCoreMedia/…`). YouTube's CDN signs the HLS playlist for a specific UA/IP, so a UA
/// mismatch between manifest and segments causes every segment to 403. By routing through the
/// resource loader we put every request on the same URLSession with the same headers.
///
/// How the URL rewriting works:
/// 1. Caller turns `https://manifest.googlevideo.com/...` into `freetubehls://manifest.googlevideo.com/...`
///    via `HLSResourceLoaderDelegate.rewrite(_:)` and hands it to `AVURLAsset`.
/// 2. AVPlayer requests the custom-scheme URL → `shouldWaitForLoadingOfRequestedResource` fires.
/// 3. We restore the original `https` scheme, perform the request with our headers, parse the body.
/// 4. For `.m3u8` responses we rewrite every absolute URL in the playlist back to the custom scheme,
///    so AVPlayer's subsequent segment requests also flow through this delegate.
@available(iOS 17.0, *)
final class HLSResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {
    static let customScheme = "freetubehls"

    private let userAgent: String
    private let session: URLSession
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "HLSLoader")

    init(userAgent: String) {
        self.userAgent = userAgent
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
        super.init()
    }

    /// Replaces the URL's scheme with our custom one so AVPlayer routes its requests through us.
    ///
    /// IMPORTANT: this is implemented via direct string surgery, NOT via `URLComponents`. YouTube's
    /// signed `googlevideo.com` URLs encode their signature into the query string, and `URLComponents`
    /// will silently re-encode characters like `%2C` (comma) on round-trip. Any re-encoding makes the
    /// CDN's signature check fail with HTTP 403. Preserving the exact byte sequence is mandatory.
    static func rewrite(_ url: URL) -> URL? {
        let s = url.absoluteString
        if s.hasPrefix("https://") {
            return URL(string: "\(customScheme)+https://" + s.dropFirst("https://".count))
        }
        if s.hasPrefix("http://") {
            return URL(string: "\(customScheme)+http://" + s.dropFirst("http://".count))
        }
        return nil
    }

    private static func restoreScheme(_ url: URL) -> URL? {
        let s = url.absoluteString
        let httpsPrefix = "\(customScheme)+https://"
        let httpPrefix = "\(customScheme)+http://"
        if s.hasPrefix(httpsPrefix) {
            return URL(string: "https://" + s.dropFirst(httpsPrefix.count))
        }
        if s.hasPrefix(httpPrefix) {
            return URL(string: "http://" + s.dropFirst(httpPrefix.count))
        }
        return nil
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard
            let requestedURL = loadingRequest.request.url,
            requestedURL.scheme?.hasPrefix(Self.customScheme) == true,
            let realURL = Self.restoreScheme(requestedURL)
        else {
            return false
        }

        Task { await handle(loadingRequest: loadingRequest, realURL: realURL) }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        // The URLSession data task will finish on its own; we just won't ship the bytes anywhere.
    }

    // MARK: - Request handling

    private func handle(loadingRequest: AVAssetResourceLoadingRequest, realURL: URL) async {
        var request = URLRequest(url: realURL)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        log.debug("→ GET \(realURL.absoluteString, privacy: .public)")

        // Honor any byte-range the player asked for. AVPlayer issues ranged GETs for media segments;
        // for the playlist itself we typically get an "all bytes" request.
        var rangeHeader: String?
        if let dataRequest = loadingRequest.dataRequest {
            let offset = dataRequest.requestedOffset
            if dataRequest.requestsAllDataToEndOfResource {
                if offset > 0 { rangeHeader = "bytes=\(offset)-" }
            } else {
                let length = max(dataRequest.requestedLength, 1)
                let end = offset + Int64(length) - 1
                rangeHeader = "bytes=\(offset)-\(end)"
            }
            if let rangeHeader {
                request.setValue(rangeHeader, forHTTPHeaderField: "Range")
            }
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                log.error("← non-HTTP response for \(realURL.absoluteString.prefix(100), privacy: .public)")
                loadingRequest.finishLoading(with: URLError(.badServerResponse))
                return
            }

            log.debug("← HTTP \(http.statusCode, privacy: .public) mime=\(http.mimeType ?? "?", privacy: .public) bytes=\(data.count, privacy: .public) range=\(rangeHeader ?? "(full)", privacy: .public) url=\(realURL.absoluteString.prefix(100), privacy: .public)")

            if http.statusCode >= 400 {
                log.error("HTTP \(http.statusCode, privacy: .public) for \(realURL.absoluteString.prefix(120), privacy: .public)")
                loadingRequest.finishLoading(with: NSError(
                    domain: "HLSLoaderHTTP",
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) from \(realURL.host ?? "?")"]
                ))
                return
            }

            let mime = http.mimeType ?? ""
            let isPlaylist = mime.contains("mpegurl") || mime.contains("m3u8")
                || realURL.path.hasSuffix(".m3u8")

            // Rewrite m3u8 contents so segment URLs in the playlist also use our custom scheme.
            // Then every segment fetch comes back to us, preserving the same UA + auth context.
            let outgoing: Data
            if isPlaylist, let text = String(data: data, encoding: .utf8) {
                outgoing = rewriteManifest(text).data(using: .utf8) ?? data
            } else {
                outgoing = data
            }

            if let contentInfo = loadingRequest.contentInformationRequest {
                contentInfo.contentType = mime
                contentInfo.isByteRangeAccessSupported = !isPlaylist
                // For ranged responses, contentLength is the FULL resource length, not the slice
                // we just received; parse from Content-Range when present.
                if let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
                   let totalString = contentRange.split(separator: "/").last,
                   let total = Int64(totalString) {
                    contentInfo.contentLength = total
                } else {
                    contentInfo.contentLength = Int64(outgoing.count)
                }
            }

            loadingRequest.dataRequest?.respond(with: outgoing)
            loadingRequest.finishLoading()
        } catch {
            log.error("Fetch failed for \(realURL.absoluteString.prefix(120), privacy: .public): \(String(describing: error), privacy: .public)")
            loadingRequest.finishLoading(with: error)
        }
    }

    /// Walks the m3u8 line-by-line, rewriting absolute URLs (both standalone lines and quoted
    /// `URI="…"` attributes inside `#EXT-X-MEDIA` / `#EXT-X-MAP` / `#EXT-X-KEY`) from `https://`
    /// to our custom scheme. Relative paths are left alone — AVPlayer resolves them against the
    /// (already rewritten) playlist's own URL, so they'll inherit the custom scheme.
    private func rewriteManifest(_ manifest: String) -> String {
        manifest.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)

            // Standalone URL line (segment or sub-playlist reference).
            if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
                if let url = URL(string: trimmed), let rewritten = Self.rewrite(url) {
                    return rewritten.absoluteString
                }
            }

            // Tag lines that embed URIs as quoted attributes.
            if trimmed.hasPrefix("#") && trimmed.contains("URI=\"") {
                return rewriteURIAttributes(in: String(line))
            }

            return String(line)
        }
        .joined(separator: "\n")
    }

    private func rewriteURIAttributes(in line: String) -> String {
        var result = ""
        var remainder = Substring(line)
        let marker = "URI=\""
        while let markerRange = remainder.range(of: marker) {
            result.append(String(remainder[..<markerRange.upperBound]))
            remainder = remainder[markerRange.upperBound...]
            guard let closing = remainder.firstIndex(of: "\"") else {
                result.append(String(remainder))
                return result
            }
            let urlText = String(remainder[..<closing])
            if let url = URL(string: urlText), let rewritten = Self.rewrite(url) {
                result.append(rewritten.absoluteString)
            } else {
                result.append(urlText)
            }
            remainder = remainder[closing...]
        }
        result.append(String(remainder))
        return result
    }
}
