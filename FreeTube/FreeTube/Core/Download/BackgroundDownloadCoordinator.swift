import Foundation
import BackgroundTasks
import OSLog

/// Bridges `URLSessionDownloadDelegate` callbacks and `BGProcessingTaskRequest` so user-initiated
/// downloads survive backgrounding.
///
/// Per CLAUDE.md §10:
/// - Use `URLSession.background(withIdentifier:)`.
/// - Register a `BGProcessingTaskRequest` for resumed downloads on next launch.
///
/// Integration glue (call sites the project must wire up):
/// 1. In `FreeTubeApp.init`, call `BackgroundDownloadCoordinator.shared.registerBackgroundTasks()`.
/// 2. Add the background-task identifier to `Info.plist` under `BGTaskSchedulerPermittedIdentifiers`.
/// 3. In the app delegate's `handleEventsForBackgroundURLSession`, forward the completion handler to
///    `BackgroundDownloadCoordinator.shared.setBackgroundEventsCompletionHandler(_:identifier:)`.
@available(iOS 17.0, *)
final class BackgroundDownloadCoordinator: NSObject {
    static let shared = BackgroundDownloadCoordinator()

    static let sessionIdentifier = "com.leshko.freetube.downloads"
    static let bgTaskIdentifier = "com.leshko.freetube.resume-downloads"

    private let log = AppLog(subsystem: "com.leshko.freetube", category: "BGDownloads")
    private var backgroundCompletionHandler: (() -> Void)?

    lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
    }

    // MARK: - BG task lifecycle

    func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.bgTaskIdentifier,
            using: nil
        ) { [weak self] task in
            self?.handle(task: task as? BGProcessingTask)
        }
        scheduleNextBackgroundTask()
    }

    func scheduleNextBackgroundTask() {
        let request = BGProcessingTaskRequest(identifier: Self.bgTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        do {
            try BGTaskScheduler.shared.submit(request)
            log.info("Scheduled BG processing task")
        } catch {
            log.error("Failed to schedule BG task: \(String(describing: error), privacy: .public)")
        }
    }

    private func handle(task: BGProcessingTask?) {
        guard let task else { return }
        log.info("Handling BG processing task")
        task.expirationHandler = {
            // No-op: URLSession background downloads continue independently of the BG task lifecycle.
        }
        scheduleNextBackgroundTask()
        task.setTaskCompleted(success: true)
    }

    func setBackgroundEventsCompletionHandler(_ handler: @escaping () -> Void, identifier: String) {
        guard identifier == Self.sessionIdentifier else { return }
        backgroundCompletionHandler = handler
    }
}

@available(iOS 17.0, *)
extension BackgroundDownloadCoordinator: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        log.info("Download finished to temp \(location.path, privacy: .public)")
        // TODO: hand off to DownloadManager for final placement + SwiftData insertion.
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            log.error("Download error: \(String(describing: error), privacy: .public)")
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            self?.backgroundCompletionHandler?()
            self?.backgroundCompletionHandler = nil
        }
    }
}
