import Foundation
import Observation
import Sparkle

/// SwiftUI-friendly wrapper around Sparkle's `SPUStandardUpdaterController`.
///
/// `SPUUpdater` and `SPUStandardUpdaterController` are `NS_SWIFT_UI_ACTOR`
/// (main-actor isolated) in Sparkle 2.9, so this class is `@MainActor` too and
/// every call is isolation-correct under Swift 6 strict concurrency.
@MainActor
@Observable
final class UpdaterController {
    /// Mirrors `SPUUpdater.canCheckForUpdates`; used for menu-item validation.
    private(set) var canCheckForUpdates = false

    /// Backed by Sparkle, which persists it in UserDefaults (`SUEnableAutomaticChecks`).
    /// Stored rather than computed so SwiftUI observes changes and the Toggle re-renders.
    var automaticallyChecksForUpdates: Bool {
        didSet {
            guard automaticallyChecksForUpdates != controller.updater.automaticallyChecksForUpdates else { return }
            controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    /// Mirrors `SPUUpdater.lastUpdateCheckDate`; refreshed after checks and by `refresh()`.
    private(set) var lastUpdateCheckDate: Date?

    private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    init() {
        // startingUpdater: true reads SUFeedURL / SUPublicEDKey from Info.plist and
        // schedules background checks. A misconfigured plist logs and shows an alert
        // after a few seconds rather than crashing.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        lastUpdateCheckDate = controller.updater.lastUpdateCheckDate

        // Sparkle mutates canCheckForUpdates on the main thread, so the KVO handler
        // runs there; assumeIsolated is a checked assumption, not a blind one.
        canCheckObservation = controller.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] _, change in
            guard let newValue = change.newValue else { return }
            MainActor.assumeIsolated {
                self?.canCheckForUpdates = newValue
            }
        }
    }

    /// User-initiated check with Sparkle's standard UI.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.refresh()
        }
    }

    /// Re-reads state Sparkle does not publish through KVO.
    func refresh() {
        lastUpdateCheckDate = controller.updater.lastUpdateCheckDate
    }
}
