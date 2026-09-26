import XCTest
@testable import AIUsage

final class MiniMaxTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let authPath = "~/.local/share/opencode/auth.json"
    private let usage = """
    {"base_resp":{"status_code":0,"status_msg":"success"},"model_remains":[
      {"model_name":"general","current_interval_total_count":0,"current_interval_usage_count":0,
       "current_interval_status":1,"current_interval_remaining_percent":80,"end_time":1790018000000,
       "current_weekly_total_count":0,"current_weekly_usage_count":0,
       "current_weekly_status":1,"current_weekly_remaining_percent":65,"weekly_end_time":1790604800000},
      {"model_name":"video","current_interval_status":3,"current_interval_remaining_percent":100,
       "current_weekly_status":3,"current_weekly_remaining_percent":100}]}
    """
    private let plan = """
    {"base_resp":{"status_code":0},"current_subscribe":{"current_subscribe_title":"Monthly Plus"},
     "cycle_resource_packages":[{"title":"Ultra"}],"current_combo_card":{"title":"Plus"}}
    """

    func testCurrentTokenPlanUsesPercentagesDespiteZeroCounters() throws {
        let snapshot = try MiniMaxUsageMapper.map(usage: httpResponse(json: usage),
                                                  plan: httpResponse(json: plan), now: now)
        XCTAssertEqual(snapshot.provider, .minimax)
        XCTAssertEqual(snapshot.planName, "Plus")
        XCTAssertEqual(snapshot.windows.map(\.kind), [.fiveHour, .weekly])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [20, 35])
        XCTAssertEqual(snapshot.windows.first?.resetsAt?.timeIntervalSince1970, 1_790_018_000)
        XCTAssertNil(snapshot.window(for: .monthly))
    }

    func testLegacyPromptCountersRepresentRemainingUsage() throws {
        let snapshot = try MiniMaxUsageMapper.map(usage: httpResponse(json: """
        {"base_resp":{"status_code":0},"model_remains":[{"model_name":"MiniMax-M2.7",
         "current_interval_total_count":100,"current_interval_usage_count":30,
         "current_weekly_total_count":1000,"current_weekly_usage_count":900}]}
        """), plan: nil, now: now)
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 70)
        XCTAssertEqual(snapshot.windows.last?.usedPercent ?? -1, 10, accuracy: 0.001)
    }

    func testUnavailableVideoDoesNotCreateFakeQuota() {
        XCTAssertThrowsError(try MiniMaxUsageMapper.map(usage: httpResponse(json: """
        {"base_resp":{"status_code":0},"model_remains":[{"model_name":"video",
         "current_interval_status":3,"current_interval_remaining_percent":100}]}
        """), plan: nil, now: now))
    }

    func testInactiveGeneralQuotaIsNotDisplayedAsFullyAvailable() {
        XCTAssertThrowsError(try MiniMaxUsageMapper.map(usage: httpResponse(json: """
        {"base_resp":{"status_code":0},"model_remains":[{"model_name":"general",
         "current_interval_status":3,"current_interval_remaining_percent":100,
         "current_weekly_status":3,"current_weekly_remaining_percent":100}]}
        """), plan: nil, now: now))
    }

    func testInvalidOrMissingPercentagesDoNotBecomeZeroUsage() {
        for remaining in ["null", "\"invalid\"", "101", "-1"] {
            XCTAssertThrowsError(try MiniMaxUsageMapper.map(usage: httpResponse(json: """
            {"base_resp":{"status_code":0},"model_remains":[{"model_name":"general",
             "current_interval_remaining_percent":\(remaining),
             "current_interval_total_count":0,"current_interval_usage_count":0}]}
            """), plan: nil, now: now))
        }
    }

    func testExhaustedQuotaIsReportedAsFullyConsumed() throws {
        let snapshot = try MiniMaxUsageMapper.map(usage: httpResponse(json: """
        {"base_resp":{"status_code":0},"model_remains":[{"model_name":"general",
         "current_interval_status":2,"current_interval_remaining_percent":0}]}
        """), plan: nil, now: now)
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 100)
    }

    func testPlanFailurePreservesQuotaWithoutGuessingTier() throws {
        let snapshot = try MiniMaxUsageMapper.map(usage: httpResponse(json: usage),
                                                  plan: httpResponse(503), now: now)
        XCTAssertEqual(snapshot.planName, "Token Plan")
        XCTAssertEqual(snapshot.windows.count, 2)
    }

    func testPlanBadgeUsesCurrentSubscriptionInsteadOfAdvertisedPlans() throws {
        let snapshot = try MiniMaxUsageMapper.map(usage: httpResponse(json: usage),
            plan: httpResponse(json: """
            {"base_resp":{"status_code":0},"current_subscribe":{"current_subscribe_title":"Yearly Max"},
             "cycle_resource_packages":[{"title":"Plus"}],"current_combo_card":{"title":"Plus"}}
            """), now: now)
        XCTAssertEqual(snapshot.planName, "Max")
    }

    func testOpenCodeSubscriptionKeyIsReadWithoutChangingOtherProviders() throws {
        let text = "{\"minimax-coding-plan\":{\"type\":\"api\",\"key\":\"subscription\"},\"deepseek\":{\"key\":\"other\"}}"
        let files = MemoryFiles([authPath: text])
        let credentials = try XCTUnwrap(MiniMaxAuthStore(files: files, environment: MockEnvironment()).load())
        XCTAssertEqual(credentials.apiKey, "subscription")
        XCTAssertEqual(credentials.host, "www.minimax.io")
        XCTAssertEqual(try files.readText(authPath), text)
    }

    func testPayAsYouGoKeyIsNotMistakenForSubscription() {
        let files = MemoryFiles([authPath: "{\"minimax\":{\"type\":\"api\",\"key\":\"ordinary-api-key\"}}"])
        XCTAssertNil(MiniMaxAuthStore(files: files, environment: MockEnvironment()).load())
    }

    func testGenericProviderCanHoldASubscriptionKey() throws {
        let files = MemoryFiles([authPath: "{\"minimax\":{\"type\":\"api\",\"key\":\"sk-cp-example\"}}"])
        XCTAssertEqual(MiniMaxAuthStore(files: files, environment: MockEnvironment()).load()?.apiKey,
                       "sk-cp-example")
    }

    func testXDGAuthPathAndChinaProviderSelectCorrectRegion() throws {
        let files = MemoryFiles(["/custom/opencode/auth.json": "{\"minimax-cn-coding-plan\":{\"type\":\"api\",\"key\":\"china-key\"}}"])
        let store = MiniMaxAuthStore(files: files, environment: MockEnvironment(values: ["XDG_DATA_HOME": "/custom"]))
        XCTAssertEqual(store.load()?.host, "www.minimax.cn")
    }

    func testEnvironmentCredentialTakesPriority() {
        let store = MiniMaxAuthStore(files: MemoryFiles(), environment: MockEnvironment(
            values: ["MINIMAX_API_KEY": "  configured-key  "]
        ))
        XCTAssertEqual(store.load()?.apiKey, "configured-key")
    }

    func testProviderQueriesUsageAndCurrentPlanUsingReadOnlyRequests() async throws {
        let files = MemoryFiles([authPath: "{\"minimax-coding-plan\":{\"type\":\"api\",\"key\":\"subscription\"}}"])
        let http = MockHTTPClient([httpResponse(json: usage), httpResponse(json: plan)])
        let provider = MiniMaxProvider(authStore: MiniMaxAuthStore(files: files, environment: MockEnvironment()),
            client: MiniMaxUsageClient(http: http), dateProvider: FixedDateProvider(value: now))
        let snapshot = try await provider.fetch()
        XCTAssertEqual(snapshot.planName, "Plus")
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.method == .get && $0.headers["Authorization"] == "Bearer subscription" })
        XCTAssertEqual(requests[0].url.path, "/v1/token_plan/remains")
        XCTAssertTrue(requests[1].url.query?.contains("resource_package_type=7") == true)
    }

    func testHTTPAndAPIAuthenticationErrorsAreRecognized() {
        let responses = [httpResponse(401), httpResponse(403),
                         httpResponse(json: "{\"base_resp\":{\"status_code\":1004}}")]
        for response in responses {
            XCTAssertThrowsError(try MiniMaxUsageMapper.payload(response)) {
                XCTAssertEqual(($0 as? ProviderFailure)?.kind, .authentication)
            }
        }
        XCTAssertThrowsError(try MiniMaxUsageMapper.payload(httpResponse(429))) {
            XCTAssertEqual(($0 as? ProviderFailure)?.kind, .rateLimited)
        }
        XCTAssertThrowsError(try MiniMaxUsageMapper.payload(httpResponse(503))) {
            XCTAssertEqual(($0 as? ProviderFailure)?.kind, .transient)
        }
    }

    @MainActor
    func testExistingInstallationKeepsMiniMaxTrackingAcrossRestartsAndRespectsOptOut() throws {
        let suite = "MiniMaxTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode([ProviderID.claude]), forKey: "trackedProviderIDs.v1")
        defaults.set(true, forKey: "openUsageProvidersAdded.v1")
        defaults.set(true, forKey: "kimiProviderAdded.v1")
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertTrue(preferences.trackedProviderIDs.contains(.minimax))
        XCTAssertTrue(AppPreferences(defaults: defaults).trackedProviderIDs.contains(.minimax))
        preferences.setTracking(false, for: .minimax)
        XCTAssertFalse(AppPreferences(defaults: defaults).trackedProviderIDs.contains(.minimax))
    }
}
