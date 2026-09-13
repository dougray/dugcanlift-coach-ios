import XCTest
import LiftCore
@testable import Coach

final class PlanWeekTests: XCTestCase {

    func testAWeekIsSevenConsecutiveDaysFromItsStart() {
        let week = PlanWeek(startDayKey: "2026-09-14")
        XCTAssertEqual(week.days.count, 7)
        XCTAssertEqual(week.days.first, "2026-09-14")
        XCTAssertEqual(week.days.last, "2026-09-20")
    }

    func testAdvancingMovesByWholeWeeks() {
        let week = PlanWeek(startDayKey: "2026-09-14")
        XCTAssertEqual(week.advanced(by: 1).startDayKey, "2026-09-21")
        XCTAssertEqual(week.advanced(by: -1).startDayKey, "2026-09-07")
        XCTAssertEqual(week.advanced(by: 4).startDayKey, "2026-10-12")
    }

    func testAWeekCrossingADSTFallBackStillHasSevenDistinctDays() {
        // America/Chicago falls back on 2026-11-01. Seconds-based arithmetic
        // repeats 2026-11-01 and never reaches 2026-11-07.
        let week = PlanWeek(startDayKey: "2026-10-30")
        XCTAssertEqual(Set(week.days).count, 7, "a day repeated across DST")
        XCTAssertEqual(week.days.last, "2026-11-05")
    }

    func testAWeekCrossingAYearBoundaryRollsOver() {
        XCTAssertEqual(PlanWeek(startDayKey: "2026-12-28").days.last, "2027-01-03")
    }

    func testAnUnparseableStartYieldsNoDaysRatherThanCrashing() {
        XCTAssertTrue(PlanWeek(startDayKey: "not-a-day").days.isEmpty)
    }
}
