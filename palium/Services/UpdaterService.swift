import Foundation
import Observation
import Sparkle

/// Owns the Sparkle updater for the lifetime of the app.
///
/// The feed URL and public EdDSA key live in Info.plist (`SUFeedURL`,
/// `SUPublicEDKey`); Sparkle picks them up on its own. The controller has to be
/// created once at launch and kept alive — it drives the scheduled background
/// check as well as the manual one.
@MainActor
@Observable
class UpdaterService {
    static let shared = UpdaterService()

    /// False while a check is already in flight, so the menu item can grey out.
    private(set) var canCheckForUpdates = false

    var automaticallyChecksForUpdates: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var canCheckObserver: NSKeyValueObservation?

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates

        // Sparkle posts this on the main thread.
        canCheckObserver = controller.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] updater, _ in
            MainActor.assumeIsolated {
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
    }

    /// User-initiated check — always reports a result, including "you're up to date".
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    /// The last time a scheduled or manual check completed, for display in Settings.
    var lastUpdateCheckDate: Date? {
        controller.updater.lastUpdateCheckDate
    }
}
