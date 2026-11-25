//
//  ScanSplatsSection.swift
//  StrayScanner
//
//  "Splats" on a scan's page: the phone-trained splat (phone_splat.ply) and every finished SplatForge run that was
//  trained from this scan (matched by the scan folder name, SplatForge /stray/results → source_scan).
//

import SwiftUI

struct ScanSplatsSection: View {
    let folder: URL
    @State private var pcRuns: [(title: String, ply: String)] = []
    @State private var pcState = "Looking on the PC…"
    @State private var viewing: SplatSource?

    private var phoneSplat: URL? {
        let url = folder.appendingPathComponent("phone_splat.ply")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Splats", systemImage: "cube.transparent").font(.headline)
            if let url = phoneSplat {
                Button { viewing = .file(url) } label: {
                    row(icon: "iphone", title: "Phone splat", detail: "trained on this phone")
                }
            }
            ForEach(Array(pcRuns.enumerated()), id: \.offset) { _, run in
                Button { viewing = .studio(ply: run.ply, title: run.title, sourceScan: folder.lastPathComponent) } label: {
                    row(icon: "desktopcomputer", title: run.title, detail: "SplatForge")
                }
            }
            if pcRuns.isEmpty {
                Text(phoneSplat == nil ? pcState + " Use “Send to PC” or “Train here” to make one." : pcState)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 22)
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .onAppear(perform: load)
        .fullScreenCover(item: $viewing) { SplatViewerScreen(source: $0) }
    }

    private func row(icon: String, title: String, detail: String) -> some View {
        HStack {
            Image(systemName: icon).frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    private func fetch(_ path: String) async -> Any? {
        let s = PCLinkSettings.load()
        guard s.isConfigured, let url = s.url(path) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue(s.token, forHTTPHeaderField: "X-Token")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func load() {
        let scan = folder.lastPathComponent
        Task {
            guard PCLinkSettings.load().isPaired else {
                await MainActor.run { pcState = "This phone is not paired with the PC yet (Settings tab)." }
                return
            }
            guard let results = await fetch("/stray/results") as? [[String: Any]],
                  let projects = await fetch("/api/projects") as? [[String: Any]] else {
                await MainActor.run { pcState = "PC not reachable — is SplatForge Studio running and on the same Wi-Fi?" }
                return
            }
            var found: [(String, String)] = []
            for r in results where (r["source_scan"] as? String) == scan {
                guard let project = r["project"] as? String, let run = r["run"] as? String,
                      let p = projects.first(where: { ($0["name"] as? String) == project }),
                      let runs = p["runs"] as? [[String: Any]],
                      let entry = runs.first(where: { ($0["name"] as? String) == run }),
                      let plys = entry["plys"] as? [String],
                      let ply = plys.first(where: { $0.hasSuffix("splat.ply") }) ?? plys.last else { continue }
                found.append(("\(project) · \(run)", ply))
            }
            await MainActor.run {
                pcRuns = Array(found.prefix(5))
                pcState = found.isEmpty ? "No finished PC splat for this scan yet." : ""
            }
        }
    }
}
