# CLAUDE.md

This file gives Claude Code the context, constraints, and conventions it must follow when working in this repository. Read it fully before touching any code. Re-read it when starting a new session.

---

## 1. What this project is

**FreeTube iOS** — a native SwiftUI YouTube client that replicates the YouTube mobile app: home feed, search, playback, login, subscriptions, library, history, playlists, comments, likes, downloads. Plus a "Link" tab for downloading from any of ~2,000 sites supported by yt-dlp.

**Distribution:** TestFlight internal, sideload, or personal use. **Not for public App Store submission.** Do not suggest changes that assume App Store distribution.

**Platforms:** iOS 17.0+, Swift 5.9+, Xcode 15+.

**Bundle identifier:** `com.leshko.freetube`. This is also the reverse-DNS namespace for the `os.Logger` subsystem, the Keychain cookie key (`com.leshko.freetube.cookies`), the `UserDefaults` keys (subscriptions / downloads / metadata), and internal `Notification.Name`s. Keep all of them on this same domain. Changing the identifier invalidates provisioning profiles and resets Keychain / `UserDefaults` state for any prior install.

---

## 2. Non-negotiable constraints

These come first. Violating them breaks the project.

1. **No Google Cloud YouTube Data API.** All YouTube interaction goes through `b5i/YouTubeKit` (cookie-based, no API key). Never suggest `GoogleAPIClientForREST`, `YTPlayerView`, IFrame embeds, or `https://www.googleapis.com/youtube/v3/...`.
2. **No `dimitris-c/AudioStreaming`.** It is for raw audio streams (Icecast/Shoutcast). YouTube serves HLS/DASH. Playback uses `AVPlayer` only.
3. **No App Store assumptions.** Do not add capabilities, entitlements, or workarounds aimed at App Store review (e.g. avoiding `WKWebView` cookie reads, hiding download functionality). Sideload-honest behavior is expected.
4. **No telemetry, analytics, or remote logging by default.** Logs go to `os.Logger` only. Never add SDKs that beacon out.
5. **Cookies are sensitive.** Always store in Keychain via `KeychainHelper`. Never write them to disk, `UserDefaults`, plist, or logs. Never print cookie values.
6. **Signed stream URLs are sensitive and time-limited.** Never persist them. In-memory cache only (`StreamURLCache`), 30-minute TTL max.
7. **MVVM with service layer is mandatory.** Views do not import `YouTubeKit` or `YoutubeDL`. ViewModels do not perform networking directly — they call services in `Core/Networking/`.
8. **SwiftUI only for UI.** No UIKit `UIViewController` subclasses except where bridging is unavoidable (`AVPlayerViewController`, `WKWebView`, `AVPictureInPictureController`). Wrap those in `UIViewControllerRepresentable` / `UIViewRepresentable`.
9. **Swift Concurrency is the default.** Use `async`/`await` and `AsyncSequence`. Use Combine only inside `PlayerStateManager` for `AVPlayer` time observation. Do not introduce RxSwift.
10. **No force unwraps in production code.** Use `guard let`, `if let`, or proper `throw`. Force unwraps allowed only in test fixtures.
11. **`@Observable` is the default for view models, not `ObservableObject`.** Injected through SwiftUI `@Environment(...)`.

---

## 3. Tech stack (locked)

| Layer | Choice |
|---|---|
| UI | SwiftUI (`@Observable`, iOS 17 APIs) |
| Async | Swift Concurrency, `AsyncSequence` |
| Networking (YouTube) | `b5i/YouTubeKit` |
| Stream extraction / download | `kewlbear/YoutubeDL-iOS` (yt-dlp via `PythonKit`) |
| In-process ffmpeg | `FFmpegSupport` (Swift wrapper around ffmpeg C library) |
| Playback | `AVFoundation` / `AVKit` (`AVQueuePlayer`, `AVPlayerViewController`, `AVPictureInPictureController`) |
| Mini / expanded player | `LNPopupUI` |
| Now-playing indicator | `SwimplyPlayIndicator` |
| Login web view | `WebKit` (`WKWebView`, `WKHTTPCookieStore` against ephemeral `.nonPersistent()` data store) |
| Images | `Kingfisher` |
| Secure storage | `Security` (raw Keychain via `KeychainHelper`) |
| Persistence | `SwiftData` (`@Model`); `UserDefaults` for simple flags via `UserPreferences` |
| Background work | `BackgroundTasks` framework + `URLSession` background config (`BackgroundDownloadCoordinator`) |
| Logging | `os.Logger` with subsystem `com.leshko.freetube` |
| JavaScript runtime | `JavaScriptCore` (`JSContext`) — solves YouTube's N/SIG cipher challenges in-process by faking the `deno` runtime to yt-dlp; see §15.11 |

Adding any other dependency requires an explicit ask in the PR description with justification.

---

## 4. Project structure

