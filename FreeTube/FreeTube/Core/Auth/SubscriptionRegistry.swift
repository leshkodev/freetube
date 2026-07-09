import Foundation
import Observation
import OSLog

/// Local cache of channel IDs the signed-in user is subscribed to.
///
/// **Why this exists:** YouTubeKit's `ChannelInfosResponse.subscribeStatus` parser only
/// recognizes two layouts (`c4TabbedHeaderRenderer.subscribeButton…` and the *first*
/// `frameworkUpdates` mutation). Modern channel pages use `pageHeaderRenderer` which surfaces
/// subscription state through an entity-key indirection that YouTubeKit doesn't follow, so
/// `subscribeStatus` comes back **nil** and the channel screen incorrectly shows "Subscribe"
/// for channels you already follow. This registry is the local source of truth that the channel
/// screen consults in addition to the response field.
///
/// **How it stays in sync:**
///   - `seed(_:)` overwrites the cache wholesale — called by `SubscribedChannelsScreen` when it
///     loads its full channel list, so every channel you have ever subscribed to (via the YouTube
///     site or this app) lands in the cache after the user visits the menu once.
///   - `add(_:)` / `remove(_:)` are called by `ChannelViewModel.toggleSubscribe` right after the
///     subscribe/unsubscribe API call succeeds, keeping the cache consistent across the app
///     without waiting for the next round-trip.
///   - `clear()` is called on sign-out so the next signed-in user starts fresh.
///
/// **Persistence:** stored as a JSON-encoded `[String]` in `UserDefaults`. No SwiftData migration
/// needed and survives app launches.
@available(iOS 17.0, *)
@Observable
@MainActor
final class SubscriptionRegistry {
    static let shared = SubscriptionRegistry()

    nonisolated fileprivate static let defaultsKey = "com.leshko.freetube.subscriptions"

    private(set) var ids: Set<String> = []
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "SubscriptionRegistry")

    private init() {
        load()
    }

    func contains(_ channelID: String) -> Bool {
        ids.contains(channelID)
    }

    /// Non-isolated lookup that bypasses the actor's executor — reads straight from
    /// `UserDefaults`. Use this from non-MainActor contexts like `ChannelService.mapChannel`
    /// where awaiting the actor would be awkward. `UserDefaults` is thread-safe, and the
    /// MainActor-isolated mutators always `persist()` after every change, so the on-disk view
    /// is consistent with `ids`.
    nonisolated static func containsBypassActor(_ channelID: String) -> Bool {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let array = try? JSONDecoder().decode([String].self, from: data) else {
            return false
        }
        return array.contains(channelID)
    }

    /// Records that the user just subscribed to `channelID`. Idempotent.
    func add(_ channelID: String) {
        guard !channelID.isEmpty else { return }
        let inserted = ids.insert(channelID).inserted
        if inserted {
            persist()
            log.info("[subs-reg] add \(channelID, privacy: .public) — total=\(self.ids.count, privacy: .public)")
        }
    }

    /// Records that the user just unsubscribed from `channelID`. Idempotent.
    func remove(_ channelID: String) {
        guard ids.remove(channelID) != nil else { return }
        persist()
        log.info("[subs-reg] remove \(channelID, privacy: .public) — total=\(self.ids.count, privacy: .public)")
    }

    /// Wholesale replace with a fresh server-side snapshot. Called by
    /// `SubscribedChannelsScreen` after each successful list fetch so the cache reflects what
    /// YouTube actually has, not just what the user has touched in this session.
    func seed(_ channelIDs: [String]) {
        let new = Set(channelIDs.filter { !$0.isEmpty })
        guard new != ids else { return }
        ids = new
        persist()
        log.info("[subs-reg] seeded \(new.count, privacy: .public) channels")
    }

    func clear() {
        guard !ids.isEmpty else { return }
        ids.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        log.info("[subs-reg] cleared (sign-out)")
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let array = try? JSONDecoder().decode([String].self, from: data) else {
            ids = []
            return
        }
        ids = Set(array)
        log.info("[subs-reg] loaded \(self.ids.count, privacy: .public) channel IDs from defaults")
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(Array(ids)) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
