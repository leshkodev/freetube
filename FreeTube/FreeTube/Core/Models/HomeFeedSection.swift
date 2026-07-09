import Foundation

struct HomeFeedSection: Identifiable, Sendable {
    let id: String
    let title: String?
    let videos: [Video]
}

struct HomeFeed: Sendable {
    let sections: [HomeFeedSection]
    let continuationToken: String?
}
