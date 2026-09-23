import CommonCrypto
import CryptoKit
import Foundation
import SQLite3

struct BrowserCookie: Equatable, Sendable {
    let hostKey: String
    let name: String
    let value: String

    func matches(host: String) -> Bool {
        let domain = hostKey.hasPrefix(".") ? String(hostKey.dropFirst()) : hostKey
        return host == domain || host.hasSuffix("." + domain)
    }
}

/// A logged-in browser profile: every cookie it holds for the requested
/// domains, already decrypted.
struct BrowserCookieSession: Equatable, Sendable {
    let browser: String
    let cookies: [BrowserCookie]

    func header(for host: String) -> String {
        cookies
            .filter { $0.matches(host: host) }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    func value(named name: String) -> String? {
        cookies.first { $0.name == name }?.value
    }
}

protocol BrowserCookieReading: Sendable {
    /// Returns the most recently used profile that holds at least one of
    /// `requiredNames` for a domain ending in one of `domainSuffixes`.
    func session(
        domainSuffixes: [String],
        requiredNames: Set<String>
    ) throws -> BrowserCookieSession?
}

/// Reads cookies straight from the on-disk stores of Chromium-based browsers
/// on macOS. The browser's "Safe Storage" Keychain secret is only requested
/// for a profile that actually holds a session, so browsers the user never
/// signed in with never trigger a Keychain prompt.
final class ChromiumCookieReader: BrowserCookieReading, @unchecked Sendable {
    struct Browser: Sendable {
        let name: String
        let supportPath: String
        let keychainService: String
    }

    static let browsers: [Browser] = [
        Browser(
            name: "Brave",
            supportPath: "~/Library/Application Support/BraveSoftware/Brave-Browser",
            keychainService: "Brave Safe Storage"
        ),
        Browser(
            name: "Chrome",
            supportPath: "~/Library/Application Support/Google/Chrome",
            keychainService: "Chrome Safe Storage"
        ),
        Browser(
            name: "Arc",
            supportPath: "~/Library/Application Support/Arc/User Data",
            keychainService: "Arc Safe Storage"
        ),
        Browser(
            name: "Edge",
            supportPath: "~/Library/Application Support/Microsoft Edge",
            keychainService: "Microsoft Edge Safe Storage"
        ),
        Browser(
            name: "Vivaldi",
            supportPath: "~/Library/Application Support/Vivaldi",
            keychainService: "Vivaldi Safe Storage"
        ),
        Browser(
            name: "Chromium",
            supportPath: "~/Library/Application Support/Chromium",
            keychainService: "Chromium Safe Storage"
        )
    ]

    struct RawCookie {
        let hostKey: String
        let name: String
        let value: String
        let encryptedValue: Data
        let lastAccess: Int64
    }

    private let browsers: [Browser]
    private let processRunner: ProcessRunning
    private let lock = NSLock()
    private var keys: [String: Data] = [:]

    init(
        browsers: [Browser] = ChromiumCookieReader.browsers,
        processRunner: ProcessRunning = SystemProcessRunner()
    ) {
        self.browsers = browsers
        self.processRunner = processRunner
    }

    func session(
        domainSuffixes: [String],
        requiredNames: Set<String>
    ) throws -> BrowserCookieSession? {
        var best: (browser: Browser, rows: [RawCookie], lastAccess: Int64)?
        for browser in browsers {
            for database in cookieDatabases(for: browser) {
                guard let rows = try? readRows(
                    database: database,
                    domainSuffixes: domainSuffixes
                ) else { continue }
                guard let lastAccess = rows
                    .filter({ requiredNames.contains($0.name) })
                    .map(\.lastAccess)
                    .max() else { continue }
                if lastAccess > best?.lastAccess ?? .min {
                    best = (browser, rows, lastAccess)
                }
            }
        }

        guard let best else { return nil }
        let key = try encryptionKey(for: best.browser)
        let cookies = best.rows.compactMap { row -> BrowserCookie? in
            guard let value = Self.decrypt(row, key: key), !value.isEmpty else {
                return nil
            }
            return BrowserCookie(hostKey: row.hostKey, name: row.name, value: value)
        }
        return BrowserCookieSession(browser: best.browser.name, cookies: cookies)
    }

    // MARK: - Profiles

    private func cookieDatabases(for browser: Browser) -> [URL] {
        let root = URL(fileURLWithPath: expandHome(browser.supportPath))
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(atPath: root.path) else {
            return []
        }
        return entries
            .filter { $0 == "Default" || $0.hasPrefix("Profile ") }
            .flatMap { profile -> [URL] in
                let directory = root.appendingPathComponent(profile)
                return [
                    directory.appendingPathComponent("Network/Cookies"),
                    directory.appendingPathComponent("Cookies")
                ].filter { fileManager.fileExists(atPath: $0.path) }
            }
    }

    // MARK: - SQLite

