//
//  VideoToSplat.swift
//  Stray SF
//
//  Ordinary videos (Photos, Immich, Files) → splats (owner 2026-11-25: "i want all three"):
//  1. VideoUploader: sends the video to SplatForge (background upload, survives locking the phone), then queues
//     `sf run` on it; the PC aligns the cameras and trains like any other video.
//  2. ImmichClient: lists the videos on the owner's Immich server and downloads one.
//  3. PhoneVideoAligner (beta): camera alignment on the phone with Apple's photogrammetry engine
//     (RealityKit PhotogrammetrySession: poses + sparse points), written as a scan the phone trainer can use.
//

import Foundation
import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers
import AVFoundation
import CoreData
import RealityKit
import CoreImage

// MARK: - Picked / shared videos

/// A video copied out of Photos into the app's own folder (the picker only lends the file).
struct PickedMovie: Transferable {
    let url: URL

    // Photos hands over the exact type (QuickTime, MPEG-4, …); a generic "movie" alone is not always matched.
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .quickTimeMovie) { PickedMovie(url: try VideoInbox.keep($0.file)) }
        FileRepresentation(importedContentType: .mpeg4Movie) { PickedMovie(url: try VideoInbox.keep($0.file)) }
        FileRepresentation(importedContentType: .appleProtectedMPEG4Video) { PickedMovie(url: try VideoInbox.keep($0.file)) }
        FileRepresentation(importedContentType: .movie) { PickedMovie(url: try VideoInbox.keep($0.file)) }
    }
}

/// Videos waiting to be sent or aligned live in Caches/videos (removed after use).
enum VideoInbox {
    static var folder: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let dir = caches.appendingPathComponent("videos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Copies a file into the inbox (unique name, original extension).
    static func keep(_ source: URL) throws -> URL {
        let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension.lowercased()
        let target = folder.appendingPathComponent(UUID().uuidString.prefix(8) + "." + ext)
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: source, to: target)
        return target
    }

    static func isMovie(_ url: URL) -> Bool {
        return ["mov", "mp4", "m4v", "hevc", "avi", "mkv"].contains(url.pathExtension.lowercased())
    }

    /// A video handed to the app from elsewhere (Files, "Open in…", Immich's share sheet).
    static let openedNotification = Notification.Name("VideoOpenedInApp")
}

// MARK: - 1. Video → PC

/// One video sent to the PC, shown in the Splats tab until the owner clears it.
struct VideoJob: Codable, Identifiable, Equatable {
    var id: String            // upload name, also the SplatForge project vid_<id>
    var title: String
    var created: Date
    var status: String
    var progress: Double?
    var pcJob: Int?
    var failed = false
}

