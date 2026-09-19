import Foundation

struct OpenCodeAuthStore: Sendable {
    func loadToken() -> String? {
        let keychain = SecurityKeychainAccessor()
        return try? keychain.readGenericPasswordForCurrentUser(service: "opencode-api-key")
    }
}
