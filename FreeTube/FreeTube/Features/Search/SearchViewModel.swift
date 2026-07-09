import Foundation
import Observation
import OSLog

@available(iOS 17.0, *)
@Observable
@MainActor
final class SearchViewModel {
    var query: String = "" {
        didSet { scheduleAutocomplete() }
    }
    private(set) var suggestions: [SearchSuggestion] = []
    private(set) var results: SearchResult?
    private(set) var isLoading: Bool = false
    var errorState: ErrorState?

    private let service: any SearchServicing
    private let preferences = UserPreferences()
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "SearchViewModel")

    private var autocompleteTask: Task<Void, Never>?

    init(service: any SearchServicing = SearchService()) {
        self.service = service
    }

    /// Drops the previous search's results + suggestions so the embedding view can fall
    /// back to its non-search state. Called when the search field is cleared.
    func clearResults() {
        results = nil
        suggestions = []
        isLoading = false
        autocompleteTask?.cancel()
    }

    func submit() async {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await service.search(query: query, restricted: preferences.restrictedSearchMode)
            results = result
            suggestions = []
        } catch {
            errorState = ErrorState(from: error)
        }
    }

    func loadMore() async {
        guard let token = results?.continuationToken, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let next = try await service.fetchMore(continuation: token)
            let mergedVideos = (results?.videos ?? []) + next.videos
            let mergedChannels = (results?.channels ?? []) + next.channels
            let mergedPlaylists = (results?.playlists ?? []) + next.playlists
            results = SearchResult(
                videos: mergedVideos,
                channels: mergedChannels,
                playlists: mergedPlaylists,
                continuationToken: next.continuationToken
            )
        } catch {
            errorState = ErrorState(from: error)
        }
    }

    private func scheduleAutocomplete() {
        autocompleteTask?.cancel()
        let snapshot = query
        autocompleteTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.runAutocomplete(snapshot)
        }
    }

    private func runAutocomplete(_ q: String) async {
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else {
            suggestions = []
            return
        }
        do {
            suggestions = try await service.autocomplete(query: q)
        } catch {
            // Autocomplete failures are silent.
            log.debug("Autocomplete failed: \(String(describing: error), privacy: .public)")
        }
    }
}
