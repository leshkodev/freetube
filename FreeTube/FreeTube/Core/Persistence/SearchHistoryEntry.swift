import Foundation
import SwiftData

@available(iOS 17.0, *)
@Model
final class SearchHistoryEntry {
    @Attribute(.unique) var query: String
    var searchedAt: Date

    init(query: String, searchedAt: Date = .now) {
        self.query = query
        self.searchedAt = searchedAt
    }
}
