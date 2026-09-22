import Foundation

actor QwenProvider: UsageProvider {
    nonisolated let id = ProviderID.qwen
    
    private let reader: any QwenUsageReading
    private let dateProvider: any DateProviding
    
    init(
        reader: any QwenUsageReading = QwenUsageReader(),
        dateProvider: any DateProviding = SystemDateProvider()
    ) {
        self.reader = reader
        self.dateProvider = dateProvider
    }
    
    func fetch() async throws -> ProviderSnapshot {
        let entries = try reader.readEntries()
        return QwenUsageMapper.map(entries: entries, now: dateProvider.now())
    }
}
