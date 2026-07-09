import Foundation
import Observation
import OSLog

@available(iOS 17.0, *)
@Observable
@MainActor
final class HomeViewModel {
    private(set) var sections: [HomeFeedSection] = []
    private(set) var isLoading: Bool = false
    private(set) var continuationToken: String?
    var errorState: ErrorState?

    private let service: any HomeServicing
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "HomeViewModel")

    init(service: any HomeServicing = HomeService()) {
        self.service = service
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let feed = try await service.fetchHome()
            sections = feed.sections
            continuationToken = feed.continuationToken
        } catch {
            log.error("Home fetch failed: \(String(describing: error), privacy: .public)")
            errorState = ErrorState(from: error)
        }
    }

    func loadMore() async {
        guard let token = continuationToken, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let feed = try await service.fetchMore(continuation: token)
            sections.append(contentsOf: feed.sections)
            continuationToken = feed.continuationToken
        } catch {
            errorState = ErrorState(from: error)
        }
    }

    func refresh() async {
        continuationToken = nil
        sections = []
        await load()
    }
}
