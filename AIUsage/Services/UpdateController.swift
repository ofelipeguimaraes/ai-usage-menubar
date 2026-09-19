import Observation

@MainActor
@Observable
final class UpdateController {
    private(set) var availableVersion: String?
    private(set) var isChecking = false

    init(startingUpdater: Bool = false) {
    }

    var isUpdateAvailable: Bool {
        false
    }

    func checkForUpdates() {
    }
}
