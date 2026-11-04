//
//  AppDaemon.swift
//  StrayScanner
//
//  Created by Kenneth Blomqvist on 1/17/21.
//  Copyright © 2021 Stray Robots. All rights reserved.
//

import Foundation
import CoreData
import UIKit

class AppDaemon {
    private let dataContext: NSManagedObjectContext?

    init(appDelegate: AppDelegate) {
        dataContext = appDelegate.persistentContainer.viewContext
    }

    /// Adds scans that were cut off by a crash (they still have the in-progress marker and no
    /// database entry) to the list, so their files can be shared and continued.
    public func recoverUnfinishedScans() {
        guard let context = dataContext,
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let folders = try? FileManager.default.contentsOfDirectory(at: documents, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let request = NSFetchRequest<NSManagedObject>(entityName: "Recording")
        let known = Set(((try? context.fetch(request)) ?? []).compactMap { ($0 as? Recording)?.rgbFilePath?.components(separatedBy: "/").first })
        var recovered = 0
        for folder in folders {
            let marker = folder.appendingPathComponent(DatasetEncoder.inProgressMarker)
            guard FileManager.default.fileExists(atPath: marker.path) else { continue }
            let name = folder.lastPathComponent
            if !known.contains(name) {
                let entity = NSEntityDescription.entity(forEntityName: "Recording", in: context)!
                let recording = Recording(entity: entity, insertInto: context)
                recording.id = UUID()
                recording.name = "Recovered scan"
                recording.createdAt = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                recording.duration = AppDaemon.duration(odometry: folder.appendingPathComponent("odometry.csv"))
                recording.rgbFilePath = "\(name)/rgb.mp4"
                recording.depthFilePath = "\(name)/depth/"
                recovered += 1
            }
            try? FileManager.default.removeItem(at: marker)
        }
        if recovered > 0 {
            do {
                try context.save()
                print("Recovered \(recovered) unfinished scan(s).")
            } catch let error as NSError {
                print("Could not save recovered scans. \(error), \(error.userInfo)")
            }
        }
    }

    private static func duration(odometry: URL) -> Double {
        guard let text = try? String(contentsOf: odometry, encoding: .utf8) else { return 0 }
        let rows = text.split(separator: "\n").dropFirst()
        guard let first = rows.first?.split(separator: ",").first, let last = rows.last?.split(separator: ",").first,
              let start = Double(first.trimmingCharacters(in: .whitespaces)),
              let end = Double(last.trimmingCharacters(in: .whitespaces)) else { return 0 }
        return max(end - start, 0)
    }

    public func removeDeletedEntries() {
        recoverUnfinishedScans()
        let request = NSFetchRequest<NSManagedObject>(entityName: "Recording")
        do {
            let fetched: [NSManagedObject] = try dataContext?.fetch(request) ?? []
            let sessions = fetched.map { session in
                return session as! Recording
            }
            sessions.forEach { session in
                if let path = session.absoluteRgbPath() {
                    let enclosingFolder = path.deletingLastPathComponent()
                    if !FileManager.default.fileExists(atPath: enclosingFolder.path) {
                        // This means that the files have been removed from the device.
                        // For example through finder/iTunes.
                        // This is the main mechanism through which datasets are exported.
                        print("The dataset folder has been removed.")
                        DispatchQueue.main.async {
                            self.removeEntry(session)
                        }
                    }
                } else {
                    print("Session \(session) does not have an rgb file.")
                }
            }

            NotificationCenter.default.post(name: NSNotification.Name("sessionsChanged"), object: nil)
        } catch let error as NSError {
            print("Something went wrong. Error: \(error), \(error.userInfo)")
        }
        
    }

    private func removeEntry(_ session: Recording) {
        session.deleteFiles()
        self.dataContext?.delete(session)
        do {
            try self.dataContext?.save()
        } catch let error as NSError {
            print("Could not delete recording. \(error), \(error.userInfo)")
        }
    }
}
