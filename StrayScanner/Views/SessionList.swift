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

}

struct SessionList: View {
    @ObservedObject var viewModel = SessionListViewModel()
    @State private var showingInfo = false
    @State private var showingPCLink = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                if viewModel.sessions.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "viewfinder")
                            .font(.system(size: 56, weight: .thin))
                            .foregroundStyle(.secondary)
                        Text("No scans yet")
                            .font(.title3.weight(.semibold))
                        Text("Tap New scan, then walk slowly around the space.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(viewModel.sessions, id: \.self) { recording in
                            NavigationLink(destination: SessionDetailView(recording: recording)) {
                                SessionRow(session: recording)
                            }
                            .listRowBackground(Color.clear)
                        }
                        Color.clear.frame(height: 80).listRowBackground(Color.clear)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }

                NavigationLink(destination: NewSessionView()) {
                    Label("New scan", systemImage: "record.circle")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                }
                .glassButton(prominent: true)
                .tint(.red)
                .padding(.bottom, 20)
            }
            .navigationTitle("Scans")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink(destination: SplatForgeView()) {
                        Image(systemName: "desktopcomputer")
                    }
                    .accessibilityLabel("SplatForge on the PC")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingInfo.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel("About")
                }
            }
            .sheet(isPresented: $showingInfo) {
                InformationView()
            }
            .sheet(isPresented: $showingPCLink) {
                PCLinkSettingsView()
            }
            .onAppear {
                DispatchQueue.main.async {
                    viewModel.fetchSessions()
                }
                let delegate = UIApplication.shared.delegate as! AppDelegate
                delegate.appDaemon?.removeDeletedEntries()
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct SessionList_Previews: PreviewProvider {
    static var previews: some View {
        SessionList()
    }
}
