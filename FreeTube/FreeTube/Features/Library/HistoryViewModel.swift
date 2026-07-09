import Foundation
import Observation

@available(iOS 17.0, *)
@Observable
@MainActor
final class HistoryViewModel {
    private(set) var videos: [Video] = []
    private(set) var isLoading: Bool = false
    /// Separate flag for "load more in progress" so the row-level prefetch trigger can avoid
    /// firing duplicate continuation requests while the previous page is still en route.
    private(set) var isLoadingMore: Bool = false
    /// Continuation token from the most recent response. Nil → no more pages, the list is done.
    private(set) var continuationToken: String?
    var errorState: ErrorState?

    private let service: any HistoryServicing

    init(service: any HistoryServicing = HistoryService()) {
        self.service = service
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await service.fetch()
            videos = page.videos
            continuationToken = page.continuationToken
        } catch {
            errorState = ErrorState(from: error)
        }
    }

    /// True when more pages remain AND we're not already fetching one. The screen reads this
    /// from its row `.onAppear` to decide whether to trigger another `loadMore`.
    var canLoadMore: Bool {
        continuationToken != nil && !isLoadingMore && !isLoading
    }

    /// Appends the next history page. Dedupes concurrent callers via `isLoadingMore`.
    func loadMore() async {
        guard let token = continuationToken, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await service.fetchMore(continuation: token)
            videos.append(contentsOf: page.videos)
            continuationToken = page.continuationToken
        } catch {
            errorState = ErrorState(from: error)
        }
    }

    func remove(_ video: Video) async {
        do {
            try await service.remove(videoID: video.id)
            videos.removeAll { $0.id == video.id }
        } catch {
            errorState = ErrorState(from: error)
        }
    }
}
