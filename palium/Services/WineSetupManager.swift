import Foundation

nonisolated enum WineSetupManager {

    struct SetupProgress: Sendable {
        enum Step: Sendable {
            case checkingRosetta
            case downloadingWine
            case extractingWine
            case downloadingDXMT
            case extractingDXMT
            case initializingPrefix
            case complete
        }

        let step: Step
        let bytesDownloaded: Int64
        let totalBytes: Int64

        var description: String {
            switch step {
            case .checkingRosetta:
                return "Checking Rosetta 2..."
            case .downloadingWine:
                if totalBytes > 0 {
                    return "Downloading Wine Staging (\(formatSize(UInt64(bytesDownloaded))) / \(formatSize(UInt64(totalBytes))))..."
                }
                return "Downloading Wine Staging..."
            case .extractingWine:
                return "Extracting Wine Staging..."
            case .downloadingDXMT:
                if totalBytes > 0 {
                    return "Downloading DXMT (\(formatSize(UInt64(bytesDownloaded))) / \(formatSize(UInt64(totalBytes))))..."
                }
                return "Downloading DXMT..."
            case .extractingDXMT:
                return "Extracting DXMT..."
            case .initializingPrefix:
                return "Initializing Wine prefix..."
            case .complete:
                return "Setup complete"
            }
        }

        var fraction: Double {
            totalBytes > 0 ? Double(bytesDownloaded) / Double(totalBytes) : 0
        }
    }

    /// Check if full standalone setup is ready
    static var isSetupComplete: Bool {
        WineManager.isWineStagingInstalled && WineManager.isDXMTInstalled
    }

    /// Perform full setup: Rosetta check, Wine download, DXMT download
    static func performSetup(
        onProgress: @escaping @Sendable (SetupProgress) -> Void,
        onLog: @escaping @Sendable (String, LogEntry.Level) -> Void
    ) async throws {
        // Step 1: Rosetta check (ARM only)
        if WineManager.needsRosetta {
            if WineManager.isRosettaAvailable() {
                onLog("Rosetta 2 already installed", .success)
            } else {
                onProgress(SetupProgress(step: .checkingRosetta, bytesDownloaded: 0, totalBytes: 0))
                onLog("Installing Rosetta 2 (required for Wine on Apple Silicon)...", .info)
                try await WineManager.installRosetta()
                onLog("Rosetta 2 installed", .success)
            }
        }

        // Step 2: Download + extract Wine Staging
        if !WineManager.isWineStagingInstalled {
            let wineDir = WineManager.wineStagingDir()
            try FileManager.default.createDirectory(at: wineDir, withIntermediateDirectories: true)

            let archivePath = wineDir.appendingPathComponent("wine-staging.tar.xz")

            onLog("Downloading Wine Staging \(WineManager.wineStagingVersion)...", .info)
            try await downloadWithProgress(
                from: WineManager.wineStagingDownloadURL,
                to: archivePath
            ) { bytesDownloaded, totalBytes in
                onProgress(SetupProgress(
                    step: .downloadingWine,
                    bytesDownloaded: bytesDownloaded,
                    totalBytes: totalBytes
                ))
            }
            onLog("Wine Staging downloaded", .success)

            onProgress(SetupProgress(step: .extractingWine, bytesDownloaded: 0, totalBytes: 0))
            onLog("Extracting Wine Staging...", .info)
            try await extractTarArchive(at: archivePath, to: wineDir)
            try? FileManager.default.removeItem(at: archivePath)
            onLog("Wine Staging extracted", .success)

            // Validate
            guard WineManager.isWineStagingInstalled else {
                throw PaliumError.wineSetupFailed(
                    "Wine binary not found after extraction at \(WineManager.wineStagingBinaryPath().path)"
                )
            }
        } else {
            onLog("Wine Staging already installed", .success)
        }

        // Step 3: Download + extract DXMT
        if !WineManager.isDXMTInstalled {
            let dxmtDir = WineManager.dxmtDir()
            try FileManager.default.createDirectory(at: dxmtDir, withIntermediateDirectories: true)

            let archivePath = dxmtDir.appendingPathComponent("dxmt.tar.gz")

            onLog("Downloading DXMT \(WineManager.dxmtVersion)...", .info)
            try await downloadWithProgress(
                from: WineManager.dxmtDownloadURL,
                to: archivePath
            ) { bytesDownloaded, totalBytes in
                onProgress(SetupProgress(
                    step: .downloadingDXMT,
                    bytesDownloaded: bytesDownloaded,
                    totalBytes: totalBytes
                ))
            }
            onLog("DXMT downloaded", .success)

            onProgress(SetupProgress(step: .extractingDXMT, bytesDownloaded: 0, totalBytes: 0))
            onLog("Extracting DXMT...", .info)
            try await extractTarArchive(at: archivePath, to: dxmtDir)
            try? FileManager.default.removeItem(at: archivePath)

            // DXMT tarballs may extract to a versioned subdirectory (e.g. v0.74/).
            // If the expected files aren't at the root, find and relocate them.
            try flattenDXMTDirectory(dxmtDir)

            onLog("DXMT extracted", .success)

            guard WineManager.isDXMTInstalled else {
                throw PaliumError.wineSetupFailed(
                    "DXMT DLLs not found after extraction at \(dxmtDir.path)"
                )
            }
        } else {
            onLog("DXMT already installed", .success)
        }

        onProgress(SetupProgress(step: .complete, bytesDownloaded: 0, totalBytes: 0))
    }

    // MARK: - Download

    private static func downloadWithProgress(
        from url: URL,
        to destination: URL,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        try? FileManager.default.removeItem(at: destination)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let delegate = DownloadDelegate(
                destination: destination,
                onProgress: onProgress,
                onComplete: { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )

            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 300
            config.timeoutIntervalForResource = 3600
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            delegate.session = session
            session.downloadTask(with: url).resume()
        }
    }
}

