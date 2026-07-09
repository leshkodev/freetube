import SwiftUI
import Observation

/// Pushed when the user taps "My subscriptions" in the Library menu. Lists every channel the
/// signed-in user follows (paginated via `AccountSubscriptionsResponse.Continuation`). Each row
/// shows the channel's avatar + name + subscriber line via `ChannelRow`, wrapped in a
/// `NavigationLink` that pushes `ChannelScreen`.
///
/// Named distinctly from the existing `SubscriptionsScreen` (which shows the *feed of latest
/// videos* from your subscriptions, not the channel list) — file names must be unique within
/// the Xcode target. The Library menu sends users here; the Subscriptions feed has its own
/// entry point elsewhere if you want a chronological video stream.
@available(iOS 17.0, *)
struct SubscribedChannelsScreen: View {
    @State private var model = SubscriptionsListViewModel()

    /// Lookahead distance (in rows) at which the next page is prefetched. Matches the pattern
    /// used by Channel tabs / History / Playlist screens.
    private let prefetchLookahead = 5

    var body: some View {
        Group {
            if model.channels.isEmpty && model.isLoading {
                LoadingView()
            } else if model.channels.isEmpty {
                EmptyStateView(
                    systemImage: "person.2.fill",
                    title: "No subscriptions",
                    message: "Channels you subscribe to on YouTube will show up here."
                )
            } else {
                List {
                    ForEach(Array(model.channels.enumerated()), id: \.element.id) { index, channel in
                        NavigationLink {
                            ChannelScreen(channelID: channel.id)
                        } label: {
                            ChannelRow(channel: channel)
                        }
                        .buttonStyle(.plain)
                        .onAppear { prefetchIfNeeded(currentIndex: index) }
                    }
                    if model.canLoadMore || model.isLoadingMore {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .listRowSeparator(.hidden)
                        .onAppear {
                            if model.canLoadMore { Task { await model.loadMore() } }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Subscriptions")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model.channels.isEmpty { await model.load() }
        }
        .refreshable { await model.load() }
        .errorToast(Bindable(model).errorState)
    }

    private func prefetchIfNeeded(currentIndex: Int) {
        guard currentIndex >= model.channels.count - prefetchLookahead else { return }
        guard model.canLoadMore else { return }
        Task { await model.loadMore() }
    }
}

@available(iOS 17.0, *)
@Observable
@MainActor
final class SubscriptionsListViewModel {
    private(set) var channels: [Channel] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    /// Continuation token from the most recent response. Nil → no more pages.
    private(set) var continuationToken: String?
    var errorState: ErrorState?

    private let service: any SubscriptionServicing

    init(service: any SubscriptionServicing = SubscriptionService()) {
        self.service = service
    }

    var canLoadMore: Bool {
        continuationToken != nil && !isLoadingMore && !isLoading
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await service.fetchSubscriptionsPage()
            channels = page.channels
            continuationToken = page.continuationToken
            // If this is the only page (no continuation), seed the registry wholesale — we
            // know the full set. With pagination, seed once we've drained all pages instead.
            if continuationToken == nil {
                SubscriptionRegistry.shared.seed(channels.map(\.id))
            }
        } catch {
            errorState = ErrorState(from: error)
        }
    }

    func loadMore() async {
        guard let token = continuationToken, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await service.fetchSubscriptionsMore(continuation: token)
            channels.append(contentsOf: page.channels)
            continuationToken = page.continuationToken
            // Re-seed once we've reached the last page (no more continuation).
            if continuationToken == nil {
                SubscriptionRegistry.shared.seed(channels.map(\.id))
            }
        } catch {
            errorState = ErrorState(from: error)
        }
    }
}