final class VideoUploader: NSObject, ObservableObject, URLSessionDataDelegate {
    static let shared = VideoUploader()
    static let backgroundIdentifier = "lt.nuskenuota.strayscanner.video"
    var backgroundCompletion: (() -> Void)?
    @Published private(set) var jobs: [VideoJob] = []
    private let jobsKey = "VideoToSplatJobs"
    private let lock = NSLock()
    private var responses: [Int: Data] = [:]

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: VideoUploader.backgroundIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.timeoutIntervalForResource = 12 * 3600
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: jobsKey),
           let saved = try? JSONDecoder().decode([VideoJob].self, from: data) {
            jobs = saved
        }
    }

    func reconnect() { session.getAllTasks { _ in } }

    private func save() {
        if let data = try? JSONEncoder().encode(jobs) { UserDefaults.standard.set(data, forKey: jobsKey) }
    }

    private func update(_ id: String, _ change: @escaping (inout VideoJob) -> Void) {
        DispatchQueue.main.async {
            guard let i = self.jobs.firstIndex(where: { $0.id == id }) else { return }
            change(&self.jobs[i])
            self.save()
        }
    }

    func remove(_ id: String) {
        jobs.removeAll { $0.id == id }
        save()
    }

    /// Uploads the video, then asks SplatForge to align and train it. `file` is moved into the inbox if needed.
    func send(file: URL, title: String) {
        let settings = PCLinkSettings.load()
        let stamp = DateFormatter()
        stamp.dateFormat = "yyMMdd_HHmm"
        let id = "vid_" + stamp.string(from: Date()) + "_" + String(UUID().uuidString.prefix(4)).lowercased()
        var job = VideoJob(id: id, title: title, created: Date(), status: "Starting…")
        guard settings.isPaired else {
            job.status = "Pair with the PC first (Settings tab)"
            job.failed = true
            jobs.insert(job, at: 0)
            save()
            return
        }
        jobs.insert(job, at: 0)
        save()
        let name = "video." + (file.pathExtension.isEmpty ? "mov" : file.pathExtension.lowercased())
        guard let url = settings.url("/api/upload", query: ["dir": id, "name": name]) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(settings.token, forHTTPHeaderField: "X-Token")
        let task = session.uploadTask(with: request, fromFile: file)
        task.taskDescription = "upload|\(id)|\(file.path)"
        task.resume()
        update(id) { $0.status = "Uploading — you can lock the phone"; $0.progress = 0 }
    }

    /// Sends the same video again (after a failed upload).
    func retry(_ job: VideoJob, file: URL) {
        remove(job.id)
        send(file: file, title: job.title)
    }

    // MARK: Delegate

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let parts = (task.taskDescription ?? "").split(separator: "|").map(String.init)
        guard parts.count >= 2, parts[0] == "upload", totalBytesExpectedToSend > 0 else { return }
        let p = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        let mb = { (b: Int64) in Double(b) / 1_048_576 }
        let text = p >= 0.999
            ? "Uploaded — the PC is saving the file and starting the job…"
            : String(format: "Uploading %.0f%% · %.0f / %.0f MB — you can lock the phone",
                     p * 100, mb(totalBytesSent), mb(totalBytesExpectedToSend))
        update(parts[1]) { $0.progress = p >= 0.999 ? nil : p; $0.status = text }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        responses[dataTask.taskIdentifier, default: Data()].append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let data = responses.removeValue(forKey: task.taskIdentifier) ?? Data()
        lock.unlock()
        let parts = (task.taskDescription ?? "").split(separator: "|").map(String.init)
        guard parts.count >= 2 else { return }
        let kind = parts[0], id = parts[1]
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        if let error = error {
            let text = PCLinkSettings.explainFailure(error, host: PCLinkSettings.load().host)
            update(id) { $0.status = "Failed: " + text; $0.failed = true; $0.progress = nil }
            return
        }
        guard status == 200 else {
            let text = (json["error"] as? String) ?? "PC answered \(status)"
            update(id) { $0.status = "Failed: " + text; $0.failed = true; $0.progress = nil }
            return
        }
        if kind == "upload" {
            if parts.count >= 3 { try? FileManager.default.removeItem(atPath: parts[2]) }
            guard let dir = json["dir"] as? String else {
                update(id) { $0.status = "The PC did not say where it saved the video"; $0.failed = true }
                return
            }
            queueTraining(id: id, uploadDir: dir)
        } else if kind == "run" {
            let jobID = (json["id"] as? Int) ?? (json["id"] as? NSNumber)?.intValue
            update(id) {
                $0.pcJob = jobID
                $0.progress = nil
                $0.status = jobID.map { "Queued on the PC (job \($0)) — the splat appears in this tab when done" }
                    ?? "Queued on the PC"
            }
        }
    }

    /// `sf run <SF_projects>/vid_… -i <upload dir>`: the normal video path (frames, alignment, training).
    private func queueTraining(id: String, uploadDir: String) {
        let settings = PCLinkSettings.load()
        let inputs = URL(fileURLWithPath: uploadDir.replacingOccurrences(of: "\\", with: "/"))
        let projects = inputs.deletingLastPathComponent().deletingLastPathComponent()
        let project = projects.appendingPathComponent(id).path
        let body: [String: Any] = ["args": ["run", project, "-i", uploadDir, "--run-name", "phone_video"]]
        guard let url = settings.url("/api/run"), let json = try? JSONSerialization.data(withJSONObject: body) else { return }
        let file = VideoInbox.folder.appendingPathComponent(id + "-run.json")
        try? json.write(to: file)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(settings.token, forHTTPHeaderField: "X-Token")
        let task = session.uploadTask(with: request, fromFile: file)
        task.taskDescription = "run|\(id)"
        task.resume()
        update(id) { $0.status = "Uploaded — starting the training on the PC…"; $0.progress = nil }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.backgroundCompletion?()
            self.backgroundCompletion = nil
        }
    }
}

