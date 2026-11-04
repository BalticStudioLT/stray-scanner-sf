//
//  WallSweepGuide.swift
//  StrayScanner
//
//  Scan path guide (stray-scanner-sf fork): finds the wall the phone points at (ARKit vertical
//  planes), lays vertical stripes on it every 30/50/80 cm, and ticks a stripe off once it has
//  been swept up and down while facing the wall. Stripes are drawn in the camera, mix,
//  point-cloud and minimap views.
//

import Foundation
import ARKit
import simd

final class WallSweepGuide {
    static let spacings: [Float] = [0.3, 0.5, 0.8]
    static let userDefaultsKey = "WallSweepSpacing"

    /// Stripe spacing in metres, nil = guide off.
    var spacing: Float? {
        didSet {
            if spacing != oldValue { walls.removeAll(); currentWall = nil }
            UserDefaults.standard.set(spacing ?? 0, forKey: WallSweepGuide.userDefaultsKey)
        }
    }

    private struct Stripe {
        var minPitch: Float = 0
        var maxPitch: Float = 0
        var done: Bool { return minPitch < -0.3 && maxPitch > 0.3 }
    }

    private struct Wall {
        let id: UUID
        var origin: SIMD3<Float>   // fixed reference point on the wall
        var normal: SIMD3<Float>   // points into the room
        var along: SIMD3<Float>    // horizontal direction along the wall
        var uMin: Float = 0
        var uMax: Float = 0
        var yMin: Float = 0
        var yMax: Float = 0
        var stripes: [Int: Stripe] = [:]
    }

    private var walls: [UUID: Wall] = [:]
    private var currentWall: UUID?
    private(set) var currentStripe: Int?
    private var frameCounter = 0
    private var cameraRight = SIMD3<Float>(1, 0, 0)

    init() {
        let saved = UserDefaults.standard.float(forKey: WallSweepGuide.userDefaultsKey)
        spacing = saved > 0 ? saved : nil
    }

    var isActive: Bool { return spacing != nil }

    func update(frame: ARFrame) {
        guard let spacing = spacing else { return }
        frameCounter += 1
        let t = frame.camera.transform
        let position = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let forward = -simd_normalize(SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z))
        cameraRight = simd_normalize(SIMD3<Float>(t.columns.0.x, t.columns.0.y, t.columns.0.z))

        if frameCounter % 15 == 0 || currentWall == nil {
            selectWall(frame: frame, position: position, forward: forward)
        }
        guard let id = currentWall, var wall = walls[id] else {
            currentStripe = nil
            return
        }

