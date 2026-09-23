import CryptoKit
import XCTest
@testable import AIUsage

final class MapperTests: XCTestCase {
    func testClaudeMapsAllSupportedWindowsAndPlan() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let response = httpResponse(json: """
        {
          "five_hour": {"utilization": 12.5, "resets_at": "2027-01-15T12:00:00.123456"},
          "seven_day": {"utilization": 44, "resets_at": 1800100000},
          "seven_day_sonnet": {"utilization": 67, "resets_at": 1800200000000},
          "limits": [
            {
              "kind": "weekly_scoped",
              "scope": {"model": {"display_name": "Fable"}},
              "percent": 89,
              "resets_at": "2027-01-20T00:00:00Z"
            }
          ],
          "extra_usage": {"is_enabled": true, "used_credits": 9999}
        }
        """)
        let oauth = ClaudeOAuth(
            accessToken: "token",
            refreshToken: "refresh",
            expiresAt: nil,
            subscriptionType: "PRO PLAN",
            rateLimitTier: "default_claude_max_20x",
            scopes: ["user:profile"]
        )

        let snapshot = try ClaudeUsageMapper.map(
            response: response,
            credentials: oauth,
            now: now
        )

        XCTAssertEqual(snapshot.planName, "Pro Plan 20x")
        XCTAssertEqual(snapshot.windows.map(\.kind), [.session, .weekly, .sonnet, .fable])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [12.5, 44, 67, 89])
        XCTAssertNotNil(snapshot.windows[0].resetsAt)
        XCTAssertEqual(
            snapshot.windows[1].resetsAt,
            Date(timeIntervalSince1970: 1_800_100_000)
        )
        XCTAssertEqual(
            snapshot.windows[2].resetsAt,
            Date(timeIntervalSince1970: 1_800_200_000)
        )
    }

    func testCodexClassifiesWeeklyInPrimaryAndMapsSpark() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let response = httpResponse(json: """
        {
          "plan_type": "prolite",
          "rate_limit": {
            "primary_window": {
              "used_percent": 73,
              "limit_window_seconds": 604800,
              "reset_at": 1800100000
            }
          },
          "additional_rate_limits": [
            {
              "limit_name": "GPT-5.3-Codex-Spark",
              "rate_limit": {
                "primary_window": {
                  "used_percent": 101.4,
                  "limit_window_seconds": 18000,
                  "reset_after_seconds": 600
                },
                "secondary_window": {
                  "used_percent": 22,
                  "limit_window_seconds": 604800
                }
              }
            }
          ]
        }
        """)

        let snapshot = try CodexUsageMapper.map(response: response, now: now)

        XCTAssertEqual(snapshot.planName, "Pro 5x")
        XCTAssertEqual(snapshot.windows.map(\.kind), [.weekly, .sparkSession, .sparkWeekly])
        XCTAssertEqual(snapshot.windows[0].usedPercent, 73)
        XCTAssertEqual(snapshot.windows[1].usedPercent, 101.4)
        XCTAssertEqual(snapshot.windows[1].renderedFraction, 1)
        XCTAssertEqual(
            snapshot.windows[1].resetsAt,
            now.addingTimeInterval(600)
        )
    }

    func testCodexFallsBackToPercentHeadersWhenBodyOmitsPercent() throws {
        let response = httpResponse(
            json: """
            {
              "rate_limit": {
                "primary_window": {"limit_window_seconds": 18000},
                "secondary_window": {"limit_window_seconds": 604800}
              }
            }
            """,
            headers: [
                "X-Codex-Primary-Used-Percent": "17.25",
                "x-codex-secondary-used-percent": "68"
            ]
        )

        let snapshot = try CodexUsageMapper.map(response: response, now: Date())

        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [17.25, 68])
    }

    func testClaudeMapsBoundedExtraUsageFromCents() throws {
        let response = httpResponse(json: """
        {
          "extra_usage": {
            "is_enabled": true,
            "used_credits": 500,
            "monthly_limit": 1000
          }
        }
        """)

        let snapshot = try ClaudeUsageMapper.map(
            response: response,
            credentials: claudeOAuth(),
            now: Date()
        )

        XCTAssertEqual(
            snapshot.billingUsage,
            .boundedSpend(
                usedAmount: 5,
                limitAmount: 10,
                currencyCode: "USD"
            )
        )
    }

    func testClaudeMapsUncappedExtraUsageAsSpend() throws {
        let response = httpResponse(json: """
        {
          "extra_usage": {
            "is_enabled": true,
            "used_credits": 123456,
            "monthly_limit": 0
          }
        }
        """)

        let snapshot = try ClaudeUsageMapper.map(
            response: response,
            credentials: claudeOAuth(),
            now: Date()
        )

        XCTAssertEqual(
            snapshot.billingUsage,
            .unboundedSpend(
                usedAmount: 1234.56,
                currencyCode: "USD"
            )
        )
    }

    func testClaudeOmitsDisabledOrEmptyUncappedExtraUsage() throws {
        for json in [
            """
            {"extra_usage":{"is_enabled":false,"used_credits":500}}
            """,
            """
            {"extra_usage":{"is_enabled":true,"used_credits":0}}
            """,
            """
            {"extra_usage":{"is_enabled":true,"used_credits":0,"monthly_limit":0}}
            """
        ] {
            let snapshot = try ClaudeUsageMapper.map(
                response: httpResponse(json: json),
                credentials: claudeOAuth(),
                now: Date()
            )

            XCTAssertNil(snapshot.billingUsage)
        }
    }

    func testCodexFloorsCreditCountAndPricesEachCreditAtFourCents() throws {
        let snapshot = try CodexUsageMapper.map(
            response: httpResponse(json: """
            {"credits":{"balance":"820.9"}}
            """),
            now: Date()
        )

        XCTAssertEqual(
            snapshot.billingUsage,
            .flexCreditBalance(
                remainingCredits: 820,
                usdValue: 32.8
            )
        )
    }

    func testCodexCreditBalanceUsesBodyThenHeaderFallback() throws {
        let bodyWins = try CodexUsageMapper.map(
            response: httpResponse(
                json: """
                {"credits":{"balance":"100"}}
                """,
                headers: ["x-codex-credits-balance": "25"]
            ),
            now: Date()
        )
        let headerFallback = try CodexUsageMapper.map(
            response: httpResponse(
                json: "{}",
                headers: ["X-Codex-Credits-Balance": "42.9"]
            ),
            now: Date()
        )

        XCTAssertEqual(
            bodyWins.billingUsage,
            .flexCreditBalance(
                remainingCredits: 100,
                usdValue: 4
            )
        )
        XCTAssertEqual(
            headerFallback.billingUsage,
            .flexCreditBalance(
                remainingCredits: 42,
                usdValue: 1.68
            )
        )
    }

    func testCodexTreatsNoCreditsAndNegativeBalanceAsRealZero() throws {
        let responses = [
            httpResponse(
                json: """
                {"credits":{"has_credits":false}}
                """,
                headers: ["x-codex-credits-balance": "25"]
            ),
            httpResponse(json: """
            {"credits":{"balance":-5}}
            """)
        ]
        for response in responses {
            let snapshot = try CodexUsageMapper.map(
                response: response,
                now: Date()
            )

            XCTAssertEqual(
                snapshot.billingUsage,
                .flexCreditBalance(
                    remainingCredits: 0,
                    usdValue: 0
                )
            )
        }
    }

    func testCodexOmitsUnknownCreditAvailability() throws {
        let snapshot = try CodexUsageMapper.map(
            response: httpResponse(json: """
            {"credits":{"has_credits":true,"balance":null}}
            """),
            now: Date()
        )

        XCTAssertNil(snapshot.billingUsage)
    }

    func testParsingRejectsBooleanAsNumberAndEscapesFormValues() {
        XCTAssertNil(ProviderParsing.double(true))
        let body = String(
            data: ProviderParsing.formBody([("refresh_token", "a+b c&d")]),
            encoding: .utf8
        )
        XCTAssertEqual(body, "refresh_token=a%2Bb%20c%26d")
    }

    func testDateParserAcceptsProviderTimestampVariants() {
        XCTAssertNotNil(ProviderParsing.date("2027-01-15T12:00:00.123456"))
        XCTAssertNotNil(ProviderParsing.date("2027-01-15 12:00:00 UTC"))
        XCTAssertNotNil(ProviderParsing.date("2027-01-15T12:00:00+03:00"))
    }

    func testCursorMapsTotalAutoAPIAndPlan() throws {
        let snapshot = try CursorUsageMapper.map(
            usageResponse: httpResponse(json: """
            {
              "enabled": true,
              "billingCycleEnd": 1800100000000,
              "planUsage": {
                "limit": 2000,
                "totalSpend": 500,
                "autoPercentUsed": 40,
                "apiPercentUsed": 12
              }
            }
            """),
            planResponse: httpResponse(json: """
            {"planInfo":{"planName":"Pro"}}
            """),
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(snapshot.provider, .cursor)
        XCTAssertEqual(snapshot.planName, "Pro")
        XCTAssertEqual(
            snapshot.windows.map(\.kind),
            [.totalUsage, .autoUsage, .apiUsage]
        )
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [25, 40, 12])
        XCTAssertEqual(
            snapshot.windows.first?.resetsAt,
            Date(timeIntervalSince1970: 1_800_100_000)
        )
    }

    func testCopilotConvertsRemainingQuotaToUsed() throws {
        let snapshot = try CopilotUsageMapper.map(
            response: httpResponse(json: """
            {
              "copilot_plan": "individual_pro",
              "quota_reset_date": "2027-01-15T00:00:00Z",
              "quota_snapshots": {
                "premium_interactions": {
                  "entitlement": 300,
                  "remaining": 225,
                  "percent_remaining": 75
                },
                "chat": {
                  "entitlement": 100,
                  "remaining": 80
                }
              }
            }
            """),
            now: Date()
        )

        XCTAssertEqual(snapshot.provider, .copilot)
        XCTAssertEqual(snapshot.planName, "Individual Pro")
        XCTAssertEqual(snapshot.windows.map(\.kind), [.credits, .chat])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [25, 20])
    }

    func testDevinMapsDailyAndWeeklyRemainingQuota() throws {
        let snapshot = try DevinUsageMapper.map(
            response: httpResponse(json: """
            {
              "userStatus": {
                "planStatus": {
                  "dailyQuotaRemainingPercent": 80,
                  "weeklyQuotaRemainingPercent": 35,
                  "dailyQuotaResetAtUnix": 1800003600,
                  "weeklyQuotaResetAtUnix": 1800604800,
                  "planInfo": {"planName": "Teams"}
                }
              }
            }
            """),
            now: Date()
        )

        XCTAssertEqual(snapshot.provider, .devin)
        XCTAssertEqual(snapshot.planName, "Teams")
        XCTAssertEqual(snapshot.windows.map(\.kind), [.daily, .weekly])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [20, 65])
    }

    func testGrokMapsWeeklyPoolAndPlan() throws {
        let snapshot = try GrokUsageMapper.map(
            response: httpResponse(json: """
            {
              "config": {
                "creditUsagePercent": 48,
                "currentPeriod": {
                  "type": "USAGE_PERIOD_TYPE_WEEKLY",
                  "end": "2027-01-15T00:00:00Z"
                }
              }
            }
            """),
            planResponse: httpResponse(json: """
            {"subscription_tier_display":"SuperGrok"}
            """),
            now: Date()
        )

        XCTAssertEqual(snapshot.provider, .grok)
        XCTAssertEqual(snapshot.planName, "SuperGrok")
        XCTAssertEqual(snapshot.windows.map(\.kind), [.weekly])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [48])
    }

    func testAntigravityMapsAllAuthoritativeQuotaPools() throws {
        let snapshot = try XCTUnwrap(AntigravityUsageMapper.summary(
            Data("""
            {
              "groups": [
                {"buckets": [
                  {"bucketId":"gemini-5h","remainingFraction":0.9},
                  {"bucketId":"gemini-weekly","remainingFraction":0.6},
                  {"bucketId":"3p-5h","remainingFraction":0.25},
                  {"bucketId":"3p-weekly","remainingFraction":0.1}
                ]}
              ]
            }
            """.utf8),
            planName: "Pro",
            now: Date()
        ))

        XCTAssertEqual(snapshot.provider, .antigravity)
        XCTAssertEqual(
            snapshot.windows.map(\.kind),
            [.session, .weekly, .claudePool, .claudePoolWeekly]
        )
        XCTAssertEqual(
            snapshot.windows.map(\.usedPercent),
            [10, 40, 75, 90]
        )
    }

    func testDeepSeekMapsBalanceFromStringValues() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = try DeepSeekUsageMapper.map(
            response: httpResponse(json: """
            {
              "is_available": true,
              "balance_infos": [
                {
                  "currency": "USD",
                  "total_balance": "4.84",
                  "granted_balance": "0.00",
                  "topped_up_balance": "4.84"
                }
              ]
            }
            """),
            now: now
        )

        XCTAssertEqual(snapshot.provider, .deepseek)
        XCTAssertTrue(snapshot.windows.isEmpty)
        XCTAssertEqual(
            snapshot.billingUsage,
            .balance(amount: 4.84, currencyCode: "USD")
        )
        XCTAssertEqual(snapshot.fetchedAt, now)
        XCTAssertEqual(
            snapshot.availableMenuBarItems,
            [MenuBarItemID(provider: .deepseek, metric: .balance)]
        )
    }

    func testDeepSeekFallsBackToUSDCurrency() throws {
        let snapshot = try DeepSeekUsageMapper.map(
            response: httpResponse(json: """
            {"is_available":true,"balance_infos":[{"total_balance":10}]}
            """),
            now: Date()
        )

        XCTAssertEqual(
            snapshot.billingUsage,
            .balance(amount: 10, currencyCode: "USD")
        )
    }

    func testDeepSeekRejectsUnauthorizedKey() {
        XCTAssertThrowsError(
            try DeepSeekUsageMapper.map(
                response: httpResponse(401, json: "{}"),
                now: Date()
            )
        ) { error in
            guard let failure = error as? ProviderFailure else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(failure.kind, .authentication)
        }
    }

    func testDeepSeekRejectsMissingBalanceInfo() {
        XCTAssertThrowsError(
            try DeepSeekUsageMapper.map(
                response: httpResponse(json: """
                {"is_available":true,"balance_infos":[]}
                """),
                now: Date()
            )
        ) { error in
            guard let failure = error as? ProviderFailure else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(failure.kind, .invalidResponse)
        }
    }

    private func claudeOAuth() -> ClaudeOAuth {
        ClaudeOAuth(
            accessToken: "token",
            refreshToken: nil,
            expiresAt: nil,
            subscriptionType: "pro",
            rateLimitTier: nil,
            scopes: ["user:profile"]
        )
    }
}

