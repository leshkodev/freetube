import Foundation
import OSLog
import YouTubeKit

struct ChannelTab<Item: Sendable>: Sendable {
    let items: [Item]
    let continuationToken: String?
}

struct ChannelDetails: Sendable {
    let channel: Channel
    let videos: ChannelTab<Video>
    let shorts: ChannelTab<Video>
    let directs: ChannelTab<Video>
    let playlists: ChannelTab<Playlist>
}

protocol ChannelServicing: Sendable {
    func fetchChannel(id: String) async throws -> ChannelDetails
    func fetchVideosNextPage(channelID: String) async throws -> ChannelTab<Video>
    func fetchShortsNextPage(channelID: String) async throws -> ChannelTab<Video>
    func fetchDirectsNextPage(channelID: String) async throws -> ChannelTab<Video>
    func fetchPlaylistsNextPage(channelID: String) async throws -> ChannelTab<Playlist>
}

/// Wraps `YouTubeKit.ChannelInfosResponse` and its per-tab subtypes.
///
/// **Flow:** `fetchChannel(id:)` sends one base request → response includes the channel header
/// (name, handle, avatar, banner, subscriber count, description) AND the default tab's payload
/// (usually `videos`). For the other tabs we issue per-tab fetches via the response's
/// `getChannelContentThrowing(forType:)` helper, which YouTubeKit short-circuits to a per-tab
/// browse endpoint.
///
/// **Pagination:** the original `ChannelInfosResponse` instance is cached in an internal actor
/// keyed by channelID — YouTubeKit's continuation API (`getChannelContentContinuationThrowing`)
/// is a method on the response, not a free function, so we have to keep the instance alive across
/// "load more" calls. The cache is cleared when `fetchChannel` reloads the same channelID.
final class ChannelService: ChannelServicing {
    private let client: YouTubeKitClient
    private let videosFallback: ChannelVideosFallbackService
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "ChannelService")

    /// Caches the live `ChannelInfosResponse` per channel so continuation calls can hit it. Actor
    /// isolation keeps reads/writes safe across concurrent pagination requests.
    private actor ResponseCache {
        private var cache: [String: ChannelInfosResponse] = [:]
        func get(_ id: String) -> ChannelInfosResponse? { cache[id] }
        func set(_ id: String, _ response: ChannelInfosResponse) { cache[id] = response }
    }
    private let cache = ResponseCache()

    nonisolated init(client: YouTubeKitClient = .shared) {
        self.client = client
        self.videosFallback = ChannelVideosFallbackService(client: client)
    }

    func fetchChannel(id: String) async throws -> ChannelDetails {
        log.info("fetchChannel(\(id, privacy: .public))")
        let response: ChannelInfosResponse
        do {
            response = try await ChannelInfosResponse.sendThrowingRequest(
                youtubeModel: client.model,
                data: [.browseId: id]
            )
        } catch {
            log.error("ChannelInfosResponse failed for \(id, privacy: .public): \(String(describing: error), privacy: .public)")
            throw YouTubeServiceError.network(error)
        }

        let channel = mapChannel(from: response, channelID: id)

        // Issue all four tab fetches concurrently. Each helper short-circuits when the base
        // response already contains the tab's data; otherwise it sends an extra browse request
        // for just that tab. The returned `merged` response carries all four tabs' data and
        // continuation tokens, which we hand to the cache so pagination can reuse it.
        async let videosResult = fetchSecondaryTab(response: response, type: .videos, channelID: id)
        async let shortsResult = fetchSecondaryTab(response: response, type: .shorts, channelID: id)
        async let directsResult = fetchSecondaryTab(response: response, type: .directs, channelID: id)
        async let playlistsResult = fetchSecondaryTab(response: response, type: .playlists, channelID: id)

        let (videosTab, shortsTab, directsTab, playlistsTab) = await (videosResult, shortsResult, directsResult, playlistsResult)

        // Build a merged response that owns the unified channelContentStore. Pagination calls
        // operate on this merged instance — that's why we can't just throw away the per-tab
        // results after extracting their items.
        var merged = response
        merge(into: &merged, from: videosTab.source)
        merge(into: &merged, from: shortsTab.source)
        merge(into: &merged, from: directsTab.source)
        merge(into: &merged, from: playlistsTab.source)
        await cache.set(id, merged)

        return ChannelDetails(
            channel: channel,
            videos: videosTab.videoTab,
            shorts: shortsTab.videoTab,
            directs: directsTab.videoTab,
            playlists: extractPlaylistTab(from: merged)
        )
    }

    // MARK: - Pagination

    func fetchVideosNextPage(channelID: String) async throws -> ChannelTab<Video> {
        // If the initial fetch handed off to our fallback decoder, keep pagination on the same
        // path — YouTubeKit's continuation decoder has the same lockup gap as the initial one,
        // and mixing decoders mid-paginate would dead-end at the next page.
        if await videosFallback.hasPendingContinuation(channelID: channelID) {
            if let tab = try await videosFallback.fetchContinuation(channelID: channelID) {
                return tab
            }
        }
        return try await fetchVideoContinuation(channelID: channelID, type: ChannelInfosResponse.Videos.self, requestType: .videos)
    }

    func fetchShortsNextPage(channelID: String) async throws -> ChannelTab<Video> {
        try await fetchVideoContinuation(channelID: channelID, type: ChannelInfosResponse.Shorts.self, requestType: .shorts)
    }

    func fetchDirectsNextPage(channelID: String) async throws -> ChannelTab<Video> {
        try await fetchVideoContinuation(channelID: channelID, type: ChannelInfosResponse.Directs.self, requestType: .directs)
    }

    func fetchPlaylistsNextPage(channelID: String) async throws -> ChannelTab<Playlist> {
        guard var response = await cache.get(channelID) else {
            throw YouTubeServiceError.unknown(NSError(domain: "ChannelService", code: -2, userInfo: [NSLocalizedDescriptionKey: "No cached channel response"]))
        }
        guard let token = response.channelContentContinuationStore[.playlists] ?? nil, !token.isEmpty else {
            return ChannelTab(items: [], continuationToken: nil)
        }
        let continuation: ChannelInfosResponse.ContentContinuation<ChannelInfosResponse.Playlists>
        do {
            continuation = try await response.getChannelContentContinuationThrowing(ChannelInfosResponse.Playlists.self, youtubeModel: client.model)
        } catch {
            log.error("playlist continuation failed: \(String(describing: error), privacy: .public)")
            throw YouTubeServiceError.network(error)
        }
        response.mergeListableChannelContentContinuation(continuation)
        await cache.set(channelID, response)

        let newItems = (continuation.contents?.items ?? []).compactMap { ($0 as? YTPlaylist).map(Mappers.playlist(from:)) }
        return ChannelTab(items: newItems, continuationToken: continuation.newContinuationToken)
    }

    /// Generic video-tab continuation. Caller supplies the concrete YouTubeKit type
    /// (Videos / Shorts / Directs) so the generic method dispatches to the right decoder.
    private func fetchVideoContinuation<T: ListableChannelContent>(
        channelID: String,
        type: T.Type,
        requestType: ChannelInfosResponse.RequestTypes
    ) async throws -> ChannelTab<Video> {
        guard var response = await cache.get(channelID) else {
            throw YouTubeServiceError.unknown(NSError(domain: "ChannelService", code: -2, userInfo: [NSLocalizedDescriptionKey: "No cached channel response"]))
        }
        guard let token = response.channelContentContinuationStore[requestType] ?? nil, !token.isEmpty else {
            return ChannelTab(items: [], continuationToken: nil)
        }
        let continuation: ChannelInfosResponse.ContentContinuation<T>
        do {
            continuation = try await response.getChannelContentContinuationThrowing(T.self, youtubeModel: client.model)
        } catch {
            log.error("\(String(describing: requestType), privacy: .public) continuation failed: \(String(describing: error), privacy: .public)")
            throw YouTubeServiceError.network(error)
        }
        response.mergeListableChannelContentContinuation(continuation)
        await cache.set(channelID, response)

        let channelName = response.name ?? ""
        let channelID2 = response.channelId ?? channelID
        let channelThumb = Mappers.bestThumbnailURL(response.avatarThumbnails)
        let newVideos: [Video] = (continuation.contents?.items ?? []).compactMap { item -> Video? in
            guard let yt = item as? YTVideo else { return nil }
            let v = Mappers.video(from: yt)
            return Video(
                id: v.id,
                title: v.title,
                channelID: v.channelID.isEmpty ? channelID2 : v.channelID,
                channelName: v.channelName.isEmpty ? channelName : v.channelName,
                channelThumbnailURL: v.channelThumbnailURL ?? channelThumb,
                thumbnailURL: v.thumbnailURL,
                duration: v.duration,
                viewCount: v.viewCount,
                publishedAt: v.publishedAt,
                publishedRelative: v.publishedRelative,
                descriptionSnippet: v.descriptionSnippet,
                isLive: v.isLive,
                isShort: requestType == .shorts
            )
        }
        return ChannelTab(items: newVideos, continuationToken: continuation.newContinuationToken)
    }

    // MARK: - Mapping helpers

    private func mapChannel(from response: ChannelInfosResponse, channelID: String) -> Channel {
        let id = response.channelId ?? channelID
        let name = response.name ?? ""
        let handle = response.handle
        let thumb = Mappers.bestThumbnailURL(response.avatarThumbnails)
        let banner = Mappers.bestThumbnailURL(response.bannerThumbnails)
        let subCount = Mappers.parseAbbreviatedCount(response.subscriberCount)
        let videoCount = Int((response.videoCount ?? "").filter(\.isNumber))
        // **isSubscribed source priority:**
        //   1. `SubscriptionRegistry` — our local cache of channel IDs the user has subscribed
        //      to. Updated on every subscribe/unsubscribe call and on `SubscribedChannelsScreen`
        //      load. Trusted because we own it.
        //   2. `response.subscribeStatus` — YouTubeKit's parser. Unreliable on the modern
        //      `pageHeaderRenderer` channel layout (the field comes back nil), but valid when
        //      present, so we OR it in as a fallback.
        // Defaulting to `false` only when both signals are absent fixes the long-standing bug
        // where the channel screen always showed "Subscribe" regardless of subscription state.
        let registryHit = SubscriptionRegistry.containsBypassActor(id)
        let parsed = response.subscribeStatus ?? false
        let isSubscribed = registryHit || parsed
        log.debug("[channel] mapChannel \(id, privacy: .public) — registry=\(registryHit, privacy: .public) parsed=\(parsed, privacy: .public) → isSubscribed=\(isSubscribed, privacy: .public)")
        return Channel(
            id: id,
            name: name,
            handle: handle,
            thumbnailURL: thumb,
            bannerURL: banner,
            subscriberCount: subCount,
            videoCount: videoCount,
            isSubscribed: isSubscribed,
            descriptionText: response.shortDescription
        )
    }

    /// Pulls a tab's items out of `channelContentStore`, mapping each `YTVideo` to our domain
    /// `Video`. Returns an empty `ChannelTab` if YouTubeKit hasn't populated that tab — or if the
    /// stored value isn't a `ListableChannelContent` (only listable subtypes expose `.items`).
    ///
    /// Backfills `channelName` and `channelID` from the response header onto each video. Shorts
    /// in particular are decoded via `decodeShortFromLockupJSON`, which doesn't carry channel info
    /// — without this backfill every shorts row would show an empty channel name.
    private func extractVideoTab(from response: ChannelInfosResponse, type: ChannelInfosResponse.RequestTypes) -> ChannelTab<Video> {
        guard let content = response.channelContentStore[type] as? (any ListableChannelContent) else {
            log.notice("[channel] extractVideoTab \(String(describing: type), privacy: .public) — store entry missing or not ListableChannelContent")
            return ChannelTab(items: [], continuationToken: nil)
        }
        let channelName = response.name ?? ""
        let channelID = response.channelId ?? ""
        let channelThumb = Mappers.bestThumbnailURL(response.avatarThumbnails)
        let videos: [Video] = content.items.compactMap { item -> Video? in
            guard let yt = item as? YTVideo else { return nil }
            let v = Mappers.video(from: yt)
            return Video(
                id: v.id,
                title: v.title,
                channelID: v.channelID.isEmpty ? channelID : v.channelID,
                channelName: v.channelName.isEmpty ? channelName : v.channelName,
                channelThumbnailURL: v.channelThumbnailURL ?? channelThumb,
                thumbnailURL: v.thumbnailURL,
                duration: v.duration,
                viewCount: v.viewCount,
                publishedAt: v.publishedAt,
                publishedRelative: v.publishedRelative,
                descriptionSnippet: v.descriptionSnippet,
                isLive: v.isLive,
                isShort: type == .shorts
            )
        }
        // Trace decode rate so we can spot future YouTubeKit decoder gaps (e.g. when YouTube
        // rolls out a new renderer that drops items silently — same class of bug as the
        // missing lockupViewModel fallback in Videos/Directs tabs).
        if content.items.count != videos.count {
            log.notice("[channel] extractVideoTab \(String(describing: type), privacy: .public) — raw=\(content.items.count, privacy: .public) decoded=\(videos.count, privacy: .public) (some items dropped)")
        }
        let continuation = response.channelContentContinuationStore[type] ?? nil
        return ChannelTab(items: videos, continuationToken: continuation)
    }

    private func extractPlaylistTab(from response: ChannelInfosResponse) -> ChannelTab<Playlist> {
        guard let content = response.channelContentStore[.playlists] as? (any ListableChannelContent) else {
            return ChannelTab(items: [], continuationToken: nil)
        }
        let playlists = content.items.compactMap { ($0 as? YTPlaylist).map(Mappers.playlist(from:)) }
        let continuation = response.channelContentContinuationStore[.playlists] ?? nil
        return ChannelTab(items: playlists, continuationToken: continuation)
    }

    /// One unified entry point for the four secondary tab fetches. Returns the tab data as a
    /// `ChannelTab<Video>` (callers reading playlists ignore this) PLUS the `source` response
    /// that produced it — we need the latter to merge back into the cached response so
    /// pagination tokens for ALL tabs are in one place.
    private struct SecondaryFetchResult {
        let videoTab: ChannelTab<Video>
        let source: ChannelInfosResponse
    }

    private func fetchSecondaryTab(
        response: ChannelInfosResponse,
        type: ChannelInfosResponse.RequestTypes,
        channelID: String
    ) async -> SecondaryFetchResult {
        let primary: SecondaryFetchResult
        if response.channelContentStore[type] != nil {
            primary = SecondaryFetchResult(videoTab: extractVideoTab(from: response, type: type), source: response)
        } else {
            // For some channels the base response doesn't include tab links with their `params`
            // payload (e.g. when YouTube serves only a Home tab in the initial browse). YouTubeKit's
            // `getChannelContent` requires `requestParams[type]` and otherwise errors with
            // "Something between returnType or params haven't been added". We inject YouTube's
            // well-known per-tab params strings so the request can still go through — these are
            // global constants in YouTube's protocol, not per-channel values.
            var mutable = response
            if mutable.requestParams[type] == nil, let fallback = Self.fallbackTabParams[type] {
                mutable.requestParams[type] = fallback
            }
            do {
                let updated = try await mutable.getChannelContentThrowing(forType: type, youtubeModel: client.model)
                primary = SecondaryFetchResult(videoTab: extractVideoTab(from: updated, type: type), source: updated)
            } catch {
                log.notice("fetchSecondaryTab(\(channelID, privacy: .public), \(String(describing: type), privacy: .public)) skipped: \(String(describing: error), privacy: .public)")
                primary = SecondaryFetchResult(videoTab: ChannelTab(items: [], continuationToken: nil), source: response)
            }
        }

        // **Fallback path.** YouTubeKit's Videos/Directs tab decoder only walks the legacy
        // `videoRenderer` shape. When YouTube serves a channel's tab as `lockupViewModel`,
        // YouTubeKit silently produces zero items. Our own decoder (§ChannelVideosFallbackService)
        // covers both shapes. We only run it for `.videos` because that's the tab that surfaces
        // the bug the most in practice; Directs has the same gap but live-stream channels are
        // rare enough that we leave it alone until the fix gets exercised here first.
        if type == .videos, primary.videoTab.items.isEmpty, let params = Self.fallbackTabParams[type] {
            log.notice("[channel] YouTubeKit returned 0 videos for \(channelID, privacy: .public); trying ChannelVideosFallbackService")
            do {
                let tab = try await videosFallback.fetchVideos(channelID: channelID, params: params)
                if !tab.items.isEmpty {
                    return SecondaryFetchResult(videoTab: tab, source: primary.source)
                }
            } catch {
                log.error("[channel] fallback fetch failed for \(channelID, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        return primary
    }

    /// YouTube uses a fixed `params` value per channel tab type — they encode "request the X
    /// sub-tab" generically. These have been stable for years and are the same fallbacks used
    /// by yt-dlp / Invidious when scraping channel responses that lack the tab links.
    private static let fallbackTabParams: [ChannelInfosResponse.RequestTypes: String] = [
        .videos: "EgZ2aWRlb3PyBgQKAjoA",
        .shorts: "EgZzaG9ydHPyBgUKA5oBAA%3D%3D",
        .directs: "EgdzdHJlYW1z8gYECgJ6AA%3D%3D",
        .playlists: "EglwbGF5bGlzdHPyBgQKAkIA"
    ]

    /// Folds the per-tab response's store + continuation token into the primary response so
    /// continuation calls dispatched against the primary response know about every tab.
    private func merge(into target: inout ChannelInfosResponse, from source: ChannelInfosResponse) {
        for (key, value) in source.channelContentStore {
            target.channelContentStore[key] = value
        }
        for (key, value) in source.channelContentContinuationStore {
            target.channelContentContinuationStore[key] = value
        }
    }
}
