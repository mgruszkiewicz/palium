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
            if let result = try? await detectGPTK() {
                return result
            }
            if let result = try? detectWhisky() {
                return result
            }
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

    static var isGPTKInstalled: Bool {
        gptkCandidatePaths.contains { FileManager.default.fileExists(atPath: $0) }
    }

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
        let filtered = users.filter { $0 != "Public" && !$0.hasPrefix(".") && !$0.contains("Default") }

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

    // MARK: - Diagnostics

    struct DiagnosticResult: Sendable {
        let name: String
        let passed: Bool
        let detail: String
    }

    /// Minimum size for a real VC++ DLL (Wine PE stubs are typically 1–5 KB).
    private static let minRealDLLSize: UInt64 = 10_000

    /// VC++ DLLs needed for UE4. Used for diagnostics, installation, and DLL overrides.
    static let vcDLLNames = [
        "msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll",
        "concrt140.dll", "ucrtbase.dll", "vcomp140.dll",
        "msvcp140_1.dll", "msvcp140_2.dll", "mfc140u.dll",
        "vccorlib140.dll", "vcruntime140_threads.dll",
    ]

    /// Run all troubleshooting diagnostics and return results.
    static func runDiagnostics(info: WineInfo) async -> [DiagnosticResult] {
        var results: [DiagnosticResult] = []
        let fm = FileManager.default

        let winePath = info.wineBinaryURL.path
        let wineExists = fm.isExecutableFile(atPath: winePath)
        results.append(DiagnosticResult(
            name: "Wine Binary",
            passed: wineExists,
            detail: wineExists ? winePath : "Not found at \(winePath)"
        ))

        if wineExists {
            let versionOutput = await getWineVersion(binary: info.wineBinaryURL, prefix: info.prefixPath)
            results.append(DiagnosticResult(
                name: "Wine Runs",
                passed: versionOutput != nil,
                detail: versionOutput ?? "wine64 --version failed to execute"
            ))
        } else {
            results.append(DiagnosticResult(name: "Wine Runs", passed: false, detail: "Skipped (no binary)"))
        }

        let prefixValid = isPrefixValid(info.prefixPath)
        results.append(DiagnosticResult(
            name: "Wine Prefix",
            passed: prefixValid,
            detail: prefixValid ? info.prefixPath.path : "Missing drive_c at \(info.prefixPath.path)"
        ))

        let userFound = !info.wineUsername.isEmpty
        results.append(DiagnosticResult(
            name: "Wine User",
            passed: userFound,
            detail: userFound ? info.wineUsername : "No user found in prefix"
        ))

        let systemRegPath = info.prefixPath.appendingPathComponent("system.reg").path
        let systemRegExists = fm.fileExists(atPath: systemRegPath)
        results.append(DiagnosticResult(
            name: "system.reg",
            passed: systemRegExists,
            detail: systemRegExists ? "Present" : "Missing — prefix may be corrupt"
        ))

        let vcRegInstalled = isVCRuntimeInstalled(info: info)
        results.append(DiagnosticResult(
            name: "VC++ Registry Keys",
            passed: vcRegInstalled,
            detail: vcRegInstalled ? "Installed=1 found in system.reg" : "Missing — run Reinstall VC++ Runtime"
        ))

        let sys32 = info.prefixPath.appendingPathComponent("drive_c/windows/system32")
        for dll in vcDLLNames {
            let dllPath = sys32.appendingPathComponent(dll).path
            if let attrs = try? fm.attributesOfItem(atPath: dllPath),
               let size = attrs[.size] as? UInt64 {
                let isReal = size > minRealDLLSize
                results.append(DiagnosticResult(
                    name: dll,
                    passed: isReal,
                    detail: isReal ? "\(formatSize(size))" : "\(formatSize(size)) (Wine stub)"
                ))
            } else {
                results.append(DiagnosticResult(name: dll, passed: false, detail: "Missing"))
            }
        }

        let userRegPath = info.prefixPath.appendingPathComponent("user.reg").path
        if let userRegContents = try? String(contentsOfFile: userRegPath, encoding: .utf8) {
            let hasOverrides = userRegContents.contains("DllOverrides")
                && userRegContents.contains("vcruntime140")
            results.append(DiagnosticResult(
                name: "DLL Overrides (user.reg)",
                passed: hasOverrides,
                detail: hasOverrides ? "native,builtin entries found" : "Missing Wine DLL override entries"
            ))
        } else {
            results.append(DiagnosticResult(name: "DLL Overrides (user.reg)", passed: false, detail: "user.reg not found"))
        }

        let gameInstalled = isGameInstalled(info: info)
        results.append(DiagnosticResult(
            name: "PaliaClient.exe",
            passed: gameInstalled,
            detail: gameInstalled ? info.gameInstallPath.appendingPathComponent("PaliaClient.exe").path : "Not found"
        ))

        return results
    }

    /// Run `wine64 --version` and capture output.
    private static func getWineVersion(binary: URL, prefix: URL) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = binary
            process.arguments = ["--version"]
            var env = ProcessInfo.processInfo.environment
            env["WINEPREFIX"] = prefix.path
            env["WINEBOOT_HIDE_DIALOG"] = "1"
            env["WINEDEBUG"] = "-all"
            process.environment = env

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: output?.isEmpty == false ? output : nil)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    // MARK: - VC++ Runtime

    /// Check if VC++ runtime is installed: real DLLs present AND registry keys set.
    static func isVCRuntimeInstalled(info: WineInfo) -> Bool {
        let fm = FileManager.default
        let sys32 = info.prefixPath.appendingPathComponent("drive_c/windows/system32")

        // Check that vcruntime140.dll exists and is a real Microsoft DLL,
        // not a tiny Wine builtin stub
        let vcrt = sys32.appendingPathComponent("vcruntime140.dll").path
        guard fm.fileExists(atPath: vcrt),
              let attrs = try? fm.attributesOfItem(atPath: vcrt),
              let size = attrs[.size] as? UInt64,
              size > minRealDLLSize else {
            return false
        }

        // Check registry has the VC++ Runtimes entry
        let registryFile = info.prefixPath.appendingPathComponent("system.reg")
        guard let contents = try? String(contentsOf: registryFile, encoding: .utf8) else {
            return false
        }
        return contents.contains("Runtimes\\\\X64") || contents.contains("Runtimes\\\\x64")
    }

    /// Install VC++ runtime by downloading the official redistributables, running them
    /// through Wine, and extracting DLLs with 7z as fallback. Sets registry via wine reg add.
    static func installVCRuntime(
        info: WineInfo,
        onLog: (@Sendable (String, LogEntry.Level) -> Void)? = nil
    ) async throws {
        let log = onLog ?? { _, _ in }
        let fm = FileManager.default
        let downloadsPath = info.wineDownloadsPath
        try fm.createDirectory(at: downloadsPath, withIntermediateDirectories: true)

        let redistributables = [
            ("https://aka.ms/vs/17/release/vc_redist.x64.exe", "vc_redist.x64.exe"),
            ("https://aka.ms/vs/17/release/vc_redist.x86.exe", "vc_redist.x86.exe"),
        ]

        // Step 1: Download redistributables
        for (urlString, filename) in redistributables {
            let destPath = downloadsPath.appendingPathComponent(filename)
            if fm.fileExists(atPath: destPath.path) {
                log("\(filename) already cached", .info)
            } else {
                log("Downloading \(filename)...", .info)
                let url = URL(string: urlString)!
                let (data, _) = try await URLSession.shared.data(from: url)
                try data.write(to: destPath)
                log("Downloaded \(filename) (\(formatSize(UInt64(data.count))))", .success)
            }
        }

        // Step 2: Try running installers via Wine
        let wineUser = info.wineUsername
        for (_, filename) in redistributables {
            let winePath = "C:\\users\\\(wineUser)\\Downloads\\\(filename)"
            log("Running \(filename) via Wine...", .info)
            do {
                try await runWineAsync(
                    binary: info.wineBinaryURL,
                    prefix: info.prefixPath,
                    arguments: [winePath, "/install", "/norestart", "/quiet"]
                )
                log("\(filename) installer completed", .success)
            } catch {
                log("\(filename) installer failed (will try extraction fallback): \(error.localizedDescription)", .warning)
            }
        }

        // Step 3: Verify DLLs are real — if they're Wine stubs, extract natively
        let sys32 = info.prefixPath.appendingPathComponent("drive_c/windows/system32")
        let vcrt = sys32.appendingPathComponent("vcruntime140.dll").path
        let vcrtSize = ((try? fm.attributesOfItem(atPath: vcrt))?[.size] as? UInt64) ?? 0

        if vcrtSize < minRealDLLSize {
            log("vcruntime140.dll is \(formatSize(vcrtSize)) (Wine stub) — extracting from redistributable...", .warning)
            try await extractVCRuntimeDLLs(
                from: downloadsPath.appendingPathComponent("vc_redist.x64.exe"),
                to: sys32,
                info: info,
                onLog: log
            )
            let syswow64 = info.prefixPath.appendingPathComponent("drive_c/windows/syswow64")
            try fm.createDirectory(at: syswow64, withIntermediateDirectories: true)
            try await extractVCRuntimeDLLs(
                from: downloadsPath.appendingPathComponent("vc_redist.x86.exe"),
                to: syswow64,
                info: info,
                onLog: log
            )
        } else {
            log("vcruntime140.dll is \(formatSize(vcrtSize)) (real Microsoft DLL)", .success)
        }

        // Step 4: Set registry keys via wine reg add
        log("Setting registry keys via wine reg add...", .info)
        try await registerVCRuntime(info: info, onLog: log)
    }

    /// Extract VC++ DLLs from the redistributable .exe natively.
    /// The .exe is a WiX Burn bundle containing embedded CAB archives.
    /// We find the CAB payload by scanning for the MSCF signature, extract it,
    /// then use Wine's `expand.exe` to unpack DLLs. No external tools needed.
    private static func extractVCRuntimeDLLs(
        from redistPath: URL,
        to destDir: URL,
        info: WineInfo,
        onLog: @Sendable (String, LogEntry.Level) -> Void = { _, _ in }
    ) async throws {
        let fm = FileManager.default
        let cabDir = info.wineDownloadsPath.appendingPathComponent("cab_extract")
        try? fm.removeItem(at: cabDir)
        try fm.createDirectory(at: cabDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: cabDir) }

        // Step 1: Find and extract the payload CAB from the .exe binary (native Swift)
        let exeData = try Data(contentsOf: redistPath, options: .mappedIfSafe)
        let mscf: [UInt8] = [0x4D, 0x53, 0x43, 0x46] // "MSCF" — CAB signature

        var payloadOffset = -1
        var payloadSize = 0
        var searchOffset = 0
        while searchOffset < exeData.count - 16 {
            guard let pos = exeData[searchOffset...].firstRange(of: Data(mscf))?.lowerBound else { break }
            let offset = exeData.distance(from: exeData.startIndex, to: pos)
            // CAB size is a little-endian uint32 at offset +8
            let sizeBytes = exeData[(offset + 8)..<(offset + 12)]
            let cabSize = sizeBytes.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            onLog("Found CAB at offset \(offset), size \(formatSize(UInt64(cabSize)))", .info)
            if cabSize > 1_000_000 { // the payload CAB (not the small UX cab)
                payloadOffset = offset
                payloadSize = Int(cabSize)
            }
            searchOffset = offset + 1
        }

        guard payloadOffset >= 0 else {
            onLog("No payload CAB found in redistributable", .error)
            return
        }

        let cabPath = cabDir.appendingPathComponent("payload.cab")
        try exeData[payloadOffset..<(payloadOffset + payloadSize)].write(to: cabPath)
        onLog("Extracted payload CAB (\(formatSize(UInt64(payloadSize))))", .success)

        // Step 2: Use Wine's expand.exe to extract the CAB contents
        let wineUser = info.wineUsername
        let cabWinePath = "C:\\users\\\(wineUser)\\Downloads\\cab_extract\\payload.cab"
        let outWinePath = "C:\\users\\\(wineUser)\\Downloads\\cab_extract\\out"
        let outDir = cabDir.appendingPathComponent("out")
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)

        onLog("Extracting CAB with Wine expand.exe...", .info)
        try? await runWineAsync(
            binary: info.wineBinaryURL,
            prefix: info.prefixPath,
            arguments: ["expand", cabWinePath, "-F:*", outWinePath]
        )

        // Step 3: If expand produced MSI files, extract DLLs from them via msiexec /a
        if let extracted = try? fm.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil) {
            for file in extracted where file.pathExtension.lowercased() == "msi" {
                let msiWinePath = outWinePath + "\\" + file.lastPathComponent
                let msiOutPath = outWinePath + "\\msi_out"
                onLog("Extracting \(file.lastPathComponent) with msiexec...", .info)
                try? await runWineAsync(
                    binary: info.wineBinaryURL,
                    prefix: info.prefixPath,
                    arguments: ["msiexec", "/a", msiWinePath, "/qn", "TARGETDIR=\(msiOutPath)"]
                )
            }
        }

        // Step 4: Find and copy DLLs from extracted contents
        var copiedCount = 0
        let searchDirs = [cabDir]
        for dllName in vcDLLNames {
            for searchDir in searchDirs {
                if let found = findFile(named: dllName, in: searchDir) {
                    let srcSize = ((try? fm.attributesOfItem(atPath: found.path))?[.size] as? UInt64) ?? 0
                    // Only copy if it's a real DLL (not a Wine stub)
                    guard srcSize > minRealDLLSize else { continue }
                    let dest = destDir.appendingPathComponent(dllName)
                    try? fm.removeItem(at: dest)
                    try? fm.copyItem(at: found, to: dest)
                    onLog("Copied \(dllName) (\(formatSize(srcSize))) → \(destDir.lastPathComponent)", .success)
                    copiedCount += 1
                    break
                }
            }
        }

        if copiedCount > 0 {
            onLog("Extracted \(copiedCount) DLLs from redistributable", .success)
        } else {
            onLog("No DLLs extracted — Wine expand/msiexec may not support this format", .warning)
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
    /// Uses `wine reg add` which modifies wineserver's in-memory registry directly —
    /// this is critical because direct file writes to system.reg are NOT picked up
    /// by a running wineserver.
    private static func registerVCRuntime(
        info: WineInfo,
        onLog: @Sendable (String, LogEntry.Level) -> Void = { _, _ in }
    ) async throws {
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
                do {
                    try await runWineAsync(
                        binary: info.wineBinaryURL,
                        prefix: info.prefixPath,
                        arguments: [
                            "reg", "add", entry.key,
                            "/v", value.name, "/t", value.type, "/d", value.data, "/f",
                        ]
                    )
                    onLog("reg add \(entry.key.split(separator: "\\").last ?? "?").\(value.name) = \(value.data)", .success)
                } catch {
                    onLog("reg add \(entry.key.split(separator: "\\").last ?? "?").\(value.name) FAILED: \(error.localizedDescription)", .error)
                }
            }
        }

        // Register native DLL overrides so Wine loads real Microsoft DLLs
        onLog("Setting DLL overrides...", .info)
        let dllBasenames = vcDLLNames.map { $0.replacingOccurrences(of: ".dll", with: "") }
        for dll in dllBasenames {
            do {
                try await runWineAsync(
                    binary: info.wineBinaryURL,
                    prefix: info.prefixPath,
                    arguments: [
                        "reg", "add", "HKCU\\Software\\Wine\\DllOverrides",
                        "/v", dll, "/t", "REG_SZ", "/d", "native,builtin", "/f",
                    ]
                )
                onLog("DllOverride \(dll) = native,builtin", .success)
            } catch {
                onLog("DllOverride \(dll) FAILED: \(error.localizedDescription)", .error)
            }
        }

        onLog("Registry setup complete", .success)
    }
}
