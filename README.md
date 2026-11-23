# Palium

![Screenshot showing Palia game running on a MacOS, with Palium launcher on top of it and with METAL HUD enabled](https://i.issei.space/x8IaBwFH.jpg)

A native macOS launcher for [Palia](https://palia.com), built with Swift and SwiftUI. Palium downloads, updates, and launches the Windows version of Palia on macOS using Wine 11 and D3DMetal from Apple's Game Porting Toolkit (GPTK).

## Features

- **Managed Wine engine** — downloads its own Wine 11 build on first start and uses D3DMetal from your GPTK install for DirectX
- **DX11 and DX12 support** — pick the renderer in Settings → Graphics. DX12 is experimental, but in my testing it looks stable enough.
- **Game download & updates**
- **File verification & repair** — checks all installed files against the manifest and re-downloads any corrupt or missing ones
- **VC++ runtime setup** — automatically installs the Microsoft Visual C++ redistributable into the Wine prefix
- **Settings window** — engine and D3DMetal status, renderer and performance toggles, open Wine prefix in Finder

## How to setup?
1. Download the latest release from [Release page](https://github.com/mgruszkiewicz/palium/releases).
2. Make sure that you have Game Porting Toolkit installed in Application directory. If not, please download the latest release (.tar.xz file) from [Gcenx/game-porting-toolkit releases](https://github.com/Gcenx/game-porting-toolkit/releases) and extract the application to Application directory. Palium uses only its D3DMetal libraries; the game itself runs on Palium's own Wine.
3. Launch the Palium launcher. On the first start it downloads the Wine engine (about 170 MB) and creates the Wine prefix, which takes a minute or two. Then click on "Download Palia", and wait for game to install.

### Updating from Palium 1.1 or older
Older versions ran the game on GPTK's Wine 7.7, which can't run Palia since its update to Unreal Engine 5.7. After updating, Palium moves your installed game into the new Wine 11 prefix on the first start; nothing is downloaded again. Quit Palia before updating: the move waits until the game is closed. The old prefix is kept until you remove it with Settings → Troubleshooting → "Remove Old GPTK Prefix".

[Whisky](https://github.com/Whisky-App/Whisky) is no longer supported as a Wine source.

## Requirements

- macOS 15.7 or later on Apple Silicon
- **Game Porting Toolkit** (required, for D3DMetal; tested with GPTK 3.0): download from [Gcenx/game-porting-toolkit releases](https://github.com/Gcenx/game-porting-toolkit/releases) and place in `/Applications/`. A Homebrew GPTK install (`wine64` in `/opt/homebrew/bin` or `/usr/local/bin`) works too.
- About 1 GB of free space for the engine and prefix, plus the game itself

## Troubleshooting
If you have problem with game launch, you can open a Settings page (the gear icon in right top corner, or press `⌘+,`) -> Troubleshooting tab -> Run Diagnostics to validate that the environment was setup correctly. 
You can also run "Verify & Repair Files" below the "Launch Game" button to validate downloaded files or resume an interrupted download.

- **Paste in the game** is `Ctrl+V`, as on Windows. Palium maps both Command keys to Ctrl, so `⌘+V` works too.
- **Skipping the intro video**: the game asks for Delete, which on a Mac keyboard is `Fn+Backspace`. Clicking the button works too.
- **DirectX 12** takes longer to reach gameplay on the first start, while it compiles shaders. If it doesn't start, switch back to DirectX 11 in Settings → Graphics.
- **Performance numbers**: `python3 scripts/palia_perf.py` summarises the frame-time telemetry Palia writes to its log, so you can compare sessions (e.g. DirectX 11 against DirectX 12). Run it after each session, because Palia overwrites its log on start.

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

1. **Find D3DMetal** — locates GPTK and links its D3DMetal modules (`d3d11`, `d3d12`, `dxgi`, …) into a folder of their own
2. **Install the engine** — downloads [Sikarugir's](https://github.com/Sikarugir-App/Engines) Wine 11.0 build (from Palium's own release, falling back to the original), checks its SHA-256 and unpacks it
3. **Initialize prefix** — runs `wineboot --init` if the Wine prefix doesn't exist yet, then moves an existing game from an older prefix into it
4. **Install VC++ runtime** — downloads Microsoft redistributables and installs them into the prefix; sets Wine registry keys and DLL overrides so UE4 skips its prerequisite check
5. **Fetch manifest** — queries the Palia CDN for the current game version, downloads and parses the FlexBuffers manifest
6. **Download game** — streams all game files concurrently (4 parallel downloads), verifies SHA-256 hashes
7. **Launch** — starts `PaliaClient.exe` on the engine with D3DMetal, msync, and the chosen DirectX version

## License

This project is not affiliated with Singularity 6 or Palia. Use at your own risk.

Wine is licensed under the LGPL 2.1 or later. The Wine engine Palium downloads is built by the [Sikarugir](https://github.com/Sikarugir-App/Engines) project from CodeWeavers' CrossOver sources; D3DMetal is part of Apple's Game Porting Toolkit and is not redistributed by Palium.
