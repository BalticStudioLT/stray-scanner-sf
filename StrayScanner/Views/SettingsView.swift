//
//  SettingsView.swift
//  StrayScanner
//
//  The Settings tab (stray-scanner-sf fork): PC link, capture quality and the scanning guide in one place.
//  The same capture choices are also in the record screen's views menu.
//

import SwiftUI
import ARKit

struct SettingsView: View {
    @AppStorage(VideoQuality.userDefaultsKey) private var videoQuality = VideoQuality.high.rawValue
    @AppStorage(StillSetting.userDefaultsKey) private var stills = StillSetting.off.rawValue
    @AppStorage(RecordSessionViewController.use4KKey) private var use4K = false
    @State private var showingPCLink = false
    @State private var showingHelp = false
    @State private var pcLine = ""
    @State private var pcPaired = false
    @State private var pcTest: String?
    @State private var pcTestOK = false
    @State private var testing = false
    @State private var freeSpace = "–"

    private let has4K = ARWorldTrackingConfiguration.recommendedVideoFormatFor4KResolution != nil
    private let hasStills = StillSetting.isSupported

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Image(systemName: pcPaired ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(pcPaired ? Color.green : Color.orange)
                        Text(pcLine)
                    }
                    Button(pcPaired ? "Change PC link" : "Pair with the PC") { showingPCLink = true }
                    if pcPaired {
                        Button {
                            testing = true
                            pcTest = nil
                            PCUploader.ping(PCLinkSettings.load()) { ok, message in
                                testing = false
                                pcTestOK = ok
                                pcTest = message
                            }
                        } label: {
                            HStack {
                                Text("Test connection")
                                if testing {
                                    Spacer()
                                    ProgressView()
                                }
                            }
                        }
                        if let result = pcTest {
                            Label(result, systemImage: pcTestOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(pcTestOK ? Color.green : Color.orange)
                        }
                    }
                } header: {
                    Text("SplatForge PC")
                } footer: {
                    Text("The PC turns scans into splats. A new phone has to be paired once: open the Studio link from the PC on this phone, or paste it under Pair with the PC. Both need Tailscale or the same Wi-Fi.")
                }

                Section {
                    Picker("Video quality", selection: $videoQuality) {
                        ForEach(VideoQuality.allCases, id: \.rawValue) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                    Toggle("4K video (30 fps)", isOn: $use4K)
                        .disabled(!has4K || (stills != 0 && hasStills))
                    Picker("Sharp photos (beta)", selection: $stills) {
                        ForEach(StillSetting.allCases, id: \.rawValue) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                    .disabled(!hasStills)
                } header: {
                    Text("Capture")
                } footer: {
                    Text("High keeps fine texture on walls and fabric; files are about 3× bigger than Standard. Sharp photos add 12 MP pictures beside the video (about 4 MB each); they are saved with the scan, but SplatForge does not train on them yet. 4K is off while Sharp photos are on.")
                }

                Section {
                    Button("How to scan well") { showingHelp = true }
                    LabeledContent("Free space on this phone", value: freeSpace)
                    LabeledContent("App version", value: appVersion)
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showingPCLink, onDismiss: refresh) {
                PCLinkSettingsView()
            }
            .sheet(isPresented: $showingHelp) {
                InformationView()
            }
            .onAppear(perform: refresh)
        }
        .preferredColorScheme(.dark)
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (info?["CFBundleVersion"] as? String) ?? "?"
        return "\(version) (\(build))"
    }

    private func refresh() {
        #if DEBUG
        if UserDefaults.standard.string(forKey: "DebugOpen") == "pclink", !showingPCLink, pcLine.isEmpty { showingPCLink = true }
        #endif
        let settings = PCLinkSettings.load()
        pcPaired = settings.isPaired
        pcLine = pcPaired ? "Paired with \(settings.host)" : "Not paired with a PC yet"
        DispatchQueue.global(qos: .utility).async {
            let url = URL(fileURLWithPath: NSHomeDirectory())
            let bytes = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage
            let text = bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "–"
            DispatchQueue.main.async { freeSpace = text }
        }
    }
}
