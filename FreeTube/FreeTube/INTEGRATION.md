# Integration guide

This scaffold implements CLAUDE.md sections 1–18. Until two things happen in Xcode, the project will not compile:

## 1. Add the new folders to the Xcode target

Open `FreeTube.xcodeproj` and drag each of these folders into the project navigator under the existing `FreeTube` group, with **"Create groups"** selected and the **`FreeTube`** target ticked:

- `App/`
- `Core/`
- `Features/`
- `UI/`

The original `ContentView.swift` is no longer used at runtime. Right-click → **Delete → Remove Reference** to take it out of the build.

## 2. Add the SPM packages from CLAUDE.md §3

File → Add Package Dependencies… and add each of these (latest stable):

| Package | URL | Used by |
|---|---|---|
| YouTubeKit | `https://github.com/b5i/YouTubeKit` | `Core/Networking/YouTubeKitClient.swift` |
| YoutubeDL-iOS | `https://github.com/kewlbear/YoutubeDL-iOS` | `Core/Download/DownloadManager.swift` |
| Kingfisher | `https://github.com/onevcat/Kingfisher` | `UI/Components/VideoCard.swift`, `VideoRow.swift`, etc. (currently using `AsyncImage`) |
| KeychainAccess | `https://github.com/kishikawakatsumi/KeychainAccess` | `Core/Auth/KeychainHelper.swift` (currently using `Security` framework directly) |

Then search the project for `// TODO(YouTubeKit):` and `// TODO(YoutubeDL-iOS):` and fill in the bodies.

## 3. Project capabilities

- **Background Modes** (target → Signing & Capabilities → +):
  - "Audio, AirPlay, and Picture in Picture" — required for background audio (§8).
  - "Background fetch" — required for `BGProcessingTaskRequest` (§10).
- Add `com.leshko.freetube.resume-downloads` to `Info.plist` under `BGTaskSchedulerPermittedIdentifiers`.
- Deployment target: iOS 17.0 (SwiftData + `@Observable` are required).

## 4. What's stubbed vs. what's wired

- ✅ MVVM service-layer architecture, all 10 services with full method signatures from §6.
- ✅ Playback pipeline (`PlaybackResolver`) implementing §7 step-for-step. Service calls are stubbed.
- ✅ Mini-player + full-screen-player with shared `AVPlayer` (§8).
- ✅ `AVAudioSession` configuration (§8).
- ✅ `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` wired to the player.
- ✅ `WKWebView` login flow capturing cookies → Keychain (§9). Bootstraps on launch.
- ✅ SwiftData models per §11 plus `PersistenceController`.
- ✅ `URLSession.background(withIdentifier:)` + `BGProcessingTaskRequest` skeleton.
- ✅ `os.Logger` everywhere with the subsystem from §13.
- ✅ Error toast modifier reading `errorState` per §12.
- ⚠️ All service bodies are stubs — they call `YouTubeKitClient.send(_:)` which currently throws. Replace those calls with real `YouTubeKit` `sendThrowingRequest` invocations.
- ⚠️ YoutubeDL-iOS fallback inside `DownloadManager.downloadTemporary(...)` is a stub. Wire it to the real `YoutubeDL().download(...)` once the SPM package is in.
- ⚠️ Image loading uses `AsyncImage`. Swap for `KFImage` for caching once Kingfisher is in.
- ⚠️ Tests (§14) are not included in this scaffold. Add `FreeTubeTests/` mirroring the source structure when starting P0 verification.

## 5. SourceKit diagnostics during scaffolding

Most "cannot find type X in scope" errors visible right now are because the new files are not yet members of the `FreeTube` build target. They resolve after step 1.

## 6. Next steps (CLAUDE.md §15)

After integration:

1. Wire `YouTubeKitClient.send` to YouTubeKit and verify Home + Search load.
2. Replace placeholder formats in `PlaybackResolver` with `DownloadFormat` mapping.
3. Verify mini-player and full-screen-player share the same `AVPlayer` instance.
4. Walk through the playback pipeline tests listed in §14.
