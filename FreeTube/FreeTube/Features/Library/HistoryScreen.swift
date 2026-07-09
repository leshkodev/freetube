import SwiftUI

@available(iOS 17.0, *)
struct HistoryScreen: View {
    @State private var model = HistoryViewModel()
    @Environment(PlayerStateManager.self) private var player

    /// Distance from the end at which we kick off the next page. 5 keeps the next chunk warm
    /// before the user reaches the actual last row, so scrolling stays fluid.
    private let prefetchLookahead = 5

    var body: some View {
        List {
            ForEach(Array(model.videos.enumerated()), id: \.element.id) { index, video in
                VideoRow(video: video, showsMoreMenu: true) { player.load(video) }
                    .swipeActions {
                        Button(role: .destructive) {
                            Task { await model.remove(video) }
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                    .onAppear { prefetchIfNeeded(currentIndex: index) }
            }
            if model.continuationToken != nil {
                // Footer spinner — also acts as a fallback trigger if the prefetch lookahead
                // hasn't fired (e.g. when the list is very short).
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowSeparator(.hidden)
                .onAppear { Task { await model.loadMore() } }
            }
        }
        .listStyle(.plain)
        .navigationTitle("History")
        .task { await model.load() }
        .refreshable { await model.load() }
        .errorToast(Bindable(model).errorState)
    }

    private func prefetchIfNeeded(currentIndex: Int) {
        guard currentIndex >= model.videos.count - prefetchLookahead else { return }
        guard model.canLoadMore else { return }
        Task { await model.loadMore() }
    }
}
