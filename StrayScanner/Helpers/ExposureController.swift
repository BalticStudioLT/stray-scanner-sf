//
//  ExposureController.swift
//  StrayScanner
//
//  Short-shutter capture for sharper frames (stray-scanner-sf fork).
//
//  Uses ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera (iOS 16+)
//  to fix the exposure duration while ARKit keeps running tracking and LiDAR depth.
//  ISO is adjusted automatically ("shutter priority"): a small loop reads the device's
//  metered exposureTargetOffset and nudges ISO within the active format's min/max.
//

import Foundation
import ARKit
import AVFoundation

let ShutterUserDefaultsKey: String = "ShutterSetting"

enum ShutterSetting: Int, CaseIterable {
    case auto = 0
    case s120 = 1
    case s250 = 2
    case s500 = 3

    static let defaultSetting: ShutterSetting = .s250

    /// Denominator of the requested shutter time, nil for automatic exposure.
    var denominator: Int32? {
        switch self {
        case .auto: return nil
        case .s120: return 120
        case .s250: return 250
        case .s500: return 500
        }
    }

    /// Requested exposure duration in seconds, nil for automatic exposure.
    var requestedDuration: Double? {
        return denominator.map { 1.0 / Double($0) }
    }

    var label: String {
        if let d = denominator { return "1/\(d)" }
        return "Auto"
    }

    static func load() -> ShutterSetting {
        guard UserDefaults.standard.object(forKey: ShutterUserDefaultsKey) != nil else {
            return defaultSetting
        }
        return ShutterSetting(rawValue: UserDefaults.standard.integer(forKey: ShutterUserDefaultsKey)) ?? defaultSetting
    }

    func save() {
        UserDefaults.standard.set(self.rawValue, forKey: ShutterUserDefaultsKey)
    }
}

/// Values read from the capture device at the moment a frame arrives.
struct ExposureSnapshot {
    let iso: Float
    let whiteBalanceGains: AVCaptureDevice.WhiteBalanceGains
}

/// Controls exposure, white balance and focus of ARKit's primary camera.
/// All methods are meant to be called on the main thread (ARSession delegate callbacks
/// arrive there in this app as well).
final class ExposureController {
    let device: AVCaptureDevice?
    private(set) var setting: ShutterSetting = .auto
    private(set) var isCaptureLocked: Bool = false
    private var isoTimer: Timer?

    /// Smallest metered error (in EV) the ISO loop reacts to, and the fraction of it corrected per step.
    private let isoDeadband: Float = 0.15
    private let isoGain: Float = 0.5

    init() {
        self.device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera
        if device == nil {
            print("ExposureController: no configurable capture device; exposure control unavailable.")
        }
    }

    var isAvailable: Bool { return device != nil }

    deinit {
        isoTimer?.invalidate()
    }

    // MARK: - Shutter