    /// Chromium keeps the live database locked, so work on a private copy.
    private func readRows(database: URL, domainSuffixes: [String]) throws -> [RawCookie] {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("AIUsage-cookies-\(UUID().uuidString)")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let copy = directory.appendingPathComponent("Cookies")
        try fileManager.copyItem(at: database, to: copy)
        let wal = URL(fileURLWithPath: database.path + "-wal")
        if fileManager.fileExists(atPath: wal.path) {
            try? fileManager.copyItem(
                at: wal,
                to: URL(fileURLWithPath: copy.path + "-wal")
            )
        }

        var handle: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let db = handle else {
            sqlite3_close(handle)
            throw ProviderFailure(.storage, "Browser cookies could not be opened.")
        }
        defer { sqlite3_close(db) }

        let filter = domainSuffixes.map { _ in "host_key LIKE ?" }.joined(separator: " OR ")
        let sql = """
            SELECT host_key, name, value, encrypted_value, last_access_utc, expires_utc
            FROM cookies WHERE \(filter)
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ProviderFailure(.storage, "Browser cookies could not be read.")
        }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, suffix) in domainSuffixes.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), "%\(suffix)", -1, transient)
        }

        let now = Self.chromiumTimestamp(Date())
        var rows: [RawCookie] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let expires = sqlite3_column_int64(statement, 5)
            if expires != 0 && expires < now { continue }
            let blobLength = Int(sqlite3_column_bytes(statement, 3))
            let blob = sqlite3_column_blob(statement, 3).map {
                Data(bytes: $0, count: blobLength)
            } ?? Data()
            rows.append(RawCookie(
                hostKey: Self.text(statement, 0),
                name: Self.text(statement, 1),
                value: Self.text(statement, 2),
                encryptedValue: blob,
                lastAccess: sqlite3_column_int64(statement, 4)
            ))
        }
        return rows
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }

    /// Chromium stores times as microseconds since 1601-01-01.
    static func chromiumTimestamp(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
    }

    // MARK: - Decryption

    private func encryptionKey(for browser: Browser) throws -> Data {
        lock.lock()
        let cached = keys[browser.keychainService]
        lock.unlock()
        if let cached { return cached }

        // Generous timeout: the first read shows a Keychain prompt.
        let result = try processRunner.run(
            executable: "/usr/bin/security",
            arguments: ["find-generic-password", "-w", "-s", browser.keychainService],
            environment: [:],
            timeout: 120
        )
        let password = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.succeeded, !password.isEmpty else {
            throw ProviderFailure(
                .authentication,
                "Allow AI Usage to read \"\(browser.keychainService)\" in Keychain."
            )
        }
        let key = Self.deriveKey(password: password)
        lock.lock()
        keys[browser.keychainService] = key
        lock.unlock()
        return key
    }

    static func deriveKey(password: String) -> Data {
        let passwordBytes = Array(password.utf8)
        let salt = Array("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        passwordBytes.withUnsafeBufferPointer { passwordPointer in
            passwordPointer.withMemoryRebound(to: Int8.self) { password in
                _ = CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    password.baseAddress,
                    password.count,
                    salt,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    1003,
                    &key,
                    key.count
                )
            }
        }
        return Data(key)
    }

    static func decrypt(_ row: RawCookie, key: Data) -> String? {
        if !row.value.isEmpty { return row.value }
        let prefix = Data("v10".utf8)
        guard row.encryptedValue.starts(with: prefix) else {
            return String(data: row.encryptedValue, encoding: .utf8)
        }
        guard var plain = aesDecrypt(
            Data(row.encryptedValue.dropFirst(prefix.count)),
            key: key
        ) else { return nil }

        // Since cookie DB version 24 the value is prefixed with SHA-256(host_key).
        let hostHash = Data(SHA256.hash(data: Data(row.hostKey.utf8)))
        if plain.starts(with: hostHash) {
            plain = Data(plain.dropFirst(hostHash.count))
        }
        return String(data: plain, encoding: .utf8)
    }

    static func aesEncrypt(_ data: Data, key: Data) -> Data? {
        aes(CCOperation(kCCEncrypt), data, key: key)
    }

    private static func aesDecrypt(_ data: Data, key: Data) -> Data? {
        aes(CCOperation(kCCDecrypt), data, key: key)
    }

    private static func aes(_ operation: CCOperation, _ data: Data, key: Data) -> Data? {
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var output = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        var written = 0
        let status = key.withUnsafeBytes { keyBytes in
            data.withUnsafeBytes { dataBytes in
                CCCrypt(
                    operation,
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionPKCS7Padding),
                    keyBytes.baseAddress,
                    key.count,
                    iv,
                    dataBytes.baseAddress,
                    data.count,
                    &output,
                    output.count,
                    &written
                )
            }
        }
        guard status == kCCSuccess else { return nil }
        return Data(output.prefix(written))
    }
}
