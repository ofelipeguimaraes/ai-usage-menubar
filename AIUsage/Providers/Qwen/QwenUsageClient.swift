import Foundation

/// Talks to the QwenCloud console gateway that backs
/// home.qwencloud.com/analytics/token-plan/individual.
struct QwenUsageClient: Sendable {
    static let consoleHost = "home.qwencloud.com"
    static let gatewayHost = "cs-data.qwencloud.com"
    static let dashboardURL = URL(
        string: "https://home.qwencloud.com/analytics/token-plan/individual"
    )!
    static let userInfoURL = URL(
        string: "https://home.qwencloud.com/tool/user/info.json"
    )!
    static let usageAPI = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage"
    static let subscriptionAPI =
        "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/subscription"
    static let commodityCode = "sfm_tokenplansolo_public_intl"
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/140.0 Safari/537.36"

    let http: HTTPClient

    init(http: HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func fetchSecToken(session: BrowserCookieSession) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: .get,
            url: Self.userInfoURL,
            headers: [
                "Cookie": session.header(for: Self.consoleHost),
                "Accept": "application/json",
                "Referer": Self.dashboardURL.absoluteString,
                "User-Agent": Self.userAgent
            ]
        ))
    }

    func fetchUsage(
        session: BrowserCookieSession,
        secToken: String
    ) async throws -> HTTPResponse {
        try await call(api: Self.usageAPI, data: [:], session: session, secToken: secToken)
    }

    func fetchSubscription(
        session: BrowserCookieSession,
        secToken: String
    ) async throws -> HTTPResponse {
        try await call(
            api: Self.subscriptionAPI,
            data: ["commodityCode": Self.commodityCode],
            session: session,
            secToken: secToken
        )
    }

    private func call(
        api: String,
        data: [String: Any],
        session: BrowserCookieSession,
        secToken: String
    ) async throws -> HTTPResponse {
        var cornerstone: [String: Any] = [
            "feTraceId": UUID().uuidString.lowercased(),
            "feURL": Self.dashboardURL.absoluteString,
            "protocol": "V2",
            "console": "ONE_CONSOLE",
            "productCode": "p_efm",
            "domain": Self.consoleHost,
            "consoleSite": "QWENCLOUD",
            "userNickName": "",
            "userPrincipalName": "",
            "xsp_lang": "en-US"
        ]
        if let anonymousID = session.value(named: "cna") {
            cornerstone["X-Anonymous-Id"] = anonymousID
        }
        var payload = data
        payload["cornerstoneParam"] = cornerstone
        let params = try JSONSerialization.data(withJSONObject: [
            "Api": api,
            "V": "1.0",
            "Data": payload
        ])

        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.gatewayHost
        components.path = "/data/api.json"
        components.queryItems = [
            URLQueryItem(name: "action", value: "IntlBroadScopeAspnGateway"),
            URLQueryItem(name: "product", value: "sfm_bailian"),
            URLQueryItem(name: "api", value: api)
        ]

        var headers = [
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json, text/plain, */*",
            "Cookie": session.header(for: Self.gatewayHost),
            "Origin": "https://\(Self.consoleHost)",
            "Referer": Self.dashboardURL.absoluteString,
            "X-Requested-With": "XMLHttpRequest",
            "User-Agent": Self.userAgent
        ]
        if let csrf = session.value(named: "login_aliyunid_csrf") ??
            session.value(named: "csrf") {
            headers["x-xsrf-token"] = csrf
            headers["x-csrf-token"] = csrf
        }

        return try await http.send(HTTPRequest(
            method: .post,
            url: components.url!,
            headers: headers,
            body: ProviderParsing.formBody([
                ("product", "sfm_bailian"),
                ("action", "IntlBroadScopeAspnGateway"),
                ("sec_token", secToken),
                ("region", "ap-southeast-1"),
                ("language", "en-US"),
                ("params", String(decoding: params, as: UTF8.self))
            ])
        ))
    }
}
