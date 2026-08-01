import SwiftUI

struct TroubleshootingTab: View {
    @State private var results: [WineManager.DiagnosticResult] = []
    @State private var logEntries: [LogEntry] = []
    @State private var isRunning = false
    @State private var isReinstallingVC = false
    @State private var hasRun = false

    var body: some View {
        VStack(spacing: 0) {
            if !hasRun && !isRunning {
                promptView
            } else if isRunning {
                runningView
            } else {
                resultsView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Views

    private var promptView: some View {
        VStack(spacing: 12) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Run diagnostics to check your Wine environment, VC++ runtime, and registry entries.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Button("Run Diagnostics") {
                Task { await runDiagnostics() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var runningView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.2)
            Text(isReinstallingVC ? "Reinstalling VC++ Runtime..." : "Running diagnostics...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var resultsView: some View {
        VStack(spacing: 0) {
            // Summary bar
            HStack {
                let passed = results.filter(\.passed).count
                let total = results.count
                Image(systemName: passed == total ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(passed == total ? .green : .orange)
                Text("\(passed)/\(total) checks passed")
                    .font(.caption.bold())
                Spacer()
                Button("Re-run") {
                    Task { await runDiagnostics() }
                }
                .controlSize(.small)
                .disabled(isRunning)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.03))

            Divider()

            // Results + log list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(results) { result in
                            diagnosticRow(result)
                            Divider().padding(.leading, 28)
                        }

                        if !logEntries.isEmpty {
                            Text("Install Log")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.top, 8)
                                .padding(.bottom, 4)

                            ForEach(logEntries) { entry in
                                logRow(entry)
                                    .id(entry.id)
                            }
                        }
                    }
                }
                .onChange(of: logEntries.count) { _, _ in
                    if let last = logEntries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            Divider()

            // Actions
            HStack(spacing: 8) {
                Button("Reinstall VC++ Runtime") {
                    Task { await reinstallVCRuntime() }
                }
                .controlSize(.small)
                .disabled(isReinstallingVC)

                if isReinstallingVC {
                    ProgressView()
                        .scaleEffect(0.6)
                }

                Spacer()

                Button("Delete Wine Prefix") {
                    deletePrefix()
                }
                .controlSize(.small)
                .foregroundStyle(.red)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func diagnosticRow(_ result: WineManager.DiagnosticResult) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(result.passed ? .green : .red)
                .font(.system(size: 12))
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 1) {
                Text(result.name)
                    .font(.system(size: 11, weight: .medium))
                Text(result.detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(result.passed ? .secondary : .orange)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func logRow(_ entry: LogEntry) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: logIcon(entry.level))
                .font(.system(size: 9))
                .foregroundStyle(logColor(entry.level))
                .padding(.top, 2)

            Text(entry.message)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(logColor(entry.level))
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 1)
    }

    private func logIcon(_ level: LogEntry.Level) -> String {
        switch level {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.circle"
        case .success: "checkmark.circle"
        }
    }

    private func logColor(_ level: LogEntry.Level) -> Color {
        switch level {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        case .success: .green
        }
    }

    // MARK: - Actions

    private func runDiagnostics() async {
        isRunning = true
        hasRun = true

        guard let info = try? await WineManager.detect(
            preferredSource: LaunchSettings.shared.wineSource
        ) else {
            results = [
                WineManager.DiagnosticResult(
                    name: "Wine Detection",
                    passed: false,
                    detail: "No Wine environment found — install GPTK or Whisky first"
                )
            ]
            isRunning = false
            return
        }

        results = await WineManager.runDiagnostics(info: info)
        isRunning = false
    }

    private func reinstallVCRuntime() async {
        isReinstallingVC = true
        logEntries = []

        guard let info = try? await WineManager.detect(
            preferredSource: LaunchSettings.shared.wineSource
        ) else {
            logEntries.append(LogEntry(level: .error, message: "Wine detection failed"))
            isReinstallingVC = false
            return
        }

        do {
            try await WineManager.installVCRuntime(info: info) { message, level in
                Task { @MainActor in
                    logEntries.append(LogEntry(level: level, message: message))
                }
            }
            logEntries.append(LogEntry(level: .success, message: "VC++ runtime installation finished"))
        } catch {
            logEntries.append(LogEntry(level: .error, message: "Installation failed: \(error.localizedDescription)"))
        }

        isReinstallingVC = false
        await runDiagnostics()
    }

    private func deletePrefix() {
        results = []
        logEntries = []
        hasRun = false

        // File removal and wineserver shutdown run off the main thread.
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: WineManager.gptkPrefix)
            // Also kill wineserver so it doesn't hold stale state
            let binDir = (WineManager.findGPTKBinary() ?? WineManager.findWhiskyBinary())?.deletingLastPathComponent()
            if let wineserver = binDir?.appendingPathComponent("wineserver") {
                let p = Process()
                p.executableURL = wineserver
                p.arguments = ["-k"]
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                try? p.run()
                p.waitUntilExit()
            }
        }
    }
}
