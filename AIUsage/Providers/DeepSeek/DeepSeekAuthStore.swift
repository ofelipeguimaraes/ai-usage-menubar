import Foundation

struct DeepSeekAuthStore: Sendable {
    static let authPaths = [
        "~/.local/share/opencode/auth.json",
        "~/.config/opencode/auth.json"
    ]

    let files: TextFileAccessing
    let environment: EnvironmentReading

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader()
    ) {
        self.files = files
        self.environment = environment
    }

    func loadAPIKey() -> String? {
        if let key = trimmed(environment.value(for: "DEEPSEEK_API_KEY")) {
            return key
        }
        for path in Self.authPaths {
            guard files.exists(path),
                  let text = try? files.readText(path),
                  let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(
                    with: data
                  ) as? [String: Any],
                  let provider = object["deepseek"] as? [String: Any],
                  let key = trimmed(provider["key"] as? String) else {
                continue
            }
            return key
        }
        return nil
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !value.isEmpty else {
            return nil
        }
        return value
    }
}
