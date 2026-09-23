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

    let cookies: BrowserCookieReading

    init(cookies: BrowserCookieReading = ChromiumCookieReader()) {
        self.cookies = cookies
    }

    func loadSession() throws -> BrowserCookieSession? {
        try cookies.session(
            domainSuffixes: Self.domainSuffixes,
            requiredNames: Self.ticketCookies
        )
    }
}
