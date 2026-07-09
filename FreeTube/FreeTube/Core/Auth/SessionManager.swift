import Foundation
import OSLog

/// Loads the persisted cookie header on launch and pushes it to YouTubeKit. Reacts to expiration by
/// clearing cookies and flipping `AuthState.shared.status = .loggedOut`.
@available(iOS 17.0, *)
@MainActor
final class SessionManager {
    static let shared = SessionManager()

    private let store = CookieStore.shared
    private let client = YouTubeKitClient.shared
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "SessionManager")

    private init() {}

    /// Call exactly once during `FreeTubeApp.init` or `RootView.onAppear`.
    func bootstrap() async {
        if let header = store.loadHeader(), !header.isEmpty {
            client.applyCookies(header)
            AuthState.shared.status = .loggedIn(displayName: nil)
            log.info("[session] bootstrap: header found in keychain (length=\(header.count, privacy: .public)) → applied to client, status=.loggedIn")
        } else {
            AuthState.shared.status = .loggedOut
            log.info("[session] bootstrap: no cookies on disk — status=.loggedOut")
        }
        // Visitor data is needed even for anonymous video requests. See YouTubeKitClient.ensureVisitorData().
        await client.ensureVisitorData()
        log.info("[session] bootstrap: visitor data ensured")
    }

    func signIn(with header: String) async {
        log.info("[session] signIn called — header length=\(header.count, privacy: .public)")
        store.storeHeader(header)
        client.applyCookies(header)
        AuthState.shared.status = .loggedIn(displayName: nil)
        log.info("[session] signIn complete → status=.loggedIn")
    }

    func signOut() async {
        log.info("[session] signOut called")
        store.clear()
        client.applyCookies("")
        // Drop the visitor token too — if cookies were stale, the token they were paired with may
        // also be invalid. `ensureVisitorData` below seeds a fresh one for the anonymous session.
        client.clearVisitorData()
        await client.ensureVisitorData()
        // Wipe the local subscriptions cache so the next signed-in user doesn't see the previous
        // account's channels marked as "subscribed".
        SubscriptionRegistry.shared.clear()
        AuthState.shared.status = .loggedOut
        log.info("[session] signOut complete → status=.loggedOut")
    }

    /// Called by error-handling layer when 401-equivalent or `cookieExpired` is observed.
    func handleExpiredSession() async {
        log.error("[session] expired — clearing cookies and routing to login")
        await signOut()
    }
}
