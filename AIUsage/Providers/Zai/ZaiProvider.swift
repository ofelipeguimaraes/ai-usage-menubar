import Foundation

actor ZaiProvider: UsageProvider {
    nonisolated let id = ProviderID.zai
    private let authStore: ZaiAuthStore
    private let http: any HTTPClient
    private let dateProvider: any DateProviding

    init(authStore: ZaiAuthStore = ZaiAuthStore(),
         http: any HTTPClient = URLSessionHTTPClient(),
         dateProvider: any DateProviding = SystemDateProvider()) {
        self.authStore = authStore
        self.http = http
        self.dateProvider = dateProvider
    }

    func fetch() async throws -> ProviderSnapshot {
        guard let key = authStore.load() else {
            throw ProviderFailure(.authentication, "GLM Coding Plan key not found. Connect Z.ai Coding Plan in OpenCode.")
        }
        // The official usage plugin sends the API key directly, without a Bearer prefix.
        let response = try await http.send(HTTPRequest(
            method: .get,
            url: URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!,
            headers: ["Authorization": key, "Accept": "application/json", "Accept-Language": "en-US,en"]
        ))
        return try ZaiUsageMapper.map(response, now: dateProvider.now())
    }
}