// MARK: - 2. Immich

struct ImmichSettings {
    static let serverKey = "ImmichServer", apiKeyKey = "ImmichAPIKey"
    var server: String
    var apiKey: String

    static func load() -> ImmichSettings {
        let d = UserDefaults.standard
        let trim = { (s: String?) in (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        return ImmichSettings(server: trim(d.string(forKey: serverKey)), apiKey: trim(d.string(forKey: apiKeyKey)))
    }

    func save() {
        UserDefaults.standard.set(server.trimmingCharacters(in: .whitespacesAndNewlines), forKey: ImmichSettings.serverKey)
        UserDefaults.standard.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), forKey: ImmichSettings.apiKeyKey)
    }

    var isSet: Bool { !server.isEmpty && !apiKey.isEmpty }

    /// "photos.home:2283", "http://100.x.x.x:2283" or "https://…/" → base URL ending in /api.
    func url(_ path: String) -> URL? {
        var base = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if !base.contains("://") { base = "http://" + base }
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/api") { base.removeLast(4) }
        return URL(string: base + "/api" + path)
    }
}

struct ImmichVideo: Identifiable, Hashable {
    let id: String
    let name: String
    let date: String
    let duration: String
}

enum ImmichClient {
    private static func request(_ settings: ImmichSettings, _ path: String, method: String = "GET", body: Any? = nil) -> URLRequest? {
        guard let url = settings.url(path) else { return nil }
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.httpMethod = method
        r.setValue(settings.apiKey, forHTTPHeaderField: "x-api-key")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body = body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return r
    }

    /// Newest videos first (POST /api/search/metadata, type VIDEO).
    static func videos(_ settings: ImmichSettings, page: Int) async throws -> (videos: [ImmichVideo], more: Bool) {
        guard let r = request(settings, "/search/metadata", method: "POST",
                              body: ["type": "VIDEO", "page": page, "size": 60, "order": "desc", "withExif": false]) else {
            throw TrainError("Immich address is not valid")
        }
        let (data, response) = try await URLSession.shared.data(for: r)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw TrainError("Immich refused the API key") }
        guard code == 200 else { throw TrainError("Immich answered \(code)") }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let assets = json["assets"] as? [String: Any] ?? [:]
        let items = assets["items"] as? [[String: Any]] ?? []
        let videos = items.compactMap { item -> ImmichVideo? in
            guard let id = item["id"] as? String else { return nil }
            let date = ((item["fileCreatedAt"] as? String) ?? "").prefix(10)
            let duration = ((item["duration"] as? String) ?? "").split(separator: ".").first.map(String.init) ?? ""
            return ImmichVideo(id: id, name: (item["originalFileName"] as? String) ?? id, date: String(date), duration: duration)
        }
        let next = assets["nextPage"]
        return (videos, next != nil && !(next is NSNull))
    }

    static func thumbnail(_ settings: ImmichSettings, id: String) async -> UIImage? {
        guard let r = request(settings, "/assets/\(id)/thumbnail?size=thumbnail"),
              let (data, response) = try? await URLSession.shared.data(for: r),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return UIImage(data: data)
    }

    /// Downloads the original video into the inbox.
    static func download(_ settings: ImmichSettings, video: ImmichVideo) async throws -> URL {
        guard var r = request(settings, "/assets/\(video.id)/original") else { throw TrainError("Immich address is not valid") }
        r.timeoutInterval = 600
        let (file, response) = try await URLSession.shared.download(for: r)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw TrainError("Immich did not send the video") }
        let ext = (video.name as NSString).pathExtension.isEmpty ? "mov" : (video.name as NSString).pathExtension
        let target = VideoInbox.folder.appendingPathComponent(String(UUID().uuidString.prefix(8)) + "." + ext.lowercased())
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: file, to: target)
        return target
    }
}

// MARK: - 3. Camera alignment on the phone (beta)

