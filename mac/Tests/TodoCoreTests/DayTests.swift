import Foundation
import Testing
@testable import TodoCore

struct DayTests {
    @Test func parsesAndPrints() {
        #expect(Day("2026-11-19") == Day(year: 2026, month: 11, day: 19))
        #expect(Day("2026-11-19")?.description == "2026-11-19")
        #expect(Day("2026-13-01") == nil)
        #expect(Day("nope") == nil)
    }

    @Test func addsAcrossMonthsAndYears() {
        #expect(Day(year: 2026, month: 11, day: 30).adding(days: 1) == Day(year: 2026, month: 12, day: 1))
        #expect(Day(year: 2026, month: 12, day: 31).adding(days: 1) == Day(year: 2027, month: 1, day: 1))
        #expect(Day(year: 2027, month: 1, day: 31).adding(months: 1) == Day(year: 2027, month: 2, day: 28))
        #expect(Day(year: 2026, month: 3, day: 1).adding(days: -1) == Day(year: 2026, month: 2, day: 28))
    }

    @Test func weeksStartOnMonday() {
        let thursday = Day(year: 2026, month: 11, day: 19)
        #expect(thursday.isoWeekday == 4)
        #expect(thursday.weekStart == Day(year: 2026, month: 11, day: 16))
        #expect(Day(year: 2026, month: 11, day: 22).weekStart == Day(year: 2026, month: 11, day: 16)) // Sunday
        #expect(thursday.week.count == 7)
        #expect(thursday.week.last == Day(year: 2026, month: 11, day: 22))
    }

    @Test func monthGridCoversWholeWeeks() {
        let grid = Day(year: 2026, month: 11, day: 19).monthGrid
        #expect(grid.count % 7 == 0)
        #expect(grid.first == Day(year: 2026, month: 10, day: 26)) // Monday before Nov 1 (a Sunday)
        #expect(grid.last == Day(year: 2026, month: 12, day: 6))
        #expect(grid.contains(Day(year: 2026, month: 11, day: 30)))
    }

    @Test func todayUsesTheGivenTimeZone() {
        var seoul = Calendar(identifier: .gregorian)
        seoul.timeZone = TimeZone(identifier: "Asia/Seoul")!
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let lateUTC = utc.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 20))!
        #expect(Day.today(lateUTC, calendar: utc) == Day(year: 2026, month: 11, day: 19))
        #expect(Day.today(lateUTC, calendar: seoul) == Day(year: 2026, month: 11, day: 20))
    }

    @Test func codesAsString() throws {
        let data = try JSONEncoder().encode([Day(year: 2026, month: 1, day: 5)])
        #expect(String(decoding: data, as: UTF8.self) == "[\"2026-01-05\"]")
        #expect(try JSONDecoder().decode([Day].self, from: data) == [Day(year: 2026, month: 1, day: 5)])
    }
}
