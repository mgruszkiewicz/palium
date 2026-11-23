import Foundation

/// Moves an existing Palia install from Palium's old GPTK prefix into the Wine 11
/// prefix, so users who update Palium keep their game without downloading it again.
///
/// The game folder (`AppData/Local/Palia`, holding `Client` and `Saved`) is moved
/// with a single rename on the same volume, which is atomic: afterwards it exists at
/// exactly one of the two paths. A journal in UserDefaults records the move, so a
/// crash or force-quit at any point resolves cleanly on the next start.
/// The old prefix itself is never deleted here.
nonisolated enum PrefixMigration {

    struct Journal: Codable, Equatable {
        enum Step: String, Codable { case moving, done }
        var step: Step
        var source: String
        var destination: String
    }

    enum Outcome: Equatable {
        /// No game in the old prefix (fresh install or already migrated earlier).
        case nothingToMigrate
        /// The new prefix already has a game; the old one was left where it is.
        case newPrefixAlreadyHasGame(legacyGame: URL)
        case migrated(from: URL, to: URL)
    }

    enum Failure: Error, Equatable, LocalizedError {
        case gameRunning
        case differentVolumes(source: URL, destination: URL)

        var errorDescription: String? {
            switch self {
            case .gameRunning:
                "Palia is running. Quit the game, then click Retry to finish moving it to the new Wine."
            case .differentVolumes(let source, let destination):
                "The game (\(source.path)) and the new Wine prefix (\(destination.path)) are on different disks, so it can't be moved instantly. Move it manually or download the game again."
            }
        }
    }

    static let journalKey = "prefixMigration_v1"

    static var legacyPrefix: URL {
        WineEngine.supportDirectory.appendingPathComponent("prefix")
    }

    /// The Palia folder inside a prefix for `user`.
    static func paliaFolder(prefix: URL, user: String) -> URL {
        prefix.appendingPathComponent("drive_c/users/\(user)/AppData/Local/Palia")
    }

    static func hasGame(_ paliaFolder: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: paliaFolder.appendingPathComponent("Client/PaliaClient.exe").path
        )
    }

    /// The Palia folder holding a game in `prefix`, if any: the registry user first,
    /// then any user folder with a game in it.
    static func findGame(inPrefix prefix: URL) -> URL? {
        let fm = FileManager.default
        if let user = try? WineManager.findWineUsername(in: prefix) {
            let folder = paliaFolder(prefix: prefix, user: user)
            if hasGame(folder) { return folder }
        }
        let users = prefix.appendingPathComponent("drive_c/users")
        let names = (try? fm.contentsOfDirectory(atPath: users.path))?.sorted() ?? []
        for name in names where name != "Public" && !name.hasPrefix(".") {
            let folder = paliaFolder(prefix: prefix, user: name)
            if hasGame(folder) { return folder }
        }
        return nil
    }

    /// Bring the game into `newPrefix` for `newUser`, if there is one to move.
    ///
    /// - Parameters:
    ///   - isGameRunning: true while any Palia process runs (checked before moving).
    ///   - stopLegacyWine: stops the old prefix's wineserver before the move.
    static func run(
        newPrefix: URL,
        newUser: String,
        legacyPrefix: URL = legacyPrefix,
        defaults: UserDefaults = .standard,
        isGameRunning: () -> Bool,
        stopLegacyWine: () -> Void,
        onLog: (String, LogEntry.Level) -> Void = { _, _ in }
    ) throws -> Outcome {
        let fm = FileManager.default
        let destination = paliaFolder(prefix: newPrefix, user: newUser)

        // 1. Finish an interrupted move.
        if let journal = loadJournal(defaults), journal.step == .moving {
            let source = URL(fileURLWithPath: journal.source)
            let recorded = URL(fileURLWithPath: journal.destination)
            let sourceExists = fm.fileExists(atPath: source.path)
            let destinationExists = fm.fileExists(atPath: recorded.path)
            if destinationExists && !sourceExists {
                saveJournal(Journal(step: .done, source: journal.source, destination: journal.destination), defaults)
                onLog("Finished an interrupted migration: the game is in the new prefix", .success)
                return .migrated(from: source, to: recorded)
            }
            if !sourceExists && !destinationExists {
                clearJournal(defaults)
            }
            // Source still in place: the rename never happened, start over below.
        }

        // 2. Nothing to do when the new prefix already holds the game.
        guard let source = findGame(inPrefix: legacyPrefix) else {
            return .nothingToMigrate
        }
        if hasGame(destination) {
            onLog("The new prefix already has a game; the old install at \(source.path) was left in place", .warning)
            return .newPrefixAlreadyHasGame(legacyGame: source)
        }

        // 3. Preconditions.
        if isGameRunning() { throw Failure.gameRunning }
        stopLegacyWine()

        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        guard sameVolume(source.deletingLastPathComponent(), parent) else {
            throw Failure.differentVolumes(source: source, destination: parent)
        }

        // A Palia folder without a game (e.g. settings the game wrote before it was
        // installed here) is kept aside rather than merged or overwritten.
        if fm.fileExists(atPath: destination.path) {
            let aside = parent.appendingPathComponent("Palia.before-migration-\(Int(Date().timeIntervalSince1970))")
            try fm.moveItem(at: destination, to: aside)
            onLog("Moved an existing Palia folder without a game aside to \(aside.lastPathComponent)", .warning)
        }

        // 4. The move: one rename, recorded before and after.
        saveJournal(Journal(step: .moving, source: source.path, destination: destination.path), defaults)
        onLog("Moving the game from \(source.path) to \(destination.path)...", .info)
        try fm.moveItem(at: source, to: destination)
        saveJournal(Journal(step: .done, source: source.path, destination: destination.path), defaults)
        onLog("Game moved to the new Wine prefix", .success)
        return .migrated(from: source, to: destination)
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let key: URLResourceKey = .volumeIdentifierKey
        guard let va = try? a.resourceValues(forKeys: [key]).volumeIdentifier as? NSObject,
              let vb = try? b.resourceValues(forKeys: [key]).volumeIdentifier as? NSObject else {
            return false
        }
        return va.isEqual(vb)
    }

    // MARK: - Journal

    static func loadJournal(_ defaults: UserDefaults = .standard) -> Journal? {
        guard let data = defaults.data(forKey: journalKey) else { return nil }
        return try? JSONDecoder().decode(Journal.self, from: data)
    }

    private static func saveJournal(_ journal: Journal, _ defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(journal) {
            defaults.set(data, forKey: journalKey)
        }
    }

    private static func clearJournal(_ defaults: UserDefaults) {
        defaults.removeObject(forKey: journalKey)
    }
}
