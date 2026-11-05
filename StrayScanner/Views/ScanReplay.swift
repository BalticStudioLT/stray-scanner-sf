//
//  ScanReplay.swift
//  Stray SF
//
//  Plays a finished scan with every view in sync: camera video, LiDAR depth, LiDAR confidence and a
//  top-down map (room points + camera path + where the phone is now), plus a blur timeline to scrub.
//  Tap a small view to swap it with the big one, as in the recorder.
//

import SwiftUI
import AVKit
import simd

enum ReplayView: String, CaseIterable, Identifiable {
    case camera, depth, confidence, map
    var id: String { rawValue }
    var title: String {
        switch self {
        case .camera: return "Camera"
        case .depth: return "Depth"
        case .confidence: return "Confidence"
        case .map: return "Map"
        }
    }
    var symbol: String {
        switch self {
        case .camera: return "camera"
        case .depth: return "square.3.layers.3d.down.right"
        case .confidence: return "checkmark.seal"
        case .map: return "map"
        }
    }
}

struct OdometryRow {
    let frame: Int
    let position: SIMD3<Float>
    let rotation: simd_quatf
    let fx, fy, cx, cy: Float
}

final class ScanReplayModel: ObservableObject {
    let folder: URL
    let player: AVPlayer
    @Published var frame: Int = 0
    @Published var playing = false
    @Published var depthImage: UIImage?
    @Published var confidenceImage: UIImage?
    @Published var mapImage: UIImage?
    @Published var mapLoading = true
    @Published var duration: Double = 1
    private(set) var poses: [Int: OdometryRow] = [:]
    private(set) var orderedPoses: [OdometryRow] = []
    private(set) var blur: [Float] = []
    private(set) var videoFPS: Double = 60
    private var frameOffset = 0
    private var rgbWidth: Float = 1920
    private var observer: Any?
    private let loadQueue = DispatchQueue(label: "replay.load", qos: .userInitiated)
    private var lastLoadedFrame = -1
    /// Map extent (world x/z) and pixels per metre, to place the live marker on the map image.
    private(set) var mapOrigin = SIMD2<Float>(0, 0)
    private(set) var mapScale: Float = 1
    private(set) var mapSize = CGSize(width: 1, height: 1)

