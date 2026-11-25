//
//  SessionRow.swift
//  Stray Scanner
//
//  Created by Kenneth Blomqvist on 11/15/20.
//  Copyright © 2020 Stray Robots. All rights reserved.
//
//  stray-scanner-sf: thumbnail, own name, and what happened to the scan (on the PC, splat made).
//

import SwiftUI
import AVFoundation

extension Recording {
    private static let titleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter
    }()

    /// A name typed by the owner; the automatic "Recording 12" does not count.
    var customName: String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        if name.hasPrefix("Recording "), Int(name.dropFirst("Recording ".count)) != nil { return nil }
        return name
    }

    var dateTitle: String {
        guard let created = createdAt else { return "Scan" }
        return Recording.titleFormatter.string(from: created)
    }

    var displayTitle: String { return customName ?? dateTitle }
}

/// Small upright picture of a scan: one video frame, made once and kept in the app's cache folder.
enum ScanThumbnail {
    private static let cache = NSCache<NSString, UIImage>()

    static func cached(_ key: String) -> UIImage? {
        return cache.object(forKey: key as NSString)
    }

    /// Call on a background queue.
    static func load(video: URL, key: String) -> UIImage? {
        if let hit = cache.object(forKey: key as NSString) { return hit }
        let fm = FileManager.default
        guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let folder = caches.appendingPathComponent("thumbs", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(key + ".jpg")
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
            cache.setObject(image, forKey: key as NSString)
            return image
        }
        guard fm.fileExists(atPath: video.path) else { return nil }
        let asset = AVURLAsset(url: video)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: 720, height: 720)   // also shown large on the scan's page
        generator.appliesPreferredTrackTransform = false
        let seconds = CMTimeGetSeconds(asset.duration)
        let time = CMTime(seconds: (seconds.isFinite && seconds > 2) ? 1.0 : 0.0, preferredTimescale: 600)
        guard let frame = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
        // The video is stored the way the sensor sees it (landscape); scans are filmed upright.
        let upright = UIImage(cgImage: frame, scale: 1, orientation: .right)
        let size = CGSize(width: frame.height, height: frame.width)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            upright.draw(in: CGRect(origin: .zero, size: size))
        }
        if let data = rendered.jpegData(compressionQuality: 0.8) {
            try? data.write(to: file, options: .atomic)
        }
        cache.setObject(rendered, forKey: key as NSString)
        return rendered
    }
}

struct ScanThumbnailView: View {
    let video: URL?
    let key: String
    var width: CGFloat = 60
    var height: CGFloat = 80
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.08))
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
            } else {
                Image(systemName: "viewfinder")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onAppear(perform: load)
    }

    private func load() {
        guard image == nil, let video = video else { return }
        if let hit = ScanThumbnail.cached(key) {
            image = hit
            return
        }
        let name = key
        DispatchQueue.global(qos: .utility).async {
            let loaded = ScanThumbnail.load(video: video, key: name)
            DispatchQueue.main.async { image = loaded }
        }
    }
}

struct SessionRow: View {
    var session: Recording
    /// Passed in as a value so the row redraws when the scan is renamed.
    var title: String
    @State private var summary: ScanSummary?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ScanThumbnailView(video: session.absoluteRgbPath(),
                              key: session.directoryPath()?.lastPathComponent ?? "none")
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let summary = summary {
                    ScanSummaryChips(summary: summary, compact: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .onAppear {
            let directory = session.directoryPath()
            DispatchQueue.global(qos: .utility).async {
                let loaded = ScanSummary.load(directory: directory)
                DispatchQueue.main.async { summary = loaded }
            }
        }
    }

    /// Length of the scan, and the date when the title is a name.
    private var subtitle: String {
        let seconds = Int(session.duration.rounded())
        let length = seconds >= 60 ? String(format: "%d min %02d s", seconds / 60, seconds % 60) : "\(seconds) s"
        return session.customName == nil ? length : "\(session.dateTitle) · \(length)"
    }
}
