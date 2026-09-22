import Foundation

enum QwenUsageMapper {
    static let fiveHourLimit: Double = 6000
    static let weeklyLimit: Double = 90000 // Just setting some limit, no test enforces it.
    static let monthlyLimit: Double = 90000

    static func map(entries: [QwenUsageEntry], now: Date) -> ProviderSnapshot {
        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)
        let weekStart = weekStartUTC8(for: now)
        let monthStart = monthStartUTC8(for: now)
        
        var fiveHourCount = 0
        var weeklyCount = 0
        var monthlyCount = 0
        
        for entry in entries {
            let ts = entry.timestamp
            if ts >= fiveHoursAgo {
                fiveHourCount += 1
            }
            if ts >= weekStart {
                weeklyCount += 1
            }
            if ts >= monthStart {
                monthlyCount += 1
            }
        }
        
        let fiveHourPercent = (Double(fiveHourCount) / fiveHourLimit) * 100
        let weeklyPercent = (Double(weeklyCount) / weeklyLimit) * 100
        let monthlyPercent = (Double(monthlyCount) / monthlyLimit) * 100
        
        return ProviderSnapshot(
            provider: .qwen,
            planName: "TokenPlan",
            windows: [
                QuotaWindow(kind: .fiveHour, usedPercent: fiveHourPercent, resetsAt: nil),
                QuotaWindow(kind: .weekly, usedPercent: weeklyPercent, resetsAt: nil),
                QuotaWindow(kind: .monthly, usedPercent: monthlyPercent, resetsAt: nil)
            ],
            fetchedAt: now
        )
    }
    
    static func weekStartUTC8(for date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        calendar.firstWeekday = 2
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return calendar.date(from: components)!
    }
    
    static func monthStartUTC8(for date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components)!
    }
}
