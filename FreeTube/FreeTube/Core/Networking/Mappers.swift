import Foundation
import YouTubeKit

/// Maps YouTubeKit response types into the app's domain models. Lives in `Core/Networking/` per
/// CLAUDE.md §6 — services use these helpers; nothing outside this folder should see YouTubeKit types.
enum Mappers {

    // MARK: - Thumbnails

    /// Largest thumbnail (last in the array per YouTubeKit's sort order).
    static func bestThumbnailURL(_ thumbnails: [YTThumbnail]) -> URL? {
        thumbnails.last?.url
    }

    // MARK: - Videos

    static func video(from yt: YTVideo) -> Video {
        let duration = yt.timeLengthSeconds.map { TimeInterval($0) }
        // YouTubeKit returns an empty thumbnail array for some channel listings (notably Shorts
        // lockup view models when YouTube changes the JSON path). Falling back to the canonical
        // CDN URL keyed by videoId guarantees a working image — `hqdefault.jpg` is always served
        // by YouTube for every public video, including Shorts.
        let thumb = bestThumbnailURL(yt.thumbnails) ?? canonicalThumbnailURL(for: yt.videoId)
        return Video(
            id: yt.videoId,
            title: yt.title ?? "",
            channelID: yt.channel?.channelId ?? "",
            channelName: yt.channel?.name ?? "",
            channelThumbnailURL: bestThumbnailURL(yt.channel?.thumbnails ?? []),
            thumbnailURL: thumb,
            duration: duration,
            viewCount: parseViewCount(yt.viewCount),
            publishedAt: nil,
            publishedRelative: yt.timePosted,
            descriptionSnippet: nil,
            isLive: yt.timeLength == "live",
            isShort: false
        )
    }

    /// Canonical YouTube CDN thumbnail. `hqdefault` is 480×360 and is always available for any
    /// public video — used as a fallback when YouTubeKit doesn't populate the thumbnails array.
    static func canonicalThumbnailURL(for videoID: String) -> URL? {
        URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg")
    }

    private static func parseViewCount(_ text: String?) -> Int? {
        guard let text else { return nil }
        let lower = text.lowercased()
        // Quick path: pure digits with optional separators ("1,234,567").
        let digits = text.unicodeScalars.filter(CharacterSet.decimalDigits.contains).map(Character.init)
        if let value = Int(String(digits)), !lower.contains("k"), !lower.contains("m"), !lower.contains("b") {
            return value
        }
        // Short-form path ("1.2M views", "856K"): parse the leading number then apply suffix.
        let trimmed = lower
            .replacingOccurrences(of: "views", with: "")
            .replacingOccurrences(of: "view", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last else { return nil }
        let multiplier: Double
        switch last {
        case "k": multiplier = 1_000
        case "m": multiplier = 1_000_000
        case "b": multiplier = 1_000_000_000
        default:
            return Int(String(digits))
        }
        let number = trimmed.dropLast().trimmingCharacters(in: .whitespaces)
        guard let value = Double(number) else { return nil }
        return Int(value * multiplier)
    }

    // MARK: - Channels

    static func channel(from yt: YTChannel) -> Channel {
        Channel(
            id: yt.channelId,
            name: yt.name ?? "",
            handle: yt.handle,
            thumbnailURL: bestThumbnailURL(yt.thumbnails),
            bannerURL: nil,
            subscriberCount: parseAbbreviatedCount(yt.subscriberCount),
            videoCount: Int(yt.videoCount ?? ""),
            isSubscribed: false,
            descriptionText: nil
        )
    }

    /// Parses YouTube's human-readable count strings into an Int. Handles:
    ///   - subscribers: `"1.2M subscribers"`, `"856K subscribers"`, `"12,345 subscribers"`
    ///   - views: `"1.2M views"`, `"856 views"`
    ///   - playlist front-preview annotations: `"5 videos"`, `"1,234 videos"`, `"12 items"`
    ///   - playlist counts in channel listings: `"45 playlists"`
    ///   - bare numbers: `"123"`, `"12,345"`
    ///
    /// The previous implementation only stripped `subscribers`/`views` and broke on the
    /// `"5 videos"` form YouTube uses for the library response's history/likes/watchLater
    /// previews, leaving every count nil → the Library menu rendered "—" instead of a number.
    /// Now we strip the trailing noun (any common count suffix YouTube emits) regardless of
    /// what comes after.
    static func parseAbbreviatedCount(_ raw: String?) -> Int? {
        guard let raw, !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        // Strip every count suffix YouTube is known to emit, plural first to avoid a partial
        // match leaving an "s" dangling (e.g. "subscribers" → strip whole word, not "subscriber"
        // first which would leave "s").
        let suffixes = [
            "subscribers", "subscriber",
            "views", "view",
            "videos", "video",
            "playlists", "playlist",
            "items", "item",
            "channels", "channel"
        ]
        var stripped = lower
        for suffix in suffixes {
            stripped = stripped.replacingOccurrences(of: suffix, with: "")
        }
        stripped = stripped.trimmingCharacters(in: .whitespaces)

        // Some locales emit non-breaking spaces in counts ("1 234"); normalise everything
        // whitespace-like to plain space, then drop spaces entirely after we've handled the
        // suffix.
        stripped = stripped.replacingOccurrences(of: "\u{00A0}", with: " ")

        guard let last = stripped.last else { return nil }
        let multiplier: Double
        switch last {
        case "k": multiplier = 1_000
        case "m": multiplier = 1_000_000
        case "b": multiplier = 1_000_000_000
        default:
            // Plain digit string with separators — strip commas, dots-as-thousands, and any
            // remaining whitespace, then convert.
            let digits = stripped
                .replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: " ", with: "")
            return Int(digits)
        }
        let number = stripped.dropLast().trimmingCharacters(in: .whitespaces)
        guard let value = Double(number) else { return nil }
        return Int(value * multiplier)
    }

