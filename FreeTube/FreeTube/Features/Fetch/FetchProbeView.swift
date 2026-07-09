import SwiftUI
import Kingfisher

/// Probe-result screen. Layout:
///   - Header (thumb / title / uploader / extractor badge / live badge / duration)
///   - **Video** button — tap to open a menu of all video-bearing formats. Label shows the
///     current selection (e.g. "1080p mp4 · 245 MB"). Includes a "None" option for
///     audio-only downloads.
///   - **Audio** button — same shape, lists audio-bearing formats. Includes "None" for
///     silent/video-only downloads.
///   - **Output** summary line — shows the destination filename + extension and total size
///     so the user knows what they're about to commit to.
///   - **Download** button — single CTA. Disabled when both menus are set to "None".
///   - Live job row below once a download is in flight.
///
/// Selection state lives on `FetchViewModel.selectedVideoFormat` / `selectedAudioFormat` so
/// it survives nav-back / nav-forward. Defaults are applied on every fresh probe (best
/// adaptive video + best adaptive audio, or best progressive when no adaptive formats
/// exist).
@available(iOS 17.0, *)
struct FetchProbeView: View {
    @Bindable var model: FetchViewModel
    @State private var downloads = URLDownloadManager.shared

    var body: some View {
        Group {
            switch model.probeState {
            case .idle, .loading:
                loadingView
            case .loaded(let media):
                content(for: media)
            case .failed(let message, let url):
                failureView(message: message, url: url)
            }
        }
        .navigationTitle("Preview")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - States

    @ViewBuilder
    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.4)
            Text("Reading link…")
                .foregroundStyle(.secondary)
            Text("This can take a few seconds the first time yt-dlp loads.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func failureView(message: String, url: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Couldn't read this link")
                .font(.headline)
            Text(message)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Button("Try again") {
                model.query = url
                model.submit()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func content(for media: RemoteMedia) -> some View {
        let videoFormats = media.formats.filter { $0.hasVideo && $0.url != nil && $0.protocolKind != .unsupported }
        let audioFormats = media.formats.filter { $0.hasAudio && $0.url != nil && $0.protocolKind != .unsupported }

        List {
            Section {
                headerCell(media)
            }
            .listRowSeparator(.hidden)

            Section {
                videoMenu(videoFormats: videoFormats)
                audioMenu(audioFormats: audioFormats)
            } header: {
                Text("Format")
            }

            Section {
                // Video → H.264. Apple's hardware encoder is fast (~realtime on iPhone)
                // and the resulting mp4 plays everywhere. Auto-on for non-H.264 sources
                // (set by `recomputeConversionDefaults` when the selection changes).
                Toggle(isOn: Bindable(model).convertVideoToH264) {
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Convert video to H.264")
                            if let codec = model.selectedVideoFormat?.vcodec, !codec.isEmpty {
                                Text("Source codec: \(codecLabel(codec))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: "film")
                    }
                }
                .disabled(model.selectedVideoFormat == nil)

                Toggle(isOn: Bindable(model).convertAudioToMP3) {
                    Label("Convert audio to MP3", systemImage: "music.note.list")
                }
                .disabled(model.selectedAudioFormat == nil && (model.selectedVideoFormat?.isProgressive ?? false) == false && model.selectedVideoFormat?.hasAudio != true)
            } header: {
                Text("Convert")
            } footer: {
                Text("H.264 is universally playable on Apple platforms. MP3 is for audio you'll share with apps that don't accept AAC / Opus. Conversion happens on-device via FFmpeg and may take a few seconds.")
                    .font(.caption)
            }

            Section {
                summaryRow(media: media)
                downloadButton(media: media)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }

        }
        .listStyle(.insetGrouped)
        // Re-compute the "Convert to H.264" default whenever the user picks a new video
        // format — switching from a VP9 to an H.264 row should flip the auto-toggle off,
        // and vice versa.
        .onChange(of: model.selectedVideoFormat?.id) { _, _ in
            model.recomputeConversionDefaults()
        }
    }

    /// Pretty codec label for the "Source codec" caption under the Convert toggle. Mirrors
    /// the `shortVideoCodec` helper used in the menu rows.
    private func codecLabel(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.hasPrefix("avc") || lower.contains("h264") { return "H.264" }
        if lower.hasPrefix("hev") || lower.hasPrefix("hvc") || lower.contains("hevc") { return "HEVC" }
        if lower.hasPrefix("vp09") || lower.hasPrefix("vp9") { return "VP9" }
        if lower.hasPrefix("av01") || lower.contains("av1") { return "AV1" }
        return raw.uppercased()
    }

    // MARK: - Header

    @ViewBuilder
    private func headerCell(_ media: RemoteMedia) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let thumb = media.thumbnailURL {
                KFImage(thumb)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                    .clipped()
                    .cornerRadius(8)
            }
            Text(media.title)
                .font(.headline)
                .lineLimit(3)
            HStack(spacing: 8) {
                if let uploader = media.uploader, !uploader.isEmpty {
                    Label(uploader, systemImage: "person.crop.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let extractor = media.extractor {
                    Text(extractor)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
                Spacer()
                if let duration = media.duration {
                    Text(formatDuration(duration))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if media.isLive {
                    Text("LIVE")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red, in: Capsule())
                        .foregroundStyle(.white)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Menus

    @ViewBuilder
    private func videoMenu(videoFormats: [RemoteFormat]) -> some View {
        // Sort by AVPlayer-compatibility tier first (H.264 → HEVC → everything else), then
        // resolution and fps. Matches `FetchViewModel.videoRank` so the menu's top option is
        // also what `applyDefaults` would pick. Reversed so "best" sits at the top.
        let sorted = videoFormats.sorted { FetchViewModel.videoRank($0, $1) }.reversed().map { $0 }
        Menu {
            ForEach(sorted) { fmt in
                Button {
                    model.selectedVideoFormat = fmt
                    // If the user picks a progressive (has audio embedded), drop any
                    // separate audio selection — combining them would be ignored anyway and
                    // it's confusing to leave it set.
                    if fmt.isProgressive { model.selectedAudioFormat = nil }
                } label: {
                    formatMenuLabel(fmt, kind: .video)
                }
            }
            if !sorted.isEmpty { Divider() }
            Button("None (audio only)") {
                model.selectedVideoFormat = nil
            }
        } label: {
            menuButtonLabel(
                title: "Video",
                systemImage: "video.fill",
                selection: model.selectedVideoFormat,
                placeholder: "Select…",
                disabledNote: sorted.isEmpty ? "No video streams" : nil
            )
        }
        .disabled(sorted.isEmpty)
    }

    @ViewBuilder
    private func audioMenu(audioFormats: [RemoteFormat]) -> some View {
        let sorted = audioFormats.sorted { lhs, rhs in
            (lhs.abr ?? 0) > (rhs.abr ?? 0)
        }
        let videoIsProgressive = model.selectedVideoFormat?.isProgressive ?? false

        Menu {
            ForEach(sorted) { fmt in
                Button {
                    model.selectedAudioFormat = fmt
                } label: {
                    formatMenuLabel(fmt, kind: .audio)
                }
            }
            if !sorted.isEmpty { Divider() }
            Button(videoIsProgressive ? "None (use video's embedded audio)" : "None (silent video)") {
                model.selectedAudioFormat = nil
            }
        } label: {
            menuButtonLabel(
                title: "Audio",
                systemImage: "music.note",
                selection: model.selectedAudioFormat,
                placeholder: videoIsProgressive ? "Included with video" : "Select…",
                disabledNote: sorted.isEmpty ? "No audio streams" : nil
            )
        }
        .disabled(sorted.isEmpty)
    }

    /// Row inside a Menu — bigger label with the full format detail.
    private func formatMenuLabel(_ fmt: RemoteFormat, kind: FormatKind) -> Text {
        var pieces: [String] = [fmt.label, fmt.ext.uppercased()]
        // Surface the codec so users notice the H.264 vs VP9/AV1 distinction. VP9/AV1 in MP4
        // plays poorly on older Apple stacks — Instagram and YouTube both serve those
        // formats. A short codec tag in the label makes it obvious which row is the safe
        // choice without having to know the format-ID convention.
        if kind == .video, let short = shortVideoCodec(fmt.vcodec) {
            pieces.append(short)
        } else if kind == .audio, let short = shortAudioCodec(fmt.acodec) {
            pieces.append(short)
        }
        if fmt.protocolKind == .hls { pieces.append("HLS") }
        if fmt.protocolKind == .dash { pieces.append("DASH") }
        if let size = fmt.filesize { pieces.append(byteString(size)) }
        if kind == .video && fmt.isProgressive { pieces.append("+ audio") }
        return Text(pieces.joined(separator: " · "))
    }

    /// "avc1.640028" → "H.264". "vp09.00.41.08" → "VP9". Returns nil when there's no codec
    /// info to show.
    private func shortVideoCodec(_ raw: String?) -> String? {
        guard let lower = raw?.lowercased(), !lower.isEmpty else { return nil }
        if lower.hasPrefix("avc") || lower.contains("h264") || lower.contains("h.264") { return "H.264" }
        if lower.hasPrefix("hev") || lower.hasPrefix("hvc") || lower.contains("h265") || lower.contains("hevc") { return "HEVC" }
        if lower.hasPrefix("vp09") || lower.hasPrefix("vp9") { return "VP9" }
        if lower.hasPrefix("av01") || lower.contains("av1") { return "AV1" }
        if lower.hasPrefix("vp08") || lower.hasPrefix("vp8") { return "VP8" }
        return raw?.uppercased()
    }

    /// "mp4a.40.2" → "AAC", "opus" → "Opus".
    private func shortAudioCodec(_ raw: String?) -> String? {
        guard let lower = raw?.lowercased(), !lower.isEmpty else { return nil }
        if lower.hasPrefix("mp4a") || lower.contains("aac") { return "AAC" }
        if lower.contains("opus") { return "Opus" }
        if lower.contains("vorbis") { return "Vorbis" }
        if lower.contains("mp3") { return "MP3" }
        return raw?.uppercased()
    }

    /// Outer button label for the Menu — shows the current selection or placeholder.
    @ViewBuilder
    private func menuButtonLabel(title: String, systemImage: String, selection: RemoteFormat?, placeholder: String, disabledNote: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(disabledNote ?? selection.map { selectionSummary($0) } ?? placeholder)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    /// Compact selection caption shown under the menu's title — fits in one line.
    private func selectionSummary(_ fmt: RemoteFormat) -> String {
        var pieces = [fmt.label, fmt.ext.uppercased()]
        if let size = fmt.filesize { pieces.append(byteString(size)) }
        return pieces.joined(separator: " · ")
    }

    private enum FormatKind { case video, audio }

    // MARK: - Output summary + download

    @ViewBuilder
    private func summaryRow(media: RemoteMedia) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.fill")
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text("Will save")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(outputFilename(media: media))
                    .font(.body.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if let total = estimatedTotalBytes() {
                Text("≈ \(byteString(total))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func downloadButton(media: RemoteMedia) -> some View {
        let enabled = model.selectedVideoFormat != nil || model.selectedAudioFormat != nil
        Button {
            _ = downloads.startDownload(
                originalURL: model.activeProbeURL ?? (media.webpageURL?.absoluteString ?? ""),
                media: media,
                video: model.selectedVideoFormat,
                audio: model.selectedAudioFormat,
                conversion: ConversionOptions(
                    videoToH264: model.convertVideoToH264,
                    audioToMP3: model.convertAudioToMP3
                )
            )
            // Pop back to FetchScreen — the queue row on the recents list now shows live
            // progress + cancel for this download. Flipping probeState to .idle causes
            // FetchScreen's `.navigationDestination(isPresented:)` binding to return false,
            // which pops the stack.
            model.clearResult()
        } label: {
            HStack {
                Spacer()
                Image(systemName: "arrow.down.circle.fill")
                Text("Download")
                    .fontWeight(.semibold)
                Spacer()
            }
            .frame(minHeight: 36)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!enabled)
    }

    /// What the saved file will be named. Mirrors `URLDownloadManager`'s logic: audio-only
    /// preserves the audio extension; everything else lands as `.mp4`.
    private func outputFilename(media: RemoteMedia) -> String {
        let stem = (media.title.isEmpty ? media.id : media.title)
            .replacingOccurrences(of: "/", with: "_")
            .prefix(80)
        let ext: String = {
            // Audio-only download (no video selected).
            if model.selectedVideoFormat == nil, let a = model.selectedAudioFormat {
                return a.ext
            }
            return "mp4"
        }()
        return "\(stem).\(ext)"
    }

    /// Sum of selected formats' filesize hints, when available. Best-effort — yt-dlp returns
    /// estimates for HLS/DASH and exact values for progressive.
    private func estimatedTotalBytes() -> Int64? {
        var total: Int64 = 0
        if let v = model.selectedVideoFormat?.filesize { total += v }
        if let a = model.selectedAudioFormat?.filesize, model.selectedAudioFormat?.id != model.selectedVideoFormat?.id {
            total += a
        }
        return total > 0 ? total : nil
    }

    // MARK: - Helpers

    private func activeJob(for media: RemoteMedia) -> FetchJob? {
        downloads.jobs.values
            .filter { $0.key.hasPrefix("\(media.id)|") }
            .sorted { $0.startedAt > $1.startedAt }
            .first
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    private func byteString(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

/// Row used for the live "Download" section at the bottom of `FetchProbeView`. Shows the
/// current state with a percent / spinner, plus a Share button when complete.
@available(iOS 17.0, *)
struct FetchJobRow: View {
    let job: FetchJob
    let onDismiss: () -> Void
    @State private var showingShareSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                stateIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.formatLabel).font(.subheadline.weight(.medium))
                    stateLabel.font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                trailingControl
            }
            if case .downloading(let progress, _) = job.state {
                if let progress {
                    ProgressView(value: progress)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
            } else if case .processing = job.state {
                ProgressView().progressViewStyle(.linear)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch job.state {
        case .queued: Image(systemName: "hourglass").foregroundStyle(.secondary)
        case .downloading: Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
        case .processing: Image(systemName: "gearshape.2.fill").foregroundStyle(.tint)
        case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var stateLabel: some View {
        switch job.state {
        case .queued: Text("Queued")
        case .downloading(let progress, let phase):
            if let phase, let progress {
                Text("\(phase) · \(Int(progress * 100))%")
            } else if let phase {
                Text("\(phase) · streaming…")
            } else if let progress {
                Text("\(Int(progress * 100))%")
            } else {
                Text("Streaming…")
            }
        case .processing(let msg): Text(msg)
        case .completed(let url): Text("Saved to \(url.lastPathComponent)").lineLimit(1)
        case .failed(let msg): Text(msg).lineLimit(2)
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        switch job.state {
        case .completed(let url):
            Button {
                showingShareSheet = true
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .sheet(isPresented: $showingShareSheet) {
                ActivityShareSheet(activityItems: [url])
            }
        case .failed:
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        default:
            EmptyView()
        }
    }
}
