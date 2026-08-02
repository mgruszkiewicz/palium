//
//  paliumApp.swift
//  palium
//
//  Created by Mateusz Gruszkiewicz on 12/03/2026.
//

import SwiftUI

@main
struct PaliumApp: App {
    /// Referenced here so the Sparkle updater starts at launch and stays alive.
    @State private var updater = UpdaterService.shared

    var body: some Scene {
        Window("Palium", id: "main") {
            ContentView()
        }
        .defaultSize(width: 500, height: 400)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }
        }

        Settings {
            SettingsView()
        }
    }
}
