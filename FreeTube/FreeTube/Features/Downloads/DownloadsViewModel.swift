import Foundation
import Observation

/// Tiny façade around `DownloadManager` so the view stays declarative. `DownloadManager`
/// is itself `@Observable`, so the view reads `manager.activeTasks` directly — this
/// view-model only owns the error toast state and the cancel action.
@available(iOS 17.0, *)
@Observable
@MainActor
final class DownloadsViewModel {
    var errorState: ErrorState?

    let manager: DownloadManager

    init(manager: DownloadManager = .shared) {
        self.manager = manager
    }

    /// Cancel a transfer-queue row. Routes by snapshot kind:
    ///   - YouTube downloads (id is the snapshot UUID) → `DownloadManager.cancel(taskID:)`.
    ///   - URL downloads (id has `"fetch-"` prefix, set in `URLDownloadManager.transferSnapshotID`)
    ///     → `URLDownloadManager.cancel(url:)`. The original URL is stored in `snapshot.videoID`
    ///     for exactly this lookup.
    func cancel(_ snapshot: DownloadTaskSnapshot) {
        if snapshot.id.hasPrefix("fetch-") {
            URLDownloadManager.shared.cancel(url: snapshot.videoID)
        } else {
            manager.cancel(taskID: snapshot.id)
        }
    }
}
