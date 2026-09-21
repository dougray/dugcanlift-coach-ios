import XCTest
import LiftCore
@testable import Coach

/// Issue #7, findings 1 and 2: a kilogram client's numbers were rendered as raw
/// pounds, and two lifts that differ only by equipment shared one trend line.
final class ClientDisplayTests: XCTestCase {

    // MARK: - Weight is stored in pounds and displayed in the client's unit

    func testAPoundClientSeesTheStoredNumber() {
        XCTAssertEqual(ClientDisplay.weightText(lb: 209.4, unit: "lb"), "209.4")
        XCTAssertEqual(ClientDisplay.weightWithUnit(lb: 225, unit: "lb"), "225 lb")
    }

    func testAKilogramClientSeesKilograms() {
        // The case from the issue: a client who logs in kg weighs 95, which is
        // stored as 209.4 lb. They must not be shown 209.4.
        let stored = 95 * ClientDisplay.lbPerKg
        XCTAssertEqual(ClientDisplay.weightText(lb: stored, unit: "kg"), "95")
        XCTAssertEqual(ClientDisplay.weightWithUnit(lb: stored, unit: "kg"), "95 kg")
    }

    func testConversionUsesTheSameFactorAsAndroid() {
        XCTAssertEqual(ClientDisplay.lbPerKg, 2.2046226218, accuracy: 1e-10)
        XCTAssertEqual(ClientDisplay.weightValue(lb: 100, unit: "kg"), 100 / 2.2046226218, accuracy: 1e-9)
    }

    func testConversionIsDisplayOnlyAndLeavesPoundsAlone() {
        XCTAssertEqual(ClientDisplay.weightValue(lb: 180, unit: "lb"), 180)
    }

    func testAnAbsentWeightIsADashNotAZero() {
        // A set that was never logged is not a zero-weight set.
        XCTAssertEqual(ClientDisplay.weightText(lb: nil, unit: "lb"), "—")
        XCTAssertEqual(ClientDisplay.weightWithUnit(lb: nil, unit: "kg"), "—",
                       "the dash is left bare rather than becoming '— kg'")
    }

    func testTrailingZeroIsTrimmed() {
        XCTAssertEqual(ClientDisplay.weightText(lb: 225.0, unit: "lb"), "225")
        XCTAssertEqual(ClientDisplay.weightText(lb: 102.14, unit: "lb"), "102.1")
    }

    // MARK: - A lift is a name and its equipment

    func testTwoLiftsDifferingOnlyByEquipmentAreDifferentKeys() {
        let cable = ClientDisplay.liftKey(name: "Row", equipment: "Cable")
        let barbell = ClientDisplay.liftKey(name: "Row", equipment: "Barbell")
        XCTAssertNotEqual(cable, barbell,
                          "a cable row and a barbell row must not share a trend line")
    }

    func testTheKeyMatchesTheWireFormat() {
        XCTAssertEqual(ClientDisplay.exerciseKey(name: "Back Squat", equipment: "Barbell"),
                       "Back Squat|Barbell")
        XCTAssertEqual(ClientDisplay.exerciseKey(name: "Pull Up", equipment: nil), "Pull Up|",
                       "an equipment-less exercise is an empty string on the wire, not a missing pipe")
        // The grouping key adds the side, which is empty for a two-sided
        // lift -- so a bench press groups exactly as it always did.
        XCTAssertEqual(ClientDisplay.liftKey(name: "Back Squat", equipment: "Barbell"),
                       "Back Squat|Barbell|")
    }

    func testTheDisplayNameReadsAsACoachWouldSayIt() {
        XCTAssertEqual(ClientDisplay.liftDisplayName(key: "Back Squat|Barbell"), "Back Squat (Barbell)")
        XCTAssertEqual(ClientDisplay.liftDisplayName(key: "Pull Up|"), "Pull Up")
        XCTAssertEqual(ClientDisplay.liftDisplayName(key: "Pull Up| "), "Pull Up",
                       "blank equipment is not equipment")
        XCTAssertEqual(ClientDisplay.liftDisplayName(key: "Unkeyed"), "Unkeyed")
    }

    // MARK: - Roster order

    func testNeverLoggedSortsAsInfinitelySilent() {
        XCTAssertEqual(ClientDisplay.silenceRank(nil), Int.max,
                       "a client who has never logged is the quietest there is")
        XCTAssertEqual(ClientDisplay.silenceRank(3), 3)
    }
}

/// Issue #7, findings 3 and 4: the session log listed days that contained
/// nothing, and the roster was ordered by when the coach happened to tap a
/// link rather than by who needs attention.
final class ClientDetailOrderingTests: XCTestCase {

    private func day(_ key: String, sets: Int, bodyweight: Double? = nil) -> TrainingDay {
        let day = TrainingDay(client: nil, dayKey: key, bodyweightLb: bodyweight)
        day.sets = (0..<sets).map { ExerciseSet(exerciseName: "Squat \($0)", weightLb: 225, reps: 5) }
        return day
    }

    func testADayWithOnlyAWeighInIsNotASession() {
        let days = [
            day("2026-09-10", sets: 0, bodyweight: 206),
            day("2026-09-11", sets: 3),
            day("2026-09-12", sets: 0, bodyweight: 205)
        ]
        let listed = ClientDisplay.sessionDays(days)
        XCTAssertEqual(listed.map(\.dayKey), ["2026-09-11"],
                       "a row that expands to nothing should not be there")
    }

    func testSessionDaysComeBackOldestFirst() {
        let listed = ClientDisplay.sessionDays([day("2026-09-12", sets: 1), day("2026-09-10", sets: 1)])
        XCTAssertEqual(listed.map(\.dayKey), ["2026-09-10", "2026-09-12"])
    }

    func testTheRosterPutsTheQuietestFirst() {
        let rows = [("Recent", 0), ("Quiet", 30), ("Middling", 5)]
        let ordered = ClientDisplay.orderedBySilence(rows, rank: { $0.1 }, name: { $0.0 })
        XCTAssertEqual(ordered.map(\.0), ["Quiet", "Middling", "Recent"])
    }

    func testAClientWhoHasNeverLoggedSortsAboveEveryone() {
        let rows: [(String, Int?)] = [("Logged today", 0), ("Never", nil), ("A week", 7)]
        let ordered = ClientDisplay.orderedBySilence(rows, rank: { $0.1 }, name: { $0.0 })
        XCTAssertEqual(ordered.map(\.0), ["Never", "A week", "Logged today"])
    }

    func testEqualSilenceBreaksOnNameSoTheOrderIsStable() {
        let rows = [("Zoe", 3), ("adam", 3), ("Mia", 3)]
        let ordered = ClientDisplay.orderedBySilence(rows, rank: { $0.1 }, name: { $0.0 })
        XCTAssertEqual(ordered.map(\.0), ["adam", "Mia", "Zoe"],
                       "ties are alphabetical and case-insensitive, not incidental")
    }
}