```
FreeTube/
├── App/
│   ├── AppEnvironment.swift
│   └── RootView.swift
├── FreeTubeApp.swift
├── Core/
│   ├── Networking/        # YouTubeKit wrappers, one Service per response family
│   ├── Auth/              # CookieStore, KeychainHelper, LoginCoordinator,
│   │                      # SessionManager, SubscriptionRegistry, AuthState
│   ├── Player/            # PlayerStateManager, PlaybackResolver, QueueManager,
│   │                      # AudioSessionConfigurator, NowPlayingCenter,
│   │                      # RemoteCommandCenter, StreamURLCache, HLSResourceLoaderDelegate
│   ├── Download/          # DownloadManager (yt-dlp orchestration),
│   │                      # BackgroundDownloadCoordinator, DownloadTask
│   ├── JavaScript/        # JSEvaluator (JSContext wrapper), PythonJSBridge
│   │                      # (yt-dlp ↔ JSCore glue), FreeTubeYtDlp (forked
│   │                      # entry point that splices the bridge), EJSResources
│   │                      # (loader for bundled yt-dlp-ejs JS)
│   ├── Persistence/       # @Model types, PersistenceController, PersistenceWriter
│   └── Models/            # Domain types: Video, Channel, Playlist, Comment,
│                          # VideoFormat, VideoQuality, ErrorState,
│                          # PlaybackSource, UserPreferences, YouTubeServiceError
├── Features/
│   ├── Home/              # HomeScreen + HomeViewModel
│   ├── Search/            # SearchScreen, SearchSuggestionList, SearchViewModel
│   ├── Subscriptions/     # SubscriptionsScreen + ViewModel
│   ├── Library/           # LibraryScreen, HistoryScreen, SubscribedChannelsScreen, ViewModels
│   ├── Channel/           # ChannelScreen, ChannelTabScreen, ViewModel
│   ├── Playlist/          # PlaylistScreen + ViewModel
│   ├── VideoDetail/       # VideoDetailScreen, CommentsSection, SaveToPlaylistSheet, ViewModels
│   ├── Account/           # AccountScreen + ViewModel
│   ├── Login/             # LoginScreen, LoginWebView
│   ├── Downloads/         # DownloadsScreen + ViewModel
│   └── Settings/          # SettingsScreen + ViewModel
├── UI/
│   ├── Player/            # FullScreenPlayer, PlayerSurface, DownloadProgressOverlay
│   ├── Components/        # VideoCard, VideoRow, ChannelRow, CommentRow,
│   │                      # PlaylistRow, AddToPlaylistSheet, ActivityShareSheet,
│   │                      # NowPlayingIndicator, SectionHeader, LoadingView
│   └── Modifiers/         # ErrorToastModifier
├── Resources/
│   ├── Localizable.xcstrings    # en / es / ru / fr / de, 236 keys
│   ├── core.min.js              # yt-dlp-ejs N/SIG solver (~7 KB, see §15.11)
│   └── lib.min.js               # meriyah + astring bundle (~152 KB, see §15.11)
└── Assets.xcassets
```

When asked to "add a feature", create or extend a folder under `Features/`. Keep shared UI atoms in `UI/Components/`.

---

## 5. File and naming conventions

- One type per file. File name matches the type name.
- Service classes end in `Service` (`SearchService`, `HistoryService`).
- View models end in `ViewModel`, declared `@Observable` (iOS 17+).
- SwiftUI views are nouns (`VideoCard`, `HomeScreen`). Use `Screen` suffix for top-level screens.
- Async functions return concrete types or throw — no `Result` returns from public service APIs.
- Use `// MARK: -` to separate logical sections in files over 100 lines.
- Annotate iOS-17-only types with `@available(iOS 17.0, *)` even though the deployment target is 17.0 — it documents the dependency and keeps the build clean if the target ever drops.

---

## 6. Mandatory mapping: YouTubeKit response → service method → ViewModel

Every YouTubeKit response type gets exactly one service method. Do not call `YouTubeKit` from anywhere except `Core/Networking/`. Source of truth:

| Response | Service method |
|---|---|
| `HomeScreenResponse` (+Continuation) | `HomeService.fetchHome()` / `fetchMore()` |
| `TrendingVideosResponse` | `HomeService.fetchTrending()` |
| `SearchResponse` (+Continuation, +Restricted) | `SearchService.search(query:restricted:)` / `fetchMore()` |
| `AutoCompletionResponse` | `SearchService.autocomplete(query:)` |
| `ChannelInfosResponse` (+Videos/Shorts/Directs/Playlists +Continuations) | `ChannelService.fetchChannel(id:)` / `fetchVideos()` / `fetchShorts()` / `fetchDirects()` / `fetchPlaylists()` |
| `PlaylistInfosResponse` (+Continuation) | `PlaylistService.fetchPlaylist(id:)` / `fetchMore()` |
| `VideoInfosResponse` | `VideoService.fetchInfo(id:)` (iOS client) — **also `VideoService.fetchInfoViaTVHTML5(id:)`** (TVHTML5_SIMPLY_EMBEDDED_PLAYER context for PoT-resistant URLs) |
| `VideoInfosWithDownloadFormatsResponse` | `VideoService.fetchInfoWithFormats(id:)` |
| `MoreVideoInfosResponse` | `VideoService.fetchMoreInfo(id:)` |
| `AccountInfosResponse` | `AccountService.fetchAccountInfo()` |
| `AccountLibraryResponse` | `AccountService.fetchLibrary()` |
| `AccountPlaylistsResponse` | `AccountService.fetchPlaylists()` |
| `AccountSubscriptionsFeedResponse` | `SubscriptionService.fetchFeed()` |
| `AccountSubscriptionsResponse` | `SubscriptionService.fetchSubscriptions()` |
| `HistoryResponse` / `RemoveVideoFromHistroryResponse` | `HistoryService.fetch()` / `remove(videoID:)` |
| `SubscribeChannelResponse` / `UnsubscribeChannelResponse` | `SubscriptionService.subscribe(channelID:)` / `unsubscribe(channelID:)` |
| `AllPossibleHostPlaylistsResponse` | `PlaylistService.fetchHostablePlaylists(videoID:)` |
| `AddVideoToPlaylistResponse` / `RemoveVideoByIdFromPlaylistResponse` / `RemoveVideoFromPlaylistResponse` | `PlaylistService.add/remove*` |
| `CreatePlaylistResponse` / `DeletePlaylistResponse` / `MoveVideoInPlaylistResponse` | `PlaylistService.create/delete/move*` |
| `LikeVideoResponse` / `DislikeVideoResponse` / `RemoveLikeFromVideoResponse` | `VideoActionsService.like/dislike/removeRating*` |
| `CreateCommentResponse` / `EditCommentResponse` / `DeleteCommentResponse` | `CommentService.create/edit/delete*` |
| `ReplyCommentResponse` / `EditReplyCommandResponse` | `CommentService.reply/editReply*` |
| `LikeCommentResponse` / `DislikeCommentResponse` / `RemoveLikeCommentResponse` / `RemoveDislikeCommentResponse` | `CommentService.like/dislike/removeRating*` |
| `CommentTranslationResponse` | `CommentService.translate(commentID:)` |