final class QwenMapperTests: XCTestCase {
    func testMapsAllReportedWindowsWithResets() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let usage = try QwenUsageMapper.payload(from: httpResponse(json: qwenGatewayJSON("""
            {"per5HourPercentage":0.5,"per5HourResetTime":1800003600000,
             "per1WeekPercentage":0.1,
             "per1MonthPercentage":0.0669,"per1MonthResetTime":1792684800000}
            """)))

        let snapshot = try QwenUsageMapper.map(
            usage: usage,
            subscription: ["specCode": "essential"],
            now: now
        )

        XCTAssertEqual(snapshot.provider, .qwen)
        XCTAssertEqual(snapshot.planName, "Essential")
        XCTAssertEqual(snapshot.windows.map(\.kind), [.fiveHour, .weekly, .monthly])
        XCTAssertEqual(snapshot.windows[0].usedPercent, 50, accuracy: 0.001)
        XCTAssertEqual(
            snapshot.windows[0].resetsAt,
            Date(timeIntervalSince1970: 1_800_003_600)
        )
        XCTAssertNil(snapshot.windows[1].resetsAt)
        XCTAssertEqual(snapshot.windows[2].usedPercent, 6.69, accuracy: 0.001)
        XCTAssertEqual(
            snapshot.windows[2].resetsAt,
            Date(timeIntervalSince1970: 1_792_684_800)
        )
    }

    func testRejectsUsageWithoutAnyWindow() {
        XCTAssertThrowsError(
            try QwenUsageMapper.map(usage: [:], subscription: nil, now: Date())
        ) { error in
            XCTAssertEqual((error as? ProviderFailure)?.kind, .invalidResponse)
        }
    }

    func testTreatsLoginRedirectAsExpiredSession() {
        let response = httpResponse(json: #"{"code":"ConsoleNeedLogin","data":null}"#)

        XCTAssertThrowsError(try QwenUsageMapper.payload(from: response)) { error in
            XCTAssertEqual((error as? ProviderFailure)?.kind, .authentication)
        }
        XCTAssertThrowsError(try QwenUsageMapper.secToken(from: response)) { error in
            XCTAssertEqual((error as? ProviderFailure)?.kind, .authentication)
        }
    }

    func testTreatsUnauthorizedStatusAsExpiredSession() {
        XCTAssertThrowsError(
            try QwenUsageMapper.payload(from: httpResponse(401))
        ) { error in
            XCTAssertEqual((error as? ProviderFailure)?.kind, .authentication)
        }
    }
}

