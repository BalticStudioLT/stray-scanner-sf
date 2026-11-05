//
//  PCLink.swift
//  StrayScanner
//
//  Link to the owner's PC running SplatForge (stray-scanner-sf fork), e.g. over Tailscale.
//  The phone runs the normal Tailscale app; this code only talks HTTP / WebSocket to the PC's
//  address. Protocol: docs/pc-link.md.
//
//  - Upload: POST http://<host>:<port>/api/scan/upload?name=<scan>&recipe=base|draft (zip of the scan folder),
//            then GET /api/scan/state?name=… and /api/scan/status?job=… until the splat is trained
//  - Status: GET  http://<host>:<port>/api/system
//  - Live:   ws://<host>:<port + 1>/stray/live (poses, new points, small JPEG previews out; hints back)
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
        return PCLinkSettings(host: d.string(forKey: hostKey) ?? "coolmaster4",
                              port: port > 0 ? port : 8777,
                              token: cleanToken(d.string(forKey: tokenKey) ?? ""),
                              autoUpload: d.bool(forKey: autoUploadKey),
                              // On unless the owner turned it off: hints only reach the phone through it.
                              live: d.object(forKey: liveKey) == nil ? true : d.bool(forKey: liveKey))
    }

    func save() {
        let d = UserDefaults.standard
        d.set(host.trimmingCharacters(in: .whitespaces), forKey: PCLinkSettings.hostKey)
        d.set(port, forKey: PCLinkSettings.portKey)
        d.set(PCLinkSettings.cleanToken(token), forKey: PCLinkSettings.tokenKey)
        d.set(autoUpload, forKey: PCLinkSettings.autoUploadKey)
        d.set(live, forKey: PCLinkSettings.liveKey)
    }

    /// Tokens pasted from a file or a URL often carry spaces, newlines or a "t=" prefix — the server then says "wrong token".
    static func cleanToken(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
        if t.contains("t=") {
            let query = t.contains("?") ? t : "http://x/?" + t
            if let comps = URLComponents(string: query),
               let v = comps.queryItems?.first(where: { $0.name == "t" || $0.name == "token" })?.value {
                t = v
            }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// straysf://pair?host=coolmaster4&port=8777&t=TOKEN — or a Studio URL like http://coolmaster4:8777/?t=TOKEN.
    /// Returns true when the link carried a token and settings were saved.
    @discardableResult
    static func pair(with url: URL) -> Bool {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let items = comps.queryItems ?? []
        func item(_ n: String) -> String? { items.first(where: { $0.name == n })?.value }
        guard let token = item("t") ?? item("token"), !token.isEmpty else { return false }
        var s = PCLinkSettings.load()
        if url.scheme == "straysf" {
            if let h = item("host"), !h.isEmpty { s.host = h }
            if let p = item("port").flatMap(Int.init) { s.port = p }
        } else {
            if let h = comps.host, !h.isEmpty { s.host = h }
            if let p = comps.port { s.port = p }
        }
        s.token = cleanToken(token)
        s.save()
        NotificationCenter.default.post(name: PCLinkSettings.pairedNotification, object: nil)
        return true
    }
    static let pairedNotification = Notification.Name("PCLinkPaired")

    var isConfigured: Bool { return !host.trimmingCharacters(in: .whitespaces).isEmpty }

    func url(_ path: String, scheme: String = "http", query: [String: String] = [:]) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host.trimmingCharacters(in: .whitespaces)
        components.port = port
        components.path = path
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
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
    private static let uploadedKey = "PCUploadedScans"
    static func wasUploaded(_ name: String) -> Bool {
        return (UserDefaults.standard.stringArray(forKey: uploadedKey) ?? []).contains(name)
    }
    private static func markUploaded(_ name: String) {
        var names = UserDefaults.standard.stringArray(forKey: uploadedKey) ?? []
        if !names.contains(name) { names.append(name) }
        UserDefaults.standard.set(names, forKey: uploadedKey)
    }

    /// A continued scan is merged on the PC with the scan it continues, so that one has to be there first:
    /// upload the chain oldest-first when an earlier part was never sent.
    func upload(directory: URL) {
        if let data = try? Data(contentsOf: directory.appendingPathComponent("capture_settings.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let parentName = json["continues_scan"] as? String, !PCUploader.wasUploaded(parentName) {
            let parent = directory.deletingLastPathComponent().appendingPathComponent(parentName, isDirectory: true)
            if FileManager.default.fileExists(atPath: parent.path) {
                report(directory.lastPathComponent, 0, "Sending the earlier part (\(parentName.prefix(8))…) first")
                upload(directory: parent, then: { [weak self] in self?.upload(directory: directory) })
                return
            }
        }
        upload(directory: directory, then: nil)
    }

    private func upload(directory: URL, then next: (() -> Void)?) {
        let settings = PCLinkSettings.load()
        let name = directory.lastPathComponent
        let recipe = UserDefaults.standard.bool(forKey: "PCLinkDraft") ? "draft" : "base"
        guard settings.isConfigured, let url = settings.url("/api/scan/upload", query: ["name": name, "recipe": recipe]) else {
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
                        PCUploader.markUploaded(name)
                        next?()
                        self.report(name, nil, "Sent to PC — preparing frames…")
                        self.follow(scan: name, settings: settings, attempt: 0)
                    } else {
                        let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                        self.report(name, nil, "PC answered \((response as? HTTPURLResponse)?.statusCode ?? 0) \(text.prefix(120))")
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

    /// Follows the PC's processing: /api/scan/state until a job exists, then /api/scan/status until it is done.
    private func follow(scan: String, settings: PCLinkSettings, attempt: Int, job: Int? = nil) {
        guard attempt < 2000 else { return } // ~3 h at 5 s
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            let url = job.map { settings.url("/api/scan/status", query: ["job": String($0)]) }
                ?? settings.url("/api/scan/state", query: ["name": scan])
            guard let requestURL = url else { return }
            var request = URLRequest(url: requestURL, timeoutInterval: 15)
            request.setValue(settings.token, forHTTPHeaderField: "X-Token")
            URLSession.shared.dataTask(with: request) { data, _, _ in
                let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                let text = (json["text"] as? String) ?? ""
                if let job = job {
                    let status = (json["status"] as? String) ?? ""
                    let progress = (json["progress"] as? Double) ?? (json["progress"] as? NSNumber)?.doubleValue
                    if status == "done" {
                        let result = json["result"] as? [String: Any] ?? [:]
                        let psnr = (result["psnr"] as? Double).map { String(format: " · PSNR %.1f", $0) } ?? ""
                        self.report(scan, nil, "Splat ready on the PC" + psnr + " — open SplatForge to view it")
                        return
                    }
                    if status == "failed" {
                        self.report(scan, nil, "PC training failed: \(text.prefix(120))")
                        return
                    }
                    self.report(scan, progress ?? 0, text.isEmpty ? "PC: \(status)" : "PC: \(text)")
                    self.follow(scan: scan, settings: settings, attempt: attempt + 1, job: job)
                } else {
                    let stage = (json["stage"] as? String) ?? ""
                    if stage == "failed" {
                        self.report(scan, nil, "PC could not use the scan: \(text.prefix(150))")
                        return
                    }
                    let nextJob = (json["job"] as? Int) ?? (json["job"] as? NSNumber)?.intValue
                    self.report(scan, nil, text.isEmpty ? "PC: \(stage)" : "PC: \(text)")
                    self.follow(scan: scan, settings: settings, attempt: attempt + 1, job: nextJob)
                }
            }.resume()
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
    /// One spot the PC wants filmed next (world space) and why.
    private(set) var target: (point: SIMD3<Float>, text: String)?
    /// The PC's live preview splat (trained while scanning) and its version.
    private(set) var previewSplats: SplatData?
    private(set) var previewVersion = 0
    /// Verdict after recording_stopped: {"verdict": "good" | "rescan", "text": …}.
    var onSummary: ((_ good: Bool, _ text: String) -> Void)?

    init?(settings: PCLinkSettings) {
        guard settings.isConfigured else { return nil }
        self.settings = settings
    }

    private var closedByUs = false
    private var lastScanName: String?
    private var imageSize: (Int, Int)?
    private var retryCount = 0

    func connect(scanName: String?, frame: ARFrame?) {
        closedByUs = false
        lastScanName = scanName
        if let frame = frame { imageSize = (Int(frame.camera.imageResolution.width), Int(frame.camera.imageResolution.height)) }
        statusText = "PC: connecting to \(settings.host)…"
        // Python's http.server (Studio, port 8777) cannot do WebSockets: the live link listens on the next port.
        var liveSettings = settings
        liveSettings.port = settings.port + 1
        guard let url = liveSettings.url("/stray/live", scheme: "ws") else { return }
        var request = URLRequest(url: url)
        request.setValue(settings.token, forHTTPHeaderField: "X-Token")
        let task = URLSession.shared.webSocketTask(with: request)
        self.task = task
        task.resume()
        var hello: [String: Any] = ["type": "hello", "app": "stray-scanner-sf", "protocol": 1,
                                    "device": UIDevice.current.model, "scan": scanName ?? NSNull()]
        if let size = imageSize {
            hello["image_width"] = size.0
            hello["image_height"] = size.1
        }
        sendJSON(hello)
        receive()
    }

    func disconnect() {
        closedByUs = true
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
                    guard !self.closedByUs else { return }
                    self.connected = false
                    self.statusText = PCLiveLink.explain(error, host: self.settings.host, port: self.settings.port + 1)
                    // Keep trying: the PC may start later, Tailscale may reconnect, or the token gets fixed.
                    self.retryCount += 1
                    let delay = min(5.0 * Double(self.retryCount), 30.0)
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        guard !self.closedByUs, !self.connected else { return }
                        self.task?.cancel()
                        self.connect(scanName: self.lastScanName, frame: nil)
                    }
                }
            case .success(let message):
                if case .string(let text) = message { self.handle(text) }
                self.receive()
            }
        }
    }

    private var fetchingPreview = false
    private func fetchPreview(path: String, version: Int) {
        guard !fetchingPreview, let base = settings.url("/"),
              let url = URL(string: path, relativeTo: base)?.absoluteURL,
              let device = MTLCreateSystemDefaultDevice() else { return }
        fetchingPreview = true
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue(settings.token, forHTTPHeaderField: "X-Token")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let splats = data.flatMap { (response as? HTTPURLResponse)?.statusCode == 200 ? try? SplatLoader.decodeStudio($0, device: device) : nil }
            DispatchQueue.main.async {
                self.fetchingPreview = false
                if let splats = splats {
                    self.previewSplats = splats
                    self.previewVersion = version
                }
            }
        }.resume()
    }

    /// Plain-language reason why the live link is down.
    static func explain(_ error: Error, host: String, port: Int) -> String {
        let code = (error as NSError).code
        switch code {
        case NSURLErrorBadServerResponse:
            return "PC ✗ refused — wrong token? (Settings ▸ SplatForge PC)"
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "PC ✗ \(host) not found — Tailscale on?"
        case NSURLErrorCannotConnectToHost:
            return "PC ✗ no answer on port \(port) — SplatForge Studio running?"
        case NSURLErrorTimedOut, NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            return "PC ✗ network lost — retrying"
        default:
            return "PC ✗ \(error.localizedDescription) — retrying"
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
            self.retryCount = 0
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
                var text = (json["text"] as? String) ?? ""
                for prefix in ["PC: ", "PC "] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
                self.statusText = "PC ✓ " + text
            case "markers":
                let color = (json["color"] as? [Double]) ?? [1, 0, 1]
                let rgba = SIMD4<Float>(Float(color[safe: 0] ?? 1), Float(color[safe: 1] ?? 0), Float(color[safe: 2] ?? 1), 1)
                let points = (json["points"] as? [[Double]]) ?? []
                let colors = json["colors"] as? [[Double]]   // optional per-point colour (e.g. render error)
                self.markers = points.prefix(2000).enumerated().compactMap { i, p in
                    guard p.count >= 3 else { return nil }
                    var c = rgba
                    if let pc = colors?[safe: i], pc.count >= 3 { c = SIMD4<Float>(Float(pc[0]), Float(pc[1]), Float(pc[2]), 1) }
                    return PointCloudVertex(position: SIMD4<Float>(Float(p[0]), Float(p[1]), Float(p[2]), 0.06), color: c)
                }
            case "target":
                if let p = json["point"] as? [Double], p.count >= 3 {
                    self.target = (SIMD3<Float>(Float(p[0]), Float(p[1]), Float(p[2])), (json["text"] as? String) ?? "Film this spot")
                } else {
                    self.target = nil
                }
            case "summary":
                let good = (json["verdict"] as? String) == "good"
                self.onSummary?(good, (json["text"] as? String) ?? (good ? "Good to train" : "Some areas need rescanning"))
            case "preview":
                // {"type":"preview","version":n,"path":"/stray/live/preview?…"}: fetch the new draft splat.
                let version = (json["version"] as? Int) ?? (self.previewVersion + 1)
                if let path = json["path"] as? String, version > self.previewVersion { self.fetchPreview(path: path, version: version) }
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