If a feature seems to need data without a clear mapping above, stop and ask before improvising.

---

## 7. Playback pipeline (critical)

This is what the codebase actually does today, not the original v1 design. The flow has three independent tiers — playback starts from whichever tier first succeeds.

### Tier 1 — yt-dlp download (`DownloadManager.runYoutubeDLDownload`)

1. User taps a video. `PlayerStateManager.resolveAndPlay` calls `DownloadManager.ensureDownloaded(video:quality:priority:)`.
2. **Cache check first.** `localFile(for:)` returns immediately if the mp4 already exists in `Documents/Downloads/<videoID>.mp4`.
3. **Network gate.** `waitForAllowedNetwork()` blocks the call until the user-allowed network is up (Wi-Fi if `wifiOnlyDownloads` is set).
4. **Submit to PythonRunner** with priority `.high` (`.userInitiated`) for play taps, `.low` (`.background`) for prefetch / Download All.
5. yt-dlp is invoked with a hard-coded set of player clients (`player_client=tv_simply,tv_embedded,web_creator,mweb,web_safari,ios,android_vr;formats=missing_pot`) to maximise chances of getting a non-cipher format.
6. **Critical: `--ffmpeg-location /dev/null/no-ffmpeg` is forced**, so yt-dlp's Python-side ffmpeg merger never runs. yt-dlp's `subprocess.Popen` against ffmpeg reliably hangs Python in `Popen.communicate` on iOS. We mux ourselves in Swift afterwards (`muxToDestination` → `FFmpegRunner.shared.run`). See §15 on the workaround.
7. **JS bridge installed before download**: `freetube_yt_dlp` (our forked entry point in `Core/JavaScript/FreeTubeYtDlp.swift`) splices `PythonJSBridge.install()` between YoutubeDL-iOS's `injectFakePopen` and `ydl.download`. This wires `JavaScriptCore` as the `deno` runtime for yt-dlp's EJS-based N/SIG challenge solver — formats that previously hit `n challenge solving failed` now resolve in-process. Full architecture in §15.11.
8. If yt-dlp produces output, optionally mux video+audio and persist as `DownloadedVideo` row.

### Tier 2 — YouTubeKit fallback (`DownloadManager.runYouTubeKitFallback`)

Reached when tier 1 returns no file (PoT-locked content, n-cipher failures, 403s on signed URLs).

1. `fetchFallbackFormats(videoID:)` walks two sub-tiers:
   - `VideoService.fetchInfoViaTVHTML5(id:)` — `TVHTML5_SIMPLY_EMBEDDED_PLAYER` client returns URLs not stamped with PoT. Wins for most non-locked content.
   - If TVHTML5 returns zero usable URLs (cipher-protected), `VideoService.fetchInfoWithFormats(id:)` triggers YouTubeKit's player.js scrape. This is increasingly fragile — YouTube has been breaking the `n` decoder regex and we frequently see `"Could not get n-parameter function."` here.
2. **Strategy 1 — progressive** (`pickBestProgressive`): pick itag 18 or similar with `containsBothTracks`. Download as single mp4 via `URLSession.bytes(for:)`. No mux needed.
3. **Strategy 2 — adaptive**: `pickBestVideoOnly` + `pickBestAudioOnly`, download both, mux with in-process `FFmpegRunner` using `ffmpeg -c copy -movflags +faststart`.
4. If neither strategy finds usable formats, throw `streamExtractionFailed` — tier 1 + 2 fail and we hand off to tier 3.

### Tier 3 — streaming-only fallback (`PlayerStateManager.resolveStreamingURL`)

Reached when `ensureDownloaded` throws. **Produces no local file** — AVPlayer streams a remote URL directly.

Walks four sub-tiers, returns first hit:
1. iOS-client HLS master playlist URL (from `VideoService.fetchInfo`)
2. iOS-client progressive MP4 URL (highest format with `containsBothTracks` within `preferredQuality.heightCap`)
3. TVHTML5-client HLS
4. TVHTML5-client progressive MP4

