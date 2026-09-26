import XCTest
@testable import AIUsage

final class KimiTests: XCTestCase {
    func testCodeShareIsConsumedContributionEvenInRemainingMode() throws {
        for ratio in [0.0, 0.0123] {
            let snapshot = try KimiUsageMapper.map(usage: httpResponse(json:
                "{\"usages\":{\"limit_month_total\":{\"used_ratio\":0.0621},\"limit_month_code\":{\"used_ratio\":\(ratio)}}}"), profile: nil, now: Date())
            XCTAssertEqual(snapshot.menuBarValue(for: .codeMonthly, displayMode: .remaining), .percentage(ratio * 100))
            XCTAssertEqual(snapshot.window(for: .codeMonthly)?.effectiveDisplayMode(.remaining), .used)
            XCTAssertEqual(snapshot.window(for: .monthly)?.effectiveDisplayMode(.remaining), .remaining)
            XCTAssertEqual(snapshot.menuBarValue(for: .monthly, displayMode: .remaining), .percentage(93.79))
        }
    }

    func testExhaustedFiveHourCounterOverridesAnIncorrectZeroRatio() throws {
        let snapshot = try KimiUsageMapper.map(usage: httpResponse(json: """
            {"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},
            "detail":{"limit":"100","used":"100","resetTime":"2026-09-27T00:59:18Z"}}],
            "usages":{"limit_5h":{"used_ratio":0,"reset_time":"2026-09-27T00:59:17Z"},
            "limit_month_total":{"used_ratio":0.0621},"limit_month_code":{"used_ratio":0}}}
            """), profile: nil, now: Date())
        XCTAssertEqual(snapshot.window(for: .fiveHour)?.usedPercent, 100)
        XCTAssertEqual(snapshot.window(for: .fiveHour)?.resetsAt, ProviderParsing.date("2026-09-27T00:59:18Z"))
        XCTAssertEqual(snapshot.window(for: .monthly)?.usedPercent ?? -1, 6.21, accuracy: 0.001)
        XCTAssertNil(snapshot.window(for: .weekly))
    }

    func testFiveHourCounterDoesNotEraseHigherReportedUsage() throws {
        let snapshot = try KimiUsageMapper.map(usage: httpResponse(json: """
            {"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},
            "detail":{"limit":"100","used":"10"}}],"usages":{"limit_5h":{"used_ratio":0.5}}}
            """), profile: nil, now: Date())
        XCTAssertEqual(snapshot.window(for: .fiveHour)?.usedPercent, 50)
    }

    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let path = "~/.kimi-code/credentials/kimi-code.json"
    private let usage = """
    {"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},
      "detail":{"limit":"100","remaining":"80"}}],
     "usages":{"limit_5h":{"used_ratio":0.2,"reset_time":"2026-10-01T00:00:00Z"},
     "limit_month_total":{"used_ratio":"0.3","reset_time":"2026-10-27T00:00:00Z"},
     "limit_month_code":{"used_ratio":0.4,"reset_time":"2026-10-27T00:00:00Z"}}}
    """

