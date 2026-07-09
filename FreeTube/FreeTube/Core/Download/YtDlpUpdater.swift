import Foundation
import Observation
import OSLog
import PythonKit
import YoutubeDL

/// Manages the on-disk yt-dlp Python module: weekly auto-refresh + manual "Update now".
///
/// **Why this exists.** `YoutubeDL-iOS` downloads yt-dlp from its GitHub Releases on first
/// launch (`YoutubeDL.loadPythonModule` → `downloadPythonModule`) and then never touches it
/// again. There's no version check, no TTL, no scheduled refresh — once the file is on disk
/// the package reuses it forever. Installed apps get stuck on whatever yt-dlp was current at
/// first launch, which is a problem when YouTube rotates the n-cipher or player.js layout
/// faster than monthly TestFlight builds can ship.
///
/// **What we add:**
/// 1. **Weekly TTL.** `refreshIfStale()` (called from `AppEnvironment.init`) checks
///    `lastYtDlpUpdate` — if older than 7 days, kicks a background re-download. Non-blocking;
///    if the network is down, the existing copy keeps working.
/// 2. **Manual update.** `updateNow()` always re-downloads regardless of TTL. Wired to the
///    "Update now" button in Settings.
/// 3. **Version readout.** After a successful download/load we read `yt_dlp.version.__version__`
///    and persist to `UserPreferences.ytDlpVersion` so Settings can display the running version
///    without spinning up a `YtDlp()` instance every time the screen renders.
///
/// **Concurrency.** All actor methods route Python work through `PythonRunner.shared` so we
/// inherit the same single-threaded interpreter discipline as the download path. We never
/// touch `YoutubeDL.downloadPythonModule` (a static method on the package) from the main actor.
///
/// **EJS hash compatibility caveat.** yt-dlp validates its bundled EJS solver against
/// `vendor.HASHES`. Our shipped `core.min.js`/`lib.min.js` are pinned at version `0.8.0` —
/// if yt-dlp auto-updates past a major/minor version that changes those hashes, the EJS path
/// silently disables and n-cipher solving falls back to the failing state. Worth a CLAUDE.md
/// re-pull note when a refresh lands a new yt-dlp version (visible in Settings's version row).
@available(iOS 17.0, *)
@Observable
@MainActor
final class YtDlpUpdater {
    static let shared = YtDlpUpdater()

    /// Re-download if the current file is older than this. One week is a deliberate compromise:
    /// long enough that we don't burn bandwidth on every cold launch, short enough that
    /// breaking-yt-dlp-updates land within a week of release. yt-dlp's own release cadence is
    /// roughly weekly, so a 7-day TTL aligns with how often there's something new to pull.
    static let ttl: TimeInterval = 7 * 24 * 60 * 60

    private let log = AppLog(subsystem: "com.leshko.freetube", category: "YtDlpUpdater")
    private let preferences = UserPreferences()

    /// True while a download is in flight. Settings observes this to disable the button and
    /// show a progress indicator. `@Observable`-friendly via `@MainActor` isolation — SwiftUI
    /// reads it on the main thread, only `YtDlpUpdater` writes to it, no Combine needed.
    private(set) var isUpdating: Bool = false

    /// Last update outcome, surfaced by the Settings UI as a status line under the button.
    /// Cleared on the next attempt so transient errors don't linger across sessions.
    private(set) var lastResult: UpdateResult?

    enum UpdateResult: Equatable {
        case success(version: String)
        case noChange(version: String)
        case failure(message: String)
    }

    private init() {}

    /// Called from `AppEnvironment.init`. Non-blocking: spawns a detached task so launch isn't
    /// delayed by network. Skips the refresh if the cached file is fresher than the TTL.
    func refreshIfStale() {
        let last = preferences.lastYtDlpUpdate
        if let last, Date().timeIntervalSince(last) < Self.ttl {
            log.info("yt-dlp is fresh (last updated \(last, privacy: .public)); skipping TTL refresh")
            return
        }

        log.info("yt-dlp stale (last updated \(String(describing: last), privacy: .public)); scheduling background refresh")
        Task.detached(priority: .utility) { [weak self] in
            await self?.performUpdate(force: false)
        }
    }

