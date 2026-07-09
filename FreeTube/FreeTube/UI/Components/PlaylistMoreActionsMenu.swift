import SwiftUI
import SwiftData
import UIKit

/// Reusable trailing ellipsis Menu for `Playlist` items. Used by search results, the
/// library's user-playlists screen, and anywhere else a playlist appears in a list.
///
/// Auth-gating rules (per product spec):
///   - Open in browser, Copy URL: always shown
///   - Add to favorites / Remove from favorites: shown only when signed in
///
/// Favorites are stored locally in `FavoritePlaylist` (SwiftData) — no YouTube sync, so the
/// auth gate is purely a UI affordance: when signed out, the menu is just the two URL actions.
@available(iOS 17.0, *)
struct PlaylistMoreActionsMenu: View {
    let playlist: Playlist

    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Query private var favorites: [FavoritePlaylist]

    var body: some View {
        Menu {
            if let url = playlistURL {
                Button {
                    openURL(url)
                } label: {
                    Label("Open in browser", systemImage: "safari")
                }
                Button {
                    UIPasteboard.general.string = url.absoluteString
                } label: {
                    Label("Copy URL", systemImage: "link")
                }
            }
            if isSignedIn {
                Divider()
                Button {
                    toggleFavorite()
                } label: {
                    if isFavorite {
                        Label("Remove from favorites", systemImage: "hand.thumbsup.fill")
                    } else {
                        Label("Add to favorites", systemImage: "hand.thumbsup")
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    /// YouTube's playlist URLs use the bare playlist id, stripping the `VL` prefix YouTubeKit
    /// adds for browse requests.
    private var playlistURL: URL? {
        let bare = playlist.id.hasPrefix("VL") ? String(playlist.id.dropFirst(2)) : playlist.id
        return URL(string: "https://www.youtube.com/playlist?list=\(bare)")
    }

    private var isSignedIn: Bool {
        if case .loggedIn = AuthState.shared.status { return true }
        return false
    }

    private var isFavorite: Bool {
        favorites.contains { $0.playlistID == playlist.id }
    }

    private func toggleFavorite() {
        if isFavorite {
            for fav in favorites where fav.playlistID == playlist.id {
                modelContext.delete(fav)
            }
        } else {
            modelContext.insert(FavoritePlaylist(
                playlistID: playlist.id,
                title: playlist.title,
                channelName: playlist.channelName ?? "",
                thumbnailURL: playlist.thumbnailURL,
                videoCount: playlist.videoCount
            ))
        }
        try? modelContext.save()
    }
}
