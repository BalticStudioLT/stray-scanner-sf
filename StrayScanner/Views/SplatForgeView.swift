//
//  SplatForgeView.swift
//  StrayScanner
//
//  SplatForge on the PC, seen from the phone (stray-scanner-sf fork): live status (CPU/RAM/GPU,
//  what is running, ETA), training now, job queue with cancel, projects and results, and the full
//  Studio web app. Talks to the Studio server (splatforge/studio.py, port 8777, token in X-Token).
//

import SwiftUI
import WebKit

final class SplatForgeClient: ObservableObject {
    @Published var system: [String: Any] = [:]
    @Published var jobs: [[String: Any]] = []
    @Published var projects: [[String: Any]] = []
    @Published var live: [String: Any] = [:]
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
        guard s.isConfigured, let url = s.url(path) else {
            DispatchQueue.main.async {
                self.error = "Set the PC address and Studio token (gear button)."
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
                problem = error.localizedDescription
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                problem = http.statusCode == 403 ? "Wrong Studio token" : "PC answered \(http.statusCode)"
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
    @StateObject private var client = SplatForgeClient()
    @State private var showingSettings = false
    @State private var showingStudio = false

    var body: some View {
        List {
            if let error = client.error {
                Section {
                    Label(error, systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.orange)
                    Button("PC link settings") { showingSettings = true }
                }
            }
            machineSection
            liveSection
            activitySection
            jobsSection
            projectsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("SplatForge")
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
        .onAppear { client.start() }
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

    @ViewBuilder private var liveSection: some View {
        if let run = client.live["run"] as? String {
            Section("Training now") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(run).font(.headline)
                    if let project = client.live["project"] as? String {
                        Text(URL(fileURLWithPath: project).lastPathComponent).font(.caption).foregroundStyle(.secondary)
                    }
                    if let snaps = client.live["snaps"] as? [[String: Any]], let last = snaps.last {
                        let step = number(last["step"]).map { "step \(Int($0))" } ?? ""
                        let psnr = number(last["psnr"]).map { String(format: " · PSNR %.2f", $0) } ?? ""
                        let splats = number(last["splats"]).map { String(format: " · %.1f M splats", $0 / 1e6) } ?? ""
                        Text(step + psnr + splats).font(.subheadline.monospacedDigit())
                        let psnrs = snaps.compactMap { number($0["psnr"]) }
                        if psnrs.count > 1 { Sparkline(values: psnrs).frame(height: 36) }
                    }
                    if let progress = client.live["progress"] as? [String: Any] {
                        let fraction = number(progress["fraction"]) ?? number(progress["progress"])
                        if let f = fraction { ProgressView(value: min(max(f, 0), 1)) }
                        if let text = eta(number(progress["eta_s"])) { Text(text).font(.caption).foregroundStyle(.secondary) }
                    }
                    if (client.live["done"] as? Bool) == true {
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

    @ViewBuilder private var jobsSection: some View {
        if !client.jobs.isEmpty {
            Section("Jobs") {
                ForEach(Array(client.jobs.prefix(15).enumerated()), id: \.offset) { _, job in
                    let id = (job["id"] as? Int) ?? -1
                    let status = (job["status"] as? String) ?? ""
                    let args = (job["args"] as? [String])?.joined(separator: " ") ?? ""
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("#\(id) \(args)").font(.caption.monospaced()).lineLimit(2)
                            Text(status).font(.caption2).foregroundStyle(status == "failed" ? .red : .secondary)
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
            }
        }
    }

    @ViewBuilder private var projectsSection: some View {
        if !client.projects.isEmpty {
            Section("Results") {
                ForEach(Array(client.projects.enumerated()), id: \.offset) { _, project in
                    let runs = (project["runs"] as? [[String: Any]]) ?? []
                    let best = runs.compactMap { number($0["psnr"]) }.max()
                    DisclosureGroup {
                        ForEach(Array(runs.reversed().prefix(12).enumerated()), id: \.offset) { _, run in
                            HStack {
                                Text((run["name"] as? String) ?? "").font(.caption.monospaced()).lineLimit(1)
                                Spacer()
                                if let psnr = number(run["psnr"]) { Text(String(format: "%.2f dB", psnr)).font(.caption.monospacedDigit()) }
                                if let splats = number(run["splats"]) { Text(String(format: "%.1fM", splats / 1e6)).font(.caption2).foregroundStyle(.secondary) }
                            }
                        }
                    } label: {
                        HStack {
                            Text((project["name"] as? String) ?? "").font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(runs.count) runs" + (best.map { String(format: " · best %.2f dB", $0) } ?? ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
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
