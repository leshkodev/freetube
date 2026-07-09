import SwiftUI

struct LoadingView: View {
    var body: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 40)
    }
}

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.vertical, 60)
        .frame(maxWidth: .infinity)
    }
}
