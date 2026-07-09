import SwiftUI
import Kingfisher
import UIKit

/// **Link** tab — the user pastes any URL yt-dlp supports (YouTube, Vimeo, Twitter/X,
/// TikTok, SoundCloud, ~2000 sites total per yt-dlp's extractor count), we probe via
/// `YtDlpInfoService`, then push `FetchProbeView` with a format picker. After downloading,
/// the user is popped back here — the row below the URL input shows the title, a thumbnail,
/// and a More menu to play / share / open in browser / reveal in Finder.
///
/// **One queue, one section.** The "Recent" list isn't just history anymore: every URL the
/// user has ever probed or downloaded shows up as a row, and rows that have an active
/// `URLDownloadManager.jobs` entry render live progress in place. There's no separate
/// "Active downloads" section to duplicate against — the join happens in `rowState(for:)`.
@available(iOS 17.0, *)
struct FetchScreen: View {
    @State private var model = FetchViewModel()
    @State private var downloads = URLDownloadManager.shared
    @Environment(PlayerStateManager.self) private var player
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "link")
                            .foregroundStyle(.secondary)
                        TextField("Paste a link…", text: $model.query)
                            .textFieldStyle(.plain)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .submitLabel(.go)
                            .focused($fieldFocused)
                            .onSubmit {
                                fieldFocused = false
                                model.submit()
                            }
                        if !model.query.isEmpty {
                            Button {
                                model.query = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)

                    Button {
                        fieldFocused = false
                        model.submit()
                    } label: {
                        HStack {
                            Spacer()
                            Image(systemName: "arrow.right.circle.fill")
                            Text("Fetch")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } footer: {
                    Text("Works with YouTube, Vimeo, X/Twitter, TikTok, SoundCloud, and ~2,000 other sites supported by yt-dlp.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !model.recents.isEmpty {
                    Section {
                        // `id: \.url` keys rows by URL so SwiftUI keeps the same row across
                        // state transitions (active → completed) — preventing a row from
                        // flashing or losing its in-progress chrome between updates.
                        ForEach(model.recents) { entry in
                            FetchQueueRow(
                                entry: entry,
                                state: model.rowState(for: entry),
                                onTap: { handleTap(entry: entry) },
                                onRedownload: { model.reopenProbe(for: entry) },
                                onDelete: { model.deleteRecent(entry) }
                            )
                        }
                    } header: {
                        HStack {
                            Text("Recent")
                            Spacer()
                            Button("Clear", role: .destructive) {
                                model.clearRecents()
                            }
                            .font(.caption)
                            .buttonStyle(.plain)
                            .textCase(nil)
                        }
                    }
                }
            }
            .navigationTitle("Link")
            .navigationDestination(isPresented: probeNavBinding) {
                FetchProbeView(model: model)
            }
        }
    }

    /// Tap handler. Completed rows play the local file; everything else opens the Preview
    /// screen for that URL (so the user can pick formats / re-pick formats and retry).
    private func handleTap(entry: RecentFetchURL) {
        if case .completed(let fileURL) = model.rowState(for: entry) {
            player.loadLocalFile(
                at: fileURL,
                title: entry.title ?? entry.url,
                source: entry.extractor,
                thumbnailURL: entry.thumbnailURL.flatMap(URL.init(string:))
            )
        } else {
            model.reopenProbe(for: entry)
        }
    }

    /// Two-way binding the navigation destination uses to push/pop based on `probeState`.
    private var probeNavBinding: Binding<Bool> {
        Binding(
            get: {
                switch model.probeState {
                case .idle: return false
                case .loading, .loaded, .failed: return true
                }
            },
            set: { isActive in
                if !isActive { model.clearResult() }
            }
        )
    }
}

