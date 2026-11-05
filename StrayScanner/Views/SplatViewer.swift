//
//  SplatViewer.swift
//  StrayScanner
//
//  View finished Gaussian splats on the phone (stray-scanner-sf fork): orbit view or AR
//  (tap a surface to place the splat; 1:1 to walk inside it, or 1:10 / 1:50 as a model).
//  Own renderer (Metal only, no third-party code): EWA projection of each splat's 3D covariance
//  in gsVertex/gsFragment (Shaders.metal), back-to-front order from a background bucket sort.
//  Sources: SplatForge Studio's /api/splat (works with today's Studio) or a 3DGS .ply from Files.
//

import SwiftUI
import MetalKit
import ARKit
import simd

// MARK: - Data

enum SplatSource: Equatable, Identifiable {
    /// `sourceScan`: Stray folder the splat was trained from; SplatForge keeps its ARKit coordinates
    /// (scan_to_splat = identity), so AR can show the splat exactly where it was scanned.
    case studio(ply: String, title: String, sourceScan: String?)
    case file(URL)

    var id: String {
        switch self {
        case .studio(let ply, _, _): return "studio:" + ply
        case .file(let url): return "file:" + url.absoluteString
        }
    }

    var title: String {
        switch self {
        case .studio(_, let title, _): return title
        case .file(let url): return url.lastPathComponent
        }
    }