// MARK: - URLSession Download Delegate

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let onProgress: @Sendable (Int64, Int64) -> Void
    let onComplete: @Sendable (Error?) -> Void
    var session: URLSession?

    init(
        destination: URL,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void,
        onComplete: @escaping @Sendable (Error?) -> Void
    ) {
        self.destination = destination
        self.onProgress = onProgress
        self.onComplete = onComplete
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            onComplete(error)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            onComplete(error)
        } else if let httpResponse = task.response as? HTTPURLResponse,
                  !(200...299).contains(httpResponse.statusCode) {
            onComplete(PaliumError.wineSetupFailed(
                "Download failed with HTTP \(httpResponse.statusCode)"
            ))
        } else {
            onComplete(nil)
        }
        self.session?.invalidateAndCancel()
    }
}

// MARK: - Extraction (WineSetupManager)

extension WineSetupManager {

    static func extractTarArchive(at archivePath: URL, to destinationDir: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["xf", archivePath.path, "-C", destinationDir.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: PaliumError.extractionFailed(
                        "tar extraction failed with status \(proc.terminationStatus)"
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

    /// If DXMT extracted to a versioned subdirectory, move contents up to the root.
    static func flattenDXMTDirectory(_ dxmtDir: URL) throws {
        let fm = FileManager.default

        // Check if x86_64-windows exists at root
        if fm.fileExists(atPath: dxmtDir.appendingPathComponent("x86_64-windows").path) {
            return // Already flat
        }

        // Look for a versioned subdirectory containing x86_64-windows
        guard let contents = try? fm.contentsOfDirectory(at: dxmtDir, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return
        }

        for item in contents {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let candidate = item.appendingPathComponent("x86_64-windows")
            if fm.fileExists(atPath: candidate.path) {
                // Found the nested directory — move its contents up
                if let nestedContents = try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil) {
                    for nested in nestedContents {
                        let dest = dxmtDir.appendingPathComponent(nested.lastPathComponent)
                        try? fm.removeItem(at: dest)
                        try fm.moveItem(at: nested, to: dest)
                    }
                }
                try? fm.removeItem(at: item)
                return
            }
        }
    }
}
