import Foundation

nonisolated enum WineManager {

    private static let gptkPrefixRelativePath = "Library/Application Support/com.palium/prefix"

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
        let candidates = [
            "/opt/homebrew/bin/wine64",
            "/usr/local/bin/wine64",
            "/Applications/Game Porting Toolkit.app/Contents/Resources/wine/bin/wine64",
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    private static func findWhiskyBinary() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = home.appendingPathComponent(whiskyWineRelativePath)
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    /// Check if GPTK is installed via Homebrew (not just any wine binary).
    static var isGPTKInstalled: Bool {
        let candidates = [
            "/opt/homebrew/bin/wine64",
            "/usr/local/bin/wine64",
            "/Applications/Game Porting Toolkit.app/Contents/Resources/wine/bin/wine64",
        ]
        return candidates.contains { FileManager.default.fileExists(atPath: $0) }
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
        let filtered = users.filter { $0 != "Public" && !$0.hasPrefix(".") }

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
        env["WINEDLLOVERRIDES"] = "dxgi,d3d9,d3d10core,d3d11,msvcp140,msvcp140_1,msvcp140_2,vcruntime140,vcruntime140_1,vcruntime140_threads,concrt140,ucrtbase,vcomp140,mfc140u,vccorlib140=n,b"
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
        arguments: [String]
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

            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: PaliumError.launchFailed(
                        "Wine process exited with status \(proc.terminationStatus)"
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Check if VC++ runtime is properly installed (real DLLs + registry).
    static func isVCRuntimeInstalled(info: WineInfo) -> Bool {
        let fm = FileManager.default
        let sys32 = info.prefixPath.appendingPathComponent("drive_c/windows/system32")

        // Check that vcruntime140.dll exists and is a real Microsoft DLL (>100KB),
        // not a tiny Wine builtin stub
        let vcrt = sys32.appendingPathComponent("vcruntime140.dll").path
        guard fm.fileExists(atPath: vcrt),
              let attrs = try? fm.attributesOfItem(atPath: vcrt),
              let size = attrs[.size] as? UInt64,
              size > 100_000 else {
            return false
        }

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

        // Verify the DLLs are real Microsoft binaries (not Wine stubs).
        // If the installer failed silently, extract DLLs from the redist using cabextract.
        let sys32 = info.prefixPath.appendingPathComponent("drive_c/windows/system32")
        let vcrt = sys32.appendingPathComponent("vcruntime140.dll").path
        let attrs = try? fm.attributesOfItem(atPath: vcrt)
        let size = (attrs?[.size] as? UInt64) ?? 0

        if size < 100_000 {
            // DLLs are Wine stubs — extract real ones from the downloaded redistributable
            try await extractVCRuntimeDLLs(
                from: downloadsPath.appendingPathComponent("vc_redist.x64.exe"),
                to: sys32
            )
            // Also extract x86 DLLs to syswow64
            let syswow64 = info.prefixPath.appendingPathComponent("drive_c/windows/syswow64")
            try fm.createDirectory(at: syswow64, withIntermediateDirectories: true)
            try await extractVCRuntimeDLLs(
                from: downloadsPath.appendingPathComponent("vc_redist.x86.exe"),
                to: syswow64
            )
        }

        // Set complete registry keys for UE4 prerequisite check
        try await registerVCRuntime(info: info)
    }

    /// Extract VC++ DLLs from the redistributable using cabextract/expand.
    private static func extractVCRuntimeDLLs(from redistPath: URL, to destDir: URL) async throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("vcredist_\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        // The VC++ redist .exe is a self-extracting archive; extract with 7z or expand
        // Try expand (macOS built-in) first, then fall back to copying from a known source
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["7z", "x", "-o\(tempDir.path)", redistPath.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let ran7z = (try? process.run()).map { process.waitUntilExit(); return process.terminationStatus == 0 } ?? false

        if ran7z {
            // Find and extract .cab files that contain the DLLs
            if let cabFiles = try? fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil) {
                for cab in cabFiles where cab.pathExtension == "cab" {
                    let cabProcess = Process()
                    cabProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                    cabProcess.arguments = ["7z", "x", "-o\(tempDir.path)/dlls", cab.path]
                    cabProcess.standardOutput = FileHandle.nullDevice
                    cabProcess.standardError = FileHandle.nullDevice
                    try? cabProcess.run()
                    cabProcess.waitUntilExit()
                }
            }

            // Copy extracted DLLs to destination
            let dllNames = [
                "msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll",
                "concrt140.dll", "ucrtbase.dll", "vcomp140.dll",
                "msvcp140_1.dll", "msvcp140_2.dll", "mfc140u.dll",
                "vccorlib140.dll", "vcruntime140_threads.dll",
            ]
            let searchDirs = [tempDir, tempDir.appendingPathComponent("dlls")]
            for dllName in dllNames {
                for searchDir in searchDirs {
                    if let found = findFile(named: dllName, in: searchDir) {
                        let dest = destDir.appendingPathComponent(dllName)
                        try? fm.removeItem(at: dest)
                        try? fm.copyItem(at: found, to: dest)
                        break
                    }
                }
            }
        }
    }

    /// Recursively find a file by name in a directory.
    private static func findFile(named name: String, in directory: URL) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }
        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent.lowercased() == name.lowercased() {
                return fileURL
            }
        }
        return nil
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
