import Foundation
import CryptoKit

struct DownloadProgress: Sendable {
    let bytesDownloaded: Int64
    let totalBytes: Int64
    let currentFile: String
    let filesCompleted: Int
    let filesTotal: Int

    var fraction: Double {
        totalBytes > 0 ? Double(bytesDownloaded) / Double(totalBytes) : 0
    }
}

// MARK: - URLSession Download Delegate (reports per-chunk progress)

private final class FileDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onBytesWritten: @Sendable (Int64) -> Void
    private let onComplete: @Sendable (Result<(URL, URLResponse), Error>) -> Void
    private var didResume = false
    private var lastReportedBytes: Int64 = 0
    weak var session: URLSession?

    init(
        onBytesWritten: @escaping @Sendable (Int64) -> Void,
        onComplete: @escaping @Sendable (Result<(URL, URLResponse), Error>) -> Void
    ) {
        self.onBytesWritten = onBytesWritten
        self.onComplete = onComplete
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        // Throttle: report every 256 KB to avoid flooding the actor
        guard totalBytesWritten - lastReportedBytes >= 262_144 else { return }
        lastReportedBytes = totalBytesWritten
        onBytesWritten(totalBytesWritten)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Copy file before the system deletes it when this method returns
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.copyItem(at: location, to: tempFile)
            guard !didResume else { return }
            didResume = true
            let response = downloadTask.response ?? URLResponse()
            onComplete(.success((tempFile, response)))
        } catch {
            guard !didResume else { return }
            didResume = true
            onComplete(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        self.session?.finishTasksAndInvalidate()
        if let error = error {
            guard !didResume else { return }
            didResume = true
            onComplete(.failure(error))
        }
    }
}

// MARK: - Download Manager