final class ChromiumCookieReaderTests: XCTestCase {
    func testDecryptsValueAndStripsHostDigest() throws {
        let key = ChromiumCookieReader.deriveKey(password: "peanuts")
        let hostKey = ".qwencloud.com"
        var plain = Data(SHA256.hash(data: Data(hostKey.utf8)))
        plain.append(Data("ticket-value".utf8))
        var encrypted = Data("v10".utf8)
        encrypted.append(try XCTUnwrap(ChromiumCookieReader.aesEncrypt(plain, key: key)))

        let value = ChromiumCookieReader.decrypt(
            ChromiumCookieReader.RawCookie(
                hostKey: hostKey,
                name: "login_qwencloud_ticket",
                value: "",
                encryptedValue: encrypted,
                lastAccess: 0
            ),
            key: key
        )

        XCTAssertEqual(value, "ticket-value")
    }

    func testCookieDomainMatching() {
        let shared = BrowserCookie(hostKey: ".qwencloud.com", name: "a", value: "1")
        let hostOnly = BrowserCookie(hostKey: "home.qwencloud.com", name: "b", value: "2")

        XCTAssertTrue(shared.matches(host: "cs-data.qwencloud.com"))
        XCTAssertTrue(shared.matches(host: "qwencloud.com"))
        XCTAssertTrue(hostOnly.matches(host: "home.qwencloud.com"))
        XCTAssertFalse(hostOnly.matches(host: "cs-data.qwencloud.com"))
        XCTAssertFalse(shared.matches(host: "evilqwencloud.com"))
    }
}
