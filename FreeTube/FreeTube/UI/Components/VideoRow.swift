import SwiftUI
import Kingfisher

/// Horizontal compact video row — used in search results, history, library lists.
///
/// Set `showsMoreMenu: true` to render a trailing ellipsis Menu next to the row content
/// (open in browser, copy URL, favorites, add to playlist, downloads). The Menu lives as a
/// sibling of the main tap target so taps on it don't trigger `onTap`.
@available(iOS 17.0, *)
struct VideoRow: View {
    let video: Video
    var onTap: () -> Void = {}
    var showsMoreMenu: Bool = false

    /// Playback count + relative upload date joined by a middle dot. Either half can be empty
    /// (older listings sometimes omit one), so we filter before joining to avoid stray separators.
    private var statsLine: String {
        [video.viewCountString, video.publishedRelative ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " • ")
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onTap) {
                content
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)

            if showsMoreMenu {
                VideoMoreActionsMenu(video: video)
            }
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                KFImage(video.thumbnailURL)
                    .thumbnail(size: CGSize(width: 168, height: 96)) {
                        Color.gray.opacity(0.2)
                    }
                    .resizable()
                    .scaledToFill()
                    .frame(width: 168, height: 96)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                if !video.durationString.isEmpty {
                    Text(video.durationString)
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.black.opacity(0.75))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .padding(4)
                }
            }
            .frame(width: 168, height: 96)

            VStack(alignment: .leading, spacing: 4) {
                Text(video.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(video.channelName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !statsLine.isEmpty {
                    Text(statsLine)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
    }
}
