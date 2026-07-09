import Foundation
import JavaScriptCore

/// Synchronous JavaScript evaluator backed by `JSContext` (JavaScriptCore).
///
/// **Why this exists:** YouTube's player.js obfuscates the `n` parameter in stream URLs by
/// wrapping it in a JavaScript transform. yt-dlp extracts the transform function source from
/// player.js but can't run it without a JS runtime — on desktop it shells out to `deno`/`node`
/// via subprocess.Popen; on iOS there's no such binary, so yt-dlp gives up (the `n challenge
/// solving failed` warnings in our logs) and serves URLs that subsequently 403 at YouTube's CDN.
///
/// This evaluator is the foundation of the JS-runtime path. Later phases of the work plan wire
/// it into a Python-level subprocess.Popen replacement so yt-dlp's existing `deno` integration
/// transparently routes through here.
///
/// **Contract for callers:**
/// - Each call is synchronous, independent, and short-lived. A fresh `JSContext` is allocated
///   per call so prior evaluations don't leak global state.
/// - `evaluate(_:)` runs the script and returns its final-expression value coerced to a String.
///   Wrap your computation in an IIFE if you need explicit `return` semantics:
///     `(function(){ return decode('abc'); })()`.
/// - JavaScript exceptions are captured via `context.exceptionHandler` and re-thrown as
///   `JSEvaluator.Error.scriptError`.
/// - JSContext itself is thread-safe for concurrent use, but we expect callers to drive it
///   from a single thread (typically `PythonRunner`'s `PythonSerialExecutor` so that PythonKit
///   interop stays single-threaded — CLAUDE.md §15.1).
///
/// **What it can run:** pure ES6 JavaScript (math, string manipulation, array methods, regex,
/// Function constructors, JSON). What it can't run: the DOM, fetch, `crypto.subtle`, `setTimeout`
/// — none of which the n-cipher solver needs.
@available(iOS 17.0, *)
nonisolated struct JSEvaluator {
    enum Error: Swift.Error, CustomStringConvertible {
        /// The JavaScript runtime raised an exception during evaluation. Message is from JSC.
        case scriptError(message: String)
        /// `JSContext()` returned nil. Theoretically impossible (the constructor is documented
        /// non-failing) but defensive code; if you ever see this, the runtime is broken.
        case nullContext
        /// Evaluation produced no return value (e.g. the script ended with a statement, not an
        /// expression).
        case noResult

        var description: String {
            switch self {
            case .scriptError(let message): return "JS script error: \(message)"
            case .nullContext: return "JS context could not be created"
            case .noResult: return "JS evaluation produced no value"
            }
        }
    }

    /// Evaluates the JavaScript `code` and returns its result as a String.
    ///
    /// To pass values in, embed them in the source — JSCore takes a string, not parameters:
    ///
    /// ```swift
    /// let n = "abc123"
    /// let decoded = try JSEvaluator.evaluate("""
    ///     var input = \(JSONSerialization.escape(n));
    ///     decode(input)
    /// """)
    /// ```
    ///
    /// Use the bundled `JSONSerialization.escape` helper above (or `JSONEncoder`) to escape
    /// values safely so you don't open injection holes when the input comes from YouTube.
    static func evaluate(_ code: String) throws -> String {
        guard let context = JSContext() else {
            throw Error.nullContext
        }

        // Capture any exception JSC raises during evaluation. Without this hook, exceptions
        // become silent — JSC sets `context.exception` but `evaluateScript` still returns a
        // truthy `JSValue` (the `undefined` value) and we'd mistake failure for success.
        var capturedError: String?
        context.exceptionHandler = { _, exception in
            capturedError = exception?.toString() ?? "<unknown JS exception>"
        }

        guard let value = context.evaluateScript(code) else {
            throw Error.noResult
        }

        if let err = capturedError {
            throw Error.scriptError(message: err)
        }

        // `toString()` coerces any JSValue (numbers, booleans, objects via valueOf/toString) to
        // a String. The n-cipher always returns a string, so this is the right contract here.
        guard let result = value.toString() else {
            throw Error.noResult
        }

        return result
    }
}
