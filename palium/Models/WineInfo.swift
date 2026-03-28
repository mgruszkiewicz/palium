import Foundation

nonisolated struct WineInfo: Sendable {
    let wineBinaryURL: URL
    let prefixPath: URL
    let wineUsername: String
    let source: Source

    enum Source: String, Sendable {
        case gptk = "GPTK"
        case wineStaging = "Wine Staging"
    }

    var gameInstallPath: URL {
        prefixPath
            .appendingPathComponent("drive_c/users/\(wineUsername)/AppData/Local/Palia/Client")
    }

    var gameSavedPath: URL {
        prefixPath
            .appendingPathComponent("drive_c/users/\(wineUsername)/AppData/Local/Palia/Saved")
    }

    var wineDownloadsPath: URL {
        prefixPath
            .appendingPathComponent("drive_c/users/\(wineUsername)/Downloads")
    }
}
