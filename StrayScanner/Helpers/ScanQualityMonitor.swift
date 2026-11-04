//
//  ScanQualityMonitor.swift
//  StrayScanner
//
//  Live scan quality for the record screen and frame_quality.csv (stray-scanner-sf fork):
//  camera speed, estimated motion blur, distance to the scene, LiDAR coverage,
//  which directions have been filmed, and plain-language advice.
//

import Foundation
import ARKit
import simd

/// Per-frame values written to frame_quality.csv.
struct FrameQuality {
    let trackingState: String
    let trackingReason: String
    let linearSpeed: Float        // m/s
    let angularSpeedDeg: Float    // deg/s
    let blurPixels: Float         // estimated motion blur in pixels of the full-size image
    let medianDepth: Float        // m, 0 if unknown
    let depthConfidentFraction: Float // share of LiDAR pixels with high confidence
    var torchLevel: Float = 0     // phone torch brightness 0…1
}

struct ScanAdvice: Equatable {
    enum Level: Int { case info = 0, good = 1, warning = 2, bad = 3 }
    let level: Level
    let text: String
    let symbolName: String
}

final class ScanQualityMonitor {
    /// Blur (pixels) above which frames start to look soft in a splat.
    static let blurGoodLimit: Float = 1.5
    static let blurBadLimit: Float = 3.0
    static let headingSectors = 12

    private(set) var linearSpeed: Float = 0
    private(set) var angularSpeed: Float = 0 // rad/s
    private(set) var blurPixels: Float = 0
    private(set) var medianDepth: Float = 0
    private(set) var confidentFraction: Float = 0
    private(set) var distanceTravelled: Float = 0
    private(set) var exposureDuration: Double = 0
    private(set) var focalLength: Float = 1400
    private(set) var trackingState: ARCamera.TrackingState = .notAvailable
    private(set) var headingSector: Int = 0
    private(set) var headingCoverage = [Double](repeating: 0, count: ScanQualityMonitor.headingSectors)
    private(set) var lookDownTime: Double = 0
    private(set) var lookUpTime: Double = 0

    private var lastPosition: SIMD3<Float>?
    private var lastRotation: simd_quatf?
    private var lastTimestamp: TimeInterval?
    private var frameIndex: Int = 0
    private let smoothing: Float = 0.25

    func resetForRecording() {
        distanceTravelled = 0
        headingCoverage = [Double](repeating: 0, count: ScanQualityMonitor.headingSectors)
        lookDownTime = 0
        lookUpTime = 0
    }

    func update(frame: ARFrame, recording: Bool) {
        frameIndex += 1
        let camera = frame.camera
        trackingState = camera.trackingState
        exposureDuration = camera.exposureDuration
        focalLength = camera.intrinsics.columns.0.x

        let t = camera.transform
        let position = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let rotation = simd_quatf(t)
        if let lastPosition = lastPosition, let lastRotation = lastRotation, let lastTimestamp = lastTimestamp {
            let dt = Float(frame.timestamp - lastTimestamp)
            if dt > 0.001 && dt < 0.5 {
                let step = simd_distance(position, lastPosition)
                var angle = (rotation * lastRotation.inverse).angle
                if angle > Float.pi { angle = 2 * Float.pi - angle }
                linearSpeed += smoothing * (step / dt - linearSpeed)
                angularSpeed += smoothing * (abs(angle) / dt - angularSpeed)
                if recording, case .normal = trackingState {
                    distanceTravelled += step
                    accumulateCoverage(transform: t, dt: Double(dt))
                }
            }
        }
        lastPosition = position
        lastRotation = rotation
        lastTimestamp = frame.timestamp

        let forward = -simd_normalize(SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z))
        let yaw = atan2(forward.x, -forward.z) // 0 = initial direction, positive = turned right
        let sectorFloat = (yaw + Float.pi) / (2 * Float.pi) * Float(ScanQualityMonitor.headingSectors)
        headingSector = min(max(Int(sectorFloat), 0), ScanQualityMonitor.headingSectors - 1)

