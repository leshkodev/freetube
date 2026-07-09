import Foundation
import OSLog

/// Factory that returns a real `Logger` writing to the unified log on every configuration.
///
/// **History.** This used to return `Logger(.disabled)` in Release as a battery / log-volume
/// optimization (commit `0cb0506`). That was reverted once `LogFileWriter` shipped: the writer
/// polls `OSLogStore` and gets nothing when the loggers are disabled, so TestFlight users who
/// enable "Save logs to file" in Settings (the primary diagnostic channel for sideloaded /
/// TestFlight installs) ended up with header-only log files.
///
/// **Trade-off accepted.** `Logger.info/.notice/.error` calls now hit the unified log in
/// Release. Cost is small in practice:
///   - Each call is one syscall via `os_log_internal`.
///   - String interpolation args are `@autoclosure @escaping` in `OSLogInterpolation`, so
///     expensive interpolations (`\(myArray.count, privacy: .public)`) still aren't evaluated
///     until the underlying log level fires.
///   - Privacy markers (`privacy: .public` / `.private`) gate what shows up in any sysdiagnose;
///     audit call sites to keep PII out of `.public` slots.
///
/// **If you want to mute logging again** without breaking `LogFileWriter`, the right approach
/// is not flipping this factory back to `Logger(.disabled)` — it's adding a runtime gate
/// inside `LogFileWriter.flushPass()` so the writer skips reading OSLogStore when the user
/// hasn't enabled file logging. The unified-log side then becomes a self-cleaning ring buffer
/// that costs nothing visible.
///
/// **Why a function and not a typealias.** The original attempt at a no-op `AppLog` struct
/// (mirroring `Logger`'s API with `@autoclosure () -> OSLogMessage`) fails to compile because
/// `OSLogMessage`'s string interpolation only works when the compiler recognizes the receiver
/// as a direct `os_log` call. Passing it through an autoclosure triggers "string interpolation
/// cannot be used in this context."
@inlinable
public nonisolated func AppLog(subsystem: String, category: String) -> Logger {
    Logger(subsystem: subsystem, category: category)
}
