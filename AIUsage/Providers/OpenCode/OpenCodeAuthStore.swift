import Foundation

struct OpenCodeAuthStore: Sendable {
    let files: any TextFileAccessing
    let environment: any EnvironmentReading
    let keychain: any KeychainAccessing

    init(files: any TextFileAccessing = LocalTextFileAccessor(),
         environment: any EnvironmentReading = ProcessEnvironmentReader(),
         keychain: any KeychainAccessing = SecurityKeychainAccessor()) {
        self.files = files
        self.environment = environment
        self.keychain = keychain
    }

    func loadToken() -> String? {
        if let key = nonempty(environment.value(for: "OPENCODE_API_KEY")) { return key }
        let dataHome = nonempty(environment.value(for: "XDG_DATA_HOME")) ?? "~/.local/share"
        for path in [dataHome + "/opencode/auth.json", "~/.config/opencode/auth.json"] {
            guard let text = try? files.readText(path),
                  let root = try? ProviderParsing.object(from: Data(text.utf8)) else { continue }
            for id in ["opencode-go", "opencode"] {
                guard let entry = ProviderParsing.object(root[id]),
                      ProviderParsing.string(entry["type"]) == "api",
                      let key = nonempty(ProviderParsing.string(entry["key"])) else { continue }
                return key
            }
        }
        return nonempty(try? keychain.readGenericPasswordForCurrentUser(service: "opencode-api-key"))
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
