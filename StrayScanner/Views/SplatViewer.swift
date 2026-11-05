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
import MetalFX

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
    /// Degree-1 spherical harmonics (view-dependent colour): 9 halves per splat, coefficient-major (c1 rgb, c2 rgb, c3 rgb).
    var sh: MTLBuffer?
    /// "Up" from SplatForge (world_up.json or the cameras' average up), in file coordinates.
    var pcUp: SIMD3<Float>?
    /// Turns the file's coordinates upright (world = orientation × file). Set by auto-level or the Level menu.
    var orientation = matrix_identity_float3x3 { didSet { if orientation != oldValue { computeStats() } } }
    /// Framing in the upright frame (robust: median and 5–95th percentile, so far floaters don't count).
    private(set) var center = SIMD3<Float>(repeating: 0)
    private(set) var radius: Float = 1
    private(set) var floorY: Float = 0
    /// Robust subsample of positions (file coordinates) used for framing and levelling.
    private let sample: [SIMD3<Float>]

    init(count: Int, buffer: MTLBuffer, positions: [SIMD3<Float>]) {
        self.count = count
        self.buffer = buffer
        self.positions = positions
        var picked: [SIMD3<Float>] = []
        let stride = max(count / 60_000, 1)
        var i = 0
        while i < count {
            let p = positions[i]
            if p.x.isFinite && p.y.isFinite && p.z.isFinite { picked.append(p) }
            i += stride
        }
        sample = picked
        computeStats()
    }

    /// Splat indices, most visible first (opacity × size). Used to draw a lighter subset while the view moves.
    lazy var importanceOrder: [UInt32] = {
        let base = buffer.contents()
        var keys = [UInt16](repeating: 0, count: count)
        var buckets = [Int](repeating: 0, count: 4097)
        for i in 0..<count {
            let o = base.advanced(by: i * SplatLoader.stride)
            let m = o.load(fromByteOffset: 28, as: Float.self)
            let xx = Float(o.load(fromByteOffset: 12, as: Float16.self)) * m
            let yy = Float(o.load(fromByteOffset: 18, as: Float16.self)) * m
            let zz = Float(o.load(fromByteOffset: 22, as: Float16.self)) * m
            let alpha = Float(o.load(fromByteOffset: 27, as: UInt8.self)) / 255
            let size = max(xx + yy + zz, 1e-10)                       // ~ squared extent
            let score = log2(alpha * size + 1e-12)                    // about -40 … +10
            let k = UInt16(min(max((score + 45) * 70, 0), 4095))
            keys[i] = 4095 - k                                        // descending
            buckets[Int(keys[i]) + 1] += 1
        }
        for k in 1...4096 { buckets[k] += buckets[k - 1] }
        var out = [UInt32](repeating: 0, count: count)
        for i in 0..<count {
            let k = Int(keys[i])
            out[buckets[k]] = UInt32(i)
            buckets[k] += 1
        }
        return out
    }()

    var orientation4: simd_float4x4 {
        let r = orientation
        return simd_float4x4(SIMD4(r.columns.0, 0), SIMD4(r.columns.1, 0), SIMD4(r.columns.2, 0), SIMD4(0, 0, 0, 1))
    }

    private static func percentile(_ a: [Float], _ f: Float) -> Float {
        a.isEmpty ? 0 : a[min(Int(Float(a.count - 1) * f), a.count - 1)]
    }

    private func computeStats() {
        let pts = sample.map { orientation * $0 }
        let xs = pts.map(\.x).sorted(), ys = pts.map(\.y).sorted(), zs = pts.map(\.z).sorted()
        let P = SplatData.percentile
        center = SIMD3(P(xs, 0.5), P(ys, 0.5), P(zs, 0.5))
        let lo = SIMD3(P(xs, 0.05), P(ys, 0.05), P(zs, 0.05))
        let hi = SIMD3(P(xs, 0.95), P(ys, 0.95), P(zs, 0.95))
        floorY = P(ys, 0.02)
        radius = max(simd_length(hi - lo) * 0.5, 0.5)
    }

    /// Rotation that turns SplatForge's up vector to +Y, if the PC sent one.
    func pcUpOrientation() -> simd_float3x3? {
        guard let up = pcUp, simd_length(up) > 0.1 else { return nil }
        return simd_float3x3(simd_quatf(from: simd_normalize(up), to: SIMD3<Float>(0, 1, 0)))
    }

    /// Finds "up": the ground (or floor) is the scene's flattest direction, so take the axis of least spread of the
    /// central 90 % of splats; the ground is a dense layer at the bottom with things sticking up, so the side the
    /// distribution trails off to is up. Returns identity when the scene is not flat enough to tell.
    func autoLevelOrientation() -> simd_float3x3 {
        guard sample.count > 100 else { return matrix_identity_float3x3 }
        let xs = sample.map(\.x).sorted(), ys = sample.map(\.y).sorted(), zs = sample.map(\.z).sorted()
        let P = SplatData.percentile
        let lo = SIMD3(P(xs, 0.05), P(ys, 0.05), P(zs, 0.05)), hi = SIMD3(P(xs, 0.95), P(ys, 0.95), P(zs, 0.95))
        let core = sample.filter { all($0 .>= lo) && all($0 .<= hi) }
        guard core.count > 100 else { return matrix_identity_float3x3 }
        let mean = core.reduce(SIMD3<Float>(repeating: 0), +) / Float(core.count)
        var c = simd_float3x3(0)
        for p in core {
            let d = p - mean
            c += simd_float3x3(columns: (d * d.x, d * d.y, d * d.z))
        }
        c = c * (1 / Float(core.count))
        let (values, vectors) = SplatData.symmetricEigen(c)
        // values ascending
        guard values.0 < 0.45 * values.1 else { return matrix_identity_float3x3 }
        var up = simd_normalize(vectors.0)
        var m3: Float = 0, m2: Float = 0
        for p in core { let t = simd_dot(p - mean, up); m2 += t * t; m3 += t * t * t }
        let skew = (m3 / Float(core.count)) / pow(max(m2 / Float(core.count), 1e-9), 1.5)
        if skew < -0.15 || (abs(skew) <= 0.15 && up.y < 0) { up = -up }
        let q = simd_quatf(from: up, to: SIMD3<Float>(0, 1, 0))
        return simd_float3x3(q)
    }

    /// Jacobi eigen-decomposition of a symmetric 3×3 matrix; eigenvalues ascending with their vectors.
    static func symmetricEigen(_ m: simd_float3x3) -> ((Float, Float, Float), (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)) {
        var a = [[Float]](repeating: [0, 0, 0], count: 3)
        for i in 0..<3 { for j in 0..<3 { a[i][j] = m[j][i] } }
        var v: [[Float]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        for _ in 0..<32 {
            var p = 0, q = 1
            var best = abs(a[0][1])
            if abs(a[0][2]) > best { best = abs(a[0][2]); p = 0; q = 2 }
            if abs(a[1][2]) > best { best = abs(a[1][2]); p = 1; q = 2 }
            if best < 1e-12 { break }
            let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
            let t = (theta >= 0 ? 1 : -1) / (abs(theta) + sqrt(theta * theta + 1))
            let cs = 1 / sqrt(t * t + 1), sn = t * cs
            for k in 0..<3 {
                let akp = a[k][p], akq = a[k][q]
                a[k][p] = cs * akp - sn * akq
                a[k][q] = sn * akp + cs * akq
            }
            for k in 0..<3 {
                let apk = a[p][k], aqk = a[q][k]
                a[p][k] = cs * apk - sn * aqk
                a[q][k] = sn * apk + cs * aqk
            }
            for k in 0..<3 {
                let vkp = v[k][p], vkq = v[k][q]
                v[k][p] = cs * vkp - sn * vkq
                v[k][q] = sn * vkp + cs * vkq
            }
        }
        let pairs = (0..<3).map { i in (a[i][i], SIMD3<Float>(v[0][i], v[1][i], v[2][i])) }.sorted { $0.0 < $1.0 }
        return ((pairs[0].0, pairs[1].0, pairs[2].0), (pairs[0].1, pairs[1].1, pairs[2].1))
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
    /// Covariance on the GPU: 6 half floats divided by the splat's own largest diagonal term, plus that term as a
    /// float32 in the last 4 bytes. Halves alone either lose small splats (m²) or clip big ones (cm²); per-splat
    /// normalising keeps both exact to ~0.1 %.
    static func packCov(_ c: [Float], into o: UnsafeMutableRawPointer) {
        let m = max(abs(c[0]), abs(c[3]), abs(c[5]), 1e-20)
        for t in 0..<6 {
            o.storeBytes(of: Float16(c[t] / m), toByteOffset: 12 + t * 2, as: Float16.self)
        }
        o.storeBytes(of: m, toByteOffset: 28, as: Float.self)
    }

    /// SplatForge Studio /api/splat: u32 N, u32 pad×3 | f32 pos[N×3] | f16 cov[N×6] | u8 rgba[N×4].
    static func loadFromStudio(ply: String, maxSplats: Int, device: MTLDevice,
                               progress: @escaping (String) -> Void) async throws -> SplatData {
        let settings = PCLinkSettings.load()
        // fmt=2 asks for float32 covariances (older Studios ignore it and send format 1).
        // fmt=2: f32 covariances · sh=1: view-dependent colour · opt=1: PC prunes floaters and sorts best-first,
        // so max=N is simply the best N splats. Older Studios ignore what they don't know.
        guard let url = settings.url("/api/splat", query: ["ply": ply, "max": String(maxSplats), "fmt": "2", "sh": "1", "opt": "1"]) else {
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
        let splats = try decodeStudio(data, device: device)
        if let metaURL = settings.url("/api/splat/meta", query: ["ply": ply]) {
            var meta = URLRequest(url: metaURL, timeoutInterval: 10)
            meta.setValue(settings.token, forHTTPHeaderField: "X-Token")
            if let (body, _) = try? await URLSession.shared.data(for: meta),
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let up = json["up"] as? [Double], up.count == 3 {
                splats.pcUp = SIMD3<Float>(Float(up[0]), Float(up[1]), Float(up[2]))
            }
        }
        return splats
    }

    static func decodeStudio(_ data: Data, device: MTLDevice) throws -> SplatData {
        guard data.count >= 16 else { throw SplatLoaderError.bad("Empty splat") }
        let n = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) })
        let version = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) })
        let hasSH = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self) } == 1
        let covIs32 = version >= 2
        let posBytes = n * 12, covBytes = n * (covIs32 ? 24 : 12)
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
                let c = base.advanced(by: 16 + posBytes + i * (covIs32 ? 24 : 12))
                let cov = (0..<6).map { t in
                    covIs32 ? c.loadUnaligned(fromByteOffset: t * 4, as: Float.self)
                            : Float(c.loadUnaligned(fromByteOffset: t * 2, as: Float16.self))
                }
                packCov(cov, into: o)
                o.advanced(by: 24).copyMemory(from: base.advanced(by: 16 + posBytes + covBytes + i * 4), byteCount: 4)
            }
        }
        let result = SplatData(count: n, buffer: buffer, positions: positions)
        let shOffset = 16 + posBytes + covBytes + n * 4
        if hasSH, data.count >= shOffset + n * 18 {
            result.sh = data.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!.advanced(by: shOffset), length: n * 18, options: .storageModeShared) }
        }
        return result
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
        // f_rest is channel-major (all R coefficients, then G, then B); degree 1 = the first 3 of each channel.
        let restCount = properties.filter { $0.hasPrefix("f_rest_") }.count
        let perChannel = restCount / 3
        let rest: [Int]? = perChannel >= 3 ? (0..<3).flatMap { k in (0..<3).map { c in properties.firstIndex(of: "f_rest_\(c * perChannel + k)") ?? -1 } } : nil
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
        let shBuffer = rest.flatMap { r in r.contains(-1) ? nil : device.makeBuffer(length: n * 18, options: .storageModeShared) }
        let shOut = shBuffer?.contents().bindMemory(to: Float16.self, capacity: n * 9)
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
                SplatLoader.packCov(terms, into: o)
                for c in 0..<3 {
                    let v = min(max(0.5 + c0 * f(dc[c]), 0), 1)
                    o.storeBytes(of: UInt8(v * 255), toByteOffset: 24 + c, as: UInt8.self)
                }
                o.storeBytes(of: UInt8(min(max(opacity, 0), 1) * 255), toByteOffset: 27, as: UInt8.self)
                if let shOut = shOut, let rest = rest {
                    for j in 0..<9 { shOut[k * 9 + j] = Float16(f(rest[j])) }
                }
            }
        }
        let result = SplatData(count: n, buffer: buffer, positions: positions)
        result.sh = shBuffer
        return result
    }
}

