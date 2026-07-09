import Foundation
import Observation

@available(iOS 17.0, *)
@Observable
@MainActor
final class ChannelViewModel {
    /// Identifies which tab a paginated "load more" call should target. The first three resolve
    /// to the same backing array (the channel's `videos` tab) but are kept distinct so the menu's
    /// row labels are explicit.
    enum Tab: String, CaseIterable, Identifiable {
        case allVideos, popular, latest, shorts, directs, playlists
        var id: String { rawValue }
    }

    let channelID: String
    private(set) var details: ChannelDetails?
    private(set) var isLoading: Bool = false
    /// True while a per-tab continuation request is in flight. Used by the tab screen to avoid
    /// firing duplicate "load more" requests when the user is rapidly scrolling near the bottom.
    private(set) var isLoadingMore: [Tab: Bool] = [:]
    var errorState: ErrorState?

    private let service: any ChannelServicing
    private let subscriptions: any SubscriptionServicing

    init(
        channelID: String,
        service: any ChannelServicing = ChannelService(),
        subscriptions: any SubscriptionServicing = SubscriptionService()
    ) {
        self.channelID = channelID
        self.service = service
        self.subscriptions = subscriptions
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            details = try await service.fetchChannel(id: channelID)
        } catch {
            errorState = ErrorState(from: error)
        }
    }

    /// Toggles the user's subscription to this channel. Two-step state update:
    ///   1. Call the subscribe/unsubscribe API and update `SubscriptionRegistry` (the latter
    ///      happens inside the service).
    ///   2. **Optimistically flip the local `Channel.isSubscribed` immediately** rather than
    ///      waiting on a full `load()` round-trip. The reload is unreliable because YouTubeKit
    ///      can't always parse the new subscription state out of the channel response (the
    ///      modern `pageHeaderRenderer` layout puts it behind an entity-key indirection the
    ///      library doesn't follow). With the optimistic flip plus `SubscriptionRegistry`'s
    ///      persistent cache, the button stays correct even after fully closing and reopening
    ///      the channel later.
    func toggleSubscribe() async {
        guard let current = details else { return }
        let wasSubscribed = current.channel.isSubscribed
        do {
            if wasSubscribed {
                try await subscriptions.unsubscribe(channelID: current.channel.id)
            } else {
                try await subscriptions.subscribe(channelID: current.channel.id)
            }
            // Optimistic flip — rebuild `details` with the new state on the channel.
            let c = current.channel
            let updatedChannel = Channel(
                id: c.id,
                name: c.name,
                handle: c.handle,
                thumbnailURL: c.thumbnailURL,
                bannerURL: c.bannerURL,
                subscriberCount: c.subscriberCount,
                videoCount: c.videoCount,
                isSubscribed: !wasSubscribed,
                descriptionText: c.descriptionText
            )
            details = ChannelDetails(
                channel: updatedChannel,
                videos: current.videos,
                shorts: current.shorts,
                directs: current.directs,
                playlists: current.playlists
            )
        } catch {
            errorState = ErrorState(from: error)
        }
    }

    /// True when YouTubeKit still has a continuation token for the underlying tab. The three
    /// videos-derived tabs (allVideos/popular/latest) share the same backing token.
    func canLoadMore(for tab: Tab) -> Bool {
        guard let details else { return false }
        if isLoadingMore[tab] == true { return false }
        switch tab {
        case .allVideos, .popular, .latest:
            return details.videos.continuationToken != nil
        case .shorts:
            return details.shorts.continuationToken != nil
        case .directs:
            return details.directs.continuationToken != nil
        case .playlists:
            return details.playlists.continuationToken != nil
        }
    }

    /// Appends the next page of items for the given tab onto `details`. SwiftUI views observing
    /// `details` re-render automatically because we replace the whole struct (and `@Observable`
    /// tracks the property).
    func loadMore(for tab: Tab) async {
        guard canLoadMore(for: tab), let current = details else { return }
        isLoadingMore[tab] = true
        defer { isLoadingMore[tab] = false }
        do {
            switch tab {
            case .allVideos, .popular, .latest:
                let next = try await service.fetchVideosNextPage(channelID: channelID)
                details = current.appendingVideos(next)
            case .shorts:
                let next = try await service.fetchShortsNextPage(channelID: channelID)
                details = current.appendingShorts(next)
            case .directs:
                let next = try await service.fetchDirectsNextPage(channelID: channelID)
                details = current.appendingDirects(next)
            case .playlists:
                let next = try await service.fetchPlaylistsNextPage(channelID: channelID)
                details = current.appendingPlaylists(next)
            }
        } catch {
            errorState = ErrorState(from: error)
        }
    }
}

private extension ChannelDetails {
    func appendingVideos(_ page: ChannelTab<Video>) -> ChannelDetails {
        ChannelDetails(
            channel: channel,
            videos: ChannelTab(items: videos.items + page.items, continuationToken: page.continuationToken),
            shorts: shorts,
            directs: directs,
            playlists: playlists
        )
    }
    func appendingShorts(_ page: ChannelTab<Video>) -> ChannelDetails {
        ChannelDetails(
            channel: channel,
            videos: videos,
            shorts: ChannelTab(items: shorts.items + page.items, continuationToken: page.continuationToken),
            directs: directs,
            playlists: playlists
        )
    }
    func appendingDirects(_ page: ChannelTab<Video>) -> ChannelDetails {
        ChannelDetails(
            channel: channel,
            videos: videos,
            shorts: shorts,
            directs: ChannelTab(items: directs.items + page.items, continuationToken: page.continuationToken),
            playlists: playlists
        )
    }
    func appendingPlaylists(_ page: ChannelTab<Playlist>) -> ChannelDetails {
        ChannelDetails(
            channel: channel,
            videos: videos,
            shorts: shorts,
            directs: directs,
            playlists: ChannelTab(items: playlists.items + page.items, continuationToken: page.continuationToken)
        )
    }
}