/// Single row in the "Recent" list. Renders a 56×56 thumbnail on the left, title + status
/// caption in the middle, and the per-state trailing control on the right (More menu when
/// completed, simple chevron / spinner / Redownload otherwise).
///
/// **In-flight downloads do not render progress bars or Cancel buttons here** — those live
/// in the shared transfer queue under the Downloads tab. This row's job is just to surface
/// the URL's status; the actual queue UX is one place (Downloads).
///
/// The row's tap target is the whole HStack — `onTap` dispatches based on state at the
/// callsite (playback for completed, re-probe for everything else).
@available(iOS 17.0, *)
struct FetchQueueRow: View {
    let entry: RecentFetchURL
    let state: FetchViewModel.RowState
    let onTap: () -> Void
    let onRedownload: () -> Void
    let onDelete: () -> Void

    @State private var showingShareSheet = false

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title ?? entry.url)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                stateCaption
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            trailingControl
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .sheet(isPresented: $showingShareSheet) {
            if case .completed(let fileURL) = state {
                ActivityShareSheet(activityItems: [fileURL])
            }
        }
    }

    // MARK: - Thumbnail

    @ViewBuilder
    private var thumbnail: some View {
        if let urlString = entry.thumbnailURL, let url = URL(string: urlString) {
            KFImage(url)
                .placeholder {
                    placeholderThumbnail
                }
                .resizable()
                .scaledToFill()
        } else {
            placeholderThumbnail
        }
    }

    @ViewBuilder
    private var placeholderThumbnail: some View {
        ZStack {
            Color.gray.opacity(0.18)
            Image(systemName: stateIconName)
                .foregroundStyle(.secondary)
        }
    }

    private var stateIconName: String {
        switch state {
        case .completed: return "play.rectangle.fill"
        case .downloading, .processing: return "arrow.down.circle"
        case .failed: return "exclamationmark.triangle"
        case .idle: return "link"
        }
    }

    // MARK: - Caption

    @ViewBuilder
    private var stateCaption: some View {
        switch state {
        case .idle:
            Text(hostLabel)
        case .downloading(let progress, let phase):
            Text(downloadingCaption(progress: progress, phase: phase))
        case .processing(let message):
            Text(message)
        case .completed:
            Text("Ready · \(hostLabel)")
        case .failed(let msg):
            Text(msg)
                .foregroundStyle(.red)
                .lineLimit(1)
        }
    }

    /// "Downloading 45% · Stream", or "Downloading · Stream" when the phase is indeterminate
    /// (ffmpeg HLS pass). The phase suffix is dropped when it's empty so we don't print " · ".
    private func downloadingCaption(progress: Double?, phase: String?) -> String {
        let prefix: String
        if let progress, progress > 0 {
            let pct = Int((progress * 100).rounded())
            prefix = String(format: String(localized: "Downloading %lld%%"), pct)
        } else {
            prefix = String(localized: "Downloading")
        }
        if let phase, !phase.isEmpty {
            return "\(prefix) · \(phase)"
        }
        return prefix
    }

    // MARK: - Trailing control

    @ViewBuilder
    private var trailingControl: some View {
        switch state {
        case .idle:
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        case .downloading, .processing:
            // Progress lives in the caption (e.g. "Downloading 45% · Stream"). No spinner —
            // the changing percentage is the activity indicator.
            EmptyView()
        case .failed:
            Button {
                onRedownload()
            } label: {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
        case .completed(let fileURL):
            Menu {
                Button {
                    showingShareSheet = true
                } label: {
                    Label("Open in…", systemImage: "square.and.arrow.up")
                }
                // "Reveal in Finder" is meaningful only when the app is running on macOS
                // (either via "Designed for iPad" or true Catalyst). On iOS the Files app
                // surfaces our Documents directory but there's no shortcut to
                // a specific path, so we hide the option.
                if MacIntegration.isRunningOnMac {
                    Button {
                        MacIntegration.revealInFinder(fileURL)
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                }
                Button {
                    UIPasteboard.general.string = entry.url
                } label: {
                    Label("Copy URL", systemImage: "doc.on.doc")
                }
                Button {
                    if let url = URL(string: entry.url) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Open in browser", systemImage: "safari")
                }
                Divider()
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
        }
    }

    private var hostLabel: String {
        if let extractor = entry.extractor, !extractor.isEmpty {
            return "\(extractor) · \(URL(string: entry.url)?.host ?? entry.url)"
        }
        return URL(string: entry.url)?.host ?? entry.url
    }

}
