import Foundation

struct Channel: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let handle: String?
    let thumbnailURL: URL?
    let bannerURL: URL?
    let subscriberCount: Int?
    let videoCount: Int?
    let isSubscribed: Bool
    let descriptionText: String?
}
