import Foundation
import OSLog
import PythonKit
import YoutubeDL

/// Forked variant of YoutubeDL-iOS's `yt_dlp(argv:progress:log:makeTranscodeProgressBlock:)` whose
/// only structural difference is the call to `PythonJSBridge.install()` between `YtDlp` init and
/// `ydl.download`.
///
/// **Why we need this fork.** The package's `yt_dlp(...)` does, in order:
///   1. `let context = YoutubeDL()`
///   2. `let yt_dlp = try await YtDlp(context: context)` — this triggers `loadPythonModule()`
///      which calls `injectFakePopen(handler:)`, replacing `subprocess.Popen` with the package's
///      ffmpeg-only `Pop` class.
///   3. `parseOptions`, configure logger / progress, build post-processor.
///   4. `try ydl.download.throwing.dynamicallyCall(withArguments: all_urls)` — actually downloads.
///
/// To make yt-dlp's n-cipher solver succeed we need to extend `subprocess.Popen` so calls to
/// `deno`/`node` route through our `JavaScriptCore`-backed `JSEvaluator`. That extension has
/// to happen **between steps 2 and 4** — earlier and the package's `injectFakePopen` clobbers
/// us, later and yt-dlp has already given up. The package's `yt_dlp(...)` is a single async
/// block that doesn't expose a splice point, so we replicate it.
///
/// **What we drop vs the package version:**
///   - The `MyPP` post-processor that pokes `merger+ffmpeg` postprocessor_args with `-b:v`. That
///     setting is only consumed by yt-dlp's ffmpeg merger path, which we disable via
///     `--ffmpeg-location /dev/null/no-ffmpeg` (CLAUDE.md §15.3); our Swift-side `FFmpegRunner`
///     mux doesn't read it. Skipping the PP keeps this fork ~25 lines instead of 45.
///   - `context.willTranscode` — set on the `YoutubeDL` Swift class (typealiased to `Context`,
///     which is internal to the package). We can't reach it from outside anyway, and it only
///     drives transcode progress for yt-dlp's in-process ffmpeg pipeline (which is also
///     disabled). Not needed.
///
/// **Init quirk:** the package's `YtDlp.init(context:)` is internal — only the no-arg public
/// `init() async throws` (a convenience init that creates its own `Context()`) is reachable
/// from outside. We use that; the Context object is opaque to us but the bridge install only
/// needs Python state to exist, which `YtDlp()` provides via its `loadPythonModule()` call.
///
/// **What we preserve verbatim:** logger wiring, progress-hook wiring, parseOptions, the
/// `ydl.download.throwing.dynamicallyCall(withArguments: all_urls)` invocation pattern.
@available(iOS 17.0, *)
public nonisolated func freetube_yt_dlp(
    argv: [String],
    progress: @escaping @Sendable ([String: PythonObject]) -> Void,
    log: @escaping @Sendable (String, String) -> Void
) async throws {
    let bridgeLog = AppLog(subsystem: "com.leshko.freetube", category: "FreeTubeYtDlp")

    // Step 1+2 (collapsed): `YtDlp()`'s convenience init creates its own Context() internally
    // and calls `loadPythonModule()`, which initializes Python, downloads yt-dlp on first run,
    // and (critically for us) runs `injectFakePopen` — replacing `subprocess.Popen` with the
    // package's ffmpeg-only `Pop` class. After this returns we own the splice point.
    let ytdlp = try await YtDlp()

    // Splice point: now that `injectFakePopen` has run, layer our extension on top. Our
    // `_FreeTubePop` wraps the package's `Pop` (delegating ffmpeg/ffprobe) and additionally
    // routes `deno`/`node` calls through `JSEvaluator`. Idempotent across multiple
    // invocations of `freetube_yt_dlp` in the same process — the Python `_PrevPopen` capture
    // and class redefinition is harmless on repeat.
    bridgeLog.info("YtDlp ready, installing JS bridge before download")
    PythonJSBridge.install()

    // Step 3: configure options exactly as the package's `yt_dlp(...)` does, plus our
    // synthetic `js_runtimes` entry that registers our fake deno path with yt-dlp's
    // `_js_runtimes` dict. Without this, the dict stays empty and `DenoJCP.runtime_info`
    // returns `None` — bypassing the EJS path entirely no matter what else we patch.
    let (ydl_opts, all_urls) = try ytdlp.parseOptions(args: argv)
    ydl_opts["logger"] = makeLogger(name: "MyLogger", log)
    ydl_opts["progress_hooks"] = [makeProgressHook(progress)]
    ydl_opts["js_runtimes"] = PythonObject(["deno": ["path": PythonJSBridge.fakeDenoPath]])

    // Step 4: build the YoutubeDL downloader. `YtDlp.makeYoutubeDL(ydlOpts:)` is `internal` to
    // the package so we can't call it directly; we replicate it by importing the Python yt_dlp
    // module ourselves and instantiating `yt_dlp.YoutubeDL(opts)`. Same result, same object.
    let yt_dlp_module = try Python.attemptImport("yt_dlp")
    let ydl = yt_dlp_module.YoutubeDL(ydl_opts)

    // Step 5: actually run. yt-dlp's extractor chain will now find `deno` via our shim and
    // succeed at n-cipher solving — assuming the JS function yt-dlp extracts from player.js is
    // pure ES (no Web APIs, no `fetch`, etc.), which it is.
    try ydl.download.throwing.dynamicallyCall(withArguments: all_urls)
}

