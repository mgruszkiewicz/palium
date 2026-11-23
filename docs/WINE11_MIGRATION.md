# Plan: move Palium to Wine 11

Status: steps 1–4 implemented on 2026-11-23 (engine, D3DMetal links, prefix, migration, UI); not yet tested end to end through Sparkle. The engine mirror (step 5) is not published yet.

## Why

Palia's 2026-11-23 update moved the game from Unreal Engine 5.5.4 to 5.7.4. On the
Wine that Palium uses today (Gcenx GPTK 3.0-3, which is Wine 7.7), the game now
crashes about 50 seconds after start, every time, at the same instruction in
`libcef.dll` (exception `0x80000003`), with both the old and the current launch
settings. On Sikarugir's Wine 11.0 engine, with the same D3DMetal 3.0 taken from
the GPTK app, the game starts, logs in and plays (tested for about 9 minutes, 60 FPS,
see `scripts/palia_perf.py`). So moving is required, not optional.

Wine 11 also brings msync (GPTK's Wine has only esync) and is the base that
Recall's Wine fixes are written for, which matters for later performance work.

## Target layout

```text
~/Library/Application Support/com.palium/
  engines/wine-11.0_1/wswine.bundle/   Sikarugir engine, verified by SHA-256
  d3dmetal/lib/                        links to the user's GPTK D3DMetal only
    external -> <GPTK>/lib/external
    wine/x86_64-windows/{d3d10,d3d11,d3d12,dxgi,nvapi64,nvngx-on-metalfx}.dll
    wine/x86_64-unix/{same}.so
  prefix-w11/                          new Wine 11 prefix
    drive_c/users/<macOS user>/AppData/Local/Palia/   the game, moved here
  prefix/                              old GPTK prefix, kept until the user removes it
```

The D3DMetal folder must hold only D3DMetal's own modules: the GPTK app's
`lib/wine` contains all of Wine 7.7, and prepending it makes Wine 11 fail with
`could not load kernel32.dll` (seen in testing).

## Launch environment

Tested on 2026-11-23 (`try_wine11.sh`):

| Variable | Value |
|---|---|
| `WINEPREFIX` | `prefix-w11` |
| `WINEMSYNC`, `WINEESYNC` | `1` (Whisky notes D3DMetal checks for esync) |
| `SikarugirAppWine11` | `1` (the engine expects it outside Sikarugir's launcher) |
| `WINEDLLPATH_D3DMETAL`, `WINEDLLPATH_PREPEND` | `d3dmetal/lib/wine` |
| `CX_APPLEGPTK_LIBD3DSHARED_PATH` | `d3dmetal/lib/external/libd3dshared.dylib` |
| `DYLD_FALLBACK_LIBRARY_PATH` | `d3dmetal/lib/external:<GPTK>/lib:/usr/lib` |
| `WINEDLLOVERRIDES` | `dxgi,d3d9,d3d10core,d3d11,d3d12=b;<VC++ DLLs>=n,b` |

Same rule as today: every Wine process Palium starts (wineboot, reg, installers,
the game) uses the same base environment, so the sync settings always match the
running wineserver.

Prefix settings written once at creation (`HKCU\Software\Wine\Mac Driver`):
`LeftCommandIsCtrl=y`, `RightCommandIsCtrl=y`, so Cmd+C/V work in game.

## Components

1. **`EngineManager`** (new): download the engine tarball, check its SHA-256,
   extract it with `tar` into `engines/<name>.partial`, then rename to the final
   folder. A folder without the rename never counts as installed. Source URL:
   - primary: a copy attached to a Palium GitHub release (`runtime-wine-11.0_1`),
     so Sikarugir removing or replacing the asset can't break installs;
   - fallback: `https://github.com/Sikarugir-App/Engines/releases/download/v1.0/WS12WineSikarugir11.0_1.tar.xz`.
   - pinned SHA-256 `67e29fb3d74f363af39c69ba11f9b13a79812c5db07cf4748672658e4a200a0e`,
     159 MB download, 510 MB extracted, ad-hoc signed, needs macOS 14+.
2. **`D3DMetalLocator`** (new): find GPTK (`/Applications/Game Porting Toolkit.app`,
   then Homebrew's `<wine64>/../lib`), check that `lib/external/D3DMetal.framework`,
   `libd3dshared.dylib` and the six module pairs exist, and (re)create the
   `d3dmetal/lib` links. Run on every start, because the user may move or update GPTK.
   Report the D3DMetal version from the framework's `Info.plist`.
3. **`WineManager`**: build `WineInfo` from the engine and `prefix-w11`. Create the
   prefix with `wineboot --init` (`WINEDLLOVERRIDES=mscoree,mshtml=` during init so
   no Mono/Gecko dialog), then write the Mac Driver keys. The Wine user in a new
   prefix is the macOS user name, read the same way as today (`Volatile Environment`).
4. **`PrefixMigration`** (new): moves an existing install over (next section).
5. **VC++ check fix**: `isVCRuntimeInstalled` treats any DLL over 10 KB as Microsoft's,
   but Wine's own copies in `system32` pass that test (the current prefix has
   only Wine's). Detect Wine's `Wine builtin DLL` marker instead, and keep the
   registry entries the game's prerequisite check reads.
6. **One engine only.** Palium runs everything on this one Wine 11 engine. Whisky
   support is removed: its detection, paths, `WineInfo.Source.whisky` and the Wine
   Source picker (GPTK/Whisky/Automatic). GPTK stays required, but only as the
   D3DMetal source; its Wine is no longer used.
7. **Settings**: Keep the DirectX 11/12 and Metal HUD settings.
   Add a Troubleshooting row for each new piece (engine and hash, D3DMetal folder
   and version, prefix), and "Remove old GPTK prefix" once migration is done.

## Migrating existing installs

Goal: after a Sparkle update, a user who already has the game opens Palium and plays,
with no download of game files and nothing lost. The game folder
(`AppData/Local/Palia`, holding `Client` with the game and `Saved` with settings and
logs) is moved, never copied or deleted. The game's install records in Palium's
settings (`installedVersion`, `installedManifestHash`) don't depend on the prefix,
so they stay valid. D3DMetal's shader cache lives in the macOS user cache, keyed by
the game's exe name, so it carries over as well.

### Where an existing game can be

Only Palium's own GPTK prefix is migrated:
`com.palium/prefix/drive_c/users/<user>/AppData/Local/Palia` (`<user>` is usually
`crossover`). Games in Whisky bottles are not migrated: a Whisky user gets the
normal fresh install, and their Whisky bottle is left alone.

Find the user through the existing `findWineUsername`, and fall back to scanning
`drive_c/users/*/AppData/Local/Palia/Client/PaliaClient.exe` so an odd user name
can't hide an install.

### Steps

A small journal in `UserDefaults` (`migration_v1`: step, source, destination)
records progress, so a crash or force-quit at any point resumes cleanly on the next
start. Each step can be repeated safely.

1. **Detect.** No `prefix-w11` with a game in it, but a game folder at an old
   location → start migration. A fresh user with no game skips straight to the new setup.
2. **Preconditions.**
   - The game is not running: no `PaliaClient` process. If it is, ask the user to quit it.
   - Stop the old prefix's wineserver (`wineserver -k` with the old Wine and `WINEPREFIX`).
   - GPTK found: `D3DMetalLocator` passes.
   - The source and destination are on the same volume (compare `volumeIdentifier`).
3. **Engine.** Download and verify. A failure here leaves everything as it was;
   show "Retry".
4. **New prefix.** Create `prefix-w11` under a temporary name (`prefix-w11.partial`),
   write its settings, then rename it. A crash mid-way leaves only a `.partial`
   folder, which the next start deletes and recreates. The game is still untouched.
5. **Move the game.** Write the journal (`moving`, source, destination), then one
   `rename` of the Palia folder into `prefix-w11/drive_c/users/<user>/AppData/Local/`.
   On the same volume this is atomic: afterwards the folder exists at exactly one of
   the two paths, and on the next start the journal plus that check tell which.
   - Different volumes (only possible if a user moved folders by hand): don't copy
     22 GB silently. Show the sizes and ask; copy only with enough free space.
   - Destination already has a game (e.g. a half-done fresh download): don't merge.
     Keep the copy that matches `installedVersion`, and leave the other where it is.
6. **Quick check.** Every file in the manifest exists with the right size; no
   hashing, so it takes seconds. A missing or wrong file goes through the existing
   repair flow, which downloads only those files.
7. **Finish.** Journal `done`. Keep the old prefix (it's about 1–2 GB once the game
   is out of it) and offer to remove it in Troubleshooting. Never delete it
   automatically.

### What the user sees

One screen: "Palium now uses a newer Wine to run the current Palia. Your game stays
installed; nothing is downloaded again except the Wine engine (159 MB)." Progress
shows the engine download, prefix setup and the move. A failure shows what
happened and "Retry", and the game folder stays where it was.

## Edge cases

| Case | Handling |
|---|---|
| Game running during the update | Step 2 waits for it to close. Sparkle relaunches only Palium, not the game. |
| Force-quit or power loss mid-migration | Journal + atomic renames: resume at the recorded step. |
| GPTK missing or moved | Same install prompt as today; migration waits, game untouched. |
| Engine asset gone or changed upstream | The mirror in Palium's release is the primary source; the hash check rejects a changed file. |
| Old Palium run after migrating (downgrade) | Old prefix lacks the game, and GPTK's Wine can't run 5.7 anyway. Note in release notes. |
| Low disk space | Engine needs about 700 MB during install; check first. The move needs none. |
| `prefix-wine11-test` from today's experiment | Not one of the known locations, ignored. Delete it by hand (`try_wine11.sh remove`). |

## Tests

- **Unit tests** (temporary folders, no Wine): migration planning from a given
  folder layout; resuming from each journal step; same-volume check; refusing to merge; the D3DMetal link builder; the VC++ marker check;
  the launch environment (variables above, same base for every process).
- **Engine install**: a wrong hash is rejected, and a `.partial` folder is never used.
- **Manual end-to-end on a Mac**: install the current release, download the game,
  update to the new build through Sparkle (local appcast), confirm no game files
  download, launch, and check `palia_perf.py` reaches gameplay. Repeat with a
  force-quit during the move.

## Open questions

- **Videos.** Resolved: the intro video plays on Wine 11 (2026-11-23). To skip it,
  the game asks for Delete, which on a Mac keyboard is Fn+Backspace.
- **Hosting the engine.** Mirroring the tarball in Palium's releases is fine under
  Wine's LGPL, with a link to the sources (`Sikarugir-App/wine`,
  `Sikarugir-App/Sikarugir-foss-sources`) in third-party notices.
- **D3DMetal.** It stays the user's own GPTK install. Apple's license allows only
  non-commercial redistribution, so Palium doesn't ship it.
- **DirectX 12 and GPTK 4.** Retest DX12 on Wine 11, and D3DMetal 4 beta (`D3DM_MTL4`),
  after the move; both are opt-in.
- **Recall's Wine fixes** (registry-save pause, ntdll lock) need our own Wine build
  from CrossOver 26.3 sources; a separate project after this one.

## Order of work

1. `EngineManager` + `D3DMetalLocator` + new `WineManager` paths for fresh installs.
2. `PrefixMigration` with the journal, plus its unit tests.
3. UI: the migration screen, Troubleshooting rows; remove Whisky support and the
   Wine Source picker.
4. VC++ check fix.
5. Mirror the engine in a Palium release; README and release notes.
6. Manual end-to-end test through Sparkle, then release.
