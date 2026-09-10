import XCTest
@testable import AIUsage

/// The payload a running `agy` serves on its loopback listener for a Starter
/// account: weekly buckets only, no session window.
private let runningCLISummary = """
{
  "response": {
    "groups": [
      {
        "displayName": "Gemini Models",
        "buckets": [
          {
            "bucketId": "gemini-weekly",
            "window": "weekly",
            "remainingFraction": 0.3869904,
            "resetTime": "2026-09-16T15:20:32Z"
          }
        ]
      },
      {
        "displayName": "Claude and GPT models",
        "buckets": [
          {
            "bucketId": "3p-weekly",
            "window": "weekly",
            "remainingFraction": 1,
            "resetTime": "2026-09-17T02:55:57Z"
          }
        ]
      }
    ]
  }
}
"""

private struct StubProcessRunner: ProcessRunning {
    let stdout: String

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: stdout, stderr: "")
    }
}

final class AntigravityLocalQuotaTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_757_462_400)

    private func isolatedDefaults(
        _ name: String = #function
    ) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "test.\(name)")!
        defaults.removePersistentDomain(forName: "test.\(name)")
        return defaults
    }

    /// A signed-in Keychain entry, so the tests never touch the real one.
    private var signedInAuthStore: AntigravityAuthStore {
        AntigravityAuthStore(
            runner: StubProcessRunner(stdout: "Bearer test-access"),
            files: MemoryFiles(),
            dateProvider: FixedDateProvider(value: now)
        )
    }

    /// A CLI that is not running: `lsof` reports nothing to probe.
    private var closedCLI: AntigravityLocalClient {
        AntigravityLocalClient(
            runner: StubProcessRunner(stdout: ""),
            probe: { _ in nil }
        )
    }

    // MARK: - Port discovery

    func testReadsLoopbackPortsOfTheRunningCLIOnly() {
        let lsof = """
        COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
        agy     88535  me   10u  IPv4 0xe0f7      0t0  TCP 127.0.0.1:54908 (LISTEN)
        agy     88535  me   12u  IPv4 0x8efa      0t0  TCP 127.0.0.1:54909 (LISTEN)
        agyx    99999  me   11u  IPv4 0x1234      0t0  TCP 127.0.0.1:6000 (LISTEN)
        agy     88535  me   13u  IPv4 0x5678      0t0  TCP 192.168.0.5:7000 (LISTEN)
        """
        let client = AntigravityLocalClient(
            runner: StubProcessRunner(stdout: lsof),
            probe: { _ in nil }
        )
        XCTAssertEqual(client.listeningPorts(), [54908, 54909])
    }

    func testIgnoresListenerThatAnswersWithoutQuotaGroups() async {
        let csrfRejection = Data(
            #"{"code":"unauthenticated","message":"missing CSRF token"}"#.utf8
        )
        let client = AntigravityLocalClient(
            runner: StubProcessRunner(stdout: """
            agy 1 me 10u IPv4 0x1 0t0 TCP 127.0.0.1:5000 (LISTEN)
            """),
            probe: { _ in csrfRejection }
        )
        let summary = await client.summary()
        XCTAssertNil(summary)
    }

    // MARK: - Mapping

    func testWeeklyOnlyAccountNeverGainsAnInventedSessionWindow() throws {
        let snapshot = try XCTUnwrap(AntigravityUsageMapper.summary(
            Data(runningCLISummary.utf8),
            planName: "Starter",
            now: now
        ))
        XCTAssertEqual(
            snapshot.windows.map(\.kind),
            [.weekly, .claudePoolWeekly]
        )
        XCTAssertNil(snapshot.sessionWindow)
        XCTAssertEqual(
            snapshot.windows.first?.usedPercent ?? 0,
            61,
            accuracy: 0.5
        )
    }

    // MARK: - Cache

    func testKeepsWeeklyReadingAndDropsShortLivedWindows() throws {
        let cache = AntigravitySnapshotCache(defaults: isolatedDefaults())
        cache.save(ProviderSnapshot(
            provider: .antigravity,
            planName: "Starter",
            windows: [
                QuotaWindow(
                    kind: .session,
                    usedPercent: 20,
                    resetsAt: now.addingTimeInterval(3_600)
                ),
                QuotaWindow(
                    kind: .weekly,
                    usedPercent: 61,
                    resetsAt: now.addingTimeInterval(600_000)
                )
            ],
            fetchedAt: now
        ))
        let restored = try XCTUnwrap(cache.load(now: now))
        XCTAssertEqual(restored.windows.map(\.kind), [.weekly])
        XCTAssertEqual(restored.planName, "Starter")
    }

    func testDropsCachedWindowAfterItsResetTimePasses() {
        let cache = AntigravitySnapshotCache(defaults: isolatedDefaults())
        cache.save(ProviderSnapshot(
            provider: .antigravity,
            planName: "Starter",
            windows: [
                QuotaWindow(
                    kind: .weekly,
                    usedPercent: 61,
                    resetsAt: now.addingTimeInterval(60)
                )
            ],
            fetchedAt: now
        ))
        XCTAssertNil(cache.load(now: now.addingTimeInterval(120)))
    }

    // MARK: - Provider

    /// The bug in the report: a denied summary used to surface as
    /// "session expired", and the models fallback filled the card with 100%.
    func testDeniedSummaryReportsNothingRatherThanAFalseHundredPercent() async {
        let provider = AntigravityProvider(
            authStore: signedInAuthStore,
            client: AntigravityUsageClient(
                http: MockHTTPClient([httpResponse(403), httpResponse(403)])
            ),
            localClient: closedCLI,
            cache: AntigravitySnapshotCache(defaults: isolatedDefaults()),
            dateProvider: FixedDateProvider(value: now)
        )
        do {
            let snapshot = try await provider.fetch()
            XCTFail("Expected no reading, got \(snapshot.windows)")
        } catch let failure as ProviderFailure {
            XCTAssertNotEqual(
                failure.kind,
                .authentication,
                "A denied quota endpoint is not a sign-in problem."
            )
            XCTAssertTrue(failure.preservesLastGood)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    /// With the CLI closed the card keeps the last authoritative reading, and
    /// keeps it as a normal value: no failure means no stale warning.
    func testKeepsLastReadingSilentlyWhenTheCLIIsNotRunning() async throws {
        let defaults = isolatedDefaults()
        AntigravitySnapshotCache(defaults: defaults).save(ProviderSnapshot(
            provider: .antigravity,
            planName: "Starter",
            windows: [
                QuotaWindow(
                    kind: .weekly,
                    usedPercent: 61,
                    resetsAt: now.addingTimeInterval(600_000)
                )
            ],
            fetchedAt: now
        ))
        let provider = AntigravityProvider(
            authStore: signedInAuthStore,
            client: AntigravityUsageClient(
                http: MockHTTPClient([httpResponse(403), httpResponse(403)])
            ),
            localClient: closedCLI,
            cache: AntigravitySnapshotCache(defaults: defaults),
            dateProvider: FixedDateProvider(value: now)
        )
        let snapshot = try await provider.fetch()
        XCTAssertEqual(snapshot.windows.map(\.kind), [.weekly])
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 61)
    }
}
