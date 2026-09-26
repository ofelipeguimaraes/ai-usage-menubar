import Foundation

struct MiniMaxCredentials: Sendable {
    let apiKey: String
    let isChina: Bool

    var host: String { isChina ? "www.minimax.cn" : "www.minimax.io" }
}

struct MiniMaxAuthStore: Sendable {
    let files: any TextFileAccessing
    let environment: any EnvironmentReading

    init(files: any TextFileAccessing = LocalTextFileAccessor(),
         environment: any EnvironmentReading = ProcessEnvironmentReader()) {
        self.files = files
        self.environment = environment
    }

    func load() -> MiniMaxCredentials? {
        for (name, isChina) in [("MINIMAX_API_KEY", false), ("MINIMAX_CN_API_KEY", true)] {
            if let key = nonempty(environment.value(for: name)) {
                return MiniMaxCredentials(apiKey: key, isChina: isChina)
            }
        }
        let dataHome = environment.value(for: "XDG_DATA_HOME") ?? "~/.local/share"
        for path in [dataHome + "/opencode/auth.json", "~/.config/opencode/auth.json"] {
            guard files.exists(path), let text = try? files.readText(path),
                  let root = try? ProviderParsing.object(from: Data(text.utf8)) else { continue }
            for (id, isChina) in [("minimax-coding-plan", false), ("minimax-cn-coding-plan", true),
                                  ("minimax", false), ("minimax-cn", true)] {
                guard let entry = ProviderParsing.object(root[id]),
                      ProviderParsing.string(entry["type"]) == "api",
                      let key = nonempty(ProviderParsing.string(entry["key"])) else { continue }
                // Generic MiniMax providers can also contain pay-as-you-go keys.
                if !id.contains("coding-plan"), !key.hasPrefix("sk-cp") { continue }
                return MiniMaxCredentials(apiKey: key, isChina: isChina)
            }
        }
        return nil
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
