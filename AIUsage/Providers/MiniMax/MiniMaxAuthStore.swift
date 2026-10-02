import Foundation

struct MiniMaxCredentials: Sendable {
    let apiKey: String
    let isChina: Bool

    var host: String { isChina ? "www.minimax.cn" : "www.minimax.io" }
}

struct MiniMaxAuthStore: Sendable {
    let environment: any EnvironmentReading
    let openCode: OpenCodeCredentialReader

    init(files: any TextFileAccessing = LocalTextFileAccessor(),
         environment: any EnvironmentReading = ProcessEnvironmentReader(),
         sqlite: any SQLiteValueReading = SQLiteCLIValueReader()) {
        self.environment = environment
        self.openCode = OpenCodeCredentialReader(files: files, environment: environment, sqlite: sqlite)
    }

    func load() -> MiniMaxCredentials? {
        for (name, isChina) in [("MINIMAX_API_KEY", false), ("MINIMAX_CN_API_KEY", true)] {
            if let key = nonempty(environment.value(for: name)) {
                return MiniMaxCredentials(apiKey: key, isChina: isChina)
            }
        }
        for (id, isChina) in [("minimax-coding-plan", false), ("minimax-cn-coding-plan", true),
                              ("minimax", false), ("minimax-cn", true)] {
            guard let key = openCode.apiKey(for: id) else { continue }
            // Generic MiniMax providers can also contain pay-as-you-go keys.
            if !id.contains("coding-plan"), !key.hasPrefix("sk-cp") { continue }
            return MiniMaxCredentials(apiKey: key, isChina: isChina)
        }
        return nil
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
