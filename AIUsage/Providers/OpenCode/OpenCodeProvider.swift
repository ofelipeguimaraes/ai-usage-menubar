import Foundation

actor OpenCodeProvider: UsageProvider {
    nonisolated let id = ProviderID.opencode
    private let authStore: OpenCodeAuthStore
    private let client: OpenCodeUsageClient

    init(
        authStore: OpenCodeAuthStore = OpenCodeAuthStore(),
        client: OpenCodeUsageClient = OpenCodeUsageClient()
    ) {
        self.authStore = authStore
        self.client = client
    }

    func fetch() async throws -> ProviderSnapshot {
        let token = authStore.loadToken()
        guard token != nil else {
            throw ProviderFailure(.authentication, "Not logged in to OpenCode Zen.")
        }
        
        let dbPath = NSString(string: "~/.local/share/opencode/opencode.db").expandingTildeInPath
        var usedTokens = 0
        
        // Use SystemProcessRunner to query the SQLite DB
        do {
            let runner = SystemProcessRunner()
            let query = "SELECT COALESCE(SUM(tokens_input) + SUM(tokens_output), 0) FROM session;"
            let result = try runner.run(
                executable: "/usr/bin/sqlite3",
                arguments: [dbPath, query]
            )
            if result.succeeded, let tokens = Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) {
                usedTokens = tokens
            }
        } catch {
            // Ignore error and use 0 if DB is not found or locked
        }

        return ProviderSnapshot(
            provider: .opencode,
            planName: "Zen",
            windows: [
                QuotaWindow(
                    kind: .totalUsage,
                    usedPercent: min((Double(usedTokens) / 2_000_000.0) * 100.0, 100.0),
                    resetsAt: nil
                )
            ], 
            fetchedAt: Date()
        )
    }
}
