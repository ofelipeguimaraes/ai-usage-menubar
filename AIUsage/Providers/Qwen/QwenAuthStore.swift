import Foundation

/// Finds the QwenCloud console session in a Chromium-based browser.
/// Token Plan inference keys cannot read their own quota, so the console
/// session cookie is the only way to reach the usage numbers.
struct QwenAuthStore: Sendable {
    static let domainSuffixes = ["qwencloud.com"]
    static let ticketCookies: Set<String> = [
        "login_qwencloud_ticket",
        "login_aliyunid_ticket"
    ]

    /// OpenCode integration that holds a QwenCloud Token Plan key. The key
    /// cannot read usage, but it proves the plan is in use without Qwen Code.
    static let openCodeIntegrationIDs = ["alibaba-token-plan"]

    let cookies: BrowserCookieReading
    let openCode: OpenCodeCredentialReader

    init(cookies: BrowserCookieReading = ChromiumCookieReader(),
         openCode: OpenCodeCredentialReader = OpenCodeCredentialReader()) {
        self.cookies = cookies
        self.openCode = openCode
    }

    func hasOpenCodeTokenPlan() -> Bool {
        Self.openCodeIntegrationIDs.contains { openCode.apiKey(for: $0) != nil }
    }

    func loadSession() throws -> BrowserCookieSession? {
        try cookies.session(
            domainSuffixes: Self.domainSuffixes,
            requiredNames: Self.ticketCookies
        )
    }
}
