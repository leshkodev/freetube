import Foundation
import OSLog
import YouTubeKit

/// Holds the single `YouTubeModel` instance the rest of the app talks to. Services depend on this
/// type for the model handle and for cookie application.
///
/// Per CLAUDE.md §6: `YouTubeKit` must not be imported anywhere outside `Core/Networking/`. Domain
/// types (Video, Channel, …) are mapped from YouTubeKit response types inside the services that
/// own each response.
nonisolated final class YouTubeKitClient: @unchecked Sendable {
    static let shared = YouTubeKitClient()

    /// Default iOS-client model. Returns HLS manifest URLs when available (great for music videos),
    /// but its per-format `/videoplayback` URLs are PoT-protected → segment fetches 403.
    let model = YouTubeModel()

    /// Alternate model identified as `TVHTML5_SIMPLY_EMBEDDED_PLAYER`. This client is exempt from
    /// YouTube's Proof-of-Origin-Token enforcement, so its `/videoplayback` URLs play without 403.
    /// Used as the fallback in `VideoService.fetchInfoViaTVHTML5(id:)` when the iOS client returns
    /// only PoT-protected adaptive streams. Shares the visitor token from `model` so YouTube treats
    /// them as the same anonymous session.
    let tvHtmlModel = YouTubeModel()

    private let log = AppLog(subsystem: "com.leshko.freetube", category: "YouTubeKitClient")

    private init() {
        installTVHTML5Overrides()
    }

    /// Replaces the `.videoInfos` request the default `YouTubeKitClient.tvHtmlModel` would otherwise
    /// build for the IOS client. Mirrors YouTubeKit's own `getFormatsHeaders()` structure but with
    /// the `TVHTML5_SIMPLY_EMBEDDED_PLAYER` payload that NewPipe / yt-dlp use to side-step PoT.
    private func installTVHTML5Overrides() {
        let bodyPrefix = #"{"context":{"client":{"clientName":"TVHTML5_SIMPLY_EMBEDDED_PLAYER","clientVersion":"2.0","clientScreen":"EMBED","platform":"TV","hl":"en","gl":"US","clientFormFactor":"UNKNOWN_FORM_FACTOR"},"thirdParty":{"embedUrl":"https://www.youtube.com/"}},"contentCheckOk":true,"racyCheckOk":true,"videoId":""#
        let headers = HeadersList(
            url: URL(string: "https://www.youtube.com/youtubei/v1/player")!,
            method: .POST,
            headers: [
                HeadersList.Header(name: "Accept", content: "*/*"),
                HeadersList.Header(name: "Accept-Encoding", content: "gzip, deflate, br"),
                HeadersList.Header(name: "Host", content: "www.youtube.com"),
                HeadersList.Header(name: "User-Agent", content: "Mozilla/5.0 (PlayStation; PlayStation 4/12.55) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Safari/605.1.15"),
                HeadersList.Header(name: "Content-Type", content: "application/json"),
                HeadersList.Header(name: "Origin", content: "https://www.youtube.com"),
                HeadersList.Header(name: "Referer", content: "https://www.youtube.com/")
            ],
            customHeaders: [
                "X-Goog-Visitor-Id": .visitorData
            ],
            addQueryAfterParts: [
                HeadersList.AddQueryInfo(index: 0, encode: false, content: .query)
            ],
            httpBody: [bodyPrefix, "\"}"],
            parameters: [
                HeadersList.ParameterToAdd(name: "prettyPrint", content: "false")
            ]
        )
        tvHtmlModel.customHeaders[.videoInfos] = headers
    }

    /// Current cookie header string as YouTubeKit holds it. Read-only mirror of
    /// `model.cookies` so callers outside this file don't have to touch YouTubeKit types
    /// directly (services without a YouTubeKit import — e.g. our raw-HTTP fallbacks — can
    /// still inject the auth header).
    var cookies: String { model.cookies }

    /// Drops the cached visitor token so the next request fetches a fresh one. Called by
    /// `SessionManager` after clearing cookies — the visitor token YouTube issued may have been
    /// tied to the now-expired auth.
    func clearVisitorData() {
        model.visitorData = ""
        tvHtmlModel.visitorData = ""
    }

    /// Pushes the latest cookie header string into `YouTubeModel`. Called by `SessionManager`.
    func applyCookies(_ cookies: String) {
        model.cookies = cookies
        model.alwaysUseCookies = !cookies.isEmpty
        tvHtmlModel.cookies = cookies
        tvHtmlModel.alwaysUseCookies = !cookies.isEmpty

        // Sanity-log the auth state. We never log cookie values themselves — only presence /
        // length — and we ask the model to compute SAPISIDHASH (without keeping the value) to
        // confirm YouTubeKit's auth-header generator agrees that the cookie set is usable.
        let hashOK = !cookies.isEmpty && model.generateSAPISIDHASHForCookies(cookies) != nil
        let containsSAPISID = cookies.range(of: "SAPISID=") != nil
        let containsSID = cookies.range(of: "; SID=") != nil || cookies.hasPrefix("SID=")
        log.info("[client] applyCookies length=\(cookies.count, privacy: .public) state=\(cookies.isEmpty ? "anon" : "auth", privacy: .public) alwaysUseCookies=\(self.model.alwaysUseCookies, privacy: .public) hasSAPISID=\(containsSAPISID, privacy: .public) hasSID=\(containsSID, privacy: .public) sapisidHashGenerable=\(hashOK, privacy: .public)")
    }

    /// `VideoInfosResponse` requires a `visitorData` token. YouTubeKit doesn't fetch one for you;
    /// the canonical way to obtain it (per `YouTubeModel.visitorData` docs) is to run a `SearchResponse`
    /// first and pull `visitorData` out of the response. We do that once at app bootstrap and stash
    /// the token on the shared model so subsequent video requests auto-inject it.
    func ensureVisitorData() async {
        guard model.visitorData.isEmpty else { return }
        do {
            let response = try await SearchResponse.sendThrowingRequest(
                youtubeModel: model,
                data: [.query: "music"]
            )
            if let visitorData = response.visitorData, !visitorData.isEmpty {
                model.visitorData = visitorData
                tvHtmlModel.visitorData = visitorData
                log.info("Visitor data bootstrapped")
            } else {
                log.error("SearchResponse returned no visitorData")
            }
        } catch {
            log.error("Visitor-data bootstrap failed: \(String(describing: error), privacy: .public)")
        }
    }
}
