import Foundation

struct KimiCredentials: Codable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Double?
    var scope: String?
    var tokenType: String?
    var expiresIn: Double?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
        case scope
        case tokenType = "token_type"
        case expiresIn = "expires_in"
    }
}

struct KimiAuthState: Sendable {
    let path: String
    let baseURL: URL
    let oauthHost: URL
    var credentials: KimiCredentials
}

struct KimiAuthStore: Sendable {
    let files: any TextFileAccessing
    let environment: any EnvironmentReading

    init(files: any TextFileAccessing = LocalTextFileAccessor(),
         environment: any EnvironmentReading = ProcessEnvironmentReader()) {
        self.files = files
        self.environment = environment
    }

    func load() throws -> KimiAuthState? {
        let homes = [environment.value(for: "KIMI_CODE_HOME") ?? "~/.kimi-code",
                     environment.value(for: "KIMI_SHARE_DIR") ?? "~/.kimi"]
        for home in homes {
            let config = (try? files.readText(home + "/config.toml")) ?? ""
            // Restrict credential destinations to the official Kimi API hosts.
            // The OAuth reference may be inline or in a `[providers."managed:kimi-code".oauth]` sub-table.
            let managed = config.components(separatedBy: "\n[")
                .filter { $0.contains("providers.") && $0.contains("managed:kimi-code") }
                .joined(separator: "\n[")
            let global = managed.contains("https://api.kimi.ai/coding/v1") ||
                (managed.isEmpty && (try? files.readText(home + "/region"))?.trimmingCharacters(in: .whitespacesAndNewlines) == "global")
            let key = capture(#"key\s*=\s*"oauth/([A-Za-z0-9_-]+)""#, in: managed) ?? "kimi-code"
            let path = home + "/credentials/" + key + ".json"
            guard files.exists(path) else { continue }
            guard let data = try files.readText(path).data(using: .utf8),
                  let credentials = try? JSONDecoder().decode(KimiCredentials.self, from: data),
                  !credentials.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProviderFailure(.storage, "Kimi credentials could not be read. Run `kimi login`.")
            }
            return KimiAuthState(
                path: path,
                baseURL: URL(string: global ? "https://api.kimi.ai/coding/v1" : "https://api.kimi.com/coding/v1")!,
                oauthHost: URL(string: global ? "https://auth.kimi.ai" : "https://auth.kimi.com")!,
                credentials: credentials
            )
        }
        return nil
    }

    func save(_ state: KimiAuthState, replacing original: KimiCredentials) throws {
        // Avoid replacing credentials rotated by a concurrently running CLI.
        let data = Data(try files.readText(state.path).utf8)
        let current = try JSONDecoder().decode(KimiCredentials.self, from: data)
        guard current.refreshToken == original.refreshToken,
              current.accessToken == original.accessToken else {
            throw ProviderFailure(.transient, "Kimi credentials changed. Refresh usage again.")
        }
        let encoded = try JSONEncoder().encode(state.credentials)
        try files.writeText(state.path, String(decoding: encoded, as: UTF8.self))
    }

    private func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