    /// The scan's world map on this phone, if the scan was recorded here and the map was saved.
    var worldMapURL: URL? {
        guard case .studio(_, _, let scan?) = self,
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let url = documents.appendingPathComponent(scan).appendingPathComponent(DatasetEncoder.worldMapFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// Splats packed for the GPU: 32 bytes each = float3 position, 6 × half covariance, rgba8, padding.
final class SplatData {
    let count: Int
    let buffer: MTLBuffer
    let positions: [SIMD3<Float>]
    let center: SIMD3<Float>
    let radius: Float
    let floorY: Float

    init(count: Int, buffer: MTLBuffer, positions: [SIMD3<Float>]) {
        self.count = count
        self.buffer = buffer
        self.positions = positions
        // Robust framing: trained splats always have a few floaters very far away, so use the median and the
        // 5th–95th percentile per axis instead of the mean and the full bounding box.
        var xs: [Float] = [], ys: [Float] = [], zs: [Float] = []
        let stride = max(count / 60_000, 1)
        var i = 0
        while i < count {
            let p = positions[i]
            if p.x.isFinite && p.y.isFinite && p.z.isFinite { xs.append(p.x); ys.append(p.y); zs.append(p.z) }
            i += stride
        }
        xs.sort(); ys.sort(); zs.sort()
        func pick(_ a: [Float], _ f: Float) -> Float { a.isEmpty ? 0 : a[min(Int(Float(a.count - 1) * f), a.count - 1)] }
        center = SIMD3(pick(xs, 0.5), pick(ys, 0.5), pick(zs, 0.5))
        let lo = SIMD3(pick(xs, 0.05), pick(ys, 0.05), pick(zs, 0.05))
        let hi = SIMD3(pick(xs, 0.95), pick(ys, 0.95), pick(zs, 0.95))
        floorY = pick(ys, 0.02)
        radius = max(simd_length(hi - lo) * 0.5, 0.5)
    }
}

enum SplatLoaderError: LocalizedError {
    case bad(String)
    var errorDescription: String? {
        if case .bad(let text) = self { return text }
        return nil
    }
}

enum SplatLoader {
    static let stride = 32

    /// SplatForge Studio /api/splat: u32 N, u32 pad×3 | f32 pos[N×3] | f16 cov[N×6] | u8 rgba[N×4].
    static func loadFromStudio(ply: String, maxSplats: Int, device: MTLDevice,
                               progress: @escaping (String) -> Void) async throws -> SplatData {
        let settings = PCLinkSettings.load()
        guard let url = settings.url("/api/splat", query: ["ply": ply, "max": String(maxSplats)]) else {
            throw SplatLoaderError.bad("Set the PC address first")
        }
        var request = URLRequest(url: url, timeoutInterval: 300)
        request.setValue(settings.token, forHTTPHeaderField: "X-Token")
        progress("Downloading from the PC…")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw SplatLoaderError.bad(http.statusCode == 403 ? "Wrong Studio token" : "PC answered \(http.statusCode)")
        }
        progress("Preparing \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))…")
        return try decodeStudio(data, device: device)
    }

    static func decodeStudio(_ data: Data, device: MTLDevice) throws -> SplatData {
        guard data.count >= 16 else { throw SplatLoaderError.bad("Empty splat") }
        let n = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) })
        let posBytes = n * 12, covBytes = n * 12
        guard n > 0, data.count >= 16 + posBytes + covBytes + n * 4 else { throw SplatLoaderError.bad("Splat data is cut off") }
        guard let buffer = device.makeBuffer(length: n * stride, options: .storageModeShared) else {
            throw SplatLoaderError.bad("Not enough GPU memory")
        }
        var positions = [SIMD3<Float>](repeating: .zero, count: n)
        let out = buffer.contents()
        data.withUnsafeBytes { bytes in
            let base = bytes.baseAddress!
            for i in 0..<n {
                let p = base.advanced(by: 16 + i * 12)
                let x = p.loadUnaligned(as: Float.self)
                let y = p.loadUnaligned(fromByteOffset: 4, as: Float.self)
                let z = p.loadUnaligned(fromByteOffset: 8, as: Float.self)
                positions[i] = SIMD3<Float>(x, y, z)
                let o = out.advanced(by: i * stride)
                o.storeBytes(of: x, toByteOffset: 0, as: Float.self)
                o.storeBytes(of: y, toByteOffset: 4, as: Float.self)
                o.storeBytes(of: z, toByteOffset: 8, as: Float.self)
                o.advanced(by: 12).copyMemory(from: base.advanced(by: 16 + posBytes + i * 12), byteCount: 12)
                o.advanced(by: 24).copyMemory(from: base.advanced(by: 16 + posBytes + covBytes + i * 4), byteCount: 4)
            }
        }
        return SplatData(count: n, buffer: buffer, positions: positions)
    }

    /// Standard 3D Gaussian Splatting PLY (binary little endian, float properties:
    /// x y z, f_dc_0..2, opacity, scale_0..2, rot_0..3 (w first); other properties ignored).
    static func loadPLY(_ url: URL, device: MTLDevice, maxSplats: Int) throws -> SplatData {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let headerEnd = data.range(of: Data("end_header\n".utf8)) else { throw SplatLoaderError.bad("Not a PLY file") }
        let header = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
        guard header.contains("binary_little_endian") else { throw SplatLoaderError.bad("Only binary little-endian PLY is supported") }
        var count = 0
        var properties: [String] = []
        var inVertex = false
        for line in header.split(separator: "\n") {
            let parts = line.split(separator: " ")
            if parts.first == "element" {
                inVertex = parts.count >= 3 && parts[1] == "vertex"
                if inVertex { count = Int(parts[2]) ?? 0 }
            } else if parts.first == "property", inVertex {
                guard parts.count >= 3, parts[1] == "float" else { throw SplatLoaderError.bad("Unsupported PLY property type: \(line)") }
                properties.append(String(parts[2]))
            }
        }
        func index(_ name: String) throws -> Int {
            guard let i = properties.firstIndex(of: name) else { throw SplatLoaderError.bad("PLY has no \(name) — not a Gaussian splat?") }
            return i
        }
        let ix = try index("x"), iy = try index("y"), iz = try index("z")
        let dc = [try index("f_dc_0"), try index("f_dc_1"), try index("f_dc_2")]
        let iop = try index("opacity")
        let sc = [try index("scale_0"), try index("scale_1"), try index("scale_2")]
        let rot = [try index("rot_0"), try index("rot_1"), try index("rot_2"), try index("rot_3")]
        let rowBytes = properties.count * 4
        let start = headerEnd.upperBound
        guard count > 0, data.count >= start + count * rowBytes else { throw SplatLoaderError.bad("PLY is cut off") }
        let step = max(1, count / max(maxSplats, 1))
        let n = (count + step - 1) / step
        guard let buffer = device.makeBuffer(length: n * stride, options: .storageModeShared) else {
            throw SplatLoaderError.bad("Not enough GPU memory")
        }
        var positions = [SIMD3<Float>](repeating: .zero, count: n)
        let out = buffer.contents()
        let c0: Float = 0.28209479177387814
        data.withUnsafeBytes { bytes in
            let base = bytes.baseAddress!.advanced(by: start)
            for k in 0..<n {
                let row = base.advanced(by: k * step * rowBytes)
                func f(_ i: Int) -> Float { row.loadUnaligned(fromByteOffset: i * 4, as: Float.self) }
                let p = SIMD3<Float>(f(ix), f(iy), f(iz))
                positions[k] = p
                var q = simd_quatf(ix: f(rot[1]), iy: f(rot[2]), iz: f(rot[3]), r: f(rot[0]))
                q = simd_length(q.vector) > 0 ? simd_normalize(q) : simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
                let s = SIMD3<Float>(exp(f(sc[0])), exp(f(sc[1])), exp(f(sc[2])))
                let m = simd_float3x3(q) * simd_float3x3(diagonal: s)
                let cov = m * m.transpose
                let opacity = 1 / (1 + exp(-f(iop)))
                let o = out.advanced(by: k * stride)
                o.storeBytes(of: p.x, toByteOffset: 0, as: Float.self)
                o.storeBytes(of: p.y, toByteOffset: 4, as: Float.self)
                o.storeBytes(of: p.z, toByteOffset: 8, as: Float.self)
                let terms = [cov[0, 0], cov[0, 1], cov[0, 2], cov[1, 1], cov[1, 2], cov[2, 2]]
                for (t, value) in terms.enumerated() {
                    o.storeBytes(of: Float16(value), toByteOffset: 12 + t * 2, as: Float16.self)
                }
                for c in 0..<3 {
                    let v = min(max(0.5 + c0 * f(dc[c]), 0), 1)
                    o.storeBytes(of: UInt8(v * 255), toByteOffset: 24 + c, as: UInt8.self)
                }
                o.storeBytes(of: UInt8(min(max(opacity, 0), 1) * 255), toByteOffset: 27, as: UInt8.self)
            }
        }
        return SplatData(count: n, buffer: buffer, positions: positions)
    }
}

