//
//  MotionMaskEncoder.swift
//  Stray SF
//
//  Masks for things that should not be trained into the splat: people (Vision person segmentation) and anything
//  else that moves (optical flow that does not match the camera's own motion over the LiDAR depth).
//  Writes masks/<frame>.png (256×192, same size and orientation as depth/, 255 = ignore) for frames where
//  something was found, plus masks.csv with the share of each frame that is masked. Runs on the Neural Engine / GPU
//  on a background queue, a few times per second, and skips frames while busy — it never slows down recording.
//

import Foundation
import ARKit
import Vision
import CoreImage
import Accelerate
import ImageIO
import UniformTypeIdentifiers

final class MotionMaskEncoder {
    private let directory: URL
    private let csv: FileHandle?
    private let queue = DispatchQueue(label: "masks", qos: .utility)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var busy = false
    private let lock = NSLock()
    private var lastStarted: TimeInterval = 0
    private let interval: TimeInterval = 0.2
    private var previous: (image: CVPixelBuffer, transform: simd_float4x4)?
    static let width = 256, height = 192
    private(set) var maskedFrames = 0

    init(directory: URL) {
        self.directory = directory.appendingPathComponent("masks", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("masks.csv")
        try? "frame, moving_fraction, person_fraction\n".write(to: url, atomically: true, encoding: .utf8)
        csv = try? FileHandle(forWritingTo: url)
        csv?.seekToEndOfFile()
    }

    /// Called for every saved frame (main thread). Cheap when skipped.
    func add(frame: ARFrame, frameNumber: Int) {
        guard frame.timestamp - lastStarted >= interval, let depth = frame.sceneDepth?.depthMap else { return }
        lock.lock()
        if busy { lock.unlock(); return }
        busy = true
        lock.unlock()
        lastStarted = frame.timestamp
        // Copy what we need now; never keep the ARFrame itself (ARKit runs out of buffers).
        guard let small = downscale(frame.capturedImage) else { finish(); return }
        let depthCopy = copyDepth(depth)
        let transform = frame.camera.transform
        let resolution = frame.camera.imageResolution
        let k = frame.camera.intrinsics
        let s = Float(MotionMaskEncoder.width) / Float(resolution.width)
        let intrinsics = SIMD4<Float>(k.columns.0.x * s, k.columns.1.y * s, k.columns.2.x * s, k.columns.2.y * s)
        queue.async {
            self.process(small: small, depth: depthCopy, transform: transform, intrinsics: intrinsics, frameNumber: frameNumber)
            self.finish()
        }
    }

    func done() {
        queue.sync {
            try? csv?.close()
        }
    }

    private func finish() {
        lock.lock()
        busy = false
        lock.unlock()
    }

    // MARK: - Work (background queue)

    private func process(small: CVPixelBuffer, depth: [Float], transform: simd_float4x4, intrinsics: SIMD4<Float>,
                         frameNumber: Int) {
        let w = MotionMaskEncoder.width, h = MotionMaskEncoder.height
        var mask = [UInt8](repeating: 0, count: w * h)
        var movingCount = 0, personCount = 0

        // People: Vision person segmentation (fast setting), resized to the mask grid.
        let person = VNGeneratePersonSegmentationRequest()
        person.qualityLevel = .fast
        person.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cvPixelBuffer: small, options: [:])
        try? handler.perform([person])
        if let seg = person.results?.first?.pixelBuffer {
            CVPixelBufferLockBaseAddress(seg, .readOnly)
            let sw = CVPixelBufferGetWidth(seg), sh = CVPixelBufferGetHeight(seg)
            let rb = CVPixelBufferGetBytesPerRow(seg)
            if let base = CVPixelBufferGetBaseAddress(seg)?.assumingMemoryBound(to: UInt8.self) {
                for y in 0..<h {
                    let sy = min(y * sh / h, sh - 1)
                    for x in 0..<w where base[sy * rb + min(x * sw / w, sw - 1)] > 127 {
                        mask[y * w + x] = 255
                        personCount += 1
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(seg, .readOnly)
        }

        // Anything else moving: optical flow vs. the flow the camera motion alone would cause.
        if let prev = previous {
            let flowRequest = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: prev.image, options: [:])
            flowRequest.computationAccuracy = .medium
            flowRequest.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float
            try? handler.perform([flowRequest])
            if let flow = flowRequest.results?.first?.pixelBuffer {
                movingCount = markMoving(flow: flow, depth: depth, transform: transform, previous: prev.transform,
                                         intrinsics: intrinsics, mask: &mask)
            }
        }
        previous = (small, transform)

        let total = Float(w * h)
        guard Float(movingCount + personCount) / total > 0.002 else {
            writeRow(frameNumber, 0, 0)
            return
        }
        dilate(&mask, w, h)
        writePNG(mask, w, h, to: directory.appendingPathComponent(String(format: "%06d.png", frameNumber)))
        maskedFrames += 1
        writeRow(frameNumber, Float(movingCount) / total, Float(personCount) / total)
    }

    /// Predicted flow for a static world: reproject each pixel (with LiDAR depth) into the previous camera.
    /// Pixels whose measured flow differs by more than ~3 px (or 35 %) are moving. The sign convention of Vision's
    /// flow is resolved per frame by taking whichever sign matches the camera motion better.
    private func markMoving(flow: CVPixelBuffer, depth: [Float], transform: simd_float4x4, previous: simd_float4x4,
                            intrinsics k: SIMD4<Float>, mask: inout [UInt8]) -> Int {
        let w = MotionMaskEncoder.width, h = MotionMaskEncoder.height
        CVPixelBufferLockBaseAddress(flow, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(flow, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(flow) else { return 0 }
        let fw = CVPixelBufferGetWidth(flow), fh = CVPixelBufferGetHeight(flow)
        let rowBytes = CVPixelBufferGetBytesPerRow(flow)
        let toPrevious = previous.inverse * transform
        var predicted = [SIMD2<Float>](repeating: SIMD2(.nan, .nan), count: w * h)
        var measured = [SIMD2<Float>](repeating: .zero, count: w * h)
        var errPlus: [Float] = [], errMinus: [Float] = []
        for v in Swift.stride(from: 0, to: h, by: 1) {
            for u in Swift.stride(from: 0, to: w, by: 1) {
                let i = v * w + u
                let d = depth[i]
                guard d > 0.1 && d < 8 else { continue }
                let local = SIMD4<Float>((Float(u) - k.z) / k.x * d, -(Float(v) - k.w) / k.y * d, -d, 1)
                let p = toPrevious * local
                guard p.z < -0.05 else { continue }
                let pu = k.x * p.x / -p.z + k.z, pv = -k.y * p.y / -p.z + k.w
                predicted[i] = SIMD2(pu - Float(u), pv - Float(v))
                let fx = min(u * fw / w, fw - 1), fy = min(v * fh / h, fh - 1)
                let f = base.advanced(by: fy * rowBytes + fx * 8).assumingMemoryBound(to: Float.self)
                // Flow is in flow-image pixels; scale to the mask grid.
                measured[i] = SIMD2(f[0] * Float(w) / Float(fw), f[1] * Float(h) / Float(fh))
                if (u + v) % 7 == 0 {
                    errPlus.append(simd_length(measured[i] - predicted[i]))
                    errMinus.append(simd_length(-measured[i] - predicted[i]))
                }
            }
        }
        guard errPlus.count > 50 else { return 0 }
        func median(_ a: [Float]) -> Float { let s = a.sorted(); return s[s.count / 2] }
        let sign: Float = median(errPlus) <= median(errMinus) ? 1 : -1
        var count = 0
        for i in 0..<(w * h) where !predicted[i].x.isNaN {
            let e = simd_length(sign * measured[i] - predicted[i])
            if e > max(3.0, 0.35 * simd_length(predicted[i])) {
                if mask[i] == 0 { count += 1 }
                mask[i] = 255
            }
        }
        // A single stray pixel is noise: keep only pixels with ≥ 3 moving neighbours.
        var cleaned = mask
        for v in 1..<(h - 1) {
            for u in 1..<(w - 1) where mask[v * w + u] == 255 {
                var n = 0
                for dv in -1...1 { for du in -1...1 where mask[(v + dv) * w + u + du] == 255 { n += 1 } }
                if n < 4 { cleaned[v * w + u] = 0 }
            }
        }
        mask = cleaned
        return count
    }

    // MARK: - Helpers

    private func downscale(_ image: CVPixelBuffer) -> CVPixelBuffer? {
        let w = MotionMaskEncoder.width, h = MotionMaskEncoder.height
        var out: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs, &out)
        guard let buffer = out else { return nil }
        let ci = CIImage(cvPixelBuffer: image)
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / ci.extent.width, y: CGFloat(h) / ci.extent.height))
        ciContext.render(scaled, to: buffer)
        return buffer
    }

    private func copyDepth(_ depth: CVPixelBuffer) -> [Float] {
        let w = MotionMaskEncoder.width, h = MotionMaskEncoder.height
        var out = [Float](repeating: 0, count: w * h)
        CVPixelBufferLockBaseAddress(depth, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depth) else { return out }
        let dw = CVPixelBufferGetWidth(depth), dh = CVPixelBufferGetHeight(depth)
        let rb = CVPixelBufferGetBytesPerRow(depth)
        for y in 0..<h {
            let row = base.advanced(by: min(y * dh / h, dh - 1) * rb).assumingMemoryBound(to: Float32.self)
            for x in 0..<w { out[y * w + x] = row[min(x * dw / w, dw - 1)] }
        }
        return out
    }

    /// Grow the mask by 2 px so edges of moving things are covered too.
    private func dilate(_ mask: inout [UInt8], _ w: Int, _ h: Int) {
        for _ in 0..<2 {
            let src = mask
            for v in 0..<h {
                for u in 0..<w where src[v * w + u] == 0 {
                    if (u > 0 && src[v * w + u - 1] == 255) || (u < w - 1 && src[v * w + u + 1] == 255)
                        || (v > 0 && src[(v - 1) * w + u] == 255) || (v < h - 1 && src[(v + 1) * w + u] == 255) {
                        mask[v * w + u] = 255
                    }
                }
            }
        }
    }

    private func writePNG(_ mask: [UInt8], _ w: Int, _ h: Int, to url: URL) {
        var data = mask
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    private func writeRow(_ frame: Int, _ moving: Float, _ person: Float) {
        csv?.write(String(format: "%06d, %.4f, %.4f\n", frame, moving, person).data(using: .utf8)!)
    }
}
