import Foundation

enum QwenUsageMapper {
    static let defaultPlanName = "Token Plan"

    static func secToken(from response: HTTPResponse) throws -> String {
        try requireSuccess(response)
        guard let body = try? ProviderParsing.object(from: response.body),
              let data = ProviderParsing.object(body["data"]),
              let token = ProviderParsing.string(data["secToken"]) else {
            throw sessionExpired
        }
        return token
    }

    /// Unwraps the console gateway envelope:
    /// `data.DataV2.data.data` holds the payload of the inner API.
    static func payload(from response: HTTPResponse) throws -> [String: Any] {
        try requireSuccess(response)
        guard let body = try? ProviderParsing.object(from: response.body) else {
            throw sessionExpired
        }
        let outer = ProviderParsing.object(body["data"])
        let inner = ProviderParsing.object(
            ProviderParsing.object(outer?["DataV2"])?["data"]
        )
        guard let inner,
              ProviderParsing.string(inner["code"]) == "SUCCESS",
              let payload = ProviderParsing.object(inner["data"]) else {
            if let code = ProviderParsing.string(body["code"]), code != "200" {
                throw sessionExpired
            }
            if let error = ProviderParsing.string(outer?["errorCode"]),
               error.localizedCaseInsensitiveContains("login") {
                throw sessionExpired
            }
            throw ProviderFailure(
                .invalidResponse,
                "QwenCloud Token Plan response changed."
            )
        }
        return payload
    }

    static func map(
        usage: [String: Any],
        subscription: [String: Any]?,
        now: Date
    ) throws -> ProviderSnapshot {
        let windows: [QuotaWindow] = [
            window(.fiveHour, usage, "per5HourPercentage", "per5HourResetTime"),
            window(.weekly, usage, "per1WeekPercentage", "per1WeekResetTime"),
            window(.monthly, usage, "per1MonthPercentage", "per1MonthResetTime")
        ].compactMap { $0 }

        guard !windows.isEmpty else {
            throw ProviderFailure(
                .invalidResponse,
                "QwenCloud Token Plan usage is unavailable."
            )
        }

        let planName = ProviderParsing.string(subscription?["specCode"])
            .map(ProviderParsing.titleCaseIdentifier) ?? defaultPlanName

        return ProviderSnapshot(
            provider: .qwen,
            planName: planName,
            windows: windows,
            fetchedAt: now
        )
    }

    /// The gateway reports usage as a 0...1 ratio of the plan quota.
    private static func window(
        _ kind: QuotaKind,
        _ usage: [String: Any],
        _ ratioKey: String,
        _ resetKey: String
    ) -> QuotaWindow? {
        guard let ratio = ProviderParsing.double(usage[ratioKey]) else { return nil }
        return QuotaWindow(
            kind: kind,
            usedPercent: ratio * 100,
            resetsAt: ProviderParsing.date(usage[resetKey])
        )
    }

    private static func requireSuccess(_ response: HTTPResponse) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 401, 403:
            throw sessionExpired
        default:
            throw ProviderFailure(
                response.statusCode >= 500 ? .transient : .invalidResponse,
                "QwenCloud usage request failed (\(response.statusCode))."
            )
        }
    }

    static let sessionExpired = ProviderFailure(
        .authentication,
        "QwenCloud session expired. Sign in at home.qwencloud.com in your browser."
    )
}
