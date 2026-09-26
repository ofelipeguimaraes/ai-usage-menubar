import Foundation

enum KimiUsageMapper {
    static let sessionExpired = ProviderFailure(
        .authentication, "Sign in to Kimi Code. Run `kimi login`."
    )

    static func requireSuccess(_ response: HTTPResponse) throws {
        switch response.statusCode {
        case 200..<300: return
        case 401, 403: throw sessionExpired
        case 429, 500...599:
            throw ProviderFailure(.transient, "Kimi usage is temporarily unavailable (\(response.statusCode)).")
        default:
            throw ProviderFailure(.invalidResponse, "Kimi usage request failed (\(response.statusCode)).")
        }
    }

    static func map(usage: HTTPResponse, profile: HTTPResponse?, now: Date) throws -> ProviderSnapshot {
        try requireSuccess(usage)
        let root = try ProviderParsing.object(from: usage.body)
        var windows: [QuotaWindow] = []
        // Show actionable limits only; month_code is attribution, not a quota.
        if let quotas = ProviderParsing.object(root["usages"]) {
            for (key, kind) in [("limit_5h", QuotaKind.fiveHour), ("limit_7d", .weekly),
                                ("limit_month_total", .monthly)] {
                guard let quota = ProviderParsing.object(quotas[key]),
                      let ratio = ProviderParsing.double(quota["used_ratio"]), ratio.isFinite else { continue }
                windows.append(QuotaWindow(kind: kind, usedPercent: ratio * 100,
                                           resetsAt: ProviderParsing.date(quota["reset_time"])))
            }
        }
        // Legacy accounts return absolute counters instead of named ratios.
        if windows.isEmpty {
            if let summary = ProviderParsing.object(root["usage"]),
               let window = legacyWindow(summary, kind: .weekly) { windows.append(window) }
        }
        // Current accounts can return both formats. The named 5-hour ratio can
        // stay at zero even when the request counter reports an exhausted quota.
        for item in ProviderParsing.array(root["limits"]) {
            guard let duration = ProviderParsing.object(item["window"]),
                  ProviderParsing.double(duration["duration"]) == 300,
                  ProviderParsing.string(duration["timeUnit"]) == "TIME_UNIT_MINUTE",
                  let detail = ProviderParsing.object(item["detail"]),
                  let window = legacyWindow(detail, kind: .fiveHour) else { continue }
            if let index = windows.firstIndex(where: { $0.kind == .fiveHour }) {
                if window.usedPercent >= windows[index].usedPercent { windows[index] = window }
            } else { windows.append(window) }
        }
        guard !windows.isEmpty else {
            throw ProviderFailure(.invalidResponse, "Kimi usage response contains no supported quota data.")
        }
        var plan: String?
        if let profile, (200..<300).contains(profile.statusCode),
           let info = try? ProviderParsing.object(from: profile.body) {
            plan = ProviderParsing.string(info["user_level_name"])
        }
        return ProviderSnapshot(provider: .kimi, planName: plan, windows: windows,
                                billingUsage: extraUsage(root), fetchedAt: now)
    }

    private static func legacyWindow(_ quota: [String: Any], kind: QuotaKind) -> QuotaWindow? {
        guard let limit = ProviderParsing.double(quota["limit"]), limit.isFinite, limit > 0,
              let used = ProviderParsing.double(quota["used"])
                ?? ProviderParsing.double(quota["remaining"]).map({ limit - $0 }), used.isFinite else { return nil }
        return QuotaWindow(kind: kind, usedPercent: used / limit * 100,
                           resetsAt: ProviderParsing.date(quota["resetTime"] ?? quota["reset_at"]))
    }

    private static func extraUsage(_ root: [String: Any]) -> BillingUsage? {
        guard let wallet = ProviderParsing.object(root["boosterWallet"]),
              let balance = ProviderParsing.object(wallet["balance"]),
              ProviderParsing.string(balance["type"]) == "BOOSTER",
              let amount = ProviderParsing.double(balance["amountLeft"]), amount.isFinite, amount >= 0 else { return nil }
        let charge = ProviderParsing.object(wallet["monthlyChargeLimit"])
        let used = ProviderParsing.object(wallet["monthlyUsed"])
        let currency = ProviderParsing.string(charge?["currency"])
            ?? ProviderParsing.string(used?["currency"]) ?? "USD"
        // Kimi stores wallet amounts as fixed-point millionths of a cent.
        return .balance(amount: amount / 100_000_000, currencyCode: currency)
    }
}