If all four miss, `loadState = .failed` and the user sees an error toast.

### Trade-offs

| | Tier 1 (yt-dlp) | Tier 2 (YouTubeKit) | Tier 3 (streaming) |
|---|---|---|---|
| Produces file | Yes | Yes | No |
| Persists to `DownloadedVideo` | Yes | Yes | No |
| Offline playback | Yes | Yes | No |
| Works for PoT-locked content | No | No | Often yes (HLS) |
| Latency (cold) | ~3–10s | ~2–5s | ~1–2s |

### Shape

```swift
enum PlaybackSource {
    case direct(URL)
    case localFile(URL)
}
```

`AVQueuePlayer` accepts both cases identically — the layer above doesn't branch on it.

---

## 8. Player UI rules

- **One `PlayerStateManager`** is the single source of truth for current playback. Injected via SwiftUI `@Environment(PlayerStateManager.self)`.
- **Mini player and full-screen player are both driven by `LNPopupUI`** — the popup bar above the tab bar expands into a full-screen popup. Same `AVQueuePlayer` instance for both views.
- **`AVPlayerViewController`** wrapped in `UIViewControllerRepresentable` (`PlayerSurface.swift`) is the video surface. System controls, AirPlay, PiP for free.
- **`AVQueuePlayer`**, not `AVPlayer`. Required for `advanceToNextItem()` and queue introspection. Important: `replaceCurrentItem(with:)` is a no-op on `AVQueuePlayer` when its internal queue is empty (our usual state). Use `removeAllItems()` + `insert(_:after:)` (see the `loadItem` helper).
- **Background audio:** `AudioSessionConfigurator` runs at app launch with `(.playback, .moviePlayback)`.
- **Now Playing:** `NowPlayingCenter` keeps `MPNowPlayingInfoCenter.default().nowPlayingInfo` in sync — title, channel as artist, thumbnail (downloaded via Kingfisher) as artwork, elapsed/duration.
- **Remote commands:** `RemoteCommandCenter` wires `MPRemoteCommandCenter` for play/pause/next/previous/skip ±15s/seek.
- **Endless queue:** when the user taps any video outside a curated batch action (Play all / Shuffle all of a playlist), `queueAcceptsRecommendations` is set and `fillQueueWithRecommendations` runs after playback starts. On end-of-queue with repeat off, `playNext()` re-fires recommendations using the last item as the seed.
- **Popup body backdrop must stay translucent.** The expanded `FullScreenPlayer` paints a `.thinMaterial` rectangle behind the entire popup body. Anything that introduces an opaque background and turns it black is a regression. Common offenders + neutralizers:
  - **`NavigationStack` inside the popup body:** the nav bar paints an opaque system background even with the title hidden. `.toolbarBackground(.hidden, for: .navigationBar)` is NOT sufficient — use `.toolbar(.hidden, for: .navigationBar)` to remove the bar entirely. Supply your own back/close button.
  - **`List` / `ScrollView` default content background:** apply `.scrollContentBackground(.hidden)` on every list/scroll view in the popup body.
  - **`UIHostingController`-backed views (`NavigationStack` destinations):** add a defense-in-depth `.background { Rectangle().fill(.thinMaterial).ignoresSafeArea() }` on each destination root.
  - **Where you put `.background` matters.** Modifiers on `NavigationStack` itself (outside the trailing closure) paint *behind* its UIKit hosting container — its own opaque system background covers them. Backdrop must be applied *inside* the root content and again inside every `.navigationDestination { ... }` view.
  - **Don't replace the thinMaterial with `Color.black`** — that's not the intended look; the popup is designed as one continuous translucent surface over the tab content underneath.

---

## 9. Authentication flow

1. `LoginScreen` presents a `WKWebView` against an **ephemeral `.nonPersistent()` `WKWebsiteDataStore`**. The ephemeral store is critical — a persistent store reuses any prior session and we'd capture stale cookies.
2. `LoginCoordinator` watches navigation; when the URL transitions to `youtube.com` after sign-in, it calls `WKWebsiteDataStore.default().httpCookieStore.getAllCookies` and filters for `.youtube.com` / `.google.com` domains.
3. **Cookie de-duplication:** when both `.youtube.com` and `.google.com` versions of the same cookie are present, **prefer `.youtube.com`** (`CookieStore.dedupe`). Length-based tie-breaking failed in practice — both scopes were 12 chars. YouTube-scoped cookies are the ones YouTube actually accepts.
4. Required cookies (all must be present): `SAPISID`, `__Secure-3PAPISID`, `LOGIN_INFO`, `SID`, `HSID`, `SSID`, `APISID`.
5. Cookies are serialized as a single Cookie-header string and stored in Keychain under `com.leshko.freetube.cookies` via `KeychainHelper`.
6. On every app launch, `SessionManager.bootstrap()` reads from Keychain and assigns to `YouTubeModel.shared.cookies` plus `YouTubeKitClient.shared.applyCookies(...)`.
7. **`SubscriptionRegistry`** persists the user's subscribed channel IDs in `UserDefaults` (`com.leshko.freetube.subscriptions`). Subscribe/unsubscribe optimistically flips this **and** calls the YouTube endpoint. Needed because YouTubeKit's `subscribeStatus` parser doesn't follow `pageHeaderRenderer` entity-key indirection — channel screens were always showing "Subscribe" even on subscribed channels until this cache was added.
8. **`AuthState`** (an `@Observable` singleton) drives root navigation: `.loggedIn` / `.loggedOut` / `.unknown`. On `cookieExpired` / 401-equivalent failures, `SessionManager.handleExpiredSession()` wipes Keychain + sets `AuthState.loggedOut` and the root re-routes to Login.

