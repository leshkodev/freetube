import SwiftUI
import Kingfisher

@available(iOS 17.0, *)
struct VideoDetailScreen: View {
    @State private var model: VideoDetailViewModel
    @Environment(PlayerStateManager.self) private var player

    init(videoID: String) {
        _model = State(wrappedValue: VideoDetailViewModel(videoID: videoID))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                thumbnail

                if let info = model.info {
                    metaBlock(info)
                    actionsRow(info)
                    descriptionBlock(info)
                    recommendedBlock(info)
                } else if model.isLoading {
                    LoadingView()
                } else {
                    EmptyStateView(systemImage: "play.rectangle",
                                   title: "Couldn't load video",
                                   message: "Pull to retry.")
                }
            }
            .padding(.vertical)
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .errorToast(Bindable(model).errorState)
    }

    private var thumbnail: some View {
        Button {
            if let video = model.info?.video { player.load(video) }
        } label: {
            ZStack {
                KFImage(model.info?.video.thumbnailURL)
                    .thumbnail(size: CGSize(width: 400, height: 225)) {
                        Color.gray.opacity(0.2)
                    }
                    .resizable()
                    .scaledToFill()
                    .aspectRatio(16/9, contentMode: .fit)
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(radius: 4)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func metaBlock(_ info: VideoInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(info.video.title).font(.headline)
            if let views = info.video.viewCount {
                Text("\(views) views").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private func actionsRow(_ info: VideoInfo) -> some View {
        HStack(spacing: 20) {
            Button {
                Task { await model.toggleLike() }
            } label: {
                Label("\(info.likeCount ?? 0)", systemImage: info.isLikedByUser ? "hand.thumbsup.fill" : "hand.thumbsup")
            }
            Button {
                Task { await model.toggleDislike() }
            } label: {
                Image(systemName: info.isDislikedByUser ? "hand.thumbsdown.fill" : "hand.thumbsdown")
            }
            ShareLink(item: URL(string: "https://www.youtube.com/watch?v=\(info.video.id)")!) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            Button {
                // TODO: present SaveToPlaylistSheet
            } label: {
                Label("Save", systemImage: "bookmark")
            }
            Button {
                // TODO: enqueue user download
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal)
    }

    @ViewBuilder
    private func descriptionBlock(_ info: VideoInfo) -> some View {
        if let text = info.descriptionText, !text.isEmpty {
            Text(text).font(.footnote).padding(.horizontal)
        }
    }

    @ViewBuilder
    private func recommendedBlock(_ info: VideoInfo) -> some View {
        if !info.recommended.isEmpty {
            SectionHeader(title: "Up next")
            ForEach(info.recommended) { video in
                VideoRow(video: video) {
                    player.load(video)
                }
            }
        }
    }
}
