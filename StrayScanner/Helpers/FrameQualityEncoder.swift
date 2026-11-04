//
//  FrameQualityEncoder.swift
//  StrayScanner
//
//  frame_quality.csv and markers.csv (stray-scanner-sf fork). Frame numbers match odometry.csv.
//

import Foundation
import ARKit

class FrameQualityEncoder {
    private let path: URL
    private let fileHandle: FileHandle?

    init(url: URL) {
        self.path = url
        var handle: FileHandle? = nil
        do {
            try "".write(to: url, atomically: true, encoding: .utf8)
            handle = try FileHandle(forWritingTo: url)
            handle?.write("timestamp, frame, tracking_state, tracking_reason, linear_speed_mps, angular_speed_dps, est_blur_px, median_depth_m, depth_confident_fraction, torch_level\n".data(using: .utf8)!)
        } catch let error {
            print("Can't create frame quality file \(url.absoluteString). \(error.localizedDescription)")
        }
        self.fileHandle = handle
    }

    func add(timestamp: TimeInterval, frameNumber: Int, quality: FrameQuality) {
        guard let fileHandle = fileHandle else { return }
        let frame = String(format: "%06d", frameNumber)
        let line = "\(timestamp), \(frame), \(quality.trackingState), \(quality.trackingReason), "
            + String(format: "%.4f, %.2f, %.3f, %.3f, %.3f, %.2f\n",
                     quality.linearSpeed, quality.angularSpeedDeg, quality.blurPixels,
                     quality.medianDepth, quality.depthConfidentFraction, quality.torchLevel)
        fileHandle.write(line.data(using: .utf8)!)
    }

    func done() {
        do {
            try fileHandle?.close()
        } catch let error {
            print("Can't close frame quality file \(path.absoluteString). \(error.localizedDescription)")
        }
    }
}

/// Points of interest the user pins while recording (e.g. stops for a guided tour).
class MarkerEncoder {
    private let path: URL
    private var fileHandle: FileHandle?
    private(set) var count: Int = 0
    private let q_AC = simd_quatf(ix: 1.0, iy: 0.0, iz: 0.0, r: 0.0) // same convention as odometry.csv

    init(url: URL) {
        self.path = url
    }

    func add(transform: simd_float4x4, timestamp: TimeInterval, frameNumber: Int) {
        if fileHandle == nil {
            do {
                try "marker, timestamp, frame, x, y, z, qx, qy, qz, qw\n".write(to: path, atomically: true, encoding: .utf8)
                fileHandle = try FileHandle(forWritingTo: path)
                fileHandle?.seekToEndOfFile()
            } catch let error {
                print("Can't create markers file. \(error.localizedDescription)")
                return
            }
        }
        count += 1
        let q = (simd_quatf(transform) * q_AC).vector
        let t = transform.columns.3
        let frame = String(format: "%06d", max(frameNumber, 0))
        let line = "\(count), \(timestamp), \(frame), \(t.x), \(t.y), \(t.z), \(q.x), \(q.y), \(q.z), \(q.w)\n"
        fileHandle?.write(line.data(using: .utf8)!)
    }

    func done() {
        do {
            try fileHandle?.close()
        } catch let error {
            print("Can't close markers file. \(error.localizedDescription)")
        }
    }
}
