//
//  ScanSummary.swift
//  StrayScanner
//
//  Per-scan statistics for the list and detail screens, plus Liquid Glass helpers
//  for SwiftUI (stray-scanner-sf fork).
//

import SwiftUI

struct ScanSummary {
    var shutter: String?
    var frames: Int = 0
    var sharpFraction: Double?   // share of frames with estimated blur <= 1.5 px
    var medianBlur: Double?
    var limitedTrackingFrames: Int = 0
    var markers: Int = 0
    var sizeBytes: Int64 = 0

    static func load(directory: URL?) -> ScanSummary {
        var summary = ScanSummary()
        guard let directory = directory else { return summary }
        let fm = FileManager.default

        if let data = try? Data(contentsOf: directory.appendingPathComponent("capture_settings.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            summary.shutter = json["shutter_setting"] as? String
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
        if let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let file as URL in enumerator {
                summary.sizeBytes += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return summary
    }
}

/// Small rounded label used for scan stats.
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

    var body: some View {
        let items = chips
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(0..<min(3, items.count), id: \.self) { items[$0] }
            }
            if items.count > 3 {
                HStack(spacing: 6) {
                    ForEach(3..<items.count, id: \.self) { items[$0] }
                }
            }
        }
    }

    private var chips: [StatChip] {
        var result: [StatChip] = []
        if let shutter = summary.shutter {
            result.append(StatChip(symbol: "camera.aperture", text: shutter == "Auto" ? "Auto" : "\(shutter) s"))
        }
        result.append(StatChip(symbol: "film.stack", text: "\(summary.frames)"))
        if let sharp = summary.sharpFraction {
            let tint: Color = sharp > 0.85 ? .green : (sharp > 0.6 ? .yellow : .red)
            result.append(StatChip(symbol: "scope", text: "\(Int(sharp * 100))% sharp", tint: tint))
        }
        if summary.markers > 0 {
            result.append(StatChip(symbol: "mappin.and.ellipse", text: "\(summary.markers)"))
        }
        if summary.sizeBytes > 0 {
            result.append(StatChip(symbol: "internaldrive", text: ByteCountFormatter.string(fromByteCount: summary.sizeBytes, countStyle: .file)))
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
