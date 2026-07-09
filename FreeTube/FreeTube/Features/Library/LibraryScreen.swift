import SwiftUI
import SwiftData
import Kingfisher

/// Library is the user's home for everything tied to their YouTube account. When signed in we
/// render the account header followed by a menu of six destinations:
///   - Watch history (`HistoryScreen` backed by `HistoryResponse`)
///   - Playlists (list of user-owned playlists from `AccountLibraryResponse`)
///   - Your videos (the user's own uploads — opens `ChannelScreen(channelID:)`)
///   - Subscriptions (channels you follow — opens `SubscriptionsScreen`)
///   - Liked videos (special playlist `VLLL` — opens `PlaylistScreen`)
///   - Watch later (special playlist `VLWL` — opens `PlaylistScreen`)
///
/// When signed out we show a single sign-in CTA and hide the menu. Tapping any item while
/// signed out would route to an error toast — clearer to just gate the whole menu.
@available(iOS 17.0, *)
struct LibraryScreen: View {
    @State private var libraryModel = LibraryViewModel()
    @State private var accountModel = AccountViewModel()
    @State private var showingLogin = false

    var body: some View {
        NavigationStack {
            List {
                accountSection
                if accountModel.info != nil {
                    menuSection
                }
            }
            .navigationTitle("Library")
            .task {
                await accountModel.load()
                if accountModel.info != nil { await libraryModel.load() }
            }
            .refreshable {
                await accountModel.load()
                if accountModel.info != nil { await libraryModel.load() }
            }
            .sheet(isPresented: $showingLogin) {
                LoginScreen()
                    .onDisappear {
                        // After the login sheet closes, re-fetch account info — if cookies
                        // landed, the next `fetchAccountInfo` will return non-nil and the menu
                        // appears immediately.
                        Task {
                            await accountModel.load()
                            await libraryModel.load()
                        }
                    }
            }
            .errorToast(Bindable(libraryModel).errorState)
        }
    }

    // MARK: - Account header

    @ViewBuilder
    private var accountSection: some View {
        Section {
            if let info = accountModel.info {
                HStack(spacing: 12) {
                    KFImage(info.avatarURL)
                        .thumbnail(size: CGSize(width: 56, height: 56)) {
                            Circle().fill(.gray.opacity(0.2))
                        }
                        .resizable()
                        .scaledToFill()
                        .frame(width: 56, height: 56)
                        .clipShape(Circle())
                    VStack(alignment: .leading) {
                        Text(info.displayName).font(.headline)
                        if let handle = info.handle, !handle.isEmpty {
                            Text(handle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Sign out") {
                        Task {
                            await accountModel.signOut()
                            libraryModel.clear()
                        }
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Button {
                    showingLogin = true
                } label: {
                    Label("Sign in to YouTube", systemImage: "person.crop.circle.badge.plus")
                }
            }
        } footer: {
            if accountModel.info == nil {
                Text("Sign in to access your watch history, playlists, liked videos, and Watch Later.")
            }
        }
    }

    // MARK: - Menu

    /// Five destinations as a single section (Movies removed — YouTubeKit doesn't expose it).
    /// Each row renders a custom `HStack { icon, VStack(title, subtitle) }` so we can show a
    /// count under the title. Subtitles are best-effort: when the library response hasn't
    /// loaded yet they read "—" and update reactively once `libraryModel.library` populates.
    @ViewBuilder
    private var menuSection: some View {
        Section {
            menuRow(
                title: "Watch history",
                subtitle: countSubtitle(libraryModel.library?.historyCount, noun: "video"),
                systemImage: "clock.fill"
            ) {
                HistoryScreen()
            }

            menuRow(
                title: "Playlists",
                subtitle: countSubtitle(libraryModel.library?.playlists.count, noun: "playlist"),
                systemImage: "rectangle.stack.fill"
            ) {
                UserPlaylistsScreen(playlists: libraryModel.library?.playlists ?? [])
            }

            menuRow(
                title: "Your videos",
                subtitle: "Your YouTube channel",
                systemImage: "person.crop.rectangle.fill"
            ) {
                if let channelID = libraryModel.library?.userChannelID {
                    ChannelScreen(channelID: channelID)
                } else {
                    EmptyStateView(
                        systemImage: "person.crop.rectangle.fill",
                        title: "No channel detected",
                        message: "Your YouTube channel ID wasn't returned in the library response. Try refreshing the Library screen."
                    )
                }
            }

            menuRow(
                title: "Subscriptions",
                subtitle: "Channels you follow",
                systemImage: "person.2.fill"
            ) {
                SubscribedChannelsScreen()
            }

            // VLLL — YouTube's well-known playlist ID for the signed-in user's Liked Videos.
            menuRow(
                title: "Liked videos",
                subtitle: countSubtitle(libraryModel.library?.likedCount, noun: "video"),
                systemImage: "hand.thumbsup.fill"
            ) {
                PlaylistScreen(playlistID: "VLLL")
            }

            // VLWL — Watch Later.
            menuRow(
                title: "Watch later",
                subtitle: countSubtitle(libraryModel.library?.watchLaterCount, noun: "video"),
                systemImage: "clock.arrow.circlepath"
            ) {
                PlaylistScreen(playlistID: "VLWL")
            }
        }
    }

    /// Custom row builder so we can put the count under the title (the system's `Label` only
    /// shows a single line of text next to its icon). Pushes the given destination in the
    /// surrounding NavigationStack.
    @ViewBuilder
    private func menuRow<Destination: View>(
        title: String,
        subtitle: String,
        systemImage: String,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Builds the "N videos" / "N playlists" subtitle. When the library response hasn't
    /// returned yet (count is nil), we render "—" rather than a hardcoded "0" so the user can
    /// tell "still loading" from "actually empty".
    private func countSubtitle(_ count: Int?, noun: String) -> String {
        guard let count else { return "—" }
        let plural = count == 1 ? noun : noun + "s"
        return "\(count) \(plural)"
    }
}

// MARK: - User playlists list

/// Simple list of user-owned playlists. Each row pushes `PlaylistScreen` for the playlist's
/// detail view (videos + actions). Reuses `PlaylistRow` so the visual matches search/channel.
@available(iOS 17.0, *)
private struct UserPlaylistsScreen: View {
    let playlists: [Playlist]

    var body: some View {
        Group {
            if playlists.isEmpty {
                EmptyStateView(
                    systemImage: "rectangle.stack",
                    title: "No playlists",
                    message: "Playlists you create on YouTube will appear here."
                )
            } else {
                List {
                    ForEach(playlists) { playlist in
                        NavigationLink {
                            PlaylistScreen(playlistID: playlist.id)
                        } label: {
                            PlaylistRow(playlist: playlist, showsMoreMenu: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Playlists")
        .navigationBarTitleDisplayMode(.inline)
    }
}

