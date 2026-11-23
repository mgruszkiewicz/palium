import Foundation
import Observation

@MainActor
@Observable
class LaunchSettings {
    static let shared = LaunchSettings()

    /// Direct3D version Palia renders with (passed as -dx11 / -dx12).
    enum GraphicsAPI: String, Codable, CaseIterable, Sendable {
        case dx11 = "DirectX 11"
        case dx12 = "DirectX 12"

        var launchArgument: String {
            switch self {
            case .dx11: "-dx11"
            case .dx12: "-dx12"
            }
        }
    }

    // Graphics
    var metalHUD: Bool = false { didSet { save() } }
    var graphicsAPI: GraphicsAPI = .dx11 { didSet { save() } }

    // Performance
    var useAllCores: Bool = true { didSet { save() } }

    // Installed game version (persisted to detect updates)
    var installedVersion: String? { didSet { save() } }

    // SHA-256 of the manifest's "contents" node at install time — catches
    // content updates the CDN ships without bumping the channel version.
    var installedManifestHash: Data? { didSet { save() } }

    private static let storageKey = "launchSettings_v2"

    /// Suppresses the didSet-triggered save() while restoring persisted values —
    /// property observers fire for assignments made during load.
    @ObservationIgnored private var isLoaded = false

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let stored = try? JSONDecoder().decode(StoredSettings.self, from: data) {
            metalHUD = stored.metalHUD
            graphicsAPI = stored.graphicsAPI
            useAllCores = stored.useAllCores
            installedVersion = stored.installedVersion
            installedManifestHash = stored.installedManifestHash
        }
        isLoaded = true
    }

    private struct StoredSettings: Codable {
        var metalHUD: Bool = false
        var graphicsAPI: GraphicsAPI = .dx11
        var useAllCores: Bool = true
        var installedVersion: String?
        var installedManifestHash: Data?

        init(
            metalHUD: Bool,
            graphicsAPI: GraphicsAPI,
            useAllCores: Bool,
            installedVersion: String?,
            installedManifestHash: Data?
        ) {
            self.metalHUD = metalHUD
            self.graphicsAPI = graphicsAPI
            self.useAllCores = useAllCores
            self.installedVersion = installedVersion
            self.installedManifestHash = installedManifestHash
        }

        /// Keys missing from older saved settings fall back to their defaults
        /// instead of failing the whole decode (which would forget the
        /// installed version and every other setting). Keys this version no longer
        /// has (`wineSource`, from the GPTK/Whisky picker) are ignored.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            metalHUD = try c.decodeIfPresent(Bool.self, forKey: .metalHUD) ?? false
            graphicsAPI = try c.decodeIfPresent(GraphicsAPI.self, forKey: .graphicsAPI) ?? .dx11
            useAllCores = try c.decodeIfPresent(Bool.self, forKey: .useAllCores) ?? true
            installedVersion = try c.decodeIfPresent(String.self, forKey: .installedVersion)
            installedManifestHash = try c.decodeIfPresent(Data.self, forKey: .installedManifestHash)
        }
    }

    private func save() {
        guard isLoaded else { return }
        let stored = StoredSettings(
            metalHUD: metalHUD,
            graphicsAPI: graphicsAPI,
            useAllCores: useAllCores,
            installedVersion: installedVersion,
            installedManifestHash: installedManifestHash
        )
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
