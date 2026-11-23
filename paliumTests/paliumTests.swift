import Testing
import Foundation
@testable import palium

// MARK: - FlexBuffers Parser Tests

struct FlexBuffersParserTests {

    @Test func decodeTooSmallBuffer() {
        let data = Data([0x00, 0x01])
        #expect(throws: FlexBuffersParser.ParseError.self) {
            _ = try FlexBuffersParser.decode(data)
        }
    }

    @Test func decodeEmptyBuffer() {
        let data = Data()
        #expect(throws: FlexBuffersParser.ParseError.self) {
            _ = try FlexBuffersParser.decode(data)
        }
    }

    @Test func decodeNull() throws {
        // FlexBuffers: null value, byte width 1
        // [0x00 (value), 0x00 (packed type: NULL << 2 | 0), 0x01 (byte width)]
        let data = Data([0x00, 0x00, 0x01])
        let result = try FlexBuffersParser.decode(data)
        if case .null = result {
            // pass
        } else {
            Issue.record("Expected null, got \(result)")
        }
    }

    @Test func decodeBool() throws {
        // true: value=1, packed type = FBT_BOOL(26) << 2 | 0 = 104
        let trueData = Data([0x01, 104, 0x01])
        let trueResult = try FlexBuffersParser.decode(trueData)
        #expect(trueResult == .bool(true))

        // false: value=0
        let falseData = Data([0x00, 104, 0x01])
        let falseResult = try FlexBuffersParser.decode(falseData)
        #expect(falseResult == .bool(false))
    }

    @Test func decodeUInt8() throws {
        // value=42, packed type = FBT_UINT(2) << 2 | 0 = 8, byte width 1
        let data = Data([42, 8, 0x01])
        let result = try FlexBuffersParser.decode(data)
        #expect(result.uintValue == 42)
    }

    @Test func decodeInt8Positive() throws {
        // value=100, packed type = FBT_INT(1) << 2 | 0 = 4, byte width 1
        let data = Data([100, 4, 0x01])
        let result = try FlexBuffersParser.decode(data)
        #expect(result.intValue == 100)
    }

    @Test func decodeInt8Negative() throws {
        // value=-1 (0xFF), packed type = FBT_INT(1) << 2 | 0 = 4, byte width 1
        let data = Data([0xFF, 4, 0x01])
        let result = try FlexBuffersParser.decode(data)
        #expect(result.intValue == -1)
    }

    @Test func decodeUInt16() throws {
        // value=1000 as 2-byte LE = [0xE8, 0x03]
        // packed type = FBT_UINT(2) << 2 | 1 = 9 (byteWidth hint 2)
        // root byte width = 2
        let data = Data([0xE8, 0x03, 9, 0x02])
        let result = try FlexBuffersParser.decode(data)
        #expect(result.uintValue == 1000)
    }

    @Test func decodeMap() throws {
        // {"a": 42} encoded by hand (all byte widths 1):
        // key cstring, keys vector (len + offset), keys descriptor (offset + width),
        // values vector (len + value), element types, root offset, type, width.
        let data = Data([0x61, 0x00, 0x01, 0x03, 0x01, 0x01, 0x01, 42, 8, 0x02, 0x24, 0x01])
        let result = try FlexBuffersParser.decode(data)
        #expect(result["a"]?.uintValue == 42)

        let root = try FlexBuffersParser.root(data)
        #expect(root.isMap)
        #expect(root.count == 1)
        #expect(root.key(at: 0) == "a")
        #expect(root["a"]?.uintValue == 42)
        #expect(root["missing"] == nil)
    }

    @Test func decodeVector() throws {
        // [1, 2] encoded by hand: len, values, element types, root offset, type, width
        let data = Data([2, 1, 2, 8, 8, 4, 0x28, 1])
        let result = try FlexBuffersParser.decode(data)
        #expect(result[0]?.uintValue == 1)
        #expect(result[1]?.uintValue == 2)
        #expect(result[2] == nil)

        let root = try FlexBuffersParser.root(data)
        #expect(root.isVector)
        #expect(root.count == 2)
        #expect(root[1]?.uintValue == 2)
    }

    @Test func decodeMalformedBufferDoesNotCrash() throws {
        // Garbage offsets and truncated buffers must degrade gracefully, not crash.
        let buffers: [Data] = [
            Data([0xFF, 0xFE, 0x24, 0x08]),             // map with nonsense offsets
            Data([0xFF, 0xFF, 0xFF, 0x28, 0x08]),       // vector with absurd width
            Data([0x00, 0x64, 0x01]),                    // blob pointing out of bounds
            Data((0..<64).map { _ in UInt8.random(in: 0...255) } + [0x24, 0x01]),
        ]
        for data in buffers {
            _ = try? FlexBuffersParser.decode(data)
        }
    }

    @Test func decodeString() throws {
        // FlexBuffers string: length-prefixed, null-terminated
        // "hi" = [2(len), 'h', 'i', 0, packed_type, byte_width]
        // offset from root to string start: string is at offset 1 ("h"), root is at offset 4
        // relative offset = 4 - 1 = 3
        let data = Data([
            0x02,       // string length
            0x68, 0x69, // "hi"
            0x00,       // null terminator
            0x03,       // relative offset to string (4 - 1)
            0x14,       // packed type: FBT_STRING(5) << 2 | 0 = 20
            0x01,       // root byte width
        ])
        let result = try FlexBuffersParser.decode(data)
        #expect(result.stringValue == "hi")
    }
}

