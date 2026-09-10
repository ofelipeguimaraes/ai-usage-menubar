import Foundation

/// Keeps the last authoritative Antigravity reading across launches.
///
/// AI Usage deliberately caches nothing else between launches, because every
/// other provider can be re-read on demand. Antigravity cannot: its accurate
/// summary is served by the CLI, so it is only readable while `agy` runs.
/// Without this the card would be empty most of the time.
///
/// Only weekly buckets are worth persisting, and they are: the window spans
/// seven days, so a reading taken hours ago still describes the same window.
/// Anything shorter is dropped rather than shown stale.
/// `UserDefaults` is not marked `Sendable`, but it is documented as
/// thread-safe, which is why this is unchecked rather than isolated.
struct AntigravitySnapshotCache: @unchecked Sendable {
    private static let key = "antigravity.lastAuthoritativeSummary"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private struct StoredWindow: Codable {
        let kind: QuotaKind
        let usedPercent: Double
        let resetsAt: Date?
    }

    private struct Stored: Codable {
        let planName: String?
        let windows: [StoredWindow]
        let readAt: Date
    }

    func save(_ snapshot: ProviderSnapshot) {
        let windows = snapshot.windows
            .filter { $0.kind.survivesCaching }
            .map {
                StoredWindow(
                    kind: $0.kind,
                    usedPercent: $0.usedPercent,
                    resetsAt: $0.resetsAt
                )
            }
        guard !windows.isEmpty else { return }
        let stored = Stored(
            planName: snapshot.planName,
            windows: windows,
            readAt: snapshot.fetchedAt
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: Self.key)
    }

    /// The cached reading, with windows whose reset time has already passed
    /// dropped. A refreshed window is not 100% used, and guessing its new
    /// value would repeat the very bug this cache exists to avoid.
    func load(now: Date) -> ProviderSnapshot? {
        guard let data = defaults.data(forKey: Self.key),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else {
            return nil
        }
        let windows = stored.windows
            .filter { window in
                guard let resetsAt = window.resetsAt else { return true }
                return resetsAt > now
            }
            .map {
                QuotaWindow(
                    kind: $0.kind,
                    usedPercent: $0.usedPercent,
                    resetsAt: $0.resetsAt
                )
            }
        guard !windows.isEmpty else { return nil }
        return ProviderSnapshot(
            provider: .antigravity,
            planName: stored.planName,
            windows: windows,
            fetchedAt: stored.readAt
        )
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}

private extension QuotaKind {
    /// Weekly windows stay meaningful for hours. Short windows do not.
    var survivesCaching: Bool {
        switch self {
        case .weekly, .claudePoolWeekly:
            true
        default:
            false
        }
    }
}
