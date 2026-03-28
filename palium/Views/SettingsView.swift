import SwiftUI

struct SettingsView: View {
    @Bindable private var settings = LaunchSettings.shared

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

            TroubleshootingTab()
                .tabItem {
                    Label("Troubleshoot", systemImage: "wrench.and.screwdriver")
                }
        }
        .frame(width: 500, height: 380)
    }

    // MARK: - Wine Tab

    private var wineTab: some View {
        Form {
            Picker("Wine Source", selection: $settings.wineSource) {
                ForEach(LaunchSettings.WineSource.allCases, id: \.self) { source in
                    HStack {
                        Text(source.rawValue)
                        if source != .auto {
                            availabilityBadge(for: source)
                        }
                    }
                    .tag(source)
                }
            }
            .pickerStyle(.radioGroup)

            HStack {
                Text("Wine Prefix")
                    .font(.caption)
                Spacer()
                Button("Open in Finder") {
                    let prefix = prefixPath
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: prefix)
                }
                .controlSize(.small)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Detected Environment")
                    .font(.headline)

                detectedInfoRow(
                    label: "Wine Staging + DXMT",
                    available: WineManager.isWineStagingInstalled && WineManager.isDXMTInstalled,
                    path: wineStagingPath
                )
                detectedInfoRow(
                    label: "GPTK (Homebrew)",
                    available: WineManager.isGPTKInstalled,
                    path: gptkPath
                )
            }

            if !WineManager.isWineStagingInstalled && !WineManager.isGPTKInstalled {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Label("No Wine environment found", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("Palium will download Wine Staging + DXMT automatically on next launch.")
                        .font(.caption)
                    Text("Or install GPTK via Homebrew:")
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

    @ViewBuilder
    private func availabilityBadge(for source: LaunchSettings.WineSource) -> some View {
        let available: Bool = switch source {
        case .gptk: WineManager.isGPTKInstalled
        case .wineStaging: WineManager.isWineStagingInstalled && WineManager.isDXMTInstalled
        case .auto: true
        }

        if available {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        } else {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        }
    }

    private func detectedInfoRow(label: String, available: Bool, path: String?) -> some View {
        HStack {
            Image(systemName: available ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(available ? .green : .secondary)
                .font(.caption)
            Text(label)
                .font(.caption)
            Spacer()
            if let path {
                Text(path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Not found")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var prefixPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.palium/prefix")
            .path
    }

    private var gptkPath: String? {
        WineManager.findGPTKBinary()?.path
    }

    private var wineStagingPath: String? {
        WineManager.isWineStagingInstalled ? WineManager.wineStagingBinaryPath().path : nil
    }

    // MARK: - Graphics Tab

    private var graphicsTab: some View {
        Form {
            Toggle("Metal Performance HUD", isOn: $settings.metalHUD)
            Text("Show an FPS counter and GPU usage overlay powered by Metal. Useful for monitoring performance.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Toggle("DXMT Debug Logging", isOn: $settings.enableDXMTDebug)
            Text("Log Wine DLL loading to verify DXMT translation layer is active. Check the debug log after launch for [Wine] entries showing d3d11.dll / dxgi.dll load paths.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    // MARK: - Performance Tab

    private var performanceTab: some View {
        Form {
            Toggle("Use All CPU Cores", isOn: $settings.useAllCores)
            Text("Passes -USEALLAVAILABLECORES to Unreal Engine 4, enabling multi-core task scheduling.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
