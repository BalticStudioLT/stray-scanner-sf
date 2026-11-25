//
//  SessionDetailView.swift
//  StrayScanner
//
//  Created by Kenneth Blomqvist on 12/30/20.
//  Copyright © 2020 Stray Robots. All rights reserved.
//

import SwiftUI
import AVKit
import CoreData

class SessionDetailViewModel: ObservableObject {
    private var dataContext: NSManagedObjectContext?

    init() {
        let appDelegate = UIApplication.shared.delegate as? AppDelegate
        self.dataContext = appDelegate?.persistentContainer.viewContext
    }
    
    func title(recording: Recording) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        dateFormatter.timeStyle = .short
        
        if let created = recording.createdAt {
            return dateFormatter.string(from: created)
        } else {
            return recording.name ?? "Recording"
        }
    }

    func delete(recording: Recording) {
        recording.deleteFiles()
        self.dataContext?.delete(recording)
        do {
            try self.dataContext?.save()
        } catch let error as NSError {
            print("Could not save recording. \(error), \(error.userInfo)")
        }
    }
}

struct SessionDetailView: View {
    @ObservedObject var viewModel = SessionDetailViewModel()
    var recording: Recording
    @Environment(\.presentationMode) var presentationMode: Binding<PresentationMode>
    @State private var showingShareSheet = false
    @State private var tempPackageURL: URL?
    @State private var isCreatingPackage = false
    @State private var shareError: String?
    @State private var summary: ScanSummary?
    @State private var pcStatus: String?
    @State private var pcProgress: Double?
    @State private var title = ""
    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        ZStack {
        Color("BackgroundColor")
            .edgesIgnoringSafeArea(.all)
        ScrollView {
        VStack {
            header

            if let status = pcStatus {
                VStack(spacing: 8) {
                    if let progress = pcProgress {
                        ProgressView(value: progress)
                    }
                    Text(status).font(.caption).foregroundStyle(.secondary)
                    if canResume {
                        Button {
                            if let folder = recording.directoryPath() { PCUploader.shared.restart(directory: folder) }
                            pcStatus = "Starting again…"
                            pcProgress = 0
                        } label: {
                            Label(uploading ? "Restart upload" : "Resume upload", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity, minHeight: 32)
                        }
                        .glassButton(prominent: !uploading)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 10)
            }

            if let folder = recording.directoryPath() {
                ScanSplatsSection(folder: folder)
            }

            // Two even columns of full-width buttons (an HStack squeezed the labels into tall empty pills).
            let folder = recording.directoryPath()
            let canContinue = folder.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent(DatasetEncoder.worldMapFileName).path) } ?? false
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                Button(action: shareItem) {
                    HStack {
                        if isCreatingPackage { ProgressView().scaleEffect(0.8) } else { Image(systemName: "square.and.arrow.up") }
                        Text(isCreatingPackage ? "Preparing…" : "Share").lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 32)
                }
                .glassButton(prominent: true)
                .disabled(isCreatingPackage)

                Button(action: sendToPC) {
                    Label("Send to PC", systemImage: "desktopcomputer")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .glassButton()
                .disabled(uploading)

                if let folder = folder {
                    NavigationLink(destination: ScanReplayView(folder: folder)) {
                        Label("All views", systemImage: "rectangle.3.group")
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .glassButton()
                }

                if let folder = folder, canContinue {
                    NavigationLink(destination: NewSessionView(continueFrom: folder)) {
                        Label("Continue", systemImage: "arrow.triangle.2.circlepath")
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .glassButton()
                    NavigationLink(destination: PhoneTrainView(folder: folder)) {
                        Label("Train here", systemImage: "cpu")
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .glassButton()
                    NavigationLink(destination: UltraWideSessionView(parentScan: folder)) {
                        Label("Add 0.5×", systemImage: "camera.aperture")
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .glassButton()
                }

                Button(role: .destructive, action: deleteItem) {
                    Label("Delete", systemImage: "trash")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .glassButton()
                .tint(.red)
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
        }
        .onReceive(NotificationCenter.default.publisher(for: PCUploader.statusNotification)) { note in
            guard let scan = note.userInfo?["scan"] as? String,
                  scan == recording.directoryPath()?.lastPathComponent else { return }
            pcStatus = note.userInfo?["message"] as? String
            pcProgress = note.userInfo?["progress"] as? Double
        }
        .onAppear {
            if pcStatus == nil, let last = PCUploader.shared.lastStatus[scanName] {
                pcProgress = last.0
                pcStatus = last.1
            } else if pcStatus == nil, PCUploader.uploadFailed(scanName) {
                pcStatus = "The last upload did not finish."
            }
            guard summary == nil else { return }
            let directory = recording.directoryPath()
            DispatchQueue.global(qos: .utility).async {
                let loaded = ScanSummary.load(directory: directory)
                DispatchQueue.main.async { summary = loaded }
            }
        }
        .navigationBarTitle(title.isEmpty ? recording.displayTitle : title)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    newName = recording.customName ?? ""
                    renaming = true
                } label: {
                    Image(systemName: "pencil")
                }
                .accessibilityLabel("Rename scan")
            }
        }
        .alert("Rename scan", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") {
                let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                recording.name = trimmed.isEmpty ? nil : trimmed
                try? recording.managedObjectContext?.save()
                title = recording.displayTitle
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leave it empty to show the date again.")
        }
        .background(Color("BackgroundColor"))
        .sheet(isPresented: $showingShareSheet) {
            if let packageURL = tempPackageURL {
                ShareSheet(activityItems: [packageURL]) { activityType, completed, returnedItems, activityError in
                    DispatchQueue.main.async {
                        // Clean up temporary package after sharing
                        try? FileManager.default.removeItem(at: packageURL)
                        tempPackageURL = nil
                        showingShareSheet = false
                    }
                }
            }
        }
        .alert("Export Failed", isPresented: Binding(
            get: { shareError != nil },
            set: { if !$0 { shareError = nil } }
        )) {
            Button("OK", role: .cancel) { shareError = nil }
        } message: {
            Text(shareError ?? "")
        }
        }
    }

    /// Picture of the scan (tap: the player with all views) beside its key numbers.
    /// Replaces the full-width sideways video that left the sides of the screen empty.
    private var header: some View {
        let folder = recording.directoryPath()
        let pictureWidth = min(UIScreen.main.bounds.size.width * 0.44, 190)
        return HStack(alignment: .top, spacing: 14) {
            if let folder = folder {
                NavigationLink(destination: ScanReplayView(folder: folder)) {
                    ZStack {
                        ScanThumbnailView(video: recording.absoluteRgbPath(), key: folder.lastPathComponent,
                                          width: pictureWidth, height: pictureWidth * 4 / 3)
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(Color.white.opacity(0.9))
                            .shadow(radius: 6)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play the scan with all views")
            }
            VStack(alignment: .leading, spacing: 9) {
                fact("clock", lengthText)
                if let summary = summary {
                    fact("film.stack", "\(summary.frames) frames" + (summary.photos > 0 ? " + \(summary.photos) photos" : ""))
                    if let shutter = summary.shutter {
                        fact("camera.aperture", (shutter == "Auto" ? "Auto shutter" : "\(shutter) s")
                             + (summary.videoQuality.map { " · \($0) quality" } ?? ""))
                    }
                    if let sharp = summary.sharpFraction {
                        fact("scope", "\(Int(sharp * 100))% sharp" + (summary.medianBlur.map { String(format: " · blur %.1f px", $0) } ?? ""),
                             tint: sharp > 0.85 ? .green : (sharp > 0.6 ? .yellow : .red))
                    }
                    if summary.limitedTrackingFrames > 0 {
                        fact("exclamationmark.triangle", "\(summary.limitedTrackingFrames) frames with weak tracking", tint: .orange)
                    }
                    if summary.sizeBytes > 0 {
                        fact("internaldrive", ByteCountFormatter.string(fromByteCount: summary.sizeBytes, countStyle: .file))
                    }
                    if summary.markers > 0 { fact("mappin.and.ellipse", "\(summary.markers) pins") }
                    if summary.ultraWidePasses > 0 { fact("camera.aperture", "+ \(summary.ultraWidePasses) pass at 0.5×", tint: .cyan) }
                    if summary.sentToPC { fact("desktopcomputer", "Sent to the PC", tint: .green) }
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var lengthText: String {
        let seconds = Int(recording.duration.rounded())
        return seconds >= 60 ? String(format: "%d min %02d s", seconds / 60, seconds % 60) : "\(seconds) s"
    }

    private func fact(_ symbol: String, _ text: String, tint: Color = .primary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .frame(width: 20)
                .foregroundStyle(tint == .primary ? Color.secondary : tint)
            Text(text)
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline.monospacedDigit())
    }

    private var scanName: String { recording.directoryPath()?.lastPathComponent ?? "" }
    private var uploading: Bool { PCUploader.shared.isActive(scanName) }
    /// A failed/stopped upload can be resumed; a running one that seems stuck can be restarted.
    private var canResume: Bool {
        if PCUploader.uploadFailed(scanName) { return true }
        return uploading && (pcStatus?.hasPrefix("Uploading") ?? false)
    }

    func sendToPC() {
        guard let folder = recording.directoryPath() else { return }
        pcStatus = "Starting…"
        pcProgress = 0
        PCUploader.shared.upload(directory: folder)
    }

    func deleteItem() {
        viewModel.delete(recording: recording)
        self.presentationMode.wrappedValue.dismiss()
    }
    
    func shareItem() {
        isCreatingPackage = true
        
        Task {
            do {
                let packageURL = try await ShareUtility.createShareableArchive(for: recording)
                await MainActor.run {
                    tempPackageURL = packageURL
                    isCreatingPackage = false
                    showingShareSheet = true
                }
            } catch {
                await MainActor.run {
                    isCreatingPackage = false
                    shareError = error.localizedDescription
                }
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    let applicationActivities: [UIActivity]? = nil
    let completionWithItemsHandler: UIActivityViewController.CompletionWithItemsHandler?
    
    init(activityItems: [Any], completionHandler: UIActivityViewController.CompletionWithItemsHandler? = nil) {
        self.activityItems = activityItems
        self.completionWithItemsHandler = completionHandler
    }
    
    func makeUIViewController(context: UIViewControllerRepresentableContext<ShareSheet>) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: applicationActivities
        )
        controller.completionWithItemsHandler = completionWithItemsHandler
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: UIViewControllerRepresentableContext<ShareSheet>) {
    }
}

struct SessionDetailView_Previews: PreviewProvider {
    static var recording: Recording = { () -> Recording in
        let rec = Recording()
        rec.id = UUID()
        rec.name = "Placeholder name"
        rec.createdAt = Date()
        rec.duration = 30.0
        return rec
    }()

    static var previews: some View {
        SessionDetailView(recording: recording)
    }
}
