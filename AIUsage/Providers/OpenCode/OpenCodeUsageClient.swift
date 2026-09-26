import Foundation

struct OpenCodeUsageClient: Sendable {
    let http: any HTTPClient
    init(http: any HTTPClient = URLSessionHTTPClient()) { self.http = http }

    func fetchUsage(token: String) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(method: .get,
            url: URL(string: "https://opencode.ai/zen/go/v1/usage")!,
            headers: ["Authorization": "Bearer \(token)", "Accept": "application/json"]))
    }
}
