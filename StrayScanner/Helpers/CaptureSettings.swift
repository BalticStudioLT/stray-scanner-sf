//
//  CaptureSettings.swift
//  StrayScanner
//
//  Capture quality choices shared by the record screen and the Settings tab (stray-scanner-sf fork):
//  how hard rgb.mp4 is compressed, and optional sharp 12 MP photos taken while scanning.
//

import Foundation
import ARKit

/// How hard rgb.mp4 is compressed. More bits keep fine texture (walls, fabric) and avoid blocky frames,
/// which the splat training would otherwise copy; the files get bigger.
enum VideoQuality: Int, CaseIterable {
    case standard = 0
    case high = 1
    case maximum = 2

    static let userDefaultsKey = "VideoQuality"

    static func load() -> VideoQuality {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: userDefaultsKey) != nil else { return .high }
        return VideoQuality(rawValue: defaults.integer(forKey: userDefaultsKey)) ?? .high
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: VideoQuality.userDefaultsKey)
    }

    var title: String {
        switch self {
        case .standard: return "Standard"
        case .high: return "High"
        case .maximum: return "Maximum"
        }
    }

    /// Name written to capture_settings.json.
    var name: String {
        switch self {
        case .standard: return "standard"
        case .high: return "high"
        case .maximum: return "maximum"
        }
    }

    var detail: String {
        switch self {
        case .standard: return "smallest files"
        case .high: return "about 3× the size, cleaner detail"
        case .maximum: return "about 5× the size"
        }
    }

    /// Target HEVC bit rate; nil lets iOS choose (the old behaviour, smallest files).
    /// Reference is 30 saved frames per second. Fewer saved frames differ more from each other,
    /// so the rate falls more slowly than the frame count.
    func bitRate(width: Int, height: Int, savedFramesPerSecond: Double) -> Int? {
        let bitsPerPixel: Double
        switch self {
        case .standard: return nil
        case .high: bitsPerPixel = 0.35
        case .maximum: bitsPerPixel = 0.6
        }
        let fps = max(savedFramesPerSecond, 1)
        let rate = Double(width * height) * bitsPerPixel * 30 * pow(fps / 30, 0.65)
        return Int(min(max(rate, 4_000_000), 120_000_000))
    }
}

/// Sharp full-resolution photos (ARKit high-resolution frames, about 12 MP) taken while the video runs.
/// Each one is saved with its own camera pose and intrinsics (stills/ + stills.csv), for SplatForge to train on.
enum StillSetting: Int, CaseIterable {
    case off = 0
    case everySecond = 1
    case twiceASecond = 2

    static let userDefaultsKey = "StillPhotos"

    static func load() -> StillSetting {
        return StillSetting(rawValue: UserDefaults.standard.integer(forKey: userDefaultsKey)) ?? .off
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: StillSetting.userDefaultsKey)
    }

    /// Shortest time between two photos; nil = no photos.
    var interval: TimeInterval? {
        switch self {
        case .off: return nil
        case .everySecond: return 1.0
        case .twiceASecond: return 0.5
        }
    }

    var title: String {
        switch self {
        case .off: return "Off"
        case .everySecond: return "1 per second"
        case .twiceASecond: return "2 per second"
        }
    }

    /// The phone offers a video format that allows high-resolution frames.
    static var isSupported: Bool {
        return ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing != nil
    }
}
