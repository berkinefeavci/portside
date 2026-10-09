import Foundation

enum TimeText {
    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    /// "just now", "5 min. ago", "yesterday" … in the user's language.
    static func ago(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 60 { return String(localized: "just now") }
        return relative.localizedString(for: date, relativeTo: now)
    }

    /// "40s", "12m", "3h 5m", "2d"
    static func duration(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60:
            return String(localized: "\(seconds)s")
        case ..<3600:
            return String(localized: "\(seconds / 60)m")
        case ..<86_400:
            let hours = seconds / 3600, minutes = (seconds % 3600) / 60
            return minutes == 0
                ? String(localized: "\(hours)h")
                : String(localized: "\(hours)h \(minutes)m")
        default:
            return String(localized: "\(seconds / 86_400)d")
        }
    }

    enum DayGroup: Int, CaseIterable {
        case pinned, today, yesterday, thisWeek, older

        var title: String {
            switch self {
            case .pinned: String(localized: "PINNED")
            case .today: String(localized: "TODAY")
            case .yesterday: String(localized: "YESTERDAY")
            case .thisWeek: String(localized: "THIS WEEK")
            case .older: String(localized: "OLDER")
            }
        }
    }

    static func dayGroup(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> DayGroup {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return .yesterday }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 { return .thisWeek }
        return .older
    }
}
