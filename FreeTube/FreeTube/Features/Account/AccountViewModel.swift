import Foundation
import Observation

@available(iOS 17.0, *)
@Observable
@MainActor
final class AccountViewModel {
    private(set) var info: AccountInfo?
    private(set) var isLoading: Bool = false
    var errorState: ErrorState?

    private let service: any AccountServicing
    private let session: SessionManager

    init(
        service: any AccountServicing = AccountService(),
        session: SessionManager = .shared
    ) {
        self.service = service
        self.session = session
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            info = try await service.fetchAccountInfo()
        } catch YouTubeServiceError.notAuthenticated {
            info = nil
        } catch {
            errorState = ErrorState(from: error)
        }
    }

    func signOut() async {
        await session.signOut()
        await LoginCoordinator.clearWebData()
        info = nil
    }
}
