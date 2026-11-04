//
//  PCLink.swift
//  StrayScanner
//
//  Link to the owner's PC running SplatForge (stray-scanner-sf fork), e.g. over Tailscale.
//  The phone runs the normal Tailscale app; this code only talks HTTP / WebSocket to the PC's
//  address. Protocol: docs/pc-link.md.
//
//  - Upload: POST http://<host>:<port>/stray/upload (zip of the scan folder)
//  - Ping:   GET  http://<host>:<port>/stray/ping
//  - Live:   ws://<host>:<port>/stray/live (poses, new points, small JPEG previews out; hints back)
//

import Foundation
import ARKit
import CoreImage
import ImageIO
import UIKit

struct PCLinkSettings {
    static let hostKey = "PCLinkHost"
    static let portKey = "PCLinkPort"
    static let tokenKey = "PCLinkToken"
    static let autoUploadKey = "PCLinkAutoUpload"
    static let liveKey = "PCLinkLive"

    var host: String
    var port: Int
    var token: String
    var autoUpload: Bool
    var live: Bool

    static func load() -> PCLinkSettings {
        let d = UserDefaults.standard
        let port = d.integer(forKey: portKey)
        return PCLinkSettings(host: d.string(forKey: hostKey) ?? "",
                              port: port > 0 ? port : 8777,
                              token: d.string(forKey: tokenKey) ?? "",
                              autoUpload: d.bool(forKey: autoUploadKey),
                              live: d.bool(forKey: liveKey))
    }

    func save() {
        let d = UserDefaults.standard
        d.set(host.trimmingCharacters(in: .whitespaces), forKey: PCLinkSettings.hostKey)
        d.set(port, forKey: PCLinkSettings.portKey)
        d.set(token, forKey: PCLinkSettings.tokenKey)
        d.set(autoUpload, forKey: PCLinkSettings.autoUploadKey)
        d.set(live, forKey: PCLinkSettings.liveKey)
    }

    var isConfigured: Bool { return !host.trimmingCharacters(in: .whitespaces).isEmpty }

    func url(_ path: String, scheme: String = "http") -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host.trimmingCharacters(in: .whitespaces)
        components.port = port
        components.path = path
        return components.url
    }
}

// MARK: - Upload

final class PCUploader: NSObject, URLSessionTaskDelegate {
    static let shared = PCUploader()

    /// Called on the main queue: (scan folder name, progress 0…1 or nil when finished, message).
    var onUpdate: ((String, Double?, String) -> Void)?
    private(set) var activeScans = Set<String>()
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 6 * 3600
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    private var names: [Int: String] = [:]
    private let lock = NSLock()

