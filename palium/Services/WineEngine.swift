import CryptoKit
import Foundation

/// The single Wine build Palium runs everything on: Sikarugir's Wine 11.0 engine
/// (CrossOver-based, with msync and CrossOver's hooks for an external D3DMetal).
///
/// It is downloaded once into Application Support and checked against a pinned
/// SHA-256. Installation goes through a `.partial` folder that is renamed into place
/// only after extraction succeeded, so a half-installed engine is never used.
nonisolated enum WineEngine {

    struct Release: Sendable {
        /// Folder name under `engines/`; also shown in the UI.
        let name: String
        let displayName: String
        let sha256: String
        let downloadSize: Int64
        let urls: [URL]
    }

    static let current = Release(
        name: "wine-11.0_1",
        displayName: "Wine 11.0 (Sikarugir r1)",
        sha256: "67e29fb3d74f363af39c69ba11f9b13a79812c5db07cf4748672658e4a200a0e",
        downloadSize: 167_322_744,
        urls: [
            // A copy in Palium's own releases goes first once it is published, so
            // upstream replacing or removing the asset can't break installs.
            URL(string: "https://github.com/Sikarugir-App/Engines/releases/download/v1.0/WS12WineSikarugir11.0_1.tar.xz")!,
        ]
    )

    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.palium")
    }

    static var enginesDirectory: URL {
        supportDirectory.appendingPathComponent("engines")
    }

    static func installDirectory(for release: Release = current) -> URL {
        enginesDirectory.appendingPathComponent(release.name)
    }

    /// The Wine tree inside the archive (`bin/`, `lib/`, `share/`).
    static func root(for release: Release = current) -> URL {
        installDirectory(for: release).appendingPathComponent("wswine.bundle")
    }

    static var wineBinary: URL { root().appendingPathComponent("bin/wine") }
    static var wineserverBinary: URL { root().appendingPathComponent("bin/wineserver") }

    /// Written after a verified install; holds the archive's SHA-256.
    private static let markerName = ".palium-verified"

    static func isInstalled(_ release: Release = current) -> Bool {
        let dir = installDirectory(for: release)
        let marker = dir.appendingPathComponent(markerName)
        guard let recorded = try? String(contentsOf: marker, encoding: .utf8) else { return false }
        return recorded.trimmingCharacters(in: .whitespacesAndNewlines) == release.sha256
            && FileManager.default.isExecutableFile(
                atPath: root(for: release).appendingPathComponent("bin/wine").path
            )
    }

    /// Download, verify and unpack the engine if it isn't installed yet.
    static func ensureInstalled(
        _ release: Release = current,
        onLog: @escaping @Sendable (String, LogEntry.Level) -> Void = { _, _ in }
    ) async throws {
        if isInstalled(release) { return }

        let fm = FileManager.default
        try fm.createDirectory(at: enginesDirectory, withIntermediateDirectories: true)
        try checkFreeSpace(needed: release.downloadSize * 5, at: enginesDirectory)

        onLog("Downloading \(release.displayName) (\(formatSize(UInt64(release.downloadSize))))...", .info)
        let archive = try await download(release, onLog: onLog)
        defer { try? fm.removeItem(at: archive) }

        let digest = try sha256Hex(of: archive)
        guard digest == release.sha256 else {
            throw PaliumError.engineInstallFailed(
                "checksum mismatch (expected \(release.sha256.prefix(12))…, got \(digest.prefix(12))…)"
            )
        }
        onLog("Wine engine checksum verified", .success)

        try install(archive: archive, release: release)
        onLog("Installed \(release.displayName)", .success)
    }

    /// Unpack a verified archive into place. Exposed for tests.
    static func install(archive: URL, release: Release, enginesDirectory: URL = enginesDirectory) throws {
        let fm = FileManager.default
        let final = enginesDirectory.appendingPathComponent(release.name)
        let partial = enginesDirectory.appendingPathComponent(release.name + ".partial")
        try? fm.removeItem(at: partial)
        try fm.createDirectory(at: partial, withIntermediateDirectories: true)

        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xJf", archive.path, "-C", partial.path]
        let errPipe = Pipe()
        tar.standardError = errPipe
        tar.standardOutput = FileHandle.nullDevice
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else {
            let message = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            try? fm.removeItem(at: partial)
            throw PaliumError.engineInstallFailed("extracting failed: \(message.prefix(200))")
        }

        let wine = partial.appendingPathComponent("wswine.bundle/bin/wine")
        guard fm.isExecutableFile(atPath: wine.path) else {
            try? fm.removeItem(at: partial)
            throw PaliumError.engineInstallFailed("archive has no wswine.bundle/bin/wine")
        }

        try release.sha256.write(
            to: partial.appendingPathComponent(markerName), atomically: true, encoding: .utf8
        )
        try? fm.removeItem(at: final)
        try fm.moveItem(at: partial, to: final)
    }

    private static func download(
        _ release: Release,
        onLog: @escaping @Sendable (String, LogEntry.Level) -> Void
    ) async throws -> URL {
        var lastError: Error?
        for url in release.urls {
            do {
                let (tempURL, response) = try await URLSession.shared.download(from: url)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    try? FileManager.default.removeItem(at: tempURL)
                    throw PaliumError.engineInstallFailed("HTTP \(http.statusCode) from \(url.host() ?? "?")")
                }
                // The system deletes the temporary file soon; keep our own copy.
                let kept = enginesDirectory.appendingPathComponent(release.name + ".tar.xz.download")
                try? FileManager.default.removeItem(at: kept)
                try FileManager.default.moveItem(at: tempURL, to: kept)
                return kept
            } catch {
                lastError = error
                onLog("Engine download from \(url.host() ?? "?") failed: \(error.localizedDescription)", .warning)
            }
        }
        throw PaliumError.engineInstallFailed(lastError?.localizedDescription ?? "no download source")
    }

    static func sha256Hex(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func checkFreeSpace(needed: Int64, at directory: URL) throws {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values?.volumeAvailableCapacityForImportantUsage, available < needed {
            throw PaliumError.engineInstallFailed(
                "not enough free space: needs \(formatSize(UInt64(needed))), \(formatSize(UInt64(available))) available"
            )
        }
    }
}