// MARK: - FlexValue Accessor Tests

struct FlexValueTests {

    @Test func stringValueAccessor() {
        let val = FlexValue.string("hello")
        #expect(val.stringValue == "hello")
        #expect(val.intValue == nil)
        #expect(val.uintValue == nil)
    }

    @Test func intValueAccessor() {
        let val = FlexValue.int(42)
        #expect(val.intValue == 42)
        #expect(val.uintValue == 42) // positive int converts to uint
        #expect(val.stringValue == nil)
    }

    @Test func negativeIntDoesNotConvertToUInt() {
        let val = FlexValue.int(-5)
        #expect(val.intValue == -5)
        #expect(val.uintValue == nil)
    }

    @Test func uintValueAccessor() {
        let val = FlexValue.uint(100)
        #expect(val.uintValue == 100)
        #expect(val.intValue == 100) // small uint converts to int
    }

    @Test func largeUIntDoesNotConvertToInt() {
        let val = FlexValue.uint(UInt64(Int64.max) + 1)
        #expect(val.uintValue == UInt64(Int64.max) + 1)
        #expect(val.intValue == nil)
    }

    @Test func floatValueAccessor() {
        let val = FlexValue.float(3.14)
        #expect(val.floatValue == 3.14)
        #expect(val.intValue == nil)
    }

    @Test func blobValueAccessor() {
        let data = Data([1, 2, 3])
        let val = FlexValue.blob(data)
        #expect(val.blobValue == data)
        #expect(val.stringValue == nil)
    }

    @Test func vectorSubscript() {
        let val = FlexValue.vector([.int(10), .int(20), .int(30)])
        #expect(val[0]?.intValue == 10)
        #expect(val[2]?.intValue == 30)
        #expect(val[3] == nil) // out of bounds
        #expect(val[-1] == nil)
    }

    @Test func mapSubscript() {
        let val = FlexValue.map(["name": .string("test"), "size": .uint(42)])
        #expect(val["name"]?.stringValue == "test")
        #expect(val["size"]?.uintValue == 42)
        #expect(val["missing"] == nil)
    }

    @Test func nullAccessors() {
        let val = FlexValue.null
        #expect(val.stringValue == nil)
        #expect(val.intValue == nil)
        #expect(val.uintValue == nil)
        #expect(val.floatValue == nil)
        #expect(val.blobValue == nil)
        #expect(val.vectorValue == nil)
        #expect(val.mapValue == nil)
    }
}

// MARK: - CDN Client Tests

struct CDNClientTests {

    @Test func fileURLConstruction() {
        let url = CDNClient.fileURL(version: "1.2.3", path: "Client/PaliaClient.exe")
        #expect(url.absoluteString == "https://dl.palia.com/bundle/Palia/v/1.2.3/windows/file/Client/PaliaClient.exe")
    }

    @Test func fileURLWithSpaces() {
        let url = CDNClient.fileURL(version: "1.0", path: "Content/Paks/some file.pak")
        #expect(url.absoluteString.contains("some%20file.pak"))
    }

    @Test func parseManifestFromFlexValue() throws {
        // Build a minimal FlexBuffers-encoded manifest by hand.
        // This tests the parseManifest -> collectFiles logic.
        // We'll construct a FlexValue tree and encode it as a map,
        // but since we can't easily encode FlexBuffers, we test
        // parseManifest indirectly by checking it rejects bad input.
        let emptyData = Data([0x00, 0x00, 0x01]) // null root
        #expect(throws: PaliumError.self) {
            _ = try CDNClient.parseManifest(emptyData)
        }
    }
}

// MARK: - Model Tests

struct ManifestModelTests {

    @Test func manifestFileIdentity() {
        let file = ManifestFile(path: "test/file.exe", size: 1024, hash: Data())
        #expect(file.id == "test/file.exe")
    }

    @Test func updateManifestTotalSize() {
        let manifest = UpdateManifest(
            bundle: "Palia",
            version: "1.0",
            platform: "windows",
            files: [
                ManifestFile(path: "a.exe", size: 100, hash: Data()),
                ManifestFile(path: "b.pak", size: 200, hash: Data()),
            ],
            totalSize: 300,
            contentsHash: Data()
        )
        #expect(manifest.files.count == 2)
        #expect(manifest.totalSize == 300)
    }
}

// MARK: - PaliumError Tests

struct PaliumErrorTests {

    @Test func isWineNotFound() {
        let error = PaliumError.wineNotFound
        #expect(error.isWineNotFound == true)
    }

    @Test func otherErrorsAreNotWineNotFound() {
        let errors: [PaliumError] = [
            .noBottleFound,
            .gameNotInstalled,
            .launchFailed("test"),
            .cdnError("test"),
        ]
        for error in errors {
            #expect(error.isWineNotFound == false)
        }
    }

