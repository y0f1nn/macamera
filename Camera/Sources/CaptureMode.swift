import Foundation

enum CaptureMode: String, CaseIterable, Identifiable {
    case timelapse  = "Timelapse"
    case slowMotion = "Slo-Mo"
    case video      = "Video"
    case photo      = "Photo"
    case hsdr       = "HSDR"
    case qrCode     = "QR"

    var id: String { rawValue }

    var isVideoMode: Bool {
        switch self {
        case .video, .timelapse, .slowMotion: return true
        case .photo, .hsdr, .qrCode: return false
        }
    }

    var systemImage: String {
        switch self {
        case .photo:      return "camera"
        case .video:      return "video"
        case .timelapse:  return "timelapse"
        case .slowMotion: return "slowmo"
        case .hsdr:       return "camera.filters"
        case .qrCode:     return "qrcode.viewfinder"
        }
    }
}
