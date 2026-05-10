import XCTest
@testable import ClaudeMeter

final class HappyHourPeakWindowTests: XCTestCase {
    func testDefaultWindowIsPeakDuringWeekdayPeakHours() throws {
        let date = try makeDate(year: 2026, month: 5, day: 11, hour: 12, minute: 0, timeZoneID: "America/Los_Angeles")

        let status = HappyHourPeakWindow.default.status(at: date)

        XCTAssertFalse(status.isHappyHour)
        XCTAssertNil(status.nextPeakStart)
    }

    func testDefaultWindowIsHappyHourBeforeWeekdayPeakStarts() throws {
        let date = try makeDate(year: 2026, month: 5, day: 11, hour: 4, minute: 59, timeZoneID: "America/Los_Angeles")

        let status = HappyHourPeakWindow.default.status(at: date)

        XCTAssertTrue(status.isHappyHour)
        XCTAssertEqual(
            status.nextPeakStart,
            try makeDate(year: 2026, month: 5, day: 11, hour: 5, minute: 0, timeZoneID: "America/Los_Angeles")
        )
    }

    func testDefaultWindowIsHappyHourAfterWeekdayPeakEnds() throws {
        let date = try makeDate(year: 2026, month: 5, day: 11, hour: 23, minute: 0, timeZoneID: "America/Los_Angeles")

        let status = HappyHourPeakWindow.default.status(at: date)

        XCTAssertTrue(status.isHappyHour)
        XCTAssertEqual(
            status.nextPeakStart,
            try makeDate(year: 2026, month: 5, day: 12, hour: 5, minute: 0, timeZoneID: "America/Los_Angeles")
        )
    }

    func testDefaultWindowTreatsWeekendAsHappyHour() throws {
        let date = try makeDate(year: 2026, month: 5, day: 9, hour: 14, minute: 0, timeZoneID: "America/Los_Angeles")

        let status = HappyHourPeakWindow.default.status(at: date)

        XCTAssertTrue(status.isHappyHour)
        XCTAssertEqual(
            status.nextPeakStart,
            try makeDate(year: 2026, month: 5, day: 11, hour: 5, minute: 0, timeZoneID: "America/Los_Angeles")
        )
    }

    func testDecodingFallsBackPerInvalidField() throws {
        let data = """
        {
          "days": [1, 8],
          "start": "04:30",
          "end": "99:99",
          "tz": "Mars/Olympus"
        }
        """.data(using: .utf8)!

        let window = try JSONDecoder().decode(HappyHourPeakWindow.self, from: data)

        XCTAssertEqual(window.days, [1])
        XCTAssertEqual(window.start, "04:30")
        XCTAssertEqual(window.end, HappyHourPeakWindow.default.end)
        XCTAssertEqual(window.tz, HappyHourPeakWindow.default.tz)
    }

    private func makeDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        timeZoneID: String
    ) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: timeZoneID))

        let components = DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )

        return try XCTUnwrap(calendar.date(from: components))
    }
}
