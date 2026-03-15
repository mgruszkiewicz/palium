//
//  paliumApp.swift
//  palium
//
//  Created by Mateusz Gruszkiewicz on 12/03/2026.
//

import SwiftUI

@main
struct paliumApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 500, height: 400)
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
        }
    }
}
