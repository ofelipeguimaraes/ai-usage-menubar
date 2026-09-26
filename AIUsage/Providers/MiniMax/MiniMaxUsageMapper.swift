import Foundation

enum MiniMaxUsageMapper {
    static func map(usage: HTTPResponse, plan: HTTPResponse?, now: Date) throws -> ProviderSnapshot {
        let root = try payload(usage)
        let models = ProviderParsing.array(root["model_remains"])
        // The current Token Plan uses a unified general bucket. Video can be
        // returned as 100% remaining even when it is not included in the plan.
        let general = models.filter { ProviderParsing.string($0["model_name"])?.lowercased() == "general" }
        let buckets = general.isEmpty ? models.filter {
            ProviderParsing.string($0["model_name"])?.lowercased().hasPrefix("minimax-m") == true
        } : general
        var windows: [QuotaWindow] = []
        for (kind, prefix, resetKey) in [(QuotaKind.fiveHour, "current_interval", "end_time"),
                                          (.weekly, "current_weekly", "weekly_end_time")] {
            let candidates = buckets.compactMap { bucket -> QuotaWindow? in
                guard ProviderParsing.double(bucket[prefix + "_status"]) != 3,
                      let used = usedPercent(bucket, prefix: prefix) else { return nil }
                let reset = millisecondsDate(bucket[resetKey])
                return QuotaWindow(kind: kind, usedPercent: used, resetsAt: reset)
            }
            if let window = candidates.max(by: { $0.usedPercent < $1.usedPercent }) {
                windows.append(window)
            }
        }
        guard !windows.isEmpty else {
            throw ProviderFailure(.invalidResponse, "MiniMax Token Plan has no supported active quota data.")
        }
        return ProviderSnapshot(provider: .minimax, planName: planName(plan) ?? "Token Plan",
                                windows: windows, fetchedAt: now)
    }

    static func payload(_ response: HTTPResponse) throws -> [String: Any] {
        switch response.statusCode {
        case 200..<300: break
        case 401, 403:
            throw ProviderFailure(.authentication, "MiniMax Subscription Key was rejected. Reconnect it in OpenCode.")
        case 429:
            throw ProviderFailure(.rateLimited, "MiniMax usage requests are temporarily rate limited.")
        case 500...599:
            throw ProviderFailure(.transient, "MiniMax usage is temporarily unavailable.")
        default:
            throw ProviderFailure(.invalidResponse, "MiniMax usage request failed (\(response.statusCode)).")
        }
        let root = try ProviderParsing.object(from: response.body)
        guard let status = ProviderParsing.object(root["base_resp"]),
              let code = ProviderParsing.double(status["status_code"]), code.isFinite else {
            throw ProviderFailure(.invalidResponse, "MiniMax usage response changed.")
        }
        guard code == 0 else {
            if code == 1004 {
                throw ProviderFailure(.authentication, "MiniMax Subscription Key was rejected. Reconnect it in OpenCode.")
            }
            if code == 2062 {
                throw ProviderFailure(.invalidResponse, "MiniMax reports no active Token Plan subscription for this key.")
            }
            throw ProviderFailure(.invalidResponse, "MiniMax usage request failed (API status \(code)).")
        }
        return root
    }

    private static func usedPercent(_ bucket: [String: Any], prefix: String) -> Double? {
        if bucket[prefix + "_remaining_percent"] != nil {
            guard let remaining = ProviderParsing.double(bucket[prefix + "_remaining_percent"]),
                  remaining.isFinite, (0...100).contains(remaining) else { return nil }
            return 100 - remaining
        }
        // Legacy count responses report remaining prompts, despite the name.
        guard let total = ProviderParsing.double(bucket[prefix + "_total_count"]),
              let remaining = ProviderParsing.double(bucket[prefix + "_usage_count"]),
              total.isFinite, remaining.isFinite, total > 0, (0...total).contains(remaining) else { return nil }
        return (1 - remaining / total) * 100
    }

    private static func millisecondsDate(_ value: Any?) -> Date? {
        guard let milliseconds = ProviderParsing.double(value), milliseconds.isFinite,
              milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    private static func planName(_ response: HTTPResponse?) -> String? {
        guard let response, let root = try? payload(response),
              let subscription = ProviderParsing.object(root["current_subscribe"]),
              let title = ProviderParsing.string(subscription["current_subscribe_title"]),
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let words = title.lowercased().split { !$0.isLetter }
        for tier in ["Ultra", "Max", "Plus", "Starter"] where words.contains(Substring(tier.lowercased())) {
            return tier
        }
        return title
    }
}