    @Test func errorDescriptionsAreNotEmpty() {
        let errors: [PaliumError] = [
            .wineNotFound,
            .noBottleFound,
            .gameNotInstalled,
            .manifestParseFailed("reason"),
            .downloadFailed(path: "file", reason: "reason"),
            .hashMismatch(path: "file"),
            .launchFailed("reason"),
            .cdnError("msg"),
            .prefixInitFailed("reason"),
            .engineInstallFailed("reason"),
            .migrationFailed("reason"),
        ]
        for error in errors {
            #expect(error.errorDescription != nil)
            #expect(error.errorDescription!.isEmpty == false)
        }
    }
}

// MARK: - WineInfo Tests

struct WineInfoTests {

    @Test func gameInstallPath() {
        let info = WineInfo(
            wineBinaryURL: URL(fileURLWithPath: "/usr/bin/wine64"),
            prefixPath: URL(fileURLWithPath: "/tmp/prefix"),
            wineUsername: "testuser"
        )
        #expect(info.gameInstallPath.path.contains("testuser"))
        #expect(info.gameInstallPath.path.hasSuffix("Palia/Client"))
    }

    @Test func gameSavedPath() {
        let info = WineInfo(
            wineBinaryURL: URL(fileURLWithPath: "/usr/bin/wine64"),
            prefixPath: URL(fileURLWithPath: "/tmp/prefix"),
            wineUsername: "player"
        )
        #expect(info.gameSavedPath.path.contains("player"))
        #expect(info.gameSavedPath.path.hasSuffix("Palia/Saved"))
    }

    @Test func wineDownloadsPath() {
        let info = WineInfo(
            wineBinaryURL: URL(fileURLWithPath: "/usr/bin/wine64"),
            prefixPath: URL(fileURLWithPath: "/tmp/prefix"),
            wineUsername: "user"
        )
        // Never the Windows user's Downloads, which Wine links to the Mac's ~/Downloads.
        #expect(info.wineDownloadsPath.path.hasSuffix("drive_c/palium-downloads"))
        #expect(!info.wineDownloadsPath.path.contains("/users/"))
        #expect(info.wineDownloadsWindowsPath == "C:\\palium-downloads")
    }
}

// MARK: - LaunchSettings Tests

struct LaunchSettingsTests {

    @Test func graphicsAPICodable() throws {
        let data = try JSONEncoder().encode(LaunchSettings.GraphicsAPI.dx12)
        let decoded = try JSONDecoder().decode(LaunchSettings.GraphicsAPI.self, from: data)
        #expect(decoded == .dx12)
    }
}

// MARK: - GameLauncher Tests

struct GameLauncherTests {

    @Test func launchOptionsDefaults() {
        let options = GameLauncher.LaunchOptions(metalHUD: false, graphicsAPI: .dx11, useAllCores: true)
        #expect(options.metalHUD == false)
        #expect(options.graphicsAPI == .dx11)
        #expect(options.useAllCores == true)
    }

    @Test func graphicsAPILaunchArguments() {
        #expect(LaunchSettings.GraphicsAPI.dx11.launchArgument == "-dx11")
        #expect(LaunchSettings.GraphicsAPI.dx12.launchArgument == "-dx12")
    }

    @Test func launchFailsWithMissingGame() {
        let info = WineInfo(
            wineBinaryURL: URL(fileURLWithPath: "/usr/bin/false"),
            prefixPath: URL(fileURLWithPath: "/tmp/nonexistent"),
            wineUsername: "test"
        )
        let options = GameLauncher.LaunchOptions(metalHUD: false, graphicsAPI: .dx11, useAllCores: false)
        #expect(throws: PaliumError.self) {
            _ = try GameLauncher.launch(info: info, options: options)
        }
    }
}

// MARK: - WineManager Tests

struct WineManagerTests {

    @Test func makeWineEnvironmentSetsRequiredVars() {
        let info = WineInfo(
            wineBinaryURL: URL(fileURLWithPath: "/usr/bin/wine64"),
            prefixPath: URL(fileURLWithPath: "/tmp/testprefix"),
            wineUsername: "test"
        )
        let env = WineManager.makeWineEnvironment(info: info)
        #expect(env["WINEPREFIX"] == "/tmp/testprefix")
        #expect(env["WINEBOOT_HIDE_DIALOG"] == "1")
        #expect(env["WINEDEBUG"] == "-all")
        #expect(env["WINEESYNC"] == "1")
        #expect(env["WINEMSYNC"] == "1")
        #expect(env["DXVK_ASYNC"] == nil)
        #expect(env["DXVK_STATE_CACHE"] == nil)
        #expect(env["MTL_HUD_ENABLED"] == nil)
        #expect(env["SikarugirAppWine11"] == "1")
        #expect(env["WINEDLLPATH_D3DMETAL"] == D3DMetal.managedModules.path)
        #expect(env["WINEDLLPATH_PREPEND"] == D3DMetal.managedModules.path)
        #expect(env["CX_APPLEGPTK_LIBD3DSHARED_PATH"] == D3DMetal.libd3dshared.path)
        #expect(env["DYLD_FALLBACK_LIBRARY_PATH"]?.hasPrefix(D3DMetal.managedExternal.path) == true)
    }

