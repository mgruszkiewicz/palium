import Foundation

/// Apple's D3DMetal, taken from the user's own Game Porting Toolkit install.
///
/// Palium doesn't ship D3DMetal (Apple's license only allows non-commercial
/// redistribution). Instead it builds a folder of links to just D3DMetal's pieces:
/// the Gcenx GPTK app's `lib/wine` holds all of Wine 7.7, and prepending that whole
/// folder to Wine 11's module path breaks Wine 11 ("could not load kernel32.dll").
///
/// ```text
/// com.palium/d3dmetal/
///   lib/external  -> <GPTK>/lib/external   (D3DMetal.framework, libd3dshared.dylib)
///   lib/wine/x86_64-windows/<module>.dll -> <GPTK>/lib/wine/x86_64-windows/<module>.dll
///   lib/wine/x86_64-unix/<module>.so     -> <GPTK>/lib/wine/x86_64-unix/<module>.so
///   gptk-lib      -> <GPTK>/lib            (freetype, gnutls, … that Wine loads)
/// ```
nonisolated enum D3DMetal {

    /// Modules D3DMetal can't work without.
    static let requiredModules = ["d3d11", "d3d12", "dxgi"]
    /// Linked when present (older GPTK builds lack some).
    static let optionalModules = ["d3d10", "nvapi64", "nvngx-on-metalfx"]

    struct Source: Sendable, Equatable {
        /// GPTK's `lib` folder (holds `external/` and `wine/`).
        let lib: URL
        let version: String?
    }

    /// GPTK `lib` folders to try, in order. Homebrew's `wine64` links resolve into the app.
    static let candidateLibs: [String] = [
        "/Applications/Game Porting Toolkit.app/Contents/Resources/wine/lib",
        "/opt/homebrew/bin/wine64",
        "/usr/local/bin/wine64",
    ]

    static var managedDirectory: URL {
        WineEngine.supportDirectory.appendingPathComponent("d3dmetal")
    }

    static var managedLib: URL { managedDirectory.appendingPathComponent("lib") }
    static var managedModules: URL { managedLib.appendingPathComponent("wine") }
    static var managedExternal: URL { managedLib.appendingPathComponent("external") }
    static var managedGPTKLib: URL { managedDirectory.appendingPathComponent("gptk-lib") }
    static var libd3dshared: URL { managedExternal.appendingPathComponent("libd3dshared.dylib") }

    // MARK: - Finding GPTK

    static func findSource(candidates: [String] = candidateLibs) -> Source? {
        for candidate in candidates {
            guard let lib = libDirectory(for: candidate), isValid(lib: lib) else { continue }
            return Source(lib: lib, version: version(in: lib))
        }
        return nil
    }

    /// A `lib` folder as given, or the `lib` next to a `wine64` binary (following links).
    private static func libDirectory(for candidate: String) -> URL? {
        let url = URL(fileURLWithPath: candidate)
        if url.lastPathComponent == "wine64" {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url.resolvingSymlinksInPath()
                .deletingLastPathComponent()      // bin
                .deletingLastPathComponent()      // wine
                .appendingPathComponent("lib")
        }
        return url
    }

    static func isValid(lib: URL) -> Bool {
        let fm = FileManager.default
        let external = lib.appendingPathComponent("external")
        guard fm.fileExists(atPath: external.appendingPathComponent("D3DMetal.framework").path),
              fm.fileExists(atPath: external.appendingPathComponent("libd3dshared.dylib").path) else {
            return false
        }
        return requiredModules.allSatisfy { module in
            fm.fileExists(atPath: lib.appendingPathComponent("wine/x86_64-windows/\(module).dll").path)
                && fm.fileExists(atPath: lib.appendingPathComponent("wine/x86_64-unix/\(module).so").path)
        }
    }

    static func version(in lib: URL) -> String? {
        let framework = lib.appendingPathComponent("external/D3DMetal.framework")
        for plist in ["Resources/Info.plist", "Versions/Current/Resources/Info.plist"] {
            let url = framework.appendingPathComponent(plist)
            if let info = NSDictionary(contentsOf: url),
               let version = info["CFBundleShortVersionString"] as? String {
                return version
            }
        }
        return nil
    }

    // MARK: - Managed link folder

    /// (Re)build the managed link folder for `source`. Runs on every start, since the
    /// user may move or update GPTK. Built next to the old folder and swapped in.
    static func prepare(source: Source, in directory: URL = managedDirectory) throws {
        let fm = FileManager.default
        let building = directory.deletingLastPathComponent()
            .appendingPathComponent(directory.lastPathComponent + ".partial")
        try? fm.removeItem(at: building)

        let lib = building.appendingPathComponent("lib")
        let windows = lib.appendingPathComponent("wine/x86_64-windows")
        let unix = lib.appendingPathComponent("wine/x86_64-unix")
        try fm.createDirectory(at: windows, withIntermediateDirectories: true)
        try fm.createDirectory(at: unix, withIntermediateDirectories: true)

        try fm.createSymbolicLink(
            at: lib.appendingPathComponent("external"),
            withDestinationURL: source.lib.appendingPathComponent("external")
        )
        try fm.createSymbolicLink(
            at: building.appendingPathComponent("gptk-lib"),
            withDestinationURL: source.lib
        )

        for module in requiredModules + optionalModules {
            let dll = source.lib.appendingPathComponent("wine/x86_64-windows/\(module).dll")
            let so = source.lib.appendingPathComponent("wine/x86_64-unix/\(module).so")
            guard fm.fileExists(atPath: dll.path), fm.fileExists(atPath: so.path) else { continue }
            try fm.createSymbolicLink(at: windows.appendingPathComponent("\(module).dll"), withDestinationURL: dll)
            try fm.createSymbolicLink(at: unix.appendingPathComponent("\(module).so"), withDestinationURL: so)
        }

        try? fm.removeItem(at: directory)
        try fm.moveItem(at: building, to: directory)
    }

    /// The links point at existing files (GPTK wasn't moved or removed since).
    static func isPrepared(in directory: URL = managedDirectory) -> Bool {
        let fm = FileManager.default
        let lib = directory.appendingPathComponent("lib")
        return fm.fileExists(atPath: lib.appendingPathComponent("external/libd3dshared.dylib").path)
            && requiredModules.allSatisfy {
                fm.fileExists(atPath: lib.appendingPathComponent("wine/x86_64-unix/\($0).so").path)
            }
    }
}
