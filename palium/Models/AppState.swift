import Foundation
import Observation

struct LogEntry: Identifiable, Sendable {
    enum Level: Sendable {
        case info, warning, error, success
    }

    let id = UUID()
    let timestamp = Date()
    let level: Level
    let message: String
}

@MainActor
@Observable
class AppState {

    enum Phase: Sendable {
        case checking
        case needsSetup(PaliumError)
        case needsWineSetup
        case settingUpWine
        case needsDownload
        case needsUpdate
        case downloading
        case verifying
        case repairing
        case ready
        case launching
        case error(PaliumError)
    }

    var phase: Phase = .checking
    var statusMessage: String = "Checking requirements..."

    // Download progress
    var downloadProgress: Double = 0
    var downloadedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var currentFile: String = ""
    var filesCompleted: Int = 0
    var filesTotal: Int = 0
    var downloadSpeed: Double = 0 // bytes per second
    var speedHistory: [Double] = [] // recent speed samples for graph

    // Speed tracking (not observed by UI directly)
    private static let maxSpeedSamples = 60
    private var _speedLastBytes: Int64 = 0
    private var _speedLastTime: Date = .now

    // Wine setup progress
    var setupStepDescription: String = ""

    // Debug log
    var showDebugLog: Bool = false
    var logEntries: [LogEntry] = []

    // Discovered state
    var wineInfo: WineInfo?
    var manifest: UpdateManifest?
    var gameVersion: String = ""
    var localGameVersion: String = ""
    var gameProcess: Process?

    var isRepairing: Bool {
        if case .repairing = phase { return true }
        return false
    }

    private static let maxLogEntries = 1000

    /// Log file at ~/Library/Logs/palium/palium.log
    static let logFileURL: URL = {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/palium")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        return logsDir.appendingPathComponent("palium.log")
    }()

    private nonisolated static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    func log(_ message: String, level: LogEntry.Level = .info) {
        let entry = LogEntry(level: level, message: message)
        logEntries.append(entry)
        if logEntries.count > Self.maxLogEntries {
            logEntries.removeFirst(logEntries.count - Self.maxLogEntries)
        }

        let prefix = switch level {
        case .info: "INFO"
        case .warning: "WARN"
        case .error: "ERROR"
        case .success: "OK"
        }
        let line = "[\(Self.dateFormatter.string(from: entry.timestamp))] [\(prefix)] \(message)\n"
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: Self.logFileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                try? data.write(to: Self.logFileURL)
            }
        }
    }

    func clearLog() {
        logEntries.removeAll()
    }

    func updateSpeed(currentBytes: Int64) {
        let now = Date.now
        let elapsed = now.timeIntervalSince(_speedLastTime)
        guard elapsed >= 0.5 else { return }

        let delta = currentBytes - _speedLastBytes
        let instantSpeed = Double(delta) / elapsed

        // Exponential moving average (smooth out jumps)
        if downloadSpeed < 1 {
            downloadSpeed = instantSpeed
        } else {
            downloadSpeed = downloadSpeed * 0.6 + instantSpeed * 0.4
        }

        _speedLastBytes = currentBytes
        _speedLastTime = now

        speedHistory.append(downloadSpeed)
        if speedHistory.count > Self.maxSpeedSamples {
            speedHistory.removeFirst(speedHistory.count - Self.maxSpeedSamples)
        }
    }

    func resetSpeed() {
        downloadSpeed = 0
        speedHistory.removeAll()
        _speedLastBytes = 0
        _speedLastTime = .now
    }
}
