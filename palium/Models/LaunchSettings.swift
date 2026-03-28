import Foundation
import Observation

@MainActor
@Observable
class LaunchSettings {
    static let shared = LaunchSettings()

    enum WineSource: String, Codable, CaseIterable, Sendable {
        case auto = "Automatic"
        case wineStaging = "Wine Staging + DXMT"
        case gptk = "GPTK (Homebrew)"
    }

    // Wine environment
    var wineSource: WineSource = .auto { didSet { save() } }

    // Graphics
    var metalHUD: Bool = false { didSet { save() } }

    // Performance
    var useAllCores: Bool = true { didSet { save() } }

    // Debug
    var enableDXMTDebug: Bool = false { didSet { save() } }

    // Installed game version (persisted to detect updates)
    var installedVersion: String? { didSet { save() } }

    private static let storageKey = "launchSettings_v3"

    private init() {
        load()
    }

    private struct StoredSettings: Codable {
        var wineSource: WineSource = .auto
        var metalHUD: Bool = false
        var useAllCores: Bool = true
        var enableDXMTDebug: Bool = false
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
        enableDXMTDebug = stored.enableDXMTDebug
        installedVersion = stored.installedVersion
    }

    private func save() {
        let stored = StoredSettings(
            wineSource: wineSource,
            metalHUD: metalHUD,
            useAllCores: useAllCores,
            enableDXMTDebug: enableDXMTDebug,
            installedVersion: installedVersion
        )
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
