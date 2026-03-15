//
//  paliumApp.swift
//  palium
//
//  Created by Mateusz Gruszkiewicz on 12/03/2026.
//

import SwiftUI

@main
struct PaliumApp: App {
    var body: some Scene {
        Window("Palium", id: "main") {
            ContentView()
        }
        .defaultSize(width: 500, height: 400)
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
        }
    }
}