        if frameIndex % 4 == 0 {
            sampleDepth(frame: frame)
        }
        let depthForBlur = medianDepth > 0.2 ? medianDepth : 1.5
        blurPixels = (angularSpeed * focalLength + linearSpeed * focalLength / depthForBlur) * Float(exposureDuration)
    }

    private func accumulateCoverage(transform t: simd_float4x4, dt: Double) {
        let forward = -simd_normalize(SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z))
        let pitch = asin(max(-1, min(1, forward.y)))
        if pitch < -0.5 { lookDownTime += dt }
        if pitch > 0.5 { lookUpTime += dt }
        if abs(pitch) < 1.0 {
            headingCoverage[headingSector] += dt
        }
    }

    private func sampleDepth(frame: ARFrame) {
        guard let sceneDepth = frame.sceneDepth, let confidence = sceneDepth.confidenceMap else { return }
        let depthMap = sceneDepth.depthMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        CVPixelBufferLockBaseAddress(confidence, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(confidence, .readOnly)
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
        }
        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap),
              let confidenceBase = CVPixelBufferGetBaseAddress(confidence) else { return }
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let depthRow = CVPixelBufferGetBytesPerRow(depthMap)
        let confidenceRow = CVPixelBufferGetBytesPerRow(confidence)
        let confidenceBytes = confidenceBase.assumingMemoryBound(to: UInt8.self)

        var values: [Float] = []
        values.reserveCapacity(800)
        var confident = 0
        var total = 0
        var v = 4
        while v < height {
            let row = depthBase.advanced(by: v * depthRow).assumingMemoryBound(to: Float32.self)
            var u = 4
            while u < width {
                total += 1
                if confidenceBytes[v * confidenceRow + u] >= 2 { confident += 1 }
                // Median over the central half of the image: what the user is pointing at.
                if u > width / 4 && u < width * 3 / 4 && v > height / 4 && v < height * 3 / 4 {
                    let d = row[u]
                    if d > 0.05 && d < 10 { values.append(d) }
                }
                u += 8
            }
            v += 8
        }
        confidentFraction = total > 0 ? Float(confident) / Float(total) : 0
        if values.isEmpty {
            medianDepth = 0
        } else {
            values.sort()
            medianDepth = values[values.count / 2]
        }
    }

    /// Fastest rotation (deg/s) that keeps motion blur under the good limit at the current shutter.
    var maxAngularSpeedForSharpFrames: Float {
        guard exposureDuration > 0 else { return 0 }
        let radPerSecond = ScanQualityMonitor.blurGoodLimit / (focalLength * Float(exposureDuration))
        return radPerSecond * 180 / Float.pi
    }

    var angularSpeedDegrees: Float { return angularSpeed * 180 / Float.pi }

    func currentQuality() -> FrameQuality {
        return FrameQuality(trackingState: ScanQualityMonitor.stateName(trackingState),
                            trackingReason: ScanQualityMonitor.reasonName(trackingState),
                            linearSpeed: linearSpeed,
                            angularSpeedDeg: angularSpeedDegrees,
                            blurPixels: blurPixels,
                            medianDepth: medianDepth,
                            depthConfidentFraction: confidentFraction)
    }

    /// Sectors (of 12) filmed for at least half a second.
    var coveredSectors: [Bool] {
        return headingCoverage.map { $0 >= 0.5 }
    }

    // MARK: - Advice

    func advice(recording: Bool, recordingSeconds: Double, underexposed: Bool,
                thermalState: ProcessInfo.ThermalState, freeMinutes: Double?) -> ScanAdvice {
        switch trackingState {
        case .notAvailable:
            return ScanAdvice(level: .bad, text: "Tracking lost — move back to a scanned area", symbolName: "exclamationmark.triangle.fill")
        case .limited(let reason):
            switch reason {
            case .excessiveMotion:
                return ScanAdvice(level: .bad, text: "Too fast — slow down", symbolName: "tortoise.fill")
            case .insufficientFeatures:
                return ScanAdvice(level: .bad, text: "Not enough detail — aim at textured surfaces", symbolName: "eye.trianglebadge.exclamationmark")
            case .initializing:
                return ScanAdvice(level: .warning, text: "Starting tracking — move slowly sideways", symbolName: "arrow.left.and.right")
            case .relocalizing:
                return ScanAdvice(level: .warning, text: "Relocalizing — return to where you were", symbolName: "location.fill")
            @unknown default:
                return ScanAdvice(level: .warning, text: "Tracking limited", symbolName: "exclamationmark.triangle")
            }
        case .normal:
            break
        }
        if let minutes = freeMinutes, recording, minutes < 2 {
            return ScanAdvice(level: .bad, text: String(format: "Storage almost full — %.0f min left", minutes), symbolName: "externaldrive.fill.badge.exclamationmark")
        }
        if thermalState == .critical || thermalState == .serious {
            return ScanAdvice(level: .warning, text: "Phone is hot — frames may drop", symbolName: "thermometer.high")
        }
        if blurPixels > ScanQualityMonitor.blurBadLimit {
            return ScanAdvice(level: .bad, text: String(format: "Slow down — blur %.1f px", blurPixels), symbolName: "tortoise.fill")
        }
        if medianDepth > 0 && medianDepth < 0.3 {
            return ScanAdvice(level: .warning, text: "Too close — step back", symbolName: "arrow.down.backward.and.arrow.up.forward")
        }
        if medianDepth > 4.5 {
            return ScanAdvice(level: .warning, text: "Far away — LiDAR reaches ~5 m, move closer", symbolName: "arrow.up.forward.and.arrow.down.backward")
        }
        if underexposed {
            return ScanAdvice(level: .warning, text: "Dark — add light or use 1/120 s", symbolName: "lightbulb.fill")
        }
        if blurPixels > ScanQualityMonitor.blurGoodLimit {
            return ScanAdvice(level: .warning, text: String(format: "A bit slower — blur %.1f px", blurPixels), symbolName: "gauge.with.dots.needle.33percent")
        }
        if recording {
            if let direction = turnSuggestion(), recordingSeconds > 12 {
                return ScanAdvice(level: .info, text: direction, symbolName: "arrow.triangle.turn.up.right.circle.fill")
            }
            if recordingSeconds > 25 && lookDownTime < 2 {
                return ScanAdvice(level: .info, text: "Tilt down to capture the floor", symbolName: "arrow.down.circle.fill")
            }
            if recordingSeconds > 35 && lookUpTime < 2 {
                return ScanAdvice(level: .info, text: "Tilt up to capture the ceiling", symbolName: "arrow.up.circle.fill")
            }
            return ScanAdvice(level: .good, text: "Good pace — keep going", symbolName: "checkmark.circle.fill")
        }
        return ScanAdvice(level: .good, text: "Ready — move slowly and steadily", symbolName: "checkmark.circle.fill")
    }

    /// Suggests turning towards the nearest direction that has not been filmed yet.
    private func turnSuggestion() -> String? {
        let covered = coveredSectors
        guard covered.contains(true), covered.contains(false) else { return nil }
        let n = ScanQualityMonitor.headingSectors
        for offset in 1...(n / 2) {
            let right = (headingSector + offset) % n
            let left = (headingSector - offset + n) % n
            if !covered[right] { return offset <= 1 ? "Keep turning right — new area" : "Turn right to scan the rest" }
            if !covered[left] { return offset <= 1 ? "Keep turning left — new area" : "Turn left to scan the rest" }
        }
        return nil
    }

    // MARK: - Names

    static func stateName(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal: return "normal"
        case .limited: return "limited"
        case .notAvailable: return "not_available"
        }
    }

    static func reasonName(_ state: ARCamera.TrackingState) -> String {
        guard case .limited(let reason) = state else { return "" }
        switch reason {
        case .initializing: return "initializing"
        case .excessiveMotion: return "excessive_motion"
        case .insufficientFeatures: return "insufficient_features"
        case .relocalizing: return "relocalizing"
        @unknown default: return "unknown"
        }
    }
}
