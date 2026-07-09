import SwiftUI
import Kingfisher

struct CommentRow: View {
    let comment: Comment
    var onLike: () -> Void = {}
    var onDislike: () -> Void = {}
    var onReply: () -> Void = {}
    var onTranslate: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            KFImage(comment.authorThumbnailURL)
                .thumbnail(size: CGSize(width: 32, height: 32)) {
                    Circle().fill(.gray.opacity(0.2))
                }
                .resizable()
                .scaledToFill()
                .frame(width: 32, height: 32)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(comment.authorName).font(.caption.weight(.semibold))
                    Text(comment.publishedRelative).font(.caption2).foregroundStyle(.secondary)
                }
                Text(comment.bodyText).font(.subheadline)

                HStack(spacing: 16) {
                    Button(action: onLike) {
                        Label("\(comment.likeCount)", systemImage: comment.isLikedByUser ? "hand.thumbsup.fill" : "hand.thumbsup")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                    }
                    Button(action: onDislike) {
                        Image(systemName: comment.isDislikedByUser ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                            .font(.caption)
                    }
                    Button("Reply", action: onReply).font(.caption)
                    if let onTranslate {
                        Button("Translate", action: onTranslate).font(.caption)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
}
