# Palium

A native macOS launcher for [Palia](https://palia.com), built with Swift and SwiftUI. Palium downloads, updates, and launches the Windows version of Palia on macOS using Wine and Apple's Game Porting Toolkit (GPTK).

## Features

- **Automatic Wine detection** — supports GPTK (Homebrew / prebuild) and Whisky, with manual source selection
- **Game download & updates** — fetches the latest version from the Palia CDN, downloads all game files with concurrent streaming, and verifies integrity via SHA-256
- **File verification & repair** — checks all installed files against the manifest and re-downloads any corrupt or missing ones
- **VC++ runtime setup** — automatically installs the Microsoft Visual C++ redistributable into the Wine prefix
- **Real-time progress** — download speed graph, per-file progress, and a debug log panel
- **Settings window** — Wine source picker, graphics/performance toggles, open Wine prefix in Finder

## Requirements

- macOS 14+ (Sonoma) on Apple Silicon
- **Game Porting Toolkit** (recommended): download from [Gcenx/game-porting-toolkit releases](https://github.com/Gcenx/game-porting-toolkit/releases) and place in `/Applications/`

## How to setup?
1. Download the latest release from [Release page](https://github.com/mgruszkiewicz/palium/releases)
2. Make sure that you have Game Porting Toolkit installed in Application directory. If not, please download the .tar.xz file from [Gcenx/game-porting-toolkit releases](https://github.com/Gcenx/game-porting-toolkit/releases) and extract the application to Application directory.
3. Launch the Palium launcher. Wait for initial setup to finish, the launcher will check for updates. Click on "Download Palia", and wait for game to install.

## Troubleshooting
If you have problem with game launch, you can open a Settings page (the gear icon in right top corner, or press `⌘+,`) -> Troubleshooting tab -> Run Diagnostics to validate that the environment was setup correctly. 
You can also ran "Verify & Repair Files" below the "Launch Game" button to validate downloaded file/resume interrputed download.

## Building

Open `palium.xcodeproj` in Xcode 16+ and build the `palium` scheme:

```
xcodebuild -project palium.xcodeproj -scheme palium -configuration Debug build
```

The app is **not sandboxed** (required for Wine JIT and process launching). Entitlements include:
- `com.apple.security.cs.allow-jit`
- `com.apple.security.cs.disable-library-validation`
- `com.apple.security.network.client`


## How it works

1. **Detect Wine** — finds a usable `wine64` binary (GPTK paths, Whisky paths, or app bundle)
2. **Initialize prefix** — runs `wineboot --init` if the Wine prefix doesn't exist yet
3. **Install VC++ runtime** — downloads Microsoft redistributables and installs them into the prefix; sets Wine registry keys and DLL overrides so UE4 skips its prerequisite check
4. **Fetch manifest** — queries the Palia CDN for the current game version, downloads and parses the FlexBuffers manifest
5. **Download game** — streams all game files concurrently (4 parallel downloads), verifies SHA-256 hashes
6. **Launch** — starts `wine64 PaliaClient.exe` with the configured DirectX mode, environment variables, and UE4 flags

## License

This project is not affiliated with Singularity 6 or Palia. Use at your own risk.