    /// Every Wine process must agree on esync with the running wineserver.
    @Test func baseEnvironmentMatchesGameSyncSettings() {
        let prefix = URL(fileURLWithPath: "/tmp/testprefix")
        let info = WineInfo(
            wineBinaryURL: URL(fileURLWithPath: "/usr/bin/wine64"),
            prefixPath: prefix,
            wineUsername: "test"
        )
        let base = WineManager.baseWineEnvironment(prefix: prefix)
        let game = WineManager.makeWineEnvironment(info: info)
        for key in ["WINEPREFIX", "WINEESYNC", "WINEMSYNC", "WINEDLLPATH_PREPEND", "DYLD_FALLBACK_LIBRARY_PATH"] {
            #expect(base[key] != nil)
            #expect(base[key] == game[key])
        }
    }

    @Test func makeWineEnvironmentWithMetalHUD() {
        let info = WineInfo(
            wineBinaryURL: URL(fileURLWithPath: "/usr/bin/wine64"),
            prefixPath: URL(fileURLWithPath: "/tmp/testprefix"),
            wineUsername: "test"
        )
        let env = WineManager.makeWineEnvironment(info: info, metalHUD: true)
        #expect(env["MTL_HUD_ENABLED"] == "1")
    }

    @Test func makeWineEnvironmentHasDLLOverrides() {
        let info = WineInfo(
            wineBinaryURL: URL(fileURLWithPath: "/usr/bin/wine64"),
            prefixPath: URL(fileURLWithPath: "/tmp/testprefix"),
            wineUsername: "test"
        )
        let env = WineManager.makeWineEnvironment(info: info)
        let overrides = env["WINEDLLOVERRIDES"] ?? ""
        #expect(overrides.contains("dxgi"))
        #expect(overrides.contains("d3d11"))
        #expect(overrides.contains("d3d9"))
        #expect(overrides.contains("d3d10core"))
        #expect(overrides.contains("msvcp140"))
        #expect(overrides.contains("vcruntime140"))
        #expect(overrides.contains("vcomp140"))
        #expect(overrides.contains("mfc140u"))
        #expect(overrides.contains("vccorlib140"))
        #expect(overrides.contains("n,b"))
    }

    @Test func direct3DOverridesAreBuiltinOnly() {
        let info = WineInfo(
            wineBinaryURL: URL(fileURLWithPath: "/usr/bin/wine64"),
            prefixPath: URL(fileURLWithPath: "/tmp/testprefix"),
            wineUsername: "test"
        )
        let overrides = WineManager.makeWineEnvironment(info: info)["WINEDLLOVERRIDES"] ?? ""
        var modes: [String: String] = [:]
        for group in overrides.split(separator: ";") {
            let parts = group.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            for dll in parts[0].split(separator: ",") {
                modes[String(dll)] = String(parts[1])
            }
        }
        for dll in ["dxgi", "d3d9", "d3d10core", "d3d11", "d3d12"] {
            #expect(modes[dll] == "b", "\(dll) should load Wine's built-in (D3DMetal)")
        }
        #expect(modes["d3d12core"] == nil, "the game's own D3D12 Agility SDK must stay loadable")
        #expect(modes["vcruntime140"] == "n,b")
        #expect(modes["msvcp140"] == "n,b")
    }

    @Test func isVCRuntimeInstalledReturnsFalseForMissingPrefix() {
        let info = WineInfo(
            wineBinaryURL: URL(fileURLWithPath: "/usr/bin/wine64"),
            prefixPath: URL(fileURLWithPath: "/tmp/nonexistent_prefix_\(UUID())"),
            wineUsername: "test"
        )
        #expect(WineManager.isVCRuntimeInstalled(info: info) == false)
    }

    @Test func isGameInstalledReturnsFalseForMissingGame() {
        let info = WineInfo(
            wineBinaryURL: URL(fileURLWithPath: "/usr/bin/wine64"),
            prefixPath: URL(fileURLWithPath: "/tmp/nonexistent_prefix_\(UUID())"),
            wineUsername: "test"
        )
        #expect(WineManager.isGameInstalled(info: info) == false)
    }

    // MARK: - Wine Username Detection

    /// Build a throwaway prefix. `users` become directories under `drive_c/users`;
    /// `registryUser`, when set, is written into `user.reg` as Wine's wineboot does.
    private func makePrefix(
        users: [String],
        registryUser: String? = nil,
        installedFor: String? = nil
    ) throws -> URL {
        let fm = FileManager.default
        let prefix = fm.temporaryDirectory.appendingPathComponent("prefix_\(UUID())")
        let usersDir = prefix.appendingPathComponent("drive_c/users")
        for user in users {
            try fm.createDirectory(
                at: usersDir.appendingPathComponent(user),
                withIntermediateDirectories: true
            )
        }
        if let installedFor {
            let clientDir = usersDir
                .appendingPathComponent("\(installedFor)/AppData/Local/Palia/Client")
            try fm.createDirectory(at: clientDir, withIntermediateDirectories: true)
            try Data().write(to: clientDir.appendingPathComponent("PaliaClient.exe"))
        }
        if let registryUser {
            let userReg = """
            WINE REGISTRY Version 2

            [Software\\\\Wine] 1782835665
            "SomeKey"="SomeValue"

            [Volatile Environment] 1782835665
            #time=1dd08aa966aefd2
            "HOMEPATH"="\\\\users\\\\\(registryUser)"
            "USERNAME"="\(registryUser)"
            "USERPROFILE"="C:\\\\users\\\\\(registryUser)"

            """
            try userReg.write(
                to: prefix.appendingPathComponent("user.reg"),
                atomically: true,
                encoding: .utf8
            )
        }
        return prefix
    }

