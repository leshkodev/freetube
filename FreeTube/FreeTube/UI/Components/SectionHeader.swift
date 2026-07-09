import SwiftUI

struct SectionHeader: View {
    let title: String
    var trailing: AnyView? = nil

    var body: some View {
        HStack {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            trailing
        }
        .padding(.horizontal)
        .padding(.top, 4)
    }
}
