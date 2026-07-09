import Foundation

/// Loader for the bundled `yt-dlp-ejs` JavaScript solver assets.
///
/// We ship `core.min.js` (the N/SIG challenge solver from `yt-dlp/ejs`) and `lib.min.js`
/// (its bundled deps: the `meriyah` JS parser + `astring` code generator) directly in the
/// app bundle. The Python-side `yt_dlp_ejs` shim (see `PythonJSBridge`) reads these via
/// `EJSResources.core()` / `EJSResources.lib()` and exposes them through the same
/// `yt_dlp_ejs.yt.solver.core()` / `lib()` API yt-dlp expects.
///
/// **Version tracking:** `version` must match the upstream package version these files were
/// pulled from. yt-dlp validates the version tuple's major/minor against its embedded
/// `_SCRIPT_VERSION` (see `yt_dlp.extractor.youtube.jsc._builtin.vendor.VERSION`) — if our
/// version doesn't match the major/minor of the yt-dlp build the user has, yt-dlp will reject
/// our scripts and fall through to no-JS-runtime. When the YoutubeDL-iOS package upgrades
/// yt-dlp, re-pull `yt-dlp-ejs` from PyPI and bump `version` here.
@available(iOS 17.0, *)
nonisolated enum EJSResources {
    /// Upstream `yt-dlp-ejs` version these JS files came from. Pulled from PyPI 2026-05-19.
    static let version = "0.8.0"

    /// Returns the contents of `core.min.js` (the N/SIG challenge solver).
    static func core() throws -> String {
        try loadResource(name: "core.min", ext: "js")
    }

    /// Returns the contents of `lib.min.js` (meriyah + astring bundle).
    static func lib() throws -> String {
        try loadResource(name: "lib.min", ext: "js")
    }

    private static func loadResource(name: String, ext: String) throws -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else {
            throw Error.notFound("\(name).\(ext)")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    enum Error: Swift.Error, CustomStringConvertible {
        case notFound(String)

        var description: String {
            switch self {
            case .notFound(let name): return "EJS resource not found in bundle: \(name)"
            }
        }
    }
}
