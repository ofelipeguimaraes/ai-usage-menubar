import Foundation

/// Reads API keys that OpenCode stores for its provider integrations.
///
/// OpenCode 2.x keeps credentials in the `credential` table of `opencode.db`
/// (`{"type":"key","key":"..."}`); older releases used `auth.json`
/// (`{"<id>":{"type":"api","key":"..."}}`). The database wins because it is
/// the source the current OpenCode release reads and writes.
struct OpenCodeCredentialReader: Sendable {
    let files: any TextFileAccessing
    let environment: any EnvironmentReading
    let sqlite: any SQLiteValueReading

    init(files: any TextFileAccessing = LocalTextFileAccessor(),
         environment: any EnvironmentReading = ProcessEnvironmentReader(),
         sqlite: any SQLiteValueReading = SQLiteCLIValueReader()) {
        self.files = files
        self.environment = environment
        self.sqlite = sqlite
    }

    func apiKey(for integrationID: String) -> String? {
        databaseKey(for: integrationID) ?? legacyKey(for: integrationID)
    }

    private var dataHome: String {
        nonempty(environment.value(for: "XDG_DATA_HOME")) ?? "~/.local/share"
    }

    private func databaseKey(for integrationID: String) -> String? {
        let id = integrationID.replacingOccurrences(of: "'", with: "''")
        let sql = "SELECT value FROM credential WHERE integration_id = '\(id)' " +
            "AND (active IS NULL OR active = 1) ORDER BY time_updated DESC LIMIT 1"
        guard let text = try? sqlite.queryValue(path: dataHome + "/opencode/opencode.db", sql: sql),
              let entry = try? ProviderParsing.object(from: Data(text.utf8)),
              ProviderParsing.string(entry["type"]) == "key" else { return nil }
        return nonempty(ProviderParsing.string(entry["key"]))
    }

    private func legacyKey(for integrationID: String) -> String? {
        for path in [dataHome + "/opencode/auth.json", "~/.config/opencode/auth.json"] {
            guard files.exists(path), let text = try? files.readText(path),
                  let root = try? ProviderParsing.object(from: Data(text.utf8)),
                  let entry = ProviderParsing.object(root[integrationID]),
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
