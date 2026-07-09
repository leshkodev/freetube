import Foundation
import SwiftUI

/// Lightweight user preferences stored in `UserDefaults` via `@AppStorage`. Use this for primitive flags only;
/// anything queryable belongs in SwiftData.
struct UserPreferences {
    /// Default to 360p on a fresh install — it's the only YouTube format that ships as a single
    /// combined progressive mp4 (itag 18), so downloads complete fast and skip the Swift-side
    /// ffmpeg mux step. Users can bump it higher in Settings.
    @AppStorage("preferredQuality") var preferredQualityRaw: String = VideoQuality.p360.rawValue
    @AppStorage("alwaysDownloadBeforePlayback") var alwaysDownloadBeforePlayback: Bool = false
    /// When `true`, downloads (and playback-time fetches, since those use the same path) are
    /// allowed to run over cellular. Default is `true` — permissive — so a fresh install
    /// works out of the box on a phone without Wi-Fi. Users who pay per MB can disable this
    /// and the network gate in `DownloadManager.waitForAllowedNetwork` will throw until
    /// Wi-Fi comes back. Was previously stored under the `wifiOnlyDownloads` key with the
    /// opposite meaning (true = blocked on cellular); fresh key here so the default flips
    /// cleanly for existing installs.
    @AppStorage("allowCellularDownloads") var allowCellularDownloads: Bool = true
    @AppStorage("autoplayNext") var autoplayNext: Bool = true
    /// When true, `LogFileWriter` opens a new file under `Documents/Logs/` on every app
    /// launch and mirrors the unified-log entries for our subsystem into it. Useful for
    /// capturing diagnostic traces from TestFlight / sideload installs where Console.app
    /// access isn't practical. Defaults off — only a handful of users will ever flip this.
    @AppStorage("logToFile") var logToFile: Bool = false
    /// When true (default), `PlayerStateManager` kicks off a background download of the
    /// next queue item right after the current video starts playing — so Next-tap is
    /// instant. Users who want to save bandwidth (or who tend not to advance through the
    /// queue) can flip this off in Settings.
    @AppStorage("prefetchNextInQueue") var prefetchNextInQueue: Bool = true
    @AppStorage("restrictedSearchMode") var restrictedSearchMode: Bool = false
    @AppStorage("appearanceMode") var appearanceModeRaw: String = AppearanceMode.system.rawValue
    @AppStorage("downloadCacheLimit") var downloadCacheLimitRaw: String = DownloadCacheLimit.unlimited.rawValue
    /// `--concurrent-fragments` value passed to yt-dlp. Higher values fetch more DASH/HLS chunks
    /// in parallel within a single download, cutting wall-clock time. Defaults to 4 — a good
    /// balance for cellular and consumer Wi-Fi. Values above 8 risk YouTube rate-limiting.
    @AppStorage("concurrentFragments") var concurrentFragments: Int = 4
    /// Persisted playback rate (1.0 = normal speed). Mirrors `AVPlayer.defaultRate`, which is the
    /// value `AVPlayerViewController`'s built-in speed menu writes when the user picks 0.5×/1.5×/2×.
    /// `PlayerStateManager` reads this on init and observes the player's `defaultRate` to write
    /// changes back here — so a relaunch picks up where the last session left off.
    @AppStorage("playbackRate") var playbackRate: Double = 1.0

    /// yt-dlp `__version__` from the last successful download/load (e.g. `"2026.3.17"`).
    /// Empty until `YtDlpUpdater` has loaded the module at least once. Displayed in Settings so
    /// the user can see what version they're running without opening the device log.
    @AppStorage("ytDlpVersion") var ytDlpVersion: String = ""

    /// UNIX timestamp of the last successful yt-dlp re-download. `Date` itself isn't `AppStorage`-
    /// compatible without a wrapper, so we store the time interval and expose `Date?` below.
    /// Zero means "never refreshed since install" — the launch-time TTL check treats that as
    /// "use whatever's on disk" (the package's first-run download set it up).
    @AppStorage("lastYtDlpUpdate") var lastYtDlpUpdateRaw: Double = 0

    /// JSON-encoded `[RecentFetchURL]` for the "From URL" tab's recents list. Kept as JSON
    /// in `@AppStorage` instead of a SwiftData `@Model` because (a) it's a small bounded
    /// list (capped at 20), (b) the UI only ever reads the whole array, never queries it,
    /// and (c) keeping it in `UserDefaults` matches the rest of this struct's conventions.
    @AppStorage("recentFetchURLs") var recentFetchURLsJSON: String = "[]"

