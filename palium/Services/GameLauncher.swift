import Foundation

nonisolated enum GameLauncher {

    struct LaunchOptions: Sendable {
        let metalHUD: Bool
        let useAllCores: Bool
    }

    static func launch(info: WineInfo, options: LaunchOptions) throws -> Process {
        let wineUser = info.wineUsername
        let gameWindowsPath = "C:\\users\\\(wineUser)\\AppData\\Local\\Palia\\Client\\PaliaClient.exe"

        // Verify the game exists on the macOS filesystem
        let gameExePath = info.gameInstallPath.appendingPathComponent("PaliaClient.exe")
        guard FileManager.default.fileExists(atPath: gameExePath.path) else {
            throw PaliumError.gameNotInstalled
        }

        var arguments = [gameWindowsPath, "-dx11"]

        // UE4 engine flags
        if options.useAllCores {
            arguments.append("-USEALLAVAILABLECORES")
        }

        let process = Process()
        process.executableURL = info.wineBinaryURL
        process.arguments = arguments
        process.environment = WineManager.makeWineEnvironment(info: info, metalHUD: options.metalHUD)
        process.currentDirectoryURL = info.gameInstallPath

        try process.run()
        return process
    }
}
