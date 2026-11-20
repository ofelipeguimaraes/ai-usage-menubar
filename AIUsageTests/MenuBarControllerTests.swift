import XCTest
@testable import AIUsage

@MainActor
final class MenuBarControllerTests: XCTestCase {
    func testCloseSuppressesOnlyTheMatchingToggleEvent() {
        var gate = PanelToggleGate()

        gate.panelDidClose()

        XCTAssertTrue(gate.consumeSuppression())
        XCTAssertFalse(gate.consumeSuppression())
    }

    func testOutsideCloseSuppressionCanExpireBeforeAnotherToggle() {
        var gate = PanelToggleGate()

        gate.panelDidClose()
        gate.clearSuppression()

        XCTAssertFalse(gate.consumeSuppression())
    }

    func testSuppressionSurvivesRunloopTurnsUntilNextMouseDown() {
        var gate = PanelToggleGate()

        gate.panelDidClose()
        let turn = XCTestExpectation(description: "runloop turn")
        DispatchQueue.main.async { turn.fulfill() }
        wait(for: [turn], timeout: 1)

        // Dismissal observers hop through a Task; the mouse-up action of the
        // same click must still see the suppression a turn later.
        XCTAssertTrue(gate.consumeSuppression())
    }

    func testSuppressionExpiresAfterTheClickWindow() {
        var gate = PanelToggleGate()
        let close = Date()

        gate.panelDidClose(at: close)
        XCTAssertTrue(gate.consumeSuppression(at: close.addingTimeInterval(0.2)))

        gate.panelDidClose(at: close)
        XCTAssertFalse(gate.consumeSuppression(at: close.addingTimeInterval(1)))
    }

    func testSettingsRouteExpandsTheSameCompactMenuBarPanel() {
        XCTAssertEqual(MenuBarPanelRoute.dashboard.width, 392)
        XCTAssertEqual(MenuBarPanelRoute.settings.width, 560)
        XCTAssertGreaterThan(
            MenuBarPanelRoute.settings.width,
            MenuBarPanelRoute.dashboard.width
        )
        XCTAssertLessThan(MenuBarPanelRoute.settings.width, 600)
    }

    func testOpeningPanelActivatesApplicationBeforePresentation() {
        let suiteName = "MenuBarControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let application = RecordingApplicationActivator()
        let controller = MenuBarController(
            store: UsageStore(
                providers: [],
                availabilityChecker: FixedProviderAvailabilityChecker(
                    installed: []
                )
            ),
            preferences: AppPreferences(defaults: defaults),
            launchAtLogin: LaunchAtLoginController(
                service: MenuBarControllerLoginService()
            ),
            updateController: UpdateController(startingUpdater: false),
            application: application
        )

        controller.start()
        controller.showSettings()

        XCTAssertEqual(application.activationCount, 1)

        controller.stop()
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
private final class RecordingApplicationActivator:
    ApplicationActivating
{
    private(set) var activationCount = 0

    func activate() {
        activationCount += 1
    }
}

@MainActor
private struct MenuBarControllerLoginService: LaunchAtLoginServicing {
    var status: LaunchAtLoginStatus { .notRegistered }

    func register() throws {}
    func unregister() throws {}
}
