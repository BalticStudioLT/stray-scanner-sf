//
//  ExposureEncoder.swift
//  StrayScanner
//
//  Writes exposure.csv (stray-scanner-sf fork): the real exposure of every saved frame.
//  Frame numbers match odometry.csv, depth/ and confidence/.
//

import Foundation
import ARKit

class ExposureEncoder {
    let path: URL
    private let fileHandle: FileHandle?

    init(url: URL) {
        self.path = url
        var handle: FileHandle? = nil
        do {
            try "".write(to: url, atomically: true, encoding: .utf8)
            handle = try FileHandle(forWritingTo: url)
            handle?.write("timestamp, frame, exposure_duration_s, exposure_offset, iso, white_balance_r, white_balance_g, white_balance_b\n".data(using: .utf8)!)
        } catch let error {
            print("Can't create exposure file \(url.absoluteString). \(error.localizedDescription)")
        }
        self.fileHandle = handle
    }

    func add(frame: ARFrame, currentFrame: Int, snapshot: ExposureSnapshot?) {
        guard let fileHandle = fileHandle else { return }
        let frameNumber = String(format: "%06d", currentFrame)
        let iso = snapshot.map { "\($0.iso)" } ?? ""
        let r = snapshot.map { "\($0.whiteBalanceGains.redGain)" } ?? ""
        let g = snapshot.map { "\($0.whiteBalanceGains.greenGain)" } ?? ""
        let b = snapshot.map { "\($0.whiteBalanceGains.blueGain)" } ?? ""
        let line = "\(frame.timestamp), \(frameNumber), \(frame.camera.exposureDuration), \(frame.camera.exposureOffset), \(iso), \(r), \(g), \(b)\n"
        fileHandle.write(line.data(using: .utf8)!)
    }

    func done() {
        do {
            try fileHandle?.close()
        } catch let error {
            print("Can't close exposure file \(path.absoluteString). \(error.localizedDescription)")
        }
    }
}
