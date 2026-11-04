//
//  ShareUtility.swift
//  StrayScanner
//
//  Created by Claude on 6/24/25.
//

import Foundation

/// Utility class for creating shareable archives from recording datasets
class ShareUtility {
    
    /// Creates a shareable ZIP archive from a recording's dataset
    /// - Parameter recording: The recording to create a ZIP archive for
    /// - Returns: URL of the created ZIP file
    static func createShareableArchive(for recording: Recording) async throws -> URL {
        guard let sourceDirectory = recording.directoryPath() else {
            throw NSError(domain: "ShareError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to get recording directory path"])
        }
        
        let tempDirectory = FileManager.default.temporaryDirectory
        let archiveURL = tempDirectory.appendingPathComponent(sourceDirectory.lastPathComponent + ".zip")
        
        // Remove existing archive if it exists
        try? FileManager.default.removeItem(at: archiveURL)
        
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try createZipArchive(sourceDirectory: sourceDirectory, destinationURL: archiveURL)
                    continuation.resume(returning: archiveURL)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Zips a scan folder into the temporary directory (synchronous; call off the main thread).
    static func createZipArchive(directory: URL) throws -> URL {
        let archiveURL = FileManager.default.temporaryDirectory.appendingPathComponent(directory.lastPathComponent + "-upload.zip")
        try? FileManager.default.removeItem(at: archiveURL)
        try createZipArchive(sourceDirectory: directory, destinationURL: archiveURL)
        return archiveURL
    }

    private static func createZipArchive(sourceDirectory: URL, destinationURL: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        var copyError: Error?

        coordinator.coordinate(readingItemAt: sourceDirectory, options: [.forUploading], error: &coordinatorError) { zipURL in
            do {
                try FileManager.default.copyItem(at: zipURL, to: destinationURL)
            } catch {
                copyError = error
            }
        }

        if let error = coordinatorError ?? copyError {
            throw error
        }
    }
}
