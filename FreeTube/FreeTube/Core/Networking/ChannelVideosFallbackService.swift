import Foundation
import OSLog

/// Decodes a channel's Videos tab without going through YouTubeKit's parser. Used as a
/// fallback when YouTubeKit returns zero items for a tab that actually has videos.
///
/// **Why this exists.** `ChannelInfosResponse.Videos.decodeJSONFromTab` and
/// `decodeContinuation` only walk the legacy `richItemRenderer.content.videoRenderer` shape.
/// YouTube has been migrating channel surfaces to `lockupViewModel`; YouTubeKit added
/// lockup fallbacks to Home, Account library, History, MoreVideoInfo, Subscriptions feed —
/// but missed the channel Videos and Directs tabs. When a channel uses the new shape we'd
/// see an empty list while the header still reports the correct video count. Subclassing
/// isn't an option (the affected types are structs and the decoders are static methods),
/// so we duplicate just enough of the request + decode pipeline to cover the gap, and
/// keep YouTubeKit as the primary path.
///
/// **Continuation handoff.** When the initial fetch uses the fallback path we store the
/// continuation token on the actor-backed state map. `ChannelService.fetchVideosNextPage`
/// checks for a stored token before dispatching to YouTubeKit — if present, we route
/// pagination through our own decoder too. Mixing decoders mid-pagination would dead-end
/// at the same lockup gap on the very next page.
@available(iOS 17.0, *)
final class ChannelVideosFallbackService: Sendable {
    private let session: URLSession
    private let client: YouTubeKitClient
    private let state = State()
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "ChannelVideosFallback")

    init(client: YouTubeKitClient = .shared, session: URLSession = .shared) {
        self.client = client
        self.session = session
    }

    /// Per-channel continuation state. Keyed by channelID. Presence in the map also signals
    /// "this channel is on the fallback path" so subsequent `fetchVideosNextPage` calls in
    /// `ChannelService` know to route through us instead of YouTubeKit.
    private actor State {
        private var continuations: [String: String] = [:]
        func get(_ channelID: String) -> String? { continuations[channelID] }
        func set(_ channelID: String, token: String?) {
            if let token, !token.isEmpty {
                continuations[channelID] = token
            } else {
                continuations.removeValue(forKey: channelID)
            }
        }
        func contains(_ channelID: String) -> Bool { continuations[channelID] != nil }
    }

    /// True when a prior fetch handed off pagination to this fetcher for the given channel.
    /// `ChannelService.fetchVideosNextPage` calls this before dispatching to YouTubeKit.
    func hasPendingContinuation(channelID: String) async -> Bool {
        await state.contains(channelID)
    }

    /// Fetches the channel's Videos tab via a raw POST to youtubei/v1/browse and decodes
    /// items as either `videoRenderer` or `lockupViewModel`. Records the continuation token
    /// on the state map so subsequent pagination calls can route through `fetchContinuation`.
    func fetchVideos(channelID: String, params: String) async throws -> ChannelTab<Video> {
        let body = Self.initialBrowseBody(channelID: channelID, params: params)
        let result = try await sendBrowse(body: body, channelID: channelID, kind: "initial") { root in
            Self.decodeVideosTab(root: root, channelID: channelID)
        }
        await state.set(channelID, token: result.continuation)
        return ChannelTab(items: result.videos, continuationToken: result.continuation)
    }

    /// Fetches the next page of videos using the stored continuation token. Returns nil if
    /// no continuation is recorded (caller should fall through to YouTubeKit's path).
    func fetchContinuation(channelID: String) async throws -> ChannelTab<Video>? {
        guard let token = await state.get(channelID) else { return nil }
        let body = Self.continuationBody(token: token)
        let result = try await sendBrowse(body: body, channelID: channelID, kind: "continuation") { root in
            Self.decodeContinuation(root: root, channelID: channelID)
        }
        await state.set(channelID, token: result.continuation)
        return ChannelTab(items: result.videos, continuationToken: result.continuation)
    }

    // MARK: - Networking

    /// Single shared POST path used by both `fetchVideos` and `fetchContinuation`.
    private func sendBrowse(
        body: Data,
        channelID: String,
        kind: String,
        decode: (Any) -> (videos: [Video], continuation: String?)
    ) async throws -> (videos: [Video], continuation: String?) {
        let url = URL(string: "https://www.youtube.com/youtubei/v1/browse?prettyPrint=false")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.2 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        let cookies = client.cookies
        if !cookies.isEmpty {
            request.setValue(cookies, forHTTPHeaderField: "Cookie")
        }
        request.httpBody = body

        log.info("[channel-fallback] POST browse kind=\(kind, privacy: .public) channelID=\(channelID, privacy: .public)")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw YouTubeServiceError.network(error)
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            log.error("[channel-fallback] HTTP \(http.statusCode, privacy: .public) kind=\(kind, privacy: .public) for \(channelID, privacy: .public)")
            throw YouTubeServiceError.network(NSError(domain: "ChannelVideosFallback", code: http.statusCode))
        }

        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            log.error("[channel-fallback] JSON parse failed kind=\(kind, privacy: .public): \(String(describing: error), privacy: .public)")
            throw YouTubeServiceError.decoding(error)
        }

        let result = decode(root)
        log.info("[channel-fallback] decoded kind=\(kind, privacy: .public) videos=\(result.videos.count, privacy: .public) hasContinuation=\(result.continuation != nil, privacy: .public)")
        return result
    }

    // MARK: - Request bodies

    /// Initial-page body, shaped like YouTubeKit's `getChannelVideosHeaders`. Keep the
    /// `clientVersion` roughly in sync with YouTubeKit when you bump the package — large
    /// drift can make YouTube serve a degraded layout that this decoder doesn't cover.
    private static func initialBrowseBody(channelID: String, params: String) -> Data {
        let payload: [String: Any] = [
            "context": [
                "client": clientContext(),
                "user": ["lockedSafetyMode": false],
                "request": ["useSsl": true]
            ],
            "browseId": channelID,
            "params": params
        ]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }

    /// Continuation body, shaped like YouTubeKit's `channelContinuationHeaders`. Same
    /// endpoint as the initial fetch; the response shape is `onResponseReceivedActions[0]
    /// .appendContinuationItemsAction.continuationItems[]`.
    private static func continuationBody(token: String) -> Data {
        let payload: [String: Any] = [
            "context": [
                "client": clientContext(),
                "user": ["lockedSafetyMode": false],
                "request": ["useSsl": true]
            ],
            "continuation": token
        ]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }

    private static func clientContext() -> [String: Any] {
        [
            "clientName": "WEB",
            "clientVersion": "2.20260213.01.00",
            "deviceMake": "Apple",
            "userAgent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.2 Safari/605.1.15,gzip(gfe)",
            "osName": "Macintosh",
            "osVersion": "10_15_7",
            "platform": "DESKTOP",
            "clientFormFactor": "UNKNOWN_FORM_FACTOR",
            "browserName": "Safari",
            "browserVersion": "16.2"
        ]
    }

    // MARK: - Decoder

    /// Decodes a continuation response. Items live under
    /// `onResponseReceivedActions[0].appendContinuationItemsAction.continuationItems[]`.
    /// The very last item (or near-last) is typically the next-page `continuationItemRenderer`.
    private static func decodeContinuation(root: Any, channelID: String) -> (videos: [Video], continuation: String?) {
        guard
            let dict = root as? [String: Any],
            let actions = dict["onResponseReceivedActions"] as? [[String: Any]],
            let items = ((actions.first?["appendContinuationItemsAction"] as? [String: Any])?["continuationItems"]) as? [[String: Any]]
        else { return ([], nil) }

        return extractVideos(from: items, channelID: channelID)
    }

    /// Walks the response JSON to the Videos tab's items array and extracts videos.
    /// Accepts both `videoRenderer` (legacy) and `lockupViewModel` (current) shapes.
    private static func decodeVideosTab(root: Any, channelID: String) -> (videos: [Video], continuation: String?) {
        guard
            let dict = root as? [String: Any],
            let tabs = (dict["contents"] as? [String: Any])?["twoColumnBrowseResultsRenderer"]
                .flatMap({ ($0 as? [String: Any])?["tabs"] }) as? [[String: Any]]
        else { return ([], nil) }

        // Match the Videos tab by URL suffix; fall back to `selected: true` if URL is missing.
        // YouTube has been known to flip `selected` onto Home for atypical channels, so URL is
        // the more reliable signal when we sent `params=videos`.
        let videosTab = tabs.first { tab in
            guard let renderer = tab["tabRenderer"] as? [String: Any] else { return false }
            let url = (((renderer["endpoint"] as? [String: Any])?["commandMetadata"] as? [String: Any])?["webCommandMetadata"] as? [String: Any])?["url"] as? String
            return url?.hasSuffix("/videos") ?? false
        } ?? tabs.first { ($0["tabRenderer"] as? [String: Any])?["selected"] as? Bool == true }

        guard
            let renderer = videosTab?["tabRenderer"] as? [String: Any],
            let items = ((renderer["content"] as? [String: Any])?["richGridRenderer"] as? [String: Any])?["contents"] as? [[String: Any]]
        else { return ([], nil) }

        return extractVideos(from: items, channelID: channelID)
    }

    /// Shared per-item walker. Same shape on both the initial `richGridRenderer.contents`
    /// array and the continuation `appendContinuationItemsAction.continuationItems` array —
    /// each entry is either a `richItemRenderer` (carrying a video) or a
    /// `continuationItemRenderer` (carrying the next-page token).
    private static func extractVideos(from items: [[String: Any]], channelID: String) -> (videos: [Video], continuation: String?) {
        var videos: [Video] = []
        var continuation: String?
        for item in items {
            if let inner = (item["richItemRenderer"] as? [String: Any])?["content"] as? [String: Any] {
                if let r = inner["videoRenderer"] as? [String: Any],
                   let v = decodeVideoRenderer(r, channelID: channelID) {
                    videos.append(v)
                } else if let r = inner["lockupViewModel"] as? [String: Any],
                          let v = decodeLockupViewModel(r, channelID: channelID) {
                    videos.append(v)
                }
            } else if let cont = item["continuationItemRenderer"] as? [String: Any],
                      let token = (((cont["continuationEndpoint"] as? [String: Any])?["continuationCommand"] as? [String: Any])?["token"]) as? String {
                continuation = token
            }
        }
        return (videos, continuation)
    }

    /// Legacy `videoRenderer` extractor. Same fields YouTubeKit's `YTVideo.decodeJSON` reads.
    private static func decodeVideoRenderer(_ json: [String: Any], channelID: String) -> Video? {
        guard let videoID = json["videoId"] as? String else { return nil }

        let title: String = {
            if let simple = (json["title"] as? [String: Any])?["simpleText"] as? String { return simple }
            let runs = (json["title"] as? [String: Any])?["runs"] as? [[String: Any]] ?? []
            return runs.compactMap { $0["text"] as? String }.joined()
        }()

        let ownerRun = ((json["ownerText"] as? [String: Any])?["runs"] as? [[String: Any]])?.first
            ?? ((json["longBylineText"] as? [String: Any])?["runs"] as? [[String: Any]])?.first
            ?? ((json["shortBylineText"] as? [String: Any])?["runs"] as? [[String: Any]])?.first
        let channelName = ownerRun?["text"] as? String ?? ""
        let resolvedChannelID = (((ownerRun?["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any])?["browseId"] as? String) ?? channelID

        let thumb = ((json["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]])?
            .compactMap { $0["url"] as? String }.last.flatMap(URL.init(string:))
            ?? Mappers.canonicalThumbnailURL(for: videoID)

        let durationText = (json["lengthText"] as? [String: Any])?["simpleText"] as? String
        let viewText = (json["shortViewCountText"] as? [String: Any])?["simpleText"] as? String
            ?? ((json["shortViewCountText"] as? [String: Any])?["runs"] as? [[String: Any]])?
                .compactMap { $0["text"] as? String }.joined()
        let publishedRel = (json["publishedTimeText"] as? [String: Any])?["simpleText"] as? String

        return Video(
            id: videoID,
            title: title,
            channelID: resolvedChannelID,
            channelName: channelName,
            channelThumbnailURL: nil,
            thumbnailURL: thumb,
            duration: parseDuration(durationText),
            viewCount: Mappers.parseAbbreviatedCount(viewText),
            publishedAt: nil,
            publishedRelative: publishedRel,
            descriptionSnippet: nil,
            isLive: durationText == nil,
            isShort: false
        )
    }

    /// New `lockupViewModel` extractor. Mirrors the field traversal in YouTubeKit's
    /// `YTVideo.decodeLockupJSON` but produces our domain `Video` directly.
    private static func decodeLockupViewModel(_ json: [String: Any], channelID: String) -> Video? {
        guard
            let videoID = json["contentId"] as? String,
            (json["contentType"] as? String) == "LOCKUP_CONTENT_TYPE_VIDEO"
        else { return nil }

        let lockupMeta = (json["metadata"] as? [String: Any])?["lockupMetadataViewModel"] as? [String: Any]
        let title = ((lockupMeta?["title"] as? [String: Any])?["content"] as? String) ?? ""

        // metadataRows is an ordered list:
        //   [0] channel name (with WEB_PAGE_TYPE_CHANNEL link)
        //   [1] "N views • posted-ago"  (two parts)
        // We bucket each text into channel name / view count / time-posted based on the link
        // hint when present; otherwise fall back to "first non-channel = views, last = posted".
        let rows = ((lockupMeta?["metadata"] as? [String: Any])?["contentMetadataViewModel"] as? [String: Any])?["metadataRows"] as? [[String: Any]]
        var channelName = ""
        var viewsText: String?
        var publishedRel: String?
        for row in rows ?? [] {
            guard let parts = row["metadataParts"] as? [[String: Any]] else { continue }
            for part in parts {
                guard let textJSON = part["text"] as? [String: Any],
                      let content = textJSON["content"] as? String else { continue }
                let commandRuns = textJSON["commandRuns"] as? [[String: Any]]
                let webType = ((((commandRuns?.first?["onTap"] as? [String: Any])?["innertubeCommand"] as? [String: Any])?["commandMetadata"] as? [String: Any])?["webCommandMetadata"] as? [String: Any])?["webPageType"] as? String
                if webType == "WEB_PAGE_TYPE_CHANNEL" {
                    channelName = content
                } else if viewsText == nil {
                    viewsText = content
                } else {
                    publishedRel = content
                }
            }
        }

        let sources = (((json["contentImage"] as? [String: Any])?["thumbnailViewModel"] as? [String: Any])?["image"] as? [String: Any])?["sources"] as? [[String: Any]]
        let thumb = sources?.compactMap { $0["url"] as? String }.last.flatMap(URL.init(string:))
            ?? Mappers.canonicalThumbnailURL(for: videoID)

        // Duration: either thumbnailOverlayBadgeViewModel.thumbnailBadges[0]... or
        // thumbnailBottomOverlayViewModel.badges[0]... depending on which overlay variant
        // YouTube serves for the channel.
        let overlays = ((json["contentImage"] as? [String: Any])?["thumbnailViewModel"] as? [String: Any])?["overlays"] as? [[String: Any]]
        let durationText: String? = {
            for overlay in overlays ?? [] {
                if let badges = (overlay["thumbnailOverlayBadgeViewModel"] as? [String: Any])?["thumbnailBadges"] as? [[String: Any]],
                   let text = (badges.first?["thumbnailBadgeViewModel"] as? [String: Any])?["text"] as? String {
                    return text
                }
                if let badges = (overlay["thumbnailBottomOverlayViewModel"] as? [String: Any])?["badges"] as? [[String: Any]],
                   let text = (badges.first?["thumbnailBadgeViewModel"] as? [String: Any])?["text"] as? String {
                    return text
                }
            }
            return nil
        }()

        return Video(
            id: videoID,
            title: title,
            channelID: channelID,
            channelName: channelName,
            channelThumbnailURL: nil,
            thumbnailURL: thumb,
            duration: parseDuration(durationText),
            viewCount: Mappers.parseAbbreviatedCount(viewsText),
            publishedAt: nil,
            publishedRelative: publishedRel,
            descriptionSnippet: nil,
            isLive: durationText == nil,
            isShort: false
        )
    }

    /// "1:23" → 83, "1:02:03" → 3723. Returns nil for live / unparseable.
    private static func parseDuration(_ text: String?) -> TimeInterval? {
        guard let text, text != "live" else { return nil }
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }
        var seconds = 0
        for part in parts { seconds = seconds * 60 + part }
        return TimeInterval(seconds)
    }
}
