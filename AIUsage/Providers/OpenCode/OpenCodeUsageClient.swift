import Foundation

struct OpenCodeUsageClient: Sendable {
    func fetchUsage(token: String) async throws -> Data {
        // TODO: Hit the Zen API
        throw URLError(.badURL)
    }
}
