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

/// Owner 2026-11-25: "add all but make all as options". Each switch is a Settings ▸ phone training option.
struct PhoneTrainOptions {
    static let moveKey = "TrainMovePositions", flatKey = "TrainFlatSplats", depthKey = "TrainLidarDepth"
    static let ssimKey = "TrainSSIM", relocateKey = "TrainRelocate", shKey = "TrainAngleColour"
    static let resolutionKey = "TrainResolution", lengthKey = "TrainLength"
    static let denseKey = "TrainDenseStart", framesKey = "TrainMoreFrames"

    var movePositions = true
    var flatSplats = true
    var lidarDepth = true
    var ssim = true
    var relocate = true
    var angleColour = true
    var width = 720            // 480, 720 or 1080
    var iterations = 7000      // 3000 quick, 7000 better, 15000 best, 30000 max
    var denseStart = false     // splats every 1 cm (up to 1 M) instead of 1.5 cm (up to 400 k)
    var moreFrames = false     // 300 keyframes instead of 150 (150 at 1080 px: memory)

    var keyframeCount: Int { moreFrames && width <= 720 ? 300 : 150 }
    var voxel: Float { denseStart ? 0.010 : 0.015 }
    var maxSplats: Int { denseStart ? 1_000_000 : 400_000 }

    static func load() -> PhoneTrainOptions {
        let d = UserDefaults.standard
        func flag(_ key: String) -> Bool { d.object(forKey: key) == nil ? true : d.bool(forKey: key) }
        var o = PhoneTrainOptions()
        o.movePositions = flag(moveKey); o.flatSplats = flag(flatKey); o.lidarDepth = flag(depthKey)
        o.ssim = flag(ssimKey); o.relocate = flag(relocateKey); o.angleColour = flag(shKey)
        if d.object(forKey: resolutionKey) != nil {
            let w = d.integer(forKey: resolutionKey)
            o.width = [480, 720, 1080].contains(w) ? w : 720
        }
        if d.object(forKey: lengthKey) != nil {
            let l = d.integer(forKey: lengthKey)
            o.iterations = [3000, 7000, 15000, 30000].contains(l) ? l : 7000
        }
        o.denseStart = d.bool(forKey: denseKey)
        o.moreFrames = d.bool(forKey: framesKey)
        return o
    }

    /// Everything off = the first phone trainer (colour, opacity and size on fixed round splats).
    var summary: String {
        var parts: [String] = []
        if movePositions { parts.append("moving") }
        if flatSplats { parts.append("flat") }
        if lidarDepth { parts.append("LiDAR depth") }
        if ssim { parts.append("SSIM") }
        if relocate { parts.append("relocation") }
        if angleColour { parts.append("angle colour") }
        if denseStart { parts.append("dense start") }
        return (parts.isEmpty ? "basic" : parts.joined(separator: ", ")) + " · \(width) px · \(keyframeCount) frames · \(iterations) steps"
    }
}

private struct Train2Uniforms {
    var view: simd_float4x4
    var focal: SIMD2<Float>
    var viewport: SIMD2<Float>
    var principal: SIMD2<Float>
    var pad: SIMD2<Float> = .zero
    var cameraPos: SIMD4<Float>
    var depthWeight: Float
    var movePositions: UInt32
    var anisotropic: UInt32
    var useSH: UInt32
    var count: UInt32
    var pad0: UInt32 = 0, pad1: UInt32 = 0, pad2: UInt32 = 0
}

private struct Adam2Uniforms {
    var lrPos: Float, lrColor: Float, lrOpacity: Float, lrScale: Float, lrRot: Float, lrSH: Float
    var beta1: Float, beta2: Float, eps: Float, bias1: Float, bias2: Float
    var count: UInt32
    var anisotropic: UInt32
    var pad0: UInt32 = 0, pad1: UInt32 = 0, pad2: UInt32 = 0
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
    var iterations = 7000
    private(set) var options = PhoneTrainOptions()
    private var stopRequested = false

    private struct Keyframe {
        let texture: MTLTexture
        let mask: MTLTexture?
        let depth: MTLTexture?          // LiDAR metres (confident pixels only, 0 = none)
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
        options = PhoneTrainOptions.load()
        iterations = options.iterations
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

