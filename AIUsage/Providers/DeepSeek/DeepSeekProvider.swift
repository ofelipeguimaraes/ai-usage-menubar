import Foundation

actor DeepSeekProvider: UsageProvider {
    nonisolated let id = ProviderID.deepseek

    private let authStore: DeepSeekAuthStore
    private let client: DeepSeekUsageClient
    private let dateProvider: DateProviding

    init(
        authStore: DeepSeekAuthStore = DeepSeekAuthStore(),
        client: DeepSeekUsageClient = DeepSeekUsageClient(),
        dateProvider: DateProviding = SystemDateProvider()
    ) {
        self.authStore = authStore
        self.client = client
        self.dateProvider = dateProvider
    }

    func fetch() async throws -> ProviderSnapshot {
        guard let apiKey = authStore.loadAPIKey() else {
            throw ProviderFailure(
                .authentication,
                "DeepSeek API key not found. Add it to the OpenCode auth file."
            )
        }
        let response = try await client.fetchBalance(apiKey: apiKey)
        return try DeepSeekUsageMapper.map(
            response: response,
            now: dateProvider.now()
        )
    }
}
