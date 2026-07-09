import Foundation
import Observation

/// Global, observable auth state. Root view watches this and routes Login when `loggedOut` fires.
/// CLAUDE.md §12: on `cookieExpired` / 401 the session manager flips this and clears cookies.
@available(iOS 17.0, *)
@Observable
final class AuthState {
    enum Status: Equatable {
        case unknown
        case loggedIn(displayName: String?)
        case loggedOut
    }

    var status: Status = .unknown

    static let shared = AuthState()

    private init() {}
}