---

## 10. Downloads

### User-initiated (Download button)

- `DownloadManager.ensureDownloaded(video:quality:priority: .background)` from the explicit Download button in the player menu.
- Files go to `Documents/Downloads/<videoID>.mp4` and are tracked in SwiftData as `DownloadedVideo`.
- Visible in the Downloads screen, playable offline.

### Playback-side download (the implicit case)

- Same `ensureDownloaded` call, priority `.userInitiated`, fired by `PlayerStateManager.resolveAndPlay` whenever a user taps Play.
- This is why every successful playback also produces an offline file — the player's "fetch" *is* a download. Quirk of the architecture, intentional, makes the Downloads tab self-populate as the user watches.
- Next-up prefetch: `prefetchNextUpcoming()` fires `ensureDownloaded` for the next queue item at `.background` priority. Just one — we don't chain a long preload that would block user taps behind the `PythonRunner` queue.

### PythonRunner priority queue

- **`.high` / `.userInitiated`** — play taps. Jumps the line.
- **`.low` / `.background`** — Download All, queue prefetch.
- Within priority: FIFO. Cannot preempt the currently-running yt-dlp (Python has no safe interrupt point).
- This is the fix for "user taps a video while a 50-item playlist Download All is in flight" — without the priority lane the user waits behind the entire batch.

### Network gate

- `wifiOnlyDownloads` setting checked via `NWPathMonitor` before every `ensureDownloaded` returns from queued state.

### Background URL session

- `BackgroundDownloadCoordinator` configures `URLSession(.background(withIdentifier:))` so user-initiated direct-URL downloads (tier 2 strategy 1/2) survive backgrounding.
- `BGProcessingTaskRequest` is registered for resuming downloads at next launch.

### Cache limit

- `UserPreferences.downloadCacheLimitBytes` — when exceeded, oldest `DownloadedVideo` rows by `downloadedAt` get evicted along with their files.

---

## 11. SwiftData models

```swift
@Model class WatchHistoryEntry { videoID, title, channelName, thumbnailURL, watchedAt, lastPosition }
@Model class DownloadedVideo   { videoID, title, channelName, thumbnailData, fileURL, formatID, fileSize, downloadedAt }
@Model class FavoriteVideo     { videoID, title, channelName, thumbnailURL, savedAt }
@Model class FavoritePlaylist  { playlistID, title, thumbnailURL, savedAt }
@Model class SearchHistoryEntry { query, searchedAt }
```

`PlaybackQueueSnapshot` (originally planned) was not implemented — the queue is reconstructed from recommendations on each play.

**Writes go through `PersistenceWriter` (an `@ModelActor`).** Views and view models never block on SwiftData saves; they call `PersistenceWriter.shared.upsertFoo(...)` and fire-and-forget. The actor owns a background `ModelContext`, batches writes, and keeps the SQLite queue off the main thread. Direct `modelContext.insert(...)` on the main actor is fine for trivial inserts (e.g. one-shot user actions) but avoid loops or burst inserts there.

Preferences live in `UserDefaults` via a `@AppStorage`-backed `UserPreferences` type. Don't over-engineer with SwiftData for primitive flags.

---

## 12. Error handling rules

- Public service methods are `async throws`. Define `YouTubeServiceError`: `notAuthenticated`, `rateLimited`, `videoUnavailable`, `streamExtractionFailed`, `cookieExpired`, `network(Error)`, `decoding(Error)`, `unknown(Error)`.
- View models catch errors and translate to `@Published var errorState: ErrorState?` (or `var` on `@Observable`). Never let raw errors bubble to views.
- Show errors via the single `ErrorToastModifier`. Don't pepper alerts across screens.
- On `cookieExpired` / 401-equivalent: `SessionManager.handleExpiredSession()` wipes Keychain cookies + flips `AuthState`. Root view reacts and routes to Login.
- Stream extraction failure must always fall through to the next tier (see §7) before surfacing to the user.

---

## 13. Logging

Use `os.Logger`:

```swift
private let log = Logger(subsystem: "com.leshko.freetube", category: "PlaybackResolver")
log.info("Resolving \(videoID, privacy: .public) at quality \(quality.rawValue, privacy: .public)")
log.error("Stream extraction failed: \(error.localizedDescription, privacy: .public)")
```

- Cookie values, signed URLs, user emails: `privacy: .private` or omit entirely.
- Public IDs, response status, timing: `privacy: .public` is fine.
- **Do not log from SwiftUI body re-evaluation paths.** `DownloadManager.localFile(for:)` is called from `Menu` bodies that re-evaluate every player time tick; even a `log.debug` line floods the device log with hundreds of "miss" lines per second.

---

## 14. Localization

