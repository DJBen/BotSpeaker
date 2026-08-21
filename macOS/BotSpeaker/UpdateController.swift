import Foundation
import Observation
import Sparkle

@MainActor
@Observable
final class UpdateController {
    private(set) var canCheckForUpdates = false

    let updaterController: SPUStandardUpdaterController
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        if updaterController.updater.automaticallyChecksForUpdates {
            updaterController.updater.checkForUpdatesInBackground()
        }
        observation = updaterController.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] updater, _ in
            guard let controller = self else { return }
            let canCheckForUpdates = updater.canCheckForUpdates
            Task { @MainActor [controller] in
                controller.canCheckForUpdates = canCheckForUpdates
            }
        }
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}
