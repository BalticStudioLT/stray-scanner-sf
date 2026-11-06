//
//  PhoneTrainer.swift
//  Stray SF
//
//  Trains a Gaussian splat on the phone from a LiDAR scan, no PC needed (roadmap item 16).
//  LiDAR-anchored and simple on purpose so it fits a phone: splats sit on the LiDAR points (positions fixed,
//  ~1 cm accurate already), isotropic; colour, opacity and size are learnt from ~120 sharp video frames with an
//  L1 loss and Adam, all on the GPU (forward = the viewer's renderer, backward = Shaders.metal gsBackward).
//  Result: <scan>/phone_splat.ply (standard 3DGS PLY, opens in the viewer and in SplatForge/other tools).
//

import Foundation
import Metal
import AVFoundation
import MetalKit
import simd
import UIKit
import SwiftUI

/// Layout must match TrainParams in Shaders.metal (48 bytes).
struct TrainParams {
    var rgb: SIMD3<Float>
    var opacityLogit: Float
    var logScale: Float
    var position: SIMD3<Float>
}

private struct TrainUniforms {
    var gain: SIMD4<Float>
    var gradScale: Float
}

private struct AdamUniforms {
    var lrColor: Float, lrOpacity: Float, lrScale: Float
    var beta1: Float, beta2: Float, eps: Float
    var bias1: Float, bias2: Float
    var count: UInt32
}

final class PhoneTrainer: ObservableObject {
    enum State: Equatable { case idle, loading(String), training, finished(URL), failed(String) }

    @Published private(set) var state: State = .idle
    @Published private(set) var iteration = 0
    @Published private(set) var splatCount = 0
    /// Live splat (its GPU buffer is updated while training), for the preview.
    @Published private(set) var liveSplats: SplatData?

    let folder: URL
    var iterations = 3000
    private var stopRequested = false

    private struct Keyframe {
        let texture: MTLTexture
        let mask: MTLTexture?
        let view: simd_float4x4          // ARKit world → camera
        let intrinsics: SIMD4<Float>     // fx, fy, cx, cy at training resolution
    }

    init(folder: URL) {
        self.folder = folder
    }

    var outputURL: URL { folder.appendingPathComponent("phone_splat.ply") }

    func stop() { stopRequested = true }

    func start() {
        guard state != .training else { return }
        stopRequested = false
        iteration = 0
        Thread.detachNewThread { [weak self] in
            guard let self = self else { return }
            do {
                try self.run()
            } catch {
                DispatchQueue.main.async { self.state = .failed(error.localizedDescription) }
            }
        }
    }

    private func publish(_ s: State) { DispatchQueue.main.async { self.state = s } }

    // MARK: - Pipeline

    private func run() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let library = device.makeDefaultLibrary(),
              let queue = device.makeCommandQueue() else { throw TrainError("No Metal GPU") }
        publish(.loading("Reading the scan…"))
        let scan = try ScanData(folder: folder)
        publish(.loading("Picking sharp frames…"))
        let picks = scan.pickKeyframes(max: 150)
        guard picks.count >= 8 else { throw TrainError("Not enough sharp frames with poses") }
        let width = 480, height = Int((480 * scan.videoHeight / scan.videoWidth).rounded())
        publish(.loading("Decoding \(picks.count) frames…"))
        let (keyframes, cgImages) = try loadKeyframes(scan: scan, frames: picks, width: width, height: height, device: device)
        publish(.loading("Placing splats on the LiDAR points…"))
        var params = initialSplats(scan: scan, frames: picks, images: cgImages, width: width, height: height)
        guard params.count > 1000 else { throw TrainError("Too little LiDAR depth in this scan") }
        let n = params.count