- `Localizable.xcstrings` (Apple String Catalog format), 236 keys, fully translated for **en / es / ru / fr / de**. `sourceLanguage: "en"`.
- Add new strings by using `String(localized:)` / `LocalizedStringKey` in code; Xcode's build-time extractor populates the catalog. After a build, open `Localizable.xcstrings` and translate any new `state: "new"` entries.
- **Non-translatable strings must never enter the catalog. Emit them with `Text(verbatim:)`, not a localizable `Text`.** A string whose entire content is format specifiers (`%@`, `%lld`, `%lld%%`), punctuation/symbols (`•`, `·`, `≈`, `,`), or brand names (`yt-dlp`, `freetube.io`) — with no actual words — has nothing to translate. The root cause is code: `Text("\(x) · \(n)%")` makes SwiftUI treat the literal as a `LocalizedStringKey`, so the extractor auto-adds junk keys like `%@ · %lld%%` on every build. Marking them `shouldTranslate: false` only suppresses *translation* — the key still gets re-added and clutters the catalog. **Fix at the source:** wrap these in `Text(verbatim: "...")` (for `.accessibilityLabel`, pass `Text(verbatim:)` explicitly). Then delete the orphaned keys from `Localizable.xcstrings`; once the code uses `verbatim`, the extractor won't recreate them. Keys removed this way (all now `verbatim` in code): `%@ · %lld%%` (FetchProbeView), `%lld%%` (FetchProbeView/DownloadsScreen), `≈ %@` (FetchProbeView), `• %@` (DownloadsScreen), `%lld %@ • %@` (DownloadsScreen), `%lld` (DownloadsScreen), `%@, %@` (VideoCard accessibility), `yt-dlp` (SettingsScreen header). When you write a new pure-format/symbol/brand string, reach for `Text(verbatim:)` up front so it never reaches the catalog.
- Pluralization uses Apple's CLDR plural rules through the catalog's variation editor.
- If you add a string that contains a literal source-file reference (e.g. an internal `ContentView` placeholder), use a clean user-facing value in the translation columns even if the key looks debug-ish.

---

## 15. Critical workarounds (read before refactoring `Core/`)

### 15.1 PythonRunner — Python-thread-pinning + serial drain

`PythonKit` + CPython assume one thread touches the interpreter — the thread that ran `PythonSupport.initialize()`. A plain `actor` rotates between cooperative-pool workers and Python crashes in `_PyInterpreterState_GET`. Fix: `PythonSerialExecutor` (a custom `SerialExecutor` backed by a serial `DispatchQueue`) — GCD reuses the same worker thread back-to-back for serial-queue jobs.

A plain serial actor isn't enough either: actor methods only guarantee one *body* at a time, but `await` lets another caller in. Fix: strict Task chaining through the `pump()` drain — new tickets enqueue, only one `pump` task drains at a time.

### 15.2 FFmpegRunner — ffmpeg C library serialization

`FFmpegSupport.ffmpeg(_:)` is not thread-safe. The `+faststart` post-pass walks global I/O buffers and crashes with `EXC_BAD_ACCESS` on concurrent calls. `setjmp`/`longjmp` in the Hook.m shim has undefined behavior across concurrent calls. Fix: `FFmpegRunner.shared.run(args)` serializes all ffmpeg calls through a chained `Task` FIFO. **Every** ffmpeg invocation goes through this actor.

### 15.3 yt-dlp's ffmpeg merger hangs on iOS

`subprocess.Popen.communicate` against ffmpeg never returns from inside the embedded Python on iOS — `longjmp` tears through the Python interpreter's stack. Fix: pass `--ffmpeg-location /dev/null/no-ffmpeg` to yt-dlp so it fails-fast at probe time instead of hanging. We mux ourselves with direct `FFmpegRunner` calls afterwards. Same reason `--postprocessor` flags must not request anything ffmpeg-backed inside yt-dlp.

### 15.4 yt-dlp PoT / n-cipher reality

YouTube has been enforcing Proof-of-Origin Tokens and rotating the `n`-parameter cipher in player.js on a 2–8-week cadence. Symptoms in logs:
- `n challenge solving failed: Some formats may be missing.`
- `Could not get n-parameter function.`
- `HTTP Error 403: Forbidden` on download.

**N-cipher: solved in-process via JavaScriptCore.** See §15.11 — `PythonJSBridge` fakes a `deno` runtime to yt-dlp using `JSContext`, and ships `yt-dlp-ejs` solver scripts in `Resources/`. The "n challenge solving failed" warnings should no longer fire for normal videos. The solver bundle (`yt-dlp-ejs 0.8.0`) needs re-pulling when YouTube rotates the cipher faster than yt-dlp's vendored regexes can match.

**PoT: still unsolved.** Proof-of-Origin Tokens require attesting to YouTube via a Play Integrity / DroidGuard / WidevineCDM challenge — not something a JS runtime alone can answer. Tier 3 streaming (HLS or direct progressive URL from `VideoInfosResponse`) remains the user-facing safety net for PoT-locked content (typically kids/family videos, some music labels).

### 15.5 AVQueuePlayer + `replaceCurrentItem` is a no-op when queue is empty

Don't use it. Use `removeAllItems()` + `insert(_:after:)` (see `loadItem`).

### 15.6 SourceKit "No such module 'FFmpegSupport' / 'Kingfisher'" warnings

Stale Xcode index. Real compiler links these fine; `xcodebuild` shows `BUILD SUCCEEDED`. Ignore. Clean Build Folder clears it.

### 15.7 Login `WKWebsiteDataStore` must be ephemeral