        // Which stripe is the phone in front of, and is it facing the wall?
        let u = simd_dot(position - wall.origin, wall.along)
        let k = Int((u / spacing).rounded())
        currentStripe = k
        let facing = simd_dot(forward, -wall.normal) > 0.5
        let offset = abs(u - Float(k) * spacing)
        if facing && offset < spacing * 0.5 {
            let pitch = asin(max(-1, min(1, forward.y)))
            var stripe = wall.stripes[k] ?? Stripe()
            stripe.minPitch = min(stripe.minPitch, pitch)
            stripe.maxPitch = max(stripe.maxPitch, pitch)
            wall.stripes[k] = stripe
            walls[id] = wall
        }
    }

    private func selectWall(frame: ARFrame, position: SIMD3<Float>, forward: SIMD3<Float>) {
        var best: (anchor: ARPlaneAnchor, distance: Float)?
        for anchor in frame.anchors {
            guard let plane = anchor as? ARPlaneAnchor, plane.alignment == .vertical else { continue }
            let n = SIMD3<Float>(plane.transform.columns.1.x, plane.transform.columns.1.y, plane.transform.columns.1.z)
            let center4 = plane.transform * SIMD4<Float>(plane.center.x, plane.center.y, plane.center.z, 1)
            let center = SIMD3<Float>(center4.x, center4.y, center4.z)
            let denominator = simd_dot(forward, n)
            guard abs(denominator) > 0.3 else { continue }
            let distance = simd_dot(center - position, n) / denominator
            guard distance > 0.15 && distance < 6 else { continue }
            let hit = position + forward * distance
            let bounds = extent(of: plane, origin: center, normal: n)
            let along = simd_dot(hit - center, bounds.along)
            guard along > bounds.uMin - 0.4 && along < bounds.uMax + 0.4 else { continue }
            if best == nil || distance < best!.distance {
                best = (plane, distance)
            }
        }
        guard let plane = best?.anchor else { return }
        var n = SIMD3<Float>(plane.transform.columns.1.x, plane.transform.columns.1.y, plane.transform.columns.1.z)
        let center4 = plane.transform * SIMD4<Float>(plane.center.x, plane.center.y, plane.center.z, 1)
        let center = SIMD3<Float>(center4.x, center4.y, center4.z)
        if simd_dot(position - center, n) < 0 { n = -n }

        var wall = walls[plane.identifier] ?? Wall(id: plane.identifier, origin: center, normal: n,
                                                   along: simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), n)))
        wall.normal = n
        let bounds = extent(of: plane, origin: wall.origin, normal: n)
        wall.along = bounds.along
        wall.uMin = bounds.uMin
        wall.uMax = bounds.uMax
        wall.yMin = bounds.yMin
        wall.yMax = bounds.yMax
        walls[plane.identifier] = wall
        currentWall = plane.identifier
    }

    private func extent(of plane: ARPlaneAnchor, origin: SIMD3<Float>, normal: SIMD3<Float>)
        -> (along: SIMD3<Float>, uMin: Float, uMax: Float, yMin: Float, yMax: Float) {
        var horizontal = simd_cross(SIMD3<Float>(0, 1, 0), normal)
        horizontal = simd_length(horizontal) > 0.01 ? simd_normalize(horizontal) : SIMD3<Float>(1, 0, 0)
        var uMin = Float.greatestFiniteMagnitude, uMax = -Float.greatestFiniteMagnitude
        var yMin = Float.greatestFiniteMagnitude, yMax = -Float.greatestFiniteMagnitude
        for vertex in plane.geometry.vertices {
            let w4 = plane.transform * SIMD4<Float>(vertex.x, vertex.y, vertex.z, 1)
            let w = SIMD3<Float>(w4.x, w4.y, w4.z)
            let u = simd_dot(w - origin, horizontal)
            uMin = min(uMin, u); uMax = max(uMax, u)
            yMin = min(yMin, w.y); yMax = max(yMax, w.y)
        }
        if uMin > uMax { uMin = -0.5; uMax = 0.5; yMin = origin.y - 0.5; yMax = origin.y + 0.5 }
        return (horizontal, uMin, uMax, yMin, yMax)
    }

    // MARK: - Drawing

    /// Points that draw the stripes of the current wall (green = done, white = here, orange = to do).
    func vertices() -> [PointCloudVertex] {
        guard let spacing = spacing, let id = currentWall, let wall = walls[id] else { return [] }
        var result: [PointCloudVertex] = []
        let kMin = Int((wall.uMin / spacing).rounded(.up))
        let kMax = Int((wall.uMax / spacing).rounded(.down))
        guard kMin <= kMax, kMax - kMin < 60 else { return [] }
        let top = min(wall.yMax, wall.yMin + 3.0)
        for k in kMin...kMax {
            let done = wall.stripes[k]?.done ?? false
            let color: SIMD4<Float>
            if done {
                color = SIMD4<Float>(0.25, 0.9, 0.4, 1)
            } else if k == currentStripe {
                color = SIMD4<Float>(1, 1, 1, 1)
            } else {
                color = SIMD4<Float>(1.0, 0.55, 0.1, 1)
            }
            let base = wall.origin + wall.along * (Float(k) * spacing) + wall.normal * 0.02
            var y = wall.yMin
            while y <= top {
                result.append(PointCloudVertex(position: SIMD4<Float>(base.x, y, base.z, 0.03), color: color))
                y += 0.08
            }
        }
        return result
    }

    // MARK: - Advice

    func advice() -> ScanAdvice? {
        guard let spacing = spacing else { return nil }
        let cm = Int((spacing * 100).rounded())
        guard let id = currentWall, let wall = walls[id], let k = currentStripe else {
            return ScanAdvice(level: .info, text: "Path guide: point at a wall and move a little", symbolName: "rectangle.portrait.and.arrow.right")
        }
        let kMin = Int((wall.uMin / spacing).rounded(.up))
        let kMax = Int((wall.uMax / spacing).rounded(.down))
        guard kMin <= kMax else { return nil }
        let total = kMax - kMin + 1
        let doneCount = (kMin...kMax).filter { wall.stripes[$0]?.done ?? false }.count
        if doneCount == total {
            return ScanAdvice(level: .good, text: "Wall done (\(total)/\(total)) — turn to the next wall", symbolName: "checkmark.seal.fill")
        }
        if !(wall.stripes[k]?.done ?? false) && k >= kMin && k <= kMax {
            return ScanAdvice(level: .info, text: "Sweep floor ↔ ceiling here · \(doneCount)/\(total) stripes", symbolName: "arrow.up.and.down")
        }
        // Next stripe to do: nearest unfinished one, told as left/right from the user's point of view.
        var target: Int?
        for offset in 1...max(total, 1) {
            if k + offset <= kMax && !(wall.stripes[k + offset]?.done ?? false) { target = k + offset; break }
            if k - offset >= kMin && !(wall.stripes[k - offset]?.done ?? false) { target = k - offset; break }
        }
        guard let next = target else { return nil }
        let stepDirection = wall.along * Float(next - k)
        let toRight = simd_dot(stepDirection, cameraRight) > 0
        let meters = Float(abs(next - k)) * spacing
        let distance = meters < 1 ? "\(Int((meters * 100).rounded())) cm" : String(format: "%.1f m", meters)
        return ScanAdvice(level: .info,
                          text: "Step \(toRight ? "right" : "left") \(distance) to the next stripe · \(doneCount)/\(total) · \(cm) cm grid",
                          symbolName: toRight ? "arrow.right.circle.fill" : "arrow.left.circle.fill")
    }
}