        guard let paramBuffer = device.makeBuffer(bytes: &params, length: n * MemoryLayout<TrainParams>.stride, options: .storageModeShared),
              let renderBuffer = device.makeBuffer(length: n * SplatLoader.stride, options: .storageModeShared),
              let grads = device.makeBuffer(length: n * 5 * 4, options: .storageModePrivate),
              let m = device.makeBuffer(length: n * 5 * 4, options: .storageModePrivate),
              let v = device.makeBuffer(length: n * 5 * 4, options: .storageModePrivate),
              let build = library.makeFunction(name: "trainBuild").flatMap({ try? device.makeComputePipelineState(function: $0) }),
              let adam = library.makeFunction(name: "trainAdam").flatMap({ try? device.makeComputePipelineState(function: $0) })
        else { throw TrainError("Not enough GPU memory") }
        let backDesc = MTLRenderPipelineDescriptor()
        backDesc.vertexFunction = library.makeFunction(name: "gsVertexBack")
        backDesc.fragmentFunction = library.makeFunction(name: "gsBackward")
        backDesc.colorAttachments[0].pixelFormat = .r32Float
        backDesc.colorAttachments[1].pixelFormat = .rgba32Float
        let backward = try device.makeRenderPipelineState(descriptor: backDesc)

        // Zero optimiser state.
        if let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
            for b in [grads, m, v] { blit.fill(buffer: b, range: 0..<b.length, value: 0) }
            blit.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
        }
        var count32 = UInt32(n)
        func encodeBuild(_ cb: MTLCommandBuffer) {
            guard let enc = cb.makeComputeCommandEncoder() else { return }
            enc.setComputePipelineState(build)
            enc.setBuffer(paramBuffer, offset: 0, index: 0)
            enc.setBuffer(renderBuffer, offset: 0, index: 1)
            enc.setBytes(&count32, length: 4, index: 2)
            enc.dispatchThreads(MTLSize(width: n, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
            enc.endEncoding()
        }
        if let cb = queue.makeCommandBuffer() { encodeBuild(cb); cb.commit(); cb.waitUntilCompleted() }

        let positions = params.map { $0.position }
        let splats = SplatData(count: n, buffer: renderBuffer, positions: positions)
        guard let renderer = GaussianSplatRenderer(device: device, splats: splats, colorFormat: .rgba16Float),
              renderer.sortedOrder != nil else { throw TrainError("GPU sort not available on this phone") }
        renderer.commandQueue = queue
        renderer.lodMinPixels = 0
        DispatchQueue.main.async {
            self.splatCount = n
            self.liveSplats = splats
            self.state = .training
        }

        func target(_ format: MTLPixelFormat) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        guard let rendered = target(.rgba16Float), let transmittance = target(.r32Float), let front = target(.rgba32Float),
              let gainGrad = device.makeBuffer(length: 16, options: .storageModeShared),
              let gainKernel = library.makeFunction(name: "trainGainGrad").flatMap({ try? device.makeComputePipelineState(function: $0) })
        else {
            throw TrainError("Not enough GPU memory")
        }
        let noMask: MTLTexture? = {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 1, height: 1, mipmapped: false)
            return device.makeTexture(descriptor: d)
        }()
        // Per-frame exposure / colour gain (SplatForge: the biggest single error source on phone footage).
        var gains = [SIMD3<Float>](repeating: SIMD3(1, 1, 1), count: keyframes.count)

        var step: Float = 0
        for it in 0..<iterations {
            if stopRequested { break }
            if ProcessInfo.processInfo.thermalState == .serious { Thread.sleep(forTimeInterval: 0.03) }
            if ProcessInfo.processInfo.thermalState == .critical { Thread.sleep(forTimeInterval: 0.3) }
            let kfIndex = Int.random(in: 0..<keyframes.count)
            let kf = keyframes[kfIndex]
            let learnGain = it > iterations / 3
            memset(gainGrad.contents(), 0, 16)
            let projection = PhoneTrainer.projection(kf.intrinsics, width: Float(width), height: Float(height))

            // 1) parameters → render buffer (committed before the renderer's own sort command buffer).
            guard let buildCB = queue.makeCommandBuffer() else { break }
            encodeBuild(buildCB)
            buildCB.commit()

            // 2) forward render, 3) backward pass, 4) Adam.
            guard let cb = queue.makeCommandBuffer() else { break }
            let fwd = MTLRenderPassDescriptor()
            fwd.colorAttachments[0].texture = rendered
            fwd.colorAttachments[0].loadAction = .clear
            fwd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            fwd.colorAttachments[0].storeAction = .store
            if let enc = cb.makeRenderCommandEncoder(descriptor: fwd) {
                renderer.draw(enc, view: kf.view, projection: projection, viewport: CGSize(width: width, height: height))
                enc.endEncoding()
            }
            if let sorted = renderer.sortedOrder {
                let back = MTLRenderPassDescriptor()
                back.colorAttachments[0].texture = transmittance
                back.colorAttachments[0].loadAction = .clear
                back.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)
                back.colorAttachments[0].storeAction = .dontCare
                back.colorAttachments[1].texture = front
                back.colorAttachments[1].loadAction = .clear
                back.colorAttachments[1].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                back.colorAttachments[1].storeAction = .dontCare
                if let enc = cb.makeRenderCommandEncoder(descriptor: back) {
                    var u = GSUniforms(view: kf.view, projection: projection,
                                       viewport: SIMD2<Float>(Float(width), Float(height)),
                                       focal: SIMD2<Float>(kf.intrinsics.x, kf.intrinsics.y))
                    var tu = TrainUniforms(gain: SIMD4<Float>(gains[kfIndex], 1), gradScale: 1)
                    enc.setRenderPipelineState(backward)
                    enc.setVertexBuffer(renderBuffer, offset: 0, index: 0)
                    enc.setVertexBuffer(sorted.order, offset: 0, index: 1)
                    enc.setVertexBytes(&u, length: MemoryLayout<GSUniforms>.stride, index: 2)
                    enc.setVertexBuffer(renderBuffer, offset: 0, index: 3)
                    enc.setVertexBuffer(sorted.args, offset: 0, index: 4)
                    enc.setFragmentTexture(rendered, index: 0)
                    enc.setFragmentTexture(kf.texture, index: 1)
                    enc.setFragmentTexture(kf.mask ?? noMask, index: 2)
                    enc.setFragmentBuffer(grads, offset: 0, index: 0)
                    enc.setFragmentBytes(&tu, length: MemoryLayout<TrainUniforms>.stride, index: 1)
                    enc.drawPrimitives(type: .triangleStrip, indirectBuffer: sorted.args, indirectBufferOffset: 0)
                    enc.endEncoding()
                }
            }
            if learnGain, let enc = cb.makeComputeCommandEncoder() {
                var tu = TrainUniforms(gain: SIMD4<Float>(gains[kfIndex], 1), gradScale: 1)
                enc.setComputePipelineState(gainKernel)
                enc.setTexture(rendered, index: 0)
                enc.setTexture(kf.texture, index: 1)
                enc.setTexture(kf.mask ?? noMask, index: 2)
                enc.setBuffer(gainGrad, offset: 0, index: 0)
                enc.setBytes(&tu, length: MemoryLayout<TrainUniforms>.stride, index: 1)
                enc.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                enc.endEncoding()
            }
            step += 1
            // Learning rates decay to 30 % over the run.
            let decay = 1 - 0.7 * Float(it) / Float(max(iterations, 1))
            var a = AdamUniforms(lrColor: 0.01 * decay, lrOpacity: 0.05 * decay, lrScale: 0.005 * decay,
                                 beta1: 0.9, beta2: 0.999, eps: 1e-8,
                                 bias1: 1 - pow(0.9, step), bias2: 1 - pow(0.999, step), count: UInt32(n))
            if let enc = cb.makeComputeCommandEncoder() {
                enc.setComputePipelineState(adam)
                enc.setBuffer(paramBuffer, offset: 0, index: 0)
                enc.setBuffer(grads, offset: 0, index: 1)
                enc.setBuffer(m, offset: 0, index: 2)
                enc.setBuffer(v, offset: 0, index: 3)
                enc.setBytes(&a, length: MemoryLayout<AdamUniforms>.stride, index: 4)
                enc.dispatchThreads(MTLSize(width: n, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
                enc.endEncoding()
            }
            cb.commit()
            cb.waitUntilCompleted()
            if learnGain {
                let g = gainGrad.contents().bindMemory(to: Float.self, capacity: 4)
                if g[3] > 100 {
                    let mean = SIMD3<Float>(g[0], g[1], g[2]) / g[3]
                    // Small step on the mean sign error, gently pulled back to 1 (tiny L2).
                    gains[kfIndex] = simd_clamp(gains[kfIndex] - 0.02 * mean + 0.002 * (SIMD3(1, 1, 1) - gains[kfIndex]),
                                                SIMD3(repeating: 0.5), SIMD3(repeating: 2))
                }
            }
            if it % 25 == 0 { DispatchQueue.main.async { self.iteration = it } }
        }
        if let cb = queue.makeCommandBuffer() { encodeBuild(cb); cb.commit(); cb.waitUntilCompleted() }
        publish(.loading("Saving phone_splat.ply…"))
        let trained = paramBuffer.contents().bindMemory(to: TrainParams.self, capacity: n)
        try PhoneTrainer.writePLY(Array(UnsafeBufferPointer(start: trained, count: n)), to: outputURL)
        let done = iteration
        DispatchQueue.main.async {
            self.iteration = max(done, self.iterations)
            self.state = .finished(self.outputURL)
        }
    }

    // MARK: - Data

    private func loadKeyframes(scan: ScanData, frames: [ScanData.Pose], width: Int, height: Int,
                               device: MTLDevice) throws -> ([Keyframe], [Int: CGImage]) {
        let asset = AVURLAsset(url: folder.appendingPathComponent("rgb.mp4"))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: width, height: height)
        generator.appliesPreferredTrackTransform = false
        let loader = MTKTextureLoader(device: device)
        var keyframes: [Keyframe] = []
        var images: [Int: CGImage] = [:]
        let sx = Float(width) / scan.videoWidth, sy = Float(height) / scan.videoHeight
        for pose in frames {
            let time = CMTime(seconds: (Double(pose.frame + scan.frameOffset) + 0.5) / scan.fps, preferredTimescale: 6000)
            guard let image = try? generator.copyCGImage(at: time, actualTime: nil),
                  image.width == width, image.height == height,
                  let texture = try? loader.newTexture(cgImage: image, options: [.SRGB: false, .textureStorageMode: MTLStorageMode.private.rawValue])
            else { continue }
            let maskURL = folder.appendingPathComponent("masks").appendingPathComponent(String(format: "%06d.png", pose.frame))
            let mask = FileManager.default.fileExists(atPath: maskURL.path)
                ? try? loader.newTexture(URL: maskURL, options: [.SRGB: false, .textureStorageMode: MTLStorageMode.private.rawValue]) : nil
            keyframes.append(Keyframe(texture: texture, mask: mask, view: pose.arkitCameraToWorld.inverse,
                                      intrinsics: SIMD4(pose.intrinsics.x * sx, pose.intrinsics.y * sy,
                                                        pose.intrinsics.z * sx, pose.intrinsics.w * sy)))
            images[pose.frame] = image
        }
        guard keyframes.count >= 8 else { throw TrainError("Could not decode the video frames") }
        return (keyframes, images)
    }

    /// One splat per 1.5 cm voxel of confident LiDAR depth, coloured from the frame it was seen in.
    private func initialSplats(scan: ScanData, frames: [ScanData.Pose], images: [Int: CGImage],
                               width: Int, height: Int) -> [TrainParams] {
        var seen = Set<Int64>()
        var out: [TrainParams] = []
        let voxel: Float = 0.015
        for pose in frames {
            guard let image = images[pose.frame], let pixels = PhoneTrainer.rgba(image),
                  let depth = DepthPNG.load(folder.appendingPathComponent("depth").appendingPathComponent(String(format: "%06d.png", pose.frame)))
            else { continue }
            let conf = PhoneTrainer.gray(folder.appendingPathComponent("confidence").appendingPathComponent(String(format: "%06d.png", pose.frame)))
            let s = Float(depth.width) / scan.videoWidth
            let k = pose.intrinsics * SIMD4(s, s, s, s)
            for v in Swift.stride(from: 0, to: depth.height, by: 2) {
                for u in Swift.stride(from: 0, to: depth.width, by: 2) {
                    let i = v * depth.width + u
                    let d = Float(depth.mm[i]) / 1000
                    guard d > 0.15, d < 5 else { continue }
                    if let c = conf, c.count == depth.mm.count, c[i] < 2 { continue }
                    let cam = SIMD4<Float>((Float(u) - k.z) / k.x * d, (Float(v) - k.w) / k.y * d, d, 1)   // OpenCV camera
                    let w4 = pose.cvCameraToWorld * cam
                    let p = SIMD3<Float>(w4.x, w4.y, w4.z)
                    let key = (Int64(floor(p.x / voxel)) & 0x1FFFFF) | ((Int64(floor(p.y / voxel)) & 0x1FFFFF) << 21) | ((Int64(floor(p.z / voxel)) & 0x1FFFFF) << 42)
                    guard seen.insert(key).inserted else { continue }
                    let px = min(Int(Float(u) / Float(depth.width) * Float(width)), width - 1)
                    let py = min(Int(Float(v) / Float(depth.height) * Float(height)), height - 1)
                    let o = (py * width + px) * 4
                    let rgb = SIMD3<Float>(Float(pixels[o]), Float(pixels[o + 1]), Float(pixels[o + 2])) / 255
                    out.append(TrainParams(rgb: rgb, opacityLogit: -2.2, logScale: log(voxel), position: p))
                    if out.count >= 400_000 { return PhoneTrainer.nnScales(out, voxel: voxel) }
                }
            }
        }
        return PhoneTrainer.nnScales(out, voxel: voxel)
    }

    /// Scale = 0.6 × mean distance to the 3 nearest splats (SplatForge's init; voxel size alone was too coarse).
    static func nnScales(_ input: [TrainParams], voxel: Float) -> [TrainParams] {
        var out = input
        var grid: [SIMD3<Int32>: [Int32]] = [:]
        for (i, p) in input.enumerated() {
            grid[SIMD3<Int32>(Int32(floor(p.position.x / voxel)), Int32(floor(p.position.y / voxel)), Int32(floor(p.position.z / voxel))), default: []].append(Int32(i))
        }
        for (i, p) in input.enumerated() {
            let c = SIMD3<Int32>(Int32(floor(p.position.x / voxel)), Int32(floor(p.position.y / voxel)), Int32(floor(p.position.z / voxel)))
            var best: [Float] = [.infinity, .infinity, .infinity]
            for dx in -1...1 { for dy in -1...1 { for dz in -1...1 {
                for j in grid[c &+ SIMD3<Int32>(Int32(dx), Int32(dy), Int32(dz))] ?? [] where Int(j) != i {
                    let d = simd_distance(p.position, input[Int(j)].position)
                    if d < best[2] { best[2] = d; best.sort() }
                }
            }}}
            let found = best.filter { $0.isFinite }
            let mean = found.isEmpty ? voxel * 1.5 : found.reduce(0, +) / Float(found.count)
            out[i].logScale = log(min(max(0.6 * mean, 0.002), 0.04))
        }
        return out
    }

    // MARK: - Helpers

    /// Perspective from pinhole intrinsics (image y down, camera looks −Z, Metal depth 0…1).
    static func projection(_ k: SIMD4<Float>, width: Float, height: Float, near: Float = 0.05, far: Float = 100) -> simd_float4x4 {
        let a = far / (near - far), b = near * far / (near - far)
        return simd_float4x4(columns: (SIMD4(2 * k.x / width, 0, 0, 0),
                                       SIMD4(0, 2 * k.y / height, 0, 0),
                                       SIMD4(1 - 2 * k.z / width, 2 * k.w / height - 1, a, -1),
                                       SIMD4(0, 0, b, 0)))
    }

    static func rgba(_ image: CGImage) -> [UInt8]? {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let ctx = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }

    static func gray(_ url: URL) -> [UInt8]? {
        guard let image = UIImage(contentsOfFile: url.path)?.cgImage else { return nil }
        var data = [UInt8](repeating: 0, count: image.width * image.height)
        guard let ctx = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let maxValue = data.max() ?? 2
        return maxValue > 2 ? data.map { UInt8(Int($0) * 2 / Int(maxValue)) } : data
    }

    /// Standard 3DGS PLY (x y z, normals, f_dc, opacity, scale, rot), ARKit world coordinates (y up).
    static func writePLY(_ params: [TrainParams], to url: URL) throws {
        let c0: Float = 0.28209479177387814
        let kept = params.filter { $0.opacityLogit > -4.5 }
        var header = "ply\nformat binary_little_endian 1.0\nelement vertex \(kept.count)\n"
        for name in ["x", "y", "z", "nx", "ny", "nz", "f_dc_0", "f_dc_1", "f_dc_2", "opacity",
                     "scale_0", "scale_1", "scale_2", "rot_0", "rot_1", "rot_2", "rot_3"] {
            header += "property float \(name)\n"
        }
        header += "end_header\n"
        var data = Data(header.utf8)
        var row = [Float](repeating: 0, count: 17)
        data.reserveCapacity(data.count + kept.count * 68)
        for p in kept {
            row[0] = p.position.x; row[1] = p.position.y; row[2] = p.position.z
            row[3] = 0; row[4] = 0; row[5] = 0
            row[6] = (p.rgb.x - 0.5) / c0; row[7] = (p.rgb.y - 0.5) / c0; row[8] = (p.rgb.z - 0.5) / c0
            row[9] = p.opacityLogit
            row[10] = p.logScale; row[11] = p.logScale; row[12] = p.logScale
            row[13] = 1; row[14] = 0; row[15] = 0; row[16] = 0
            row.withUnsafeBytes { data.append(contentsOf: $0) }
        }
        try data.write(to: url, options: .atomic)
    }
}