Using `.default()` reuses prior session cookies and captures stale ones. Use `.nonPersistent()`.

### 15.8 Cookie domain de-dup picks `.youtube.com`

When `.youtube.com` and `.google.com` versions of the same cookie are both present (post-login), YouTube only accepts the `.youtube.com` value. `CookieStore.dedupe` enforces this — don't simplify it to a length-based tiebreak.

### 15.9 `SubscriptionRegistry` exists because YouTubeKit can't parse subscribe state reliably

YouTubeKit's `subscribeStatus` doesn't follow `pageHeaderRenderer` entity-key indirection. We persist subscribe state in `UserDefaults` and reconcile on subscribe/unsubscribe.

### 15.10 Don't run heavy work from SwiftUI bodies

`FileManager.fileExists` inside `Menu` bodies (e.g. `localFile(for:)`) fires hundreds of times per second under the player view's KVO storm. The function itself is cheap; logging from it is not. Generally: anything called from a re-evaluating body should be allocation-free and log-free.

### 15.11 JavaScriptCore as yt-dlp's `deno` runtime

YouTube serves stream URLs whose `n` parameter is obfuscated by a transform function defined in player.js. yt-dlp's solver (the `EJS` framework, package `yt-dlp-ejs`) extracts that JS, builds a script, and pipes it to an external JS runtime — `deno`, `node`, `bun`, or `qjs`. No such binary exists on iOS. Without intercepting this, the user sees `n challenge solving failed` followed by 403s at the CDN.

We fake `deno` to yt-dlp using `JavaScriptCore`. The bridge is **five pieces**, all installed by `PythonJSBridge.install()` at exactly one splice point inside our forked `freetube_yt_dlp(...)` entry — between `YtDlp()`'s init (which runs YoutubeDL-iOS's `injectFakePopen`) and `ydl.download` (which triggers JSC provider registration):

1. **`builtins.eval_js(code: str) -> str`** — Python-callable hook that runs JS via `JSEvaluator.evaluate(_:)`. The caller's source is wrapped in an IIFE that fakes a `console` global (capturing `console.log` args to an array) and returns the joined captures, so yt-dlp's `console.log(JSON.stringify(jsc({...})))` payload works unchanged.

2. **`yt_dlp_ejs` sys.modules shim** — yt-dlp gates the whole EJS path on `from yt_dlp.dependencies import yt_dlp_ejs as _has_ejs` being truthy. We synthesize three modules (`yt_dlp_ejs`, `.yt`, `.yt.solver`) in `sys.modules` with the package's exact API — `version`, `core()`, `lib()` — reading from our bundled `core.min.js` (the N/SIG solver, ~7 KB) and `lib.min.js` (meriyah + astring bundle, ~152 KB) via `EJSResources`. We also rebind `yt_dlp.dependencies.yt_dlp_ejs` after the fact in case it was imported before us.

3. **`DenoJsRuntime._info` monkey-patch** — yt-dlp normally spawns `deno --version` and parses stdout to populate `_js_runtimes['deno'].info`. We replace `_info` to return `JsRuntimeInfo(name='deno', version='2.0.0', version_tuple=(2,0,0), supported=True)` without any subprocess call.

4. **Pop class monkey-patch (not `subprocess.Popen`)** — YoutubeDL-iOS replaces `subprocess.Popen` with its ffmpeg-only `Pop` class at init time. Then `yt_dlp.utils.Popen` declares `class Popen(subprocess.Popen):` — which captures `Pop` as its base **at class definition time, frozen**. Rebinding `subprocess.Popen` later would NOT change that MRO. The fix is to monkey-patch `Pop.__init__` and `Pop.communicate` directly; `yt_dlp.utils.Popen` looks up methods dynamically via `super()`, so calls now hit our extended handlers. For argv[0] equal to our fake path (`/dev/null/freetube-deno`), we capture stdin, pass to `builtins.eval_js`, return the JS result on stdout. Everything else falls through to the original `Pop` (preserving ffmpeg passthrough).

5. **`js_runtimes` ydl_opt** — even with the runtime detection stubbed, yt-dlp's `_js_runtimes` dict only gets populated from the `js_runtimes` ydl_opt. `FreeTubeYtDlp.swift` adds `ydl_opts["js_runtimes"] = {"deno": {"path": fakeDenoPath}}` so the dict has an entry to apply (3) to.

**Maintenance:** when YoutubeDL-iOS bumps its yt-dlp version, re-pull `yt-dlp-ejs` from PyPI to match (check upstream `vendor.HASHES`), update `EJSResources.version`, drop new `core.min.js`/`lib.min.js` into `Resources/`. yt-dlp validates major/minor version of the script against its embedded `_SCRIPT_VERSION`; mismatch silently disables the EJS path.

### 15.12 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` runs anything unannotated on main

This project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` in both Debug and Release. Under that setting:

- A top-level `public func foo() async throws { ... }` is implicitly `@MainActor`.
- A top-level enum / struct / class with no isolation marker is implicitly `@MainActor`. Its static members inherit.
- `Task { ... }` (the `init` form) inherits caller isolation, which under default-MainActor is main — **even when created from inside a non-main `actor` body** like `PythonRunner`.

Symptom: a yt-dlp download stack shows up on Thread 1 (main) — `_ssl__SSLSocket_do_handshake` → many `_PyEval_EvalFrameDefault` → `ThrowingPythonObject.dynamicallyCall` → `freetube_yt_dlp` → `closure #1 in PythonRunner.pump()`. Main runloop is blocked for the entire download.

