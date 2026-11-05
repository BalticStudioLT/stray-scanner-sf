//
//  PCLinkSettingsView.swift
//  StrayScanner
//
//  Settings for the link to the SplatForge PC (stray-scanner-sf fork).
//

import SwiftUI

struct PCLinkSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var host: String = ""
    @State private var port: String = "8777"
    @State private var token: String = ""
    @State private var autoUpload = false
    @State private var live = false
    @State private var draft = UserDefaults.standard.bool(forKey: "PCLinkDraft")
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("PC address, e.g. coolmaster4 or 100.72.101.23", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                    TextField("Studio token (A:\\AI\\SplatForge\\.studio_token)", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.footnote, design: .monospaced))
                    Button {
                        if let text = UIPasteboard.general.string, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                           PCLinkSettings.pair(with: url) {
                            load()
                        } else if let text = UIPasteboard.general.string {
                            token = PCLinkSettings.cleanToken(text)
                        }
                    } label: {
                        Label("Paste Studio link or token", systemImage: "doc.on.clipboard")
                    }
                } header: {
                    Text("SplatForge PC")
                } footer: {
                    Text("Install Tailscale on the iPhone and the PC and sign in to the same account. Use the PC's Tailscale name or 100.x address. Start SplatForge Studio on the PC (port 8777). Token: open the Studio link from the PC (it ends in ?t=…) and paste it here, or scan the Studio’s “Pair phone” QR code. Status and Studio work right away; Send to PC and the live link need the phone receiver in SplatForge (docs/pc-link.md).")
                }
                Section {
                    Button {
                        save()
                        testing = true
                        testResult = nil
                        PCUploader.ping(PCLinkSettings.load()) { _, message in
                            testing = false
                            testResult = message
                        }
                    } label: {
                        HStack {
                            Text("Test connection")
                            if testing { Spacer(); ProgressView() }
                        }
                    }
                    if let result = testResult {
                        Text(result).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Toggle("Send each scan to the PC when recording stops", isOn: $autoUpload)
                    Toggle("Quick draft training (~4 min instead of ~10)", isOn: $draft)
                    Toggle("Live link while scanning (coverage and hints from the PC)", isOn: $live)
                } footer: {
                    Text("The live link sends the camera position 5×/s, new points 2×/s and a small preview image 1×/s. It uses some battery; turn it off when the PC is not running.")
                }
            }
            .navigationTitle("PC link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        save()
                        dismiss()
                    }
                }
            }
            .onAppear(perform: load)
        }
        .preferredColorScheme(.dark)
    }

    private func load() {
        let settings = PCLinkSettings.load()
        host = settings.host
        port = String(settings.port)
        token = settings.token
        autoUpload = settings.autoUpload
        live = settings.live
    }

    private func save() {
        UserDefaults.standard.set(draft, forKey: "PCLinkDraft")
        PCLinkSettings(host: host, port: Int(port) ?? 8777, token: token, autoUpload: autoUpload, live: live).save()
    }
}