    /// User-triggered. Always re-downloads. The returned `UpdateResult` is also written to
    /// `lastResult` for any other observer.
    @discardableResult
    func updateNow() async -> UpdateResult {
        await performUpdate(force: true)
    }

    /// The actual download + version-read sequence. `force` only affects logging — both
    /// callers want a re-download by the time they hit this method (TTL was already checked
    /// by `refreshIfStale`).
    private func performUpdate(force: Bool) async -> UpdateResult {
        if isUpdating {
            log.info("yt-dlp update already in progress; ignoring concurrent request")
            return lastResult ?? .failure(message: "Update already in progress")
        }
        isUpdating = true
        defer { isUpdating = false }

        log.info("Downloading yt-dlp (force=\(force, privacy: .public))")
        do {
            try await YoutubeDL.downloadPythonModule()
        } catch {
            let msg = "Download failed: \(error.localizedDescription)"
            log.error("\(msg, privacy: .public)")
            let result = UpdateResult.failure(message: msg)
            lastResult = result
            return result
        }

        // Read the new version through `PythonRunner.runIsolated` — NOT a bare
        // `Task.detached`. Critical: CPython isn't thread-safe, and both this version
        // read and the yt-dlp pump's `freetube_yt_dlp` work end up calling
        // `Python.attemptImport("yt_dlp")`. If they run concurrently on different
        // cooperative-pool worker threads (e.g. user opens app + immediately taps a
        // video so the launch-time TTL refresh races a play-now download), CPython
        // crashes inside `_PyTuple_FromArray` during the import. Routing through
        // `runIsolated` enqueues this work behind any in-flight yt-dlp in the same
        // FIFO, so they take turns on the interpreter.
        //
        // The closure still has to call `try await YtDlp()` first: `YtDlp()`'s init runs
        // `PythonSupport.initialize()` (gated by `Py_IsInitialized()`), which sets up
        // PYTHONHOME so `Python.attemptImport("yt_dlp")` won't fail with `init_fs_encoding`
        // / `No module named 'encodings'`. After the first call it's a no-op.
        do {
            let newVersion = try await PythonRunner.shared.runIsolated {
                _ = try await YtDlp()
                let module = try Python.attemptImport("yt_dlp")
                guard let v = String(module.version.__version__) else {
                    throw YtDlpVersionError.notReadable
                }
                return v
            }

            let prevVersion = preferences.ytDlpVersion
            preferences.ytDlpVersion = newVersion
            preferences.lastYtDlpUpdate = Date()

            let result: UpdateResult
            if !prevVersion.isEmpty, prevVersion == newVersion {
                result = .noChange(version: newVersion)
                log.info("yt-dlp re-downloaded; version unchanged at \(newVersion, privacy: .public)")
            } else {
                result = .success(version: newVersion)
                log.info("yt-dlp updated: \(prevVersion.isEmpty ? "(none)" : prevVersion, privacy: .public) → \(newVersion, privacy: .public)")
            }
            lastResult = result
            return result

        } catch {
            // We did download successfully but couldn't read the version back. Don't bump
            // the timestamp — next launch will retry. (If the download is corrupt,
            // retrying is the right behavior; if PythonKit isn't initialized yet,
            // retry-on-next-launch hits the initialized state.)
            let msg = "Version read failed: \(error.localizedDescription)"
            log.error("\(msg, privacy: .public)")
            let result = UpdateResult.failure(message: msg)
            lastResult = result
            return result
        }
    }

    enum YtDlpVersionError: LocalizedError {
        case notReadable
        var errorDescription: String? { "yt_dlp.version.__version__ could not be read as String" }
    }
}
