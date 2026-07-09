import SwiftUI
import SwiftData
import AVFoundation
import UIKit

@available(iOS 17.0, *)
struct DownloadsScreen: View {
    @State private var model = DownloadsViewModel()
    /// File-system + xattr backed downloads list. Replaces the SwiftData `@Query` —
    /// the store rebuilds `entries` from the Documents root on launch and after every
    /// `DownloadsStore.didChange` notification (posted by the YouTube + URL writers).
    @State private var store = DownloadsStore.shared
    @Environment(\.modelContext) private var context
    /// All favorited video IDs, kept in sync by SwiftData's `@Query`. We do *not* per-row fetch
    /// because that runs synchronous Core Data on the main queue for every menu rebuild and tanks
    /// the UI during downloads (the SQL fetches show up dominating Instruments traces).
    @Query private var favorites: [FavoriteVideo]
    @Environment(PlayerStateManager.self) private var player

    /// O(1) lookup table for `isFavorite(_:)`. Recomputed when `favorites` changes (which `@Query`
    /// keeps reactive), so menu rendering avoids any database work.
    private var favoriteIDs: Set<String> {
        Set(favorites.map(\.videoID))
    }

    // MARK: - Selection + sort state

    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var sortBy: SortBy = .date
    @State private var sortDescending = true
    /// Confirmation alert before deleting selected items in selection mode.
    @State private var showBulkDeleteConfirmation = false
    /// When non-nil, the user tapped delete on a single row — confirm before removing.
    @State private var pendingSingleDelete: SavedItem?
    /// When non-nil, the user tapped "Open in…" on a row — present the system activity sheet.
    @State private var shareFileURL: URL?

    /// What the user can sort by. `duration` reads each file's AVAsset at row-build time —
    /// inexpensive because we already cached it once per launch.
    enum SortBy: String, CaseIterable, Identifiable {
        case date = "Date downloaded"
        case title = "Title"
        case size = "File size"
        case duration = "Duration"
        var id: String { rawValue }
    }

    /// Active in-flight downloads.
    private var inProgress: [DownloadTaskSnapshot] {
        model.manager.activeTasks.filter { snapshot in
            switch snapshot.state {
            case .queued, .downloading, .paused, .failed: return true
            case .completed: return false
            }
        }
    }

    /// File-system + xattr backed list. `DownloadsStore.entries` already includes both
    /// "tracked" rows (file has our metadata xattr) and "orphan" rows (file present but no
    /// xattr — surfaces with filename-as-title). We just map and apply the user's sort.
    private var savedItems: [SavedItem] {
        sortItems(store.entries.map(SavedItem.init(from:)))
    }

    /// Aggregate stats shown under the title.
    private var totalSize: Int64 { savedItems.reduce(0) { $0 + $1.fileSize } }
    private var totalCount: Int { savedItems.count }

