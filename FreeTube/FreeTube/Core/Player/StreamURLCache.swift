import Foundation
import OSLog

/// In-memory cache of resolved direct stream URLs. Per CLAUDE.md §2/§7: signed URLs are sensitive
/// and time-limited — they never touch disk. 30-minute TTL.
actor StreamURLCache {
    static let shared = StreamURLCache()

    struct Key: Hashable {
        let videoID: String
        let formatID: String
    }

    private struct Entry {
        let url: URL
        let expiresAt: Date
    }

    private var entries: [Key: Entry] = [:]
    private let ttl: TimeInterval
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "StreamURLCache")

    init(ttl: TimeInterval = 30 * 60) {
        self.ttl = ttl
    }

    func get(videoID: String, formatID: String) -> URL? {
        let key = Key(videoID: videoID, formatID: formatID)
        guard let entry = entries[key] else { return nil }
        if entry.expiresAt < .now {
            entries[key] = nil
            return nil
        }
        return entry.url
    }

    func set(videoID: String, formatID: String, url: URL) {
        let key = Key(videoID: videoID, formatID: formatID)
        entries[key] = Entry(url: url, expiresAt: .now.addingTimeInterval(ttl))
        log.debug("Cached stream URL for \(videoID, privacy: .public)/\(formatID, privacy: .public)")
    }

    func purge() {
        entries.removeAll()
    }
}
