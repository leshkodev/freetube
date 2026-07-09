import SwiftUI
import WebKit

@available(iOS 17.0, *)
struct LoginScreen: View {
    @StateObject private var coordinator = LoginCoordinator()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                LoginWebView(coordinator: coordinator)
                if case .verifying = coordinator.state {
                    Color.black.opacity(0.3).ignoresSafeArea()
                    ProgressView("Finishing sign-in…")
                        .tint(.white)
                        .foregroundStyle(.white)
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .navigationTitle("Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onChange(of: coordinator.state) { _, new in
                if case .succeeded = new { dismiss() }
            }
            .alert(
                "Sign-in failed",
                isPresented: failureBinding,
                presenting: failureMessage
            ) { _ in
                Button("OK", role: .cancel) { coordinator.resetState() }
            } message: { message in
                Text(message)
            }
        }
    }

    private var failureMessage: String? {
        if case .failed(let message) = coordinator.state { return message }
        return nil
    }

    private var failureBinding: Binding<Bool> {
        Binding(
            get: {
                if case .failed = coordinator.state { return true }
                return false
            },
            set: { newValue in
                if !newValue { coordinator.resetState() }
            }
        )
    }
}