    var preferredQuality: VideoQuality {
        get { VideoQuality(rawValue: preferredQualityRaw) ?? .auto }
        nonmutating set { preferredQualityRaw = newValue.rawValue }
    }

    var appearanceMode: AppearanceMode {
        get { AppearanceMode(rawValue: appearanceModeRaw) ?? .system }
        nonmutating set { appearanceModeRaw = newValue.rawValue }
    }

    var downloadCacheLimit: DownloadCacheLimit {
        get { DownloadCacheLimit(rawValue: downloadCacheLimitRaw) ?? .unlimited }
        nonmutating set { downloadCacheLimitRaw = newValue.rawValue }
    }

    /// `nil` when yt-dlp has never been refreshed by `YtDlpUpdater` (initial install state).
    var lastYtDlpUpdate: Date? {
        get { lastYtDlpUpdateRaw > 0 ? Date(timeIntervalSince1970: lastYtDlpUpdateRaw) : nil }
        nonmutating set { lastYtDlpUpdateRaw = newValue?.timeIntervalSince1970 ?? 0 }
    }

    /// Decodes the JSON-backed recent URLs list. Returns an empty array if the stored JSON is
    /// malformed (defensive — corruption shouldn't take down the tab).
    var recentFetchURLs: [RecentFetchURL] {
        get {
            guard let data = recentFetchURLsJSON.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([RecentFetchURL].self, from: data)) ?? []
        }
        nonmutating set {
            let trimmed = Array(newValue.prefix(20))
            if let data = try? JSONEncoder().encode(trimmed), let str = String(data: data, encoding: .utf8) {
                recentFetchURLsJSON = str
            }
        }
    }
}

/// One entry in the recent-URLs list shown on the "From URL" tab. Stored as JSON inside
/// `UserPreferences.recentFetchURLsJSON`. We cap the list at 20 entries — anything older
/// gets dropped on insert.
///
/// **State the row needs to render across app launches:** URL, title, extractor, remote
/// thumbnail URL (Kingfisher caches the bitmap on disk), and the local file path of any
/// completed download. The `URLDownloadManager.jobs` dict is in-memory only, so any
/// completed download we want to preserve across launches has to write its file path here.
struct RecentFetchURL: Codable, Hashable, Identifiable, Sendable {
    /// The URL string the user typed/pasted, unmodified. Used as identity so re-fetching the
    /// same URL bubbles its entry to the top instead of creating a duplicate.
    let url: String
    /// Title from the last successful probe of this URL. Optional — the entry exists from
    /// the moment the URL is submitted, but the title isn't known until probe completes.
    var title: String?
    /// Source/extractor name (e.g. "Youtube", "Vimeo") for the small badge in the UI.
    var extractor: String?
    /// Remote thumbnail URL from the probe. Rendered by `KFImage` which caches it on disk so
    /// the row keeps showing the thumb even when the user is offline.
    var thumbnailURL: String?
    /// File-system path (under Documents) of the completed download. `nil` while
    /// the URL has been probed but not yet downloaded. We persist the relative filename
    /// rather than the absolute path because the iOS container path can change across
    /// reinstalls — `URLDownloadManager.fileURL(for:)` re-resolves the absolute path.
    var localFilename: String?
    var lastUsedAt: Date

    var id: String { url }
}

/// Caps the total on-disk size of downloaded videos. When the cache exceeds the limit after a
/// new download lands, the oldest entries are evicted (by `downloadedAt`) until total bytes fit.
enum DownloadCacheLimit: String, CaseIterable, Identifiable {
    case gb1, gb5, gb10, unlimited

    var id: String { rawValue }

    /// `nil` means "no cap — keep downloading until the device runs out of storage".
    var bytes: Int64? {
        switch self {
        case .gb1: return 1 * 1_073_741_824
        case .gb5: return 5 * 1_073_741_824
        case .gb10: return 10 * 1_073_741_824
        case .unlimited: return nil
        }
    }

    var displayName: String {
        switch self {
        case .gb1: return "1 GB"
        case .gb5: return "5 GB"
        case .gb10: return "10 GB"
        case .unlimited: return "Unlimited"
        }
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
