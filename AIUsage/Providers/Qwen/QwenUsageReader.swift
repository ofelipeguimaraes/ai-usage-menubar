import Foundation

protocol QwenUsageReading: Sendable {
    func readEntries() throws -> [QwenUsageEntry]
}

struct QwenUsageReader: QwenUsageReading {
    private let directoryURL: URL
    
    init(directoryURL: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".qwen/usage")) {
        self.directoryURL = directoryURL
    }
    
    func readEntries() throws -> [QwenUsageEntry] {
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw ProviderFailure(.storage, "Usage directory not found at \(directoryURL.path)")
        }
        
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()
        
        var entries: [QwenUsageEntry] = []
        let enumerator = fileManager.enumerator(at: directoryURL, includingPropertiesForKeys: nil)
        
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent.hasPrefix("token-usage-") && url.pathExtension == "jsonl" {
                if let string = try? String(contentsOf: url, encoding: .utf8) {
                    let lines = string.components(separatedBy: .newlines)
                    for line in lines where !line.isEmpty {
                        if let data = line.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let timestampStr = json["timestamp"] as? String {
                           if let date = formatter.date(from: timestampStr) ?? fallbackFormatter.date(from: timestampStr) {
                               entries.append(QwenUsageEntry(timestamp: date))
                           }
                        }
                    }
                }
            }
        }
        return entries
    }
}