// MARK: - Renderer

private struct GSUniforms {
    var view: simd_float4x4
    var projection: simd_float4x4
    var viewport: SIMD2<Float>
    var focal: SIMD2<Float>
}

/// Draws splats back to front. Sorting runs on a background queue whenever the camera has moved;
/// rendering always uses the newest finished order.
final class GaussianSplatRenderer {
    let splats: SplatData
    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private var orderBuffers: [MTLBuffer]
    private var currentOrder = 0
    private var sorting = false
    private var lastSortedView: simd_float4x4?
    private let sortQueue = DispatchQueue(label: "splat.sort", qos: .userInitiated)
    private let lock = NSLock()
    private var buckets = [UInt32](repeating: 0, count: 65536)
    private var keys: [UInt16] = []

    init?(device: MTLDevice, splats: SplatData, colorFormat: MTLPixelFormat) {
        guard let library = device.makeDefaultLibrary() else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "gsVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "gsFragment")
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = colorFormat
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        var buffers: [MTLBuffer] = []
        for _ in 0..<3 {
            guard let b = device.makeBuffer(length: splats.count * 4, options: .storageModeShared) else { return nil }
            buffers.append(b)
        }
        // Start with the file order so something shows before the first sort finishes.
        let first = buffers[0].contents().bindMemory(to: UInt32.self, capacity: splats.count)
        for i in 0..<splats.count { first[i] = UInt32(i) }
        self.device = device
        self.splats = splats
        self.pipeline = pipeline
        self.orderBuffers = buffers
        keys = [UInt16](repeating: 0, count: splats.count)
    }

