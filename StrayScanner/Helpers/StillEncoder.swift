//
//  StillEncoder.swift
//  StrayScanner
//
//  Sharp photos taken while scanning (stray-scanner-sf fork, optional): ARKit high-resolution frames,
//  about 12 MP against the 2.8 MP video frames. Written as stills/<n>.jpg (sensor orientation, like the
//  video) plus stills.csv with each photo's own pose and intrinsics, in the same convention as odometry.csv.
//  `frame` in stills.csv is the latest saved video frame, so depth/ and masks/ of that frame can be used.
//

import Foundation
import ARKit
import CoreImage
import ImageIO

final class StillEncoder {
    private let directory: URL
    private var csv: FileHandle?
    private let queue = DispatchQueue(label: "stills", qos: .utility)
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private let q_AC = simd_quatf(ix: 1.0, iy: 0.0, iz: 0.0, r: 0.0) // same convention as odometry.csv
    private let lock = NSLock()
    private var queued = 0
    private var saved = 0
    /// Photos handed over so far (main thread).
    private(set) var count = 0

    init(directory: URL) {
        self.directory = directory.appendingPathComponent("stills", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("stills.csv")
        let header = "still, timestamp, frame, x, y, z, qx, qy, qz, qw, fx, fy, cx, cy, width, height, exposure_duration_s, iso\n"
        try? header.write(to: url, atomically: true, encoding: .utf8)
        csv = try? FileHandle(forWritingTo: url)
        csv?.seekToEndOfFile()
    }

    /// Photos still waiting to be written (each holds a full-size camera buffer, so the caller keeps this small).
    var pending: Int {
        lock.lock()
        defer { lock.unlock() }
        return queued
    }

    /// Photos written to disk so far.
    var savedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return saved
    }

    /// Main thread. Keeps only the pixel buffer and the numbers, never the ARFrame itself.
    func add(frame: ARFrame, videoFrame: Int, iso: Float?) {
        let image = frame.capturedImage
        let transform = frame.camera.transform
        let intrinsics = frame.camera.intrinsics
        let timestamp = frame.timestamp
        let exposure = frame.camera.exposureDuration
        let number = count
        count += 1
        lock.lock()
        queued += 1
        lock.unlock()
        queue.async {
            self.write(image: image, number: number, timestamp: timestamp, videoFrame: videoFrame,
                       transform: transform, intrinsics: intrinsics, exposure: exposure, iso: iso)
            self.lock.lock()
            self.queued -= 1
            self.lock.unlock()
        }
    }

    func done() {
        queue.sync {
            try? csv?.close()
            csv = nil
        }
    }

    // MARK: - Work (background queue)

    private func write(image: CVPixelBuffer, number: Int, timestamp: TimeInterval, videoFrame: Int,
                       transform: simd_float4x4, intrinsics: simd_float3x3, exposure: TimeInterval, iso: Float?) {
        let name = String(format: "%06d", number)
        let url = directory.appendingPathComponent(name).appendingPathExtension("jpg")
        let picture = CIImage(cvPixelBuffer: image)
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        do {
            try context.writeJPEGRepresentation(of: picture, to: url, colorSpace: colorSpace, options: [quality: 0.9])
        } catch {
            print("Could not save photo \(number): \(error.localizedDescription)")
            return
        }
        let q = (simd_quatf(transform) * q_AC).vector
        let t = transform.columns.3
        let width = CVPixelBufferGetWidth(image)
        let height = CVPixelBufferGetHeight(image)
        let isoText = iso.map { "\($0)" } ?? ""
        let line = "\(name), \(timestamp), \(String(format: "%06d", max(videoFrame, 0))), \(t.x), \(t.y), \(t.z), "
            + "\(q.x), \(q.y), \(q.z), \(q.w), "
            + "\(intrinsics.columns.0.x), \(intrinsics.columns.1.y), \(intrinsics.columns.2.x), \(intrinsics.columns.2.y), "
            + "\(width), \(height), \(exposure), \(isoText)\n"
        if let data = line.data(using: .utf8) {
            csv?.write(data)
        }
        lock.lock()
        saved += 1
        lock.unlock()
    }
}