    var body: some View {
        NavigationStack {
            List(selection: $selectedIDs) {
                if !inProgress.isEmpty {
                    Section("Transfer queue") {
                        ForEach(inProgress) { snapshot in
                            transferRow(snapshot)
                        }
                    }
                }

                Section {
                    if savedItems.isEmpty {
                        EmptyStateView(systemImage: "arrow.down.circle",
                                       title: "No downloads",
                                       message: "Tap a video to play — it will be saved here automatically.")
                    }
                    ForEach(savedItems) { item in
                        savedItemRow(item)
                            .tag(item.id)
                    }
                } header: {
                    savedHeader
                }
            }
            .navigationTitle("Downloads")
            .environment(\.editMode, .constant(isSelecting ? .active : .inactive))
            .toolbar {
                transferToolbarItem
                selectionToolbarLeading
                sortAndSelectToolbarTrailing
                // When selection mode is active, replace the nav title with a stacked
                // "Downloads" + "N selected" so the count reads as a subtitle, not a separate row.
                if isSelecting {
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 1) {
                            Text("Downloads").font(.headline)
                            Text("\(selectedIDs.count) selected")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            // Glass-style action bar with just two pill buttons: Select all + Delete.
            .safeAreaInset(edge: .top) {
                if isSelecting {
                    selectionActionBar
                }
            }
            .alert(
                "Delete \(selectedIDs.count) \(selectedIDs.count == 1 ? "video" : "videos")?",
                isPresented: $showBulkDeleteConfirmation
            ) {
                Button("Delete", role: .destructive) { deleteSelected() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently removes the selected file\(selectedIDs.count == 1 ? "" : "s") from your device.")
            }
            .alert(
                "Delete this video?",
                isPresented: Binding(
                    get: { pendingSingleDelete != nil },
                    set: { if !$0 { pendingSingleDelete = nil } }
                ),
                presenting: pendingSingleDelete
            ) { item in
                Button("Delete", role: .destructive) {
                    deleteSavedItem(item)
                    pendingSingleDelete = nil
                }
                Button("Cancel", role: .cancel) { pendingSingleDelete = nil }
            } message: { item in
                Text("“\(item.title)” will be permanently removed from your device.")
            }
            .errorToast(Bindable(model).errorState)
            // Presents UIActivityViewController for the per-row "Open in…" action. The bound bool
            // mirrors `shareFileURL` so the sheet lifecycle matches user intent.
            .sheet(isPresented: Binding(
                get: { shareFileURL != nil },
                set: { if !$0 { shareFileURL = nil } }
            )) {
                if let url = shareFileURL {
                    ActivityShareSheet(activityItems: [url])
                }
            }
        }
    }

    // MARK: - Saved section header (stats + sort)

    @ViewBuilder
    private var savedHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Saved on device").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            if totalCount > 0 {
                Text("\(totalCount) \(totalCount == 1 ? "video" : "videos") • \(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .textCase(nil)
        .padding(.bottom, 4)
    }

    // MARK: - Transfer rows (in-progress)

    @ViewBuilder
    private func transferRow(_ snapshot: DownloadTaskSnapshot) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                progress(for: snapshot.state)
            }
            Spacer()
            Button(role: .destructive) {
                model.cancel(snapshot)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func progress(for state: DownloadTaskSnapshot.State) -> some View {
        switch state {
        case .queued:
            Text("Queued").font(.caption).foregroundStyle(.secondary)
        case .downloading(let value):
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: value)
                Text("\(Int(value * 100))%").font(.caption2).foregroundStyle(.secondary)
            }
        case .paused:
            Text("Paused").font(.caption).foregroundStyle(.secondary)
        case .completed:
            Text("Completed").font(.caption).foregroundStyle(.green)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red)
        }
    }

    // MARK: - Downloaded row + per-row menu

