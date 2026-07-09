import Foundation
import Combine
import WebKit
import OSLog

/// Drives the `WKWebView`-based login flow per CLAUDE.md §9.
/// - Loads `accounts.google.com`.
/// - Watches for redirects to `youtube.com` after sign-in.
/// - Reads cookies from `WKWebsiteDataStore.default().httpCookieStore`.
/// - Verifies all required cookies (`SAPISID`, `__Secure-3PAPISID`, `LOGIN_INFO`, `SID`, `HSID`,
///   `SSID`, `APISID`) are present before storing the cookie header in Keychain.
@available(iOS 17.0, *)
@MainActor
final class LoginCoordinator: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case awaitingCredentials
        case verifying
        case succeeded
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    func resetState() {
        state = .idle
    }

    private let log = AppLog(subsystem: "com.leshko.freetube", category: "LoginCoordinator")
    private let session = SessionManager.shared

    /// Start URL that tells Google "this is a YouTube sign-in" via the `service=youtube` and
    /// `continue=youtube.com/signin?...` parameters. Without these, accounts.google.com just
    /// returns to `myaccount.google.com` after successful login and never visits YouTube — so
    /// no YouTube cookies (SAPISID, LOGIN_INFO, etc.) are ever set in the WKWebView's data
    /// store, and the login flow silently captures nothing. Forcing the post-login bounce to
    /// `youtube.com` is the same trick yt-dlp / NewPipe / Invidious use for browser-based auth.
    static let startURL: URL = {
        var components = URLComponents(string: "https://accounts.google.com/ServiceLogin")!
        components.queryItems = [
            URLQueryItem(name: "service", value: "youtube"),
            URLQueryItem(name: "uilel", value: "3"),
            URLQueryItem(name: "passive", value: "true"),
            URLQueryItem(name: "continue", value: "https://www.youtube.com/signin?action_handle_signin=true&next=%2F")
        ]
        return components.url!
    }()
    static let signedInHostFragment = "youtube.com"

    /// Fallback URL to load if we detect Google sign-in completed but the redirect to YouTube
    /// didn't happen automatically (some accounts land on `myaccount.google.com` after sign-in).
    /// Loading youtube.com directly causes YouTube's edge to set its session cookies (SAPISID,
    /// LOGIN_INFO, …) for the now-authenticated Google session.
    static let youTubeLandingURL = URL(string: "https://www.youtube.com/")!

    func handleNavigation(to url: URL?, in webView: WKWebView) {
        guard let url else {
            log.debug("[login] handleNavigation called with nil url")
            return
        }
        log.info("[login] nav → host=\(url.host ?? "?", privacy: .public) path=\(url.path, privacy: .public)")
        if url.host?.contains(Self.signedInHostFragment) == true {
            log.info("[login] reached youtube.com — entering verifying state, will read cookies")
            state = .verifying
            Task { await captureCookies(from: webView) }
            return
        }
        if isPostSignInGoogleURL(url) {
            log.info("[login] detected post-sign-in Google URL — bouncing to youtube.com to mint YT cookies")
            webView.load(URLRequest(url: Self.youTubeLandingURL))
        }
    }

    /// Heuristic for "Google login completed, now on an account-management page". When we see
    /// one of these, we know the credentials were accepted but the OAuth-style continue redirect
    /// to youtube.com didn't happen for some reason — so we bounce manually.
    private func isPostSignInGoogleURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if host == "myaccount.google.com" { return true }
        if host == "accounts.google.com" {
            // accounts.google.com/b/0/ManageAccount, /InteractiveLogin/CheckCookie, etc. show up
            // after a successful interactive sign-in.
            let path = url.path.lowercased()
            return path.contains("manageaccount") || path.contains("checkcookie") || path.contains("/b/")
        }
        return false
    }

    private func captureCookies(from webView: WKWebView) async {
        // Cookies are written to the shared store asynchronously after navigation commits.
        // Reading immediately on `didCommit` sometimes misses the freshest YT cookies, so we
        // also re-check on `didFinish` — the coordinator gets both callbacks. To keep this
        // method idempotent, only do the keychain write when we have the full required set.
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let ytCookies = cookies.filter { $0.domain.hasSuffix("youtube.com") || $0.domain.hasSuffix(".google.com") }
        let presentNames = Set(ytCookies.map(\.name))
        let missing = CookieStore.requiredCookieNames.subtracting(presentNames).sorted().joined(separator: ",")

        // Count duplicates so we can confirm the dedup logic in CookieStore is actually firing.
        let byName = Dictionary(grouping: ytCookies, by: \.name)
        let duplicateNames = byName.filter { $0.value.count > 1 }
        let duplicateSummary = duplicateNames
            .map { "\($0.key)×\($0.value.count)" }
            .sorted()
            .joined(separator: ",")
        let domainSet = Set(ytCookies.map(\.domain)).sorted().joined(separator: ",")

        log.info("[login] captureCookies: total=\(cookies.count, privacy: .public) ytScoped=\(ytCookies.count, privacy: .public) presentRequired=\(CookieStore.requiredCookieNames.intersection(presentNames).count, privacy: .public)/\(CookieStore.requiredCookieNames.count, privacy: .public) missing=[\(missing, privacy: .public)] uniqueNames=\(byName.count, privacy: .public)")
        log.info("[login] captureCookies domains: [\(domainSet, privacy: .public)]")
        if !duplicateNames.isEmpty {
            log.info("[login] captureCookies duplicates (will be deduped): [\(duplicateSummary, privacy: .public)]")
        } else {
            log.info("[login] captureCookies: no duplicate names — single-domain capture")
        }

        // Full per-cookie dump — name, domain, path, secure/httpOnly flags, value length.
        // **Cookie values are never logged** (CLAUDE.md §5: cookies are sensitive, value bytes
        // must not touch logs). The length is safe and helps us tell empty / placeholder
        // cookies from real session ones.
        let sorted = cookies.sorted { ($0.domain, $0.name) < ($1.domain, $1.name) }
        log.info("[login] === full cookie inventory (\(sorted.count, privacy: .public)) ===")
        for c in sorted {
            let flags: [String] = [
                c.isSecure ? "secure" : nil,
                c.isHTTPOnly ? "httpOnly" : nil,
                c.isSessionOnly ? "session" : nil
            ].compactMap { $0 }
            let flagText = flags.isEmpty ? "" : " flags=[\(flags.joined(separator: ","))]"
            let scope = c.domain.hasSuffix("youtube.com")
                ? "[yt]"
                : (c.domain.hasSuffix("google.com") ? "[g]" : "[other]")
            log.info("[login] cookie \(scope, privacy: .public) name=\(c.name, privacy: .public) domain=\(c.domain, privacy: .public) path=\(c.path, privacy: .public) valueLen=\(c.value.count, privacy: .public)\(flagText, privacy: .public)")
        }
        log.info("[login] === end cookie inventory ===")

        guard let header = CookieStore.shared.makeHeader(from: cookies) else {
            log.notice("[login] required cookie set incomplete — staying in verifying, waiting for next navigation callback")
            // Stay in `.verifying` so the next navigation callback gets another shot — don't
            // flip to `.failed` here. The user can still tap Cancel to abort.
            return
        }
        log.info("[login] required cookies present, signing in (header length=\(header.count, privacy: .public))")
        await session.signIn(with: header)
        state = .succeeded
        log.info("[login] sign-in succeeded — state=.succeeded")
    }

    /// Wipe WKWebView data store at sign-out time (called from `AccountViewModel.signOut`).
    static func clearWebData() async {
        let types: Set<String> = [
            WKWebsiteDataTypeCookies,
            WKWebsiteDataTypeLocalStorage,
            WKWebsiteDataTypeSessionStorage,
            WKWebsiteDataTypeIndexedDBDatabases,
            WKWebsiteDataTypeWebSQLDatabases
        ]
        await WKWebsiteDataStore.default()
            .removeData(ofTypes: types, modifiedSince: .distantPast)
    }
}
