import Foundation

struct MiniMaxUsageClient: Sendable {
    let http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) { self.http = http }

    func fetchUsage(credentials: MiniMaxCredentials) async throws -> HTTPResponse {
        try await request(path: "/v1/token_plan/remains", credentials: credentials)
    }

    func fetchPlan(credentials: MiniMaxCredentials) async throws -> HTTPResponse {
        // This is the console's read-only subscription query, not a purchase.
        try await request(
            path: "/v1/api/openplatform/charge/combo/cycle_audio_resource_package",
            query: [URLQueryItem(name: "biz_line", value: "2"),
                    URLQueryItem(name: "cycle_type", value: "1"),
                    URLQueryItem(name: "resource_package_type", value: "7")],
            credentials: credentials
        )
    }

    private func request(path: String, query: [URLQueryItem] = [],
                         credentials: MiniMaxCredentials) async throws -> HTTPResponse {
        var url = URLComponents()
        url.scheme = "https"
        url.host = credentials.host
        url.path = path
        if !query.isEmpty { url.queryItems = query }
        return try await http.send(HTTPRequest(
            method: .get, url: url.url!,
            headers: ["Authorization": "Bearer \(credentials.apiKey)",
                      "Accept": "application/json", "Content-Type": "application/json"]
        ))
    }
}
