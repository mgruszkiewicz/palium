import Foundation

nonisolated enum GameLauncher {

    struct LaunchOptions: Sendable {
        let metalHUD: Bool
        let useAllCores: Bool
        let enableDXMTDebug: Bool
    }

    static func launch(
        info: WineInfo,
        options: LaunchOptions,
        onLog: (@Sendable (String, LogEntry.Level) -> Void)? = nil
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
        process.environment = WineManager.makeWineEnvironment(
            info: info,
            metalHUD: options.metalHUD,
            enableDXMTDebug: options.enableDXMTDebug
        )
        process.currentDirectoryURL = info.gameInstallPath

        // When DXMT debug is enabled, capture Wine's stderr to surface DLL loading info
        if options.enableDXMTDebug, let onLog {
            let pipe = Pipe()
            process.standardError = pipe

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty,
                      let line = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      !line.isEmpty else { return }
                // Filter to only DLL-related lines to avoid flooding the log
                let lower = line.lowercased()
                if lower.contains("loaddll") || lower.contains("module")
                    || lower.contains("dxmt") || lower.contains("dxgi")
                    || lower.contains("d3d11") || lower.contains("d3d10")
                    || lower.contains("winemetal") || lower.contains("dllpath") {
                    onLog("[Wine] \(line)", .info)
                }
            }
        }

        try process.run()
        return process
    }
}
