//
//  SplatForgeView.swift
//  StrayScanner
//
//  SplatForge on the PC, seen from the phone (stray-scanner-sf fork): live status (CPU/RAM/GPU,
//  what is running, ETA), training now, job queue with cancel, projects and results, and the full
//  Studio web app. Talks to the Studio server (splatforge/studio.py, port 8777, token in X-Token).
//

import SwiftUI
import PhotosUI
import Photos
import WebKit
import UniformTypeIdentifiers

final class SplatForgeClient: ObservableObject {
    @Published var system: [String: Any] = [:]
    @Published var jobs: [[String: Any]] = []
    @Published var projects: [[String: Any]] = []
    @Published var live: [String: Any] = [:]
    /// "project/run" → Stray scan folder it was trained from (SplatForge /stray/results).
    @Published var sourceScans: [String: String] = [:]
    @Published var error: String?
    @Published var lastUpdate: Date?
    private var timer: Timer?

    var settings: PCLinkSettings { PCLinkSettings.load() }

    func start() {
        refresh(full: true)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refresh(full: false)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh(full: Bool) {
        get("/api/system") { [weak self] (json: [String: Any]?) in
            if let json = json { self?.system = json; self?.lastUpdate = Date() }
        }
        get("/api/live") { [weak self] (json: [String: Any]?) in
            self?.live = json ?? [:]
        }
        get("/api/jobs") { [weak self] (json: [[String: Any]]?) in
            if let json = json { self?.jobs = Array(json.reversed().prefix(30)) }
        }
        if full || projects.isEmpty {
            get("/api/projects") { [weak self] (json: [[String: Any]]?) in
                if let json = json { self?.projects = json }
            }
            get("/stray/results") { [weak self] (json: [[String: Any]]?) in
                var map: [String: String] = [:]
                for item in json ?? [] {
                    if let project = item["project"] as? String, let run = item["run"] as? String, let scan = item["source_scan"] as? String {
                        map[URL(fileURLWithPath: project).lastPathComponent + "/" + run] = scan
                    }
                }
                self?.sourceScans = map
            }
        }
    }

    func cancel(job id: Int) {
        guard let url = settings.url("/api/cancel") else { return }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue(settings.token, forHTTPHeaderField: "X-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["id": id])
        URLSession.shared.dataTask(with: request) { [weak self] _, _, _ in
            DispatchQueue.main.async { self?.refresh(full: false) }
        }.resume()
    }

    var studioURL: URL? {
        guard var components = settings.url("/").flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else { return nil }
        components.queryItems = [URLQueryItem(name: "t", value: settings.token)]
        return components.url
    }

    private func get<T>(_ path: String, completion: @escaping (T?) -> Void) {
        let s = settings
        guard s.isPaired, let url = s.url(path) else {
            DispatchQueue.main.async {
                self.error = "This phone is not paired with the PC yet (Settings tab ▸ Pair with the PC)."
                completion(nil)
            }
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue(s.token, forHTTPHeaderField: "X-Token")
        URLSession.shared.dataTask(with: request) { data, response, error in
            var value: T?
            var problem: String?
            if let error = error {
                problem = PCLinkSettings.explainFailure(error, host: s.host)
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                problem = http.statusCode == 403 ? "The PC refused the token — pair again in the Settings tab" : "PC answered \(http.statusCode)"
            } else if let data = data {
                value = (try? JSONSerialization.jsonObject(with: data)) as? T
            }
            DispatchQueue.main.async {
                if path == "/api/system" { self.error = problem }
                completion(value)
            }
        }.resume()
    }
}

private func number(_ any: Any?) -> Double? {
    if let d = any as? Double { return d }
    if let i = any as? Int { return Double(i) }
    if let n = any as? NSNumber { return n.doubleValue }
    return nil
}

private func eta(_ seconds: Double?) -> String? {
    guard let s = seconds, s > 0 else { return nil }
    if s < 90 { return "\(Int(s)) s left" }
    if s < 5400 { return "\(Int(s / 60)) min left" }
    return String(format: "%.1f h left", s / 3600)
}

struct SplatForgeView: View {
    @Binding var pendingVideo: PendingVideo?
    @State private var showingPhotos = false
    @State private var showingImmich = false
    @State private var photoItem: PhotosPickerItem?
    @State private var importingVideo = false
    @State private var videoError: String?
    @StateObject private var client = SplatForgeClient()
    @State private var showingSettings = false
    @State private var showingStudio = false
    @State private var viewerSource: SplatSource?
    @State private var showingImporter = false
    @State private var phoneSplats: [PhoneSplatItem] = []

    var body: some View {
        List {
            if let error = client.error {
                Section {
                    Label(error, systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.orange)
                    Button("PC link settings") { showingSettings = true }
                } footer: {
                    Text("Splats made by SplatForge are listed here when this phone can reach the PC.")
                }
            }
            liveSection
            phoneScanSplatsSection
            phoneSplatsSection
            VideoSourcesSection(showingPhotos: $showingPhotos, showingImmich: $showingImmich,
                                importing: importingVideo, importError: videoError)
            otherSplatsSection
            machineSection
            activitySection
            jobsSection
        }
        .listStyle(.insetGrouped)
        .photosPicker(isPresented: $showingPhotos, selection: $photoItem, matching: .videos,
                      preferredItemEncoding: .current, photoLibrary: .shared())
        #if DEBUG
        .task {
            // Simulator test: -DebugPhotosImport YES loads the newest library video the same way the picker does.
            guard UserDefaults.standard.bool(forKey: "DebugPhotosImport") else { return }
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            if let asset = PHAsset.fetchAssets(with: .video, options: options).firstObject {
                photoItem = PhotosPickerItem(itemIdentifier: asset.localIdentifier)
            } else {
                videoError = "Debug: no video in the library"
            }
        }
        #endif
        .onChange(of: photoItem) { item in
            guard let item = item else { return }
            importingVideo = true
            videoError = nil
            Task { @MainActor in
                do {
                    pendingVideo = try await PhotosVideoLoader.load(item)
                } catch {
                    videoError = "Could not read that video: " + error.localizedDescription
                }
                importingVideo = false
                photoItem = nil
            }
        }
        .sheet(isPresented: $showingImmich) {
            ImmichBrowserView { video in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { pendingVideo = video }
            }
        }
        .navigationTitle("Splats")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingStudio = true
                } label: {
                    Label("Open Studio", systemImage: "macwindow")
                }
                .disabled(client.studioURL == nil)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingImporter = true
                } label: {
                    Image(systemName: "cube.transparent")
                }
                .accessibilityLabel("Open a splat file")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("PC link settings")
            }
        }
        .refreshable { client.refresh(full: true) }
        .sheet(isPresented: $showingSettings, onDismiss: { client.refresh(full: true) }) {
            PCLinkSettingsView()
        }
        .fullScreenCover(isPresented: $showingStudio) {
            StudioWebScreen(url: client.studioURL)
        }
        .fullScreenCover(item: $viewerSource) { source in
            SplatViewerScreen(source: source)
        }
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [UTType(filenameExtension: "ply") ?? .data]) { result in
            if case .success(let url) = result { viewerSource = .file(url) }
        }
        .onAppear {
            client.start()
            findPhoneSplats()
        }
        .onDisappear { client.stop() }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var machineSection: some View {
        if !client.system.isEmpty {
            Section("PC") {
                let cpu = number(client.system["cpu"]) ?? 0
                let ram = client.system["ram"] as? [String: Any] ?? [:]
                let gpu = client.system["gpu"] as? [String: Any] ?? [:]
                meter("CPU", value: cpu / 100, text: String(format: "%.0f %%", cpu))
                if let used = number(ram["used_gb"]), let total = number(ram["total_gb"]), total > 0 {
                    meter("RAM", value: used / total, text: String(format: "%.0f / %.0f GB", used, total))
                }
                if let util = number(gpu["util"]) {
                    let vram = number(gpu["vram_gb"]) ?? 0
                    let vramTotal = number(gpu["vram_total_gb"]) ?? 0
                    let temp = number(gpu["temp_c"]).map { String(format: " · %.0f °C", $0) } ?? ""
                    let power = number(gpu["power_w"]).map { String(format: " · %.0f W", $0) } ?? ""
                    meter((gpu["name"] as? String) ?? "GPU", value: util / 100,
                          text: String(format: "%.0f %% · VRAM %.1f / %.0f GB", util, vram, vramTotal) + temp + power)
                }
                HStack {
                    if let queued = client.system["queued"] as? Int { Text("\(queued) queued") }
                    Spacer()
                    if let beat = number(client.system["worker_beat_s"]) {
                        Text(beat < 120 ? "worker alive" : "worker silent \(Int(beat)) s")
                            .foregroundStyle(beat < 120 ? Color.secondary : Color.orange)
                    }
                    if let time = client.system["time"] as? String { Text("· \(time)") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// What the "Training now" card shows. SplatForge (2026-11-13) sends `live` = progress.json, written every 500
    /// steps; the snapshots list only grows every 5 000 steps and is used for the PSNR curve.
    private struct LiveState {
        var line = ""
        var fraction: Double?
        var eta: String?
        var psnrs: [Double] = []
    }

    private func liveState() -> LiveState {
        var state = LiveState()
        let snaps = client.live["snaps"] as? [[String: Any]] ?? []
        let progress = client.live["progress"] as? [String: Any] ?? [:]
        let now = (client.live["live"] as? [String: Any]) ?? snaps.last ?? [:]
        let step = number(now["step"])
        let steps = number(now["steps"]) ?? number(progress["steps"])
        var parts: [String] = []
        if let step = step {
            if let steps = steps, steps > 0 {
                parts.append("step \(Int(step)) / \(Int(steps))")
                state.fraction = min(max(step / steps, 0), 1)
            } else {
                parts.append("step \(Int(step))")
            }
        }
        if let psnr = number(now["psnr_train"]) ?? number(now["psnr"]) { parts.append(String(format: "PSNR %.2f", psnr)) }
        if let splats = number(now["splats"]) { parts.append(String(format: "%.1f M splats", splats / 1e6)) }
        state.line = parts.joined(separator: " · ")
        if state.fraction == nil {
            state.fraction = (number(progress["fraction"]) ?? number(progress["progress"])).map { min(max($0, 0), 1) }
        }
        state.eta = eta(number(now["eta_s"]) ?? number(progress["eta_s"]))
        state.psnrs = snaps.compactMap { number($0["psnr_train"]) ?? number($0["psnr"]) }
        return state
    }

    @ViewBuilder private var liveSection: some View {
        if let run = client.live["run"] as? String {
            let state = liveState()
            let finished = (client.live["done"] as? Bool) == true
            Section("Training now") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(run).font(.headline)
                    if let project = client.live["project"] as? String {
                        Text(URL(fileURLWithPath: project).lastPathComponent).font(.caption).foregroundStyle(.secondary)
                    }
                    if !state.line.isEmpty {
                        Text(state.line).font(.subheadline.monospacedDigit())
                    }
                    if state.psnrs.count > 1 { Sparkline(values: state.psnrs).frame(height: 36) }
                    if !finished, let fraction = state.fraction { ProgressView(value: fraction) }
                    if !finished, let text = state.eta { Text(text).font(.caption).foregroundStyle(.secondary) }
                    if finished {
                        Label("Finished", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                    }
                }
            }
        }
    }

    @ViewBuilder private var activitySection: some View {
        if let activity = client.system["activity"] as? [[String: Any]], !activity.isEmpty {
            Section("Running") {
                ForEach(Array(activity.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text((item["name"] as? String) ?? "job").font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text((item["stage"] as? String) ?? "").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                        if let p = number(item["progress"]) { ProgressView(value: min(max(p > 1 ? p / 100 : p, 0), 1)) }
                        if let text = eta(number(item["eta_s"])) { Text(text).font(.caption2).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }

    private func jobRow(_ job: [String: Any]) -> some View {
        let id = (job["id"] as? Int) ?? -1
        let status = (job["status"] as? String) ?? ""
        let args = (job["args"] as? [String])?.joined(separator: " ") ?? ""
        let label = (job["label"] as? String) ?? ""
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                // verbatim: a plain "#1331", not the locale's "#1,331"
                Text(verbatim: "#\(id) " + (label.isEmpty ? args : label)).font(.caption.monospaced()).lineLimit(2)
                Text(status).font(.caption2).foregroundStyle(status == "failed" ? Color.red : Color.secondary)
            }
            Spacer()
            if status == "running" || status == "queued" {
                Button(role: .destructive) {
                    client.cancel(job: id)
                } label: {
                    Image(systemName: "stop.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Cancel job \(id)")
            }
        }
    }

    /// Waiting and running jobs are shown; finished ones are folded away so they don't bury the splats.
    @ViewBuilder private var jobsSection: some View {
        let jobs = Array(client.jobs.prefix(30))
        let open = jobs.filter { ["running", "queued"].contains(($0["status"] as? String) ?? "") }
        let closed = jobs.filter { !["running", "queued"].contains(($0["status"] as? String) ?? "") }
        if !jobs.isEmpty {
            Section("Jobs on the PC") {
                if open.isEmpty {
                    Text("Nothing is waiting or running.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(open.enumerated()), id: \.offset) { _, job in
                    jobRow(job)
                }
                if !closed.isEmpty {
                    DisclosureGroup("Finished (\(closed.count))") {
                        ForEach(Array(closed.prefix(15).enumerated()), id: \.offset) { _, job in
                            jobRow(job)
                        }
                    }
                    .font(.subheadline)
                }
            }
        }
    }

    /// A project SplatForge made from a scan sent by the phone app.
    private func isPhoneScan(_ project: [String: Any]) -> Bool {
        let name = (project["name"] as? String) ?? ""
        if name.hasPrefix("scan_") { return true }
        return client.sourceScans.keys.contains { $0.hasPrefix(name + "/") }
    }

    /// Newest first (the PC lists them by name, which put phone scans at the very end).
    private func projects(phoneScans: Bool) -> [[String: Any]] {
        return client.projects
            .filter { isPhoneScan($0) == phoneScans }
            .sorted { (number($0["mtime"]) ?? 0) > (number($1["mtime"]) ?? 0) }
    }

    @ViewBuilder private var phoneScanSplatsSection: some View {
        let list = projects(phoneScans: true)
        if !list.isEmpty {
            Section("Splats from phone scans") {
                projectRows(list, symbol: "iphone")
            }
        }
    }

    @ViewBuilder private var otherSplatsSection: some View {
        let list = projects(phoneScans: false)
        if !list.isEmpty {
            Section("Other splats on the PC") {
                projectRows(list, symbol: "desktopcomputer")
            }
        }
    }

    private func projectRows(_ projects: [[String: Any]], symbol: String) -> some View {
        ForEach(Array(projects.enumerated()), id: \.offset) { _, project in
            let runs = (project["runs"] as? [[String: Any]]) ?? []
            let best = runs.compactMap { number($0["psnr"]) }.max()
            DisclosureGroup {
                if runs.isEmpty {
                    Text("No finished splat yet.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(runs.reversed().prefix(12).enumerated()), id: \.offset) { _, run in
                    let plys = (run["plys"] as? [String]) ?? []
                    let ply = plys.first(where: { $0.hasSuffix("splat.ply") }) ?? plys.last
                    let name = (run["name"] as? String) ?? ""
                    Button {
                        if let ply = ply {
                            let projectName = (project["name"] as? String) ?? ""
                            viewerSource = .studio(ply: ply, title: "\(projectName) · \(name)",
                                                   sourceScan: client.sourceScans[projectName + "/" + name])
                        }
                    } label: {
                        HStack {
                            Image(systemName: ply == nil ? "hourglass" : "cube.fill")
                                .foregroundStyle(ply == nil ? Color.secondary : Color.accentColor)
                            Text(name).font(.caption.monospaced()).lineLimit(1)
                            Spacer()
                            if let psnr = number(run["psnr"]) { Text(String(format: "%.2f dB", psnr)).font(.caption.monospacedDigit()) }
                            if let splats = number(run["splats"]) { Text(String(format: "%.1fM", splats / 1e6)).font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                    .disabled(ply == nil)
                    .accessibilityLabel("View \(name) in 3D or AR")
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
                    Text((project["name"] as? String) ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Text(verbatim: "\(runs.count) runs" + (best.map { String(format: " · %.1f dB", $0) } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Splats trained on this phone ("Train here" on a scan): <scan>/phone_splat.ply.
    @ViewBuilder private var phoneSplatsSection: some View {
        if !phoneSplats.isEmpty {
            Section("Trained on this phone") {
                ForEach(phoneSplats, id: \.url) { item in
                    Button {
                        viewerSource = .file(item.url)
                    } label: {
                        HStack {
                            Image(systemName: "iphone").foregroundStyle(Color.accentColor)
                            Text(item.title).font(.caption.monospaced()).lineLimit(1)
                            Spacer()
                            Text(item.size).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel("View phone splat \(item.title) in 3D or AR")
                }
            }
        }
    }

    private func findPhoneSplats() {
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            var found: [PhoneSplatItem] = []
            if let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first,
               let folders = try? fm.contentsOfDirectory(at: documents, includingPropertiesForKeys: [.contentModificationDateKey]) {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                for folder in folders where folder.hasDirectoryPath {
                    let ply = folder.appendingPathComponent("phone_splat.ply")
                    guard let attributes = try? fm.attributesOfItem(atPath: ply.path) else { continue }
                    let date = (attributes[.modificationDate] as? Date) ?? Date.distantPast
                    let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                    found.append(PhoneSplatItem(url: ply, title: formatter.string(from: date), date: date,
                                                size: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))
                }
            }
            found.sort { $0.date > $1.date }
            DispatchQueue.main.async { phoneSplats = found }
        }
    }

    private func meter(_ title: String, value: Double, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(text).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ProgressView(value: min(max(value, 0), 1))
                .tint(value > 0.9 ? .red : (value > 0.7 ? .orange : .accentColor))
        }
    }
}

struct PhoneSplatItem {
    let url: URL
    let title: String
    let date: Date
    let size: String
}

struct Sparkline: View {
    let values: [Double]
    var body: some View {
        GeometryReader { geo in
            let lo = values.min() ?? 0, hi = values.max() ?? 1
            let span = max(hi - lo, 0.001)
            Path { path in
                for (i, v) in values.enumerated() {
                    let x = geo.size.width * CGFloat(i) / CGFloat(max(values.count - 1, 1))
                    let y = geo.size.height * (1 - CGFloat((v - lo) / span))
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(Color.green, lineWidth: 2)
        }
        .accessibilityLabel("PSNR over training")
    }
}

/// The full SplatForge Studio web app (viewer, renders, editing) inside the phone app.
struct StudioWebScreen: View {
    let url: URL?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let url = url {
                    StudioWebView(url: url).ignoresSafeArea(edges: .bottom)
                } else {
                    Text("Set the PC address first.")
                }
            }
            .navigationTitle("Studio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct StudioWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
