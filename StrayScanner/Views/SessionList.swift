//
//  SessionList.swift
//  Stray Scanner
//
//  Created by Kenneth Blomqvist on 11/15/20.
//  Copyright © 2020 Stray Robots. All rights reserved.
//

import SwiftUI
import CoreData

class SessionListViewModel: ObservableObject {
    private var dataContext: NSManagedObjectContext?
    @Published var sessions: [Recording] = []

    init() {
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
        dataContext = appDelegate.persistentContainer.viewContext
        self.sessions = []
        NotificationCenter.default.addObserver(self, selector: #selector(sessionsChanged), name: NSNotification.Name("sessionsChanged"), object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func fetchSessions() {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Recording")
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        do {
            let fetched: [NSManagedObject] = try dataContext?.fetch(request) ?? []
            sessions = fetched.map { session in
                return session as! Recording
            }

        } catch let error as NSError {
            print("Something went wrong. Error: \(error), \(error.userInfo)")
        }
    }

    @objc func sessionsChanged() {
        fetchSessions()
    }

    func rename(_ recording: Recording, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        recording.name = trimmed.isEmpty ? nil : trimmed
        do {
            try dataContext?.save()
        } catch let error as NSError {
            print("Could not rename the scan. \(error), \(error.userInfo)")
        }
        fetchSessions()
    }

    func delete(_ recording: Recording) {
        sessions.removeAll { $0 == recording }
        recording.deleteFiles()
        dataContext?.delete(recording)
        do {
            try dataContext?.save()
        } catch let error as NSError {
            print("Could not delete the scan. \(error), \(error.userInfo)")
        }
    }

}

struct SessionList: View {
    @ObservedObject var viewModel = SessionListViewModel()
    @State private var showingHelp = false
    @State private var renaming: Recording?
    @State private var newName = ""
    @State private var deleting: Recording?
    @State private var debugDetail = false
    @State private var debugRecord = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                if viewModel.sessions.isEmpty {
                    emptyState
                } else {
                    scanList
                }
                newScanBar
            }
            .navigationTitle("Scans")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingHelp = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .accessibilityLabel("How to scan")
                }
            }
            .sheet(isPresented: $showingHelp) {
                InformationView()
            }
            .alert("Rename scan", isPresented: renamingBinding) {
                TextField("Name", text: $newName)
                Button("Save") {
                    if let recording = renaming { viewModel.rename(recording, to: newName) }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            } message: {
                Text("Leave it empty to show the date again.")
            }
            .confirmationDialog("Delete this scan from the phone?", isPresented: deletingBinding, titleVisibility: .visible) {
                Button("Delete scan", role: .destructive) {
                    if let recording = deleting { viewModel.delete(recording) }
                    deleting = nil
                }
                Button("Cancel", role: .cancel) { deleting = nil }
            } message: {
                Text("The video, depth and any splat trained on the phone are removed. A copy already sent to the PC stays there.")
            }
            .navigationDestination(isPresented: $debugDetail) {
                if let first = viewModel.sessions.first {
                    SessionDetailView(recording: first)
                }
            }
            .navigationDestination(isPresented: $debugRecord) {
                NewSessionView()
            }
            .onAppear {
                DispatchQueue.main.async {
                    viewModel.fetchSessions()
                }
                let delegate = UIApplication.shared.delegate as! AppDelegate
                delegate.appDaemon?.removeDeletedEntries()
                #if DEBUG
                openForScreenshot()
                #endif
            }
        }
        .preferredColorScheme(.dark)
    }

    #if DEBUG
    private static var debugOpened = false

    /// Debug builds only (Simulator screenshots): the launch argument `-DebugOpen scan|record|help`
    /// opens that screen at start. Release builds on the phone do not contain this.
    private func openForScreenshot() {
        guard !SessionList.debugOpened, let target = UserDefaults.standard.string(forKey: "DebugOpen") else { return }
        SessionList.debugOpened = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            switch target {
            case "scan": debugDetail = !viewModel.sessions.isEmpty
            case "record": debugRecord = true
            case "help": showingHelp = true
            default: break
            }
        }
    }
    #endif

    private var renamingBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var deletingBinding: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "viewfinder")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(.secondary)
            Text("No scans yet")
                .font(.title3.weight(.semibold))
            Text("Tap New scan, then walk slowly around the space. The ? button at the top has a short guide.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scanList: some View {
        List {
            ForEach(viewModel.sessions, id: \.self) { recording in
                NavigationLink(destination: SessionDetailView(recording: recording)) {
                    SessionRow(session: recording, title: recording.displayTitle)
                }
                .listRowBackground(Color.clear)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button {
                        deleting = recording
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .tint(.red)
                    Button {
                        newName = recording.customName ?? ""
                        renaming = recording
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    .tint(.indigo)
                }
                .contextMenu {
                    Button {
                        newName = recording.customName ?? ""
                        renaming = recording
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        deleting = recording
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            Color.clear.frame(height: 80)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var newScanBar: some View {
        HStack(spacing: 12) {
            NavigationLink(destination: NewSessionView()) {
                Label("New scan", systemImage: "record.circle")
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
            }
            .glassButton(prominent: true)
            .tint(.red)
            NavigationLink(destination: UltraWideSessionView()) {
                Label("0.5×", systemImage: "camera.aperture")
                    .font(.title3.weight(.semibold))
                    .padding(.vertical, 8)
            }
            .glassButton()
            .accessibilityLabel("Ultra-wide video, no LiDAR")
        }
        .padding(.bottom, 20)
    }
}

/// The app's three places: scans on this phone, splats (from the PC or trained here), and settings.
struct RootView: View {
    @State private var tab = RootView.initialTab
    /// A video picked in the Splats tab or opened in the app from Files / Immich's share sheet.
    @State private var pendingVideo: PendingVideo?

    /// Debug builds only: `-InitialTab 1` opens another tab at start (Simulator screenshots).
    private static var initialTab: Int {
        #if DEBUG
        return UserDefaults.standard.integer(forKey: "InitialTab")
        #else
        return 0
        #endif
    }

    var body: some View {
        TabView(selection: $tab) {
            SessionList()
                .tabItem { Label("Scans", systemImage: "viewfinder") }
                .tag(0)
            NavigationStack {
                SplatForgeView(pendingVideo: $pendingVideo)
            }
            .tabItem { Label("Splats", systemImage: "cube.transparent") }
            .tag(1)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(2)
        }
        .preferredColorScheme(.dark)
        .sheet(item: $pendingVideo) { video in
            VideoActionsSheet(video: video)
        }
        .onReceive(NotificationCenter.default.publisher(for: VideoInbox.openedNotification)) { note in
            guard let url = note.object as? URL else { return }
            tab = 1
            pendingVideo = PendingVideo(url: url, title: url.lastPathComponent)
        }
    }
}

struct SessionList_Previews: PreviewProvider {
    static var previews: some View {
        SessionList()
    }
}
