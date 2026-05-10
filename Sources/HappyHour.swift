import Foundation

struct HappyHourPeakWindow: Codable, Sendable, Equatable {
    static let `default` = HappyHourPeakWindow(
        days: [1, 2, 3, 4, 5],
        start: "05:00",
        end: "23:00",
        tz: "America/Los_Angeles"
    )

    let days: [Int]
    let start: String
    let end: String
    let tz: String

    enum CodingKeys: String, CodingKey {
        case days
        case start
        case end
        case tz
    }

    init(days: [Int], start: String, end: String, tz: String) {
        self.days = Self.validatedDays(days) ?? Self.default.days
        self.start = Self.validatedTime(start) ?? Self.default.start
        self.end = Self.validatedTime(end) ?? Self.default.end
        self.tz = TimeZone(identifier: tz) == nil ? Self.default.tz : tz
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let days = try container.decodeIfPresent([Int].self, forKey: .days)
        let start = try container.decodeIfPresent(String.self, forKey: .start)
        let end = try container.decodeIfPresent(String.self, forKey: .end)
        let tz = try container.decodeIfPresent(String.self, forKey: .tz)

        self.init(
            days: days ?? Self.default.days,
            start: start ?? Self.default.start,
            end: end ?? Self.default.end,
            tz: tz ?? Self.default.tz
        )
    }

    var timeZone: TimeZone {
        TimeZone(identifier: tz) ?? TimeZone(identifier: Self.default.tz)!
    }

    var startMinutes: Int {
        Self.minutes(from: start) ?? Self.minutes(from: Self.default.start)!
    }

    var endMinutes: Int {
        Self.minutes(from: end) ?? Self.minutes(from: Self.default.end)!
    }

    func status(at date: Date = Date()) -> HappyHourStatus {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let weekday = calendar.component(.weekday, from: date) - 1
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        let currentMinutes = (hour * 60) + minute

        let isPeak = days.contains(weekday) && currentMinutes >= startMinutes && currentMinutes < endMinutes
        return HappyHourStatus(
            isHappyHour: !isPeak,
            nextPeakStart: isPeak ? nil : nextPeakStart(after: date, calendar: calendar)
        )
    }

    private func nextPeakStart(after date: Date, calendar: Calendar) -> Date? {
        let startHour = startMinutes / 60
        let startMinute = startMinutes % 60
        let startOfToday = calendar.startOfDay(for: date)

        for offset in 0...7 {
            guard let candidateDay = calendar.date(byAdding: .day, value: offset, to: startOfToday) else {
                continue
            }

            let weekday = calendar.component(.weekday, from: candidateDay) - 1
            guard days.contains(weekday) else {
                continue
            }

            guard let candidateStart = calendar.date(
                bySettingHour: startHour,
                minute: startMinute,
                second: 0,
                of: candidateDay
            ) else {
                continue
            }

            if candidateStart > date {
                return candidateStart
            }
        }

        return nil
    }

    private static func validatedDays(_ days: [Int]) -> [Int]? {
        let filtered = Array(NSOrderedSet(array: days.filter { (0...6).contains($0) })) as? [Int]
        guard let filtered, !filtered.isEmpty else {
            return nil
        }
        return filtered
    }

    private static func validatedTime(_ value: String) -> String? {
        guard minutes(from: value) != nil else {
            return nil
        }
        return value
    }

    private static func minutes(from value: String) -> Int? {
        let parts = value.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0...23).contains(hour),
              (0...59).contains(minute) else {
            return nil
        }

        return (hour * 60) + minute
    }
}

struct HappyHourStatus: Sendable, Equatable {
    let isHappyHour: Bool
    let nextPeakStart: Date?

    var countdownText: String? {
        guard let nextPeakStart else {
            return nil
        }

        let interval = max(0, nextPeakStart.timeIntervalSinceNow)
        let totalMinutes = Int(interval) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return "\(hours) hr \(minutes) min"
        }

        return "\(minutes) min"
    }
}
