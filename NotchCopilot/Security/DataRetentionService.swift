import Foundation

struct DataRetentionService {
    var retentionDays: Int

    func shouldDelete(startedAt: Date, now: Date = Date()) -> Bool {
        guard retentionDays > 0 else { return false }
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: now) ?? now
        return startedAt < cutoff
    }
}

