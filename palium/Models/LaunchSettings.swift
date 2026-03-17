import Foundation
import Observation

@MainActor
@Observable
class LaunchSettings {
    static let shared = LaunchSettings()

    enum WineSource: String, Codable, CaseIterable, Sendable {
        case auto = "Automatic"
        case gptk = "GPTK (Homebrew)"
        case whisky = "Whisky"
    }

    // Wine environment
    var wineSource: WineSource = .auto { didSet { save() } }

    // Graphics
    var metalHUD: Bool = false { didSet { save() } }

    // Performance
    var useAllCores: Bool = true { didSet { save() } }

    // Installed game version (persisted to detect updates)
    var installedVersion: String? { didSet { save() } }

    private static let storageKey = "launchSettings_v2"

    private init() {
        load()
    }

    private struct StoredSettings: Codable {
        var wineSource: WineSource = .auto
        var metalHUD: Bool = false
        var useAllCores: Bool = true
        var installedVersion: String?
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let stored = try? JSONDecoder().decode(StoredSettings.self, from: data) else {
            return
        }
        wineSource = stored.wineSource
        metalHUD = stored.metalHUD
        useAllCores = stored.useAllCores
        installedVersion = stored.installedVersion
    }

    private func save() {
        let stored = StoredSettings(
            wineSource: wineSource,
            metalHUD: metalHUD,
            useAllCores: useAllCores,
            installedVersion: installedVersion
        )
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
