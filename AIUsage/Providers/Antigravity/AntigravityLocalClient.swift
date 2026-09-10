import Foundation

/// Reads the quota summary from a running Antigravity CLI (`agy`).
///
/// The Cloud Code endpoint is not authoritative for every account: Starter
/// tiers answer `retrieveUserQuotaSummary` with `PERMISSION_DENIED` (#3501)
/// while the CLI itself still reports accurate weekly buckets. The CLI serves
/// them from a loopback HTTPS listener, which is the same payload its
/// Models & Quota screen renders.
struct AntigravityLocalClient: Sendable {
    static let summaryPath =
        "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"

    private let runner: ProcessRunning
    private let probe: @Sendable (Int) async -> Data?

    init(
        runner: ProcessRunning = SystemProcessRunner(),
        probe: @escaping @Sendable (Int) async -> Data? =
            AntigravityLocalClient.probe
    ) {
        self.runner = runner
        self.probe = probe
    }

    /// Returns the first loopback listener that answers with a quota summary,
    /// or `nil` when no CLI is running or none of them answers.
    func summary() async -> Data? {
        for port in listeningPorts() {
            if let data = await probe(port), Self.containsGroups(data) {
                return data
            }
        }
        return nil
    }

    /// A CSRF-protected listener answers, but not with usage data. Only accept
    /// a payload that actually carries quota groups.
    static func containsGroups(_ data: Data) -> Bool {
        guard let root = try? ProviderParsing.object(from: data) else {
            return false
        }
        let container = ProviderParsing.object(root["response"]) ?? root
        return container["groups"] is [[String: Any]]
    }

    // MARK: - Port discovery

    /// Loopback ports the running `agy` processes listen on. A single `lsof`
    /// call keeps this cheap enough for the app's scheduled refreshes.
    func listeningPorts() -> [Int] {
        guard let result = try? runner.run(
            executable: "/usr/sbin/lsof",
            // `-a` matters: without it lsof ORs the selectors and answers
            // with every listening socket on the machine.
            arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-c", "agy"],
            environment: [:],
            timeout: 5
        ), result.succeeded else {
            return []
        }
        return Self.parsePorts(from: result.stdout)
    }

    static func parsePorts(from output: String) -> [Int] {
        var ports: [Int] = []
        for line in output.split(separator: "\n") {
            // Only the CLI itself, never another command whose name contains
            // "agy" as a substring.
            guard line.split(separator: " ").first == "agy" else { continue }
            for field in line.split(separator: " ")
            where field.hasPrefix("127.0.0.1:") {
                let raw = field.dropFirst("127.0.0.1:".count)
                if let port = Int(raw), !ports.contains(port) {
                    ports.append(port)
                }
            }
        }
        return ports
    }

    // MARK: - Loopback request

    private static func probe(port: Int) async -> Data? {
        guard let url = URL(
            string: "https://127.0.0.1:\(port)" + summaryPath
        ) else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.timeoutInterval = 5

        let delegate = AntigravityLoopbackTrust()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else {
            return nil
        }
        return data
    }
}

/// Accepts the CLI's self-signed certificate, and only ever for `127.0.0.1`.
/// Every other host keeps the system's default evaluation.
private final class AntigravityLoopbackTrust: NSObject, URLSessionDelegate,
    @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (
            URLSession.AuthChallengeDisposition, URLCredential?
        ) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod
            == NSURLAuthenticationMethodServerTrust,
            challenge.protectionSpace.host == "127.0.0.1",
            let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
