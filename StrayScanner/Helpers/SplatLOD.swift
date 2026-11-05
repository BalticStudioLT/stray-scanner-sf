//
//  SplatLOD.swift
//  Stray SF
//
//  Level-of-detail streaming from SplatForge (/api/splat/lod/*, roadmap item 7) and the compact fmt=3 decoder.
//  The whole scene opens from the coarse level (L0, ~10 % of the splats); chunks close to the camera are fetched at
//  L1 (35 %) or L2 (100 %) and swapped in. Levels replace each other per chunk (coarse levels have grown scales),
//  so a chunk is always drawn at exactly one level. Everything stays within a splat budget (the Quality setting).
//

import Foundation
import Metal
import simd

// MARK: - fmt=3 (26 B/splat with SH1, 17 B without)

struct DecodedSplats {
    let count: Int
    let gs: Data          // GSplat records, 32 B each (viewer GPU format)
    let sh: Data?         // 9 halves per splat, or nil
    let positions: [SIMD3<Float>]
}

enum SplatFormat3 {
    /// u32 N, u32 3, u32 sh, u32 0 | f32 pos_min[3], pos_max[3], lsc_min, lsc_max, sh_max, 0 | u16 pos[N·3] |
    /// u8 log-scale[N·3] | u8 quat[N·4] (w,x,y,z) | u8 rgba[N·4] | i8 sh1[N·9]
    static func decode(_ data: Data) throws -> DecodedSplats {
        guard data.count >= 56 else { throw SplatLoaderError.bad("Splat data is cut off") }
        return try data.withUnsafeBytes { raw -> DecodedSplats in
            let b = raw.baseAddress!
            func u32(_ o: Int) -> UInt32 { b.loadUnaligned(fromByteOffset: o, as: UInt32.self) }
            func f32(_ o: Int) -> Float { b.loadUnaligned(fromByteOffset: o, as: Float.self) }
            let n = Int(u32(0))
            guard u32(4) == 3 else { throw SplatLoaderError.bad("Not fmt=3") }
            let hasSH = u32(8) == 1
            let pmin = SIMD3<Float>(f32(16), f32(20), f32(24)), pmax = SIMD3<Float>(f32(28), f32(32), f32(36))
            let lmin = f32(40), lmax = f32(44), shMax = f32(48)
            let posO = 56, lscO = posO + n * 6, quatO = lscO + n * 3, rgbaO = quatO + n * 4, shO = rgbaO + n * 4
            guard data.count >= shO + (hasSH ? n * 9 : 0) else { throw SplatLoaderError.bad("Splat data is cut off") }
            var gs = Data(count: n * SplatLoader.stride)
            var positions = [SIMD3<Float>](repeating: .zero, count: n)
            let extent = pmax - pmin
            gs.withUnsafeMutableBytes { out in
                let o = out.baseAddress!
                for i in 0..<n {
                    let q = SIMD3<Float>(Float(b.loadUnaligned(fromByteOffset: posO + i * 6, as: UInt16.self)),
                                         Float(b.loadUnaligned(fromByteOffset: posO + i * 6 + 2, as: UInt16.self)),
                                         Float(b.loadUnaligned(fromByteOffset: posO + i * 6 + 4, as: UInt16.self)))
                    let p = pmin + q / 65535 * extent
                    positions[i] = p
                    var scale = SIMD3<Float>(repeating: 0)
                    for k in 0..<3 {
                        let l = lmin + Float(b.load(fromByteOffset: lscO + i * 3 + k, as: UInt8.self)) / 255 * (lmax - lmin)
                        scale[k] = exp(l)
                    }
                    func qc(_ k: Int) -> Float { Float(b.load(fromByteOffset: quatO + i * 4 + k, as: UInt8.self)) / 127.5 - 1 }
                    var rot = simd_quatf(ix: qc(1), iy: qc(2), iz: qc(3), r: qc(0))
                    rot = simd_length(rot.vector) > 1e-6 ? simd_normalize(rot) : simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
                    let m = simd_float3x3(rot) * simd_float3x3(diagonal: scale)
                    let cov = m * m.transpose
                    let rec = o.advanced(by: i * SplatLoader.stride)
                    rec.storeBytes(of: p.x, toByteOffset: 0, as: Float.self)
                    rec.storeBytes(of: p.y, toByteOffset: 4, as: Float.self)
                    rec.storeBytes(of: p.z, toByteOffset: 8, as: Float.self)
                    SplatLoader.packCov([cov[0, 0], cov[0, 1], cov[0, 2], cov[1, 1], cov[1, 2], cov[2, 2]], into: rec)
                    rec.advanced(by: 24).copyMemory(from: b.advanced(by: rgbaO + i * 4), byteCount: 4)
                }
            }
            var sh: Data?
            if hasSH {
                var shData = Data(count: n * 18)
                shData.withUnsafeMutableBytes { out in
                    let h = out.bindMemory(to: Float16.self)
                    for j in 0..<(n * 9) {
                        h[j] = Float16(Float(b.load(fromByteOffset: shO + j, as: Int8.self)) / 127 * shMax)
                    }
                }
                sh = shData
            }
            return DecodedSplats(count: n, gs: gs, sh: sh, positions: positions)
        }
    }
}

