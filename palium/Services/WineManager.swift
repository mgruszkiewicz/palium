import Foundation
import os

nonisolated enum WineManager {

    /// Palium's Wine 11 prefix. The old GPTK prefix (`prefix`) is only read by
    /// `PrefixMigration`, to move an existing game out of it.
    static var prefix: URL {
        WineEngine.supportDirectory.appendingPathComponent("prefix-w11")
    }

    // MARK: - Preparing the environment

    struct PreparedEnvironment: Sendable {
        let info: WineInfo
        let d3dMetal: D3DMetal.Source
        let migration: PrefixMigration.Outcome
    }

    /// Everything needed before the game can run: D3DMetal from GPTK, the Wine
    /// engine, the prefix, and moving an existing game over from the old prefix.
    static func prepare(
        onStatus: @escaping @Sendable (String) -> Void = { _ in },
        onLog: @escaping @Sendable (String, LogEntry.Level) -> Void = { _, _ in }
    ) async throws -> PreparedEnvironment {
        onStatus("Looking for Game Porting Toolkit...")
        guard let source = D3DMetal.findSource() else {
            throw PaliumError.wineNotFound
        }
        try D3DMetal.prepare(source: source)
        onLog("D3DMetal \(source.version ?? "(unknown version)") from \(source.lib.path)", .info)

        if !WineEngine.isInstalled() {
            onStatus("Downloading the Wine engine...")
        }
        try await WineEngine.ensureInstalled(onLog: onLog)

        if !isPrefixValid(prefix) {
            onStatus("Creating the Wine prefix...")
            onLog("Creating Wine prefix at \(prefix.path)...", .info)
            try await createPrefix(at: prefix)
            onLog("Wine prefix created", .success)
        }
        let username = try findWineUsername(in: prefix)

        onStatus("Checking for an existing game install...")
        let outcome = try PrefixMigration.run(
            newPrefix: prefix,
            newUser: username,
            isGameRunning: isPaliaRunning,
            stopLegacyWine: { stopLegacyWineserver(gptkLib: source.lib) },
            onLog: onLog
        )

        let info = WineInfo(
            wineBinaryURL: WineEngine.wineBinary,
            prefixPath: prefix,
            wineUsername: username
        )
        return PreparedEnvironment(info: info, d3dMetal: source, migration: outcome)
    }

    /// The existing setup, without downloading, creating or moving anything.
    static func currentInfo() -> WineInfo? {
        guard isPrefixValid(prefix), let user = try? findWineUsername(in: prefix) else { return nil }
        return WineInfo(wineBinaryURL: WineEngine.wineBinary, prefixPath: prefix, wineUsername: user)
    }

    // MARK: - Prefix Management

    private static func isPrefixValid(_ prefix: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: prefix.appendingPathComponent("drive_c").path)
            && fm.fileExists(atPath: prefix.appendingPathComponent("system.reg").path)
    }

    /// Create a prefix under a `.partial` name and rename it into place once it is
    /// complete, so a crash mid-way never leaves a half-made prefix in use.
    private static func createPrefix(at prefix: URL) async throws {
        let fm = FileManager.default
        let partial = prefix.deletingLastPathComponent()
            .appendingPathComponent(prefix.lastPathComponent + ".partial")
        try? fm.removeItem(at: partial)
        try fm.createDirectory(at: partial, withIntermediateDirectories: true)

        do {
            // No Mono/Gecko install prompts: Palia needs neither.
            try await runWineAsync(
                binary: WineEngine.wineBinary,
                prefix: partial,
                arguments: ["wineboot", "--init"],
                extraEnvironment: ["WINEDLLOVERRIDES": "mscoree,mshtml="]
            )
            // Cmd+C/V/X act as Ctrl+C/V/X in the game.
            for key in ["LeftCommandIsCtrl", "RightCommandIsCtrl"] {
                try await runWineAsync(
                    binary: WineEngine.wineBinary,
                    prefix: partial,
                    arguments: ["reg", "add", "HKCU\\Software\\Wine\\Mac Driver", "/v", key, "/t", "REG_SZ", "/d", "y", "/f"]
                )
            }
            try await runWineAsync(
                binary: WineEngine.wineserverBinary,
                prefix: partial,
                arguments: ["-w"]
            )
        } catch {
            try? fm.removeItem(at: partial)
            throw PaliumError.prefixInitFailed(error.localizedDescription)
        }

        try fm.moveItem(at: partial, to: prefix)
    }

    /// True while a Palia game process runs (under any Wine).
    static func isPaliaRunning() -> Bool {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", "PaliaClient-Win64-Shipping"]
        pgrep.standardOutput = FileHandle.nullDevice
        pgrep.standardError = FileHandle.nullDevice
        guard (try? pgrep.run()) != nil else { return false }
        pgrep.waitUntilExit()
        return pgrep.terminationStatus == 0
    }

    /// Stop the old GPTK prefix's wineserver, if one is running, before moving files.
    private static func stopLegacyWineserver(gptkLib: URL) {
        let wineserver = gptkLib.deletingLastPathComponent().appendingPathComponent("bin/wineserver")
        let legacy = PrefixMigration.legacyPrefix
        guard FileManager.default.isExecutableFile(atPath: wineserver.path),
              FileManager.default.fileExists(atPath: legacy.path) else { return }
        let process = Process()
        process.executableURL = wineserver
        process.arguments = ["-k"]
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = legacy.path
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
    }

    /// Remove the old GPTK prefix once its game has been moved out.
    static func removeLegacyPrefix() throws {
        let legacy = PrefixMigration.legacyPrefix
        guard PrefixMigration.findGame(inPrefix: legacy) == nil else {
            throw PaliumError.prefixInitFailed("the old prefix still contains a game install")
        }
        try FileManager.default.removeItem(at: legacy)
    }

    static var hasLegacyPrefix: Bool {
        FileManager.default.fileExists(atPath: PrefixMigration.legacyPrefix.path)
    }

    // MARK: - Username Detection

    /// The Wine user the game will actually run as.
    ///
    /// Wine stamps the running user's identity into `[Volatile Environment]` on every
    /// wineboot, and that is what `%LOCALAPPDATA%` resolves to inside the prefix — so
    /// it is authoritative in a way that listing `drive_c/users` is not. A prefix can
    /// accumulate several user directories (GPTK is CrossOver-derived and runs as
    /// `crossover`; other Wine builds use the macOS username), and `contentsOfDirectory`
    /// returns them unordered — so scanning could pick a different user between runs and
    /// silently split the game install from the save data the game writes.
    static func findWineUsername(in prefix: URL) throws -> String {
        if let username = registryUsername(in: prefix) {
            return username
        }
        return try scannedUsername(in: prefix)
    }

    /// Read `HKCU\Volatile Environment\USERNAME` out of the prefix's `user.reg`.
    private static func registryUsername(in prefix: URL) -> String? {
        let userReg = prefix.appendingPathComponent("user.reg")
        guard let contents = try? String(contentsOf: userReg, encoding: .utf8) else {
            return nil
        }

        let key = "\"USERNAME\"=\""
        var inVolatileEnvironment = false

        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            // Section headers look like `[Volatile Environment] 1782835665`.
            if line.hasPrefix("[") {
                inVolatileEnvironment = line.hasPrefix("[Volatile Environment]")
                continue
            }

            guard inVolatileEnvironment, line.hasPrefix(key), line.hasSuffix("\"") else {
                continue
            }

            let username = line.dropFirst(key.count).dropLast()
                .replacingOccurrences(of: "\\\\", with: "\\")
                .replacingOccurrences(of: "\\\"", with: "\"")
            return username.isEmpty ? nil : username
        }

        return nil
    }

    /// Fallback for prefixes with no usable `user.reg`: scan `drive_c/users`, preferring a
    /// user that already holds a game install, then sorting so the result is at least stable.
    private static func scannedUsername(in prefix: URL) throws -> String {
        let fm = FileManager.default
        let usersDir = prefix.appendingPathComponent("drive_c/users")

        guard fm.fileExists(atPath: usersDir.path) else {
            throw PaliumError.noBottleFound
        }

        let candidates = try fm.contentsOfDirectory(atPath: usersDir.path)
            .filter { $0 != "Public" && !$0.hasPrefix(".") && !$0.contains("Default") }
            .filter { name in
                var isDir: ObjCBool = false
                let exists = fm.fileExists(
                    atPath: usersDir.appendingPathComponent(name).path,
                    isDirectory: &isDir
                )
                return exists && isDir.boolValue
            }
            .sorted()

        let withInstall = candidates.first { name in
            let exe = usersDir
                .appendingPathComponent("\(name)/AppData/Local/Palia/Client/PaliaClient.exe")
            return fm.fileExists(atPath: exe.path)
        }

        guard let username = withInstall ?? candidates.first else {
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

    /// Environment shared by every Wine process Palium starts (wineboot, reg,
    /// installers, `--version` and the game).
    ///
    /// The sync settings must be identical for all of them: the first Wine process
    /// starts wineserver, and a client whose sync setting differs from the running
    /// server's refuses to start ("Server is running with WINEMSYNC but this process
    /// is not").
    static func baseWineEnvironment(prefix: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = prefix.path
        env["WINEBOOT_HIDE_DIALOG"] = "1"
        env["WINEDEBUG"] = "-all"
        env["WINEMSYNC"] = "1"
        // D3DMetal looks for esync; with both set, Wine uses msync.
        env["WINEESYNC"] = "1"
        // The engine expects this outside Sikarugir's own launcher.
        env["SikarugirAppWine11"] = "1"

        // D3DMetal from the user's GPTK, through Palium's link folder: its modules
        // go before Wine's own d3d11/d3d12/dxgi, and its dylibs (plus GPTK's
        // freetype, gnutls, …) are found by the dynamic loader.
        env["WINEDLLPATH_D3DMETAL"] = D3DMetal.managedModules.path
        env["WINEDLLPATH_PREPEND"] = D3DMetal.managedModules.path
        env["CX_APPLEGPTK_LIBD3DSHARED_PATH"] = D3DMetal.libd3dshared.path
        env["DYLD_FALLBACK_LIBRARY_PATH"] = [
            D3DMetal.managedExternal.path, D3DMetal.managedGPTKLib.path, "/usr/lib",
        ].joined(separator: ":")
        return env
    }

    /// Direct3D DLLs come from Wine's built-in modules, where D3DMetal's are first.
    /// `n,b` here would let a stray d3d11.dll/dxgi.dll (left in the game folder or
    /// system32 by a DXVK/DXMT experiment) silently replace D3DMetal.
    /// d3d12core is left out on purpose: UE5 ships its own D3D12 Agility SDK
    /// (Binaries/Win64/D3D12/D3D12Core.dll), which must not be redirected.
    private static let graphicsDLLOverrides = "dxgi,d3d9,d3d10core,d3d11,d3d12=b"

    static func makeWineEnvironment(info: WineInfo, metalHUD: Bool = false) -> [String: String] {
        var env = baseWineEnvironment(prefix: info.prefixPath)
        let vcOverrides = vcDLLNames
            .map { $0.replacingOccurrences(of: ".dll", with: "") }
            .joined(separator: ",")
        env["WINEDLLOVERRIDES"] = "\(graphicsDLLOverrides);\(vcOverrides)=n,b"

        if metalHUD {
            env["MTL_HUD_ENABLED"] = "1"
        }

        return env
    }

    private static func runWineAsync(
        binary: URL,
        prefix: URL,
        arguments: [String],
        extraEnvironment: [String: String] = [:],
        timeout: TimeInterval = 120
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = binary
            process.arguments = arguments
            process.environment = baseWineEnvironment(prefix: prefix)
                .merging(extraEnvironment) { _, new in new }
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            let didResume = OSAllocatedUnfairLock(initialState: false)

            // Weak capture: don't keep the (finished) process alive until the
            // timeout deadline; cancelled in the termination handler.
            let timeoutWork = DispatchWorkItem { [weak process] in
                let shouldResume = didResume.withLock { flag -> Bool in
                    if flag { return false }
                    flag = true
                    return true
                }
                guard shouldResume else { return }
                if let process, process.isRunning { process.terminate() }
                continuation.resume(throwing: PaliumError.launchFailed(
                    "Wine process timed out after \(Int(timeout))s"
                ))
            }

            process.terminationHandler = { proc in
                timeoutWork.cancel()
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

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)

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

    struct DiagnosticResult: Sendable, Identifiable {
        var id: String { name }
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

    /// The VC++ DLLs Palia's binaries import (`ucrtbase` through the api-ms-win-crt
    /// forwarders). Others in `vcDLLNames`, like mfc140u or vcruntime140_threads, are
    /// overridden if present but nothing in the game loads them.
    static let gameVCDLLNames = [
        "msvcp140.dll", "msvcp140_1.dll", "vcruntime140.dll", "vcruntime140_1.dll", "ucrtbase.dll",
    ]

    /// Run all troubleshooting diagnostics and return results.
    static func runDiagnostics(info: WineInfo) async -> [DiagnosticResult] {
        var results: [DiagnosticResult] = []
        let fm = FileManager.default

        let engineInstalled = WineEngine.isInstalled()
        results.append(DiagnosticResult(
            name: "Wine Engine",
            passed: engineInstalled,
            detail: engineInstalled
                ? "\(WineEngine.current.displayName), checksum verified"
                : "Not installed — restart Palium to download it"
        ))

        let source = D3DMetal.findSource()
        results.append(DiagnosticResult(
            name: "D3DMetal (Game Porting Toolkit)",
            passed: source != nil,
            detail: source.map { "\($0.version ?? "unknown version") — \($0.lib.path)" }
                ?? "Game Porting Toolkit not found in /Applications"
        ))
        let linksOK = D3DMetal.isPrepared()
        results.append(DiagnosticResult(
            name: "D3DMetal Links",
            passed: linksOK,
            detail: linksOK ? D3DMetal.managedDirectory.path : "Missing or broken — restart Palium"
        ))

        let winePath = info.wineBinaryURL.path
        let wineExists = fm.isExecutableFile(atPath: winePath)

        if wineExists {
            let versionOutput = await getWineVersion(binary: info.wineBinaryURL, prefix: info.prefixPath)
            results.append(DiagnosticResult(
                name: "Wine Runs",
                passed: versionOutput != nil,
                detail: versionOutput ?? "wine --version failed to execute"
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
        for dll in gameVCDLLNames {
            let dllURL = sys32.appendingPathComponent(dll)
            if let attrs = try? fm.attributesOfItem(atPath: dllURL.path),
               let size = attrs[.size] as? UInt64 {
                let isReal = size > minRealDLLSize
                // Wine's own implementation works for the game too; say which one it is.
                let origin = isWineBuiltinDLL(dllURL) ? "Wine's own copy" : "Microsoft"
                results.append(DiagnosticResult(
                    name: dll,
                    passed: isReal,
                    detail: isReal ? "\(origin), \(formatSize(size))" : "\(formatSize(size)) (Wine stub)"
                ))
            } else {
                results.append(DiagnosticResult(name: dll, passed: false, detail: "Missing"))
            }
        }

        // DLL overrides are passed with WINEDLLOVERRIDES at launch, not read from
        // user.reg, so there is nothing in the prefix to check for them.

        let gameInstalled = isGameInstalled(info: info)
        results.append(DiagnosticResult(
            name: "PaliaClient.exe",
            passed: gameInstalled,
            detail: gameInstalled ? info.gameInstallPath.appendingPathComponent("PaliaClient.exe").path : "Not found"
        ))

        return results
    }

    /// Wine's own DLLs carry this text in their DOS header area.
    static func isWineBuiltinDLL(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let header = (try? handle.read(upToCount: 1024)) ?? Data()
        return header.range(of: Data("Wine builtin DLL".utf8)) != nil
    }

    /// Run `wine --version` and capture output.
    private static func getWineVersion(binary: URL, prefix: URL) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = binary
            process.arguments = ["--version"]
            process.environment = baseWineEnvironment(prefix: prefix)

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
        for (_, filename) in redistributables {
            let winePath = "\(info.wineDownloadsWindowsPath)\\\(filename)"
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
        let cabWinePath = "\(info.wineDownloadsWindowsPath)\\cab_extract\\payload.cab"
        let outWinePath = "\(info.wineDownloadsWindowsPath)\\cab_extract\\out"
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
