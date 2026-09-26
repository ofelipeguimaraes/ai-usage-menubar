import XCTest
@testable import AIUsage

final class OpenCodeAccountTests: XCTestCase {
    func testExplicitMissingGoEntitlementConfirmsZenWithoutAnError() throws {
        let snapshot = try OpenCodeUsageMapper.map(httpResponse(403, json: """
            {"type":"error","error":{"type":"EntitlementError","message":"OpenCode Go subscription required."}}
            """), now: Date())
        XCTAssertEqual(snapshot.planName, "Zen")
        XCTAssertNotNil(snapshot.statusMessage)
        XCTAssertTrue(snapshot.windows.isEmpty)
        XCTAssertNil(snapshot.billingUsage)
        XCTAssertTrue(snapshot.availableMenuBarItems.isEmpty)
    }

    func testUnstructuredForbiddenDoesNotGuessThePlan() {
        for body in ["error code: 1010", "{\"error\":{\"type\":\"AuthError\"}}", "{\"error\":{\"type\":\"EntitlementError\",\"message\":\"Access denied\"}}"] {
            XCTAssertThrowsError(try OpenCodeUsageMapper.map(httpResponse(403, json: body), now: Date())) {
                XCTAssertEqual(($0 as? ProviderFailure)?.kind, .transient)
            }
        }
    }

    func testClientIdentifiesTheAppForTheUsageAPI() async throws {
        let http = MockHTTPClient([httpResponse(403, json: """
            {"error":{"type":"EntitlementError","message":"OpenCode Go subscription required."}}
            """)])
        let provider = OpenCodeProvider(authStore: OpenCodeAuthStore(files: MemoryFiles(),
            environment: MockEnvironment(values: ["OPENCODE_API_KEY": "test-key"]), keychain: MemoryKeychain()),
            client: OpenCodeUsageClient(http: http))
        let snapshot = try await provider.fetch()
        XCTAssertEqual(snapshot.planName, "Zen")
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.first?.headers["User-Agent"], "AIUsage")
        XCTAssertEqual(requests.first?.headers["Authorization"], "Bearer test-key")
    }
}
