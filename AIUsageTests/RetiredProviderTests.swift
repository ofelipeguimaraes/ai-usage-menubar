import XCTest
@testable import AIUsage

@MainActor
final class RetiredProviderTests: XCTestCase {
    func testRetiredCodeShareSelectionKeepsMonthlySelection() {
        let suite = "RetiredMetricTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("[\"kimi\",[\"monthly\",\"codeMonthly\"]]".utf8), forKey: "menuBarMetricSelections.v3")
        defaults.set(true, forKey: "menuBarConfigured.v3")
        XCTAssertEqual(AppPreferences(defaults: defaults).menuBarMetricSelections[.kimi], [.monthly])
    }

    func testRemovingOpenCodePreservesOtherProviderPreferences() throws {
        let suite = "RetiredProviderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for flag in ["openUsageProvidersAdded.v1", "kimiProviderAdded.v1", "miniMaxProviderAdded.v1", "zaiProviderAdded.v1"] {
            defaults.set(true, forKey: flag)
        }
        defaults.set(Data("[\"claude\",\"opencode\",\"kimi\"]".utf8), forKey: "trackedProviderIDs.v1")
        defaults.set(Data("[\"claude\",\"opencode\"]".utf8), forKey: "menuBarVisibleProviders.v3")
        defaults.set(Data("[\"claude\",[\"weekly\"],\"opencode\",[\"totalUsage\"]]".utf8), forKey: "menuBarMetricSelections.v3")
        defaults.set(true, forKey: "menuBarConfigured.v3")
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.trackedProviderIDs, [.claude, .kimi])
        XCTAssertEqual(preferences.visibleMenuBarProviderIDs, [.claude])
        XCTAssertEqual(preferences.menuBarMetricSelections[.claude], [.weekly])
        XCTAssertEqual(AppPreferences(defaults: defaults).trackedProviderIDs, [.claude, .kimi])
        XCTAssertFalse(ProviderID.allCases.contains { $0.rawValue == "opencode" })
    }
}