    /// Applies a shutter setting. Call again after (re)running the ARSession, since
    /// ARKit may reconfigure the device when the session starts.
    func apply(_ newSetting: ShutterSetting) {
        setting = newSetting
        guard let device = device else { return }
        isoTimer?.invalidate()
        isoTimer = nil

        guard let denominator = newSetting.denominator else {
            withLockedDevice(device) {
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
            }
            return
        }

        let duration = clampedDuration(CMTime(value: 1, timescale: denominator), device: device)
        // Keep the overall exposure (ISO x time) of what the camera currently meters.
        let currentSeconds = CMTimeGetSeconds(device.exposureDuration)
        let newSeconds = CMTimeGetSeconds(duration)
        var targetISO = device.iso
        if currentSeconds > 0 && newSeconds > 0 {
            targetISO = device.iso * Float(currentSeconds / newSeconds)
        }
        setCustomExposure(device: device, duration: duration, iso: targetISO)

        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.adjustISO()
        }
        RunLoop.main.add(timer, forMode: .common)
        isoTimer = timer
    }

    /// Shutter-priority loop: keep the requested duration, let ISO follow the meter.
    private func adjustISO() {
        guard let device = device, let denominator = setting.denominator else { return }
        let duration = clampedDuration(CMTime(value: 1, timescale: denominator), device: device)

        // ARKit can put the device back into auto exposure (e.g. after a session reset).
        if device.exposureMode != .custom {
            setCustomExposure(device: device, duration: duration, iso: device.iso)
            return
        }

        let offset = device.exposureTargetOffset // EV; positive = brighter than target
        guard offset.isFinite, abs(offset) > isoDeadband else { return }
        let newISO = device.iso * powf(2.0, -offset * isoGain)
        setCustomExposure(device: device, duration: duration, iso: newISO)
    }

    private func setCustomExposure(device: AVCaptureDevice, duration: CMTime, iso: Float) {
        let format = device.activeFormat
        let clampedISO = min(max(iso, format.minISO), format.maxISO)
        withLockedDevice(device) {
            if device.isExposureModeSupported(.custom) {
                device.setExposureModeCustom(duration: duration, iso: clampedISO, completionHandler: nil)
            }
        }
    }

    private func clampedDuration(_ duration: CMTime, device: AVCaptureDevice) -> CMTime {
        let format = device.activeFormat
        if CMTimeCompare(duration, format.minExposureDuration) < 0 { return format.minExposureDuration }
        if CMTimeCompare(duration, format.maxExposureDuration) > 0 { return format.maxExposureDuration }
        return duration
    }

    // MARK: - White balance / focus lock while recording

    func lockForRecording() {
        guard let device = device else { return }
        withLockedDevice(device) {
            if device.isWhiteBalanceModeSupported(.locked) {
                device.whiteBalanceMode = .locked
            }
            if device.isFocusModeSupported(.locked) {
                device.focusMode = .locked
            }
        }
        isCaptureLocked = true
    }

    func unlockAfterRecording() {
        guard let device = device else { return }
        withLockedDevice(device) {
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
        }
        isCaptureLocked = false
    }

    /// True when ISO is at its maximum and the picture is still darker than the meter wants.
    var isUnderexposed: Bool {
        guard let device = device, setting != .auto else { return false }
        return device.iso >= device.activeFormat.maxISO * 0.95 && device.exposureTargetOffset < -1.0
    }

    // MARK: - Logging

    func snapshot() -> ExposureSnapshot? {
        guard let device = device else { return nil }
        return ExposureSnapshot(iso: device.iso, whiteBalanceGains: device.deviceWhiteBalanceGains)
    }

    /// Capture settings written to capture_settings.json when a recording starts.
    func captureSettings() -> [String: Any] {
        var info: [String: Any] = [
            "shutter_setting": setting.label,
            "requested_exposure_duration_s": setting.requestedDuration.map { $0 as Any } ?? NSNull(),
            "iso_mode": setting == .auto ? "auto" : "auto_shutter_priority",
            "exposure_control_available": device != nil,
            "white_balance_locked": false,
            "focus_locked": false,
        ]
        if let device = device {
            info["white_balance_locked"] = device.whiteBalanceMode == .locked
            info["focus_locked"] = device.focusMode == .locked
            info["lens_position_at_start"] = device.lensPosition
            info["iso_at_start"] = device.iso
            info["exposure_duration_s_at_start"] = CMTimeGetSeconds(device.exposureDuration)
            let gains = device.deviceWhiteBalanceGains
            info["white_balance_gains_at_start"] = [gains.redGain, gains.greenGain, gains.blueGain]
            info["iso_min"] = device.activeFormat.minISO
            info["iso_max"] = device.activeFormat.maxISO
            info["exposure_duration_min_s"] = CMTimeGetSeconds(device.activeFormat.minExposureDuration)
            info["exposure_duration_max_s"] = CMTimeGetSeconds(device.activeFormat.maxExposureDuration)
        }
        return info
    }

    // MARK: - Helpers

    private func withLockedDevice(_ device: AVCaptureDevice, _ body: () -> Void) {
        do {
            try device.lockForConfiguration()
            body()
            device.unlockForConfiguration()
        } catch {
            print("ExposureController: could not lock capture device: \(error.localizedDescription)")
        }
    }
}
