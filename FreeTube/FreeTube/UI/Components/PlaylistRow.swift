import SwiftUI
import Kingfisher

/// Playlist list row. Used by search results, channel/library playlist lists.
///
/// Set `showsMoreMenu: true` to render a trailing ellipsis Menu next to the row content
/// (open in browser, copy URL, favorites). The Menu is a sibling of the tap target so taps
/// on it don't trigger `onTap` / the surrounding NavigationLink.
@available(iOS 17.0, *)
struct PlaylistRow: View {
    let playlist: Playlist

    /// Optional tap handler. **Leave nil when wrapping this row inside a `NavigationLink`** —
    /// an inner `Button` swallows the link's tap and pushing never happens. We only attach a
    /// `Button` when the caller actually provides a handler.
    var onTap: (() -> Void)? = nil

    var showsMoreMenu: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            if let onTap {
                Button(action: onTap) { content }
                    .buttonStyle(.plain)
            } else {
                content
            }

            if showsMoreMenu {
                PlaylistMoreActionsMenu(playlist: playlist)
            }
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            KFImage(playlist.thumbnailURL)
                .thumbnail(size: CGSize(width: 96, height: 56)) {
                    Color.gray.opacity(0.2)
                }
                .resizable()
                .scaledToFill()
                .frame(width: 96, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                if let count = playlist.videoCount {
                    Text("\(count) videos").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            // No manual chevron — when this row sits inside a `NavigationLink` in a List, iOS adds
            // its own disclosure chevron. Drawing one here was rendering a duplicate accessory.
        }
        .contentShape(Rectangle())
    }
}