/// Probe variant of `freetube_yt_dlp` — runs the same five-step setup (Python init via
/// `YtDlp()`, JS bridge install, fake-deno wiring) but invokes `ydl.extract_info(url,
/// download=False)` instead of `ydl.download(...)`. Used by the "From URL" tab to render a
/// format picker without actually downloading anything.
///
/// **What's different vs the download path:**
///   - No progress hooks, no `parseOptions` — we hand-build the opts dict because we have no
///     argv to parse. The opts mirror what `freetube_yt_dlp` sets via parseOptions for the
///     same set of YouTube extractor args (player_client fallback chain, missing_pot,
///     no-check-certificates) so the probe sees the same formats the downloader would.
///   - The result is a Python dict. The caller is responsible for extracting Swift-native
///     values on the Python thread before returning to the actor system — see
///     `YtDlpInfoService` for the canonical conversion pattern.
///
/// **Why not just spawn yt-dlp with `--dump-single-json` argv:** that path would write JSON
/// to stdout and we'd have to thread it back through `freetube_yt_dlp`'s `log` callback,
/// then re-parse with `JSONSerialization`. Calling `extract_info` directly gives us a
/// PythonObject in-process and saves the round-trip.
@available(iOS 17.0, *)
public nonisolated func freetube_yt_dlp_extract_info(url: String) async throws -> PythonObject {
    let bridgeLog = AppLog(subsystem: "com.leshko.freetube", category: "FreeTubeYtDlp")
    let ytdlpLog = AppLog(subsystem: "com.leshko.freetube", category: "ytdlp")

    bridgeLog.info("extract_info: about to await YtDlp() init")
    let ytdlp = try await YtDlp()
    bridgeLog.info("extract_info: YtDlp ready, installing JS bridge before extract_info")
    PythonJSBridge.install()
    bridgeLog.info("extract_info: JS bridge install complete; configuring ydl_opts")

    // -------- Stderr redirection (NO Swift logger callback) --------
    //
    // Build 13 (with `makeLogger(_:)` Swift closure wired into ydl_opts.logger) hung at
    // `YoutubeDL(opts)` init the moment yt-dlp emitted its first verbose line. The cause:
    // PythonKit's `PythonInstanceMethod` (the glue `makeLogger` is built on) lives in the
    // PythonKit SPM package and compiles with PythonKit's own optimization flags —
    // **our app-target `SWIFT_OPTIMIZATION_LEVEL = -Onone` doesn't apply to SPM deps**.
    // Under that combination the Python→Swift closure trampoline stalls.
    //
    // Workaround: don't cross the Python↔Swift boundary at all for log capture. Redirect
    // Python's `sys.stderr` to a file inside our Logs directory, then tail that file from
    // a Swift Task and forward new lines into `os.Logger`. Pure CPython on the Python
    // side; pure Foundation FileHandle on the Swift side; no closure callbacks.
    let logsDir = LogFileWriter.logsDirectory()
    try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
    let stderrPath = logsDir.appendingPathComponent("ytdlp-stderr.log").path
    try? FileManager.default.removeItem(atPath: stderrPath)
    FileManager.default.createFile(atPath: stderrPath, contents: nil)

    let sys = try Python.attemptImport("sys")
    let builtinsModule = try Python.attemptImport("builtins")
    // `buffering=1` = line-buffered. Each `\n` from Python flushes to the file
    // immediately, so the tail task sees lines as soon as yt-dlp emits them.
    sys.stderr = builtinsModule.open(stderrPath, "w", 1)
    sys.stdout = sys.stderr
    bridgeLog.info("extract_info: Python stdout/stderr redirected to \(stderrPath, privacy: .public)")

    // Tail task — reads the stderr file every second, emits each new line into the
    // `ytdlp` os.Logger category. `LogFileWriter` picks them up because they share the
    // same `subsystem == com.leshko.freetube` predicate. Detached + `.utility` so the
    // poll never competes with the Python interpreter for the calling cooperative-pool
    // worker thread.
    let tailTask = Task.detached(priority: .utility) {
        // Open the FileHandle inside the task so its `FileHandle` reference doesn't
        // need to cross the Sendable boundary — `FileHandle` isn't `Sendable`.
        guard let handle = try? FileHandle(forReadingAtPath: stderrPath) else { return }
        defer { try? handle.close() }
        var carry = ""
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            let data = handle.availableData
            if data.isEmpty { continue }
            guard let chunk = String(data: data, encoding: .utf8) else { continue }
            let combined = carry + chunk
            // Hold back any trailing partial line so we don't split a log line at a
            // poll boundary; emit it on the next pass when the newline arrives.
            let lastNewline = combined.lastIndex(of: "\n")
            let emit: Substring
            if let lastNewline {
                emit = combined[..<lastNewline]
                carry = String(combined[combined.index(after: lastNewline)...])
            } else {
                emit = combined[...]
                carry = ""
                continue
            }
            for line in emit.split(separator: "\n") {
                ytdlpLog.info("\(String(line), privacy: .public)")
            }
        }
    }

    var opts = PythonObject([:] as [String: PythonObject])
    // Verbose so we see every extractor step in the redirected stderr. Removing
    // `quiet`/`no_warnings` overrides the defaults.
    opts["verbose"] = true
    opts["quiet"] = false
    opts["no_warnings"] = false
    opts["noplaylist"] = true
    opts["nocheckcertificate"] = true
    // Socket / HTTP timeout so a hung network leg throws a Python exception after ~30s
    // instead of spinning forever. yt-dlp's default is no timeout. The user can wait
    // 30s for an error; they cannot wait 3 minutes for the spinner.
    opts["socket_timeout"] = 30.0
    opts["extractor_args"] = PythonObject([
        "youtube": ["player_client=tv_simply,tv_embedded,web_creator,mweb,web_safari,ios,android_vr", "formats=missing_pot"]
    ] as [String: [String]])
    opts["js_runtimes"] = PythonObject(["deno": ["path": PythonJSBridge.fakeDenoPath]])
    // CLAUDE.md §15.3: yt-dlp's `YoutubeDL.__init__` runs an ffmpeg version probe
    // (`Popen(['ffmpeg', '-bsfs']).communicate()`). On iOS the YoutubeDL-iOS `Pop` class
    // accepts this argv but `communicate()` deadlocks the embedded Python forever.
    // The download path passes `--ffmpeg-location /dev/null/no-ffmpeg` via argv to make
    // yt-dlp skip the probe. We hand-build opts here, so set the same key directly —
    // without it the probe path hangs at `YoutubeDL(opts)` instantiation. Confirmed
    // empirically: build 14 stderr-redirect log captured `Popen.communicate` for ffmpeg
    // as the last entry before the 4+ minute spin.
    opts["ffmpeg_location"] = PythonObject("/dev/null/no-ffmpeg")

    bridgeLog.info("extract_info: importing yt_dlp module via Python.attemptImport")
    let yt_dlp_module = try Python.attemptImport("yt_dlp")
    bridgeLog.info("extract_info: yt_dlp imported, instantiating YoutubeDL (verbose, stderr→file)")
    let ydl = yt_dlp_module.YoutubeDL(opts)
    bridgeLog.info("extract_info: YoutubeDL instantiated, calling extract_info(url, download=False)")

    defer {
        tailTask.cancel()
        bridgeLog.info("extract_info: tail task cancelled")
    }
    let result = try ydl.extract_info.throwing.dynamicallyCall(withArguments: [url, false])
    bridgeLog.info("extract_info: extract_info call returned, handing back to caller")
    return result
}
