//
//  VideoImportView.swift
//  Stray SF
//
//  Screens for ordinary videos → splats: choose what to do with a video, the Immich browser, and the list of
//  videos sent to the PC (shown in the Splats tab).
//

import SwiftUI
import PhotosUI
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
                        Text("No PC needed. Apple's photogrammetry finds the camera path from about 150 frames (works best for objects and small spaces, filmed slowly with lots of overlap). The result is added to Scans, where Train here makes the splat.")
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
            .navigationTitle("Video to splat")
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
                Text(text).font(.caption).foregroundStyle(.secondary)
                Text("Keep the app open.").font(.caption2).foregroundStyle(.secondary)
            }
        case .done(let text):
            Label("Aligned: \(text). Open it in Scans and tap Train here.", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .failed(let text):
            Label(text, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
        }
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

/// Splats tab section: start from a video, and the videos already sent to the PC.
struct VideoSourcesSection: View {
    @Binding var pending: PendingVideo?
    @ObservedObject private var uploader = VideoUploader.shared
    @State private var pickerItem: PhotosPickerItem?
    @State private var showingImmich = false
    @State private var importing = false
    @State private var importError: String?

    var body: some View {
        Section {
            PhotosPicker(selection: $pickerItem, matching: .videos, photoLibrary: .shared()) {
                Label(importing ? "Copying the video…" : "Video from Photos", systemImage: "photo.on.rectangle")
            }
            .disabled(importing)
            Button {
                showingImmich = true
            } label: {
                Label("Video from Immich", systemImage: "server.rack")
            }
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
            Text("From a video")
        } footer: {
            Text("Any video works: from Photos, Immich, or “Open in Stray SF” from Files. The PC gives the best splat; aligning on the phone is a beta.")
        }
        .onChange(of: pickerItem) { item in
            guard let item = item else { return }
            importing = true
            importError = nil
            Task {
                defer { Task { @MainActor in importing = false; pickerItem = nil } }
                do {
                    if let movie = try await item.loadTransferable(type: PickedMovie.self) {
                        await MainActor.run { pending = PendingVideo(url: movie.url, title: movie.url.lastPathComponent) }
                    } else {
                        await MainActor.run { importError = "Could not read that video" }
                    }
                } catch {
                    await MainActor.run { importError = error.localizedDescription }
                }
            }
        }
        .sheet(isPresented: $showingImmich) {
            ImmichBrowserView { video in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { pending = video }
            }
        }
    }
}
