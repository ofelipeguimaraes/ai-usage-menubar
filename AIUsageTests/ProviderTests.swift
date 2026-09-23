import XCTest
@testable import AIUsage

final class ProviderTests: XCTestCase {
    func testClaudeRetriesOnceAfter401AndPersistsRotation() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oauth = ClaudeOAuth(
            accessToken: "old-access",
            refreshToken: "old-refresh",
            expiresAt: (now.timeIntervalSince1970 + 3_600) * 1_000,
            subscriptionType: "pro",
            rateLimitTier: "max_20x",
            scopes: ["user:profile"]
        )
        let keychain = MemoryKeychain(currentUser: [
            "Claude Code-credentials":
                encodedJSON(ClaudeCredentialsDocument(claudeAiOauth: oauth))
        ])
        let http = MockHTTPClient([
            httpResponse(401),
            httpResponse(json: """
            {
              "access_token": "new-access",
              "refresh_token": "new-refresh",
              "expires_in": 3600
            }
            """),
            httpResponse(json: """
            {"five_hour": {"utilization": 31, "resets_at": 1800003600}}
            """)
        ])
        let date = FixedDateProvider(value: now)
        let store = ClaudeAuthStore(
            environment: MockEnvironment(),
            files: MemoryFiles(),
            keychain: keychain,
            dateProvider: date
        )
        let provider = ClaudeProvider(
            authStore: store,
            client: ClaudeUsageClient(http: http),
            dateProvider: date
        )

        let snapshot = try await provider.fetch()

