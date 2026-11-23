import Foundation

nonisolated struct WineInfo: Sendable {
    let wineBinaryURL: URL
    let prefixPath: URL
    let wineUsername: String

    var gameInstallPath: URL {
        prefixPath
            .appendingPathComponent("drive_c/users/\(wineUsername)/AppData/Local/Palia/Client")
    }

    var gameSavedPath: URL {
        prefixPath
            .appendingPathComponent("drive_c/users/\(wineUsername)/AppData/Local/Palia/Saved")
    }

    /// Palium's scratch folder for installers, `C:\palium-downloads`. Not the Windows
    /// user's Downloads: Wine links that to the Mac user's real ~/Downloads.
    var wineDownloadsPath: URL {
        prefixPath.appendingPathComponent("drive_c/\(Self.downloadsFolderName)")
    }

    static let downloadsFolderName = "palium-downloads"

    /// `wineDownloadsPath` as Windows sees it.
    var wineDownloadsWindowsPath: String {
        "C:\\\(Self.downloadsFolderName)"
    }
}