    static func ping(_ settings: PCLinkSettings, completion: @escaping (Bool, String) -> Void) {
        guard let url = settings.url("/api/system") else {
            completion(false, "Invalid address")
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.setValue(settings.token, forHTTPHeaderField: "X-Token")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let message: String
            var ok = false
            if let error = error {
                message = error.localizedDescription
            } else if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                ok = true
                let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                message = text.contains("\"cpu\"") ? "Connected to SplatForge Studio" : "Connected"
            } else {
                message = "PC answered \((response as? HTTPURLResponse)?.statusCode ?? 0)"
            }
            DispatchQueue.main.async { completion(ok, message) }
        }.resume()
    }

    /// Zips the scan folder and uploads it. Safe to call from the main thread.
    func upload(directory: URL) {
        let settings = PCLinkSettings.load()
        let name = directory.lastPathComponent
        guard settings.isConfigured, let url = settings.url("/stray/upload") else {
            report(name, nil, "Set the PC address first (Scans ▸ PC link)")
            return
        }
        lock.lock()
        let alreadyRunning = activeScans.contains(name)
        if !alreadyRunning { activeScans.insert(name) }
        lock.unlock()
        if alreadyRunning { return }
        report(name, 0, "Packing…")
        DispatchQueue.global(qos: .utility).async {
            do {
                let zip = try ShareUtility.createZipArchive(directory: directory)
                let size = (try? FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int64) ?? 0
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/zip", forHTTPHeaderField: "Content-Type")
                request.setValue(settings.token, forHTTPHeaderField: "X-Token")
                request.setValue(name, forHTTPHeaderField: "X-Scan-Name")
                request.setValue(String(size), forHTTPHeaderField: "X-Scan-Bytes")
                let task = self.session.uploadTask(with: request, fromFile: zip) { data, response, error in
                    try? FileManager.default.removeItem(at: zip)
                    self.lock.lock()
                    self.activeScans.remove(name)
                    self.lock.unlock()
                    if let error = error {
                        self.report(name, nil, "Upload failed: \(error.localizedDescription)")
                    } else if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                        let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                        self.report(name, nil, "Sent to PC" + (text.isEmpty ? "" : " — \(text.prefix(100))"))
                    } else {
                        self.report(name, nil, "PC answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                    }
                }
                self.lock.lock()
                self.names[task.taskIdentifier] = name
                self.lock.unlock()
                task.resume()
                self.report(name, 0, "Uploading \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))…")
            } catch {
                self.lock.lock()
                self.activeScans.remove(name)
                self.lock.unlock()
                self.report(name, nil, "Could not pack the scan: \(error.localizedDescription)")
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        lock.lock()
        let name = names[task.taskIdentifier]
        lock.unlock()
        guard let scan = name, totalBytesExpectedToSend > 0 else { return }
        let progress = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        report(scan, progress, String(format: "Uploading %.0f%%", progress * 100))
    }

    private func report(_ name: String, _ progress: Double?, _ message: String) {
        DispatchQueue.main.async {
            self.onUpdate?(name, progress, message)
            NotificationCenter.default.post(name: PCUploader.statusNotification, object: nil,
                                            userInfo: ["scan": name, "message": message, "progress": progress as Any])
        }
    }

    static let statusNotification = Notification.Name("PCUploaderStatus")
}

// MARK: - Live link

/// Streams the scan to the PC while recording and receives hints back.
final class PCLiveLink {
    private let settings: PCLinkSettings
    private var task: URLSessionWebSocketTask?
    private let sendQueue = DispatchQueue(label: "pclink.send")
    private var lastPoseSent: TimeInterval = 0
    private var lastPointsSent: TimeInterval = 0
    private var lastImageSent: TimeInterval = 0
    private var pointsSentUpTo: Int = 0
    private var pointsWrapCount: Int = 0
    private var busy = false
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private(set) var connected = false
    /// Latest hint from the PC (main thread), with the time it stops being shown.
    private(set) var hint: ScanAdvice?
    private var hintExpires = Date.distantPast
    private(set) var statusText: String = "PC: connecting…"
    /// Extra markers the PC asks to show (e.g. coverage gaps), world space.
    private(set) var markers: [PointCloudVertex] = []

    init?(settings: PCLinkSettings) {
        guard settings.isConfigured else { return nil }
        self.settings = settings
    }

    func connect(scanName: String?, frame: ARFrame?) {
        guard let url = settings.url("/stray/live", scheme: "ws") else { return }
        var request = URLRequest(url: url)
        request.setValue(settings.token, forHTTPHeaderField: "X-Token")
        let task = URLSession.shared.webSocketTask(with: request)
        self.task = task
        task.resume()
        var hello: [String: Any] = ["type": "hello", "app": "stray-scanner-sf", "protocol": 1,
                                    "device": UIDevice.current.model, "scan": scanName ?? NSNull()]
        if let frame = frame {
            hello["image_width"] = Int(frame.camera.imageResolution.width)
            hello["image_height"] = Int(frame.camera.imageResolution.height)
        }
        sendJSON(hello)
        receive()
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connected = false
    }

    /// Tells the PC a recording started (scan folder name) or stopped (it can then expect the upload).
    func notifyRecording(scan: String?, started: Bool) {
        sendJSON(["type": started ? "recording_started" : "recording_stopped", "scan": scan ?? NSNull()])
    }

    var currentHint: ScanAdvice? {
        return Date() < hintExpires ? hint : nil
    }

    /// Called for every ARKit frame on the main thread; sends at most 5 poses/s, 2 point batches/s, 1 image/s.
    func update(frame: ARFrame, savedFrame: Int?, quality: FrameQuality, pointCloud: PointCloudAccumulator?, recording: Bool) {
        guard task != nil else { return }
        let t = frame.timestamp
        if t - lastPoseSent >= 0.2 {
            lastPoseSent = t
            let m = frame.camera.transform
            let k = frame.camera.intrinsics
            let pose = [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
            sendJSON(["type": "frame", "t": t, "frame": savedFrame ?? -1, "recording": recording,
                      "pose_arkit_c2w_colmajor": pose,
                      "intrinsics": [k.columns.0.x, k.columns.1.y, k.columns.2.x, k.columns.2.y],
                      "tracking": quality.trackingState, "blur_px": quality.blurPixels,
                      "speed_mps": quality.linearSpeed, "turn_dps": quality.angularSpeedDeg,
                      "median_depth_m": quality.medianDepth, "torch": quality.torchLevel])
        }
        if let cloud = pointCloud, t - lastPointsSent >= 0.5 {
            lastPointsSent = t
            sendNewPoints(cloud)
        }
        if t - lastImageSent >= 1.0 && !busy {
            lastImageSent = t
            sendPreview(frame.capturedImage, frameNumber: savedFrame ?? -1)
        }
    }

    /// New point-cloud points since the last batch: "SFPT", uint32 count, then count × (3 float32 xyz, 4 uint8 rgba).
    private func sendNewPoints(_ cloud: PointCloudAccumulator) {
        let total = cloud.totalAppended
        if total < pointsSentUpTo {
            // The cloud was cleared (recording started): tell the PC to drop the preview points.
            pointsSentUpTo = 0
            sendJSON(["type": "reset_points"])
        }
        guard total > pointsSentUpTo else { return }
        let start = max(pointsSentUpTo, total - cloud.capacity)
        let count = min(total - start, 30_000)
        let pointer = cloud.buffer.contents().bindMemory(to: PointCloudVertex.self, capacity: cloud.capacity)
        var data = Data("SFPT".utf8)
        var n = UInt32(count).littleEndian
        data.append(Data(bytes: &n, count: 4))
        data.reserveCapacity(8 + count * 16)
        for i in 0..<count {
            let v = pointer[(start + i) % cloud.capacity]
            var xyz = [v.position.x, v.position.y, v.position.z]
            data.append(Data(bytes: &xyz, count: 12))
            let rgba: [UInt8] = [UInt8(min(max(v.color.x, 0), 1) * 255), UInt8(min(max(v.color.y, 0), 1) * 255),
                                 UInt8(min(max(v.color.z, 0), 1) * 255), 255]
            data.append(contentsOf: rgba)
        }
        pointsSentUpTo = start + count
        send(.data(data))
    }

    /// Small JPEG of the camera image: "SFJP", int32 frame, then JPEG bytes (long side 640 px, landscape sensor orientation).
    private func sendPreview(_ pixelBuffer: CVPixelBuffer, frameNumber: Int) {
        busy = true
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        sendQueue.async {
            defer { self.busy = false }
            let scale = 640 / max(image.extent.width, 1)
            let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let jpeg = self.ciContext.jpegRepresentation(of: small, colorSpace: colorSpace,
                                                               options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.6]) else { return }
            var data = Data("SFJP".utf8)
            var n = Int32(frameNumber).littleEndian
            data.append(Data(bytes: &n, count: 4))
            data.append(jpeg)
            self.send(.data(data))
        }
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        send(.string(text))
    }

    private func send(_ message: URLSessionWebSocketTask.Message) {
        task?.send(message) { [weak self] error in
            if let error = error {
                DispatchQueue.main.async {
                    self?.connected = false
                    self?.statusText = "PC: \(error.localizedDescription)"
                }
            }
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                DispatchQueue.main.async {
                    self.connected = false
                    self.statusText = "PC: disconnected (\(error.localizedDescription))"
                }
            case .success(let message):
                if case .string(let text) = message { self.handle(text) }
                self.receive()
            }
        }
    }

    /// Messages from the PC: {"type":"hint","text":…,"level":"info|warning|bad","ttl":5},
    /// {"type":"status","text":…}, {"type":"markers","points":[[x,y,z],…],"color":[r,g,b]}.
    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }
        DispatchQueue.main.async {
            self.connected = true
            switch type {
            case "hint":
                let level: ScanAdvice.Level
                switch json["level"] as? String {
                case "bad": level = .bad
                case "warning": level = .warning
                case "good": level = .good
                default: level = .info
                }
                self.hint = ScanAdvice(level: level, text: (json["text"] as? String) ?? "", symbolName: "desktopcomputer")
                self.hintExpires = Date().addingTimeInterval((json["ttl"] as? Double) ?? 5)
            case "status":
                self.statusText = "PC: " + ((json["text"] as? String) ?? "")
            case "markers":
                let color = (json["color"] as? [Double]) ?? [1, 0, 1]
                let rgba = SIMD4<Float>(Float(color[safe: 0] ?? 1), Float(color[safe: 1] ?? 0), Float(color[safe: 2] ?? 1), 1)
                let points = (json["points"] as? [[Double]]) ?? []
                self.markers = points.prefix(2000).compactMap { p in
                    guard p.count >= 3 else { return nil }
                    return PointCloudVertex(position: SIMD4<Float>(Float(p[0]), Float(p[1]), Float(p[2]), 0.06), color: rgba)
                }
            default:
                break
            }
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        return index >= 0 && index < count ? self[index] : nil
    }
}
