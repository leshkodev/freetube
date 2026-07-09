import Foundation
import OSLog
import YouTubeKit

struct SubscriptionFeed: Sendable {
    let videos: [Video]
    let continuationToken: String?
}

struct SubscriptionsPage: Sendable {
    let channels: [Channel]
    let continuationToken: String?
}

protocol SubscriptionServicing: Sendable {
    func fetchFeed() async throws -> SubscriptionFeed
    func fetchSubscriptions() async throws -> [Channel]
    func fetchSubscriptionsPage() async throws -> SubscriptionsPage
    func fetchSubscriptionsMore(continuation: String) async throws -> SubscriptionsPage
    func subscribe(channelID: String) async throws
    func unsubscribe(channelID: String) async throws
}

/// Wraps `AccountSubscriptionsFeedResponse`, `AccountSubscriptionsResponse`,
/// `SubscribeChannelResponse`, `UnsubscribeChannelResponse`.
final class SubscriptionService: SubscriptionServicing {
    private let client: YouTubeKitClient
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "SubscriptionService")

    nonisolated init(client: YouTubeKitClient = .shared) {
        self.client = client
    }

    func fetchFeed() async throws -> SubscriptionFeed {
        log.info("Fetching subscriptions feed")
        throw YouTubeServiceError.notAuthenticated
    }

    func fetchSubscriptions() async throws -> [Channel] {
        try await fetchSubscriptionsPage().channels
    }

    /// First page of the user's subscribed channels. Uses `AccountSubscriptionsResponse`, which
    /// returns up to ~30 channels per page plus a continuation token for the next batch.
    func fetchSubscriptionsPage() async throws -> SubscriptionsPage {
        log.info("[subs] fetchSubscriptionsPage")
        do {
            let response = try await AccountSubscriptionsResponse.sendThrowingRequest(
                youtubeModel: client.model,
                data: [:]
            )
            if response.isDisconnected {
                log.notice("[subs] fetchSubscriptionsPage: response isDisconnected=true")
                throw YouTubeServiceError.notAuthenticated
            }
            let channels = response.results.map(Mappers.channel(from:))
            log.info("[subs] fetchSubscriptionsPage: \(channels.count, privacy: .public) channels, more=\(response.continuationToken != nil, privacy: .public)")
            return SubscriptionsPage(channels: channels, continuationToken: response.continuationToken)
        } catch let error as YouTubeServiceError {
            throw error
        } catch {
            log.error("[subs] fetchSubscriptionsPage failed: \(String(describing: error), privacy: .public)")
            throw YouTubeServiceError.network(error)
        }
    }

    func fetchSubscriptionsMore(continuation: String) async throws -> SubscriptionsPage {
        log.info("[subs] fetchSubscriptionsMore")
        do {
            let response = try await AccountSubscriptionsResponse.Continuation.sendThrowingRequest(
                youtubeModel: client.model,
                data: [.continuation: continuation]
            )
            if response.isDisconnected {
                throw YouTubeServiceError.notAuthenticated
            }
            let channels = response.results.map(Mappers.channel(from:))
            return SubscriptionsPage(channels: channels, continuationToken: response.continuationToken)
        } catch let error as YouTubeServiceError {
            throw error
        } catch {
            log.error("[subs] fetchSubscriptionsMore failed: \(String(describing: error), privacy: .public)")
            throw YouTubeServiceError.network(error)
        }
    }

    /// Subscribes to the channel via YouTubeKit's `SubscribeChannelResponse`. Requires the user
    /// to be signed in (cookies on the model). Surfaces `.notAuthenticated` if YouTube's
    /// response carries `isDisconnected=true`, `.network(_)` for any transport error.
    func subscribe(channelID: String) async throws {
        log.info("[subs] subscribe channelID=\(channelID, privacy: .public)")
        do {
            let response = try await SubscribeChannelResponse.sendThrowingRequest(
                youtubeModel: client.model,
                data: [.browseId: channelID]
            )
            if response.isDisconnected {
                log.notice("[subs] subscribe: response isDisconnected=true (cookies rejected)")
                throw YouTubeServiceError.notAuthenticated
            }
            // Update the local registry so any ChannelScreen rendered after this call shows
            // "Subscribed" — YouTubeKit's `subscribeStatus` parser is unreliable on the modern
            // `pageHeaderRenderer` layout, so we can't depend on the next channel fetch to
            // surface the correct state.
            await MainActor.run { SubscriptionRegistry.shared.add(channelID) }
            log.info("[subs] subscribe OK channelID=\(channelID, privacy: .public)")
        } catch let error as YouTubeServiceError {
            throw error
        } catch {
            log.error("[subs] subscribe failed: \(String(describing: error), privacy: .public)")
            throw YouTubeServiceError.network(error)
        }
    }

    func unsubscribe(channelID: String) async throws {
        log.info("[subs] unsubscribe channelID=\(channelID, privacy: .public)")
        do {
            let response = try await UnsubscribeChannelResponse.sendThrowingRequest(
                youtubeModel: client.model,
                data: [.browseId: channelID]
            )
            if response.isDisconnected {
                log.notice("[subs] unsubscribe: response isDisconnected=true")
                throw YouTubeServiceError.notAuthenticated
            }
            await MainActor.run { SubscriptionRegistry.shared.remove(channelID) }
            log.info("[subs] unsubscribe OK channelID=\(channelID, privacy: .public)")
        } catch let error as YouTubeServiceError {
            throw error
        } catch {
            log.error("[subs] unsubscribe failed: \(String(describing: error), privacy: .public)")
            throw YouTubeServiceError.network(error)
        }
    }
}