**Fix for new code that touches Python / SSL / JSCore:**
- Use `Task.detached(priority: .utility) { ... }` to dispatch, never plain `Task { }`. `.detached` is the explicit "do NOT inherit isolation" form.
- Mark top-level Python-touching async functions `public nonisolated func ...`.
- Mark enclosing enums / structs `nonisolated` so their static members aren't pulled to main either. `PythonJSBridge`, `JSEvaluator`, `EJSResources`, and `freetube_yt_dlp` all carry `nonisolated`.

This bit twice during the JS-bridge work — the obvious "wrap in `Task`" fix didn't help because the wrapping Task itself was `@MainActor`. Don't revert `Task.detached` back to `Task` without also auditing the surrounding isolation annotations.

---

## 16. Build priority (work top-down)

Current state of the implementation. Items marked ✓ are shipped.

- **P0 — MVP playback** ✓
  - YouTubeKit + YoutubeDL-iOS SPM setup
  - `HomeService`, `SearchService` (+ autocomplete), `VideoService`
  - Home screen, Search screen, Video detail screen
  - Three-tier playback resolver (yt-dlp / YouTubeKit / streaming HLS)
  - `PlayerStateManager`, mini player + full-screen popup (LNPopupUI)
  - Background audio + Now Playing + Remote Command Center
- **P1 — Account** ✓
  - Login (`WKWebView` ephemeral data store + Keychain)
  - `AccountService`, `SubscriptionService`, `HistoryService`
  - Subscriptions tab, Library tab (History / Playlists / Your videos / Subscriptions / Liked / Watch later)
  - Like / Dislike, Save-to-playlist sheet
  - Channel screen, Playlist screen
- **P2 — Engagement** ✓ (mostly)
  - `CommentService` (read + write + reply + rate)
  - `DownloadManager` with priority queue + cache limit
  - Queue management UI
  - PiP, AirPlay
  - CarPlay audio mode — not yet
- **P3 — Polish** (in flight)
  - Comment translation ✓
  - Localization en / es / ru / fr / de ✓
  - JavaScriptCore-based n-decoder ✓ (see §15.11 — `PythonJSBridge` fakes deno via JSCore; ships `yt-dlp-ejs` JS in `Resources/`)
  - Custom video controls beyond AVPlayerViewController — not in scope for v1

---

## 17. When to ask before doing

Stop and ask when:

- A request implies adding a dependency not on the locked stack.
- A request implies App Store distribution accommodations.
- A YouTubeKit response type doesn't map cleanly to the service layer in §6.
- A request asks Claude to handle cookies, tokens, or stream URLs in any persistence layer other than Keychain (cookies) or in-memory (URLs).
- A request would require building custom video player controls from scratch before the AVPlayerViewController-based v1 is shipped.
- A request asks to integrate with Chromecast, Google Cast, or any non-AirPlay casting (not in scope).
- A request asks to drop the iOS deployment target below 17.0 — that's not a config change, it's a SwiftData → CoreData + `@Observable` → `ObservableObject` refactor across ~30 files.

Do not ask before:

- Adding a new feature folder under `Features/`.
- Adding shared components under `UI/Components/`.
- Refactoring within a single file.
- Writing or extending tests.
- Adding `os.Logger` lines (outside of hot view-body paths — see §15.10).

---

## 18. Code style

- Four-space indentation, matching SwiftFormat default.
- Trailing closures only when there's exactly one closure parameter.
- `self.` only when required by closure capture rules.
- Prefer `let` over `var`. Mark types `final` unless designed for subclassing.
- Group `import` statements: stdlib first, Apple frameworks next, third-party last, each block separated by a blank line.
- Doc comments (`///`) on all public service methods, view models, and non-trivial types — especially anything that encodes a workaround like §15. Future-you will thank you.

---

## 19. Known limitations to communicate

If asked to "make it more robust" or "production-ready", point to these realities first instead of inventing solutions:

- YouTube can change its internal API at any time and silently break extraction. There is no SLA.
- Cookies expire (typically 1-2 weeks of inactivity); the user will need to re-login.
- N-cipher-locked content downloads in-process via the JSCore bridge (§15.11). PoT-locked content (Play Integrity attestation, not solvable by a JS runtime) still **cannot be downloaded** and falls through to tier 3 streaming. Kids/family content is the usual PoT offender.
- yt-dlp's HLS downloader needs ffmpeg, which is blocked by §15.3 — yt-dlp picking an HLS-only format fails on iOS. Tier 2/3 take over.
- IP-level rate limiting from YouTube can hit users on shared networks (CGNAT, VPN). No client-side fix.
- This codebase intentionally does not implement App Store evasion techniques. Sideload distribution is the assumption.
- Variant selection in tier 3 HLS streaming honors `preferredQuality.heightCap` only when AVPlayer's adaptive bitrate logic agrees; we don't pre-pick a variant.

---

## 20. When in doubt

Re-read sections 2, 6, 7, and 15. Most architectural questions are answered there. If still unclear, ask in the PR or commit message rather than guessing — the cost of asking is one round-trip; the cost of guessing wrong is a refactor.
