//
//  PointCloudAccumulator.swift
//  StrayScanner
//
//  Live coloured point cloud for the preview (stray-scanner-sf fork).
//  Samples the LiDAR depth map, keeps one point per 2 cm voxel in a GPU ring buffer,
//  and estimates the scanned surface area from 10 cm voxels. Display only: nothing
//  here is written to the dataset.
//

import Foundation
import ARKit
import Metal
import simd

/// Layout must match SFPointVertex in Shaders.metal.
struct PointCloudVertex {
    var position: SIMD4<Float> // xyz world position, w = point size in metres
    var color: SIMD4<Float>
}

final class PointCloudAccumulator {
    let capacity: Int
    let buffer: MTLBuffer
    private(set) var count: Int = 0
    /// Points ever appended (keeps counting past the ring buffer's capacity); used by the PC live link.
    private(set) var totalAppended: Int = 0
    private var writeIndex: Int = 0
    private var fineVoxels = Set<Int64>()

    /// Coverage: one point per 10 cm voxel, coloured by how many different directions it was seen from.
    let coverageCapacity: Int = 400_000
    let coverageBuffer: MTLBuffer
    private(set) var coverageCount: Int = 0
    private var coverageSlots: [Int64: Int32] = [:]
    private var coverageMasks: [UInt16] = []
    private(set) var wellCoveredVoxels: Int = 0
    /// Every Nth sample is skipped when the phone is hot.
    var lowPower: Bool = false
    private var lastSampledTransform: simd_float4x4?
    private var lastTrajectoryPoint: SIMD3<Float>?
    private var frameCounter: Int = 0

    private let pointSize: Float = 0.009
    private let fineVoxelSize: Float = 0.02
    private let areaVoxelSize: Float = 0.10
    private let pixelStride: Int = 4 // 64×48 samples per depth map; 3 doubled CPU for little visible gain
    private let maxDepth: Float = 5.0

