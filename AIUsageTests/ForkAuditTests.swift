import XCTest
@testable import AIUsage

final class ForkAuditTests: XCTestCase {
    func testGrokMissingUsageIsNotReportedAsUnused() {
        XCTAssertThrowsError(try GrokUsageMapper.map(response: httpResponse(json: """
            {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2027-01-01T00:00:00Z"}}}
            """), planResponse: nil, now: Date()))
    }

    func testDifferentGLMAndKimiTiersAreReturnedWithoutAccountAssumptions() throws {
        for tier in ["lite", "pro", "max", "future-tier"] {
            let snapshot = try ZaiUsageMapper.map(httpResponse(json:
                "{\"code\":200,\"success\":true,\"data\":{\"level\":\"\(tier)\",\"limits\":[{\"type\":\"CREDIT_LIMIT\",\"unit\":3,\"number\":5,\"percentage\":10}]}}"), now: Date())
            XCTAssertEqual(snapshot.planName, tier.capitalized)
        }
        for tier in ["Plus", "Pro", "Premium", "Future Membership"] {
            let snapshot = try KimiUsageMapper.map(usage: httpResponse(json:
                "{\"usages\":{\"limit_5h\":{\"used_ratio\":0.1}}}"),
                profile: httpResponse(json: "{\"user_level_name\":\"\(tier)\"}"), now: Date())
            XCTAssertEqual(snapshot.planName, tier)
        }
    }

    func testExistingProvidersReadDifferentPlanNames() throws {
        for tier in ["free", "pro", "team", "future_plan"] {
            let credentials = ClaudeOAuth(subscriptionType: tier)
            XCTAssertEqual(ClaudeUsageMapper.planName(credentials), ProviderParsing.titleCaseIdentifier(tier))
            XCTAssertEqual(CodexUsageMapper.planName(tier), tier == "pro" ? "Pro 20x" : ProviderParsing.titleCaseIdentifier(tier))
            let data = Data("{\"paidTier\":{\"name\":\"\(tier)\"}}".utf8)
            XCTAssertEqual(AntigravityUsageMapper.plan(data), ProviderParsing.titleCaseIdentifier(tier))
        }
        for tier in ["SuperGrok", "SuperGrok Heavy", "Future Grok"] {
            let snapshot = try GrokUsageMapper.map(response: httpResponse(json:
                "{\"config\":{\"creditUsagePercent\":10,\"currentPeriod\":{\"type\":\"USAGE_PERIOD_TYPE_WEEKLY\",\"end\":\"2027-01-01T00:00:00Z\"}}}"),
                planResponse: httpResponse(json: "{\"subscription_tier_display\":\"\(tier)\"}"), now: Date())
            XCTAssertEqual(snapshot.planName, tier)
        }
        for tier in ["starter", "essential", "ultimate", "future_plan"] {
            let snapshot = try QwenUsageMapper.map(usage: ["per5HourPercentage": 0.1],
                subscription: ["specCode": tier], now: Date())
            XCTAssertEqual(snapshot.planName, ProviderParsing.titleCaseIdentifier(tier))
        }
        for tier in ["Starter", "Plus", "Max", "Ultra", "Future Plan"] {
            let snapshot = try MiniMaxUsageMapper.map(usage: httpResponse(json:
                "{\"base_resp\":{\"status_code\":0},\"model_remains\":[{\"model_name\":\"general\",\"current_interval_remaining_percent\":90}]}"),
                plan: httpResponse(json: "{\"base_resp\":{\"status_code\":0},\"current_subscribe\":{\"current_subscribe_title\":\"\(tier)\"}}"), now: Date())
            XCTAssertEqual(snapshot.planName, tier)
        }
    }

    func testDeepSeekCustomDataHomeAndCredentialType() {
        let files = MemoryFiles(["/custom/opencode/auth.json": "{\"deepseek\":{\"type\":\"api\",\"key\":\"key\"}}"])
        XCTAssertEqual(DeepSeekAuthStore(files: files, environment: MockEnvironment(values: ["XDG_DATA_HOME": "/custom"])).loadAPIKey(), "key")
        XCTAssertNil(DeepSeekAuthStore(files: MemoryFiles([DeepSeekAuthStore.authPaths[0]: "{\"deepseek\":{\"type\":\"oauth\",\"key\":\"wrong\"}}"]), environment: MockEnvironment()).loadAPIKey())
    }
}