/// Turns an ordinary video into a scan folder the phone trainer can use: frames/, odometry.csv (poses in the same
/// convention as Stray scans), points.bin (sparse points for the first splats) and capture_settings.json.
/// Alignment = Apple's photogrammetry engine (on-device, iPhone Pro with LiDAR, iOS 17+), which is built for objects
/// and small spaces; long room videos may not align.
@MainActor
final class PhoneVideoAligner: ObservableObject {
    enum State: Equatable { case idle, working(String, Double?), done(String), failed(String) }
    @Published private(set) var state: State = .idle
    /// The last couple of things the engine reported (shown under the progress bar so it never looks frozen).
    @Published private(set) var log: [String] = []
    @Published private(set) var started: Date?
    @Published private(set) var stepStarted: Date?

    private func note(_ line: String) {
        let elapsed = started.map { Int(Date().timeIntervalSince($0)) } ?? 0
        log.append(String(format: "%d:%02d  ", elapsed / 60, elapsed % 60) + line)
        if log.count > 2 { log.removeFirst(log.count - 2) }
    }
    private var task: Task<Void, Never>?

    static var isSupported: Bool {
        if #available(iOS 17.0, *) { return PhotogrammetrySession.isSupported }
        return false
    }

    func cancel() { task?.cancel() }

