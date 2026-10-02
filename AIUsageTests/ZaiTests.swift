import XCTest
@testable import AIUsage

final class ZaiTests: XCTestCase {
    func testOpenCodeCredentialsRespectDataHomeAndProviderIdentity() {
        let files = MemoryFiles(["/custom/opencode/auth.json": """
            {"zai-coding-plan":{"type":"api","key":" test-key "},"minimax-coding-plan":{"type":"api","key":"other"}}
            """])
        let store = ZaiAuthStore(files: files, environment: MockEnvironment(values: ["XDG_DATA_HOME": "/custom"]), sqlite: MockSQLite())
        XCTAssertEqual(store.load(), "test-key")
        XCTAssertNil(ZaiAuthStore(files: MemoryFiles(["~/.local/share/opencode/auth.json":
            "{\"zai\":{\"type\":\"api\",\"key\":\"pay-as-you-go\"}}"]), environment: MockEnvironment(), sqlite: MockSQLite()).load())
    }

    func testOpenCodeDatabaseCredentialIsPreferredOverLegacyAuthFile() {
        let files = MemoryFiles(["~/.local/share/opencode/auth.json":
            "{\"zai-coding-plan\":{\"type\":\"api\",\"key\":\"stale-key\"}}"])
        let sqlite = MockSQLite(values: ["zai-coding-plan": "{\"type\":\"key\",\"key\":\" db-key \"}"])
        XCTAssertEqual(ZaiAuthStore(files: files, environment: MockEnvironment(), sqlite: sqlite).load(), "db-key")
        XCTAssertNil(ZaiAuthStore(files: MemoryFiles(), environment: MockEnvironment(),
                                  sqlite: MockSQLite(values: ["zai": "{\"type\":\"key\",\"key\":\"payg\"}"])).load())
    }

    func testEnvironmentKeyTakesPrecedence() {
        XCTAssertEqual(ZaiAuthStore(files: MemoryFiles(), environment: MockEnvironment(values: ["ZAI_API_KEY": " key "]), sqlite: MockSQLite()).load(), "key")
    }

    func testLiteCreditQuotasUseReportedPercentAndMillisecondResets() throws {
        let snapshot = try ZaiUsageMapper.map(httpResponse(json: """
            {"code":200,"success":true,"data":{"level":"lite","limits":[
            {"type":"CREDIT_LIMIT","unit":3,"number":5,"usage":2000,"currentValue":4,"percentage":1,"nextResetTime":1790473678426},
            {"type":"CREDIT_LIMIT","unit":6,"number":1,"percentage":20,"nextResetTime":1791060378974}]}}
            """), now: Date())
        XCTAssertEqual(snapshot.planName, "Lite")
        XCTAssertEqual(snapshot.windows.map(\.kind), [.fiveHour, .weekly])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [1, 20])
        XCTAssertEqual(snapshot.windows[0].resetsAt?.timeIntervalSince1970, 1790473678.426)
    }

    func testLegacyTokensAndMonthlyMCPRemainSeparate() throws {
        let snapshot = try ZaiUsageMapper.map(httpResponse(json: """
            {"code":200,"success":true,"data":{"limits":[
            {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":0},
            {"type":"TIME_LIMIT","unit":5,"number":1,"percentage":50}]}}
            """), now: Date())
        XCTAssertEqual(snapshot.planName, "Coding Plan")
        XCTAssertEqual(snapshot.windows.map(\.kind), [.fiveHour, .mcpMonthly])
        XCTAssertEqual(snapshot.availableMenuBarItems.map(\.metric), [.fiveHour, .mcpMonthly])
    }

    func testMissingInvalidAndUnknownQuotasNeverBecomeZero() {
        for limit in ["{\"type\":\"CREDIT_LIMIT\",\"unit\":3,\"number\":5}",
                      "{\"type\":\"CREDIT_LIMIT\",\"unit\":3,\"number\":5,\"percentage\":101}",
                      "{\"type\":\"UNKNOWN\",\"unit\":3,\"number\":5,\"percentage\":0}"] {
            XCTAssertThrowsError(try ZaiUsageMapper.map(httpResponse(json:
                "{\"code\":200,\"success\":true,\"data\":{\"limits\":[\(limit)]}}"), now: Date()))
        }
    }

    func testAuthenticationErrorsInsideSuccessfulHTTPResponse() {
        XCTAssertThrowsError(try ZaiUsageMapper.map(httpResponse(json: "{\"code\":401,\"success\":false}"), now: Date())) {
            XCTAssertEqual(($0 as? ProviderFailure)?.kind, .authentication)
        }
    }

    func testProviderSendsRawKeyToOfficialReadOnlyEndpoint() async throws {
        let http = MockHTTPClient([httpResponse(json: """
            {"code":200,"success":true,"data":{"level":"lite","limits":[{"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":1}]}}
            """)])
        let provider = ZaiProvider(authStore: ZaiAuthStore(files: MemoryFiles(), environment: MockEnvironment(values: ["ZAI_API_KEY": "test-key"]), sqlite: MockSQLite()), http: http)
        let snapshot = try await provider.fetch()
        XCTAssertEqual(snapshot.provider, .zai)
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.first?.headers["Authorization"], "test-key")
        XCTAssertEqual(requests.first?.url.absoluteString, "https://api.z.ai/api/monitor/usage/quota/limit")
    }
    @MainActor
    func testTrackingMigrationPersistsAndRespectsOptOut() throws {
        let suite = "ZaiTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode([ProviderID.claude]), forKey: "trackedProviderIDs.v1")
        defaults.set(true, forKey: "openUsageProvidersAdded.v1")
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertTrue(AppPreferences(defaults: defaults).trackedProviderIDs.contains(.zai))
        preferences.setTracking(false, for: .zai)
        XCTAssertFalse(AppPreferences(defaults: defaults).trackedProviderIDs.contains(.zai))
    }

}
