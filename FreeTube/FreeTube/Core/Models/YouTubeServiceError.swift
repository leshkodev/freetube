import Foundation

enum YouTubeServiceError: Error, Sendable {
    case notAuthenticated
    case rateLimited
    case videoUnavailable
    case streamExtractionFailed
    case cookieExpired
    case network(Error)
    case decoding(Error)
    case unknown(Error)
}

extension YouTubeServiceError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "You need to sign in to do that."
        case .rateLimited: return "YouTube is rate-limiting requests. Try again in a moment."
        case .videoUnavailable: return "This video is unavailable."
        case .streamExtractionFailed: return "Couldn't load the video stream."
        case .cookieExpired: return "Your session expired. Please sign in again."
        case .network(let error): return "Network error: \(error.localizedDescription)"
        case .decoding: return "Couldn't read YouTube's response."
        case .unknown(let error): return error.localizedDescription
        }
    }
}
