import SwiftUI
import SwiftData

/// Renders the body of the search experience — results / suggestions / history / empty
/// state — without owning its own navigation stack or search bar. Hosted by `HomeScreen`,
/// which provides the `.searchable` text input and the `onRunSearch` callback so the
/// history upsert + submit stay in one place at the host level.
///
/// **Why decoupled from the search field:** the host (Home) needs to decide what to show
/// based on whether a search is active — when the user clears the field, we want the home
/// feed back, not a stale "Search" screen. Owning the `.searchable` at the host level
/// makes that flip simple.
@available(iOS 17.0, *)
struct SearchContent: View {
    @Bindable var model: SearchViewModel
    let onRunSearch: () -> Void
    @Environment(PlayerStateManager.self) private var player
    @Environment(\.modelContext) private var modelContext

    /// Recently entered search queries, newest first. Tapping one re-runs the search.
    @Query(sort: \SearchHistoryEntry.searchedAt, order: .reverse) private var history: [SearchHistoryEntry]

    var body: some View {
        Group {
            if let results = model.results {
                resultsList(results)
            } else if !model.suggestions.isEmpty {
                ScrollView {
                    SearchSuggestionList(suggestions: model.suggestions) { suggestion in
                        model.query = suggestion.text
                        onRunSearch()
                    }
                }
            } else if model.isLoading {
                LoadingView()
            } else if !history.isEmpty {
                historyList
            } else {
                EmptyStateView(
                    systemImage: "magnifyingglass",
                    title: "Search YouTube",
                    message: "Find videos, channels, and playlists."
                )
            }
        }
        .errorToast($model.errorState)
    }

    @ViewBuilder
    private var historyList: some View {
        List {
            Section("Recent searches") {
                ForEach(history) { entry in
                    Button {
                        model.query = entry.query
                        onRunSearch()
                    } label: {
                        HStack {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(.secondary)
                            Text(entry.query)
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets {
                        modelContext.delete(history[index])
                    }
                    try? modelContext.save()
                }

                if !history.isEmpty {
                    Button("Clear all", role: .destructive) {
                        for entry in history { modelContext.delete(entry) }
                        try? modelContext.save()
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private func resultsList(_ results: SearchResult) -> some View {
        List {
            if !results.channels.isEmpty {
                Section("Channels") {
                    ForEach(results.channels) { channel in
                        NavigationLink {
                            ChannelScreen(channelID: channel.id)
                        } label: {
                            ChannelRow(channel: channel)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !results.playlists.isEmpty {
                Section("Playlists") {
                    ForEach(results.playlists) { playlist in
                        NavigationLink {
                            PlaylistScreen(playlistID: playlist.id)
                        } label: {
                            PlaylistRow(playlist: playlist, showsMoreMenu: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !results.videos.isEmpty {
                Section("Videos") {
                    let lookaheadIDs = Set(results.videos.suffix(5).map(\.id))
                    ForEach(results.videos) { video in
                        VideoRow(video: video, showsMoreMenu: true) {
                            player.load(video)
                        }
                        .onAppear {
                            guard lookaheadIDs.contains(video.id),
                                  results.continuationToken != nil,
                                  !model.isLoading else { return }
                            Task { await model.loadMore() }
                        }
                    }
                    if model.isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
    }
}

/// Inline search field used on Mac (Designed-for-iPad-on-Mac or real Catalyst). `.searchable`
/// collapses to a trailing toolbar button on Mac runtimes — awkward at desktop widths. The
/// host view embeds this above its content and skips `.searchable` via `ConditionalSearchable`.
@available(iOS 17.0, *)
struct MacInlineSearchField: View {
    @Binding var query: String
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .onSubmit(onSubmit)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.quaternary, in: Capsule())
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// Applies `.searchable` only when `enabled`. We can't put `.searchable` behind a plain
/// `if` because it returns an opaque `some View` whose type differs between branches,
/// which breaks SwiftUI identity. A `ViewModifier` keeps the outer type stable across the
/// runtime toggle (Mac → inline field, iOS → native searchable).
@available(iOS 17.0, *)
struct ConditionalSearchable: ViewModifier {
    @Binding var text: String
    let enabled: Bool
    var prompt: String = "Search"

    func body(content: Content) -> some View {
        if enabled {
            content.searchable(text: $text, prompt: Text(prompt))
        } else {
            content
        }
    }
}