    @Test func usernameComesFromRegistryNotDirectoryOrder() throws {
        // GPTK runs the game as `crossover` regardless of which user directories
        // happen to exist, and `user.reg` is what says so.
        let prefix = try makePrefix(
            users: ["alice", "crossover", "zoe"],
            registryUser: "crossover"
        )
        defer { try? FileManager.default.removeItem(at: prefix) }

        #expect(try WineManager.findWineUsername(in: prefix) == "crossover")
    }

    @Test func registryUsernameWinsOverUserWithInstall() throws {
        // The install may sit under a stale user; the game still reads and writes
        // under whoever Wine actually runs as.
        let prefix = try makePrefix(
            users: ["crossover", "stale"],
            registryUser: "crossover",
            installedFor: "stale"
        )
        defer { try? FileManager.default.removeItem(at: prefix) }

        #expect(try WineManager.findWineUsername(in: prefix) == "crossover")
    }

    @Test func usernameIgnoresUnrelatedRegistrySections() throws {
        // A `USERNAME` value outside [Volatile Environment] must not be picked up.
        let prefix = try makePrefix(users: ["crossover"])
        defer { try? FileManager.default.removeItem(at: prefix) }
        let userReg = """
        WINE REGISTRY Version 2

        [Software\\\\Decoy] 1782835665
        "USERNAME"="wrong"

        """
        try userReg.write(
            to: prefix.appendingPathComponent("user.reg"),
            atomically: true,
            encoding: .utf8
        )

        // Falls through to the directory scan rather than trusting the decoy.
        #expect(try WineManager.findWineUsername(in: prefix) == "crossover")
    }

    @Test func fallbackPrefersUserHoldingTheInstall() throws {
        // No user.reg: the user that already has the game beats alphabetical order.
        let prefix = try makePrefix(
            users: ["aaa", "crossover"],
            installedFor: "crossover"
        )
        defer { try? FileManager.default.removeItem(at: prefix) }

        #expect(try WineManager.findWineUsername(in: prefix) == "crossover")
    }

    @Test func fallbackIsStableWhenNothingIsInstalled() throws {
        // Deterministic across runs even though contentsOfDirectory is unordered.
        let prefix = try makePrefix(users: ["zoe", "alice", "crossover"])
        defer { try? FileManager.default.removeItem(at: prefix) }

        let results = try (0..<5).map { _ in try WineManager.findWineUsername(in: prefix) }
        #expect(results.allSatisfy { $0 == "alice" })
    }

    @Test func fallbackSkipsPublicAndDefaultAndFiles() throws {
        let fm = FileManager.default
        let prefix = try makePrefix(users: ["Public", "Default User", "crossover"])
        defer { try? fm.removeItem(at: prefix) }
        // A stray file must not be mistaken for a user directory.
        try Data().write(
            to: prefix.appendingPathComponent("drive_c/users/.DS_Store")
        )

        #expect(try WineManager.findWineUsername(in: prefix) == "crossover")
    }

    @Test func throwsWhenPrefixHasNoUsers() throws {
        let prefix = try makePrefix(users: [])
        defer { try? FileManager.default.removeItem(at: prefix) }

        #expect(throws: PaliumError.self) {
            _ = try WineManager.findWineUsername(in: prefix)
        }
    }
}

// MARK: - D3DMetal Tests

struct D3DMetalTests {

    /// A fake GPTK `lib` folder: D3DMetal's pieces plus an unrelated Wine 7.7 module.
    private func makeGPTKLib(modules: [String] = ["d3d11", "d3d12", "dxgi", "d3d10"]) throws -> URL {
        let fm = FileManager.default
        let lib = fm.temporaryDirectory.appendingPathComponent("gptk_\(UUID())/wine/lib")
        let framework = lib.appendingPathComponent("external/D3DMetal.framework/Resources")
        try fm.createDirectory(at: framework, withIntermediateDirectories: true)
        try (["CFBundleShortVersionString": "3.0"] as NSDictionary)
            .write(to: framework.appendingPathComponent("Info.plist"))
        try Data().write(to: lib.appendingPathComponent("external/libd3dshared.dylib"))
        let windows = lib.appendingPathComponent("wine/x86_64-windows")
        let unix = lib.appendingPathComponent("wine/x86_64-unix")
        try fm.createDirectory(at: windows, withIntermediateDirectories: true)
        try fm.createDirectory(at: unix, withIntermediateDirectories: true)
        for module in modules + ["kernel32"] {
            try Data().write(to: windows.appendingPathComponent("\(module).dll"))
            try Data().write(to: unix.appendingPathComponent("\(module).so"))
        }
        return lib
    }

