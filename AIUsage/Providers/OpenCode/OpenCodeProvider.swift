import Foundation

actor OpenCodeProvider: UsageProvider {
    nonisolated let id = ProviderID.opencode
    private let authStore: OpenCodeAuthStore
    private let client: OpenCodeUsageClient
    private let dateProvider: any DateProviding

    init(authStore: OpenCodeAuthStore = OpenCodeAuthStore(),
         client: OpenCodeUsageClient = OpenCodeUsageClient(),
         dateProvider: any DateProviding = SystemDateProvider()) {
        self.authStore = authStore
        self.client = client
        self.dateProvider = dateProvider
    }

    func fetch() async throws -> ProviderSnapshot {
        guard let token = authStore.loadToken() else {
            throw ProviderFailure(.authentication, "Connect OpenCode Zen or Go in OpenCode.")
        }
        return try OpenCodeUsageMapper.map(await client.fetchUsage(token: token), now: dateProvider.now())
    }
}

enum OpenCodeUsageMapper {
    static func map(_ response: HTTPResponse, now: Date) throws -> ProviderSnapshot {
        switch response.statusCode {
        case 200..<300: break
        case 401: throw ProviderFailure(.authentication, "OpenCode API key was rejected. Reconnect OpenCode.")
        case 403:
            let root = try? ProviderParsing.object(from: response.body)
            let error = ProviderParsing.object(root?["error"])
            // The server validates the key before checking Go entitlement.
            // Only this specific structured response confirms a Zen-only account.
            if ProviderParsing.string(error?["type"]) == "EntitlementError",
               ProviderParsing.string(error?["message"]) == "OpenCode Go subscription required." {
                return ProviderSnapshot(provider: .opencode, planName: "Zen", windows: [],
                    statusMessage: "Pay-as-you-go. View your balance in OpenCode.", fetchedAt: now)
            }
            throw ProviderFailure(.transient, "OpenCode usage is temporarily unavailable. Try again later.")
        case 429: throw ProviderFailure(.rateLimited, "OpenCode usage requests are temporarily rate limited.")
        case 500...599: throw ProviderFailure(.transient, "OpenCode usage is temporarily unavailable.")
        default: throw ProviderFailure(.invalidResponse, "OpenCode usage request failed (\(response.statusCode)).")
        }
        let root = try ProviderParsing.object(from: response.body)
        guard let usage = ProviderParsing.object(root["usage"]) else {
            throw ProviderFailure(.invalidResponse, "OpenCode usage response changed.")
        }
        let windows = [("rolling", QuotaKind.fiveHour), ("weekly", .weekly), ("monthly", .monthly)].compactMap { key, kind -> QuotaWindow? in
            guard let window = ProviderParsing.object(usage[key]),
                  let percent = ProviderParsing.double(window["percent"]), percent.isFinite,
                  (0...100).contains(percent) else { return nil }
            return QuotaWindow(kind: kind, usedPercent: percent,
                               resetsAt: ProviderParsing.date(window["resetsAt"]))
        }
        guard !windows.isEmpty else {
            throw ProviderFailure(.invalidResponse, "OpenCode has no supported quota data.")
        }
        // This endpoint requires Go entitlement; Zen is pay-as-you-go, not this plan.
        return ProviderSnapshot(provider: .opencode, planName: "Go", windows: windows, fetchedAt: now)
    }
}
