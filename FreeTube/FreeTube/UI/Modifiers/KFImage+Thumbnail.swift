import SwiftUI
import Kingfisher

extension KFImage {
    /// Standard thumbnail-loading configuration applied at every remote-image call site.
    ///
    /// Why this exists: `AsyncImage` decodes images at full source resolution on the main
    /// thread and re-fetches on every cell recycling. For long scrolling feeds (Home, Search,
    /// Subscriptions) that drops frames on older devices. This bundles the four Kingfisher
    /// options that matter for thumbnails:
    ///   - `DownsamplingImageProcessor` — decodes at display size off-main-thread (~50–100×
    ///     less work for a 1280×720 source rendered at 168×96).
    ///   - `cacheOriginalImage()` — keep the un-downsampled image in disk cache too, so a later
    ///     larger render (player surface, fullscreen) can reuse it without a re-download.
    ///   - `fade(duration:)` — short cross-fade softens the placeholder → image transition.
    ///   - `cancelOnDisappear(true)` — fast flicks don't pile up dead requests on the queue.
    ///
    /// `size` is in points; multiplied by 3 internally for retina screens. Passing the
    /// displayed size avoids decoding a 1MB JPEG into memory for a 36pt avatar.
    func thumbnail<Placeholder: View>(
        size: CGSize,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) -> KFImage {
        self
            .placeholder(placeholder)
            .setProcessor(DownsamplingImageProcessor(size: CGSize(
                width: size.width * 3,
                height: size.height * 3
            )))
            .cacheOriginalImage()
            .fade(duration: 0.15)
            .cancelOnDisappear(true)
    }
}