    private static let P = 24      // floats per splat (Shaders.metal TP)
    private static let G = 12      // 2-D gradient floats per splat (TG)

    private func run() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let library = device.makeDefaultLibrary(),
              let queue = device.makeCommandQueue() else { throw TrainError("No Metal GPU") }
        var opt = options
        if ProcessInfo.processInfo.physicalMemory < 7_000_000_000 {
            // 6 GB phones: keep within memory.
            opt.width = min(opt.width, 720)
            opt.moreFrames = false
        }
        publish(.loading("Reading the scan…"))
        let scan = try ScanData(folder: folder)
        publish(.loading("Picking sharp frames…"))
        let picks = scan.pickKeyframes(max: opt.keyframeCount)
        guard picks.count >= 8 else { throw TrainError("Not enough sharp frames with poses") }
        let width = opt.width, height = Int((Float(opt.width) * scan.videoHeight / scan.videoWidth).rounded())
        publish(.loading("Decoding \(picks.count) frames…"))
        let (keyframes, cgImages) = try loadKeyframes(scan: scan, frames: picks, width: width, height: height,
                                                      device: device, withDepth: opt.lidarDepth)
        publish(.loading("Placing splats on the LiDAR points…"))
        let initial = initialSplats(scan: scan, frames: picks, images: cgImages, width: width, height: height,
                                    voxel: opt.voxel, maxSplats: opt.maxSplats)
        guard initial.count > (ScanData.isAlignedVideo(folder) ? 200 : 1000) else {
            throw TrainError(ScanData.isAlignedVideo(folder) ? "Too few points from the alignment" : "Too little LiDAR depth in this scan")
        }
        let n = initial.count
        let P = PhoneTrainer.P, G = PhoneTrainer.G

        var flat = [Float](repeating: 0, count: n * P)
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for (i, t) in initial.enumerated() {
            let o = i * P
            flat[o] = t.position.x; flat[o + 1] = t.position.y; flat[o + 2] = t.position.z
            flat[o + 3] = t.rgb.x; flat[o + 4] = t.rgb.y; flat[o + 5] = t.rgb.z
            flat[o + 6] = t.opacityLogit
            flat[o + 7] = t.logScale; flat[o + 8] = t.logScale; flat[o + 9] = t.logScale
            flat[o + 10] = 1
            lo = simd_min(lo, t.position); hi = simd_max(hi, t.position)
        }
        let extent = min(max(simd_length(hi - lo) * 0.5, 1), 10)

