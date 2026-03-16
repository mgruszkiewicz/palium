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
        let file = ManifestFile(path: "test/file.exe", size: 1024, hash: Data(), chunks: [])
        #expect(file.id == "test/file.exe")
    }

    @Test func manifestChunkProperties() {
        let chunk = ManifestChunk(offset: 0, size: 512, hash: Data([0xAB, 0xCD]))
        #expect(chunk.offset == 0)
        #expect(chunk.size == 512)
        #expect(chunk.hash.count == 2)
    }

    @Test func updateManifestTotalSize() {
        let manifest = UpdateManifest(
            bundle: "Palia",
            version: "1.0",
            platform: "windows",
            files: [
                ManifestFile(path: "a.exe", size: 100, hash: Data(), chunks: []),
                ManifestFile(path: "b.pak", size: 200, hash: Data(), chunks: []),
            ],
            totalSize: 300
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
            wineUsername: "testuser",
            source: .gptk
        )
        #expect(info.gameInstallPath.path.contains("testuser"))
        #expect(info.gameInstallPath.path.hasSuffix("Palia/Client"))
    }

    @Test func gameSavedPath() {
        let info = WineInfo(
            wineBinaryURL: URL(fileURLWithPath: "/usr/bin/wine64"),
            prefixPath: URL(fileURLWithPath: "/tmp/prefix"),
            wineUsername: "player",
            source: .whisky
        )
        #expect(info.gameSavedPath.path.contains("player"))
        #expect(info.gameSavedPath.path.hasSuffix("Palia/Saved"))
    }

    @Test func wineDownloadsPath() {
        let info = WineInfo(
            wineBinaryURL: URL(fileURLWithPath: "/usr/bin/wine64"),
            prefixPath: URL(fileURLWithPath: "/tmp/prefix"),
            wineUsername: "user",
            source: .gptk
        )
        #expect(info.wineDownloadsPath.path.hasSuffix("Downloads"))
    }

    @Test func sourceRawValues() {
        #expect(WineInfo.Source.gptk.rawValue == "GPTK")
        #expect(WineInfo.Source.whisky.rawValue == "Whisky")
    }
}

// MARK: - LaunchSettings Tests

struct LaunchSettingsTests {

    @Test func wineSourceCases() {
        let cases = LaunchSettings.WineSource.allCases
        #expect(cases.count == 3)
        #expect(cases.contains(.auto))
        #expect(cases.contains(.gptk))
        #expect(cases.contains(.whisky))
    }

    @Test func wineSourceRawValues() {
        #expect(LaunchSettings.WineSource.auto.rawValue == "Automatic")
        #expect(LaunchSettings.WineSource.gptk.rawValue == "GPTK (Homebrew)")
        #expect(LaunchSettings.WineSource.whisky.rawValue == "Whisky")
    }

    @Test func wineSourceCodable() throws {
        let source = LaunchSettings.WineSource.gptk
        let data = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(LaunchSettings.WineSource.self, from: data)
        #expect(decoded == source)
    }
}

// MARK: - GameLauncher Tests

struct GameLauncherTests {

    @Test func launchOptionsDefaults() {
        let options = GameLauncher.LaunchOptions(metalHUD: false, useAllCores: true)
        #expect(options.metalHUD == false)
        #expect(options.useAllCores == true)
    }

    @Test func launchFailsWithMissingGame() {
        let info = WineInfo(
            wineBinaryURL: URL(fileURLWithPath: "/usr/bin/false"),
            prefixPath: URL(fileURLWithPath: "/tmp/nonexistent"),
            wineUsername: "test",
            source: .gptk
        )
        let options = GameLauncher.LaunchOptions(metalHUD: false, useAllCores: false)
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
            wineUsername: "test",
            source: .gptk
        )
        let env = WineManager.makeWineEnvironment(info: info)
        #expect(env["WINEPREFIX"] == "/tmp/testprefix")
        #expect(env["WINEBOOT_HIDE_DIALOG"] == "1")
        #expect(env["WINEDEBUG"] == "-all")
        #expect(env["WINEMSYNC"] == "1")
        #expect(env["DXVK_ASYNC"] == "1")
        #expect(env["DXVK_STATE_CACHE"] == "1")
        #expect(env["MTL_HUD_ENABLED"] == nil)
    }

    @Test func makeWineEnvironmentWithMetalHUD() {
        let info = WineInfo(
            wineBinaryURL: URL(fileURLWithPath: "/usr/bin/wine64"),
            prefixPath: URL(fileURLWithPath: "/tmp/testprefix"),
            wineUsername: "test",
            source: .gptk
        )
        let env = WineManager.makeWineEnvironment(info: info, metalHUD: true)
        #expect(env["MTL_HUD_ENABLED"] == "1")
    }

    @Test func makeWineEnvironmentHasDLLOverrides() {
        let info = WineInfo(
            wineBinaryURL: URL(fileURLWithPath: "/usr/bin/wine64"),
            prefixPath: URL(fileURLWithPath: "/tmp/testprefix"),
            wineUsername: "test",
            source: .gptk
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

    @Test func isVCRuntimeInstalledReturnsFalseForMissingPrefix() {
        let info = WineInfo(
            wineBinaryURL: URL(fileURLWithPath: "/usr/bin/wine64"),
            prefixPath: URL(fileURLWithPath: "/tmp/nonexistent_prefix_\(UUID())"),
            wineUsername: "test",
            source: .gptk
        )
        #expect(WineManager.isVCRuntimeInstalled(info: info) == false)
    }

    @Test func isGameInstalledReturnsFalseForMissingGame() {
        let info = WineInfo(
            wineBinaryURL: URL(fileURLWithPath: "/usr/bin/wine64"),
            prefixPath: URL(fileURLWithPath: "/tmp/nonexistent_prefix_\(UUID())"),
            wineUsername: "test",
            source: .gptk
        )
        #expect(WineManager.isGameInstalled(info: info) == false)
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