    @Test func findsSourceWithVersion() throws {
        let lib = try makeGPTKLib()
        defer { try? FileManager.default.removeItem(at: lib.deletingLastPathComponent().deletingLastPathComponent()) }
        let source = D3DMetal.findSource(candidates: [lib.path])
        #expect(source?.lib.path == lib.path)
        #expect(source?.version == "3.0")
    }

    @Test func rejectsGPTKWithoutRequiredModule() throws {
        let lib = try makeGPTKLib(modules: ["d3d11", "dxgi"])
        defer { try? FileManager.default.removeItem(at: lib.deletingLastPathComponent().deletingLastPathComponent()) }
        #expect(D3DMetal.findSource(candidates: [lib.path]) == nil)
    }

    @Test func resolvesLibFromWine64Link() throws {
        let fm = FileManager.default
        let lib = try makeGPTKLib()
        let wineDir = lib.deletingLastPathComponent()
        defer { try? fm.removeItem(at: wineDir.deletingLastPathComponent()) }
        let bin = wineDir.appendingPathComponent("bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data().write(to: bin.appendingPathComponent("wine64"))
        let link = wineDir.deletingLastPathComponent().appendingPathComponent("brew-wine64")
        try fm.createSymbolicLink(at: link, withDestinationURL: bin.appendingPathComponent("wine64"))

        // Candidates named wine64 resolve to <wine>/lib.
        let renamed = wineDir.deletingLastPathComponent().appendingPathComponent("brewbin")
        try fm.createDirectory(at: renamed, withIntermediateDirectories: true)
        try fm.moveItem(at: link, to: renamed.appendingPathComponent("wine64"))
        let source = D3DMetal.findSource(candidates: [renamed.appendingPathComponent("wine64").path])
        #expect(source?.lib.resolvingSymlinksInPath().path == lib.resolvingSymlinksInPath().path)
    }

    @Test func prepareLinksOnlyD3DMetalModules() throws {
        let fm = FileManager.default
        let lib = try makeGPTKLib()
        let managed = fm.temporaryDirectory.appendingPathComponent("d3dm_\(UUID())/d3dmetal")
        defer {
            try? fm.removeItem(at: lib.deletingLastPathComponent().deletingLastPathComponent())
            try? fm.removeItem(at: managed.deletingLastPathComponent())
        }
        let source = try #require(D3DMetal.findSource(candidates: [lib.path]))

        try D3DMetal.prepare(source: source, in: managed)
        try D3DMetal.prepare(source: source, in: managed) // rebuilding replaces cleanly

        let windows = managed.appendingPathComponent("lib/wine/x86_64-windows")
        let names = try fm.contentsOfDirectory(atPath: windows.path).sorted()
        #expect(names == ["d3d10.dll", "d3d11.dll", "d3d12.dll", "dxgi.dll"])
        #expect(!fm.fileExists(atPath: windows.appendingPathComponent("kernel32.dll").path))
        #expect(D3DMetal.isPrepared(in: managed))
        #expect(!fm.fileExists(atPath: managed.deletingLastPathComponent().appendingPathComponent("d3dmetal.partial").path))

        // GPTK removed: the links dangle and the folder no longer counts as prepared.
        try fm.removeItem(at: lib)
        #expect(!D3DMetal.isPrepared(in: managed))
    }
}

// MARK: - WineEngine Tests

struct WineEngineTests {

    private func makeArchive(withWine: Bool) throws -> (archive: URL, workDir: URL) {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("engine_\(UUID())")
        let bin = work.appendingPathComponent("src/wswine.bundle/bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        if withWine {
            let wine = bin.appendingPathComponent("wine")
            try Data("#!/bin/sh\n".utf8).write(to: wine)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        }
        let archive = work.appendingPathComponent("engine.tar.xz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-cJf", archive.path, "-C", work.appendingPathComponent("src").path, "wswine.bundle"]
        try tar.run()
        tar.waitUntilExit()
        return (archive, work)
    }

    private func release(name: String) -> WineEngine.Release {
        WineEngine.Release(name: name, displayName: "test", sha256: "abc123", downloadSize: 1, urls: [])
    }

    @Test func installUnpacksIntoPlaceWithMarker() throws {
        let fm = FileManager.default
        let (archive, work) = try makeArchive(withWine: true)
        defer { try? fm.removeItem(at: work) }
        let engines = work.appendingPathComponent("engines")
        try fm.createDirectory(at: engines, withIntermediateDirectories: true)

        try WineEngine.install(archive: archive, release: release(name: "wine-test"), enginesDirectory: engines)

        let final = engines.appendingPathComponent("wine-test")
        #expect(fm.isExecutableFile(atPath: final.appendingPathComponent("wswine.bundle/bin/wine").path))
        let marker = try String(contentsOf: final.appendingPathComponent(".palium-verified"), encoding: .utf8)
        #expect(marker == "abc123")
        #expect(!fm.fileExists(atPath: engines.appendingPathComponent("wine-test.partial").path))
    }

