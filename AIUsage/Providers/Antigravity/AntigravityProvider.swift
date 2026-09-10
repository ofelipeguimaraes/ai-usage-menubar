import Foundation

actor AntigravityProvider: UsageProvider {
    nonisolated let id = ProviderID.antigravity

    private let authStore: AntigravityAuthStore
    private let client: AntigravityUsageClient
    private let localClient: AntigravityLocalClient
    private let cache: AntigravitySnapshotCache
    private let dateProvider: DateProviding

    init(
        authStore: AntigravityAuthStore = AntigravityAuthStore(),
        client: AntigravityUsageClient = AntigravityUsageClient(),
        localClient: AntigravityLocalClient = AntigravityLocalClient(),
        cache: AntigravitySnapshotCache = AntigravitySnapshotCache(),
        dateProvider: DateProviding = SystemDateProvider()
    ) {
        self.authStore = authStore
        self.client = client
        self.localClient = localClient
        self.cache = cache
        self.dateProvider = dateProvider
    }

    /// Sources, in order of trust:
    ///
    /// 1. A running `agy`, which reports the same buckets as its own
    ///    Models & Quota screen.
    /// 2. The Cloud Code summary endpoint, authoritative only for the
    ///    accounts it does not deny.
    /// 3. The last authoritative reading, so closing `agy` does not blank the
    ///    card. Weekly windows stay valid for days.
    ///
    /// `fetchAvailableModels` is deliberately not a source. It answers with
    /// `remainingFraction: 1` for every model even when the account has
    /// consumed most of its weekly quota, so it renders a confident 100%.
    /// Reporting nothing is better than reporting a wrong number.
    func fetch() async throws -> ProviderSnapshot {
        let now = dateProvider.now()
        let auth = try? authStore.load()
        var token = auth.flatMap { authStore.usableAccessToken(from: $0) }
        if token == nil, let refresh = auth?.refreshToken {
            token = await refreshedToken(refresh)
        }

        if let snapshot = await localSnapshot(token: token, now: now) {
            cache.save(snapshot)
            return snapshot
        }

        guard auth != nil else {
            if let cached = cache.load(now: now) { return cached }
            throw ProviderFailure(
                .authentication,
                "Not logged in. Sign in through Antigravity."
            )
        }
        guard let token else {
            if let cached = cache.load(now: now) { return cached }
            throw ProviderFailure(
                .authentication,
                "Antigravity session expired. Sign in again."
            )
        }

        var summary = await client.cloudCode(
            path: AntigravityUsageClient.summaryPath,
            accessToken: token,
            userAgent: "antigravity"
        )
        if case .authentication = summary,
           let refresh = auth?.refreshToken,
           let refreshed = await refreshedToken(refresh) {
            summary = await client.cloudCode(
                path: AntigravityUsageClient.summaryPath,
                accessToken: refreshed,
                userAgent: "antigravity"
            )
        }

        if case let .success(data) = summary,
           let snapshot = AntigravityUsageMapper.summary(
               data,
               planName: await planName(token: token),
               now: now
           ),
           !snapshot.windows.isEmpty {
            cache.save(snapshot)
            return snapshot
        }

        if let cached = cache.load(now: now) {
            return cached
        }

        switch summary {
        case .authentication:
            throw ProviderFailure(
                .authentication,
                "Antigravity session expired. Sign in again."
            )
        case .denied:
            throw ProviderFailure(
                .transient,
                "Antigravity quota is only readable while the CLI runs. "
                    + "Start `agy` once to read it."
            )
        default:
            throw ProviderFailure(
                .transient,
                "Antigravity could not be reached."
            )
        }
    }

    private func localSnapshot(
        token: String?,
        now: Date
    ) async -> ProviderSnapshot? {
        guard let data = await localClient.summary() else { return nil }
        guard let snapshot = AntigravityUsageMapper.summary(
            data,
            planName: await planName(token: token),
            now: now
        ), !snapshot.windows.isEmpty else {
            return nil
        }
        return snapshot
    }

    /// The plan label is cosmetic, so a failure here never fails the fetch.
    private func planName(token: String?) async -> String? {
        guard let token else { return nil }
        guard case let .success(data) = await client.cloudCode(
            path: AntigravityUsageClient.planPath,
            accessToken: token,
            userAgent: "agy"
        ) else {
            return nil
        }
        return AntigravityUsageMapper.plan(data)
    }

    private func refreshedToken(_ refresh: String) async -> String? {
        guard let result = await client.refresh(refresh) else {
            return nil
        }
        authStore.cache(
            accessToken: result.token,
            expiresIn: result.expiresIn,
            refreshToken: refresh
        )
        return result.token
    }
}
