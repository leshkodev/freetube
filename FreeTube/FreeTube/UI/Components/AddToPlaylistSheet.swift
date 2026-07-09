import SwiftUI

/// Sheet shown by the player's more-actions menu when the user taps "Add to playlist".
///
/// Lists the user's playlists with a checkmark next to ones that already contain the video.
/// Tapping a row adds the video to that playlist (or no-ops if it's already there). A
/// dedicated "Create new playlist" row at the top opens a tiny inline form to make a new
/// playlist and add the video to it in one shot.
///
/// Auth-gated by caller: this sheet should only be presented when `AuthState` reports
/// `.loggedIn`. Without cookies, `fetchHostablePlaylists` would throw `.notAuthenticated`
/// and the user would see an empty error toast.
@available(iOS 17.0, *)
struct AddToPlaylistSheet: View {
    let videoID: String
    let videoTitle: String

    @Environment(\.dismiss) private var dismiss

    @State private var playlists: [PlaylistAvailability] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var pendingPlaylistIDs: Set<String> = []
    @State private var isCreating = false
    @State private var newPlaylistTitle = ""
    @State private var newPlaylistIsPrivate = true
    @State private var isSavingNewPlaylist = false

    private let service: any PlaylistServicing = PlaylistService()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Add to playlist")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
                .task { await loadPlaylists() }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var content: some View {
        List {
            Section {
                Text(videoTitle)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
            }

            Section {
                if isCreating {
                    createPlaylistForm
                } else {
                    Button {
                        withAnimation { isCreating = true }
                    } label: {
                        Label("Create new playlist", systemImage: "plus.circle.fill")
                    }
                }
            }

            Section("Your playlists") {
                if isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if playlists.isEmpty {
                    Text("You don't have any playlists yet. Tap \"Create new playlist\" above to make one.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(playlists) { playlist in
                        playlistRow(playlist)
                    }
                }
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
        }
    }

    @ViewBuilder
    private var createPlaylistForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Playlist title", text: $newPlaylistTitle)
                .textInputAutocapitalization(.sentences)
                .textFieldStyle(.roundedBorder)
            Toggle("Private playlist", isOn: $newPlaylistIsPrivate)
                .font(.subheadline)
            HStack {
                Button("Cancel") {
                    withAnimation {
                        isCreating = false
                        newPlaylistTitle = ""
                    }
                }
                .buttonStyle(.bordered)
                Spacer()
                Button {
                    Task { await createPlaylist() }
                } label: {
                    if isSavingNewPlaylist {
                        ProgressView()
                    } else {
                        Text("Create")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(newPlaylistTitle.trimmingCharacters(in: .whitespaces).isEmpty || isSavingNewPlaylist)
            }
        }
        .padding(.vertical, 4)
    }

    /// Tappable row showing a playlist's name, privacy badge, and a leading checkmark when the
    /// video is already inside. Pending adds show a spinner so duplicate taps don't queue up.
    @ViewBuilder
    private func playlistRow(_ playlist: PlaylistAvailability) -> some View {
        let isPending = pendingPlaylistIDs.contains(playlist.id)
        Button {
            Task { await add(to: playlist) }
        } label: {
            HStack(spacing: 12) {
                Group {
                    if isPending {
                        ProgressView().frame(width: 22, height: 22)
                    } else if playlist.containsVideo {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Image(systemName: "circle")
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.title.isEmpty ? "(untitled)" : playlist.title)
                        .font(.body)
                        .foregroundStyle(.primary)
                    if playlist.isPrivate {
                        Text("Private")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .disabled(isPending || playlist.containsVideo)
    }

    // MARK: - Actions

    private func loadPlaylists() async {
        isLoading = true
        defer { isLoading = false }
        do {
            playlists = try await service.fetchHostablePlaylists(videoID: videoID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func add(to playlist: PlaylistAvailability) async {
        guard !playlist.containsVideo else { return }
        pendingPlaylistIDs.insert(playlist.id)
        defer { pendingPlaylistIDs.remove(playlist.id) }
        do {
            try await service.add(videoID: videoID, to: playlist.id)
            // Mark the playlist as containing the video so the row updates immediately
            // without another network round-trip.
            if let index = playlists.firstIndex(where: { $0.id == playlist.id }) {
                let old = playlists[index]
                playlists[index] = PlaylistAvailability(
                    id: old.id,
                    title: old.title,
                    containsVideo: true,
                    isPrivate: old.isPrivate
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createPlaylist() async {
        let title = newPlaylistTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        isSavingNewPlaylist = true
        defer { isSavingNewPlaylist = false }
        do {
            let created = try await service.create(
                title: title,
                isPrivate: newPlaylistIsPrivate,
                seedVideoID: videoID
            )
            // Prepend the new (already-contains-video) playlist to the visible list and reset
            // the form. We don't refetch — `create` returns enough to render the row.
            playlists.insert(
                PlaylistAvailability(
                    id: created.id,
                    title: created.title,
                    containsVideo: true,
                    isPrivate: newPlaylistIsPrivate
                ),
                at: 0
            )
            withAnimation {
                isCreating = false
                newPlaylistTitle = ""
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