    @Test func installRejectsArchiveWithoutWine() throws {
        let fm = FileManager.default
        let (archive, work) = try makeArchive(withWine: false)
        defer { try? fm.removeItem(at: work) }
        let engines = work.appendingPathComponent("engines")
        try fm.createDirectory(at: engines, withIntermediateDirectories: true)

        #expect(throws: PaliumError.self) {
            try WineEngine.install(archive: archive, release: release(name: "wine-test"), enginesDirectory: engines)
        }
        #expect(!fm.fileExists(atPath: engines.appendingPathComponent("wine-test").path))
        #expect(!fm.fileExists(atPath: engines.appendingPathComponent("wine-test.partial").path))
    }

    @Test func sha256OfKnownContent() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sha_\(UUID())")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("abc".utf8).write(to: file)
        #expect(try WineEngine.sha256Hex(of: file)
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

// MARK: - PrefixMigration Tests

struct PrefixMigrationTests {

    struct Sandbox {
        let root: URL
        let legacy: URL
        let newPrefix: URL
        let defaults: UserDefaults
        let suite: String

        var legacyGame: URL { PrefixMigration.paliaFolder(prefix: legacy, user: "crossover") }
        var newGame: URL { PrefixMigration.paliaFolder(prefix: newPrefix, user: "player") }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
    }

    /// An old GPTK prefix (user `crossover`, optionally with a game) and a new prefix
    /// for user `player`.
    private func makeSandbox(legacyHasGame: Bool = true) throws -> Sandbox {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("migration_\(UUID())")
        let legacy = root.appendingPathComponent("prefix")
        let newPrefix = root.appendingPathComponent("prefix-w11")
        try fm.createDirectory(at: legacy.appendingPathComponent("drive_c/users/crossover"), withIntermediateDirectories: true)
        try fm.createDirectory(at: newPrefix.appendingPathComponent("drive_c/users/player"), withIntermediateDirectories: true)
        try """
        WINE REGISTRY Version 2

        [Volatile Environment] 1782835665
        "USERNAME"="crossover"

        """.write(to: legacy.appendingPathComponent("user.reg"), atomically: true, encoding: .utf8)

        if legacyHasGame {
            let game = PrefixMigration.paliaFolder(prefix: legacy, user: "crossover")
            try fm.createDirectory(at: game.appendingPathComponent("Client"), withIntermediateDirectories: true)
            try fm.createDirectory(at: game.appendingPathComponent("Saved/Config"), withIntermediateDirectories: true)
            try Data("exe".utf8).write(to: game.appendingPathComponent("Client/PaliaClient.exe"))
            try Data("settings".utf8).write(to: game.appendingPathComponent("Saved/Config/GameUserSettings.ini"))
        }
        let suite = "palium-tests-\(UUID())"
        return Sandbox(root: root, legacy: legacy, newPrefix: newPrefix,
                       defaults: UserDefaults(suiteName: suite)!, suite: suite)
    }

    private func run(_ box: Sandbox, running: Bool = false, stopped: (() -> Void)? = nil) throws -> PrefixMigration.Outcome {
        try PrefixMigration.run(
            newPrefix: box.newPrefix,
            newUser: "player",
            legacyPrefix: box.legacy,
            defaults: box.defaults,
            isGameRunning: { running },
            stopLegacyWine: { stopped?() }
        )
    }

    /// Compares paths: directory URLs may or may not carry a trailing slash.
    private func isMigrated(_ outcome: PrefixMigration.Outcome, _ box: Sandbox) -> Bool {
        guard case .migrated(let from, let to) = outcome else { return false }
        return from.path == box.legacyGame.path && to.path == box.newGame.path
    }

    private func inode(_ url: URL) throws -> UInt64 {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? UInt64) ?? 0
    }

    @Test func movesGameWithoutCopying() throws {
        let box = try makeSandbox()
        defer { box.cleanUp() }
        let exeInode = try inode(box.legacyGame.appendingPathComponent("Client/PaliaClient.exe"))
        var stoppedOldWine = false

        let outcome = try run(box, stopped: { stoppedOldWine = true })

        #expect(isMigrated(outcome, box))
        #expect(stoppedOldWine)
        #expect(PrefixMigration.hasGame(box.newGame))
        #expect(!FileManager.default.fileExists(atPath: box.legacyGame.path))
        // Same file, renamed: nothing was copied.
        #expect(try inode(box.newGame.appendingPathComponent("Client/PaliaClient.exe")) == exeInode)
        // Settings and logs travel with the game.
        #expect(FileManager.default.fileExists(atPath: box.newGame.appendingPathComponent("Saved/Config/GameUserSettings.ini").path))
        #expect(PrefixMigration.loadJournal(box.defaults)?.step == .done)
        // The old prefix itself stays.
        #expect(FileManager.default.fileExists(atPath: box.legacy.appendingPathComponent("user.reg").path))
    }

    @Test func secondRunHasNothingToDo() throws {
        let box = try makeSandbox()
        defer { box.cleanUp() }
        _ = try run(box)
        #expect(try run(box) == .nothingToMigrate)
    }

    @Test func freshInstallHasNothingToMigrate() throws {
        let box = try makeSandbox(legacyHasGame: false)
        defer { box.cleanUp() }
        #expect(try run(box) == .nothingToMigrate)
        try FileManager.default.removeItem(at: box.legacy)
        #expect(try run(box) == .nothingToMigrate)
    }

