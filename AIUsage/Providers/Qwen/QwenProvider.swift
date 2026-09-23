import Foundation

actor QwenProvider: UsageProvider {
    nonisolated let id = ProviderID.qwen

    private let authStore: QwenAuthStore
    private let client: QwenUsageClient
    private let dateProvider: any DateProviding

    init(
        authStore: QwenAuthStore = QwenAuthStore(),
        client: QwenUsageClient = QwenUsageClient(),
        dateProvider: any DateProviding = SystemDateProvider()
    ) {
        self.authStore = authStore
        self.client = client
        self.dateProvider = dateProvider
    }

    func fetch() async throws -> ProviderSnapshot {
        guard let session = try authStore.loadSession() else {
            throw ProviderFailure(
                .authentication,
                "Sign in at home.qwencloud.com in Brave, Chrome, Arc or Edge."
            )
        }
        let secToken = try QwenUsageMapper.secToken(
            from: await client.fetchSecToken(session: session)
        )
        let usage = try QwenUsageMapper.payload(
            from: await client.fetchUsage(session: session, secToken: secToken)
        )
        // The plan name is cosmetic; never fail the refresh because of it.
        let subscription = try? QwenUsageMapper.payload(
            from: await client.fetchSubscription(session: session, secToken: secToken)
        )
        return try QwenUsageMapper.map(
            usage: usage,
            subscription: subscription,
            now: dateProvider.now()
        )
    }
}
