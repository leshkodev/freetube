import SwiftUI
import Kingfisher

@available(iOS 17.0, *)
struct SubscriptionsScreen: View {
    @State private var model = SubscriptionsViewModel()
    @Environment(PlayerStateManager.self) private var player

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if !model.channels.isEmpty {
                        SectionHeader(title: "Subscriptions")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                ForEach(model.channels) { channel in
                                    NavigationLink {
                                        ChannelScreen(channelID: channel.id)
                                    } label: {
                                        channelChip(channel)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal)
                        }
                    }

                    SectionHeader(title: "Latest from your subscriptions")
                    ForEach(model.feedVideos) { video in
                        VideoCard(video: video, onTap: { player.load(video) }, showsMoreMenu: true)
                    }

                    if model.isLoading { LoadingView() }
                    if model.feedVideos.isEmpty && !model.isLoading {
                        EmptyStateView(systemImage: "rectangle.stack.person.crop",
                                       title: "Nothing new",
                                       message: "Subscribe to channels to see their latest videos here.")
                    }
                }
                .padding(.vertical, 8)
            }
            .navigationTitle("Subscriptions")
            .refreshable { await model.load() }
            .task {
                if model.feedVideos.isEmpty { await model.load() }
            }
            .errorToast(Bindable(model).errorState)
        }
    }

    @ViewBuilder
    private func channelChip(_ channel: Channel) -> some View {
        VStack(spacing: 6) {
            KFImage(channel.thumbnailURL)
                .thumbnail(size: CGSize(width: 64, height: 64)) {
                    Circle().fill(.gray.opacity(0.2))
                }
                .resizable()
                .scaledToFill()
                .frame(width: 64, height: 64)
                .clipShape(Circle())
            Text(channel.name).font(.caption).lineLimit(1).frame(maxWidth: 80)
        }
    }
}
