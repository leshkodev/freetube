import Foundation
import OSLog

/// Persists the YouTube cookie header string in the Keychain. Per CLAUDE.md §2 cookies must
/// never touch disk, `UserDefaults`, plist, or logs — only Keychain in-memory access at runtime.
final class CookieStore {
    static let shared = CookieStore()

    static let keychainKey = "com.leshko.freetube.cookies"

    /// CLAUDE.md §9 list. Login is only considered successful when *all* of these are present.
    static let requiredCookieNames: Set<String> = [
        "SAPISID",
        "__Secure-3PAPISID",
        "LOGIN_INFO",
        "SID",
        "HSID",
        "SSID",
        "APISID"
    ]

    private let log = AppLog(subsystem: "com.leshko.freetube", category: "CookieStore")

    private init() {}

    func storeHeader(_ header: String) {
        do {
            try KeychainHelper.set(header, for: Self.keychainKey)
            log.info("[cookies] keychain write OK (length=\(header.count, privacy: .public))")
        } catch {
            log.error("[cookies] keychain write FAILED: \(String(describing: error), privacy: .public)")
        }
    }

    func loadHeader() -> String? {
        let header = KeychainHelper.string(for: Self.keychainKey)
        log.info("[cookies] keychain read \(header == nil ? "miss" : "hit (length=\(header!.count))", privacy: .public)")
        return header
    }

    func clear() {
        KeychainHelper.delete(Self.keychainKey)
        log.info("[cookies] keychain cleared")
    }

    /// Builds a `Cookie:` header string from a list of `HTTPCookie`. Filters to YouTube/Google
    /// cookies and **deduplicates by name**, preferring the entry with the most general domain
    /// scope.
    ///
    /// Why the dedupe matters: when the WKWebView's redirect chain visits
    /// `accounts.google.com → m.youtube.com → www.youtube.com`, YouTube sets multiple cookies
    /// with the same name but different domain attributes — e.g. one `SID` scoped to
    /// `m.youtube.com` and another scoped to `.youtube.com`. Concatenating both into a single
    /// `Cookie:` header sends `SID=mobile; SID=cross-domain;`, and YouTube's server picks one
    /// (often the first) which can be the mobile-only value that fails to validate at
    /// `www.youtube.com/youtubei/v1/...`. Picking the broadest-domain variant per name fixes
    /// the resulting "logged out despite valid cookies" symptom.
    func makeHeader(from cookies: [HTTPCookie]) -> String? {
        let scoped = cookies.filter {
            $0.domain.hasSuffix("youtube.com") || $0.domain.hasSuffix(".google.com")
        }

        // Domain inventory — quick way to confirm we have cookies from `.youtube.com` (cross-
        // subdomain) and not just `m.youtube.com` or `www.youtube.com` scoped variants.
        let domainSummary = Dictionary(grouping: scoped, by: \.domain)
            .map { "\($0.key)=\($0.value.count)" }
            .sorted()
            .joined(separator: ", ")
        log.info("[cookies] makeHeader: incoming \(cookies.count, privacy: .public) total / \(scoped.count, privacy: .public) yt+google-scoped — domains: [\(domainSummary, privacy: .public)]")

        // **Preference rules** (in order of priority — first wins):
        //   1. Prefer the YouTube-scoped cookie. The auth redirect lands on m.youtube.com which
        //      causes YouTube to set its session cookies AND Google to set its own session
        //      cookies under `.google.com`. We're sending the request to `www.youtube.com`, and
        //      a real browser would only attach cookies whose domain matches that host — never
        //      the `.google.com` variants. Picking the Google ones (as the old "shorter domain"
        //      heuristic did when both `.youtube.com` and `.google.com` were 12 chars long)
        //      produced "logged out" responses despite identical cookie names.
        //   2. Among multiple YouTube-scoped variants, prefer leading-dot (`.youtube.com` over
        //      `m.youtube.com`) since the dot version is cross-subdomain.
        //   3. Final tiebreaker: shorter domain string.
        func rank(_ cookie: HTTPCookie) -> (Int, Int, Int) {
            let dom = cookie.domain
            let ytScope: Int
            if dom.hasSuffix("youtube.com") {
                ytScope = 0           // best
            } else if dom.hasSuffix("google.com") {
                ytScope = 1           // worst — last resort
            } else {
                ytScope = 2
            }
            let dotFlag = dom.hasPrefix(".") ? 0 : 1
            return (ytScope, dotFlag, dom.count)
        }
        let grouped = Dictionary(grouping: scoped, by: \.name)
        var chosen: [HTTPCookie] = []
        for (name, duplicates) in grouped {
            guard let best = duplicates.min(by: { rank($0) < rank($1) }) else { continue }
            if duplicates.count > 1 {
                let droppedDomains = duplicates
                    .filter { $0 !== best }
                    .map(\.domain)
                    .sorted()
                    .joined(separator: ",")
                log.info("[cookies] dedupe \(name, privacy: .public): chose domain=\(best.domain, privacy: .public), dropped=[\(droppedDomains, privacy: .public)]")
            }
            chosen.append(best)
        }

        let chosenNames = Set(chosen.map(\.name))
        let missing = Self.requiredCookieNames.subtracting(chosenNames).sorted()
        guard missing.isEmpty else {
            log.notice("[cookies] makeHeader: incomplete — missing=[\(missing.joined(separator: ","), privacy: .public)]")
            return nil
        }
        let dropped = scoped.count - chosen.count
        let header = chosen.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")

        // Sanity-check the auth-critical names so we can confirm dedup didn't accidentally drop
        // them. We log presence + the domain we kept (not the value).
        let critical = ["SAPISID", "SID", "__Secure-1PSID", "__Secure-3PSID", "LOGIN_INFO"]
        for name in critical {
            if let cookie = chosen.first(where: { $0.name == name }) {
                log.info("[cookies] kept \(name, privacy: .public) domain=\(cookie.domain, privacy: .public) length=\(cookie.value.count, privacy: .public)")
            } else {
                log.notice("[cookies] MISSING after dedup: \(name, privacy: .public)")
            }
        }

        log.info("[cookies] makeHeader: built — kept=\(chosen.count, privacy: .public) dropped=\(dropped, privacy: .public) duplicates, header length=\(header.count, privacy: .public)")
        return header
    }
}
