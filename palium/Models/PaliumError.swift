import Foundation

enum PaliumError: LocalizedError {
    case wineNotFound
    case noBottleFound
    case gameNotInstalled
    case manifestParseFailed(String)
    case downloadFailed(path: String, reason: String)
    case hashMismatch(path: String)
    case launchFailed(String)
    case cdnError(String)
    case prefixInitFailed(String)

    var isWineNotFound: Bool {
        if case .wineNotFound = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .wineNotFound:
            return "Wine not found. Install Game Porting Toolkit via Homebrew:\nbrew tap Gcenx/homebrew-wine && brew install --cask game-porting-toolkit"
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
        }
    }
}
