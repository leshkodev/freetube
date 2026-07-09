import SwiftUI
import Kingfisher

struct ChannelRow: View {
    let channel: Channel
    /// Optional tap handler. **Leave nil when wrapping this row inside a `NavigationLink`** —
    /// the inner `Button` was swallowing the link's tap, which made channel rows in search
    /// results feel "hard to hit": you had to land precisely on the disclosure indicator area
    /// instead of anywhere on the row. Mirrors the same pattern PlaylistRow uses.
    var onTap: (() -> Void)? = nil
    var trailing: AnyView? = nil

    /// Single secondary line below the channel name. Combines handle (when present) and an
    /// abbreviated subscriber count ("1.2M subscribers"). Joined by a middle dot so it degrades
    /// gracefully when either half is missing.
    private var detailLine: String {
        var parts: [String] = []
        if let handle = channel.handle, !handle.isEmpty { parts.append(handle) }
        if let subs = channel.subscriberCount {
            parts.append("\(Self.formattedCount(subs)) subscribers")
        }
        return parts.joined(separator: " • ")
    }

    var body: some View {
        if let onTap {
            Button(action: onTap) { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            KFImage(channel.thumbnailURL)
                .thumbnail(size: CGSize(width: 48, height: 48)) {
                    Circle().fill(.gray.opacity(0.2))
                }
                .resizable()
                .scaledToFill()
                .frame(width: 48, height: 48)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name).font(.subheadline.weight(.semibold))
                if !detailLine.isEmpty {
                    Text(detailLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            trailing
        }
        .contentShape(Rectangle())
    }

    /// Compact "1.2M" / "856K" / "12,345" formatter for subscriber counts. Static so SwiftUI's
    /// view recompute doesn't allocate a fresh formatter each call.
    private static func formattedCount(_ value: Int) -> String {
        if value >= 1_000_000_000 { return String(format: "%.1fB", Double(value) / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }
}