    func testPlusMapsThreeIndependentQuotasWithoutInventingWeeklyUsage() throws {
        let snapshot = try KimiUsageMapper.map(
            usage: httpResponse(json: usage),
            profile: httpResponse(json: "{\"user_level_name\":\"Plus\"}"), now: now
        )
        XCTAssertEqual(snapshot.provider, .kimi)
        XCTAssertEqual(snapshot.planName, "Plus")
        XCTAssertEqual(snapshot.windows.map(\.kind), [.fiveHour, .monthly, .codeMonthly])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [20, 30, 40])
        XCTAssertNotNil(snapshot.windows.last?.resetsAt)
    }

    func testLegacyAccountMapsCountersAndWeeklyQuota() throws {
        let snapshot = try KimiUsageMapper.map(usage: httpResponse(json: """
        {"usage":{"limit":"100","remaining":"70"},
         "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},
         "detail":{"limit":"100","used":"10"}}]}
        """), profile: nil, now: now)
        XCTAssertEqual(snapshot.windows.map(\.kind), [.weekly, .fiveHour])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [30, 10])
        XCTAssertNil(snapshot.planName)
    }

    func testMissingAndZeroQuotaAreNotReportedAsUnused() {
        for payload in ["{}", "{\"usages\":{}}", "{\"usage\":{\"limit\":0,\"used\":0}}"] {
            XCTAssertThrowsError(try KimiUsageMapper.map(
                usage: httpResponse(json: payload), profile: nil, now: now
            ))
        }
    }

    func testProfileFailureDoesNotHideUsage() throws {
        let snapshot = try KimiUsageMapper.map(usage: httpResponse(json: usage),
                                              profile: httpResponse(503), now: now)
        XCTAssertEqual(snapshot.windows.count, 3)
        XCTAssertNil(snapshot.planName)
    }

    func testExtraUsageUsesFixedPointWalletBalance() throws {
        let snapshot = try KimiUsageMapper.map(usage: httpResponse(json: """
        {"usages":{"limit_5h":{"used_ratio":0}},
         "boosterWallet":{"balance":{"type":"BOOSTER","amountLeft":"1250000000"},
         "monthlyUsed":{"currency":"USD"}}}
        """), profile: nil, now: now)
        XCTAssertEqual(snapshot.billingUsage, .balance(amount: 12.5, currencyCode: "USD"))
    }

    func testNewCLIFileCredentialsTakePriorityOverLegacyCLI() throws {
        let files = MemoryFiles([path: "{\"access_token\":\"new-token\"}",
                                "~/.kimi/credentials/kimi-code.json": "{\"access_token\":\"old-token\"}"])
        let state = try XCTUnwrap(KimiAuthStore(files: files, environment: MockEnvironment()).load())
        XCTAssertEqual(state.credentials.accessToken, "new-token")
        XCTAssertEqual(state.baseURL.host, "api.kimi.com")
    }

    func testGlobalConfigurationUsesItsOwnCredentialSlotAndEndpoints() throws {
        let files = MemoryFiles([
            "/custom/config.toml": """
            [providers."managed:kimi-code"]
            base_url = "https://api.kimi.ai/coding/v1"
            oauth = { storage = "file", key = "oauth/kimi-code-env-global" }
            """,
            "/custom/credentials/kimi-code-env-global.json": "{\"access_token\":\"global-token\"}"
        ])
        let store = KimiAuthStore(files: files, environment: MockEnvironment(values: ["KIMI_CODE_HOME": "/custom"]))
        let state = try XCTUnwrap(store.load())
        XCTAssertEqual(state.baseURL.host, "api.kimi.ai")
        XCTAssertEqual(state.oauthHost.host, "auth.kimi.ai")
    }

    func testCredentialRotationDoesNotOverwriteConcurrentLogin() throws {
        let files = MemoryFiles([path: "{\"access_token\":\"old\",\"refresh_token\":\"refresh\"}"])
        let store = KimiAuthStore(files: files, environment: MockEnvironment())
        var state = try XCTUnwrap(store.load())
        let original = state.credentials
        state.credentials.accessToken = "renewed"
        try files.writeText(path, "{\"access_token\":\"other-login\"}")
        XCTAssertThrowsError(try store.save(state, replacing: original))
        XCTAssertEqual(try store.load()?.credentials.accessToken, "other-login")
    }

    func testProviderUsesRefreshedTokenForUsageAndProfileAndPersistsRotation() async throws {
        let files = MemoryFiles([path: "{\"access_token\":\"old\",\"refresh_token\":\"refresh\"}"])
        let http = MockHTTPClient([
            httpResponse(401),
            httpResponse(json: "{\"access_token\":\"renewed\",\"refresh_token\":\"rotated\",\"expires_in\":3600}"),
            httpResponse(json: usage), httpResponse(json: "{\"user_level_name\":\"Plus\"}")
        ])
        let store = KimiAuthStore(files: files, environment: MockEnvironment())
        let provider = KimiProvider(authStore: store, client: KimiUsageClient(http: http),
                                    dateProvider: FixedDateProvider(value: now))
        let snapshot = try await provider.fetch()
        XCTAssertEqual(snapshot.planName, "Plus")
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests[1].url.host, "auth.kimi.com")
        XCTAssertEqual(requests[2].headers["Authorization"], "Bearer renewed")
        XCTAssertEqual(requests[3].headers["Authorization"], "Bearer renewed")
        let saved = try XCTUnwrap(store.load())
        XCTAssertEqual(saved.credentials.refreshToken, "rotated")
        XCTAssertEqual(saved.credentials.expiresAt, now.timeIntervalSince1970 + 3600)
    }

    func testAuthenticationAndTransientFailuresStayDistinct() {
        for status in [401, 403, 429, 503] {
            XCTAssertThrowsError(try KimiUsageMapper.requireSuccess(httpResponse(status))) { error in
                let failure = error as? ProviderFailure
                XCTAssertEqual(failure?.kind, status == 401 || status == 403 ? .authentication : .transient)
            }
        }
    }

    @MainActor
    func testKimiIsAddedToExistingInstallationsOnlyOnce() throws {
        let suite = "KimiTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode([ProviderID.claude]), forKey: "trackedProviderIDs.v1")
        defaults.set(true, forKey: "openUsageProvidersAdded.v1")
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertTrue(preferences.trackedProviderIDs.contains(.kimi))
        XCTAssertTrue(AppPreferences(defaults: defaults).trackedProviderIDs.contains(.kimi))
        preferences.setTracking(false, for: .kimi)
        XCTAssertFalse(AppPreferences(defaults: defaults).trackedProviderIDs.contains(.kimi))
    }
}
