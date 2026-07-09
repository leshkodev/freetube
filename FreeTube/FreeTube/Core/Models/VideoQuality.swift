import Foundation

enum VideoQuality: String, CaseIterable, Identifiable, Sendable {
    case auto
    case p144 = "144p"
    case p240 = "240p"
    case p360 = "360p"
    case p480 = "480p"
    case p720 = "720p"
    case p1080 = "1080p"
    case p1440 = "1440p"
    case p2160 = "2160p"
    case audioOnly

    var id: String { rawValue }

    var heightCap: Int? {
        switch self {
        case .auto: return 1080
        case .p144: return 144
        case .p240: return 240
        case .p360: return 360
        case .p480: return 480
        case .p720: return 720
        case .p1080: return 1080
        case .p1440: return 1440
        case .p2160: return 2160
        case .audioOnly: return 0
        }
    }
}
