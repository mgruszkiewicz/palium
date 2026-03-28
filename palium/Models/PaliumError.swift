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
    case rosettaRequired
    case wineSetupFailed(String)
    case extractionFailed(String)
    

    var isWineNotFound: Bool {
        if case .wineNotFound = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .wineNotFound:
            return "Wine not found. Palium can download Wine Staging automatically, or install GPTK from \(Self.gptkReleasePage)"
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
        case .rosettaRequired:
            return "Rosetta 2 is required for Wine Staging on Apple Silicon but could not be installed"
        case .wineSetupFailed(let reason):
            return "Wine setup failed: \(reason)"
        case .extractionFailed(let reason):
            return "Failed to extract archive: \(reason)"
        }
    }
}