// MARK: - LOD streaming

final class SplatLOD {
    struct Chunk {
        let id: Int
        let min: SIMD3<Float>
        let max: SIMD3<Float>
        let levelSplats: [Int]
    }

    let ply: String
    private let settings = PCLinkSettings.load()
    private let device: MTLDevice
    private(set) var chunks: [Chunk] = []
    private(set) var up: SIMD3<Float>?
    private(set) var hasSH = false
    let budget: Int

    // Main-thread state.
    private var cache: [Int: [Int: DecodedSplats]] = [:]   // chunk → level → data
    private var shown: [Int: Int] = [:]
    private var wanted: [Int: Int] = [:]
    private var inFlight = Set<String>()
    private var lastEye = SIMD3<Float>(repeating: .infinity)
    private var composing = false
    private var ready: SplatData?
    private var buffers: [SplatData] = []
    private var active = 0
    private var basePositions: [SIMD3<Float>] = []
    private let composeQueue = DispatchQueue(label: "lod.compose", qos: .userInitiated)
    /// Called on the main thread when a refined set is waiting (views that draw on demand redraw then).
    var onRefined: (() -> Void)?

    init(ply: String, device: MTLDevice, budget: Int) {
        self.ply = ply
        self.device = device
        self.budget = budget
    }

    var totalFull: Int { chunks.reduce(0) { $0 + ($1.levelSplats.last ?? 0) } }