    /// Encodes the splats into an existing render encoder (colour target with the renderer's pixel format).
    func draw(_ encoder: MTLRenderCommandEncoder, view: simd_float4x4, projection: simd_float4x4, viewport: CGSize) {
        requestSort(view: view)
        lock.lock()
        let order = orderBuffers[currentOrder]
        lock.unlock()
        var uniforms = GSUniforms(view: view, projection: projection,
                                  viewport: SIMD2<Float>(Float(viewport.width), Float(viewport.height)),
                                  focal: SIMD2<Float>(projection.columns.0.x * Float(viewport.width) * 0.5,
                                                      projection.columns.1.y * Float(viewport.height) * 0.5))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(splats.buffer, offset: 0, index: 0)
        encoder.setVertexBuffer(order, offset: 0, index: 1)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<GSUniforms>.stride, index: 2)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: splats.count)
    }

    private func requestSort(view: simd_float4x4) {
        lock.lock()
        defer { lock.unlock() }
        guard !sorting else { return }
        if let last = lastSortedView {
            let moved = simd_distance(last.columns.3, view.columns.3) + simd_distance(last.columns.2, view.columns.2)
            if moved < 0.01 { return }
        }
        sorting = true
        lastSortedView = view
        let target = (currentOrder + 1) % orderBuffers.count
        sortQueue.async { [weak self] in
            self?.sort(view: view, into: target)
        }
    }

    /// Bucket sort by view-space depth (65 536 buckets), farthest first.
    private func sort(view: simd_float4x4, into target: Int) {
        let n = splats.count
        let r = SIMD4<Float>(view.columns.0.z, view.columns.1.z, view.columns.2.z, view.columns.3.z)
        var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
        splats.positions.withUnsafeBufferPointer { positions in
            for i in 0..<n {
                let p = positions[i]
                let z = r.x * p.x + r.y * p.y + r.z * p.z + r.w
                lo = min(lo, z)
                hi = max(hi, z)
            }
            let scale = hi > lo ? 65535 / (hi - lo) : 0
            keys.withUnsafeMutableBufferPointer { keys in
                buckets.withUnsafeMutableBufferPointer { buckets in
                    for i in 0..<65536 { buckets[i] = 0 }
                    for i in 0..<n {
                        let p = positions[i]
                        let z = r.x * p.x + r.y * p.y + r.z * p.z + r.w
                        let key = UInt16(min(max((z - lo) * scale, 0), 65535))   // more negative z = farther = first
                        keys[i] = key
                        buckets[Int(key)] += 1
                    }
                    var running: UInt32 = 0
                    for i in 0..<65536 {
                        let c = buckets[i]
                        buckets[i] = running
                        running += c
                    }
                    let out = orderBuffers[target].contents().bindMemory(to: UInt32.self, capacity: n)
                    for i in 0..<n {
                        let k = Int(keys[i])
                        out[Int(buckets[k])] = UInt32(i)
                        buckets[k] += 1
                    }
                }
            }
        }
        lock.lock()
        currentOrder = target
        sorting = false
        lock.unlock()
    }
}

// MARK: - Helpers

private func rotationY(_ angle: Float) -> simd_float4x4 {
    let c = cos(angle), s = sin(angle)
    return simd_float4x4(columns: (SIMD4<Float>(c, 0, -s, 0), SIMD4<Float>(0, 1, 0, 0), SIMD4<Float>(s, 0, c, 0), SIMD4<Float>(0, 0, 0, 1)))
}

private func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
    var m = matrix_identity_float4x4
    m.columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)
    return m
}

private func uniformScale(_ s: Float) -> simd_float4x4 {
    return simd_float4x4(diagonal: SIMD4<Float>(s, s, s, 1))
}

/// 180° about X: turns y-down (COLMAP/OpenCV style) scenes upright.
private let flipX = simd_float4x4(diagonal: SIMD4<Float>(1, -1, -1, 1))

private let cameraQuad: [Float] = [
    -1.0, -1.0, 1.0, 1.0,
     1.0, -1.0, 1.0, 0.0,
    -1.0,  1.0, 0.0, 1.0,
     1.0,  1.0, 0.0, 0.0
]

// MARK: - Orbit view

final class OrbitSplatView: MTKView, MTKViewDelegate {
    private var renderer: GaussianSplatRenderer?
    private var commandQueue: MTLCommandQueue?
    private var yaw: Float = 0, pitch: Float = 0.35, distance: Float = 3
    private var target = SIMD3<Float>(0, 0, 0)
    private let inFlight = DispatchSemaphore(value: 3)
    var flipped = false { didSet { if flipped != oldValue { resetCamera() } } }