        XCTAssertEqual(snapshot.sessionWindow?.usedPercent, 31)
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.map(\.url), [
            ClaudeAuthStore.usageURL,
            ClaudeAuthStore.refreshURL,
            ClaudeAuthStore.usageURL
        ])
        let saved = try XCTUnwrap(keychain.currentValue(service: "Claude Code-credentials"))
        let savedDocument = try XCTUnwrap(
            ProviderParsing.decodeWithHexFallback(saved, as: ClaudeCredentialsDocument.self)
        )
        XCTAssertEqual(savedDocument.claudeAiOauth?.accessToken, "new-access")
        XCTAssertEqual(savedDocument.claudeAiOauth?.refreshToken, "new-refresh")
    }

    func testClaudeCooldownSkipsSecondRequestAfter429() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oauth = ClaudeOAuth(
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: (now.timeIntervalSince1970 + 3_600) * 1_000,
            subscriptionType: nil,
            rateLimitTier: nil,
            scopes: ["user:profile"]
        )
        let keychain = MemoryKeychain(currentUser: [
            "Claude Code-credentials":
                encodedJSON(ClaudeCredentialsDocument(claudeAiOauth: oauth))
        ])
        let http = MockHTTPClient([
            httpResponse(429, headers: ["Retry-After": "120"])
        ])
        let date = FixedDateProvider(value: now)
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: MockEnvironment(),
                files: MemoryFiles(),
                keychain: keychain,
                dateProvider: date
            ),
            client: ClaudeUsageClient(http: http),
            dateProvider: date
        )

        for _ in 0..<2 {
            do {
                _ = try await provider.fetch()
                XCTFail("Expected rate limit")
            } catch let failure as ProviderFailure {
                XCTAssertEqual(failure.kind, .rateLimited)
                XCTAssertEqual(
                    failure.retryAt,
                    now.addingTimeInterval(120)
                )
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }

        let requestCount = await http.capturedRequests().count
        XCTAssertEqual(requestCount, 1)
    }

    func testCodexProactiveRefreshUsesExactSourceAndFormEncoding() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let auth = CodexAuth(
            tokens: CodexTokens(
                accessToken: jwt(expiration: now.timeIntervalSince1970 + 60),
                refreshToken: "refresh +&",
                idToken: "old-id",
                accountID: "account-1"
            ),
            lastRefresh: nil,
            apiKey: nil
        )
        let files = MemoryFiles([
            "~/.config/codex/auth.json": encodedJSON(auth)
        ])
        let http = MockHTTPClient([
            httpResponse(json: """
            {
              "access_token": "new-access",
              "refresh_token": "new-refresh",
              "id_token": "new-id"
            }
            """),
            httpResponse(json: """
            {
              "plan_type": "pro",
              "rate_limit": {
                "primary_window": {
                  "used_percent": 9,
                  "limit_window_seconds": 18000
                }
              }
            }
            """)
        ])
        let date = FixedDateProvider(value: now)
        let provider = CodexProvider(
            authStore: CodexAuthStore(
                environment: MockEnvironment(),
                files: files,
                keychain: MemoryKeychain(),
                dateProvider: date
            ),
            client: CodexUsageClient(http: http),
            dateProvider: date
        )

        let snapshot = try await provider.fetch()

        XCTAssertEqual(snapshot.planName, "Pro 20x")
        XCTAssertEqual(snapshot.sessionWindow?.usedPercent, 9)
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.map(\.url), [
            CodexUsageClient.refreshURL,
            CodexUsageClient.usageURL
        ])
        let form = String(data: requests[0].body ?? Data(), encoding: .utf8)
        XCTAssertTrue(form?.contains("refresh_token=refresh%20%2B%26") == true)
        XCTAssertEqual(requests[1].headers["ChatGPT-Account-Id"], "account-1")

        let saved = try XCTUnwrap(files.value(at: "~/.config/codex/auth.json"))
        let savedAuth = try XCTUnwrap(CodexAuthStore.parseAuth(saved))
        XCTAssertEqual(savedAuth.tokens?.accessToken, "new-access")
        XCTAssertEqual(savedAuth.tokens?.refreshToken, "new-refresh")
    }

    func testDeepSeekFetchesBalanceWithOpenCodeAuthKey() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let files = MemoryFiles([
            DeepSeekAuthStore.authPaths[0]: """
            {"deepseek": {"type": "api", "key": "sk-deepseek"}}
            """
        ])
        let http = MockHTTPClient([
            httpResponse(json: """
            {
              "is_available": true,
              "balance_infos": [
                {"currency": "USD", "total_balance": "4.84"}
              ]
            }
            """)
        ])
        let provider = DeepSeekProvider(
            authStore: DeepSeekAuthStore(
                files: files,
                environment: MockEnvironment()
            ),
            client: DeepSeekUsageClient(http: http),
            dateProvider: FixedDateProvider(value: now)
        )

        let snapshot = try await provider.fetch()

        XCTAssertEqual(
            snapshot.billingUsage,
            .balance(amount: 4.84, currencyCode: "USD")
        )
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.map(\.url), [DeepSeekUsageClient.balanceURL])
        XCTAssertEqual(
            requests.first?.headers["Authorization"],
            "Bearer sk-deepseek"
        )
    }

    func testDeepSeekFailsWithoutAPIKey() async {
        let provider = DeepSeekProvider(
            authStore: DeepSeekAuthStore(
                files: MemoryFiles(),
                environment: MockEnvironment()
            ),
            client: DeepSeekUsageClient(
                http: MockHTTPClient([])
            ),
            dateProvider: FixedDateProvider(value: Date())
        )

        do {
            _ = try await provider.fetch()
            XCTFail("Expected authentication failure")
        } catch let failure as ProviderFailure {
            XCTAssertEqual(failure.kind, .authentication)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testQwenFetchesTokenPlanUsageFromConsoleSession() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let http = MockHTTPClient([
            httpResponse(json: #"{"code":"200","data":{"secToken":"sec-123"}}"#),
            httpResponse(json: qwenGatewayJSON(
                #"{"per1MonthPercentage":0.0669,"per1MonthResetTime":1792684800000}"#
            )),
            httpResponse(json: qwenGatewayJSON(
                #"{"specCode":"essential","remainingDays":29}"#
            ))
        ])
        let provider = QwenProvider(
            authStore: QwenAuthStore(cookies: MockBrowserCookieReader(
                session: qwenSession
            )),
            client: QwenUsageClient(http: http),
            dateProvider: FixedDateProvider(value: now)
        )

        let snapshot = try await provider.fetch()

        XCTAssertEqual(snapshot.planName, "Essential")
        XCTAssertEqual(snapshot.windows.map(\.kind), [.monthly])
        XCTAssertEqual(snapshot.windows[0].usedPercent, 6.69, accuracy: 0.001)

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[0].url, QwenUsageClient.userInfoURL)
        XCTAssertEqual(
            requests[1].headers["Cookie"],
            "login_qwencloud_ticket=ticket; login_aliyunid_csrf=csrf-token"
        )
        XCTAssertEqual(requests[1].headers["x-csrf-token"], "csrf-token")
        let body = String(decoding: requests[1].body ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("sec_token=sec-123"))
        XCTAssertTrue(requests[1].url.absoluteString.contains("tokenplan"))
    }

    func testQwenKeepsUsageWhenSubscriptionLookupFails() async throws {
        let http = MockHTTPClient([
            httpResponse(json: #"{"code":"200","data":{"secToken":"sec-123"}}"#),
            httpResponse(json: qwenGatewayJSON(#"{"per5HourPercentage":0.25}"#)),
            httpResponse(500)
        ])
        let provider = QwenProvider(
            authStore: QwenAuthStore(cookies: MockBrowserCookieReader(
                session: qwenSession
            )),
            client: QwenUsageClient(http: http),
            dateProvider: FixedDateProvider(value: Date())
        )

        let snapshot = try await provider.fetch()

        XCTAssertEqual(snapshot.planName, QwenUsageMapper.defaultPlanName)
        XCTAssertEqual(snapshot.windows.map(\.kind), [.fiveHour])
    }

    func testQwenRequiresBrowserSession() async {
        let provider = QwenProvider(
            authStore: QwenAuthStore(cookies: MockBrowserCookieReader(session: nil)),
            client: QwenUsageClient(http: MockHTTPClient([])),
            dateProvider: FixedDateProvider(value: Date())
        )

        do {
            _ = try await provider.fetch()
            XCTFail("Expected authentication failure")
        } catch let failure as ProviderFailure {
            XCTAssertEqual(failure.kind, .authentication)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private let qwenSession = BrowserCookieSession(
    browser: "Brave",
    cookies: [
        BrowserCookie(
            hostKey: ".qwencloud.com",
            name: "login_qwencloud_ticket",
            value: "ticket"
        ),
        BrowserCookie(
            hostKey: ".qwencloud.com",
            name: "login_aliyunid_csrf",
            value: "csrf-token"
        ),
        BrowserCookie(
            hostKey: "account.qwencloud.com",
            name: "account_only",
            value: "ignored"
        )
    ]
)

private struct MockBrowserCookieReader: BrowserCookieReading {
    let session: BrowserCookieSession?

    func session(
        domainSuffixes: [String],
        requiredNames: Set<String>
    ) throws -> BrowserCookieSession? {
        session
    }
}
