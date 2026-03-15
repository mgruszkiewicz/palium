import SwiftUI

struct ContentView: View {
    @State private var appState = AppState()
    @State private var showGPTKInstallAlert = false
    @State private var downloadTask: Task<Void, Never>?
    @Environment(\.openURL) private var openURL


    var body: some View {
        VStack(spacing: 0) {
            // Main content
            VStack(spacing: 20) {
                Text("Palium")
                    .font(.largeTitle.bold())

                if !appState.gameVersion.isEmpty {
                    Text("Palia v\(appState.gameVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                switch appState.phase {
                case .checking:
                    checkingView

                case .needsSetup(let error):
                    setupView(error: error)

                case .needsDownload:
                    downloadPromptView

                case .downloading:
                    downloadingView

                case .verifying:
                    verifyingView

                case .repairing:
                    downloadingView

                case .ready:
                    readyView

                case .launching:
                    launchingView

                case .error(let error):
                    errorView(error: error)
                }

                Spacer()
            }
            .padding(30)

            // Debug log panel
            if appState.showDebugLog {
                Divider()
                debugLogView
            }
        }
        .frame(minWidth: 500, minHeight: appState.showDebugLog ? 550 : 350)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                SettingsLink {
                    Image(systemName: "gear")
                }
                .help("Settings")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    appState.showDebugLog.toggle()
                } label: {
                    Image(systemName: appState.showDebugLog ? "terminal.fill" : "terminal")
                }
                .help("Toggle debug log")
            }
        }
        .task {
            await checkRequirements()
        }
        .alert("Game Porting Toolkit Not Installed", isPresented: $showGPTKInstallAlert) {
            Button("Download") {
                if let url = URL(string: PaliumError.gptkReleasePage) {
                                openURL(url)
                            }
            }
            Button("Retry") {
                Task { await checkRequirements() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Game Porting Toolkit is required to run Palia on macOS.\n\nDownload GPTK from \(PaliumError.gptkReleasePage) and move it to Applications directory.\n\nAfter installing, click Retry.")
        }
    }

    // MARK: - Debug Log View

    private var debugLogView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Debug Log")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") {
                    appState.clearLog()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(appState.logEntries) { entry in
                            logEntryRow(entry)
                                .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
                .onChange(of: appState.logEntries.count) { _, _ in
                    if let last = appState.logEntries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(height: 200)
        .background(.black.opacity(0.03))
    }

    private func logEntryRow(_ entry: LogEntry) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(entry.timestamp, format: .dateTime.hour().minute().second())
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)

            Image(systemName: logIcon(entry.level))
                .font(.system(size: 10))
                .foregroundStyle(logColor(entry.level))

            Text(entry.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(logColor(entry.level))
                .textSelection(.enabled)
        }
    }

    private func logIcon(_ level: LogEntry.Level) -> String {
        switch level {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.circle"
        case .success: return "checkmark.circle"
        }
    }

    private func logColor(_ level: LogEntry.Level) -> Color {
        switch level {
        case .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        case .success: return .green
        }
    }

    // MARK: - Phase Views

    private var checkingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.5)
            Text(appState.statusMessage)
                .foregroundStyle(.secondary)
        }
    }

    private func setupView(error: PaliumError) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text(error.localizedDescription)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await checkRequirements() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var downloadPromptView: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 40))
                .foregroundStyle(.blue)

            if let manifest = appState.manifest {
                Text("Download Palia (\(formatSize(manifest.totalSize)))")
                    .font(.headline)
                Text("\(manifest.files.count) files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Download Palia")
                    .font(.headline)
            }

            Button("Download") {
                startDownload()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private var downloadingView: some View {
        VStack(spacing: 12) {
            ProgressView(value: appState.downloadProgress) {
                Text(appState.isRepairing ? "Repairing..." : "Downloading...")
            }

            HStack {
                Text("\(formatSize(UInt64(appState.downloadedBytes))) / \(formatSize(UInt64(appState.totalBytes)))")
                Spacer()
                Text("\(appState.filesCompleted)/\(appState.filesTotal) files")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            // Speed graph
            if appState.speedHistory.count >= 2 {
                SpeedGraphView(samples: appState.speedHistory)
                    .frame(height: 40)
            }

            if appState.downloadSpeed > 0 {
                Text(formatSpeed(appState.downloadSpeed))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if !appState.currentFile.isEmpty {
                Text(appState.currentFile)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack {
                Text("\(Int(appState.downloadProgress * 100))%")
                    .font(.title2.monospacedDigit())
                Spacer()
                Button("Cancel") {
                    cancelDownload()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var verifyingView: some View {
        VStack(spacing: 12) {
            ProgressView(value: Double(appState.filesCompleted), total: max(Double(appState.filesTotal), 1)) {
                Text("Verifying files...")
            }

            HStack {
                Text("\(appState.filesCompleted)/\(appState.filesTotal) files checked")
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !appState.currentFile.isEmpty {
                Text(appState.currentFile)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var readyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)

            Text("Ready to Play")
                .font(.headline)

            Button("Launch Palia") {
                launchGame()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button("Verify & Repair Files") {
                Task { await verifyAndRepair() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            // Wine source info
            if let info = appState.wineInfo {
                HStack(spacing: 4) {
                    Image(systemName: info.source == .gptk ? "cup.and.saucer" : "wineglass")
                        .font(.system(size: 9))
                    Text(info.source.rawValue)
                    Text("—")
                    Text(info.wineBinaryURL.path)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
        }
    }

    private var launchingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Game is running...")
                .foregroundStyle(.secondary)
            Button("Stop") {
                appState.gameProcess?.terminate()
                appState.gameProcess = nil
                appState.phase = .ready
            }
            .buttonStyle(.bordered)
        }
    }

    private func errorView(error: PaliumError) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "xmark.circle")
                .font(.system(size: 40))
                .foregroundStyle(.red)
            Text(error.localizedDescription)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await checkRequirements() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Actions

    private func checkRequirements() async {
        appState.phase = .checking
        appState.statusMessage = "Checking system requirements..."
        appState.log("Checking system requirements...")

        // Detect Wine environment (GPTK2 or Whisky)
        do {
            appState.statusMessage = "Detecting Wine environment..."
            let info = try await WineManager.detect(preferredSource: LaunchSettings.shared.wineSource)
            appState.wineInfo = info
            appState.log("Wine detected via \(info.source.rawValue)", level: .success)
            appState.log("Wine binary: \(info.wineBinaryURL.path)", level: .info)
            appState.log("Prefix: \(info.prefixPath.path)", level: .info)
            appState.log("Wine user: \(info.wineUsername)", level: .info)

            // Install VC++ runtime if not already present in prefix
            if !WineManager.isVCRuntimeInstalled(info: info) {
                appState.statusMessage = "Installing VC++ runtime..."
                appState.log("VC++ runtime not found in prefix, installing...")
                do {
                    try await WineManager.installVCRuntime(info: info)
                    appState.log("VC++ runtime installed", level: .success)
                } catch {
                    appState.log("VC++ runtime install failed: \(error.localizedDescription) — game may still work", level: .warning)
                }
            } else {
                appState.log("VC++ runtime already installed", level: .info)
            }
        } catch let error as PaliumError where error.isWineNotFound {
            appState.log("Wine not found", level: .error)
            showGPTKInstallAlert = true
            appState.phase = .needsSetup(error)
            return
        } catch let error as PaliumError {
            appState.log("Setup failed: \(error.localizedDescription)", level: .error)
            appState.phase = .needsSetup(error)
            return
        } catch {
            appState.log("Setup failed: \(error.localizedDescription)", level: .error)
            appState.phase = .needsSetup(.wineNotFound)
            return
        }

        // Fetch current game version
        appState.statusMessage = "Checking game version..."
        appState.log("Fetching current game version from CDN...")
        do {
            let channelInfo = try await CDNClient.fetchVersion()
            appState.gameVersion = channelInfo.version
            appState.log("Game version: \(channelInfo.version) (channel: \(channelInfo.channel))", level: .success)
        } catch {
            appState.log("CDN error: \(error.localizedDescription)", level: .error)
            appState.phase = .error(.cdnError(error.localizedDescription))
            return
        }

        // Download and parse manifest
        appState.statusMessage = "Downloading manifest..."
        appState.log("Downloading manifest...")
        do {
            let manifestData = try await CDNClient.downloadManifest(version: appState.gameVersion)
            appState.log("Manifest downloaded: \(formatSize(UInt64(manifestData.count)))")
            let manifest = try CDNClient.parseManifest(manifestData)
            appState.manifest = manifest
            appState.log("Manifest parsed: \(manifest.files.count) files, \(formatSize(manifest.totalSize)) total", level: .success)
        } catch {
            appState.log("Manifest error: \(error.localizedDescription)", level: .error)
            appState.phase = .error(.manifestParseFailed(error.localizedDescription))
            return
        }

        // Check if game is already installed
        if let info = appState.wineInfo, WineManager.isGameInstalled(info: info) {
            appState.log("Game found at \(info.gameInstallPath.path)", level: .success)
            appState.phase = .ready
        } else {
            appState.log("Game not installed — download required", level: .warning)
            appState.phase = .needsDownload
        }
    }

    private func startDownload() {
        guard let manifest = appState.manifest, let info = appState.wineInfo else { return }

        appState.phase = .downloading
        appState.showDebugLog = true
        appState.totalBytes = Int64(manifest.totalSize)
        appState.resetSpeed()

        let downloadManager = makeDownloadManager()

        downloadTask = Task {
            do {
                try await downloadManager.downloadAll(
                    manifest: manifest,
                    version: appState.gameVersion,
                    installDirectory: info.gameInstallPath
                )
                appState.phase = .ready
            } catch is CancellationError {
                appState.log("Download cancelled", level: .warning)
                appState.phase = .needsDownload
            } catch let error as PaliumError {
                appState.log("Download failed: \(error.localizedDescription)", level: .error)
                appState.phase = .error(error)
            } catch {
                appState.log("Download failed: \(error.localizedDescription)", level: .error)
                appState.phase = .error(.downloadFailed(path: "", reason: error.localizedDescription))
            }
            downloadTask = nil
        }
    }

    private func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        appState.log("Cancelling download...", level: .warning)
    }

    private func launchGame() {
        guard let info = appState.wineInfo else { return }

        let settings = LaunchSettings.shared
        let options = GameLauncher.LaunchOptions(
            metalHUD: settings.metalHUD,
            useAllCores: settings.useAllCores
        )
        appState.log("Launching game (DX11, Metal HUD: \(options.metalHUD ? "ON" : "OFF"))...")
        do {
            let process = try GameLauncher.launch(info: info, options: options)
            appState.gameProcess = process
            appState.phase = .launching
            appState.log("Game process started (PID: \(process.processIdentifier))", level: .success)

            // Monitor process in background
            Task.detached {
                process.waitUntilExit()
                let status = process.terminationStatus
                await MainActor.run {
                    appState.log("Game exited with status \(status)", level: status == 0 ? .info : .warning)
                    appState.gameProcess = nil
                    appState.phase = .ready
                }
            }
        } catch let error as PaliumError {
            appState.log("Launch failed: \(error.localizedDescription)", level: .error)
            appState.phase = .error(error)
        } catch {
            appState.log("Launch failed: \(error.localizedDescription)", level: .error)
            appState.phase = .error(.launchFailed(error.localizedDescription))
        }
    }

    private func verifyAndRepair() async {
        guard let manifest = appState.manifest, let info = appState.wineInfo else { return }

        appState.phase = .verifying
        appState.downloadProgress = 0
        appState.showDebugLog = true
        appState.clearLog()

        let verifyManager = makeDownloadManager()

        let corruptFiles = await verifyManager.verifyFiles(
            manifest: manifest,
            installDirectory: info.gameInstallPath,
            onLog: { [appState] message, level in
                Task { @MainActor in
                    appState.log(message, level: level)
                }
            }
        )

        if corruptFiles.isEmpty {
            appState.statusMessage = "All files verified successfully"
            appState.phase = .ready
            return
        }

        // Repair corrupt/missing files
        appState.phase = .repairing
        appState.downloadProgress = 0
        appState.resetSpeed()

        let repairManager = makeDownloadManager()

        do {
            try await repairManager.repairFiles(
                files: corruptFiles,
                version: appState.gameVersion,
                installDirectory: info.gameInstallPath
            )
            appState.phase = .ready
        } catch let error as PaliumError {
            appState.log("Repair failed: \(error.localizedDescription)", level: .error)
            appState.phase = .error(error)
        } catch {
            appState.log("Repair failed: \(error.localizedDescription)", level: .error)
            appState.phase = .error(.downloadFailed(path: "", reason: error.localizedDescription))
        }
    }

    private func makeDownloadManager() -> DownloadManager {
        DownloadManager(
            onProgress: { [appState] progress in
                Task { @MainActor in
                    appState.downloadProgress = progress.fraction
                    appState.downloadedBytes = progress.bytesDownloaded
                    appState.totalBytes = progress.totalBytes
                    appState.currentFile = progress.currentFile
                    appState.filesCompleted = progress.filesCompleted
                    appState.filesTotal = progress.filesTotal
                    appState.updateSpeed(currentBytes: progress.bytesDownloaded)
                }
            },
            onLog: { [appState] message, level in
                Task { @MainActor in
                    appState.log(message, level: level)
                }
            }
        )
    }

    // MARK: - Helpers

    private func formatSpeed(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1024 * 1024 * 1024 {
            return String(format: "%.1f GB/s", bytesPerSecond / (1024 * 1024 * 1024))
        } else if bytesPerSecond >= 1024 * 1024 {
            return String(format: "%.1f MB/s", bytesPerSecond / (1024 * 1024))
        } else if bytesPerSecond >= 1024 {
            return String(format: "%.0f KB/s", bytesPerSecond / 1024)
        }
        return String(format: "%.0f B/s", bytesPerSecond)
    }

}