// MARK: - Renderer

private struct GSSortUniforms {
    var view: simd_float4x4
    var tanX: Float
    var tanY: Float
    var count: UInt32
    var lodFactor: Float = 0
}

private struct GSUniforms {
    var view: simd_float4x4
    var projection: simd_float4x4
    var viewport: SIMD2<Float>
    var focal: SIMD2<Float>
    var cameraPos: SIMD4<Float> = .zero      // camera in the splat file's coordinates (for view-dependent colour)
    var hasSH: UInt32 = 0
    var pad0: UInt32 = 0, pad1: UInt32 = 0, pad2: UInt32 = 0
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
    /// How many splats each order buffer holds (only the ones in view survive the sort).
    private var orderCounts: [Int]
    private var keys: [UInt16] = []
    private var depths: [Float] = []
    private static let chunks = 8
    private var histograms = [UInt32](repeating: 0, count: 65536 * GaussianSplatRenderer.chunks)
    private var projectionForCull = matrix_identity_float4x4
    /// Called (on any thread) when a new order is ready — on-demand views redraw then.
    var onSorted: (() -> Void)?
    /// Splats drawn last frame (after culling), for the status line.
    private(set) var visibleCount = 0
    /// While the view moves, sort and draw only the most visible splats so the order keeps up with the camera
    /// (a stale order is what smears big scenes); the full set is sorted again once the view is still.
    var interactive = false
    /// Smallest on-screen splat size (σ in pixels) still drawn; far, tiny splats are skipped. 0 = draw all.
    var lodMinPixels: Float = 0.2
    /// GPU sort (every frame, exact order at any splat count). Falls back to the CPU sort if the kernels are missing.
    var commandQueue: MTLCommandQueue?
    private var gpu: (keys: MTLComputePipelineState, scan: MTLComputePipelineState, scatter: MTLComputePipelineState,
                      keyBuffer: MTLBuffer, hist: MTLBuffer, offsets: MTLBuffer, order: MTLBuffer, args: MTLBuffer)?
    static let interactiveBudget = 800_000
    private var lastSortedSubset = false

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
        self.orderCounts = [splats.count, 0, 0]
        keys = [UInt16](repeating: 0, count: splats.count)
        depths = [Float](repeating: 0, count: splats.count)
        if let k = library.makeFunction(name: "gsKeys").flatMap({ try? device.makeComputePipelineState(function: $0) }),
           let sc = library.makeFunction(name: "gsScan").flatMap({ try? device.makeComputePipelineState(function: $0) }),
           let sa = library.makeFunction(name: "gsScatter").flatMap({ try? device.makeComputePipelineState(function: $0) }),
           sc.maxTotalThreadsPerThreadgroup >= 256,
           let kb = device.makeBuffer(length: splats.count * 4, options: .storageModePrivate),
           let h = device.makeBuffer(length: 65536 * 4, options: .storageModePrivate),
           let o = device.makeBuffer(length: 65536 * 4, options: .storageModePrivate),
           let ob = device.makeBuffer(length: splats.count * 4, options: .storageModePrivate),
           let a = device.makeBuffer(length: 16, options: .storageModePrivate) {
            gpu = (k, sc, sa, kb, h, o, ob, a)
        }
    }

    /// Encodes the splats into an existing render encoder (colour target with the renderer's pixel format).
    private var lastViewport = CGSize(width: 1000, height: 1000)

    func draw(_ encoder: MTLRenderCommandEncoder, view: simd_float4x4, projection: simd_float4x4, viewport: CGSize) {
        lastViewport = viewport
        if let g = gpu, let queue = commandQueue, let cb = queue.makeCommandBuffer() {
            // Sorted on the GPU in its own command buffer, committed now — so it runs before the caller's frame.
            encodeGPUSort(cb, g, view: view, projection: projection)
            cb.commit()
            var uniforms = GSUniforms(view: view, projection: projection,
                                      viewport: SIMD2<Float>(Float(viewport.width), Float(viewport.height)),
                                      focal: SIMD2<Float>(projection.columns.0.x * Float(viewport.width) * 0.5,
                                                          projection.columns.1.y * Float(viewport.height) * 0.5))
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(splats.buffer, offset: 0, index: 0)
            encoder.setVertexBuffer(g.order, offset: 0, index: 1)
            let eye = view.inverse.columns.3
            uniforms.cameraPos = SIMD4<Float>(eye.x / eye.w, eye.y / eye.w, eye.z / eye.w, 1)
            uniforms.hasSH = splats.sh != nil ? 1 : 0
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<GSUniforms>.stride, index: 2)
            encoder.setVertexBuffer(splats.sh ?? splats.buffer, offset: 0, index: 3)
            encoder.drawPrimitives(type: .triangleStrip, indirectBuffer: g.args, indirectBufferOffset: 0)
            return
        }
        requestSort(view: view, projection: projection)
        lock.lock()
        let order = orderBuffers[currentOrder]
        let count = orderCounts[currentOrder]
        lock.unlock()
        visibleCount = count
        guard count > 0 else { return }
        var uniforms = GSUniforms(view: view, projection: projection,
                                  viewport: SIMD2<Float>(Float(viewport.width), Float(viewport.height)),
                                  focal: SIMD2<Float>(projection.columns.0.x * Float(viewport.width) * 0.5,
                                                      projection.columns.1.y * Float(viewport.height) * 0.5))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(splats.buffer, offset: 0, index: 0)
        encoder.setVertexBuffer(order, offset: 0, index: 1)
        let eye = view.inverse.columns.3
            uniforms.cameraPos = SIMD4<Float>(eye.x / eye.w, eye.y / eye.w, eye.z / eye.w, 1)
            uniforms.hasSH = splats.sh != nil ? 1 : 0
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<GSUniforms>.stride, index: 2)
            encoder.setVertexBuffer(splats.sh ?? splats.buffer, offset: 0, index: 3)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
    }

    private func encodeGPUSort(_ cb: MTLCommandBuffer, _ g: (keys: MTLComputePipelineState, scan: MTLComputePipelineState,
                               scatter: MTLComputePipelineState, keyBuffer: MTLBuffer, hist: MTLBuffer, offsets: MTLBuffer,
                               order: MTLBuffer, args: MTLBuffer), view: simd_float4x4, projection: simd_float4x4) {
        guard let blit = cb.makeBlitCommandEncoder() else { return }
        blit.fill(buffer: g.hist, range: 0..<g.hist.length, value: 0)
        blit.endEncoding()
        guard let enc = cb.makeComputeCommandEncoder() else { return }
        let n = splats.count
        var u = GSSortUniforms(view: view, tanX: 1.6 / max(projection.columns.0.x, 0.01),
                               tanY: 1.6 / max(projection.columns.1.y, 0.01), count: UInt32(n))
        if lodMinPixels > 0 {
            u.lodFactor = projection.columns.1.y * Float(lastViewport.height) * 0.5 / lodMinPixels
        }
        enc.setComputePipelineState(g.keys)
        enc.setBuffer(splats.buffer, offset: 0, index: 0)
        enc.setBuffer(g.keyBuffer, offset: 0, index: 1)
        enc.setBuffer(g.hist, offset: 0, index: 2)
        enc.setBytes(&u, length: MemoryLayout<GSSortUniforms>.stride, index: 3)
        enc.dispatchThreads(MTLSize(width: n, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        enc.setComputePipelineState(g.scan)
        enc.setBuffer(g.hist, offset: 0, index: 0)
        enc.setBuffer(g.offsets, offset: 0, index: 1)
        enc.setBuffer(g.args, offset: 0, index: 2)
        enc.setThreadgroupMemoryLength(256 * 4, index: 0)
        enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        enc.setComputePipelineState(g.scatter)
        enc.setBuffer(g.keyBuffer, offset: 0, index: 0)
        enc.setBuffer(g.offsets, offset: 0, index: 1)
        enc.setBuffer(g.order, offset: 0, index: 2)
        enc.setBytes(&u, length: MemoryLayout<GSSortUniforms>.stride, index: 3)
        enc.dispatchThreads(MTLSize(width: n, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        enc.endEncoding()
    }

    private func requestSort(view: simd_float4x4, projection: simd_float4x4) {
        lock.lock()
        defer { lock.unlock() }
        guard !sorting else { return }
        let subset = interactive && splats.count > GaussianSplatRenderer.interactiveBudget
        if let last = lastSortedView, subset == lastSortedSubset {
            let moved = simd_distance(last.columns.3, view.columns.3) + simd_distance(last.columns.2, view.columns.2)
            if moved < 0.01 { return }
        }
        sorting = true
        lastSortedView = view
        lastSortedSubset = subset
        projectionForCull = projection
        let target = (currentOrder + 1) % orderBuffers.count
        sortQueue.async { [weak self] in
            guard let self = self else { return }
            if subset {
                let list = self.splats.importanceOrder
                list.withUnsafeBufferPointer { l in
                    self.sort(view: view, into: target, subset: UnsafeBufferPointer(rebasing: l[0..<GaussianSplatRenderer.interactiveBudget]))
                }
            } else {
                self.sort(view: view, into: target, subset: nil)
            }
        }
    }

    /// Cull + bucket sort by view-space depth (65 536 buckets), farthest first, on all CPU cores:
    /// 1) depth of every splat, dropping ones behind the camera or well outside the view (a wide margin so turning
    ///    the phone doesn't show holes before the next sort), 2) per-core histograms, 3) stable parallel scatter.
    private func sort(view: simd_float4x4, into target: Int, subset: UnsafeBufferPointer<UInt32>?) {
        let n = subset?.count ?? splats.count
        let chunks = GaussianSplatRenderer.chunks
        let r = SIMD4<Float>(view.columns.0.z, view.columns.1.z, view.columns.2.z, view.columns.3.z)
        let rx = SIMD4<Float>(view.columns.0.x, view.columns.1.x, view.columns.2.x, view.columns.3.x)
        let ry = SIMD4<Float>(view.columns.0.y, view.columns.1.y, view.columns.2.y, view.columns.3.y)
        // Half-width of the view per metre of depth, with 60 % margin.
        let tanX = 1.6 / max(projectionForCull.columns.0.x, 0.01)
        let tanY = 1.6 / max(projectionForCull.columns.1.y, 0.01)
        let per = (n + chunks - 1) / chunks
        var los = [Float](repeating: .greatestFiniteMagnitude, count: chunks)
        var his = [Float](repeating: -.greatestFiniteMagnitude, count: chunks)
        splats.positions.withUnsafeBufferPointer { positions in
        depths.withUnsafeMutableBufferPointer { depths in
        los.withUnsafeMutableBufferPointer { los in
        his.withUnsafeMutableBufferPointer { his in
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
                for i in (c * per)..<min((c + 1) * per, n) {
                    let p = SIMD4<Float>(positions[subset.map { Int($0[i]) } ?? i], 1)
                    let z = simd_dot(r, p)
                    let d = -z
                    // NaN marks culled splats.
                    if d < 0.02 || abs(simd_dot(rx, p)) > d * tanX + 0.5 || abs(simd_dot(ry, p)) > d * tanY + 0.5 {
                        depths[i] = .nan
                        continue
                    }
                    // Log of the distance: 65 536 buckets spread evenly in *relative* depth, so near splats keep fine
                    // ordering even when far floaters stretch the range (linear keys caused dark ordering streaks).
                    let ld = -log2(d)                       // larger = nearer; sorted ascending = far first
                    depths[i] = ld
                    lo = min(lo, ld); hi = max(hi, ld)
                }
                los[c] = lo; his[c] = hi
            }
        }}}}
        let lo = los.min() ?? 0, hi = his.max() ?? 0
        let scale = hi > lo ? 65535 / (hi - lo) : 0
        var visible = 0
        depths.withUnsafeBufferPointer { depths in
        keys.withUnsafeMutableBufferPointer { keys in
        histograms.withUnsafeMutableBufferPointer { hist in
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                let h = hist.baseAddress! + c * 65536
                for k in 0..<65536 { h[k] = 0 }
                for i in (c * per)..<min((c + 1) * per, n) {
                    let z = depths[i]
                    if z.isNaN { continue }
                    let key = UInt16(min(max((z - lo) * scale, 0), 65535))   // more negative z = farther = first
                    keys[i] = key
                    h[Int(key)] += 1
                }
            }
            // Exclusive prefix over (bucket, chunk): bucket-major so the result is a stable sort.
            var running: UInt32 = 0
            for k in 0..<65536 {
                for c in 0..<chunks {
                    let v = hist[c * 65536 + k]
                    hist[c * 65536 + k] = running
                    running += v
                }
            }
            visible = Int(running)
            let out = orderBuffers[target].contents().bindMemory(to: UInt32.self, capacity: n)
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                let h = hist.baseAddress! + c * 65536
                for i in (c * per)..<min((c + 1) * per, n) {
                    if depths[i].isNaN { continue }
                    let k = Int(keys[i])
                    out[Int(h[k])] = subset.map { $0[i] } ?? UInt32(i)
                    h[k] += 1
                }
            }
        }}}
        lock.lock()
        orderCounts[target] = visible
        currentOrder = target
        sorting = false
        lock.unlock()
        onSorted?()
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


private let cameraQuad: [Float] = [
    -1.0, -1.0, 1.0, 1.0,
     1.0, -1.0, 1.0, 0.0,
    -1.0,  1.0, 0.0, 1.0,
     1.0,  1.0, 0.0, 0.0
]

// MARK: - Orbit view

/// Speed vs sharpness: render resolution (MetalFX upscales to the screen) and distance LOD.
enum SplatSpeed: String, CaseIterable {
    case sharp, balanced, fast
    var title: String { ["sharp": "Sharpest", "balanced": "Balanced", "fast": "Fastest"][rawValue] ?? rawValue }
    var renderScale: Float { ["sharp": 1.0, "balanced": 0.7, "fast": 0.5][rawValue] ?? 1 }
    var lodMinPixels: Float { ["sharp": 0.0, "balanced": 0.2, "fast": 0.4][rawValue] ?? 0 }
}

enum SplatBackground: String, CaseIterable {
    case black, grey, sky
    var title: String { ["black": "Black", "grey": "Grey", "sky": "Sky blue"][rawValue] ?? rawValue }
    var clear: MTLClearColor {
        switch self {
        case .black: return MTLClearColor(red: 0.03, green: 0.03, blue: 0.04, alpha: 1)
        case .grey: return MTLClearColor(red: 0.42, green: 0.43, blue: 0.45, alpha: 1)
        case .sky: return MTLClearColor(red: 0.62, green: 0.76, blue: 0.92, alpha: 1)
        }
    }
}

final class OrbitSplatView: MTKView, MTKViewDelegate {
    var background: SplatBackground = .black {
        didSet { clearColor = background.clear; setNeedsDisplay() }
    }
    /// < 1: draw the splats at this fraction of the screen resolution and let MetalFX upscale (much less overdraw).
    var speed: SplatSpeed = .balanced {
        didSet {
            renderer?.lodMinPixels = speed.lodMinPixels
            scaler = nil
            setNeedsDisplay()
        }
    }
    private var scaler: MTLFXSpatialScaler?
    private var lowTexture: MTLTexture?
    private var upscaled: MTLTexture?
    private var renderer: GaussianSplatRenderer?
    private var commandQueue: MTLCommandQueue?
    private var yaw: Float = 0, pitch: Float = 0.35, distance: Float = 3
    private var target = SIMD3<Float>(0, 0, 0)
    private let inFlight = DispatchSemaphore(value: 3)
    init(device: MTLDevice, splats: SplatData) {
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0.03, green: 0.03, blue: 0.04, alpha: 1)
        preferredFramesPerSecond = 60
        commandQueue = device.makeCommandQueue()
        renderer = GaussianSplatRenderer(device: device, splats: splats, colorFormat: colorPixelFormat)
        renderer?.commandQueue = commandQueue
        delegate = self
        // Draw only when something changed (a gesture or a finished sort): no work and no battery use while still.
        isPaused = true
        enableSetNeedsDisplay = true
        renderer?.onSorted = { [weak self] in DispatchQueue.main.async { self?.setNeedsDisplay() } }
        framebufferOnly = false   // the MetalFX result is copied into the drawable
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

    func resetCamera() {
        guard let splats = renderer?.splats else { return }
        target = splats.center
        distance = splats.radius * 1.6
        yaw = 0
        pitch = 0.35
        setNeedsDisplay()
    }

    @objc private func resetTapped() { resetCamera() }

    private var stillTimer: Timer?
    /// Light subset while a gesture runs; full quality 0.2 s after it stops.
    private func interacting(_ g: UIGestureRecognizer) {
        renderer?.interactive = true
        stillTimer?.invalidate()
        if g.state == .ended || g.state == .cancelled || g.state == .failed {
            stillTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
                self?.renderer?.interactive = false
                self?.setNeedsDisplay()
            }
        }
    }

    @objc private func pan(_ g: UIPanGestureRecognizer) {
        interacting(g)
        guard g.numberOfTouches <= 1 else { return }
        let d = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        yaw -= Float(d.x) * 0.008
        pitch = min(max(pitch + Float(d.y) * 0.006, -1.4), 1.4)
        setNeedsDisplay()
    }

    @objc private func pinch(_ g: UIPinchGestureRecognizer) {
        interacting(g)
        distance = min(max(distance / Float(g.scale), 0.05), 500)
        g.scale = 1
        setNeedsDisplay()
    }

    @objc private func twoFingerMove(_ g: UIPanGestureRecognizer) {
        interacting(g)
        let d = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        let right = SIMD3<Float>(cos(yaw), 0, -sin(yaw))
        let k = distance * 0.0015
        target -= right * Float(d.x) * k
        target += SIMD3<Float>(0, 1, 0) * Float(d.y) * k
        setNeedsDisplay()
    }

    // 2× is plenty for soft splats and draws ~45 % fewer pixels than 3× (fill rate is the limit on phones).
    override func didMoveToWindow() {
        super.didMoveToWindow()
        contentScaleFactor = min(window?.screen.scale ?? 2, 2)
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
        viewMatrix = viewMatrix * (renderer.splats.orientation4)
        let projection = ScanRenderer.perspective(fovY: Float(60.0 * Double.pi / 180.0),
                                                  aspect: Float(size.width / max(size.height, 1)),
                                                  near: max(distance * 0.01, 0.01), far: max(distance * 50, 100))
        // Dynamic resolution: while you drag, the Speed setting (lower resolution + MetalFX, distance LOD);
        // once the view is still, one frame at full resolution with every splat — sharp at no ongoing cost,
        // because the 3D view only redraws when something changes.
        let moving = renderer.interactive
        renderer.lodMinPixels = moving ? speed.lodMinPixels : 0
        if moving, speed.renderScale < 1, let device = device, prepareScaler(device: device, output: size),
           let scaler = scaler, let low = lowTexture, let out = upscaled {
            // Splats at reduced resolution → MetalFX spatial upscale → copy to the screen.
            encoder.endEncoding()
            let lowPass = MTLRenderPassDescriptor()
            lowPass.colorAttachments[0].texture = low
            lowPass.colorAttachments[0].loadAction = .clear
            lowPass.colorAttachments[0].storeAction = .store
            lowPass.colorAttachments[0].clearColor = clearColor
            if let lowEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: lowPass) {
                renderer.draw(lowEncoder, view: viewMatrix, projection: projection,
                              viewport: CGSize(width: low.width, height: low.height))
                lowEncoder.endEncoding()
            }
            scaler.colorTexture = low
            scaler.outputTexture = out
            scaler.encode(commandBuffer: commandBuffer)
            if let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.copy(from: out, to: drawable.texture)
                blit.endEncoding()
            }
        } else {
            renderer.draw(encoder, view: viewMatrix, projection: projection, viewport: size)
            encoder.endEncoding()
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// (Re)creates the MetalFX scaler and its textures for the current screen size and speed setting.
    private func prepareScaler(device: MTLDevice, output: CGSize) -> Bool {
        let outW = Int(output.width), outH = Int(output.height)
        let inW = max(Int(Float(outW) * speed.renderScale), 16), inH = max(Int(Float(outH) * speed.renderScale), 16)
        if let s = scaler, s.outputWidth == outW, s.outputHeight == outH, s.inputWidth == inW { return true }
        guard MTLFXSpatialScalerDescriptor.supportsDevice(device) else { return false }
        let d = MTLFXSpatialScalerDescriptor()
        d.inputWidth = inW; d.inputHeight = inH
        d.outputWidth = outW; d.outputHeight = outH
        d.colorTextureFormat = colorPixelFormat
        d.outputTextureFormat = colorPixelFormat
        d.colorProcessingMode = .perceptual
        guard let s = d.makeSpatialScaler(device: device) else { return false }
        let lowDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: colorPixelFormat, width: inW, height: inH, mipmapped: false)
        lowDesc.usage = [.renderTarget, .shaderRead]
        lowDesc.storageMode = .private
        let outDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: colorPixelFormat, width: outW, height: outH, mipmapped: false)
        outDesc.usage = s.outputTextureUsage
        outDesc.storageMode = .private
        guard let low = device.makeTexture(descriptor: lowDesc), let out = device.makeTexture(descriptor: outDesc) else { return false }
        s.inputContentWidth = inW
        s.inputContentHeight = inH
        scaler = s; lowTexture = low; upscaled = out
        return true
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
    func orientationChanged() { updateModel() }
    /// AR always moves, so it always uses the Speed setting: splats at reduced resolution, smoothly
    /// scaled up over the full-resolution camera picture.
    var speed: SplatSpeed = .balanced { didSet { renderer?.lodMinPixels = speed.lodMinPixels } }
    private var compositePipeline: MTLRenderPipelineState?
    private var splatTexture: MTLTexture?

    private func splatTarget(for size: CGSize) -> MTLTexture? {
        let w = max(Int(Float(size.width) * speed.renderScale), 16), h = max(Int(Float(size.height) * speed.renderScale), 16)
        if let t = splatTexture, t.width == w, t.height == h { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        splatTexture = device?.makeTexture(descriptor: d)
        return splatTexture
    }
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
        renderer?.commandQueue = commandQueue
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
            let composite = MTLRenderPipelineDescriptor()
            composite.vertexFunction = library.makeFunction(name: "fullscreenQuad")
            composite.fragmentFunction = library.makeFunction(name: "compositePremultiplied")
            let att = composite.colorAttachments[0]!
            att.pixelFormat = .bgra8Unorm
            att.isBlendingEnabled = true
            att.sourceRGBBlendFactor = .one
            att.destinationRGBBlendFactor = .oneMinusSourceAlpha
            att.sourceAlphaBlendFactor = .one
            att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            compositePipeline = try? device.makeRenderPipelineState(descriptor: composite)
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
        let anchor = SIMD3<Float>(splats.center.x, splats.floorY, splats.center.z)
        model = translation(placement) * rotationY(angle) * uniformScale(modelScale) * translation(-anchor) * splats.orientation4
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
        // Splats at reduced resolution first (own pass, transparent background), composited after the camera.
        let showInPlaceNow = inPlaceMap != nil && relocalized
        var lowSplats: MTLTexture?
        if speed.renderScale < 1, compositePipeline != nil, let renderer = renderer,
           placement != nil || showInPlaceNow, let target = splatTarget(for: drawableSize) {
            let lowPass = MTLRenderPassDescriptor()
            lowPass.colorAttachments[0].texture = target
            lowPass.colorAttachments[0].loadAction = .clear
            lowPass.colorAttachments[0].storeAction = .store
            lowPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: lowPass) {
                let viewMatrix = frame.camera.viewMatrix(for: .portrait) * (showInPlaceNow ? matrix_identity_float4x4 : model)
                let projection = frame.camera.projectionMatrix(for: .portrait, viewportSize: drawableSize, zNear: 0.03, zFar: 200)
                renderer.draw(enc, view: viewMatrix, projection: projection, viewport: CGSize(width: target.width, height: target.height))
                enc.endEncoding()
                lowSplats = target
            }
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
            if let low = lowSplats, let composite = compositePipeline {
                encoder.setRenderPipelineState(composite)
                encoder.setFragmentTexture(low, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            } else if let renderer = renderer, placement != nil || showInPlace {
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

private func turn(_ axis: SIMD3<Float>, _ angle: Float) -> simd_float3x3 {
    return simd_float3x3(simd_quatf(angle: angle, axis: axis))
}

struct SplatViewerScreen: View {
    let source: SplatSource
    @Environment(\.dismiss) private var dismiss
    @State private var splats: SplatData?
    @State private var status = "Loading…"
    @State private var hint: String?
    @State private var arMode = false
    @State private var orientation = matrix_identity_float3x3
    @State private var scaleIndex = 0
    @State private var inPlace = false
    @State private var resetToken = 0
    @State private var failed = false
    /// Quality = how many splats are loaded. SplatForge sends them best-first, so fewer = the most visible ones.
    @AppStorage("SplatMaxCount") private var maxSplats = 1_000_000
    @AppStorage("SplatBackground") private var background = SplatBackground.black.rawValue
    @AppStorage("SplatSpeed") private var speed = SplatSpeed.balanced.rawValue
    private let qualities: [(String, String, Int)] = [("Draft", "0.3 M", 300_000), ("Normal", "1 M", 1_000_000),
                                                      ("High", "2 M", 2_000_000), ("Very high", "3 M", 3_000_000),
                                                      ("Everything", "All", 50_000_000)]
    private let scales: [(String, Float)] = [("1:1", 1), ("1:10", 0.1), ("1:50", 0.02)]

    private var qualityLabel: String { qualities.first { $0.2 == maxSplats }?.1 ?? "1 M" }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let splats = splats {
                SplatCanvas(splats: splats, arMode: arMode, orientation: orientation,
                            background: SplatBackground(rawValue: background) ?? .black,
                            speed: SplatSpeed(rawValue: speed) ?? .balanced,
                            modelScale: scales[scaleIndex].1, inPlaceMap: inPlace ? source.worldMapURL : nil,
                            resetToken: resetToken, status: $status)
                    .id(inPlace)
                    .ignoresSafeArea()
            } else {
                loadingCard
            }
            VStack(spacing: 12) {
                topBar
                Spacer()
                if let hint = hint {
                    Text(hint)
                        .font(.footnote.weight(.medium))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .glassCard(cornerRadius: 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if splats != nil { controlBar }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .preferredColorScheme(.dark)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: hint)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: arMode)
        .task(id: maxSplats) { await load() }
        .onChange(of: status) { newValue in showHint(newValue) }
    }

    // MARK: Pieces

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 22, height: 22)
            }
            .glassButton()
            .accessibilityLabel("Close")
            VStack(alignment: .leading, spacing: 1) {
                Text(source.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .glassCard(cornerRadius: 18)
            Spacer(minLength: 0)
            if splats != nil && !arMode {
                Button { resetToken += 1 } label: {
                    Image(systemName: "scope").frame(width: 22, height: 22)
                }
                .glassButton()
                .accessibilityLabel("Reset view")
            }
        }
    }

    private var subtitle: String {
        guard let s = splats else { return failed ? "Not loaded" : "Loading…" }
        var parts = [String(format: "%.2f M splats", Double(s.count) / 1e6)]
        if s.sh != nil { parts.append("shiny colour") }
        if s.pcUp != nil { parts.append("level from PC") }
        return parts.joined(separator: " · ")
    }

    private var loadingCard: some View {
        VStack(spacing: 14) {
            if failed {
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
            } else {
                ProgressView().controlSize(.large).tint(.white)
            }
            Text(status).font(.callout).multilineTextAlignment(.center)
            if failed {
                Button("Try again") { failed = false; status = "Loading…"; Task { await load() } }
                    .glassButton(prominent: true)
            }
        }
        .padding(24)
        .frame(maxWidth: 300)
        .glassCard(cornerRadius: 28)
    }

    private var controlBar: some View {
        HStack(spacing: 8) {
            modeSwitch
            Divider().frame(height: 24).opacity(0.4)
            if arMode {
                if source.worldMapURL != nil {
                    Button { inPlace.toggle() } label: {
                        Image(systemName: inPlace ? "location.fill" : "location").frame(width: 22, height: 22)
                    }
                    .glassButton(prominent: inPlace)
                    .accessibilityLabel("Show where it was scanned")
                }
                if !inPlace {
                    Menu {
                        ForEach(0..<scales.count, id: \.self) { i in
                            Button { scaleIndex = i } label: { check(scales[i].0, scaleIndex == i) }
                        }
                    } label: { chip(symbol: "arrow.up.left.and.arrow.down.right", text: scales[scaleIndex].0) }
                }
            }
            Menu {
                ForEach(qualities, id: \.2) { q in
                    Button {
                        if maxSplats != q.2 { maxSplats = q.2; splats = nil; status = "Loading \(q.0.lowercased())…" }
                    } label: { check("\(q.0) · \(q.1)", maxSplats == q.2) }
                }
            } label: { chip(symbol: "sparkles", text: qualityLabel) }
            Menu {
                Section("Which way is up") {
                    if let up = splats?.pcUpOrientation() {
                        Button { orientation = up } label: { Label("From SplatForge", systemImage: "desktopcomputer") }
                    }
                    Button { if let s = splats { orientation = s.autoLevelOrientation() } } label: {
                        Label("Auto level (ground down)", systemImage: "level")
                    }
                    Button { orientation = matrix_identity_float3x3 } label: { Label("As exported", systemImage: "arrow.uturn.backward") }
                    Button { orientation = turn(.init(1, 0, 0), .pi) * orientation } label: { Label("Upside down", systemImage: "arrow.up.arrow.down") }
                    Button { orientation = turn(.init(1, 0, 0), .pi / 2) * orientation } label: { Label("Tip forward 90°", systemImage: "rotate.right") }
                    Button { orientation = turn(.init(0, 0, 1), .pi / 2) * orientation } label: { Label("Tip sideways 90°", systemImage: "rotate.left") }
                }
                Section("Speed") {
                    ForEach(SplatSpeed.allCases, id: \.self) { sp in
                        Button { speed = sp.rawValue } label: { check(sp.title, speed == sp.rawValue) }
                    }
                }
                if !arMode {
                    Section("Background") {
                        ForEach(SplatBackground.allCases, id: \.self) { b in
                            Button { background = b.rawValue } label: { check(b.title, background == b.rawValue) }
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 22, height: 22)
            }
            .glassButton()
            .accessibilityLabel("More")
        }
        .padding(8)
        .glassCard(cornerRadius: 30)
    }

    private var modeSwitch: some View {
        HStack(spacing: 2) {
            ForEach([false, true], id: \.self) { ar in
                Button { arMode = ar } label: {
                    Label(ar ? "AR" : "3D", systemImage: ar ? "arkit" : "cube")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background {
                            if arMode == ar { Capsule().fill(.white.opacity(0.22)) }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(.black.opacity(0.25)))
    }

    private func chip(symbol: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.caption)
            Text(text).font(.subheadline.weight(.semibold)).monospacedDigit()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Capsule().fill(.white.opacity(0.12)))
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private func check(_ title: String, _ on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    /// Tips show for a few seconds; errors stay.
    private func showHint(_ text: String) {
        guard splats != nil else { return }
        hint = text
        let shown = text
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await MainActor.run { if hint == shown && !shown.hasPrefix("Could not") { hint = nil } }
        }
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
            // Level it: SplatForge's up when it sent one, else find the ground.
            orientation = loaded.pcUpOrientation() ?? loaded.autoLevelOrientation()
            loaded.orientation = orientation
            splats = loaded
            status = arMode ? "Move the phone a little, then tap the floor to place the scan"
                            : "Drag to orbit · pinch to zoom · two fingers to move · double-tap to reset"
            showHint(status)
        } catch {
            failed = true
            status = "Could not load: \(error.localizedDescription)"
        }
    }
}

/// Hosts the orbit or AR Metal view.
struct SplatCanvas: UIViewRepresentable {
    let splats: SplatData
    let arMode: Bool
    let orientation: simd_float3x3
    let background: SplatBackground
    let speed: SplatSpeed
    let modelScale: Float
    let inPlaceMap: URL?
    var resetToken: Int = 0
    @Binding var status: String

    final class Container: UIView {
        var lastReset = 0
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
            if splats.orientation != orientation {
                splats.orientation = orientation
            }
            container.ar?.orientationChanged()
            if container.ar?.speed != speed { container.ar?.speed = speed }
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
            if splats.orientation != orientation {
                splats.orientation = orientation
                container.orbit?.resetCamera()
            }
            if container.orbit?.background != background { container.orbit?.background = background }
            if container.orbit?.speed != speed { container.orbit?.speed = speed }
            if container.lastReset != resetToken {
                container.lastReset = resetToken
                container.orbit?.resetCamera()
            }
        }
    }

    static func dismantleUIView(_ container: Container, coordinator: ()) {
        container.ar?.stop()
    }
}
