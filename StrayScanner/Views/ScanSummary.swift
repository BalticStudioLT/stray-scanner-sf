//
//  ScanSummary.swift
//  StrayScanner
//
//  Per-scan statistics for the list and detail screens, plus Liquid Glass helpers
//  for SwiftUI (stray-scanner-sf fork).
//

import SwiftUI

struct ScanSummary: Codable {
    var shutter: String?
    var frames: Int = 0
    var sharpFraction: Double?   // share of frames with estimated blur <= 1.5 px
    var medianBlur: Double?
    var limitedTrackingFrames: Int = 0
    var markers: Int = 0
    var ultraWidePasses: Int = 0
    var sizeBytes: Int64 = 0
    var photos: Int = 0
    var videoQuality: String?
    /// These two can change at any time, so they are looked up on every load and never cached.
    var sentToPC = false
    var hasPhoneSplat = false

    private enum CodingKeys: String, CodingKey {
        case shutter, frames, sharpFraction, medianBlur, limitedTrackingFrames, markers, ultraWidePasses, sizeBytes
        case photos, videoQuality
    }

    private struct Cached: Codable {
        let signature: String
        let summary: ScanSummary
    }

    private static var memory: [String: Cached] = [:]
    private static let lock = NSLock()

    /// Changes when the scan's own files change (a pass or a phone splat added), so the cache never goes stale.
    private static func signature(_ directory: URL) -> String {
        let fm = FileManager.default
        func stamp(_ url: URL) -> String {
            let date = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            return String(Int(date?.timeIntervalSince1970 ?? 0))
        }
        return "v2|" + stamp(directory) + "|" + stamp(directory.appendingPathComponent("passes"))
            + "|" + stamp(directory.appendingPathComponent("odometry.csv"))
    }

    private static func cacheURL(_ directory: URL) -> URL? {
        let fm = FileManager.default
        guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let folder = caches.appendingPathComponent("summaries", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(directory.lastPathComponent + ".json")
    }

    /// Reading a scan's numbers means parsing its CSV files and walking tens of thousands of small files.
    /// That is done once per scan; afterwards the list and the scan page open from a small cache file.
    static func load(directory: URL?) -> ScanSummary {
        guard let directory = directory else { return ScanSummary() }
        let key = directory.lastPathComponent
        let wanted = signature(directory)
        var found: ScanSummary?
        lock.lock()
        if let hit = memory[key], hit.signature == wanted { found = hit.summary }
        lock.unlock()
        if found == nil, let url = cacheURL(directory), let data = try? Data(contentsOf: url),
           let cached = try? JSONDecoder().decode(Cached.self, from: data), cached.signature == wanted {
            found = cached.summary
        }
        if found == nil {
            let computed = compute(directory: directory)
            found = computed
            if let url = cacheURL(directory), let data = try? JSONEncoder().encode(Cached(signature: wanted, summary: computed)) {
                try? data.write(to: url, options: .atomic)
            }
        }
        var summary = found ?? ScanSummary()
        lock.lock()
        memory[key] = Cached(signature: wanted, summary: summary)
        lock.unlock()
        summary.sentToPC = PCUploader.wasUploaded(key)
        summary.hasPhoneSplat = FileManager.default.fileExists(atPath: directory.appendingPathComponent("phone_splat.ply").path)
        return summary
    }

    private static func compute(directory: URL) -> ScanSummary {
        var summary = ScanSummary()
        let fm = FileManager.default

        if let data = try? Data(contentsOf: directory.appendingPathComponent("capture_settings.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            summary.shutter = json["shutter_setting"] as? String
            summary.videoQuality = json["video_quality"] as? String
        }
        if let odometry = try? String(contentsOf: directory.appendingPathComponent("odometry.csv"), encoding: .utf8) {
            summary.frames = max(odometry.split(separator: "\n").count - 1, 0)
        }
        if let quality = try? String(contentsOf: directory.appendingPathComponent("frame_quality.csv"), encoding: .utf8) {
            var blurs: [Double] = []
            for line in quality.split(separator: "\n").dropFirst() {
                let fields = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                guard fields.count >= 7 else { continue }
                if fields[2] != "normal" { summary.limitedTrackingFrames += 1 }
                if let blur = Double(fields[6]) { blurs.append(blur) }
            }
            if !blurs.isEmpty {
                summary.sharpFraction = Double(blurs.filter { $0 <= 1.5 }.count) / Double(blurs.count)
                summary.medianBlur = blurs.sorted()[blurs.count / 2]
            }
        }
        if let markers = try? String(contentsOf: directory.appendingPathComponent("markers.csv"), encoding: .utf8) {
            summary.markers = max(markers.split(separator: "\n").count - 1, 0)
        }
        if let stills = try? String(contentsOf: directory.appendingPathComponent("stills.csv"), encoding: .utf8) {
            summary.photos = max(stills.split(separator: "\n").count - 1, 0)
        }
        if let passes = try? fm.contentsOfDirectory(at: directory.appendingPathComponent("passes"), includingPropertiesForKeys: nil) {
            summary.ultraWidePasses = passes.filter { $0.hasDirectoryPath }.count
        }
        if let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let file as URL in enumerator {
                summary.sizeBytes += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return summary
    }
}

struct StatChip: View {
    let symbol: String
    let text: String
    var tint: Color = .white

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(text)
        }
        .font(.caption.weight(.semibold).monospacedDigit())
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .glassCard(cornerRadius: 10)
    }
}

struct ScanSummaryChips: View {
    let summary: ScanSummary
    /// The scan list shows the few that matter; the scan page shows everything.
    var compact: Bool = false

    var body: some View {
        let items = chips
        let perRow = 3
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<((items.count + perRow - 1) / perRow), id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach((row * perRow)..<min((row + 1) * perRow, items.count), id: \.self) { items[$0] }
                }
            }
        }
    }

    private var chips: [StatChip] {
        var result: [StatChip] = []
        if !compact, let shutter = summary.shutter {
            result.append(StatChip(symbol: "camera.aperture", text: shutter == "Auto" ? "Auto" : "\(shutter) s"))
        }
        if !compact {
            result.append(StatChip(symbol: "film.stack", text: "\(summary.frames)"))
        }
        if let sharp = summary.sharpFraction {
            let tint: Color = sharp > 0.85 ? .green : (sharp > 0.6 ? .yellow : .red)
            result.append(StatChip(symbol: "scope", text: "\(Int(sharp * 100))% sharp", tint: tint))
        }
        if summary.sizeBytes > 0 {
            result.append(StatChip(symbol: "internaldrive", text: ByteCountFormatter.string(fromByteCount: summary.sizeBytes, countStyle: .file)))
        }
        if summary.sentToPC {
            result.append(StatChip(symbol: "desktopcomputer", text: "On PC", tint: .green))
        }
        if summary.hasPhoneSplat {
            result.append(StatChip(symbol: "cube.transparent", text: "Splat", tint: .cyan))
        }
        if summary.photos > 0 {
            result.append(StatChip(symbol: "photo.on.rectangle", text: "\(summary.photos)"))
        }
        if !compact, summary.markers > 0 {
            result.append(StatChip(symbol: "mappin.and.ellipse", text: "\(summary.markers)"))
        }
        if summary.ultraWidePasses > 0 {
            result.append(StatChip(symbol: "camera.aperture", text: "+\(summary.ultraWidePasses)× 0.5×", tint: .cyan))
        }
        return result
    }
}

extension View {
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 20) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            if prominent {
                self.buttonStyle(.borderedProminent)
            } else {
                self.buttonStyle(.bordered)
            }
        }
    }
}
