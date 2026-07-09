import Foundation
import Observation
import OSLog
import UIKit

/// Optional file mirror of the app's `os.Logger` output. Toggled from Settings; on TestFlight
/// or sideload installs (where the user can't run `Console.app` against a real device easily)
/// this is the only practical way to capture a diagnostic trail.
///
/// **How it works.** Each launch with the feature enabled opens a new file under
/// `Documents/Logs/` named `flux-YYYYMMDDTHHmmss-v<version>-b<build>.log` and writes a
/// header (app version, build, iOS version, device model, launch timestamp). Then it polls
/// the OSLogStore every 5 seconds, filters by `subsystem == "com.leshko.freetube"`, and
/// appends new entries to the file.
///
/// **Why poll instead of intercept**: there's no public API to attach a sink to
/// `os.Logger` — the Logger writes straight to the unified log facility (`os_log`). The
/// `OSLogStore` API (iOS 15+) lets us read back our own process's entries by timestamp,
/// which gives us the file mirror without touching the 257-call-site `AppLog(...)` wrapper.
///
/// **Storage location.** Documents root → visible in the Files app under "On My iPhone"
/// (gated by Info.plist's `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`).
/// Users can grab logs out without going through a Share sheet.
@available(iOS 17.0, *)
@Observable
@MainActor
final class LogFileWriter {
    static let shared = LogFileWriter()

    /// xattr / Settings-visible state. Mutates only on the main actor.
    private(set) var isEnabled: Bool
    /// Path of the active log file when `isEnabled == true`. nil when disabled or when the
    /// file couldn't be opened.
    private(set) var currentLogFileURL: URL?

    @ObservationIgnored private var fileHandle: FileHandle?
    @ObservationIgnored private var lastEntryDate: Date = .distantPast
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private let preferences = UserPreferences()
    @ObservationIgnored private let log = AppLog(subsystem: "com.leshko.freetube", category: "LogFileWriter")

    /// Subsystem we filter the OSLogStore by. The app uses one subsystem; keeping the
    /// filter to it avoids dumping iOS system noise into the user's log files.
    nonisolated static let subsystem = "com.leshko.freetube"
    /// Poll interval. 5s is a compromise: short enough that logs land near the event,
    /// long enough that the OSLogStore query doesn't run constantly.
    nonisolated static let flushInterval: Duration = .seconds(5)

    private init() {
        // Read the persisted flag synchronously so the writer starts immediately on first
        // launch if the user had it enabled previously.
        isEnabled = UserPreferences().logToFile
        if isEnabled {
            start()
        }
    }

    // MARK: - Public

