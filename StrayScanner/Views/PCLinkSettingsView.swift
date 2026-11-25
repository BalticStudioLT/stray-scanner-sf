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
    @State private var testOK = false
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
                    TextField("Studio token", text: $token)
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
                    Text("1. The phone and the PC both need Tailscale, signed in to the same account (or the same Wi-Fi).\n2. SplatForge Studio must be running on the PC: start studio.bat in the SplatForge folder.\n3. Pair: copy the Studio link from the PC (it ends in ?t=…) and tap Paste, or scan Studio’s “Pair phone” QR code with the camera.")
                }
                Section {
                    Button {
                        save()
                        testing = true
                        testResult = nil
                        PCUploader.ping(PCLinkSettings.load()) { ok, message in
                            testing = false
                            testOK = ok
                            testResult = message
                        }
                    } label: {
                        HStack {
                            Text("Test connection")
                            if testing { Spacer(); ProgressView() }
                        }
                    }
                    if let result = testResult {
                        Label(result, systemImage: testOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(testOK ? Color.green : Color.orange)
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
