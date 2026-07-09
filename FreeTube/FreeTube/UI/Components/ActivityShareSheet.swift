import SwiftUI
import UIKit

/// SwiftUI wrapper around `UIActivityViewController` for "Open in…" workflows.
///
/// `ShareLink` works fine for URLs and strings but is unreliable for `file://` URLs inside a `Menu`
/// — depending on iOS version it sometimes serializes the URL as text rather than offering it as a
/// file activity item, so the share sheet shows only "Copy" and not the actual apps that handle
/// the underlying UTType. Falling back to `UIActivityViewController` directly handles file URLs
/// the way the rest of the system expects.
struct ActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    var excludedActivityTypes: [UIActivity.ActivityType]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
        controller.excludedActivityTypes = excludedActivityTypes
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {
        // Nothing to update — the activity controller doesn't accept post-creation changes.
    }
}