    /// Toggle file logging on or off. Persists the flag and starts/stops the writer.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        preferences.logToFile = enabled
        if enabled {
            start()
        } else {
            stop()
        }
    }

    /// All log files in `Documents/Logs/`, newest first by filename (which sorts
    /// chronologically since names start with ISO date).
    nonisolated static func allLogFiles() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: logsDirectory(), includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { $0.pathExtension.lowercased() == "log" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Where the writer keeps log files. Exposed for the "Reveal in Finder" button.
    nonisolated static func logsDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("Logs", isDirectory: true)
    }

    /// Removes every log file (current + historical). If logging is still enabled, opens
    /// a fresh file so the next entries have somewhere to land.
    func clearAllLogs() {
        stop()
        for url in Self.allLogFiles() {
            try? FileManager.default.removeItem(at: url)
        }
        if isEnabled {
            start()
        }
    }

    // MARK: - Lifecycle

    private func start() {
        stop()
        do {
            let dir = Self.logsDirectory()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(Self.makeFilename())
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            fileHandle = handle
            currentLogFileURL = url
            writeHeader(to: handle)
            // Capture the last minute of pre-start logs too — `AppEnvironment.init` runs
            // before this on cold launch, and we want those early lines (SessionManager
            // bootstrap, audio session setup) in the file.
            lastEntryDate = Date(timeIntervalSinceNow: -60)
            log.info("file logging started: \(url.lastPathComponent, privacy: .public)")

            flushTask = Task { [weak self] in
                // First flush comes near-immediately so the user doesn't stare at a
                // header-only file for 5 seconds wondering whether logging is working.
                // Subsequent flushes settle into the regular `flushInterval` cadence.
                try? await Task.sleep(for: .milliseconds(500))
                await self?.flushPass()
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.flushInterval)
                    await self?.flushPass()
                }
            }
        } catch {
            log.error("failed to start file logging: \(String(describing: error), privacy: .public)")
            currentLogFileURL = nil
            fileHandle = nil
        }
    }

    private func stop() {
        flushTask?.cancel()
        flushTask = nil
        // Last drain so any final entries make it to disk before the file closes.
        if fileHandle != nil {
            Task { @MainActor in
                await self.flushPass()
                try? self.fileHandle?.close()
                self.fileHandle = nil
                self.currentLogFileURL = nil
            }
        }
    }

    // MARK: - Flush

    /// Read new OSLogStore entries since `lastEntryDate` and append them to the file. The
    /// `OSLogStore.getEntries` call can be slow on log-heavy launches (it scans the
    /// in-memory log buffer), so it runs on a detached `.utility` task; only the file
    /// write happens on main.
    private func flushPass() async {
        guard fileHandle != nil else { return }
        let sinceDate = lastEntryDate
        let result = await Task.detached(priority: .utility) {
            Self.queryAndFormat(since: sinceDate)
        }.value
        guard !result.text.isEmpty else { return }
        if let data = result.text.data(using: .utf8) {
            try? fileHandle?.write(contentsOf: data)
        }
        if let last = result.lastDate {
            lastEntryDate = last
        }
    }

    /// Pure function over the OSLogStore — runs on the detached task. Returns the
    /// formatted text plus the timestamp of the last entry seen, so the caller can
    /// advance `lastEntryDate` exactly to that point (avoids re-fetching the same entry
    /// on the next pass).
    private nonisolated static func queryAndFormat(since: Date) -> (text: String, lastDate: Date?) {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: since)
            let entries = try store.getEntries(
                at: position,
                matching: NSPredicate(format: "subsystem == %@", subsystem)
            )
            var lines = ""
            var lastDate: Date?
            for entry in entries {
                guard let log = entry as? OSLogEntryLog else { continue }
                // OSLogStore is inclusive of the boundary timestamp; skip anything we
                // already wrote on the previous pass.
                if log.date <= since { continue }
                lines += format(entry: log)
                lastDate = log.date
            }
            return (lines, lastDate)
        } catch {
            return ("", nil)
        }
    }

    private nonisolated static func format(entry: OSLogEntryLog) -> String {
        let level: String
        switch entry.level {
        case .debug: level = "DEBUG"
        case .info: level = "INFO"
        case .notice: level = "NOTICE"
        case .error: level = "ERROR"
        case .fault: level = "FAULT"
        @unknown default: level = "?"
        }
        let ts = isoTimestampFormatter.string(from: entry.date)
        return "[\(ts)] [\(level)] [\(entry.category)] \(entry.composedMessage)\n"
    }

    private nonisolated static let isoTimestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: - File header

    private nonisolated static func makeFilename() -> String {
        let dateStr = filenameDateFormatter.string(from: Date())
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "flux-\(dateStr)-v\(version)-b\(build).log"
    }

    private nonisolated static let filenameDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private func writeHeader(to handle: FileHandle) {
        let device = UIDevice.current
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let launch = Self.isoTimestampFormatter.string(from: Date())
        let header = """
        =============================================
         FreeTube log
         App version:   \(version) (build \(build))
         iOS:           \(device.systemVersion)
         Device:        \(device.model)
         Launch:        \(launch)
         Subsystem:     \(Self.subsystem)
        =============================================

        """
        if let data = header.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }
}
