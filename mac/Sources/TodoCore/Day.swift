import Foundation

/// A calendar date with no time of day, written "YYYY-MM-DD".
/// Arithmetic runs in UTC so daylight-saving changes never shift a day.
public struct Day: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init?(_ string: String) {
        let parts = string.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    /// Today in the user's own calendar and time zone.
    public static func today(_ now: Date = Date(), calendar: Calendar = .current) -> Day {
        let c = calendar.dateComponents([.year, .month, .day], from: now)
        return Day(year: c.year!, month: c.month!, day: c.day!)
    }

    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private var noonUTC: Date {
        Day.utc.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private init(noonUTC date: Date) {
        let c = Day.utc.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year!, month: c.month!, day: c.day!)
    }

    public func adding(days n: Int) -> Day {
        Day(noonUTC: Day.utc.date(byAdding: .day, value: n, to: noonUTC)!)
    }

    /// Moves by whole months, keeping the day where the month allows it.
    public func adding(months n: Int) -> Day {
        Day(noonUTC: Day.utc.date(byAdding: .month, value: n, to: noonUTC)!)
    }

    /// 1 = Monday … 7 = Sunday.
    public var isoWeekday: Int {
        let w = Day.utc.component(.weekday, from: noonUTC) // 1 = Sunday
        return w == 1 ? 7 : w - 1
    }

    /// The Monday that starts this day's week.
    public var weekStart: Day { adding(days: -(isoWeekday - 1)) }

    public var monthStart: Day { Day(year: year, month: month, day: 1) }

    public var daysInMonth: Int { Day.utc.range(of: .day, in: .month, for: noonUTC)!.count }

    public func days(until other: Day) -> Int {
        Day.utc.dateComponents([.day], from: noonUTC, to: other.noonUTC).day!
    }

    /// The seven days of this day's week, Monday first.
    public var week: [Day] { (0..<7).map { weekStart.adding(days: $0) } }

    /// Every day in a month calendar: whole Monday-to-Sunday weeks that cover the month.
    public var monthGrid: [Day] {
        let first = monthStart.weekStart
        let last = Day(year: year, month: month, day: daysInMonth)
        let end = last.adding(days: 7 - last.isoWeekday)
        return (0...first.days(until: end)).map { first.adding(days: $0) }
    }

    public static func < (a: Day, b: Day) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let d = Day(s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad day \(s)"))
        }
        self = d
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}
