//
//  VideoImportView.swift
//  Stray SF
//
//  Screens for ordinary videos → splats: choose what to do with a video, the Immich browser, and the list of
//  videos sent to the PC (shown in the Splats tab).
//

import SwiftUI
import PhotosUI
import Photos
import AVKit

/// A video ready in the inbox, waiting for the owner's choice.
struct PendingVideo: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let title: String
}

/// "Make a splat on the PC" or "Align on this phone (beta)".
struct VideoActionsSheet: View {
    let video: PendingVideo
    @Environment(\.dismiss) private var dismiss
    @StateObject private var aligner = PhoneVideoAligner()
    @State private var sent = false
    @State private var thumbnail: UIImage?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18).fill(Color.white.opacity(0.06))
                        if let image = thumbnail {
                            Image(uiImage: image).resizable().scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 18))
                        } else {
                            Image(systemName: "film").font(.system(size: 40)).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxHeight: 260)
                    Text(video.title).font(.headline).lineLimit(2)

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Make a splat on the PC", systemImage: "desktopcomputer").font(.headline)
                        Text("Best quality. The video is uploaded (it keeps going when the phone is locked), SplatForge finds the camera path and trains. The splat appears in the Splats tab.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button {
                            VideoUploader.shared.send(file: video.url, title: video.title)
                            sent = true
                        } label: {
                            Label(sent ? "Sent — see the Splats tab" : "Send to the PC", systemImage: sent ? "checkmark" : "arrow.up.circle")
                                .frame(maxWidth: .infinity, minHeight: 32)
                        }
                        .glassButton(prominent: true)
                        .disabled(sent || isWorking)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassCard(cornerRadius: 20)

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Align on this phone (beta)", systemImage: "iphone").font(.headline)
                        Text("No PC needed. Apple's photogrammetry finds the camera path from up to 300 of the sharpest frames (4 per second; works best for objects and small spaces, filmed slowly with lots of overlap). The result is added to Scans, where Train here makes the splat.")
                            .font(.caption).foregroundStyle(.secondary)
                        alignerStatus
                        if !PhoneVideoAligner.isSupported {
                            Text("Not available on this phone.").font(.caption).foregroundStyle(.orange)
                        }
                        Button {
                            if isWorking { aligner.cancel() } else { aligner.align(video: video.url, title: video.title) }
                        } label: {
                            Label(isWorking ? "Stop" : "Align on this phone", systemImage: isWorking ? "stop.fill" : "point.3.connected.trianglepath.dotted")
                                .frame(maxWidth: .infinity, minHeight: 32)
                        }
                        .glassButton()
                        .disabled(sent || !PhoneVideoAligner.isSupported || isDone)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassCard(cornerRadius: 20)
                }
                .padding(16)
            }
            .navigationTitle("Splat from a video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.disabled(isWorking)
                }
            }
            .onAppear(perform: loadThumbnail)
            .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(isWorking)
    }

    private var isWorking: Bool {
        if case .working = aligner.state { return true }
        return false
    }

    private var isDone: Bool {
        if case .done = aligner.state { return true }
        return false
    }

    @ViewBuilder private var alignerStatus: some View {
        switch aligner.state {
        case .idle:
            EmptyView()
        case .working(let text, let progress):
            VStack(alignment: .leading, spacing: 4) {
                if let p = progress { ProgressView(value: p) } else { ProgressView() }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack {
                        Text(text).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if let start = aligner.stepStarted {
                            // Ticks every second, so a long step never looks frozen.
                            Text(Self.clock(context.date.timeIntervalSince(start)))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(aligner.log, id: \.self) { line in
                    Text(line).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                }
                Text("Keep the app open.").font(.caption2).foregroundStyle(.secondary)
            }
        case .done(let text):
            Label("Aligned: \(text). Open it in Scans and tap Train here.", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .failed(let text):
            Label(text, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
        }
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func loadThumbnail() {
        let url = video.url
        DispatchQueue.global(qos: .userInitiated).async {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 800, height: 800)
            let image = (try? generator.copyCGImage(at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil)).map { UIImage(cgImage: $0) }
            DispatchQueue.main.async { thumbnail = image }
        }
    }
}

/// Videos on the owner's Immich server, newest first; tap one to download it and choose what to do.
struct ImmichBrowserView: View {
    let onPicked: (PendingVideo) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var videos: [ImmichVideo] = []
    @State private var page = 1
    @State private var more = false
    @State private var error: String?
    @State private var loading = false
    @State private var downloading: String?
    @State private var thumbs: [String: UIImage] = [:]

    var body: some View {
        NavigationStack {
            Group {
                if !ImmichSettings.load().isSet {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.stack").font(.system(size: 44)).foregroundStyle(.secondary)
                        Text("Add your Immich server address and API key in the Settings tab first.")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    }
                    .padding(32)
                } else {
                    ScrollView {
                        if let error = error {
                            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).padding()
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                            ForEach(videos) { video in
                                Button { download(video) } label: { tile(video) }
                                    .buttonStyle(.plain)
                                    .disabled(downloading != nil)
                                    .task { await loadThumb(video) }
                            }
                        }
                        .padding(8)
                        if more {
                            Button("Load more") { Task { await load(page + 1) } }.padding()
                        }
                        if loading { ProgressView().padding() }
                    }
                }
            }
            .navigationTitle("Immich videos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .task { if videos.isEmpty && ImmichSettings.load().isSet { await load(1) } }
        }
        .preferredColorScheme(.dark)
    }

    private func tile(_ video: ImmichVideo) -> some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(Color.white.opacity(0.06))
            if let image = thumbs[video.id] {
                Image(uiImage: image).resizable().scaledToFill()
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(video.duration).font(.caption2.monospacedDigit().weight(.semibold))
                Text(video.date).font(.caption2)
            }
            .padding(4)
            .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .padding(4)
            if downloading == video.id {
                Color.black.opacity(0.5)
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 140)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func load(_ p: Int) async {
        loading = true
        defer { loading = false }
        do {
            let result = try await ImmichClient.videos(ImmichSettings.load(), page: p)
            videos += result.videos
            more = result.more
            page = p
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadThumb(_ video: ImmichVideo) async {
        guard thumbs[video.id] == nil else { return }
        if let image = await ImmichClient.thumbnail(ImmichSettings.load(), id: video.id) { thumbs[video.id] = image }
    }

    private func download(_ video: ImmichVideo) {
        downloading = video.id
        Task {
            do {
                let file = try await ImmichClient.download(ImmichSettings.load(), video: video)
                downloading = nil
                dismiss()
                onPicked(PendingVideo(url: file, title: video.name))
            } catch {
                downloading = nil
                self.error = error.localizedDescription
            }
        }
    }
}

/// Copies a video chosen in the Photos picker into the app and hands it on.
enum PhotosVideoLoader {
    /// Writes the asset's original video to the inbox. nil when the app may not read the library.
    static func original(_ id: String) async throws -> URL? {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        guard status == .authorized || status == .limited,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .fullSizeVideo })
                ?? resources.first(where: { $0.type == .video }) else { return nil }
        let ext = (resource.originalFilename as NSString).pathExtension.lowercased()
        let url = VideoInbox.folder.appendingPathComponent(String(UUID().uuidString.prefix(8)) + "." + (ext.isEmpty ? "mov" : ext))
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true     // iCloud Photos with "Optimise storage"
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                if let error = error { done.resume(throwing: error) } else { done.resume() }
            }
        }
        return url
    }

    static func load(_ item: PhotosPickerItem) async throws -> PendingVideo {
        // Best path: the original file straight from the library (also downloads iCloud-only videos).
        if let id = item.itemIdentifier, let url = try await original(id) {
            return PendingVideo(url: url, title: "Video from Photos")
        }
        // Photos videos are QuickTime or MPEG-4; ask for the movie file itself.
        if let movie = try await item.loadTransferable(type: PickedMovie.self) {
            return PendingVideo(url: movie.url, title: "Video from Photos")
        }
        // Fallback: the raw bytes (slower, but works for every format Photos can hand over).
        if let data = try await item.loadTransferable(type: Data.self) {
            let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "mov"
            let url = VideoInbox.folder.appendingPathComponent(String(UUID().uuidString.prefix(8)) + "." + ext)
            try data.write(to: url)
            return PendingVideo(url: url, title: "Video from Photos")
        }
        throw TrainError("Photos did not hand over the video (types: "
                         + item.supportedContentTypes.map(\.identifier).joined(separator: ", ") + ")")
    }
}

