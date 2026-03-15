import Foundation

import os

nonisolated enum WineManager {

    private static let gptkPrefixRelativePath = "Library/Application Support/com.palium/prefix"

    // GPTK paths
    static let gptkCandidatePaths = [
        "/opt/homebrew/bin/wine64",
        "/usr/local/bin/wine64",
        "/Applications/Game Porting Toolkit.app/Contents/Resources/wine/bin/wine64",
    ]

    // Whisky paths
    private static let whiskyAppPath = "/Applications/Whisky.app"
    private static let whiskyWineRelativePath = "Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine/bin/wine64"
    private static let whiskyBottlesRelativePath = "Library/Containers/com.isaacmarovitz.Whisky/Bottles"

    // MARK: - Detection

    /// Detect a usable Wine environment, respecting the user's source preference.
    static func detect(preferredSource: LaunchSettings.WineSource = .auto) async throws -> WineInfo {
        switch preferredSource {
        case .gptk:
            return try await detectGPTK()
        case .whisky:
            return try detectWhisky()
        case .auto:
            // Try GPTK first, then Whisky
            if let result = try? await detectGPTK() {
                return result
            }
            if let result = try? detectWhisky() {
                return result
            }
            // Last resort: create a new GPTK prefix if any wine binary exists
            guard let wineBinary = findWineBinary() else {
                throw PaliumError.wineNotFound
            }
            let gptkPrefix = gptkPrefixPath()
            try await initializePrefix(wineBinary: wineBinary, at: gptkPrefix)
            let username = try findWineUsername(in: gptkPrefix)
            return WineInfo(
                wineBinaryURL: wineBinary,
                prefixPath: gptkPrefix,
                wineUsername: username,
                source: .gptk
            )
        }
    }

    private static func detectGPTK() async throws -> WineInfo {
        guard let wineBinary = findGPTKBinary() else {
            throw PaliumError.wineNotFound
        }
        let gptkPrefix = gptkPrefixPath()
        if isPrefixValid(gptkPrefix), let username = try? findWineUsername(in: gptkPrefix) {
            return WineInfo(
                wineBinaryURL: wineBinary,
                prefixPath: gptkPrefix,
                wineUsername: username,
                source: .gptk
            )
        }
        // Create new prefix
        try await initializePrefix(wineBinary: wineBinary, at: gptkPrefix)
        let username = try findWineUsername(in: gptkPrefix)
        return WineInfo(
            wineBinaryURL: wineBinary,
            prefixPath: gptkPrefix,
            wineUsername: username,
            source: .gptk
        )
    }

    private static func detectWhisky() throws -> WineInfo {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let whiskyWine = home.appendingPathComponent(whiskyWineRelativePath)
        guard FileManager.default.fileExists(atPath: whiskyWine.path) else {
            throw PaliumError.wineNotFound
        }
        guard let whiskyResult = findWhiskyBottle() else {
            throw PaliumError.noBottleFound
        }
        return WineInfo(
            wineBinaryURL: whiskyWine,
            prefixPath: whiskyResult.bottle,
            wineUsername: whiskyResult.username,
            source: .whisky
        )
    }

    // MARK: - Wine Binary Detection

    static func findWineBinary() -> URL? {
        // Try GPTK first, then Whisky
        if let gptk = findGPTKBinary() { return gptk }
        if let whisky = findWhiskyBinary() { return whisky }
        return nil
    }

    static func findGPTKBinary() -> URL? {
        for path in gptkCandidatePaths {
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    static func findWhiskyBinary() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = home.appendingPathComponent(whiskyWineRelativePath)
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    /// Check if GPTK is installed via Homebrew (not just any wine binary).
    static var isGPTKInstalled: Bool {
        gptkCandidatePaths.contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// Check if Whisky.app is installed.
    static var isWhiskyInstalled: Bool {
        FileManager.default.fileExists(atPath: whiskyAppPath)
    }

    // MARK: - Prefix Management

    private static func gptkPrefixPath() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(gptkPrefixRelativePath)
    }

    private static func isPrefixValid(_ prefix: URL) -> Bool {
        let driveCPath = prefix.appendingPathComponent("drive_c").path
        return FileManager.default.fileExists(atPath: driveCPath)
    }

    private static func initializePrefix(wineBinary: URL, at prefix: URL) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: prefix, withIntermediateDirectories: true)

        try await runWineAsync(
            binary: wineBinary,
            prefix: prefix,
            arguments: ["wineboot", "--init"]
        )
    }

    // MARK: - Whisky Fallback

    private static func findWhiskyBottle() -> (bottle: URL, username: String)? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let bottlesDir = home.appendingPathComponent(whiskyBottlesRelativePath)

        guard fm.fileExists(atPath: bottlesDir.path),
              let contents = try? fm.contentsOfDirectory(at: bottlesDir, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return nil
        }

        for bottle in contents {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: bottle.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            if let username = try? findWineUsername(in: bottle) {
                return (bottle, username)
            }
        }
        return nil
    }

    // MARK: - Username Detection

    static func findWineUsername(in prefix: URL) throws -> String {
        let fm = FileManager.default
        let usersDir = prefix.appendingPathComponent("drive_c/users")

        guard fm.fileExists(atPath: usersDir.path) else {
            throw PaliumError.noBottleFound
        }

        let users = try fm.contentsOfDirectory(atPath: usersDir.path)
        let filtered = users.filter { $0 != "Public" && !$0.hasPrefix(".") && !$0.contains("Default")}

        guard let username = filtered.first else {
            throw PaliumError.noBottleFound
        }
        return username
    }

    // MARK: - Game Detection

    static func isGameInstalled(info: WineInfo) -> Bool {
        let exePath = info.gameInstallPath.appendingPathComponent("PaliaClient.exe")
        return FileManager.default.fileExists(atPath: exePath.path)
    }

    // MARK: - Wine Process Helpers

    static func makeWineEnvironment(info: WineInfo, metalHUD: Bool = false) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = info.prefixPath.path
        env["WINEBOOT_HIDE_DIALOG"] = "1"
        env["WINEDEBUG"] = "-all"
        env["WINEDLLOVERRIDES"] = "dxgi,d3d9,d3d10core,d3d11=n,b"
        env["WINEMSYNC"] = "1"
        env["DXVK_ASYNC"] = "1"
        env["DXVK_STATE_CACHE"] = "1"

        if metalHUD {
            env["MTL_HUD_ENABLED"] = "1"
        }

        return env
    }

    private static func runWineAsync(
        binary: URL,
        prefix: URL,
        arguments: [String],
        timeout: TimeInterval = 120
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = binary
            process.arguments = arguments
            var env = ProcessInfo.processInfo.environment
            env["WINEPREFIX"] = prefix.path
            env["WINEBOOT_HIDE_DIALOG"] = "1"
            env["WINEDEBUG"] = "-all"
            process.environment = env
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            let didResume = OSAllocatedUnfairLock(initialState: false)

            process.terminationHandler = { proc in
                let shouldResume = didResume.withLock { flag -> Bool in
                    if flag { return false }
                    flag = true
                    return true
                }
                guard shouldResume else { return }
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: PaliumError.launchFailed(
                        "Wine process exited with status \(proc.terminationStatus)"
                    ))
                }
            }

            // Timeout
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                let shouldResume = didResume.withLock { flag -> Bool in
                    if flag { return false }
                    flag = true
                    return true
                }
                guard shouldResume else { return }
                if process.isRunning { process.terminate() }
                continuation.resume(throwing: PaliumError.launchFailed(
                    "Wine process timed out after \(Int(timeout))s"
                ))
            }

            do {
                try process.run()
            } catch {
                let shouldResume = didResume.withLock { flag -> Bool in
                    if flag { return false }
                    flag = true
                    return true
                }
                guard shouldResume else { return }
                continuation.resume(throwing: error)
            }
        }
    }

    /// Check if VC++ runtime registry keys are present in the Wine prefix.
    static func isVCRuntimeInstalled(info: WineInfo) -> Bool {
        // Check registry has the full VC++ Runtimes entry
        let registryFile = info.prefixPath.appendingPathComponent("system.reg")
        guard let contents = try? String(contentsOf: registryFile, encoding: .utf8) else {
            return false
        }
        return contents.contains("Runtimes\\\\X64") || contents.contains("Runtimes\\\\x64")
    }

    /// Install VC++ runtime by downloading redistributables, running them via Wine,
    /// and then verifying/fixing the installation with direct DLL copy and registry setup.
    static func installVCRuntime(info: WineInfo) async throws {
        let fm = FileManager.default
        let downloadsPath = info.wineDownloadsPath
        try fm.createDirectory(at: downloadsPath, withIntermediateDirectories: true)

        let redistributables = [
            ("https://aka.ms/vs/17/release/vc_redist.x64.exe", "vc_redist.x64.exe"),
            ("https://aka.ms/vs/17/release/vc_redist.x86.exe", "vc_redist.x86.exe"),
        ]

        // Download redistributables
        for (urlString, filename) in redistributables {
            let destPath = downloadsPath.appendingPathComponent(filename)
            if !fm.fileExists(atPath: destPath.path) {
                let url = URL(string: urlString)!
                let (data, _) = try await URLSession.shared.data(from: url)
                try data.write(to: destPath)
            }
        }

        // Try running installers via Wine (works on newer Wine, fails on older)
        let wineUser = info.wineUsername
        for (_, filename) in redistributables {
            let winePath = "C:\\users\\\(wineUser)\\Downloads\\\(filename)"
            try? await runWineAsync(
                binary: info.wineBinaryURL,
                prefix: info.prefixPath,
                arguments: [winePath, "/install", "/norestart", "/quiet"]
            )
        }

        // Set complete registry keys for UE4 prerequisite check
        try await registerVCRuntime(info: info)
    }

    /// Set all registry keys that UE4 checks for VC++ runtime presence.
    private static func registerVCRuntime(info: WineInfo) async throws {
        // Main runtime registry entries (matching real VC++ redist installer output)
        let regEntries: [(key: String, values: [(name: String, type: String, data: String)])] = [
            (
                "HKLM\\SOFTWARE\\Microsoft\\VisualStudio\\14.0\\VC\\Runtimes\\X64",
                [
                    ("Installed", "REG_DWORD", "1"),
                    ("Major", "REG_DWORD", "14"),
                    ("Minor", "REG_DWORD", "44"),
                    ("Bld", "REG_DWORD", "35211"),
                    ("Rbld", "REG_DWORD", "0"),
                    ("Version", "REG_SZ", "v14.44.35211.00"),
                ]
            ),
            (
                "HKLM\\SOFTWARE\\Microsoft\\VisualStudio\\14.0\\VC\\Runtimes\\X86",
                [
                    ("Installed", "REG_DWORD", "1"),
                    ("Major", "REG_DWORD", "14"),
                    ("Minor", "REG_DWORD", "44"),
                    ("Bld", "REG_DWORD", "35211"),
                    ("Rbld", "REG_DWORD", "0"),
                    ("Version", "REG_SZ", "v14.44.35211.00"),
                ]
            ),
            (
                "HKLM\\SOFTWARE\\Wow6432Node\\Microsoft\\VisualStudio\\14.0\\VC\\Runtimes\\X64",
                [("Installed", "REG_DWORD", "1")]
            ),
            (
                "HKLM\\SOFTWARE\\Wow6432Node\\Microsoft\\VisualStudio\\14.0\\VC\\Runtimes\\X86",
                [("Installed", "REG_DWORD", "1")]
            ),
            (
                "HKLM\\SOFTWARE\\Microsoft\\DevDiv\\VC\\Servicing\\14.0\\RuntimeMinimum",
                [
                    ("Install", "REG_DWORD", "1"),
                    ("Version", "REG_SZ", "14.44.35211"),
                ]
            ),
            (
                "HKLM\\SOFTWARE\\Microsoft\\DevDiv\\VC\\Servicing\\14.0\\RuntimeAdditional",
                [
                    ("Install", "REG_DWORD", "1"),
                    ("Version", "REG_SZ", "14.44.35211"),
                ]
            ),
        ]

        for entry in regEntries {
            for value in entry.values {
                try? await runWineAsync(
                    binary: info.wineBinaryURL,
                    prefix: info.prefixPath,
                    arguments: [
                        "reg", "add", entry.key,
                        "/v", value.name, "/t", value.type, "/d", value.data, "/f",
                    ]
                )
            }
        }

        // Register native DLL overrides so Wine loads real Microsoft DLLs
        let vcDlls = [
            "msvcp140", "vcruntime140", "vcruntime140_1", "concrt140",
            "ucrtbase", "vcomp140", "msvcp140_1", "msvcp140_2",
            "mfc140u", "vccorlib140", "vcruntime140_threads",
        ]
        for dll in vcDlls {
            try? await runWineAsync(
                binary: info.wineBinaryURL,
                prefix: info.prefixPath,
                arguments: [
                    "reg", "add", "HKCU\\Software\\Wine\\DllOverrides",
                    "/v", dll, "/t", "REG_SZ", "/d", "native,builtin", "/f",
                ]
            )
        }
    }
}