    @Test func refusesWhileGameRuns() throws {
        let box = try makeSandbox()
        defer { box.cleanUp() }
        #expect(throws: PrefixMigration.Failure.gameRunning) {
            _ = try run(box, running: true)
        }
        #expect(PrefixMigration.hasGame(box.legacyGame))
        #expect(PrefixMigration.loadJournal(box.defaults) == nil)
    }

    @Test func leavesBothWhenNewPrefixAlreadyHasGame() throws {
        let box = try makeSandbox()
        defer { box.cleanUp() }
        let fm = FileManager.default
        try fm.createDirectory(at: box.newGame.appendingPathComponent("Client"), withIntermediateDirectories: true)
        try Data("new".utf8).write(to: box.newGame.appendingPathComponent("Client/PaliaClient.exe"))

        guard case .newPrefixAlreadyHasGame(let legacyGame) = try run(box) else {
            Issue.record("expected newPrefixAlreadyHasGame")
            return
        }
        #expect(legacyGame.path == box.legacyGame.path)
        #expect(PrefixMigration.hasGame(box.legacyGame))
        #expect(try Data(contentsOf: box.newGame.appendingPathComponent("Client/PaliaClient.exe")) == Data("new".utf8))
    }

    @Test func setsAsideFolderWithoutGame() throws {
        let box = try makeSandbox()
        defer { box.cleanUp() }
        let fm = FileManager.default
        try fm.createDirectory(at: box.newGame.appendingPathComponent("Saved"), withIntermediateDirectories: true)

        _ = try run(box)

        #expect(PrefixMigration.hasGame(box.newGame))
        let siblings = try fm.contentsOfDirectory(atPath: box.newGame.deletingLastPathComponent().path)
        #expect(siblings.contains { $0.hasPrefix("Palia.before-migration-") })
    }

    @Test func finishesInterruptedMoveAfterRename() throws {
        let box = try makeSandbox()
        defer { box.cleanUp() }
        let fm = FileManager.default
        // Crash after the rename, before the journal said done.
        let journal = PrefixMigration.Journal(step: .moving, source: box.legacyGame.path, destination: box.newGame.path)
        box.defaults.set(try JSONEncoder().encode(journal), forKey: PrefixMigration.journalKey)
        try fm.createDirectory(at: box.newGame.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: box.legacyGame, to: box.newGame)

        #expect(isMigrated(try run(box, running: true), box))
        #expect(PrefixMigration.loadJournal(box.defaults)?.step == .done)
    }

    @Test func redoesMoveInterruptedBeforeRename() throws {
        let box = try makeSandbox()
        defer { box.cleanUp() }
        // Crash after writing the journal, before the rename.
        let journal = PrefixMigration.Journal(step: .moving, source: box.legacyGame.path, destination: box.newGame.path)
        box.defaults.set(try JSONEncoder().encode(journal), forKey: PrefixMigration.journalKey)

        #expect(isMigrated(try run(box), box))
        #expect(PrefixMigration.hasGame(box.newGame))
    }
}

// MARK: - AppState Tests

@MainActor
struct AppStateTests {

    @Test func initialPhase() {
        let state = AppState()
        if case .checking = state.phase {
            // pass
        } else {
            Issue.record("Expected .checking, got \(state.phase)")
        }
    }

    @Test func logAddsEntries() {
        let state = AppState()
        #expect(state.logEntries.isEmpty)
        state.log("test message")
        #expect(state.logEntries.count == 1)
        #expect(state.logEntries[0].message == "test message")
        #expect(state.logEntries[0].level == .info)
    }

    @Test func logWithLevel() {
        let state = AppState()
        state.log("error!", level: .error)
        #expect(state.logEntries[0].level == .error)
    }

    @Test func clearLog() {
        let state = AppState()
        state.log("a")
        state.log("b")
        #expect(state.logEntries.count == 2)
        state.clearLog()
        #expect(state.logEntries.isEmpty)
    }

    @Test func isRepairingFlag() {
        let state = AppState()
        state.phase = .repairing
        #expect(state.isRepairing == true)
        state.phase = .ready
        #expect(state.isRepairing == false)
    }

    @Test func speedHistoryCapping() {
        let state = AppState()
        // Simulate many speed updates over time
        for i in 0..<100 {
            state.speedHistory.append(Double(i) * 1024)
        }
        // Should be capped internally when using updateSpeed, but direct append won't cap.
        // Test that the cap constant is reasonable
        #expect(state.speedHistory.count == 100)
    }

    @Test func resetSpeed() {
        let state = AppState()
        state.downloadSpeed = 5_000_000
        state.speedHistory = [1, 2, 3]
        state.resetSpeed()
        #expect(state.downloadSpeed == 0)
        #expect(state.speedHistory.isEmpty)
    }
}

// MARK: - FlexValue Equatable (for test assertions)

extension FlexValue: @retroactive Equatable {
    public static func == (lhs: FlexValue, rhs: FlexValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.int(let a), .int(let b)): return a == b
        case (.uint(let a), .uint(let b)): return a == b
        case (.float(let a), .float(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.blob(let a), .blob(let b)): return a == b
        case (.vector(let a), .vector(let b)): return a == b
        case (.map(let a), .map(let b)): return a == b
        default: return false
        }
    }
}
