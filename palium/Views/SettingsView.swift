import SwiftUI

struct SettingsView: View {
    @Bindable private var settings = LaunchSettings.shared
    @Bindable private var updater = UpdaterService.shared

    var body: some View {
        TabView {
            wineTab
                .tabItem {
                    Label("Wine", systemImage: "cup.and.saucer")
                }

            graphicsTab
                .tabItem {
                    Label("Graphics", systemImage: "memorychip")
                }

            performanceTab
                .tabItem {
                    Label("Performance", systemImage: "gauge.with.dots.needle.67percent")
                }

            updatesTab
                .tabItem {
                    Label("Updates", systemImage: "arrow.down.circle")
                }

            TroubleshootingTab()
                .tabItem {
                    Label("Troubleshoot", systemImage: "wrench.and.screwdriver")
                }
        }
        .frame(width: 500, height: 380)
    }

    // MARK: - Updates Tab

    private var updatesTab: some View {
        Form {
            Toggle("Check for updates automatically", isOn: $updater.automaticallyChecksForUpdates)
            Text("Palium checks for a new version once a day and asks before installing anything.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Current version \(appVersion)")
                        .font(.caption)
                    if let last = updater.lastUpdateCheckDate {
                        Text("Last checked \(last.formatted(.relative(presentation: .named)))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Button("Check Now") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }
        }
        .formStyle(.grouped)
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    // MARK: - Wine Tab

    private var wineTab: some View {
        Form {
            let engineInstalled = WineEngine.isInstalled()
            statusRow(
                label: "Wine engine",
                ok: engineInstalled,
                detail: engineInstalled ? WineEngine.current.displayName : "Downloaded on next start"
            )

            let d3dMetal = D3DMetal.findSource()
            statusRow(
                label: "D3DMetal",
                ok: d3dMetal != nil,
                detail: d3dMetal.map { "\($0.version ?? "?") from Game Porting Toolkit" } ?? "Game Porting Toolkit not found"
            )

            HStack {
                Text("Wine Prefix")
                    .font(.caption)
                Spacer()
                Button("Open in Finder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: WineManager.prefix.path)
                }
                .controlSize(.small)
            }

            if d3dMetal == nil {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Label("Game Porting Toolkit is required", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("Palium runs Palia on its own Wine 11 engine and uses Apple's D3DMetal from Game Porting Toolkit for graphics. Install it with Homebrew:")
                        .font(.caption)
                    HStack {
                        Text("brew install --cask game-porting-toolkit")
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                "brew tap Gcenx/homebrew-wine && brew install --cask game-porting-toolkit",
                                forType: .string
                            )
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func statusRow(label: String, ok: Bool, detail: String) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(ok ? .green : .secondary)
                .font(.caption)
            Text(label)
                .font(.caption)
            Spacer()
            Text(detail)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: - Graphics Tab

    private var graphicsTab: some View {
        Form {
            Picker("Renderer", selection: $settings.graphicsAPI) {
                ForEach(LaunchSettings.GraphicsAPI.allCases, id: \.self) { api in
                    Text(api.rawValue).tag(api)
                }
            }
            .pickerStyle(.segmented)
            Text("DirectX 11 is the tested default. DirectX 12 is experimental: Unreal Engine 5 can then prepare shaders ahead of time instead of mid-game, which may reduce stutter. If the game does not start, switch back to DirectX 11.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Metal Performance HUD", isOn: $settings.metalHUD)
            Text("Show an FPS counter and GPU usage overlay powered by Metal. Useful for monitoring performance.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    // MARK: - Performance Tab

    private var performanceTab: some View {
        Form {
            Toggle("Use All CPU Cores", isOn: $settings.useAllCores)
            Text("Passes -USEALLAVAILABLECORES to Unreal Engine, enabling multi-core task scheduling.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