    init(device: MTLDevice, splats: SplatData) {
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0.03, green: 0.03, blue: 0.04, alpha: 1)
        preferredFramesPerSecond = 60
        commandQueue = device.makeCommandQueue()
        renderer = GaussianSplatRenderer(device: device, splats: splats, colorFormat: colorPixelFormat)
        delegate = self
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan(_:))))
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:))))
        let twoFinger = UIPanGestureRecognizer(target: self, action: #selector(twoFingerMove(_:)))
        twoFinger.minimumNumberOfTouches = 2
        addGestureRecognizer(twoFinger)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(resetTapped))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        resetCamera()
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func resetCamera() {
        guard let splats = renderer?.splats else { return }
        let c = splats.center
        target = flipped ? SIMD3<Float>(c.x, -c.y, -c.z) : c
        distance = splats.radius * 1.6
        yaw = 0
        pitch = 0.35
    }

    @objc private func resetTapped() { resetCamera() }

    @objc private func pan(_ g: UIPanGestureRecognizer) {
        guard g.numberOfTouches <= 1 else { return }
        let d = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        yaw -= Float(d.x) * 0.008
        pitch = min(max(pitch + Float(d.y) * 0.006, -1.4), 1.4)
    }

    @objc private func pinch(_ g: UIPinchGestureRecognizer) {
        distance = min(max(distance / Float(g.scale), 0.05), 500)
        g.scale = 1
    }

    @objc private func twoFingerMove(_ g: UIPanGestureRecognizer) {
        let d = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        let right = SIMD3<Float>(cos(yaw), 0, -sin(yaw))
        let k = distance * 0.0015
        target -= right * Float(d.x) * k
        target += SIMD3<Float>(0, 1, 0) * Float(d.y) * k
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let renderer = renderer, let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let commandQueue = commandQueue else { return }
        _ = inFlight.wait(timeout: .distantFuture)
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { inFlight.signal(); return }
        let semaphore = inFlight
        commandBuffer.addCompletedHandler { _ in semaphore.signal() }
        let size = drawableSize
        let eye = target + distance * SIMD3<Float>(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
        var viewMatrix = ScanRenderer.lookAt(eye: eye, target: target, up: SIMD3<Float>(0, 1, 0))
        if flipped { viewMatrix = viewMatrix * flipX }
        let projection = ScanRenderer.perspective(fovY: Float(60.0 * Double.pi / 180.0),
                                                  aspect: Float(size.width / max(size.height, 1)),
                                                  near: max(distance * 0.01, 0.01), far: max(distance * 50, 100))
        renderer.draw(encoder, view: viewMatrix, projection: projection, viewport: size)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

// MARK: - AR view

final class ARSplatView: MTKView, MTKViewDelegate {
    private let session = ARSession()
    private var renderer: GaussianSplatRenderer?
    private var commandQueue: MTLCommandQueue?
    private var cameraPipeline: MTLRenderPipelineState?
    private var quadBuffer: MTLBuffer?
    private var textureCache: CVMetalTextureCache?
    private var placement: SIMD3<Float>?
    private var angle: Float = 0
    private var model = matrix_identity_float4x4
    private let inFlight = DispatchSemaphore(value: 3)
    var flipped = false { didSet { updateModel() } }
    /// 1 = real size (walk inside), 0.1 = 1:10 model, …
    var modelScale: Float = 1 { didSet { updateModel() } }
    var onStatus: ((String) -> Void)?
    /// "In place": relocalize in the scan's world map and draw the splat in its own coordinates.
    private var inPlaceMap: ARWorldMap?
    private var relocalized = false

    init(device: MTLDevice, splats: SplatData, inPlaceWorldMap: URL? = nil) {
        super.init(frame: .zero, device: device)
        if let url = inPlaceWorldMap, let data = try? Data(contentsOf: url) {
            inPlaceMap = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data)
        }
        colorPixelFormat = .bgra8Unorm
        preferredFramesPerSecond = 60
        commandQueue = device.makeCommandQueue()
        renderer = GaussianSplatRenderer(device: device, splats: splats, colorFormat: colorPixelFormat)
        delegate = self
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        textureCache = cache
        quadBuffer = device.makeBuffer(bytes: cameraQuad, length: cameraQuad.count * 4, options: [])
        if let library = device.makeDefaultLibrary() {
            let d = MTLVertexDescriptor()
            d.attributes[0].format = .float2
            d.attributes[0].offset = 0
            d.attributes[0].bufferIndex = 0
            d.attributes[1].format = .float2
            d.attributes[1].offset = 8
            d.attributes[1].bufferIndex = 0
            d.layouts[0].stride = 16
            let camera = MTLRenderPipelineDescriptor()
            camera.vertexFunction = library.makeFunction(name: "drawRectangle")
            camera.fragmentFunction = library.makeFunction(name: "displayTexture")
            camera.vertexDescriptor = d
            camera.colorAttachments[0].pixelFormat = .bgra8Unorm
            cameraPipeline = try? device.makeRenderPipelineState(descriptor: camera)
        }
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        addGestureRecognizer(UIRotationGestureRecognizer(target: self, action: #selector(rotated(_:))))
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func start() {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        if let map = inPlaceMap {
            config.initialWorldMap = map
            session.run(config)
            onStatus?("In place: point the phone at the room you scanned to line up…")
        } else {
            session.run(config)
            onStatus?("Move the phone a little, then tap the floor to place the scan")
        }
    }

    func stop() { session.pause() }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        guard inPlaceMap == nil, let frame = session.currentFrame, bounds.width > 0 else { return }
        let point = g.location(in: self)
        let normalized = CGPoint(x: point.x / bounds.width, y: point.y / bounds.height)
        let imagePoint = normalized.applying(frame.displayTransform(for: .portrait, viewportSize: bounds.size).inverted())
        let query = frame.raycastQuery(from: imagePoint, allowing: .estimatedPlane, alignment: .any)
        if let hit = session.raycast(query).first {
            let t = hit.worldTransform.columns.3
            placement = SIMD3<Float>(t.x, t.y, t.z)
            updateModel()
            onStatus?("Placed · rotate with two fingers · tap again to move")
        } else {
            onStatus?("No surface found there yet — move the phone slowly and try again")
        }
    }

    @objc private func rotated(_ g: UIRotationGestureRecognizer) {
        guard inPlaceMap == nil else { return }
        angle -= Float(g.rotation)
        g.rotation = 0
        updateModel()
    }

    private func updateModel() {
        guard let splats = renderer?.splats, let placement = placement else { return }
        // The splat's floor point (2nd percentile height, under its centre) goes to the tapped spot.
        var anchor = SIMD3<Float>(splats.center.x, splats.floorY, splats.center.z)
        if flipped { anchor = SIMD3<Float>(anchor.x, -anchor.y, -anchor.z) }
        var m = translation(placement) * rotationY(angle) * uniformScale(modelScale) * translation(-anchor)
        if flipped { m = m * flipX }
        model = m
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let frame = session.currentFrame, let drawable = currentDrawable, let commandQueue = commandQueue,
              let cameraPipeline = cameraPipeline, let textureCache = textureCache else { return }
        _ = inFlight.wait(timeout: .distantFuture)
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { inFlight.signal(); return }
        let semaphore = inFlight
        var keep: [CVMetalTexture] = []
        func texture(_ plane: Int, _ format: MTLPixelFormat) -> MTLTexture? {
            var cv: CVMetalTexture?
            let buffer = frame.capturedImage
            CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, buffer, nil, format,
                                                      CVPixelBufferGetWidthOfPlane(buffer, plane),
                                                      CVPixelBufferGetHeightOfPlane(buffer, plane), plane, &cv)
            guard let t = cv else { return nil }
            keep.append(t)
            return CVMetalTextureGetTexture(t)
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
            if let y = texture(0, .r8Unorm), let cbcr = texture(1, .rg8Unorm) {
                encoder.setRenderPipelineState(cameraPipeline)
                encoder.setVertexBuffer(quadBuffer, offset: 0, index: 0)
                encoder.setFragmentTexture(y, index: 0)
                encoder.setFragmentTexture(cbcr, index: 1)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
            if inPlaceMap != nil, !relocalized, case .normal = frame.camera.trackingState {
                relocalized = true
                DispatchQueue.main.async { self.onStatus?("In place: the scan is drawn where it was recorded") }
            }
            let showInPlace = inPlaceMap != nil && relocalized
            if let renderer = renderer, placement != nil || showInPlace {
                let size = drawableSize
                let viewMatrix = frame.camera.viewMatrix(for: .portrait) * (showInPlace ? matrix_identity_float4x4 : model)
                let projection = frame.camera.projectionMatrix(for: .portrait, viewportSize: size, zNear: 0.03, zFar: 200)
                renderer.draw(encoder, view: viewMatrix, projection: projection, viewport: size)
            }
            encoder.endEncoding()
        }
        let retained = keep
        commandBuffer.addCompletedHandler { _ in
            withExtendedLifetime(retained) {}
            semaphore.signal()
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

// MARK: - SwiftUI screen

struct SplatViewerScreen: View {
    let source: SplatSource
    @Environment(\.dismiss) private var dismiss
    @State private var splats: SplatData?
    @State private var status = "Loading…"
    @State private var arMode = false
    @State private var flipped = false
    @State private var scaleIndex = 0
    @State private var inPlace = false
    private let maxSplats = 1_000_000
    private let scales: [(String, Float)] = [("1:1", 1), ("1:10", 0.1), ("1:50", 0.02)]

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Color.black.ignoresSafeArea()
                if let splats = splats {
                    SplatCanvas(splats: splats, arMode: arMode, flipped: flipped,
                                modelScale: scales[scaleIndex].1, inPlaceMap: inPlace ? source.worldMapURL : nil,
                                status: $status)
                        .id(inPlace)
                        .ignoresSafeArea()
                } else {
                    ProgressView(status).tint(.white).foregroundStyle(.white)
                }
                VStack(spacing: 10) {
                    Text(status)
                        .font(.footnote.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .glassCard(cornerRadius: 16)
                    HStack(spacing: 10) {
                        Picker("View", selection: $arMode) {
                            Text("3D").tag(false)
                            Text("AR").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 110)
                        if arMode && source.worldMapURL != nil {
                            Toggle(isOn: $inPlace) { Image(systemName: "location.fill") }
                                .toggleStyle(.button)
                                .accessibilityLabel("Show where it was scanned")
                        }
                        if arMode && !inPlace {
                            Picker("Size", selection: $scaleIndex) {
                                ForEach(0..<scales.count, id: \.self) { Text(scales[$0].0).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 150)
                        }
                        Button {
                            flipped.toggle()
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                        }
                        .glassButton()
                        .accessibilityLabel("Flip upside down")
                    }
                    .padding(10)
                    .glassCard(cornerRadius: 24)
                }
                .padding(.bottom, 20)
            }
            .navigationTitle(source.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .task { await load() }
        }
        .preferredColorScheme(.dark)
    }

    private func load() async {
        guard splats == nil, let device = MTLCreateSystemDefaultDevice() else { return }
        do {
            let loaded: SplatData
            switch source {
            case .studio(let ply, _, _):
                loaded = try await SplatLoader.loadFromStudio(ply: ply, maxSplats: maxSplats, device: device) { text in
                    Task { @MainActor in status = text }
                }
            case .file(let url):
                status = "Reading file…"
                let limit = maxSplats
                loaded = try await Task.detached { try SplatLoader.loadPLY(url, device: device, maxSplats: limit) }.value
            }
            splats = loaded
            status = String(format: "%.2f M splats · drag to orbit · pinch to zoom · two fingers to move · double-tap to reset",
                            Double(loaded.count) / 1e6)
        } catch {
            status = "Could not load: \(error.localizedDescription)"
        }
    }
}

/// Hosts the orbit or AR Metal view.
struct SplatCanvas: UIViewRepresentable {
    let splats: SplatData
    let arMode: Bool
    let flipped: Bool
    let modelScale: Float
    let inPlaceMap: URL?
    @Binding var status: String

    final class Container: UIView {
        var orbit: OrbitSplatView?
        var ar: ARSplatView?
    }

    func makeUIView(context: Context) -> Container {
        let container = Container()
        container.backgroundColor = .black
        return container
    }

    func updateUIView(_ container: Container, context: Context) {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        if arMode {
            container.orbit?.removeFromSuperview()
            container.orbit = nil
            if container.ar == nil {
                let ar = ARSplatView(device: device, splats: splats, inPlaceWorldMap: inPlaceMap)
                ar.frame = container.bounds
                ar.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                let binding = $status
                ar.onStatus = { text in DispatchQueue.main.async { binding.wrappedValue = text } }
                container.addSubview(ar)
                container.ar = ar
                ar.start()
            }
            container.ar?.flipped = flipped
            container.ar?.modelScale = modelScale
        } else {
            container.ar?.stop()
            container.ar?.removeFromSuperview()
            container.ar = nil
            if container.orbit == nil {
                let orbit = OrbitSplatView(device: device, splats: splats)
                orbit.frame = container.bounds
                orbit.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                container.addSubview(orbit)
                container.orbit = orbit
            }
            container.orbit?.flipped = flipped
        }
    }

    static func dismantleUIView(_ container: Container, coordinator: ()) {
        container.ar?.stop()
    }
}