/// Splats tab section: start from a video, and the videos already sent to the PC.
/// (The pickers themselves are attached to the whole list in SplatForgeView: modifiers on a List section are
/// copied onto every row, which made the Photos picker fire badly.)
struct VideoSourcesSection: View {
    @Binding var showingPhotos: Bool
    @Binding var showingImmich: Bool
    let importing: Bool
    let importError: String?
    @ObservedObject private var uploader = VideoUploader.shared

    var body: some View {
        Section {
            Button {
                showingPhotos = true
            } label: {
                Label(importing ? "Copying the video…" : "Video from Photos", systemImage: "photo.on.rectangle")
            }
            .disabled(importing)
            Button {
                showingImmich = true
            } label: {
                Label("Video from Immich", systemImage: "server.rack")
            }
            if importing { ProgressView() }
            if let error = importError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            ForEach(uploader.jobs) { job in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: job.failed ? "exclamationmark.triangle.fill" : "film")
                            .foregroundStyle(job.failed ? Color.orange : Color.secondary)
                        Text(job.title).font(.subheadline).lineLimit(1)
                        Spacer()
                        Button {
                            uploader.remove(job.id)
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove from the list")
                    }
                    if let p = job.progress { ProgressView(value: p) }
                    Text(job.status).font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Splat from a video")
        } footer: {
            Text("Any video works: from Photos, Immich, or “Open in Stray SF” from Files. The PC gives the best splat; aligning on the phone is a beta.")
        }
    }
}