    init(folder: URL) {
        self.folder = folder
        self.player = AVPlayer(url: folder.appendingPathComponent("rgb.mp4"))
        readSettings()
        readOdometry()
        readBlur()
        let interval = CMTime(value: 1, timescale: 30)
        observer = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.timeChanged(time.seconds)
        }
        if let item = player.currentItem {
            Task { @MainActor [weak self] in
                if let d = try? await item.asset.load(.duration), d.seconds.isFinite {
                    self?.duration = max(d.seconds, 0.1)
                }
            }
        }
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in
            self?.playing = false
        }
        loadFrame(0)
        buildMap()
    }

    deinit {
        if let observer = observer { player.removeTimeObserver(observer) }
    }

    var frameCount: Int { max(Int(duration * videoFPS), 1) }

    func togglePlay() {
        if playing { player.pause() } else {
            if player.currentTime().seconds >= duration - 0.05 { player.seek(to: .zero) }
            player.play()
        }
        playing.toggle()
    }

    func seek(fraction: Double) {
        let t = max(0, min(1, fraction)) * duration
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        timeChanged(t)
    }

    func step(_ frames: Int) {
        if playing { togglePlay() }
        let t = (Double(frame + frameOffset + frames) + 0.01) / videoFPS
        seek(fraction: t / duration)
    }

    private func timeChanged(_ seconds: Double) {
        guard seconds.isFinite else { return }
        // Video frame i (PTS i/fps) is dataset row i - offset (offset 1 for scans made before the fix).
        let f = max(Int((seconds * videoFPS).rounded(.down)) - frameOffset, 0)
        if f != frame { frame = f; loadFrame(f) }
    }

    // MARK: - Files

    private func readSettings() {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("capture_settings.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            frameOffset = 1
            return
        }
        if let fps = json["video_fps"] as? Double, fps > 0 { videoFPS = fps }
        else if let fps = json["video_fps"] as? Int, fps > 0 { videoFPS = Double(fps) }
        frameOffset = json["video_frame_offset"] == nil ? 1 : 0
        if let w = json["video_width"] as? Int, w > 0 { rgbWidth = Float(w) }
    }

    private func readOdometry() {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("odometry.csv"), encoding: .utf8) else { return }
        var rows: [OdometryRow] = []
        for line in text.split(separator: "\n").dropFirst() {
            let v = line.split(separator: ",").map { Float($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
            guard v.count >= 13 else { continue }
            let row = OdometryRow(frame: Int(v[1]), position: SIMD3(v[2], v[3], v[4]),
                                  rotation: simd_quatf(ix: v[5], iy: v[6], iz: v[7], r: v[8]),
                                  fx: v[9], fy: v[10], cx: v[11], cy: v[12])
            rows.append(row)
        }
        orderedPoses = rows
        poses = Dictionary(rows.map { ($0.frame, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func readBlur() {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("frame_quality.csv"), encoding: .utf8) else { return }
        var values: [Float] = []
        for line in text.split(separator: "\n").dropFirst() {
            let f = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if f.count > 6 { values.append(Float(f[6]) ?? 0) }
        }
        blur = values
    }

    private func loadFrame(_ f: Int) {
        let name = String(format: "%06d.png", f)
        let depthURL = folder.appendingPathComponent("depth").appendingPathComponent(name)
        let confURL = folder.appendingPathComponent("confidence").appendingPathComponent(name)
        loadQueue.async { [weak self] in
            guard let self = self, f != self.lastLoadedFrame else { return }
            self.lastLoadedFrame = f
            let depth = DepthPNG.load(depthURL).map { DepthPNG.colorize($0) }
            let conf = DepthPNG.loadConfidence(confURL)
            DispatchQueue.main.async {
                guard self.frame == f else { return }
                self.depthImage = depth ?? self.depthImage
                self.confidenceImage = conf ?? self.confidenceImage
            }
        }
    }

    /// Top-down map: LiDAR points from every ~10th frame (ceiling cut), the camera path on top. Built once.
    private func buildMap() {
        let poses = orderedPoses
        let folder = self.folder
        let rgbWidth = self.rgbWidth
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard !poses.isEmpty else {
                DispatchQueue.main.async { self?.mapLoading = false }
                return
            }
            var points: [SIMD3<Float>] = []
            let step = max(poses.count / 250, 1)
            for i in Swift.stride(from: 0, to: poses.count, by: step) {
                let p = poses[i]
                let url = folder.appendingPathComponent("depth").appendingPathComponent(String(format: "%06d.png", p.frame))
                guard let d = DepthPNG.load(url) else { continue }
                let s = Float(d.width) / rgbWidth
                let fx = p.fx * s, fy = p.fy * s, cx = p.cx * s, cy = p.cy * s
                for v in Swift.stride(from: 0, to: d.height, by: 6) {
                    for u in Swift.stride(from: 0, to: d.width, by: 6) {
                        let z = Float(d.mm[v * d.width + u]) / 1000
                        guard z > 0.2, z < 6 else { continue }
                        let c = SIMD3<Float>((Float(u) - cx) * z / fx, (Float(v) - cy) * z / fy, z)
                        let w = p.rotation.act(c) + p.position
                        if w.y < p.position.y + 0.3 { points.append(w) }   // cut the ceiling away
                    }
                }
            }
            let path = poses.map { SIMD2($0.position.x, $0.position.z) }
            let all = points.map { SIMD2($0.x, $0.z) } + path
            var lo = all.reduce(SIMD2<Float>(repeating: .greatestFiniteMagnitude)) { simd_min($0, $1) }
            var hi = all.reduce(SIMD2<Float>(repeating: -.greatestFiniteMagnitude)) { simd_max($0, $1) }
            lo -= 0.3; hi += 0.3
            let side: Float = 900
            let scale = side / max(hi.x - lo.x, hi.y - lo.y)
            let size = CGSize(width: CGFloat((hi.x - lo.x) * scale), height: CGFloat((hi.y - lo.y) * scale))
            let floorY = points.map { $0.y }.sorted().dropFirst(points.count / 50).first ?? 0
            let renderer = UIGraphicsImageRenderer(size: size)
            let image = renderer.image { ctx in
                UIColor(white: 0.06, alpha: 1).setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
                for p in points {
                    // Height above the floor → colour (floor dark blue, walls/furniture warmer).
                    let h = max(0, min(1, (p.y - floorY) / 2.2))
                    UIColor(hue: CGFloat(0.62 - 0.55 * h), saturation: 0.7, brightness: CGFloat(0.45 + 0.5 * h), alpha: 0.5).setFill()
                    ctx.fill(CGRect(x: CGFloat((p.x - lo.x) * scale) - 1, y: CGFloat((p.z - lo.y) * scale) - 1, width: 2, height: 2))
                }
                let line = UIBezierPath()
                for (i, q) in path.enumerated() {
                    let pt = CGPoint(x: CGFloat((q.x - lo.x) * scale), y: CGFloat((q.y - lo.y) * scale))
                    if i == 0 { line.move(to: pt) } else { line.addLine(to: pt) }
                }
                UIColor.white.withAlphaComponent(0.55).setStroke()
                line.lineWidth = 2
                line.stroke()
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.mapOrigin = lo
                self.mapScale = scale
                self.mapSize = size
                self.mapImage = image
                self.mapLoading = false
            }
        }
    }

    /// Where the phone is (map image pixels) and which way it looks, for the current frame.
    func mapMarker() -> (CGPoint, Angle)? {
        guard let p = poses[frame] ?? nearestPose() else { return nil }
        let pt = CGPoint(x: CGFloat((p.position.x - mapOrigin.x) * mapScale), y: CGFloat((p.position.z - mapOrigin.y) * mapScale))
        let forward = p.rotation.act(SIMD3<Float>(0, 0, 1))   // OpenCV camera looks +Z
        return (pt, Angle(radians: Double(atan2(forward.z, forward.x))))
    }

    private func nearestPose() -> OdometryRow? {
        guard !orderedPoses.isEmpty else { return nil }
        var lo = 0, hi = orderedPoses.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if orderedPoses[mid].frame < frame { lo = mid + 1 } else { hi = mid }
        }
        return orderedPoses[lo]
    }
}

// MARK: - Depth PNG decoding

enum DepthPNG {
    struct Depth { let width: Int; let height: Int; let mm: [UInt16] }

    static func load(_ url: URL) -> Depth? {
        guard let image = UIImage(contentsOfFile: url.path)?.cgImage else { return nil }
        let w = image.width, h = image.height
        var mm = [UInt16](repeating: 0, count: w * h)
        guard let space = CGColorSpace(name: CGColorSpace.linearGray),
              let ctx = CGContext(data: &mm, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 2, space: space,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Depth(width: w, height: h, mm: mm)
    }

    static func colorize(_ d: Depth, maxMetres: Float = 5) -> UIImage? {
        var rgba = [UInt8](repeating: 0, count: d.width * d.height * 4)
        for i in 0..<(d.width * d.height) {
            let z = Float(d.mm[i]) / 1000
            if z <= 0 { rgba[i * 4 + 3] = 255; continue }
            let c = turbo(min(z / maxMetres, 1))
            rgba[i * 4] = c.0; rgba[i * 4 + 1] = c.1; rgba[i * 4 + 2] = c.2; rgba[i * 4 + 3] = 255
        }
        return image(rgba, d.width, d.height)
    }

    static func loadConfidence(_ url: URL) -> UIImage? {
        guard let image = UIImage(contentsOfFile: url.path)?.cgImage else { return nil }
        let w = image.width, h = image.height
        var raw = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &raw, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Stored as 0/1/2 (low/medium/high). Some exports scale to 0..255 — accept both.
        let maxValue = raw.max() ?? 2
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) {
            let level = maxValue > 2 ? Int(raw[i]) * 2 / Int(maxValue) : Int(raw[i])
            let c: (UInt8, UInt8, UInt8) = level >= 2 ? (60, 200, 90) : (level == 1 ? (240, 200, 40) : (220, 50, 50))
            rgba[i * 4] = c.0; rgba[i * 4 + 1] = c.1; rgba[i * 4 + 2] = c.2
        }
        return self.image(rgba, w, h)
    }

    private static func image(_ rgba: [UInt8], _ w: Int, _ h: Int) -> UIImage? {
        var data = rgba
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cg = ctx.makeImage() else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Google's Turbo colormap (polynomial fit), t in 0…1 → near = blue, far = red.
    static func turbo(_ t: Float) -> (UInt8, UInt8, UInt8) {
        let x = max(0, min(1, t))
        let r = 0.13572138 + x * (4.61539260 + x * (-42.66032258 + x * (132.13108234 + x * (-152.94239396 + x * 59.28637943))))
        let g = 0.09140261 + x * (2.19418839 + x * (4.84296658 + x * (-14.18503333 + x * (4.27729857 + x * 2.82956604))))
        let b = 0.10667330 + x * (12.64194608 + x * (-60.58204836 + x * (110.36276771 + x * (-89.90310912 + x * 27.34824973))))
        func c(_ v: Float) -> UInt8 { UInt8(max(0, min(255, v * 255))) }
        return (c(r), c(g), c(b))
    }
}

// MARK: - Screen

struct ScanReplayView: View {
    @StateObject private var model: ScanReplayModel
    @State private var main: ReplayView = .camera
    @State private var insets: [ReplayView] = [.depth, .confidence, .map]

    init(folder: URL) {
        _model = StateObject(wrappedValue: ScanReplayModel(folder: folder))
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            VStack(spacing: 12) {
                panel(main, big: true)
                    .frame(width: w, height: min(w * 4 / 3, geo.size.height * 0.62))
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(alignment: .topLeading) { label(main).padding(10) }

                HStack(spacing: 10) {
                    ForEach(Array(insets.enumerated()), id: \.element) { index, view in
                        panel(view, big: false)
                            .frame(height: (w - 32) / 3 * 4 / 3)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(alignment: .bottomLeading) { label(view).scaleEffect(0.8, anchor: .bottomLeading).padding(4) }
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.15)))
                            .onTapGesture {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    insets[index] = main
                                    main = view
                                }
                            }
                    }
                }
                .padding(.horizontal, 12)

                timeline
                    .padding(.horizontal, 16)

                HStack(spacing: 28) {
                    Button { model.step(-Int(model.videoFPS)) } label: { Image(systemName: "gobackward.1") }
                    Button { model.step(-1) } label: { Image(systemName: "backward.frame") }
                    Button { model.togglePlay() } label: {
                        Image(systemName: model.playing ? "pause.fill" : "play.fill").font(.title2)
                    }
                    .glassButton(prominent: true)
                    Button { model.step(1) } label: { Image(systemName: "forward.frame") }
                    Button { model.step(Int(model.videoFPS)) } label: { Image(systemName: "goforward.1") }
                }
                .font(.title3)
                .foregroundStyle(.white)
                Spacer(minLength: 0)
            }
        }
        .background(Color("BackgroundColor").ignoresSafeArea())
        .navigationTitle("Replay")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { model.player.pause() }
    }

    private func label(_ view: ReplayView) -> some View {
        Label(view.title, systemImage: view.symbol)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
    }

    @ViewBuilder
    private func panel(_ view: ReplayView, big: Bool) -> some View {
        GeometryReader { g in
            ZStack {
                Color.black
                switch view {
                case .camera:
                    upright(g.size) { PlayerLayerView(player: model.player) }
                case .depth:
                    upright(g.size) { imageView(model.depthImage) }
                case .confidence:
                    upright(g.size) { imageView(model.confidenceImage) }
                case .map:
                    mapView(g.size)
                }
            }
        }
    }

    /// Scan images are landscape (sensor orientation); show them upright as the phone was held.
    private func upright<Content: View>(_ size: CGSize, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(width: size.height, height: size.width)
            .rotationEffect(.degrees(90))
            .frame(width: size.width, height: size.height)
    }

    private func imageView(_ image: UIImage?) -> some View {
        Group {
            if let image = image {
                Image(uiImage: image).resizable().interpolation(.none).aspectRatio(contentMode: .fill)
            } else {
                Text("No LiDAR data").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func mapView(_ size: CGSize) -> some View {
        ZStack {
            if let map = model.mapImage {
                let fit = min(size.width / model.mapSize.width, size.height / model.mapSize.height)
                ZStack(alignment: .topLeading) {
                    Image(uiImage: map).resizable()
                    if let marker = model.mapMarker() {
                        let pt = marker.0, angle = marker.1
                        Image(systemName: "location.north.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.yellow)
                            .shadow(radius: 3)
                            .rotationEffect(angle + .degrees(90))
                            .position(x: pt.x * fit, y: pt.y * fit)
                    }
                }
                .frame(width: model.mapSize.width * fit, height: model.mapSize.height * fit)
            } else if model.mapLoading {
                ProgressView("Building map…").font(.caption)
            } else {
                Text("No poses").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    /// Blur per frame (green sharp → red blurry) with the play head; drag to scrub.
    private var timeline: some View {
        GeometryReader { g in
            let n = max(model.blur.count, 1)
            ZStack(alignment: .leading) {
                Canvas { ctx, size in
                    let buckets = Int(size.width / 2)
                    for b in 0..<max(buckets, 1) {
                        let i0 = b * n / buckets, i1 = max((b + 1) * n / buckets, i0 + 1)
                        let slice = model.blur.isEmpty ? [Float(0)] : Array(model.blur[min(i0, n - 1)..<min(i1, n)])
                        let worst = slice.max() ?? 0
                        let color: Color = worst <= 1.5 ? .green : (worst <= 3 ? .yellow : .red)
                        let h = CGFloat(min(worst / 6, 1)) * (size.height - 4) + 4
                        ctx.fill(Path(CGRect(x: CGFloat(b) * 2, y: size.height - h, width: 1.5, height: h)), with: .color(color.opacity(0.8)))
                    }
                }
                let x = g.size.width * CGFloat(Double(model.frame) / Double(max(model.frameCount, 1)))
                Rectangle().fill(.white).frame(width: 2).offset(x: min(max(x, 0), g.size.width - 2))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                if model.playing { model.togglePlay() }
                model.seek(fraction: Double(v.location.x / g.size.width))
            })
        }
        .frame(height: 44)
        .overlay(alignment: .topTrailing) {
            Text("frame \(model.frame) · blur \(model.blur.indices.contains(model.frame) ? String(format: "%.1f px", model.blur[model.frame]) : "–")")
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                .offset(y: -16)
        }
    }
}

/// AVPlayerLayer without the system controls (the replay screen has its own).
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class PlayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
    }
}
