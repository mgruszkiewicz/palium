import Foundation
import CryptoKit
import os

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

// MARK: - Shared Formatting

nonisolated func formatSize(_ bytes: UInt64) -> String {
    if bytes >= 1024 * 1024 * 1024 {
        return String(format: "%.2f GB", Double(bytes) / (1024 * 1024 * 1024))
    } else if bytes >= 1024 * 1024 {
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    } else if bytes >= 1024 {
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }
    return "\(bytes) B"
}

// MARK: - URLSession Delegate (one session, routes callbacks per task)

private final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    struct Handler {
        let onBytesWritten: @Sendable (Int64) -> Void
        let onComplete: @Sendable (Result<(URL, URLResponse), Error>) -> Void
    }

    private struct State {
        var handlers: [Int: Handler] = [:]
        var lastReportedBytes: [Int: Int64] = [:]
        /// Results for tasks that completed before register() ran — possible
        /// when a task is cancelled immediately after creation.
        var orphanResults: [Int: Result<(URL, URLResponse), Error>] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func register(_ task: URLSessionTask, handler: Handler) {
        let orphan = state.withLock { s -> Result<(URL, URLResponse), Error>? in
            if let result = s.orphanResults.removeValue(forKey: task.taskIdentifier) {
                return result
            }
            s.handlers[task.taskIdentifier] = handler
            return nil
        }
        if let orphan {
            handler.onComplete(orphan)
        }
    }

    private func takeHandler(for task: URLSessionTask) -> Handler? {
        state.withLock { s in
            s.lastReportedBytes[task.taskIdentifier] = nil
            return s.handlers.removeValue(forKey: task.taskIdentifier)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        // Throttle: report every 256 KB per task to avoid flooding the actor
        let handler = state.withLock { s -> Handler? in
            let id = downloadTask.taskIdentifier
            guard totalBytesWritten - (s.lastReportedBytes[id] ?? 0) >= 262_144 else { return nil }
            s.lastReportedBytes[id] = totalBytesWritten
            return s.handlers[id]
        }
        handler?.onBytesWritten(totalBytesWritten)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Move the file before the system deletes it when this method returns
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let result: Result<(URL, URLResponse), Error>
        do {
            try FileManager.default.moveItem(at: location, to: tempFile)
            result = .success((tempFile, downloadTask.response ?? URLResponse()))
        } catch {
            result = .failure(error)
        }
        takeHandler(for: downloadTask)?.onComplete(result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Success is delivered in didFinishDownloadingTo; only errors arrive here.
        guard let error else { return }
        if let handler = takeHandler(for: task) {
            handler.onComplete(.failure(error))
        } else {
            state.withLock { $0.orphanResults[task.taskIdentifier] = .failure(error) }
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

    private static let maxConcurrent = 4

    private static let sessionDelegate = DownloadSessionDelegate()
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300 // 5 min per request
        config.timeoutIntervalForResource = 43200 // 12 hour total per file
        return URLSession(configuration: config, delegate: sessionDelegate, delegateQueue: nil)
    }()

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
        onLog("Starting download: \(files.count) files, \(formatSize(manifest.totalSize))", .info)
        onLog("Install directory: \(installDirectory.path)", .info)

        try await downloadThrottled(files: files, version: version, installDirectory: installDirectory)

        onLog("All downloads complete", .success)
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

        onLog("Repairing \(files.count) files (\(formatSize(UInt64(totalBytes))))", .info)
        sendProgress()

        try await downloadThrottled(files: files, version: version, installDirectory: installDirectory)

        onLog("Repair complete", .success)
    }

    /// Download files with at most `maxConcurrent` in flight at a time.
    private func downloadThrottled(
        files: [ManifestFile],
        version: String,
        installDirectory: URL
    ) async throws {
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
                try Task.checkCancellation()
                if index < sortedFiles.count {
                    let file = sortedFiles[index]
                    index += 1
                    group.addTask {
                        try Task.checkCancellation()
                        try await self.downloadFile(file: file, version: version, to: installDirectory)
                    }
                }
            }
        }
    }

    private func downloadFile(
        file: ManifestFile,
        version: String,
        to installDirectory: URL
    ) async throws {
        let destURL = installDirectory.appendingPathComponent(file.path)
        let fm = FileManager.default
        defer { inFlightBytes.removeValue(forKey: file.path) }

        // Skip re-download only if both size and content hash match — a changed
        // file of identical size (e.g. an in-place patch) must be re-fetched.
        if fm.fileExists(atPath: destURL.path),
           let attrs = try? fm.attributesOfItem(atPath: destURL.path),
           let existingSize = attrs[.size] as? UInt64,
           existingSize == file.size {
            let hashMatches: Bool
            if file.hash.isEmpty {
                hashMatches = true
            } else {
                hashMatches = (try? await Self.computeHash(at: destURL)) == file.hash
            }
            if hashMatches {
                onLog("SKIP (up to date): \(file.path) (\(formatSize(file.size)))", .info)
                downloadedBytes += Int64(file.size)
                filesCompleted += 1
                currentFile = file.path
                sendProgress()
                return
            }
            onLog("STALE (hash changed): \(file.path) — re-downloading", .warning)
        }

        // Create parent directories
        let parentDir = destURL.deletingLastPathComponent()
        try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)

        let url = CDNClient.fileURL(version: version, path: file.path)

        currentFile = file.path
        sendProgress()
        onLog("DOWNLOADING: \(file.path) (\(formatSize(file.size))) from \(url.absoluteString)", .info)

        // Download with real-time progress tracking
        let filePath = file.path
        let (tempURL, response): (URL, URLResponse)
        do {
            (tempURL, response) = try await Self.downloadWithProgress(from: url) { totalBytesWritten in
                Task { await self.updateInFlightBytes(fileName: filePath, bytes: totalBytesWritten) }
            }
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }

        if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
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
                onLog("SIZE ERROR: \(file.path) — got \(formatSize(downloadedSize)), expected \(formatSize(file.size))", .error)
                try? fm.removeItem(at: destURL)
                throw PaliumError.downloadFailed(path: file.path, reason: "Size mismatch after download")
            }
        }

        // Verify hash
        if !file.hash.isEmpty {
            let actualHash = try await Self.computeHash(at: destURL)
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

        onLog("DONE: \(file.path) (\(formatSize(file.size)))", .success)
        downloadedBytes += Int64(file.size)
        filesCompleted += 1
        currentFile = file.path
        sendProgress()
    }

    // MARK: - Hashing

    /// Hash a file in fixed-size chunks so large files never need to be
    /// resident in memory all at once.
    private static nonisolated func hashFile(at url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try autoreleasepool { try handle.read(upToCount: 1_048_576) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }

    /// Hash off the actor so progress callbacks stay responsive.
    private static nonisolated func computeHash(at url: URL) async throws -> Data {
        try await Task.detached(priority: .utility) {
            try hashFile(at: url)
        }.value
    }

    // MARK: - Download with Progress

    private static nonisolated func downloadWithProgress(
        from url: URL,
        onBytesWritten: @escaping @Sendable (Int64) -> Void
    ) async throws -> (URL, URLResponse) {
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sessionDelegate.register(task, handler: .init(
                    onBytesWritten: onBytesWritten,
                    onComplete: { continuation.resume(with: $0) }
                ))
                task.resume()
            }
        } onCancel: {
            task.cancel()
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
        case hashMismatch(ManifestFile)
        case unreadable(ManifestFile)

        var file: ManifestFile {
            switch self {
            case .ok(let f, _), .missing(let f), .sizeMismatch(let f, _),
                 .hashMismatch(let f), .unreadable(let f):
                return f
            }
        }
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
        onLog("Expected total size: \(formatSize(manifest.totalSize))", .info)

        let results = await withTaskGroup(of: VerifyResult.self, returning: [VerifyResult].self) { group in
            let files = manifest.files
            var index = 0

            // Throttle: verify up to maxConcurrent files at a time
            for _ in 0..<min(Self.maxConcurrent, files.count) {
                let file = files[index]
                index += 1
                group.addTask {
                    await Self.verifyOneFile(file: file, installDirectory: installDirectory)
                }
            }

            var collected: [VerifyResult] = []
            collected.reserveCapacity(manifest.files.count)
            for await result in group {
                collected.append(result)
                self.incrementVerifyProgress(result: result)
                if index < files.count {
                    let file = files[index]
                    index += 1
                    group.addTask {
                        await Self.verifyOneFile(file: file, installDirectory: installDirectory)
                    }
                }
            }
            return collected
        }

        var corruptFiles: [ManifestFile] = []
        let sorted = results.sorted { $0.file.path < $1.file.path }

        for result in sorted {
            switch result {
            case .ok(let file, let size):
                onLog("OK: \(file.path) (\(formatSize(size)))", .success)
            case .missing(let file):
                onLog("MISSING: \(file.path) (expected \(formatSize(file.size)))", .error)
                corruptFiles.append(file)
            case .sizeMismatch(let file, let localSize):
                onLog("SIZE MISMATCH: \(file.path) — local: \(formatSize(localSize)), expected: \(formatSize(file.size)) (diff: \(Self.formatSizeDiff(local: localSize, expected: file.size)))", .warning)
                corruptFiles.append(file)
            case .hashMismatch(let file):
                onLog("HASH MISMATCH: \(file.path) — content differs from manifest", .warning)
                corruptFiles.append(file)
            case .unreadable(let file):
                onLog("UNREADABLE: \(file.path) — cannot read file", .error)
                corruptFiles.append(file)
            }
        }

        if corruptFiles.isEmpty {
            onLog("Verification complete: all \(manifest.files.count) files OK", .success)
        } else {
            let repairSize = corruptFiles.reduce(UInt64(0)) { $0 + $1.size }
            onLog("Verification complete: \(corruptFiles.count) file(s) need repair (\(formatSize(repairSize)) to download)", .warning)
        }

        return corruptFiles
    }

    // Nonisolated async so hashing runs on the global executor, off the actor.
    private static nonisolated func verifyOneFile(file: ManifestFile, installDirectory: URL) async -> VerifyResult {
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

        if !file.hash.isEmpty {
            guard let actualHash = try? hashFile(at: destURL) else {
                return .unreadable(file)
            }
            if actualHash != file.hash {
                return .hashMismatch(file)
            }
        }

        return .ok(file, fileSize)
    }

    private func incrementVerifyProgress(result: VerifyResult) {
        filesCompleted += 1
        if case .ok(_, let size) = result {
            downloadedBytes += Int64(size)
        }
        currentFile = result.file.path
        sendProgress()
    }

    private static func formatSizeDiff(local: UInt64, expected: UInt64) -> String {
        if local < expected {
            return "-\(formatSize(expected - local)) short"
        } else {
            return "+\(formatSize(local - expected)) over"
        }
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
