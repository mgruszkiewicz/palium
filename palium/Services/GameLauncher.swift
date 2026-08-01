import Foundation

nonisolated enum GameLauncher {

    struct LaunchOptions: Sendable {
        let metalHUD: Bool
        let useAllCores: Bool
    }

    /// Launch the game. `onExit` is installed before the process starts, so it
    /// fires even if the game exits immediately.
    static func launch(
        info: WineInfo,
        options: LaunchOptions,
        onExit: @escaping @Sendable (Int32) -> Void = { _ in }
    ) throws -> Process {
        let wineUser = info.wineUsername

        // Launch the actual game binary directly, NOT PaliaClient.exe (which is a
        // launcher stub that runs a VC++ prerequisite check via UEPrereqSetup).
        // The prerequisite check fails under GPTK because the WiX Burn bootstrapper
        // can't load kernel32.dll. Bypassing the stub avoids the dialog entirely.
        let gameWindowsPath = "C:\\users\\\(wineUser)\\AppData\\Local\\Palia\\Client\\Palia\\Binaries\\Win64\\PaliaClient-Win64-Shipping.exe"

        // Verify the game binary exists on the macOS filesystem
        let gameBinaryPath = info.gameInstallPath
            .appendingPathComponent("Palia/Binaries/Win64/PaliaClient-Win64-Shipping.exe")
        guard FileManager.default.fileExists(atPath: gameBinaryPath.path) else {
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
        process.terminationHandler = { onExit($0.terminationStatus) }

        try process.run()
        return process
    }
}