    func align(video: URL, title: String, framesPerSecond: Double = 4, maxFrames: Int = 300) {
        task?.cancel()
        task = Task { [weak self] in
            guard let self = self else { return }
            do {
                guard #available(iOS 17.0, *) else { throw TrainError("Needs iOS 17 or newer") }
                let name = try await self.run(video: video, title: title, fps: framesPerSecond, maxFrames: maxFrames)
                self.state = .done(name)
            } catch is CancellationError {
                self.state = .failed("Stopped")
            } catch {
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    @available(iOS 17.0, *)
    private func run(video: URL, title: String, fps: Double, maxFrames: Int) async throws -> String {
        guard PhotogrammetrySession.isSupported else {
            throw TrainError("This phone cannot run Apple's photogrammetry (needs an iPhone Pro with LiDAR)")
        }
        started = Date()
        stepStarted = Date()
        log = []
        state = .working("Reading the video…", nil)
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let folderName = "v" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(9)).lowercased()
        let folder = documents.appendingPathComponent(folderName, isDirectory: true)
        let framesDir = folder.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)

        // Frames: upright, longest side ≤ 1440, about `fps` per second (at most maxFrames). Each slot takes the
        // sharpest of 3 nearby frames (motion blur is what makes the engine lose track), and only the JPEGs are
        // kept in memory-light form: the engine reads them one by one.
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 1 else { throw TrainError("The video is too short") }
        let count = min(maxFrames, max(30, Int(duration * fps)))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1440, height: 1440)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.02, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.02, preferredTimescale: 600)
        var times: [Double] = []
        var imageSize = CGSize.zero
        let slot = duration / Double(count)
        for i in 0..<count {
            try Task.checkCancellation()
            var best: (CGImage, Double, Double)?
            for k in 0..<3 {
                let t = (Double(i) + (Double(k) + 0.5) / 3) * slot
                guard let cg = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image else { continue }
                let sharp = PhoneVideoAligner.sharpness(cg)
                if best == nil || sharp > best!.1 { best = (cg, sharp, t) }
            }
            guard let (cg, _, t) = best else { continue }
            imageSize = CGSize(width: cg.width, height: cg.height)
            let jpg = framesDir.appendingPathComponent(String(format: "%06d.jpg", times.count))
            guard let data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.92) else { continue }
            try data.write(to: jpg)
            times.append(t)
            state = .working("Taking the sharpest frames \(times.count) / \(count)", Double(i + 1) / Double(count) * 0.2)
        }
        let frameDir = framesDir
        let ciContext = CIContext()
        let samples = (0..<times.count).lazy.compactMap { id -> PhotogrammetrySample? in
            guard let image = UIImage(contentsOfFile: frameDir.appendingPathComponent(String(format: "%06d.jpg", id)).path)?.cgImage,
                  let buffer = PhoneVideoAligner.pixelBuffer(image, context: ciContext) else { return nil }
            return PhotogrammetrySample(id: id, image: buffer)
        }
        guard times.count >= 12 else { throw TrainError("Could not read enough frames from the video") }
        // Copy the video itself (thumbnail, playback, sending to the PC later).
        // (Named rgb.mp4 like a LiDAR scan so thumbnails and replay find it; AVFoundation reads MOV content fine.)
        let rgb = folder.appendingPathComponent("rgb.mp4")
        try? FileManager.default.copyItem(at: video, to: rgb)

        note("\(times.count) sharp frames taken, \(Int(imageSize.width))×\(Int(imageSize.height)) px")
        state = .working("Finding the camera path…", 0.2)
        stepStarted = Date()
        var configuration = PhotogrammetrySession.Configuration()
        configuration.sampleOrdering = .sequential
        configuration.featureSensitivity = .high
        let session = try PhotogrammetrySession(input: samples, configuration: configuration)
        try session.process(requests: [.poses, .pointCloud])
        var poses: PhotogrammetrySession.Poses?
        var cloud: PhotogrammetrySession.PointCloud?
        var failure: String?
        // Two requests run one after the other: camera path (poses), then the sparse points.
        var lastStage = ""
        var lastPercent = -1
        outputs: for try await output in session.outputs {
            if Task.isCancelled { session.cancel(); throw CancellationError() }
            switch output {
            case .requestProgress(let request, let fraction):
                let isPoses: Bool
                if case .poses = request { isPoses = true } else { isPoses = false }
                let overall = isPoses ? 0.2 + 0.6 * fraction : 0.8 + 0.2 * fraction
                state = .working(isPoses ? "Finding the camera path…" : "Making the starting points…", overall)
                let percent = Int(fraction * 100)
                if percent / 25 != lastPercent / 25 {
                    lastPercent = percent
                    note((isPoses ? "camera path " : "points ") + "\(percent)%")
                }
            case .requestProgressInfo(_, let info):
                let stage = info.processingStage.map { "\($0)" } ?? ""
                if !stage.isEmpty, stage != lastStage {
                    lastStage = stage
                    var line = "stage: " + stage
                    if let left = info.estimatedRemainingTime, left > 1 { line += String(format: " · ~%.0f s left", left) }
                    note(line)
                }
            case .requestComplete(_, let result):
                switch result {
                case .poses(let p):
                    poses = p
                    note("camera path done: \(p.posesBySample.count) of \(times.count) frames placed")
                    if p.posesBySample.count < times.count * 6 / 10 {
                        // Where did it lose track? (first frame after the longest placed run)
                        let placed = Set(p.posesBySample.keys)
                        var run = 0, bestRun = 0, bestEnd = 0
                        for id in 0..<times.count { if placed.contains(id) { run += 1; if run > bestRun { bestRun = run; bestEnd = id } } else { run = 0 } }
                        let lost = min(bestEnd + 1, times.count - 1)
                        note(String(format: "lost track near %d:%02d in the video (moved too fast / too little overlap)",
                                    Int(times[lost]) / 60, Int(times[lost]) % 60))
                    }
                    state = .working("Making the starting points…", 0.8)
                    stepStarted = Date()
                case .pointCloud(let c):
                    cloud = c
                    note("points done: \(c.points.count)")
                default: break
                }
            case .requestError(let request, let error):
                if case .pointCloud = request {
                    note("points failed (\(error.localizedDescription)))")
                } else {
                    failure = error.localizedDescription
                    note("camera path failed: " + error.localizedDescription)
                }
            case .invalidSample(let id, let reason):
                note("frame \(id) skipped: \(reason)")
            case .skippedSample(let id):
                note("frame \(id) skipped")
            case .processingComplete:
                break outputs          // the stream does not always end by itself
            case .processingCancelled:
                throw CancellationError()
            default:
                break
            }
        }
        state = .working("Writing the scan…", 1)
        guard let found = poses, found.posesBySample.count >= 8 else {
            try? FileManager.default.removeItem(at: folder)
            throw TrainError("Alignment failed" + (failure.map { ": \($0)" } ?? " — too few frames matched")
                             + ". Try a slower video with more overlap, or send it to the PC.")
        }

        // Scale: the engine's units are arbitrary for plain video; make the median camera-to-point distance 2 m so
        // the trainer's sizes (mm … cm) fit.
        var scale: Float = 1
        let points = cloud?.points ?? []
        if !points.isEmpty {
            let centres = found.posesBySample.values.map { $0.translation }
            var distances: [Float] = []
            for (k, p) in points.enumerated() where k % max(points.count / 2000, 1) == 0 {
                if let c = centres.min(by: { simd_distance($0, p.position) < simd_distance($1, p.position) }) {
                    distances.append(simd_distance(c, p.position))
                }
            }
            distances.sort()
            if let median = distances.dropFirst(distances.count / 2).first, median > 1e-6 { scale = 2 / median }
        }

        // odometry.csv (same columns and OpenCV convention as Stray scans: camera x right, y down, z forward).
        let w = Float(imageSize.width), h = Float(imageSize.height)
        let defaultFocal = max(w, h) * 26 / 36           // iPhone main camera, 26 mm equivalent
        var csv = "timestamp, frame, x, y, z, qx, qy, qz, qw, fx, fy, cx, cy, distortion_center_x, distortion_center_y\n"
        let toCV = simd_quatf(ix: 1, iy: 0, iz: 0, r: 0)  // ARKit/RealityKit camera → OpenCV camera (as OdometryEncoder)
        for id in found.posesBySample.keys.sorted() {
            guard let pose = found.posesBySample[id] else { continue }
            let t = pose.translation * scale
            let q = (pose.rotation * toCV).vector
            var fx = defaultFocal, fy = defaultFocal, cx = w / 2, cy = h / 2
            if #available(iOS 26.0, *), let k = pose.intrinsics {
                fx = k.columns.0.x; fy = k.columns.1.y; cx = k.columns.2.x; cy = k.columns.2.y
            }
            csv += "\(id < times.count ? times[id] : Double(id) / fps), \(String(format: "%06d", id)), \(t.x), \(t.y), \(t.z), \(q.x), \(q.y), \(q.z), \(q.w), "
                + "\(fx), \(fy), \(cx), \(cy), , \n"
        }
        try csv.write(to: folder.appendingPathComponent("odometry.csv"), atomically: true, encoding: .utf8)
        var binary = Data(capacity: points.count * 24)
        for p in points {
            var row: [Float] = [p.position.x * scale, p.position.y * scale, p.position.z * scale,
                                Float(p.color.x) / 255, Float(p.color.y) / 255, Float(p.color.z) / 255]
            binary.append(Data(bytes: &row, count: 24))
        }
        try binary.write(to: folder.appendingPathComponent("points.bin"))
        let settings: [String: Any] = ["source": "phone_aligned_video", "video_width": Int(w), "video_height": Int(h),
                                       "frames_dir": "frames", "aligned_frames": found.posesBySample.count,
                                       "frames_taken": times.count, "points": points.count, "scale_to_metres": scale,
                                       "alignment": "RealityKit PhotogrammetrySession (on the phone)", "video_frame_offset": 0]
        let json = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: folder.appendingPathComponent("capture_settings.json"))

        // Show it in the Scans list (its own name), so "Train here" works on it like on a LiDAR scan.
        let context2 = (UIApplication.shared.delegate as! AppDelegate).persistentContainer.viewContext
        let entity = NSEntityDescription.entity(forEntityName: "Recording", in: context2)!
        let recording = Recording(entity: entity, insertInto: context2)
        recording.id = UUID()
        recording.name = "Video: " + title
        recording.createdAt = Date()
        recording.duration = duration
        recording.rgbFilePath = "\(folderName)/\(rgb.lastPathComponent)"
        recording.depthFilePath = "\(folderName)/frames/"
        try context2.save()
        NotificationCenter.default.post(name: NSNotification.Name("sessionsChanged"), object: nil)
        try? FileManager.default.removeItem(at: video)
        return "\(found.posesBySample.count) of \(times.count) frames aligned · \(points.count) points"
    }

    private static func pixelBuffer(_ image: CGImage, context: CIContext) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true,
                                           kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                                           kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
        guard let out = buffer else { return nil }
        context.render(CIImage(cgImage: image), to: out)
        return out
    }
}

extension ScanData {
    /// A video aligned on the phone (PhoneVideoAligner) instead of a LiDAR scan.
    static func isAlignedVideo(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("points.bin").path)
            && FileManager.default.fileExists(atPath: folder.appendingPathComponent("frames").path)
    }
}
