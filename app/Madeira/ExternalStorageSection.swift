// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI
import UniformTypeIdentifiers

/// "Install location" for a Steam game's install sheet: choose a folder on an
/// external drive and send new installs there (docs/EXTERNAL_STORAGE.md).
/// The logic is ExternalStorage.swift's; this view only picks and shows state.
struct ExternalStorageSection: View {
    @State private var picking = false
    @State private var chosen = ExternalStorage.hasChoice
    @State private var onDrive = ExternalStorage.installsExternally
    @State private var driveName: String?
    @State private var freeBytes: Int64?
    @State private var connected = false
    @State private var problem: String?

    var body: some View {
        Section {
            Toggle("Install to the external drive", isOn: Binding(get: { onDrive }, set: { setInstallsExternally($0) }))
                .disabled(!chosen)
            Button { picking = true } label: {
                Label(chosen ? "Choose another drive folder…" : "Choose a folder on the drive…", systemImage: "externaldrive")
            }
            if chosen {
                LabeledContent("Drive", value: connected ? (driveName ?? "Connected") : "Not connected")
                if connected, let freeBytes {
                    LabeledContent("Free space on the drive", value: ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file))
                }
                Button("Stop using the drive for new installs", role: .destructive) { forget() }
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Install location")
        } footer: {
            Text("New downloads of this and other games go into a \"Madeira Games\" folder on the drive you choose; the game's files take no room on this iPad. Connect the drive before you install or start the game. Use a drive formatted as exFAT or APFS. Games already installed stay where they are.")
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                do {
                    try ExternalStorage.choose(url)
                    problem = nil
                    ExternalStorage.installsExternally = true
                    refresh()
                } catch {
                    problem = error.localizedDescription
                }
            case .failure(let failure):
                problem = failure.localizedDescription
            }
        }
        .onAppear { refresh() }
    }

    private func setInstallsExternally(_ on: Bool) {
        ExternalStorage.installsExternally = on
        refresh()
    }

    private func forget() {
        ExternalStorage.forget()
        problem = nil
        refresh()
    }

    private func refresh() {
        chosen = ExternalStorage.hasChoice
        onDrive = ExternalStorage.installsExternally
        connected = chosen && ExternalStorage.activate() != nil
        if connected {
            let info = ExternalStorage.driveInfo()
            driveName = info.name
            freeBytes = info.free
        } else {
            driveName = nil
            freeBytes = nil
        }
    }
}
