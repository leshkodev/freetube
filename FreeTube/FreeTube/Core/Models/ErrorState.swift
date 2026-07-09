import Foundation

struct ErrorState: Equatable, Identifiable {
    let id = UUID()
    let message: String
    let isFatal: Bool

    init(message: String, isFatal: Bool = false) {
        self.message = message
        self.isFatal = isFatal
    }

    init(from error: Error) {
        self.message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        self.isFatal = false
    }
}
