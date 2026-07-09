import Foundation
import SwiftData
import OSLog

/// Owns the SwiftData `ModelContainer`. Inject the container into the SwiftUI scene via
/// `.modelContainer(_:)` so any `@Query` view picks it up automatically.
@available(iOS 17.0, *)
enum PersistenceController {
    static let log = AppLog(subsystem: "com.leshko.freetube", category: "Persistence")

    static let sharedContainer: ModelContainer = {
        // Downloads moved to file-system + xattr storage (`DownloadsStore`) — no `DownloadedVideo`
        // model registered here anymore. Existing installs with stale `DownloadedVideo` tables in
        // the on-disk SQLite store are left untouched; SwiftData ignores tables for models that
        // aren't in the active schema.
        let schema = Schema([
            WatchHistoryEntry.self,
            SearchHistoryEntry.self,
            FavoriteVideo.self,
            FavoritePlaylist.self
        ])
        let config = ModelConfiguration(schema: schema)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            log.fault("Failed to construct ModelContainer: \(String(describing: error), privacy: .public)")
            fatalError("Unable to create ModelContainer: \(error)")
        }
    }()
}
