import Foundation

struct SearchSuggestion: Identifiable, Hashable, Sendable {
    var id: String { text }
    let text: String
}
