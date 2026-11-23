import Foundation

enum PaliumError: LocalizedError, Sendable, Equatable {
    static let gptkReleasePage = "https://github.com/Gcenx/game-porting-toolkit/releases"

    case wineNotFound
    case noBottleFound
    case gameNotInstalled
    case manifestParseFailed(String)
    case downloadFailed(path: String, reason: String)
    case hashMismatch(path: String)
    case launchFailed(String)
    case cdnError(String)
    case prefixInitFailed(String)
    case engineInstallFailed(String)
    case migrationFailed(String)


    var isWineNotFound: Bool {
        if case .wineNotFound = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .wineNotFound:
            return "Game Porting Toolkit not found. Palium uses its D3DMetal: install it from \(Self.gptkReleasePage)"
        case .noBottleFound:
            return "No Wine prefix found. The app will create one automatically — please retry"
        case .gameNotInstalled:
            return "Palia is not installed. Download the game first"
        case .manifestParseFailed(let reason):
            return "Failed to parse game manifest: \(reason)"
        case .downloadFailed(let path, let reason):
            return "Download failed for \(path): \(reason)"
        case .hashMismatch(let path):
            return "Hash verification failed for \(path)"
        case .launchFailed(let reason):
            return "Failed to launch game: \(reason)"
        case .cdnError(let message):
            return "CDN error: \(message)"
        case .prefixInitFailed(let reason):
            return "Failed to initialize Wine prefix: \(reason)"
        case .engineInstallFailed(let reason):
            return "Couldn't install the Wine engine: \(reason)"
        case .migrationFailed(let reason):
            return reason
        }
    }
}
