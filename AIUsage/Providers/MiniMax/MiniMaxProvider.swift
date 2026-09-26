import Foundation

actor MiniMaxProvider: UsageProvider {
    nonisolated let id = ProviderID.minimax
    private let authStore: MiniMaxAuthStore
    private let client: MiniMaxUsageClient
    private let dateProvider: any DateProviding

    init(authStore: MiniMaxAuthStore = MiniMaxAuthStore(),
         client: MiniMaxUsageClient = MiniMaxUsageClient(),
         dateProvider: any DateProviding = SystemDateProvider()) {
        self.authStore = authStore
        self.client = client
        self.dateProvider = dateProvider
    }

    func fetch() async throws -> ProviderSnapshot {
        guard let credentials = authStore.load() else {
            throw ProviderFailure(.authentication,
                "MiniMax Subscription Key not found. Connect MiniMax Coding Plan in OpenCode.")
        }
        let usage = try await client.fetchUsage(credentials: credentials)
        _ = try MiniMaxUsageMapper.payload(usage)
        // A cosmetic subscription lookup must never hide valid usage data.
        let plan = try? await client.fetchPlan(credentials: credentials)
        return try MiniMaxUsageMapper.map(usage: usage, plan: plan, now: dateProvider.now())
    }
}
