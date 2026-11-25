//
//  InformationView.swift
//  StrayScanner
//
//  Created by Kenneth Blomqvist on 2/28/21.
//  Copyright © 2021 Stray Robots. All rights reserved.
//
//  stray-scanner-sf: rewritten as a short scanning guide for this app (the upstream text described
//  cable export only).
//

import SwiftUI

struct InformationView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    card("Before you start", "sun.max", [
                        "Turn on the lights. More light means lower ISO and cleaner walls.",
                        "Wipe the lens.",
                        "Aim at the scene from about 2 m, then press record. Focus and white balance lock at that moment.",
                        "Shutter 1/250 s is a good default. Use 1/120 s only when the room is dark.",
                    ])
                    card("While scanning", "figure.walk", [
                        "Walk slowly and turn slowly. Keep the blur bar under the tip green.",
                        "Stay 0.5 to 4 m from what you film. The LiDAR reaches about 5 m.",
                        "Film every surface from at least three directions. The stats show the share seen from 3+ sides.",
                        "Sweep walls floor to ceiling in overlapping stripes (the wall path guide in the views menu helps).",
                        "End where you started, so the path closes.",
                        "People and things that move are masked out, but a still scene always gives the cleanest splat.",
                    ])
                    card("Views on the record screen", "square.3.layers.3d", [
                        "Camera, Depth and Mix show what the phone sees.",
                        "Points and Map show what has been scanned so far. With Colour by coverage on (views menu), red areas need another angle.",
                        "PC preview shows the draft splat the PC trains while you scan, when the live link is on.",
                        "Dim darkens the screen to save battery; the phone buzzes when something is wrong.",
                    ])
                    card("After the scan", "cube.transparent", [
                        "Send to PC uploads the scan to SplatForge, which trains the splat.",
                        "Train here makes a rough draft on the phone, without the PC (experimental).",
                        "Finished splats are listed on the scan's page and in the Splats tab.",
                        "Continue adds to a scan in the same coordinates. Add 0.5× adds an ultra-wide pass.",
                    ])
                    card("Where the files are", "folder", [
                        "Files app, On My iPhone, Stray SF: one folder per scan.",
                        "Share makes a ZIP of a scan for AirDrop or a cable.",
                    ])
                    Text("Based on the open-source Stray Scanner (github.com/StrayRobots/scanner). Provided as is.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                .padding(16)
            }
            .background(Color("BackgroundColor").ignoresSafeArea())
            .navigationTitle("How to scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func card(_ title: String, _ symbol: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.headline)
            ForEach(lines, id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•").foregroundStyle(.secondary)
                    Text(line)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 20)
    }
}

struct InformationView_Previews: PreviewProvider {
    static var previews: some View {
        InformationView()
    }
}