    @ViewBuilder
    private func savedItemRow(_ item: SavedItem) -> some View {
        HStack(spacing: 12) {
            thumbnail(data: item.thumbnailData)
                .frame(width: 96, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                if !item.channelName.isEmpty {
                    Text(item.channelName).font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(formatSize(item.fileSize))
                    if let dur = item.duration {
                        Text("• \(formatDuration(dur))")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if !isSelecting {
                rowMenu(item)
                    .buttonStyle(.plain)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // In selection mode, List's own selection binding handles taps. Out of selection
            // mode, tapping the row plays the file.
            if !isSelecting {
                playLocal(item)
            }
        }
        .swipeActions {
            if !isSelecting {
                Button(role: .destructive) {
                    pendingSingleDelete = item
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private func rowMenu(_ item: SavedItem) -> some View {
        Menu {
            Button {
                if let url = sourceURL(for: item) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Open in browser", systemImage: "safari")
            }
            // System "Open in…" share sheet for the downloaded mp4 — opens UIActivityViewController
            // with the local file URL so the user can send it to VLC, Files, AirDrop, etc. We use
            // a Button + sheet rather than `ShareLink` because the latter is unreliable for
            // `file://` URLs inside a `Menu` (it sometimes serializes them as plain text).
            Button {
                shareFileURL = item.fileURL
            } label: {
                Label("Open in…", systemImage: "square.and.arrow.up")
            }
            // "Show in Finder" only renders on macOS runtimes (Designed-for-iPad-on-Mac
            // or real Catalyst). On iPhone/iPad the Files app doesn't accept "select this
            // specific file" deeplinks, so the item is hidden there — surfacing a dead
            // menu entry would just confuse the user.
            if MacIntegration.isRunningOnMac {
                Button {
                    MacIntegration.revealInFinder(item.fileURL)
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
            }
            // Favorites are a YouTube-only concept (the schema keys off videoID and the
            // VideoActionsService routes through the YouTube like API). Hide the option for
            // URL-fetched items so we don't write garbage rows.
            if !item.isFromURL {
                Button {
                    toggleFavorite(item)
                } label: {
                    if isFavorite(item.videoID) {
                        Label("Remove from favorites", systemImage: "hand.thumbsup.fill")
                    } else {
                        Label("Add to favorites", systemImage: "hand.thumbsup")
                    }
                }
            }
            Button {
                if let url = sourceURL(for: item) {
                    UIPasteboard.general.string = url.absoluteString
                }
            } label: {
                Label("Copy URL", systemImage: "link")
            }
            Divider()
            Button(role: .destructive) {
                pendingSingleDelete = item
            } label: {
                Label("Delete from downloaded", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body)
                .padding(.horizontal, 8)
                .frame(minWidth: 32, minHeight: 32)
                .contentShape(Rectangle())
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var transferToolbarItem: some ToolbarContent {
        if !inProgress.isEmpty {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                        .symbolEffect(.pulse, options: .repeating, value: inProgress.count)
                        .foregroundStyle(.tint)
                    Text("\(inProgress.count)")
                        .font(.caption.weight(.semibold))
                        .contentTransition(.numericText())
                        .animation(.spring, value: inProgress.count)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var selectionToolbarLeading: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Done") {
                    isSelecting = false
                    selectedIDs.removeAll()
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var sortAndSelectToolbarTrailing: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                // Select action goes at the top of the menu with an icon.
                Button {
                    isSelecting.toggle()
                    selectedIDs.removeAll()
                } label: {
                    Label(isSelecting ? "Cancel selection" : "Select", systemImage: "checkmark.circle")
                }
                Divider()
                // Sort options live below the Select action.
                Section("Sort by") {
                    ForEach(SortBy.allCases) { option in
                        Button {
                            if sortBy == option {
                                sortDescending.toggle()
                            } else {
                                sortBy = option
                                sortDescending = (option == .date || option == .size)
                            }
                        } label: {
                            HStack {
                                Text(option.rawValue)
                                Spacer()
                                if sortBy == option {
                                    Image(systemName: sortDescending ? "arrow.down" : "arrow.up")
                                }
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    /// Top-of-screen action bar in selection mode. Two glass-style pill buttons: Select all on the
    /// left, Delete on the right. The selected count lives in the nav title as a subtitle.
    @ViewBuilder
    private var selectionActionBar: some View {
        HStack(spacing: 12) {
            glassButton(
                title: selectedIDs.count == savedItems.count ? "Deselect all" : "Select all",
                systemImage: selectedIDs.count == savedItems.count ? "checklist.unchecked" : "checklist",
                role: nil
            ) {
                if selectedIDs.count == savedItems.count {
                    selectedIDs.removeAll()
                } else {
                    selectedIDs = Set(savedItems.map(\.id))
                }
            }

            Spacer()

            glassButton(
                title: "Delete",
                systemImage: "trash",
                role: .destructive
            ) {
                showBulkDeleteConfirmation = true
            }
            .disabled(selectedIDs.isEmpty)
            .opacity(selectedIDs.isEmpty ? 0.4 : 1)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    /// Pill button with a translucent material backdrop — the closest we get to iOS 18's `.glassEffect`
    /// while still supporting iOS 17. Destructive buttons get a red tint, neutral buttons inherit
    /// the accent color.
    @ViewBuilder
    private func glassButton(title: String, systemImage: String, role: ButtonRole?, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(role == .destructive ? Color.red : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sort

    private func sortItems(_ items: [SavedItem]) -> [SavedItem] {
        let ordered: [SavedItem]
        switch sortBy {
        case .date:
            ordered = items.sorted { $0.modifiedAt < $1.modifiedAt }
        case .title:
            ordered = items.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .size:
            ordered = items.sorted { $0.fileSize < $1.fileSize }
        case .duration:
            ordered = items.sorted { ($0.duration ?? 0) < ($1.duration ?? 0) }
        }
        return sortDescending ? ordered.reversed() : ordered
    }

    // MARK: - Actions

    private func deleteSavedItem(_ item: SavedItem) {
        // `DownloadsStore.delete` removes the file (xattrs go with it) and posts the
        // change notification so the store reloads. No SwiftData row to delete.
        DownloadsStore.shared.delete(at: item.fileURL)
        selectedIDs.remove(item.id)
    }

    private func deleteSelected() {
        let items = savedItems.filter { selectedIDs.contains($0.id) }
        for item in items {
            deleteSavedItem(item)
        }
        selectedIDs.removeAll()
        isSelecting = false
    }

    /// Source URL for the "Open in browser" and "Copy URL" actions. URL-fetch items return
    /// the original pasted URL; YouTube items return the canonical watch URL built from
    /// videoID. The signature still takes a `SavedItem` so we can pick the right shape
    /// without forcing the caller to know which kind of row it has.
    private func sourceURL(for item: SavedItem) -> URL? {
        if let original = item.originalURL, let url = URL(string: original) {
            return url
        }
        return URL(string: "https://www.youtube.com/watch?v=\(item.videoID)")
    }

    /// O(1) lookup against the cached `favoriteIDs` set. The previous implementation hit Core Data
    /// on every call, which was being invoked once per row per render → SQL on the main queue and
    /// visible UI lag during active downloads.
    private func isFavorite(_ videoID: String) -> Bool {
        favoriteIDs.contains(videoID)
    }

    private func toggleFavorite(_ item: SavedItem) {
        if let existing = favorites.first(where: { $0.videoID == item.videoID }) {
            context.delete(existing)
        } else {
            context.insert(FavoriteVideo(
                videoID: item.videoID,
                title: item.title,
                channelName: item.channelName,
                thumbnailURL: nil
            ))
        }
        try? context.save()
    }

    // MARK: - Helpers

    @ViewBuilder
    private func thumbnail(data: Data?) -> some View {
        if let data, let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            Color.gray.opacity(0.2)
        }
    }

    private func formatSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Compact mm:ss / hh:mm:ss for the row's duration line.
    private func formatDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    private func playLocal(_ item: SavedItem) {
        if item.isFromURL {
            // URL-fetched items don't have a YouTube `videoID` the resolver could use, and
            // the file's already on disk — `loadLocalFile` plays it directly without going
            // through `ensureDownloaded`. The synthetic Video built inside that method
            // gives the mini-player/popup chrome everything it needs.
            player.loadLocalFile(
                at: item.fileURL,
                title: item.title,
                source: item.channelName.isEmpty ? nil : item.channelName,
                thumbnailURL: nil
            )
            return
        }
        let video = Video(
            id: item.videoID,
            title: item.title,
            channelID: "",
            channelName: item.channelName,
            channelThumbnailURL: nil,
            thumbnailURL: nil,
            duration: nil,
            viewCount: nil,
            publishedAt: nil,
            descriptionSnippet: nil,
            isLive: false,
            isShort: false
        )
        player.load(video)
    }
}

/// Unified row data for the "Saved on device" section. Backed by `DownloadsStore`'s
/// per-file xattr metadata, with sensible fallbacks (filename-as-title) for files that
/// have no xattr (manually dropped into the Downloads folder, or written before the xattr
/// migration).
@available(iOS 17.0, *)
struct SavedItem: Identifiable {
    let id: String
    let videoID: String
    let title: String
    let channelName: String
    let fileURL: URL
    let fileSize: Int64
    let modifiedAt: Date
    let thumbnailData: Data?
    /// Read from AVURLAsset on construction. Sync (deprecated API but fine) so we can use it as a
    /// sort key without async plumbing.
    let duration: TimeInterval?
    /// `nil` for YouTube downloads (videoID alone reconstructs the canonical YouTube URL).
    /// Set to the original pasted URL for files downloaded via the "From URL" tab — drives
    /// the branch between `loadLocalFile` (URL items) and the YouTube resolver, and the
    /// "Open in browser" target.
    let originalURL: String?

    /// Convenience flag: true when this row came from the "From URL" tab. Drives tap and
    /// menu behavior in `DownloadsScreen` so we don't accidentally route an Instagram
    /// download through the YouTube resolver.
    var isFromURL: Bool { originalURL != nil }

    init(from entry: DownloadEntry) {
        let fallbackID = entry.fileURL.deletingPathExtension().lastPathComponent
        self.fileURL = entry.fileURL
        self.fileSize = entry.fileSize
        // Pre-resolved during the off-main scan — no sync `AVURLAsset` read here. With a
        // large library this was the dominant source of scroll lag (the row builder ran
        // per body re-evaluation, and `.duration.seconds` is a blocking moov-atom read).
        self.duration = entry.duration
        if let m = entry.metadata {
            self.id = m.videoID
            self.videoID = m.videoID
            self.title = m.title
            self.channelName = m.channelName
            self.modifiedAt = m.downloadedAt
            self.thumbnailData = m.thumbnailData
            self.originalURL = m.originalURL
        } else {
            // Orphan: file with no metadata xattr. Surface with filename as title so the
            // user can still identify and play it.
            self.id = fallbackID
            self.videoID = fallbackID
            self.title = fallbackID
            self.channelName = ""
            self.modifiedAt = entry.modifiedAt
            self.thumbnailData = nil
            self.originalURL = nil
        }
    }

}
