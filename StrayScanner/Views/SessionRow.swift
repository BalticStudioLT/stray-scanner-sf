//
//  SessionRow.swift
//  Stray Scanner
//
//  Created by Kenneth Blomqvist on 11/15/20.
//  Copyright © 2020 Stray Robots. All rights reserved.
//

import SwiftUI

struct SessionRow: View {
    var session: Recording
    @State private var summary: ScanSummary?

    var body: some View {
        let duration = String(format: "%d s", Int(round(session.duration)))
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(sessionTitle())
                    .font(.headline)
                Spacer()
                Text(duration)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let summary = summary {
                ScanSummaryChips(summary: summary)
            }
        }
        .padding(.vertical, 6)
        .onAppear {
            guard summary == nil else { return }
            let directory = session.directoryPath()
            DispatchQueue.global(qos: .utility).async {
                let loaded = ScanSummary.load(directory: directory)
                DispatchQueue.main.async { summary = loaded }
            }
        }
    }

    private func sessionTitle() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        dateFormatter.timeStyle = .short
        
        if let created = session.createdAt {
            return dateFormatter.string(from: created)
        } else {
            return "Session"
        }
    }
}

