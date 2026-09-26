import Foundation

actor KimiProvider: UsageProvider {
    nonisolated let id = ProviderID.kimi
    private let authStore: KimiAuthStore
    private let client: KimiUsageClient
    private let dateProvider: any DateProviding

    init(authStore: KimiAuthStore = KimiAuthStore(),
         client: KimiUsageClient = KimiUsageClient(),
         dateProvider: any DateProviding = SystemDateProvider()) {
        self.authStore = authStore
        self.client = client
        self.dateProvider = dateProvider
    }

    func fetch() async throws -> ProviderSnapshot {
        guard var state = try authStore.load() else { throw KimiUsageMapper.sessionExpired }
        let now = dateProvider.now()
        if let expiresAt = state.credentials.expiresAt,
           expiresAt <= now.timeIntervalSince1970 + 60 {
            try await refresh(&state, now: now)
        }
        var usage = try await client.fetch("usages", state: state)
        if usage.statusCode == 401 {
            try await refresh(&state, now: now)
            usage = try await client.fetch("usages", state: state)
        }
        try KimiUsageMapper.requireSuccess(usage)
        let profile = try? await client.fetch("me", state: state)
        return try KimiUsageMapper.map(usage: usage, profile: profile, now: now)
    }

    private func refresh(_ state: inout KimiAuthState, now: Date) async throws {
        let original = state.credentials
        var token = try await client.refresh(state)
        token.expiresAt = now.timeIntervalSince1970 + (token.expiresIn ?? 0)
        state.credentials = token
        try authStore.save(state, replacing: original)
    }
}
