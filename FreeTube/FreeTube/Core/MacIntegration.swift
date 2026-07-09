import Foundation

/// Helpers that only do something useful when the app is running on macOS — either via
/// "Designed for iPad on Mac" (current distribution shape — `ProcessInfo.isiOSAppOnMac`)
/// or real Catalyst (`isMacCatalystApp`). On iPhone/iPad these are no-ops, so callers can
/// always invoke them without guarding the host platform themselves.
///
/// **Why a free namespace and not a `View` extension:** the reveal-in-Finder bridge uses
/// `NSWorkspace` via Objective-C runtime lookup — touching it inside SwiftUI code paths
/// would imply AppKit at compile time, which would break the iOS build. Keeping it here as
/// pure-Foundation API lets the file compile cleanly everywhere and run conditionally.
enum MacIntegration {
    /// True when the bundled iPad binary is running on macOS, or under real Mac Catalyst.
    static var isRunningOnMac: Bool {
        let info = ProcessInfo.processInfo
        return info.isMacCatalystApp || info.isiOSAppOnMac
    }

    /// Pops a Finder window selecting the file. Uses `NSWorkspace.sharedWorkspace
    /// .activateFileViewerSelectingURLs:` via Objective-C runtime lookup — we can't
    /// `import AppKit` because the binary also has to compile for iOS, but `NSWorkspace` is
    /// reachable from the iOS-app-on-Mac runtime via `NSClassFromString`.
    ///
    /// No-op when not running on a Mac runtime (the runtime check fails fast).
    static func revealInFinder(_ url: URL) {
        guard isRunningOnMac else { return }
        guard let workspaceClass = NSClassFromString("NSWorkspace") as? NSObject.Type else { return }
        let sel = NSSelectorFromString("sharedWorkspace")
        let workspace = workspaceClass.perform(sel)?.takeUnretainedValue() as? NSObject
        _ = workspace?.perform(
            NSSelectorFromString("activateFileViewerSelectingURLs:"),
            with: [url] as NSArray
        )
    }
}
