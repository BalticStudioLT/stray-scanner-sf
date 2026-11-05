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

private struct PCUniforms {
    var transform: simd_float4x4
    var intrinsics: SIMD4<Float>
    var cameraPos: SIMD4<Float>
    var imageScale: SIMD2<Float>
    var capacity: UInt32
    var coverageCapacity: UInt32
    var stride: UInt32
    var pointSize: Float
    var maxDepth: Float
    var fineMask: UInt32
    var coverageMask: UInt32
    var pad0: UInt32 = 0, pad1: UInt32 = 0, pad2: UInt32 = 0
}

final class PointCloudAccumulator {
    /// GPU path (compute kernels in Shaders.metal): unprojection, 2 cm dedupe and coverage run on the GPU, at
    /// 4× the density of the old CPU loop and with almost no CPU time (less heat while scanning).
    private struct GPU {
        let queue: MTLCommandQueue
        let sample: MTLComputePipelineState
        let append: MTLComputePipelineState
        let counters: MTLBuffer
        let fineTable: MTLBuffer
        let coverageTable: MTLBuffer
        let coverageSlots: MTLBuffer
        let coverageMasks: MTLBuffer
        let textureCache: CVMetalTextureCache
    }
    private var gpu: GPU?
    private static let fineTableSize = 1 << 22
    private static let coverageTableSize = 1 << 20
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
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        if let library = device.makeDefaultLibrary(),
           let queue = device.makeCommandQueue(),
           let sample = library.makeFunction(name: "pcSample").flatMap({ try? device.makeComputePipelineState(function: $0) }),
           let append = library.makeFunction(name: "pcAppend").flatMap({ try? device.makeComputePipelineState(function: $0) }),
           let counters = device.makeBuffer(length: 16, options: .storageModeShared),
           let fine = device.makeBuffer(length: PointCloudAccumulator.fineTableSize * 4, options: .storageModePrivate),
           let covTable = device.makeBuffer(length: PointCloudAccumulator.coverageTableSize * 4, options: .storageModePrivate),
           let covSlots = device.makeBuffer(length: PointCloudAccumulator.coverageTableSize * 4, options: .storageModePrivate),
           let covMasks = device.makeBuffer(length: coverageCapacity * 4, options: .storageModeShared),
           let cache = cache {
            gpu = GPU(queue: queue, sample: sample, append: append, counters: counters, fineTable: fine,
                      coverageTable: covTable, coverageSlots: covSlots, coverageMasks: covMasks, textureCache: cache)
            clearGPU()
        }
    }

    private func clearGPU() {
        guard let g = gpu, let cb = g.queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return }
        memset(g.counters.contents(), 0, 16)
        blit.fill(buffer: g.fineTable, range: 0..<g.fineTable.length, value: 0)
        blit.fill(buffer: g.coverageTable, range: 0..<g.coverageTable.length, value: 0)
        blit.fill(buffer: g.coverageSlots, range: 0..<g.coverageSlots.length, value: 0xFF)
        blit.fill(buffer: g.coverageMasks, range: 0..<g.coverageMasks.length, value: 0)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
    }

    /// Reads the GPU counters (after a pass has finished).
    private func readCounters() {
        guard let g = gpu else { return }
        let c = g.counters.contents().bindMemory(to: UInt32.self, capacity: 4)
        let written = Int(c[0]), coverage = Int(c[1]), well = Int(c[2])
        DispatchQueue.main.async {
            self.totalAppended = written
            self.count = min(written, self.capacity)
            self.coverageCount = min(coverage, self.coverageCapacity)
            self.wellCoveredVoxels = well
        }
    }

    private func gpuUniforms(frame: ARFrame?, depthSize: CGSize, imageSize: CGSize) -> PCUniforms {
        var u = PCUniforms(transform: matrix_identity_float4x4, intrinsics: .zero, cameraPos: .zero, imageScale: .one,
                           capacity: UInt32(capacity), coverageCapacity: UInt32(coverageCapacity), stride: 2,
                           pointSize: pointSize, maxDepth: maxDepth,
                           fineMask: UInt32(PointCloudAccumulator.fineTableSize - 1),
                           coverageMask: UInt32(PointCloudAccumulator.coverageTableSize - 1))
        if let frame = frame {
            let resolution = frame.camera.imageResolution
            let sx = Float(depthSize.width) / Float(resolution.width)
            let sy = Float(depthSize.height) / Float(resolution.height)
            let k = frame.camera.intrinsics
            u.transform = frame.camera.transform
            u.intrinsics = SIMD4(k.columns.0.x * sx, k.columns.1.y * sy, k.columns.2.x * sx, k.columns.2.y * sy)
            let t = frame.camera.transform.columns.3
            u.cameraPos = SIMD4(t.x, t.y, t.z, 1)
            u.imageScale = SIMD2(Float(imageSize.width / depthSize.width), Float(imageSize.height / depthSize.height))
        }
        return u
    }

    private func texture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat, cache: CVMetalTextureCache,
                         keep: inout [CVMetalTexture]) -> MTLTexture? {
        let planar = CVPixelBufferGetPlaneCount(buffer) > 0
        let w = planar ? CVPixelBufferGetWidthOfPlane(buffer, plane) : CVPixelBufferGetWidth(buffer)
        let h = planar ? CVPixelBufferGetHeightOfPlane(buffer, plane) : CVPixelBufferGetHeight(buffer)
        var cv: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, format, w, h, plane, &cv)
        guard let t = cv else { return nil }
        keep.append(t)
        return CVMetalTextureGetTexture(t)
    }

    private func gpuSample(_ g: GPU, depthMap: CVPixelBuffer, confidenceMap: CVPixelBuffer, frame: ARFrame) -> Bool {
        let image = frame.capturedImage
        var keep: [CVMetalTexture] = []
        guard CVPixelBufferGetPlaneCount(image) >= 2,
              let depth = texture(depthMap, plane: 0, format: .r32Float, cache: g.textureCache, keep: &keep),
              let conf = texture(confidenceMap, plane: 0, format: .r8Uint, cache: g.textureCache, keep: &keep),
              let luma = texture(image, plane: 0, format: .r8Unorm, cache: g.textureCache, keep: &keep),
              let chroma = texture(image, plane: 1, format: .rg8Unorm, cache: g.textureCache, keep: &keep),
              let cb = g.queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return false }
        var u = gpuUniforms(frame: frame, depthSize: CGSize(width: depth.width, height: depth.height),
                            imageSize: CGSize(width: luma.width, height: luma.height))
        enc.setComputePipelineState(g.sample)
        enc.setTextures([depth, conf, luma, chroma], range: 0..<4)
        enc.setBuffer(buffer, offset: 0, index: 0)
        enc.setBuffer(coverageBuffer, offset: 0, index: 1)
        enc.setBuffer(g.counters, offset: 0, index: 2)
        enc.setBuffer(g.fineTable, offset: 0, index: 3)
        enc.setBuffer(g.coverageTable, offset: 0, index: 4)
        enc.setBuffer(g.coverageSlots, offset: 0, index: 5)
        enc.setBuffer(g.coverageMasks, offset: 0, index: 6)
        enc.setBytes(&u, length: MemoryLayout<PCUniforms>.stride, index: 7)
        let grid = MTLSize(width: (depth.width + 1) / 2, height: (depth.height + 1) / 2, depth: 1)
        enc.dispatchThreads(grid, threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.endEncoding()
        let retained = keep
        cb.addCompletedHandler { [weak self] _ in
            withExtendedLifetime(retained) {}
            self?.readCounters()
        }
        cb.commit()
        return true
    }

    private func gpuAppend(_ g: GPU, _ vertex: PointCloudVertex) {
        guard let cb = g.queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return }
        var v = vertex
        var u = gpuUniforms(frame: nil, depthSize: CGSize(width: 1, height: 1), imageSize: CGSize(width: 1, height: 1))
        enc.setComputePipelineState(g.append)
        enc.setBuffer(buffer, offset: 0, index: 0)
        enc.setBuffer(g.counters, offset: 0, index: 2)
        enc.setBytes(&v, length: MemoryLayout<PointCloudVertex>.stride, index: 3)
        enc.setBytes(&u, length: MemoryLayout<PCUniforms>.stride, index: 7)
        enc.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        enc.endEncoding()
        cb.addCompletedHandler { [weak self] _ in self?.readCounters() }
        cb.commit()
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
        clearGPU()
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
        if let g = gpu, gpuSample(g, depthMap: sceneDepth.depthMap, confidenceMap: confidenceMap, frame: frame) { return }
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
        if let g = gpu {
            gpuAppend(g, PointCloudVertex(position: SIMD4<Float>(p.x, p.y, p.z, 0.02), color: SIMD4<Float>(0.25, 0.9, 1.0, 1.0)))
            return
        }
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

    /// Where the most surface seen from only one direction is (within 0.5–4 m of `camera`), for "film this from
    /// another angle" tips without the PC. Reads the GPU coverage data (shared memory), a few ms; call every few seconds.
    func weakestArea(camera: SIMD3<Float>) -> (center: SIMD3<Float>, voxels: Int)? {
        let n = min(coverageCount, coverageCapacity)
        guard n > 50 else { return nil }
        let vertices = coverageBuffer.contents().bindMemory(to: PointCloudVertex.self, capacity: coverageCapacity)
        let masks: UnsafeMutablePointer<UInt32>? = gpu.map { $0.coverageMasks.contents().bindMemory(to: UInt32.self, capacity: coverageCapacity) }
        var cells: [Int64: (sum: SIMD3<Float>, count: Int)] = [:]
        for i in 0..<n {
            let views = masks.map { $0[i].nonzeroBitCount } ?? (i < coverageMasks.count ? coverageMasks[i].nonzeroBitCount : 3)
            guard views == 1 else { continue }
            let p = SIMD3<Float>(vertices[i].position.x, vertices[i].position.y, vertices[i].position.z)
            let d = simd_distance(p, camera)
            guard d > 0.5, d < 4 else { continue }
            let key = voxelKey(p, size: 0.5)
            let c = cells[key] ?? (.zero, 0)
            cells[key] = (c.sum + p, c.count + 1)
        }
        guard let best = cells.values.max(by: { $0.count < $1.count }), best.count >= 6 else { return nil }
        return (best.sum / Float(best.count), best.count)
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
