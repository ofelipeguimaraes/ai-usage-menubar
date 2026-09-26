import Foundation

struct KimiUsageClient: Sendable {
    let http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) { self.http = http }

    func fetch(_ resource: String, state: KimiAuthState) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: .get,
            url: state.baseURL.appendingPathComponent(resource),
            headers: ["Authorization": "Bearer \(state.credentials.accessToken)",
                      "Accept": "application/json"]
        ))
    }

    func refresh(_ state: KimiAuthState) async throws -> KimiCredentials {
        guard let refresh = state.credentials.refreshToken, !refresh.isEmpty else {
            throw KimiUsageMapper.sessionExpired
        }
        let response = try await http.send(HTTPRequest(
            method: .post,
            url: state.oauthHost.appendingPathComponent("api/oauth/token"),
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: ProviderParsing.formBody([
                ("client_id", "17e5f671-d194-4dfb-9706-5516cb48c098"),
                ("grant_type", "refresh_token"), ("refresh_token", refresh)
            ])
        ))
        try KimiUsageMapper.requireSuccess(response)
        guard var token = try? JSONDecoder().decode(KimiCredentials.self, from: response.body),
              !token.accessToken.isEmpty,
              let expiresIn = token.expiresIn, expiresIn.isFinite, expiresIn > 0 else {
            throw ProviderFailure(.invalidResponse, "Kimi token response changed.")
        }
        token.refreshToken = token.refreshToken ?? refresh
        return token
    }
}
