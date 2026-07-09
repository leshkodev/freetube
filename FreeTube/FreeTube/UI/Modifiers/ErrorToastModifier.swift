import SwiftUI

/// CLAUDE.md §12: "Show errors via a single `ErrorToast` view modifier reading `errorState`."
struct ErrorToastModifier: ViewModifier {
    @Binding var errorState: ErrorState?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let errorState {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: errorState.isFatal ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        Text(errorState.message)
                            .font(.subheadline)
                            .multilineTextAlignment(.leading)
                        Spacer()
                        Button {
                            self.errorState = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.footnote)
                                .padding(4)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: errorState.id) {
                        try? await Task.sleep(for: .seconds(4))
                        if self.errorState?.id == errorState.id { self.errorState = nil }
                    }
                }
            }
            .animation(.spring(), value: errorState?.id)
    }
}

extension View {
    func errorToast(_ state: Binding<ErrorState?>) -> some View {
        modifier(ErrorToastModifier(errorState: state))
    }
}