        guard let paramBuffer = device.makeBuffer(bytes: &flat, length: n * P * 4, options: .storageModeShared),
              let renderBuffer = device.makeBuffer(length: n * SplatLoader.stride, options: .storageModeShared),
              let shBuffer = device.makeBuffer(length: n * 18, options: .storageModeShared),
              let g2 = device.makeBuffer(length: n * G * 4, options: .storageModePrivate),
              let grads = device.makeBuffer(length: n * P * 4, options: .storageModePrivate),
              let m = device.makeBuffer(length: n * P * 4, options: .storageModeShared),
              let v = device.makeBuffer(length: n * P * 4, options: .storageModeShared),
              let build = library.makeFunction(name: "trainBuild2").flatMap({ try? device.makeComputePipelineState(function: $0) }),
              let lossK = library.makeFunction(name: "trainLossGrad").flatMap({ try? device.makeComputePipelineState(function: $0) }),
              let projBack = library.makeFunction(name: "trainProjectBack").flatMap({ try? device.makeComputePipelineState(function: $0) }),
              let adam = library.makeFunction(name: "trainAdam2").flatMap({ try? device.makeComputePipelineState(function: $0) }),
              let gainKernel = library.makeFunction(name: "trainGainGrad").flatMap({ try? device.makeComputePipelineState(function: $0) })
        else { throw TrainError("Not enough GPU memory") }
        memset(shBuffer.contents(), 0, shBuffer.length)
        memset(m.contents(), 0, m.length)
        memset(v.contents(), 0, v.length)
        let backDesc = MTLRenderPipelineDescriptor()
        backDesc.vertexFunction = library.makeFunction(name: "trainVertexBack")
        backDesc.fragmentFunction = library.makeFunction(name: "trainBackward2")
        backDesc.colorAttachments[0].pixelFormat = .r32Float
        backDesc.colorAttachments[1].pixelFormat = .rgba32Float
        let backward = try device.makeRenderPipelineState(descriptor: backDesc)
        if let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
            for b in [g2, grads] { blit.fill(buffer: b, range: 0..<b.length, value: 0) }
            blit.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
        }
        var count32 = UInt32(n)
        var shFlag: UInt32 = opt.angleColour ? 1 : 0
        func encodeBuild(_ cb: MTLCommandBuffer) {
            guard let enc = cb.makeComputeCommandEncoder() else { return }
            enc.setComputePipelineState(build)
            enc.setBuffer(paramBuffer, offset: 0, index: 0)
            enc.setBuffer(renderBuffer, offset: 0, index: 1)
            enc.setBuffer(shBuffer, offset: 0, index: 2)
            enc.setBytes(&count32, length: 4, index: 3)
            enc.setBytes(&shFlag, length: 4, index: 4)
            enc.dispatchThreads(MTLSize(width: n, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
            enc.endEncoding()
        }
        if let cb = queue.makeCommandBuffer() { encodeBuild(cb); cb.commit(); cb.waitUntilCompleted() }

        let splats = SplatData(count: n, buffer: renderBuffer, positions: initial.map { $0.position })
        if opt.angleColour { splats.sh = shBuffer }
        guard let renderer = GaussianSplatRenderer(device: device, splats: splats, colorFormat: .rgba16Float),
              renderer.sortedOrder != nil else { throw TrainError("GPU sort not available on this phone") }
        renderer.commandQueue = queue
        renderer.lodMinPixels = 0
        DispatchQueue.main.async {
            self.splatCount = n
            self.liveSplats = splats
            self.state = .training
        }

        func target(_ format: MTLPixelFormat, write: Bool = false) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            d.usage = write ? [.shaderWrite, .shaderRead] : [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        guard let rendered = target(.rgba16Float), let transmittance = target(.r32Float), let front = target(.rgba32Float),
              let dLdC = target(.rgba32Float, write: true),
              let gainGrad = device.makeBuffer(length: 16, options: .storageModeShared) else {
            throw TrainError("Not enough GPU memory")
        }
        let tiny: MTLTexture? = {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 1, height: 1, mipmapped: false)
            return device.makeTexture(descriptor: d)
        }()
        let noDepth: MTLTexture? = {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: 1, height: 1, mipmapped: false)
            return device.makeTexture(descriptor: d)
        }()
        var gains = [SIMD3<Float>](repeating: SIMD3(1, 1, 1), count: keyframes.count)
        var step: Float = 0

        for it in 0..<iterations {
            if stopRequested { break }
            if ProcessInfo.processInfo.thermalState == .serious { Thread.sleep(forTimeInterval: 0.03) }
            if ProcessInfo.processInfo.thermalState == .critical { Thread.sleep(forTimeInterval: 0.3) }
            let progress = Float(it) / Float(max(iterations, 1))
            let kfIndex = Int.random(in: 0..<keyframes.count)
            let kf = keyframes[kfIndex]
            let learnGain = progress > 1.0 / 3.0
            let moving = opt.movePositions && progress >= 0.3
            let aniso = opt.flatSplats && progress >= 0.5
            let shOn = opt.angleColour && progress >= 0.2
            memset(gainGrad.contents(), 0, 16)
            let projection = PhoneTrainer.projection(kf.intrinsics, width: Float(width), height: Float(height))
            let cameraPos = kf.view.inverse.columns.3

            guard let buildCB = queue.makeCommandBuffer() else { break }
            encodeBuild(buildCB)
            buildCB.commit()

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
            // dL/dC per pixel (L1, or L1 + SSIM).
            if let enc = cb.makeComputeCommandEncoder() {
                var gl = SIMD4<Float>(gains[kfIndex], opt.ssim ? 0.2 : 0)
                enc.setComputePipelineState(lossK)
                enc.setTexture(rendered, index: 0)
                enc.setTexture(kf.texture, index: 1)
                enc.setTexture(kf.mask ?? tiny, index: 2)
                enc.setTexture(dLdC, index: 3)
                enc.setBytes(&gl, length: 16, index: 0)
                enc.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
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
                    u.cameraPos = cameraPos
                    u.hasSH = opt.angleColour ? 1 : 0
                    enc.setRenderPipelineState(backward)
                    enc.setVertexBuffer(renderBuffer, offset: 0, index: 0)
                    enc.setVertexBuffer(sorted.order, offset: 0, index: 1)
                    enc.setVertexBytes(&u, length: MemoryLayout<GSUniforms>.stride, index: 2)
                    enc.setVertexBuffer(opt.angleColour ? shBuffer : renderBuffer, offset: 0, index: 3)
                    enc.setVertexBuffer(sorted.args, offset: 0, index: 4)
                    enc.setFragmentTexture(rendered, index: 0)
                    enc.setFragmentTexture(dLdC, index: 1)
                    enc.setFragmentBuffer(g2, offset: 0, index: 0)
                    enc.drawPrimitives(type: .triangleStrip, indirectBuffer: sorted.args, indirectBufferOffset: 0)
                    enc.endEncoding()
                }
            }
            if let enc = cb.makeComputeCommandEncoder() {
                var tu = Train2Uniforms(view: kf.view, focal: SIMD2(kf.intrinsics.x, kf.intrinsics.y),
                                        viewport: SIMD2(Float(width), Float(height)),
                                        principal: SIMD2(kf.intrinsics.z, kf.intrinsics.w),
                                        cameraPos: cameraPos,
                                        depthWeight: (opt.lidarDepth && moving) ? 1.0 : 0,
                                        movePositions: moving ? 1 : 0, anisotropic: aniso ? 1 : 0,
                                        useSH: shOn ? 1 : 0, count: UInt32(n))
                enc.setComputePipelineState(projBack)
                enc.setBuffer(paramBuffer, offset: 0, index: 0)
                enc.setBuffer(g2, offset: 0, index: 1)
                enc.setBuffer(grads, offset: 0, index: 2)
                enc.setBytes(&tu, length: MemoryLayout<Train2Uniforms>.stride, index: 3)
                enc.setTexture(kf.depth ?? noDepth, index: 0)
                enc.dispatchThreads(MTLSize(width: n, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
                enc.endEncoding()
            }
            if learnGain, let enc = cb.makeComputeCommandEncoder() {
                var tu = TrainUniforms(gain: SIMD4<Float>(gains[kfIndex], 1), gradScale: 1)
                enc.setComputePipelineState(gainKernel)
                enc.setTexture(rendered, index: 0)
                enc.setTexture(kf.texture, index: 1)
                enc.setTexture(kf.mask ?? tiny, index: 2)
                enc.setBuffer(gainGrad, offset: 0, index: 0)
                enc.setBytes(&tu, length: MemoryLayout<TrainUniforms>.stride, index: 1)
                enc.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                enc.endEncoding()
            }
            step += 1
            let decay = 1 - 0.7 * progress
            // Positions: SplatForge's schedule, 1.6e-4 × scene size, decaying exponentially to 1 % at the end.
            let posLR = moving ? 1.6e-4 * extent * pow(0.01, (progress - 0.3) / 0.7) : 0
            var a = Adam2Uniforms(lrPos: posLR, lrColor: 0.01 * decay, lrOpacity: 0.05 * decay, lrScale: 0.005 * decay,
                                  lrRot: aniso ? 0.002 * decay : 0, lrSH: shOn ? 0.001 * decay : 0,
                                  beta1: 0.9, beta2: 0.999, eps: 1e-8,
                                  bias1: 1 - pow(0.9, step), bias2: 1 - pow(0.999, step),
                                  count: UInt32(n), anisotropic: aniso ? 1 : 0)
            if let enc = cb.makeComputeCommandEncoder() {
                enc.setComputePipelineState(adam)
                enc.setBuffer(paramBuffer, offset: 0, index: 0)
                enc.setBuffer(grads, offset: 0, index: 1)
                enc.setBuffer(m, offset: 0, index: 2)
                enc.setBuffer(v, offset: 0, index: 3)
                enc.setBytes(&a, length: MemoryLayout<Adam2Uniforms>.stride, index: 4)
                enc.dispatchThreads(MTLSize(width: n, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
                enc.endEncoding()
            }
            cb.commit()
            cb.waitUntilCompleted()
            if learnGain {
                let g = gainGrad.contents().bindMemory(to: Float.self, capacity: 4)
                if g[3] > 100 {
                    let mean = SIMD3<Float>(g[0], g[1], g[2]) / g[3]
                    gains[kfIndex] = simd_clamp(gains[kfIndex] - 0.02 * mean + 0.002 * (SIMD3(1, 1, 1) - gains[kfIndex]),
                                                SIMD3(repeating: 0.5), SIMD3(repeating: 2))
                }
            }
            // Relocation (MCMC-style): every 100 steps between 10 % and 80 %, nearly transparent splats move onto
            // copies of visible ones (opacity split between the two), so detail grows where it is needed.
            if opt.relocate, it % 100 == 99, progress > 0.1, progress < 0.8 {
                PhoneTrainer.relocate(params: paramBuffer, m: m, v: v, count: n)
            }
            if it % 25 == 0 { DispatchQueue.main.async { self.iteration = it } }
        }
        if let cb = queue.makeCommandBuffer() { encodeBuild(cb); cb.commit(); cb.waitUntilCompleted() }
        publish(.loading("Saving phone_splat.ply…"))
        let trained = paramBuffer.contents().bindMemory(to: Float.self, capacity: n * P)
        try PhoneTrainer.writePLY(trained, count: n, withSH: opt.angleColour, to: outputURL)
        let done = iteration
        DispatchQueue.main.async {
            self.iteration = max(done, self.iterations)
            self.state = .finished(self.outputURL)
        }
    }

    /// Moves up to 5 % of the splats with opacity < 0.5 % onto copies of opaque ones, sampled by opacity. Both copies
    /// get opacity 1 − √(1 − o) (together they look like the original); the copy is nudged inside the splat's own
    /// footprint so the two can separate. Their optimiser state is reset.
    private static func relocate(params: MTLBuffer, m: MTLBuffer, v: MTLBuffer, count n: Int) {
        let P = PhoneTrainer.P
        let p = params.contents().bindMemory(to: Float.self, capacity: n * P)
        let mm = m.contents().bindMemory(to: Float.self, capacity: n * P)
        let vv = v.contents().bindMemory(to: Float.self, capacity: n * P)
        func opacity(_ i: Int) -> Float { 1 / (1 + exp(-p[i * P + 6])) }
        var dead: [Int] = []
        var alive: [Int] = []
        var cumulative: [Float] = []
        var total: Float = 0
        for i in 0..<n {
            let o = opacity(i)
            if o < 0.005 { dead.append(i) } else { alive.append(i); total += o; cumulative.append(total) }
        }
        guard !dead.isEmpty, !alive.isEmpty, total > 0 else { return }
        dead.shuffle()
        for d in dead.prefix(max(n / 20, 1)) {
            let r = Float.random(in: 0..<total)
            var lo = 0, hi = cumulative.count - 1
            while lo < hi { let mid = (lo + hi) / 2; if cumulative[mid] < r { lo = mid + 1 } else { hi = mid } }
            let s = alive[lo]
            let o = opacity(s)
            let newO = min(max(1 - sqrt(max(1 - o, 0)), 0.006), 0.99)
            let logit = log(newO / (1 - newO))
            for k in 0..<P { p[d * P + k] = p[s * P + k] }
            p[s * P + 6] = logit
            p[d * P + 6] = logit
            let sigma = exp((p[s * P + 7] + p[s * P + 8] + p[s * P + 9]) / 3)
            for k in 0..<3 { p[d * P + k] += Float.random(in: -1...1) * sigma * 0.5 }
            for k in 0..<P { mm[d * P + k] = 0; vv[d * P + k] = 0; mm[s * P + k] = 0; vv[s * P + k] = 0 }
        }
    }

    // MARK: - Data

    private func loadKeyframes(scan: ScanData, frames: [ScanData.Pose], width: Int, height: Int,
                               device: MTLDevice, withDepth: Bool = false) throws -> ([Keyframe], [Int: CGImage]) {
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
        let framesDir = folder.appendingPathComponent("frames")
        let fromFrames = ScanData.isAlignedVideo(folder)
        for pose in frames {
            let time = CMTime(seconds: (Double(pose.frame + scan.frameOffset) + 0.5) / scan.fps, preferredTimescale: 6000)
            let picture: CGImage? = fromFrames
                ? PhoneTrainer.resized(framesDir.appendingPathComponent(String(format: "%06d.jpg", pose.frame)), width: width, height: height)
                : try? generator.copyCGImage(at: time, actualTime: nil)
            guard let image = picture,
                  image.width == width, image.height == height,
                  let texture = try? loader.newTexture(cgImage: image, options: [.SRGB: false, .textureStorageMode: MTLStorageMode.private.rawValue])
            else { continue }
            let maskURL = folder.appendingPathComponent("masks").appendingPathComponent(String(format: "%06d.png", pose.frame))
            let mask = FileManager.default.fileExists(atPath: maskURL.path)
                ? try? loader.newTexture(URL: maskURL, options: [.SRGB: false, .textureStorageMode: MTLStorageMode.private.rawValue]) : nil
            keyframes.append(Keyframe(texture: texture, mask: mask,
                                      depth: withDepth ? lidarTexture(frame: pose.frame, device: device) : nil,
                                      view: pose.arkitCameraToWorld.inverse,
                                      intrinsics: SIMD4(pose.intrinsics.x * sx, pose.intrinsics.y * sy,
                                                        pose.intrinsics.z * sx, pose.intrinsics.w * sy)))
            images[pose.frame] = image
        }
        guard keyframes.count >= 8 else { throw TrainError("Could not decode the video frames") }
        return (keyframes, images)
    }

    /// A frame image (video aligned on the phone) scaled to the training size.
    static func resized(_ url: URL, width: Int, height: Int) -> CGImage? {
        guard let source = UIImage(contentsOfFile: url.path)?.cgImage,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// The frame's LiDAR depth in metres (r32Float, sensor orientation like the video), low-confidence pixels = 0.
    private func lidarTexture(frame: Int, device: MTLDevice) -> MTLTexture? {
        let name = String(format: "%06d.png", frame)
        guard let depth = DepthPNG.load(folder.appendingPathComponent("depth").appendingPathComponent(name)) else { return nil }
        let conf = PhoneTrainer.gray(folder.appendingPathComponent("confidence").appendingPathComponent(name))
        var metres = [Float](repeating: 0, count: depth.width * depth.height)
        for i in 0..<metres.count {
            if let c = conf, c.count == metres.count, c[i] < 2 { continue }
            metres[i] = Float(depth.mm[i]) / 1000
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: depth.width, height: depth.height, mipmapped: false)
        d.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: d) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, depth.width, depth.height), mipmapLevel: 0,
                        withBytes: metres, bytesPerRow: depth.width * 4)
        return texture
    }

    /// One splat per 1.5 cm voxel of confident LiDAR depth, coloured from the frame it was seen in.
    private func initialSplats(scan: ScanData, frames: [ScanData.Pose], images: [Int: CGImage],
                               width: Int, height: Int, voxel: Float = 0.015, maxSplats: Int = 400_000) -> [TrainParams] {
        var seen = Set<Int64>()
        var out: [TrainParams] = []
        // Video aligned on the phone: no LiDAR, start from the alignment's sparse points (x y z r g b floats).
        if let data = try? Data(contentsOf: folder.appendingPathComponent("points.bin")) {
            let n = data.count / 24
            data.withUnsafeBytes { raw in
                for i in 0..<n {
                    let f = { (k: Int) in raw.loadUnaligned(fromByteOffset: i * 24 + k * 4, as: Float.self) }
                    let p = SIMD3<Float>(f(0), f(1), f(2))
                    guard p.x.isFinite, p.y.isFinite, p.z.isFinite else { continue }
                    let key = (Int64(floor(p.x / voxel)) & 0x1FFFFF) | ((Int64(floor(p.y / voxel)) & 0x1FFFFF) << 21) | ((Int64(floor(p.z / voxel)) & 0x1FFFFF) << 42)
                    guard seen.insert(key).inserted else { continue }
                    out.append(TrainParams(rgb: SIMD3(f(3), f(4), f(5)), opacityLogit: -2.2, logScale: log(voxel), position: p))
                    if out.count >= maxSplats { break }
                }
            }
            // Sparse points: grow each into a few jittered copies inside its own footprint, so there are enough splats
            // for detail (relocation then moves them where the photos need them).
            let sized = PhoneTrainer.nnScales(out, voxel: max(voxel, 0.03))
            guard !sized.isEmpty else { return sized }
            let copies = min(20, max(1, 150_000 / sized.count))
            var grown: [TrainParams] = []
            grown.reserveCapacity(sized.count * copies)
            for t in sized {
                grown.append(t)
                let sigma = exp(t.logScale)
                for _ in 1..<copies {
                    var c = t
                    c.position += SIMD3<Float>(Float.random(in: -1...1), Float.random(in: -1...1), Float.random(in: -1...1)) * sigma
                    c.logScale = log(sigma * 0.6)
                    grown.append(c)
                }
            }
            return Array(grown.prefix(maxSplats))
        }
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
                    if out.count >= maxSplats { return PhoneTrainer.nnScales(out, voxel: voxel) }
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
        guard let data = DepthPNG.rawGray(url)?.values else { return nil }
        let maxValue = data.max() ?? 2
        return maxValue > 2 ? data.map { UInt8(Int($0) * 2 / Int(maxValue)) } : data
    }

    /// Standard 3DGS PLY (x y z, normals, f_dc, f_rest for SH degree 1, opacity, scale, rot), ARKit world (y up).
    static func writePLY(_ p: UnsafeMutablePointer<Float>, count n: Int, withSH: Bool, to url: URL) throws {
        let P = PhoneTrainer.P
        let c0: Float = 0.28209479177387814
        let kept = (0..<n).filter { p[$0 * P + 6] > -4.5 }
        var names = ["x", "y", "z", "nx", "ny", "nz", "f_dc_0", "f_dc_1", "f_dc_2"]
        if withSH { names += (0..<9).map { "f_rest_\($0)" } }
        names += ["opacity", "scale_0", "scale_1", "scale_2", "rot_0", "rot_1", "rot_2", "rot_3"]
        var header = "ply\nformat binary_little_endian 1.0\nelement vertex \(kept.count)\n"
        for name in names { header += "property float \(name)\n" }
        header += "end_header\n"
        var data = Data(header.utf8)
        var row = [Float](repeating: 0, count: names.count)
        data.reserveCapacity(data.count + kept.count * names.count * 4)
        for i in kept {
            let q = p + i * P
            var k = 0
            func put(_ value: Float) { row[k] = value; k += 1 }
            put(q[0]); put(q[1]); put(q[2]); put(0); put(0); put(0)
            put((q[3] - 0.5) / c0); put((q[4] - 0.5) / c0); put((q[5] - 0.5) / c0)
            if withSH {
                // f_rest is channel-major (R coefficients 1-3, then G, then B); our buffer is coefficient-major.
                for ch in 0..<3 { for coeff in 0..<3 { put(q[14 + coeff * 3 + ch]) } }
            }
            put(q[6]); put(q[7]); put(q[8]); put(q[9]); put(q[10]); put(q[11]); put(q[12]); put(q[13])
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
            // rgb.mp4 timestamps count camera frames; saved frame k is camera frame k × fps_divider.
            // (Before: at 5 fps every keyframe got a picture from the first tenth of the video.)
            if let divider = json["fps_divider"] as? Int, divider > 1 { fps /= Double(divider) }
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
    @State private var showingOptions = false
    @AppStorage(PhoneTrainOptions.moveKey) private var optMove = true
    @AppStorage(PhoneTrainOptions.flatKey) private var optFlat = true
    @AppStorage(PhoneTrainOptions.depthKey) private var optDepth = true
    @AppStorage(PhoneTrainOptions.ssimKey) private var optSSIM = true
    @AppStorage(PhoneTrainOptions.relocateKey) private var optRelocate = true
    @AppStorage(PhoneTrainOptions.shKey) private var optSH = true
    @AppStorage(PhoneTrainOptions.resolutionKey) private var optWidth = 720
    @AppStorage(PhoneTrainOptions.lengthKey) private var optLength = 7000
    @AppStorage(PhoneTrainOptions.denseKey) private var optDense = false
    @AppStorage(PhoneTrainOptions.framesKey) private var optFrames = false
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
                    Text(training ? trainer.options.summary : PhoneTrainOptions.load().summary)
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Splats start on the LiDAR points and learn from the sharpest frames. A preview on the phone, no PC needed — SplatForge still makes the final splat.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !training {
                        Button {
                            showingOptions = true
                        } label: {
                            Label("Training options", systemImage: "slider.horizontal.3")
                        }
                        .padding(.top, 2)
                    }
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
        .sheet(isPresented: $showingOptions) { optionsSheet }
    }

    private var training: Bool {
        if case .training = trainer.state { return true }
        if case .loading = trainer.state { return true }
        return false
    }

    /// Every improvement can be turned off on its own (owner 2026-11-25); all off = the first, simple trainer.
    private var optionsSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Let splats move", isOn: $optMove)
                    Toggle("Flat and stretched splats", isOn: $optFlat)
                    Toggle("Keep splats on the LiDAR surface", isOn: $optDepth)
                        .disabled(!optMove)
                    Toggle("Sharper texture (SSIM)", isOn: $optSSIM)
                    Toggle("Move weak splats to missing detail", isOn: $optRelocate)
                    Toggle("Colour changes with angle", isOn: $optSH)
                } footer: {
                    Text("Moving starts after 30 % of the steps, flat splats after 50 %. The LiDAR option only works while splats move. Turn everything off for the old quick trainer.")
                }
                Section {
                    Picker("Frame size", selection: $optWidth) {
                        Text("480 px (faster)").tag(480)
                        Text("720 px (sharper)").tag(720)
                        Text("1080 px (max, slow)").tag(1080)
                    }
                    Picker("Length", selection: $optLength) {
                        Text("Quick · 3 000 steps").tag(3000)
                        Text("Better · 7 000 steps").tag(7000)
                        Text("Best · 15 000 steps").tag(15000)
                        Text("Max · 30 000 steps").tag(30000)
                    }
                    Toggle("Denser start (1 cm, up to 1 M splats)", isOn: $optDense)
                    Toggle("More frames (300)", isOn: $optFrames)
                        .disabled(optWidth > 720)
                } header: {
                    Text("Quality")
                } footer: {
                    Text("Max settings: 1080 px, Max length, denser start. Roughly 30–60 minutes and a warm phone; keep it on the charger. More frames is only used up to 720 px (memory).")
                }
                Section {
                    Button("All on (recommended)") {
                        optMove = true; optFlat = true; optDepth = true; optSSIM = true; optRelocate = true; optSH = true
                        optWidth = 720; optLength = 7000; optDense = false; optFrames = false
                    }
                    Button("Maximum quality (slow)") {
                        optMove = true; optFlat = true; optDepth = true; optSSIM = true; optRelocate = true; optSH = true
                        optWidth = 1080; optLength = 30000; optDense = true; optFrames = false
                    }
                    Button("All off (old quick trainer)") {
                        optMove = false; optFlat = false; optDepth = false; optSSIM = false; optRelocate = false; optSH = false
                        optWidth = 480; optLength = 3000; optDense = false; optFrames = false
                    }
                }
            }
            .navigationTitle("Training options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { showingOptions = false } }
            }
        }
        .preferredColorScheme(.dark)
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
