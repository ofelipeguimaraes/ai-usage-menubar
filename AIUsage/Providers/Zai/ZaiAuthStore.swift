import Foundation

struct ZaiAuthStore: Sendable {
    let files: any TextFileAccessing
    let environment: any EnvironmentReading

    init(files: any TextFileAccessing = LocalTextFileAccessor(),
         environment: any EnvironmentReading = ProcessEnvironmentReader()) {
        self.files = files
        self.environment = environment
    }

    func load() -> String? {
        if let key = nonempty(environment.value(for: "ZAI_API_KEY")) { return key }
        let dataHome = nonempty(environment.value(for: "XDG_DATA_HOME")) ?? "~/.local/share"
        for path in [dataHome + "/opencode/auth.json", "~/.config/opencode/auth.json"] {
            guard files.exists(path), let text = try? files.readText(path),
                  let root = try? ProviderParsing.object(from: Data(text.utf8)),
                  let entry = ProviderParsing.object(root["zai-coding-plan"]),
                  ProviderParsing.string(entry["type"]) == "api",
                  let key = nonempty(ProviderParsing.string(entry["key"])) else { continue }
            return key
        }
        return nil
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