    /// Index + all chunks at L0 → the first SplatData (nil if this Studio has no LOD API).
    func open(progress: @escaping (String) -> Void) async throws -> SplatData? {
        guard let url = settings.url("/api/splat/lod/index", query: ["ply": ply]) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 180)
        request.setValue(settings.token, forHTTPHeaderField: "X-Token")
        progress("Preparing levels on the PC…")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["chunks"] as? [[String: Any]], !list.isEmpty else { return nil }
        if let u = json["up"] as? [Double], u.count == 3 { up = SIMD3(Float(u[0]), Float(u[1]), Float(u[2])) }
        chunks = list.compactMap { c in
            guard let id = c["id"] as? Int, let a = c["bbox_min"] as? [Double], let b = c["bbox_max"] as? [Double],
                  let levels = c["levels"] as? [[String: Any]] else { return nil }
            return Chunk(id: id, min: SIMD3(Float(a[0]), Float(a[1]), Float(a[2])), max: SIMD3(Float(b[0]), Float(b[1]), Float(b[2])),
                         levelSplats: levels.map { ($0["splats"] as? Int) ?? 0 })
        }
        let capacity = min(budget, max(totalFull, 1))
        progress("Downloading the whole scene (coarse)…")
        try await withThrowingTaskGroup(of: (Int, DecodedSplats).self) { group in
            var next = 0
            func add() {
                guard next < chunks.count else { return }
                let id = chunks[next].id
                next += 1
                group.addTask { (id, try await self.fetch(id: id, level: 0)) }
            }
            for _ in 0..<4 { add() }
            var done = 0
            while let (id, decoded) = try await group.next() {
                cache[id, default: [:]][0] = decoded
                shown[id] = 0
                done += 1
                if done % 8 == 0 { progress("Downloading the whole scene (coarse)… \(done)/\(chunks.count)") }
                add()
            }
        }
        hasSH = cache.values.contains { $0[0]?.sh != nil }
        basePositions = chunks.flatMap { cache[$0.id]?[0]?.positions ?? [] }
        for _ in 0..<2 {
            guard let buffer = device.makeBuffer(length: max(capacity, 1) * SplatLoader.stride, options: .storageModeShared) else {
                throw SplatLoaderError.bad("Not enough GPU memory")
            }
            let s = SplatData(count: 0, buffer: buffer, positions: basePositions, capacity: capacity)
            if hasSH { s.sh = device.makeBuffer(length: max(capacity, 1) * 18, options: .storageModeShared) }
            buffers.append(s)
        }
        let first = buffers[0]
        compose(into: first, pieces: pieces(shown))
        active = 0
        return first
    }

    private func fetch(id: Int, level: Int) async throws -> DecodedSplats {
        guard let url = settings.url("/api/splat/lod/chunk", query: ["ply": ply, "id": String(id), "level": String(level),
                                                                     "sh": "1", "fmt": "3"]) else { throw SplatLoaderError.bad("No PC address") }
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.setValue(settings.token, forHTTPHeaderField: "X-Token")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SplatLoaderError.bad("Chunk \(id) failed") }
        return try SplatFormat3.decode(data)
    }

    /// Copies the chosen level of every chunk into `target` (one level per chunk, within capacity).
    private func pieces(_ levels: [Int: Int]) -> [DecodedSplats] {
        chunks.compactMap { c in levels[c.id].flatMap { cache[c.id]?[$0] } ?? cache[c.id]?[0] }
    }

    /// Runs off the main thread on a snapshot (no shared dictionaries touched).
    private func compose(into target: SplatData, pieces: [DecodedSplats]) {
        var n = 0
        let gsOut = target.buffer.contents()
        let shOut = target.sh?.contents()
        for d in pieces {
            guard n + d.count <= target.capacity else { continue }
            d.gs.withUnsafeBytes { gsOut.advanced(by: n * SplatLoader.stride).copyMemory(from: $0.baseAddress!, byteCount: d.gs.count) }
            if let shOut = shOut {
                if let sh = d.sh {
                    sh.withUnsafeBytes { shOut.advanced(by: n * 18).copyMemory(from: $0.baseAddress!, byteCount: sh.count) }
                } else {
                    memset(shOut.advanced(by: n * 18), 0, d.count * 18)
                }
            }
            n += d.count
        }
        target.count = n
    }

    /// Called from the renderer every frame with the camera (splat-file coordinates). Cheap unless it moved.
    func update(eye: SIMD3<Float>, focal: Float) {
        guard !chunks.isEmpty, simd_distance(eye, lastEye) > 0.05 || wanted.isEmpty else { return }
        lastEye = eye
        // Wanted level from the chunk's size on screen.
        var plan: [(chunk: Chunk, px: Float, level: Int)] = chunks.map { c in
            let nearest = simd_clamp(eye, c.min, c.max)
            let dist = max(simd_distance(eye, nearest), 0.1)
            let px = simd_length(c.max - c.min) / dist * focal
            let level = px > 1500 ? 2 : (px > 500 ? 1 : 0)
            return (c, px, min(level, c.levelSplats.count - 1))
        }
        // Stay within the budget: downgrade the smallest-on-screen chunks first.
        var total = plan.reduce(0) { $0 + $1.chunk.levelSplats[$1.level] }
        for i in plan.indices.sorted(by: { plan[$0].px < plan[$1].px }) where total > budget {
            while plan[i].level > 0 && total > budget {
                total -= plan[i].chunk.levelSplats[plan[i].level] - plan[i].chunk.levelSplats[plan[i].level - 1]
                plan[i].level -= 1
            }
        }
        wanted = Dictionary(uniqueKeysWithValues: plan.map { ($0.chunk.id, $0.level) })
        // Fetch what's missing, nearest first, 3 at a time.
        for item in plan.sorted(by: { $0.px > $1.px }) where item.level > 0 && cache[item.chunk.id]?[item.level] == nil {
            let key = "\(item.chunk.id)/\(item.level)"
            guard inFlight.count < 3, !inFlight.contains(key) else { continue }
            inFlight.insert(key)
            let id = item.chunk.id, level = item.level
            Task {
                let decoded = try? await self.fetch(id: id, level: level)
                await MainActor.run {
                    self.inFlight.remove(key)
                    if let d = decoded { self.cache[id, default: [:]][level] = d }
                    self.lastEye = SIMD3<Float>(repeating: .infinity)   // re-plan
                    self.recomposeIfNeeded()
                }
            }
        }
        recomposeIfNeeded()
    }

    private func recomposeIfNeeded() {
        guard !composing, !buffers.isEmpty else { return }
        // Best available level ≤ wanted for each chunk; drop finer levels nobody wants (memory).
        var levels: [Int: Int] = [:]
        for c in chunks {
            let want = wanted[c.id] ?? 0
            var l = want
            while l > 0 && cache[c.id]?[l] == nil { l -= 1 }
            levels[c.id] = l
            for extra in (cache[c.id]?.keys.filter { $0 > want && $0 != l }) ?? [] { cache[c.id]?[extra] = nil }
        }
        guard levels != shown else { return }
        composing = true
        let target = buffers[1 - active]
        let snapshot = levels
        let parts = pieces(levels)
        composeQueue.async {
            self.compose(into: target, pieces: parts)
            DispatchQueue.main.async {
                self.shown = snapshot
                self.active = 1 - self.active
                self.ready = target
                self.composing = false
                self.onRefined?()
            }
        }
    }

    /// Orientation lives on each SplatData; keep both LOD buffers in step.
    func setOrientation(_ m: simd_float3x3) {
        for b in buffers where b.orientation != m { b.orientation = m }
    }

    /// The buffer currently shown (for a view created later, e.g. switching 3D ↔ AR).
    var current: SplatData? { buffers.isEmpty ? nil : buffers[active] }

    /// The refined set, once (the renderer swaps it in).
    func takeReady() -> SplatData? {
        defer { ready = nil }
        return ready
    }

    var detailSummary: String {
        let counts = (0...2).map { l in shown.values.filter { $0 == l }.count }
        return "chunks L0 \(counts[0]) · L1 \(counts[1]) · L2 \(counts[2])"
    }
}
