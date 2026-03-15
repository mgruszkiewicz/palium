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
                    label: "GPTK (Homebrew)",
                    available: WineManager.isGPTKInstalled,
                    path: gptkPath
                )
                detectedInfoRow(
                    label: "Whisky",
                    available: WineManager.isWhiskyInstalled,
                    path: whiskyPath
                )
            }

            if !WineManager.isGPTKInstalled && !WineManager.isWhiskyInstalled {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Label("No Wine environment found", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("Install via Homebrew:")
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
        case .whisky: WineManager.isWhiskyInstalled
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
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch settings.wineSource {
        case .whisky:
            let bottlesDir = home.appendingPathComponent(
                "Library/Containers/com.isaacmarovitz.Whisky/Bottles"
            )
            if let contents = try? FileManager.default.contentsOfDirectory(
                at: bottlesDir, includingPropertiesForKeys: nil
            ), let first = contents.first {
                return first.path
            }
            return bottlesDir.path
        case .gptk, .auto:
            return home.appendingPathComponent(
                "Library/Application Support/com.palium/prefix"
            ).path
        }
    }

    private var gptkPath: String? {
        WineManager.findGPTKBinary()?.path
    }

    private var whiskyPath: String? {
        WineManager.findWhiskyBinary()?.path
    }

    // MARK: - Graphics Tab

    private var graphicsTab: some View {
        Form {
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
            Text("Passes -USEALLAVAILABLECORES to Unreal Engine 4, enabling multi-core task scheduling.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
