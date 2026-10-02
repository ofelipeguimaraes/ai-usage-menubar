import Foundation

struct ZaiAuthStore: Sendable {
    let environment: any EnvironmentReading
    let openCode: OpenCodeCredentialReader

    init(files: any TextFileAccessing = LocalTextFileAccessor(),
         environment: any EnvironmentReading = ProcessEnvironmentReader(),
         sqlite: any SQLiteValueReading = SQLiteCLIValueReader()) {
        self.environment = environment
        self.openCode = OpenCodeCredentialReader(files: files, environment: environment, sqlite: sqlite)
    }

    func load() -> String? {
        if let key = environment.value(for: "ZAI_API_KEY")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty { return key }
        return openCode.apiKey(for: "zai-coding-plan")
    }
}