actor DownloadManager {

    private var downloadedBytes: Int64 = 0
    private var inFlightBytes: [String: Int64] = [:]
    private var totalBytes: Int64 = 0
    private var currentFile: String = ""
    private var filesCompleted: Int = 0
    private var filesTotal: Int = 0

    private let onProgress: @Sendable (DownloadProgress) -> Void
    private let onLog: @Sendable (String, LogEntry.Level) -> Void

    private static let maxHashVerifySize: UInt64 = 2 * 1024 * 1024 * 1024 // 2 GB
    private static let maxConcurrent = 4

    init(
        onProgress: @escaping @Sendable (DownloadProgress) -> Void,
        onLog: @escaping @Sendable (String, LogEntry.Level) -> Void = { _, _ in }
    ) {
        self.onProgress = onProgress
        self.onLog = onLog
    }

    func downloadAll(
        manifest: UpdateManifest,
        version: String,
        installDirectory: URL
    ) async throws {
        let files = manifest.files
        totalBytes = Int64(manifest.totalSize)
        filesTotal = files.count
        downloadedBytes = 0
        inFlightBytes = [:]
        filesCompleted = 0

        sendProgress()
        onLog("Starting download: \(files.count) files, \(Self.formatSize(manifest.totalSize))", .info)
        onLog("Install directory: \(installDirectory.path)", .info)

        // Sort files smallest first so small files complete quickly
        let sortedFiles = files.sorted { $0.size < $1.size }

        try await withThrowingTaskGroup(of: Void.self) { group in
            var index = 0

            for _ in 0..<min(Self.maxConcurrent, sortedFiles.count) {
                let file = sortedFiles[index]
                index += 1
                group.addTask {
                    try await self.downloadFile(file: file, version: version, to: installDirectory)
                }
            }

            for try await _ in group {
                if index < sortedFiles.count {
                    let file = sortedFiles[index]
                    index += 1
                    group.addTask {
                        try await self.downloadFile(file: file, version: version, to: installDirectory)
                    }
                }
            }
        }

        onLog("All downloads complete", .success)
    }

    private func downloadFile(
        file: ManifestFile,
        version: String,
        to installDirectory: URL
    ) async throws {
        let destURL = installDirectory.appendingPathComponent(file.path)
        let fm = FileManager.default

        // Check if file already exists with correct size (skip re-download)
        if fm.fileExists(atPath: destURL.path),
           let attrs = try? fm.attributesOfItem(atPath: destURL.path),
           let existingSize = attrs[.size] as? UInt64,
           existingSize == file.size {
            onLog("SKIP (exists): \(file.path) (\(Self.formatSize(file.size)))", .info)
            downloadedBytes += Int64(file.size)
            filesCompleted += 1
            currentFile = file.path
            sendProgress()
            return
        }

        // Create parent directories
        let parentDir = destURL.deletingLastPathComponent()
        try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)

        let url = CDNClient.fileURL(version: version, path: file.path)

        currentFile = file.path
        sendProgress()
        onLog("DOWNLOADING: \(file.path) (\(Self.formatSize(file.size))) from \(url.absoluteString)", .info)

        // Download with real-time progress tracking
        let filePath = file.path
        let (tempURL, response) = try await Self.downloadWithProgress(from: url) { totalBytesWritten in
            Task { await self.updateInFlightBytes(fileName: filePath, bytes: totalBytesWritten) }
        }

        // Clear in-flight tracking for this file
        inFlightBytes.removeValue(forKey: file.path)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            try? fm.removeItem(at: tempURL)
            onLog("HTTP ERROR \(httpResponse.statusCode): \(file.path)", .error)
            throw PaliumError.downloadFailed(
                path: file.path,
                reason: "HTTP \(httpResponse.statusCode)"
            )
        }

        // Move temp file to destination
        if fm.fileExists(atPath: destURL.path) {
            try fm.removeItem(at: destURL)
        }
        try fm.moveItem(at: tempURL, to: destURL)

        // Verify downloaded size
        if let attrs = try? fm.attributesOfItem(atPath: destURL.path),
           let downloadedSize = attrs[.size] as? UInt64 {
            if downloadedSize != file.size {
                onLog("SIZE ERROR: \(file.path) — got \(Self.formatSize(downloadedSize)), expected \(Self.formatSize(file.size))", .error)
                try? fm.removeItem(at: destURL)
                throw PaliumError.downloadFailed(path: file.path, reason: "Size mismatch after download")
            }
        }

        // Verify hash for files under the size threshold
        if file.size <= Self.maxHashVerifySize && !file.hash.isEmpty {
            let actualHash = try Self.hashFile(at: destURL)
            if actualHash != file.hash {
                onLog("HASH MISMATCH: \(file.path)", .error)
                try? fm.removeItem(at: destURL)
                throw PaliumError.hashMismatch(path: file.path)
            }
        }

        // Set execute permissions on .exe files
        if destURL.pathExtension.lowercased() == "exe" {
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destURL.path)
        }

        onLog("DONE: \(file.path) (\(Self.formatSize(file.size)))", .success)
        downloadedBytes += Int64(file.size)
        filesCompleted += 1
        currentFile = file.path
        sendProgress()
    }

    /// Hash a file using memory-mapped I/O.
    private static nonisolated func hashFile(at url: URL) throws -> Data {
        let mapped = try Data(contentsOf: url, options: .mappedIfSafe)
        let digest = SHA256.hash(data: mapped)
        return Data(digest)
    }

    // MARK: - Download with Progress

    private static nonisolated func downloadWithProgress(
        from url: URL,
        onBytesWritten: @escaping @Sendable (Int64) -> Void
    ) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let delegate = FileDownloadDelegate(
                onBytesWritten: onBytesWritten,
                onComplete: { result in
                    continuation.resume(with: result)
                }
            )
            let session = URLSession(
                configuration: .default,
                delegate: delegate,
                delegateQueue: nil
            )
            delegate.session = session
            session.downloadTask(with: url).resume()
        }
    }

    // MARK: - In-Flight Progress

    private func updateInFlightBytes(fileName: String, bytes: Int64) {
        inFlightBytes[fileName] = bytes
        sendProgress()
    }

    // MARK: - Verify & Repair

    enum VerifyResult: Sendable {
        case ok(ManifestFile, UInt64)
        case missing(ManifestFile)
        case sizeMismatch(ManifestFile, local: UInt64)
        case unreadable(ManifestFile)
    }

    func verifyFiles(
        manifest: UpdateManifest,
        installDirectory: URL,
        onLog: @escaping @Sendable (String, LogEntry.Level) -> Void
    ) async -> [ManifestFile] {
        filesTotal = manifest.files.count
        filesCompleted = 0
        totalBytes = Int64(manifest.totalSize)
        downloadedBytes = 0
        inFlightBytes = [:]

        onLog("Starting verification of \(manifest.files.count) files in \(installDirectory.path)", .info)
        onLog("Expected total size: \(Self.formatSize(manifest.totalSize))", .info)

        let results = await withTaskGroup(of: VerifyResult.self, returning: [VerifyResult].self) { group in
            for file in manifest.files {
                group.addTask {
                    Self.verifyOneFile(file: file, installDirectory: installDirectory)
                }
            }

            var collected: [VerifyResult] = []
            collected.reserveCapacity(manifest.files.count)
            for await result in group {
                collected.append(result)
                self.incrementVerifyProgress(result: result)
            }
            return collected
        }

        var corruptFiles: [ManifestFile] = []
        let sorted = results.sorted { lhs, rhs in
            func path(_ r: VerifyResult) -> String {
                switch r {
                case .ok(let f, _), .missing(let f), .sizeMismatch(let f, _), .unreadable(let f): return f.path
                }
            }
            return path(lhs) < path(rhs)
        }

        for result in sorted {
            switch result {
            case .ok(let file, let size):
                onLog("OK: \(file.path) (\(Self.formatSize(size)))", .success)
            case .missing(let file):
                onLog("MISSING: \(file.path) (expected \(Self.formatSize(file.size)))", .error)
                corruptFiles.append(file)
            case .sizeMismatch(let file, let localSize):
                onLog("SIZE MISMATCH: \(file.path) — local: \(Self.formatSize(localSize)), expected: \(Self.formatSize(file.size)) (diff: \(Self.formatSizeDiff(local: localSize, expected: file.size)))", .warning)
                corruptFiles.append(file)
            case .unreadable(let file):
                onLog("UNREADABLE: \(file.path) — cannot read file attributes", .error)
                corruptFiles.append(file)
            }
        }

        if corruptFiles.isEmpty {
            onLog("Verification complete: all \(manifest.files.count) files OK", .success)
        } else {
            let repairSize = corruptFiles.reduce(UInt64(0)) { $0 + $1.size }
            onLog("Verification complete: \(corruptFiles.count) file(s) need repair (\(Self.formatSize(repairSize)) to download)", .warning)
        }

        return corruptFiles
    }

    private static nonisolated func verifyOneFile(file: ManifestFile, installDirectory: URL) -> VerifyResult {
        let destURL = installDirectory.appendingPathComponent(file.path)
        let fm = FileManager.default

        guard fm.fileExists(atPath: destURL.path) else {
            return .missing(file)
        }

        guard let attrs = try? fm.attributesOfItem(atPath: destURL.path),
              let fileSize = attrs[.size] as? UInt64 else {
            return .unreadable(file)
        }

        if fileSize != file.size {
            return .sizeMismatch(file, local: fileSize)
        }

        return .ok(file, fileSize)
    }

    private func incrementVerifyProgress(result: VerifyResult) {
        filesCompleted += 1
        switch result {
        case .ok(let file, let size):
            downloadedBytes += Int64(size)
            currentFile = file.path
        case .missing(let file), .sizeMismatch(let file, _), .unreadable(let file):
            currentFile = file.path
        }
        sendProgress()
    }

    static func formatSize(_ bytes: UInt64) -> String {
        if bytes >= 1024 * 1024 * 1024 {
            return String(format: "%.2f GB", Double(bytes) / (1024 * 1024 * 1024))
        } else if bytes >= 1024 * 1024 {
            return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
        } else if bytes >= 1024 {
            return String(format: "%.0f KB", Double(bytes) / 1024)
        }
        return "\(bytes) B"
    }

    private static func formatSizeDiff(local: UInt64, expected: UInt64) -> String {
        if local < expected {
            return "-\(formatSize(expected - local)) short"
        } else {
            return "+\(formatSize(local - expected)) over"
        }
    }

    func repairFiles(
        files: [ManifestFile],
        version: String,
        installDirectory: URL
    ) async throws {
        totalBytes = files.reduce(0) { $0 + Int64($1.size) }
        downloadedBytes = 0
        inFlightBytes = [:]
        filesTotal = files.count
        filesCompleted = 0

        onLog("Repairing \(files.count) files (\(Self.formatSize(UInt64(totalBytes))))", .info)
        sendProgress()

        let sortedFiles = files.sorted { $0.size < $1.size }

        try await withThrowingTaskGroup(of: Void.self) { group in
            var index = 0

            for _ in 0..<min(Self.maxConcurrent, sortedFiles.count) {
                let file = sortedFiles[index]
                index += 1
                group.addTask {
                    try await self.downloadFile(file: file, version: version, to: installDirectory)
                }
            }

            for try await _ in group {
                if index < sortedFiles.count {
                    let file = sortedFiles[index]
                    index += 1
                    group.addTask {
                        try await self.downloadFile(file: file, version: version, to: installDirectory)
                    }
                }
            }
        }

        onLog("Repair complete", .success)
    }

    // MARK: - Progress Tracking

    private func sendProgress() {
        let inFlight = inFlightBytes.values.reduce(Int64(0), +)
        let progress = DownloadProgress(
            bytesDownloaded: downloadedBytes + inFlight,
            totalBytes: totalBytes,
            currentFile: currentFile,
            filesCompleted: filesCompleted,
            filesTotal: filesTotal
        )
        onProgress(progress)
    }
}
