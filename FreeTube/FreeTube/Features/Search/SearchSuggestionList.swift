import SwiftUI

@available(iOS 17.0, *)
struct SearchSuggestionList: View {
    let suggestions: [SearchSuggestion]
    let onTap: (SearchSuggestion) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(suggestions) { suggestion in
                Button {
                    onTap(suggestion)
                } label: {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        Text(suggestion.text)
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
    }
}
