import Foundation

enum DeepSeekUsageMapper {
    static func map(
        response: HTTPResponse,
        now: Date
    ) throws -> ProviderSnapshot {
        switch response.statusCode {
        case 401, 403:
            throw ProviderFailure(
                .authentication,
                "DeepSeek API key is invalid."
            )
        case 200..<300:
            break
        default:
            throw ProviderFailure(
                response.statusCode >= 500 ? .transient : .invalidResponse,
                "DeepSeek balance request failed (\(response.statusCode))."
            )
        }

        let body = try ProviderParsing.object(from: response.body)
        let infos = ProviderParsing.array(body["balance_infos"])
        guard let info = infos.first,
              let total = ProviderParsing.double(info["total_balance"]) else {
            throw ProviderFailure(
                .invalidResponse,
                "DeepSeek balance response changed."
            )
        }
        let currency = ProviderParsing.string(info["currency"]) ?? "USD"

        return ProviderSnapshot(
            provider: .deepseek,
            planName: "API",
            windows: [],
            billingUsage: .balance(
                amount: total,
                currencyCode: currency
            ),
            fetchedAt: now
        )
    }
}
