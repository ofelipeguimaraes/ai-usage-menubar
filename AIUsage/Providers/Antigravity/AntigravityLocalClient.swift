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
    private let probe: @Sendable (Int, String?) async -> Data?

    init(
        runner: ProcessRunning = SystemProcessRunner(),
        probe: @escaping @Sendable (Int, String?) async -> Data? =
            AntigravityLocalClient.probe
    ) {
        self.runner = runner
        self.probe = probe
    }

    /// Convenience init that accepts the old `(Int) async -> Data?` signature
    /// so existing tests keep compiling without changes.
    init(
        runner: ProcessRunning,
        probe: @escaping @Sendable (Int) async -> Data?
    ) {
        self.runner = runner
        self.probe = { port, _ in await probe(port) }
    }

    /// Returns the first loopback listener that answers with a quota summary,
    /// or `nil` when no CLI is running or none of them answers.
    func summary() async -> Data? {
        let discovered = discoverListeners()
        for listener in discovered {
            if let data = await probe(listener.port, listener.csrfToken),
               Self.containsGroups(data) {
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
        discoverListeners().map(\.port)
    }

    struct Listener: Equatable {
        let port: Int
        let pid: Int
        let csrfToken: String?
    }

    /// Discovers loopback listeners and their CSRF tokens.
    func discoverListeners() -> [Listener] {
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
        let parsed = Self.parsePortsAndPIDs(from: result.stdout)
        guard !parsed.isEmpty else { return [] }

        // Collect unique PIDs so we look up each token only once.
        let uniquePIDs = Array(Set(parsed.map(\.pid)))
        var tokensByPID: [Int: String] = [:]
        for pid in uniquePIDs {
            if let token = csrfToken(forPID: pid) {
                tokensByPID[pid] = token
            }
        }
        return parsed.map { entry in
            Listener(
                port: entry.port,
                pid: entry.pid,
                csrfToken: tokensByPID[entry.pid]
            )
        }
    }

    struct PortAndPID: Equatable {
        let port: Int
        let pid: Int
    }

    static func parsePortsAndPIDs(from output: String) -> [PortAndPID] {
        var entries: [PortAndPID] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ")
            // Only the CLI itself, never another command whose name contains
            // "agy" as a substring.
            guard fields.first == "agy" else { continue }
            guard let pid = fields.dropFirst().first.flatMap({ Int($0) })
            else { continue }
            for field in fields where field.hasPrefix("127.0.0.1:") {
                let raw = field.dropFirst("127.0.0.1:".count)
                if let port = Int(raw),
                   !entries.contains(where: { $0.port == port }) {
                    entries.append(PortAndPID(port: port, pid: pid))
                }
            }
        }
        return entries
    }

    /// Back-compat: the existing `parsePorts` used by tests.
    static func parsePorts(from output: String) -> [Int] {
        parsePortsAndPIDs(from: output).map(\.port)
    }

    // MARK: - CSRF token discovery

    /// Reads the CSRF token that `agy` injects into its child processes.
    ///
    /// The token lives only in the environment of child processes; it is not
    /// stored on disk and not part of the `agy` process's own environment
    /// block. We find a child via `pgrep -P`, then read its environment
    /// using `sysctl(KERN_PROCARGS2)` which is allowed for same-user
    /// processes on macOS.
    private func csrfToken(forPID pid: Int) -> String? {
        // First, try to read the token from the environment of child processes.
        guard let pgrepResult = try? runner.run(
            executable: "/usr/bin/pgrep",
            arguments: ["-P", "\(pid)"],
            environment: [:],
            timeout: 3
        ), pgrepResult.succeeded else {
            return nil
        }

        let childPIDs = pgrepResult.stdout
            .split(separator: "\n")
            .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }

        for childPID in childPIDs {
            if let token = Self.readCSRFFromProcessEnvironment(childPID) {
                return token
            }
        }
        return nil
    }

    /// Uses the macOS `sysctl(KERN_PROCARGS2)` API to read the environment
    /// variables of a process owned by the current user. Returns the value
    /// of `ANTIGRAVITY_CSRF_TOKEN` if found.
    private static func readCSRFFromProcessEnvironment(
        _ pid: Int32
    ) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else {
            return nil
        }

        // The layout of KERN_PROCARGS2 is:
        // 1. First 4 bytes: argc (Int32, number of command-line arguments)
        // 2. Executable path (null-terminated)
        // 3. Padding with null bytes
        // 4. argc argument strings (each null-terminated)
        // 5. Environment strings (each null-terminated, "KEY=VALUE")
        guard size >= 4 else { return nil }
        let argc = buffer.withUnsafeBytes {
            $0.load(fromByteOffset: 0, as: Int32.self)
        }

        // Skip past argc (4 bytes), then skip the executable path.
        var offset = 4
        // Skip executable path.
        while offset < size, buffer[offset] != 0 { offset += 1 }
        // Skip null padding after executable path.
        while offset < size, buffer[offset] == 0 { offset += 1 }

        // Skip `argc` argument strings.
        var argsSkipped = 0
        while argsSkipped < argc, offset < size {
            while offset < size, buffer[offset] != 0 { offset += 1 }
            offset += 1 // skip the null terminator
            argsSkipped += 1
        }

        // Now we are at the environment strings.
        let prefix = "ANTIGRAVITY_CSRF_TOKEN="
        let prefixBytes = [UInt8](prefix.utf8)
        while offset < size {
            // Find end of this env string.
            let start = offset
            while offset < size, buffer[offset] != 0 { offset += 1 }
            let length = offset - start
            offset += 1 // skip null terminator

            guard length > prefixBytes.count else { continue }
            if buffer[start..<(start + prefixBytes.count)]
                .elementsEqual(prefixBytes) {
                let valueStart = start + prefixBytes.count
                let valueEnd = start + length
                return String(
                    bytes: buffer[valueStart..<valueEnd],
                    encoding: .utf8
                )
            }
        }
        return nil
    }

    // MARK: - Loopback request

    private static func probe(port: Int, csrfToken: String?) async -> Data? {
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
        if let csrfToken {
            request.setValue(
                csrfToken,
                forHTTPHeaderField: "X-Codeium-Csrf-Token"
            )
        }
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