    static func channel(from yt: YTLittleChannelInfos) -> Channel {
        Channel(
            id: yt.channelId,
            name: yt.name ?? "",
            handle: nil,
            thumbnailURL: bestThumbnailURL(yt.thumbnails),
            bannerURL: nil,
            subscriberCount: nil,
            videoCount: nil,
            isSubscribed: false,
            descriptionText: nil
        )
    }

    // MARK: - Playlists

    static func playlist(from yt: YTPlaylist) -> Playlist {
        Playlist(
            id: yt.playlistId,
            title: yt.title ?? "",
            channelID: yt.channel?.channelId,
            channelName: yt.channel?.name,
            thumbnailURL: bestThumbnailURL(yt.thumbnails),
            videoCount: Int(yt.videoCount ?? ""),
            descriptionText: nil,
            isOwnedByUser: false
        )
    }

    // MARK: - Comments

    static func comment(from yt: YTComment, isAuthoredByUser: Bool = false) -> Comment {
        let likeCount = Int(yt.likesCount?.filter(\.isNumber) ?? "") ?? 0
        return Comment(
            id: yt.commentIdentifier,
            authorName: yt.sender?.name ?? "",
            authorChannelID: yt.sender?.channelId,
            authorThumbnailURL: bestThumbnailURL(yt.sender?.thumbnails ?? []),
            bodyText: yt.text,
            likeCount: likeCount,
            isLikedByUser: yt.likeState == .liked,
            isDislikedByUser: yt.likeState == .disliked,
            isAuthoredByUser: isAuthoredByUser,
            publishedRelative: yt.timePosted ?? "",
            replyCount: Int(yt.totalRepliesNumber?.filter(\.isNumber) ?? "") ?? yt.replies.count,
            replyContinuationToken: nil
        )
    }

    // MARK: - Formats

    static func format(from yt: any DownloadFormat) -> VideoFormat {
        let mime = yt.mimeType ?? ""
        if let video = yt as? VideoDownloadFormat {
            return VideoFormat(
                id: "\(video.height ?? 0)x\(video.width ?? 0)-\(video.averageBitrate ?? 0)",
                url: video.url,
                mimeType: mime,
                height: video.height,
                width: video.width,
                bitrate: video.averageBitrate,
                audioSampleRate: nil,
                isVideoOnly: true,
                isAudioOnly: false,
                containsBothTracks: false
            )
        }
        if let audio = yt as? AudioOnlyFormat {
            return VideoFormat(
                id: "audio-\(audio.averageBitrate ?? 0)",
                url: audio.url,
                mimeType: mime,
                height: nil,
                width: nil,
                bitrate: audio.averageBitrate,
                audioSampleRate: audio.audioSampleRate,
                isVideoOnly: false,
                isAudioOnly: true,
                containsBothTracks: false
            )
        }
        return VideoFormat(
            id: UUID().uuidString,
            url: yt.url,
            mimeType: mime,
            height: nil,
            width: nil,
            bitrate: yt.averageBitrate,
            audioSampleRate: nil,
            isVideoOnly: false,
            isAudioOnly: false,
            containsBothTracks: true
        )
    }
}