struct TrainError: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}

/// What the trainer needs from a scan folder.
struct ScanData {
    struct Pose {
        let frame: Int
        let cvCameraToWorld: simd_float4x4      // odometry.csv (OpenCV camera: x right, y down, z forward)
        let intrinsics: SIMD4<Float>            // fx, fy, cx, cy in video pixels
        var arkitCameraToWorld: simd_float4x4 { cvCameraToWorld * simd_float4x4(diagonal: SIMD4(1, -1, -1, 1)) }
    }
    let poses: [Pose]
    let blur: [Int: Float]
    let personFraction: [Int: Float]
    let videoWidth: Float, videoHeight: Float, fps: Double, frameOffset: Int

    init(folder: URL) throws {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("odometry.csv"), encoding: .utf8) else {
            throw TrainError("This scan has no poses (odometry.csv) — LiDAR scans only")
        }
        var poses: [Pose] = []
        for line in text.split(separator: "\n").dropFirst() {
            let v = line.split(separator: ",").map { Float($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
            guard v.count >= 13 else { continue }
            var m = simd_float4x4(simd_quatf(ix: v[5], iy: v[6], iz: v[7], r: v[8]))
            m.columns.3 = SIMD4(v[2], v[3], v[4], 1)
            poses.append(Pose(frame: Int(v[1]), cvCameraToWorld: m, intrinsics: SIMD4(v[9], v[10], v[11], v[12])))
        }
        self.poses = poses
        var blur: [Int: Float] = [:]
        if let q = try? String(contentsOf: folder.appendingPathComponent("frame_quality.csv"), encoding: .utf8) {
            for line in q.split(separator: "\n").dropFirst() {
                let f = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if f.count > 6, let frame = Int(f[1]), let b = Float(f[6]) { blur[frame] = b }
            }
        }
        self.blur = blur
        var person: [Int: Float] = [:]
        if let m = try? String(contentsOf: folder.appendingPathComponent("masks.csv"), encoding: .utf8) {
            var checked: [(Int, Float)] = []
            for line in m.split(separator: "\n").dropFirst() {
                let f = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if f.count > 2, let frame = Int(f[0]), let pf = Float(f[2]) { checked.append((frame, pf)) }
            }
            // Masks are checked ~5×/s: spread each value to the frames around it (±6).
            for (frame, pf) in checked where pf > 0 { for f in (frame - 6)...(frame + 6) { person[f] = max(person[f] ?? 0, pf) } }
        }
        self.personFraction = person
        var w: Float = 1920, h: Float = 1440, fps = 60.0, offset = 1
        if let data = try? Data(contentsOf: folder.appendingPathComponent("capture_settings.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let x = json["video_width"] as? Int { w = Float(x) }
            if let x = json["video_height"] as? Int { h = Float(x) }
            if let x = json["video_fps"] as? Double { fps = x } else if let x = json["video_fps"] as? Int { fps = Double(x) }
            if json["video_frame_offset"] != nil { offset = 0 }
        }
        videoWidth = w; videoHeight = h; self.fps = fps; frameOffset = offset
    }

    /// Sharpest frames, spread over the whole scan (frames that are mostly a person are skipped).
    func pickKeyframes(max count: Int) -> [Pose] {
        let sharp = poses.filter { (blur[$0.frame] ?? 0) <= 1.5 && (personFraction[$0.frame] ?? 0) <= 0.3 }
        let pool = sharp.count >= count / 2 ? sharp : poses
        guard pool.count > count else { return pool }
        return (0..<count).map { pool[$0 * pool.count / count] }
    }
}


// MARK: - Screen

struct PhoneTrainView: View {
    @StateObject private var trainer: PhoneTrainer
    @State private var viewing: SplatSource?
    @Environment(\.dismiss) private var dismiss

    init(folder: URL) {
        _trainer = StateObject(wrappedValue: PhoneTrainer(folder: folder))
    }

    var body: some View {
        ZStack {
            Color("BackgroundColor").ignoresSafeArea()
            VStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 24).fill(Color.black)
                    if let splats = trainer.liveSplats {
                        LiveTrainPreview(splats: splats, iteration: trainer.iteration)
                            .clipShape(RoundedRectangle(cornerRadius: 24))
                    } else {
                        Image(systemName: "cpu").font(.system(size: 54)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxHeight: 420)

                VStack(alignment: .leading, spacing: 8) {
                    Text(statusText).font(.headline)
                    if case .training = trainer.state {
                        ProgressView(value: Double(trainer.iteration), total: Double(trainer.iterations))
                        Text("\(trainer.splatCount.formatted()) splats · step \(trainer.iteration) / \(trainer.iterations)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Text("Splats sit on the LiDAR points; the phone learns their colour, opacity and size from the sharpest frames. A quick preview of the scan, no PC needed — SplatForge still makes the final splat.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(cornerRadius: 22)

                HStack(spacing: 12) {
                    switch trainer.state {
                    case .training:
                        Button { trainer.stop() } label: { Label("Stop & save", systemImage: "stop.fill").frame(maxWidth: .infinity) }
                            .glassButton()
                    case .finished(let url):
                        Button { viewing = .file(url) } label: { Label("Open splat", systemImage: "cube.transparent").frame(maxWidth: .infinity) }
                            .glassButton(prominent: true)
                        Button { trainer.start() } label: { Label("Train again", systemImage: "arrow.clockwise").frame(maxWidth: .infinity) }
                            .glassButton()
                    case .loading:
                        ProgressView().frame(maxWidth: .infinity)
                    default:
                        Button { trainer.start() } label: { Label("Train on this phone", systemImage: "cpu").frame(maxWidth: .infinity) }
                            .glassButton(prominent: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(16)
        }
        .navigationTitle("Train on phone")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            if FileManager.default.fileExists(atPath: trainer.outputURL.path), case .idle = trainer.state {
                // A previous result exists: offer to open it right away.
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            trainer.stop()
        }
        .fullScreenCover(item: $viewing) { SplatViewerScreen(source: $0) }
    }

    private var statusText: String {
        switch trainer.state {
        case .idle:
            return FileManager.default.fileExists(atPath: trainer.outputURL.path) ? "A phone splat exists — train again to update" : "Ready"
        case .loading(let text): return text
        case .training: return "Training…"
        case .finished: return "Done — saved as phone_splat.ply in the scan"
        case .failed(let text): return "Could not train: \(text)"
        }
    }
}

/// The live training buffer drawn in the orbit view, redrawn as training progresses.
private struct LiveTrainPreview: UIViewRepresentable {
    let splats: SplatData
    let iteration: Int

    func makeUIView(context: Context) -> OrbitSplatView {
        let view = OrbitSplatView(device: MTLCreateSystemDefaultDevice()!, splats: splats)
        view.speed = .sharp
        return view
    }

    func updateUIView(_ view: OrbitSplatView, context: Context) {
        view.setNeedsDisplay()
    }
}
