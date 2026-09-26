import Foundation

enum ZaiUsageMapper {
    static func map(_ response: HTTPResponse, now: Date) throws -> ProviderSnapshot {
        switch response.statusCode {
        case 200..<300: break
        case 401, 403: throw authenticationFailure
        case 429: throw ProviderFailure(.rateLimited, "GLM usage requests are temporarily rate limited.")
        case 500...599: throw ProviderFailure(.transient, "GLM usage is temporarily unavailable.")
        default: throw ProviderFailure(.invalidResponse, "GLM usage request failed (\(response.statusCode)).")
        }
        let root = try ProviderParsing.object(from: response.body)
        let code = ProviderParsing.double(root["code"])
        if code == 401 || code == 403 { throw authenticationFailure }
        guard code == 200, root["success"] as? Bool == true,
              let data = ProviderParsing.object(root["data"]) else {
            throw ProviderFailure(.invalidResponse, "GLM usage response changed or reports an API failure.")
        }
        var windows: [QuotaWindow] = []
        for limit in ProviderParsing.array(data["limits"]) {
            let type = ProviderParsing.string(limit["type"])
            let unit = ProviderParsing.double(limit["unit"])
            let number = ProviderParsing.double(limit["number"])
            let kind: QuotaKind
            switch (type, unit, number) {
            case ("CREDIT_LIMIT", 3, 5), ("TOKENS_LIMIT", 3, 5): kind = .fiveHour
            case ("CREDIT_LIMIT", 6, 1), ("TOKENS_LIMIT", 6, 1): kind = .weekly
            case ("TIME_LIMIT", 5, 1): kind = .mcpMonthly
            default: continue
            }
            // The service rounds percentage separately from currentValue/remaining.
            guard let used = ProviderParsing.double(limit["percentage"]),
                  used.isFinite, (0...100).contains(used) else { continue }
            let reset = ProviderParsing.double(limit["nextResetTime"]).flatMap {
                $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil
            }
            let window = QuotaWindow(kind: kind, usedPercent: used, resetsAt: reset)
            if let index = windows.firstIndex(where: { $0.kind == kind }) {
                if used > windows[index].usedPercent { windows[index] = window }
            } else { windows.append(window) }
        }
        guard !windows.isEmpty else {
            throw ProviderFailure(.invalidResponse, "GLM Coding Plan has no supported quota data.")
        }
        let level = ProviderParsing.string(data["level"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        let plan = level.flatMap { $0.isEmpty ? nil : $0.capitalized } ?? "Coding Plan"
        return ProviderSnapshot(provider: .zai, planName: plan, windows: windows, fetchedAt: now)
    }

    private static var authenticationFailure: ProviderFailure {
        ProviderFailure(.authentication, "GLM Coding Plan key was rejected. Reconnect Z.ai in OpenCode.")
    }
}