    init?(device: MTLDevice, capacity: Int = 1_200_000) {
        let length = capacity * MemoryLayout<PointCloudVertex>.stride
        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared),
              let coverageBuffer = device.makeBuffer(length: 400_000 * MemoryLayout<PointCloudVertex>.stride, options: .storageModeShared) else { return nil }
        self.capacity = capacity
        self.buffer = buffer
        self.coverageBuffer = coverageBuffer
        coverageMasks.reserveCapacity(coverageCapacity)
    }

    /// Approximate scanned surface in square metres.
    var surfaceArea: Float {
        return Float(coverageCount) * areaVoxelSize * areaVoxelSize
    }

    /// Share of the scanned surface seen from at least 3 different directions.
    var wellCoveredFraction: Float {
        return coverageCount > 0 ? Float(wellCoveredVoxels) / Float(coverageCount) : 0
    }

    func reset() {
        count = 0
        writeIndex = 0
        totalAppended = 0
        fineVoxels.removeAll(keepingCapacity: true)
        coverageSlots.removeAll(keepingCapacity: true)
        coverageMasks.removeAll(keepingCapacity: true)
        coverageCount = 0
        wellCoveredVoxels = 0
        lastSampledTransform = nil
        lastTrajectoryPoint = nil
    }

    /// Adds points from the frame when the camera moved enough since the last sample.
    func add(frame: ARFrame) {
        frameCounter += 1
        guard case .normal = frame.camera.trackingState else { return }
        let transform = frame.camera.transform
        addTrajectoryPoint(transform: transform)

        if frameCounter % (lowPower ? 8 : 3) != 0 { return }
        if let last = lastSampledTransform, !movedEnough(from: last, to: transform) { return }
        guard let sceneDepth = frame.sceneDepth, let confidenceMap = sceneDepth.confidenceMap else { return }
        lastSampledTransform = transform
        sample(depthMap: sceneDepth.depthMap, confidenceMap: confidenceMap, frame: frame)
    }

    private func movedEnough(from a: simd_float4x4, to b: simd_float4x4) -> Bool {
        let pa = SIMD3<Float>(a.columns.3.x, a.columns.3.y, a.columns.3.z)
        let pb = SIMD3<Float>(b.columns.3.x, b.columns.3.y, b.columns.3.z)
        if simd_distance(pa, pb) > 0.03 { return true }
        let fa = SIMD3<Float>(a.columns.2.x, a.columns.2.y, a.columns.2.z)
        let fb = SIMD3<Float>(b.columns.2.x, b.columns.2.y, b.columns.2.z)
        return simd_dot(fa, fb) < cos(Float(3.0 * Double.pi / 180.0))
    }

    private func addTrajectoryPoint(transform: simd_float4x4) {
        let p = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        if let last = lastTrajectoryPoint, simd_distance(last, p) < 0.05 { return }
        lastTrajectoryPoint = p
        append(PointCloudVertex(position: SIMD4<Float>(p.x, p.y, p.z, 0.02),
                                color: SIMD4<Float>(0.25, 0.9, 1.0, 1.0)))
    }

    private func append(_ vertex: PointCloudVertex) {
        let pointer = buffer.contents().bindMemory(to: PointCloudVertex.self, capacity: capacity)
        pointer[writeIndex] = vertex
        writeIndex = (writeIndex + 1) % capacity
        count = min(count + 1, capacity)
        totalAppended += 1
    }

    private func voxelKey(_ p: SIMD3<Float>, size: Float) -> Int64 {
        let x = Int64(Int32(floor(p.x / size))) & 0x1FFFFF
        let y = Int64(Int32(floor(p.y / size))) & 0x1FFFFF
        let z = Int64(Int32(floor(p.z / size))) & 0x1FFFFF
        return x | (y << 21) | (z << 42)
    }

    private func sample(depthMap: CVPixelBuffer, confidenceMap: CVPixelBuffer, frame: ARFrame) {
        let image = frame.capturedImage
        guard CVPixelBufferGetPlaneCount(image) >= 2 else { return }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(image, .readOnly)
            CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
        }
        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap),
              let confidenceBase = CVPixelBufferGetBaseAddress(confidenceMap),
              let yBase = CVPixelBufferGetBaseAddressOfPlane(image, 0),
              let cbcrBase = CVPixelBufferGetBaseAddressOfPlane(image, 1) else { return }

        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        let depthRowBytes = CVPixelBufferGetBytesPerRow(depthMap)
        let confidenceRowBytes = CVPixelBufferGetBytesPerRow(confidenceMap)
        let imageWidth = CVPixelBufferGetWidthOfPlane(image, 0)
        let imageHeight = CVPixelBufferGetHeightOfPlane(image, 0)
        let yRowBytes = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        let cbcrRowBytes = CVPixelBufferGetBytesPerRowOfPlane(image, 1)

        let resolution = frame.camera.imageResolution
        let sx = Float(depthWidth) / Float(resolution.width)
        let sy = Float(depthHeight) / Float(resolution.height)
        let intrinsics = frame.camera.intrinsics
        let fx = intrinsics.columns.0.x * sx
        let fy = intrinsics.columns.1.y * sy
        let cx = intrinsics.columns.2.x * sx
        let cy = intrinsics.columns.2.y * sy
        let transform = frame.camera.transform
        let cameraPosition = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let imageScaleX = Float(imageWidth) / Float(depthWidth)
        let imageScaleY = Float(imageHeight) / Float(depthHeight)

        let yBytes = yBase.assumingMemoryBound(to: UInt8.self)
        let cbcrBytes = cbcrBase.assumingMemoryBound(to: UInt8.self)
        let confidenceBytes = confidenceBase.assumingMemoryBound(to: UInt8.self)

        var v = pixelStride / 2
        while v < depthHeight {
            let depthRow = depthBase.advanced(by: v * depthRowBytes).assumingMemoryBound(to: Float32.self)
            var u = pixelStride / 2
            while u < depthWidth {
                defer { u += pixelStride }
                let d = depthRow[u]
                guard d > 0.1 && d < maxDepth else { continue }
                guard confidenceBytes[v * confidenceRowBytes + u] >= 2 else { continue }

                let local = SIMD4<Float>((Float(u) - cx) / fx * d, -(Float(v) - cy) / fy * d, -d, 1.0)
                let world4 = transform * local
                let world = SIMD3<Float>(world4.x, world4.y, world4.z)
                updateCoverage(world, cameraPosition: cameraPosition)
                guard fineVoxels.insert(voxelKey(world, size: fineVoxelSize)).inserted else { continue }

                let iu = min(Int(Float(u) * imageScaleX), imageWidth - 1)
                let iv = min(Int(Float(v) * imageScaleY), imageHeight - 1)
                let luma = Float(yBytes[iv * yRowBytes + iu])
                let cbcrIndex = (iv / 2) * cbcrRowBytes + (iu / 2) * 2
                let cb = Float(cbcrBytes[cbcrIndex]) - 128.0
                let cr = Float(cbcrBytes[cbcrIndex + 1]) - 128.0
                let r = min(max((luma + 1.402 * cr) / 255.0, 0.0), 1.0)
                let g = min(max((luma - 0.344136 * cb - 0.714136 * cr) / 255.0, 0.0), 1.0)
                let b = min(max((luma + 1.772 * cb) / 255.0, 0.0), 1.0)
                append(PointCloudVertex(position: SIMD4<Float>(world.x, world.y, world.z, pointSize),
                                        color: SIMD4<Float>(r, g, b, 1.0)))
            }
            v += pixelStride
        }
    }

    // MARK: - Coverage

    private func updateCoverage(_ p: SIMD3<Float>, cameraPosition: SIMD3<Float>) {
        let key = voxelKey(p, size: areaVoxelSize)
        // Direction from the surface to the camera: 8 compass sectors x (from above / level-or-below).
        let d = cameraPosition - p
        let length = max(simd_length(d), 0.001)
        let yaw = atan2(d.x, d.z)
        let sector = min(max(Int((yaw + Float.pi) / (2 * Float.pi) * 8), 0), 7)
        let bit = UInt16(1) << UInt16(sector + (d.y / length > 0.35 ? 8 : 0))

        let slot: Int
        if let existing = coverageSlots[key] {
            slot = Int(existing)
            let old = coverageMasks[slot]
            if old & bit != 0 { return }
            coverageMasks[slot] = old | bit
        } else {
            guard coverageCount < coverageCapacity else { return }
            slot = coverageCount
            coverageSlots[key] = Int32(slot)
            coverageMasks.append(bit)
            coverageCount += 1
        }
        let views = coverageMasks[slot].nonzeroBitCount
        if views == 3 { wellCoveredVoxels += 1 }
        let center = ((p / areaVoxelSize).rounded(.down) + 0.5) * areaVoxelSize
        let pointer = coverageBuffer.contents().bindMemory(to: PointCloudVertex.self, capacity: coverageCapacity)
        pointer[slot] = PointCloudVertex(position: SIMD4<Float>(center.x, center.y, center.z, 0.07),
                                         color: PointCloudAccumulator.coverageColor(views: views))
    }

    static func coverageColor(views: Int) -> SIMD4<Float> {
        switch views {
        case 0, 1: return SIMD4<Float>(0.95, 0.2, 0.2, 1)    // seen from one direction: scan more
        case 2: return SIMD4<Float>(1.0, 0.6, 0.15, 1)
        case 3: return SIMD4<Float>(0.95, 0.9, 0.2, 1)
        default: return SIMD4<Float>(0.25, 0.85, 0.35, 1)    // seen from 4+ directions: good
        }
    }
}
