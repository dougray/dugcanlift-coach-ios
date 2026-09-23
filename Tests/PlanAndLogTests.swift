import XCTest
import SwiftData
import LiftCore
@testable import Coach

/// The Booked card's rule, against Coach web's own fixture pair.
///
/// `plan-log-sent-plan.json`, `plan-log-share-link.txt` and
/// `plan-log-expected.json` are copied from `dugcanlift-coach`'s
/// `coach/fixtures/`, where they were written by hand from the spec. **Never
/// regenerate them from Swift**: a fixture regenerated from the code under
/// test proves only that the code agrees with itself. Coach web and Coach
/// Android check their own ports against the same three files.
///
/// The locale is pinned only so the tests can assert a string -- the card
/// itself formats in the reader's own, as `RoadFoodDates` does, because Coach
/// web passes `undefined` to `toLocaleDateString`.
final class PlanAndLogTests: XCTestCase {

    private let enUS = Locale(identifier: "en_US")

    // MARK: - The fixture pair, read across the real wire

    private func fixtureURL(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext))
    }

    private struct FixturePlan: Decodable {
        let id: String
        let clientId: String
        let sentAt: Int
        let payload: PlanPayload
    }

    private struct Expected: Decodable {
        let counts: [String: Int]
        let dayStates: [String]
        let lines: [String]
    }

    /// The share link imported the way the app imports one, so the log is read
    /// across the real wire rather than handed to the rule as a convenient
    /// object -- and the set order the card prints is the order the importer
    /// recorded.
    private func fixtureResult(weeks: Int = 8) throws -> (PlanAndLog.Result, Expected) {
        let context = ModelContext(try ModelContainer(
            for: Schema(CoachSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        let link = try String(contentsOf: fixtureURL("plan-log-share-link", "txt"), encoding: .utf8)
        try ShareLinkImporter.importLink(link, into: context)
        let client = try XCTUnwrap(try context.fetch(FetchDescriptor<Client>()).first)

        let sent = try JSONDecoder().decode(
            FixturePlan.self, from: Data(contentsOf: fixtureURL("plan-log-sent-plan", "json")))
        let expected = try JSONDecoder().decode(
            Expected.self, from: Data(contentsOf: fixtureURL("plan-log-expected", "json")))

        let result = PlanAndLog.compare(
            clientID: client.id,
            sentPlans: [PlanAndLog.StoredPlan(id: sent.id, clientID: sent.clientId,
                                              sentAtEpochSec: sent.sentAt, payload: sent.payload)],
            days: PlanAndLog.loggedDays(of: client),
            coverage: client.covered,
            unit: client.displayUnit,
            today: "2026-10-18",
            weeks: weeks,
            locale: enUS)
        return (result, expected)
    }

    func testTheFixturePairProducesExactlyTheLinesTheFixtureSays() throws {
        let (result, expected) = try fixtureResult()
        XCTAssertEqual(PlanAndLog.lines(result), expected.lines)
    }

    func testTheFixturePairProducesExactlyTheCountsAndDayStatesItSays() throws {
        let (result, expected) = try fixtureResult()
        XCTAssertEqual(result.groups.count, 1)
        let counts = try XCTUnwrap(result.groups.first?.counts)
        XCTAssertEqual(counts, PlanAndLog.Counts(
            booked: expected.counts["booked"] ?? -1, logged: expected.counts["logged"] ?? -1,
            notLogged: expected.counts["notLogged"] ?? -1, outside: expected.counts["outside"] ?? -1,
            other: expected.counts["other"] ?? -1))
        XCTAssertEqual(result.groups[0].days.map(\.state.rawValue), expected.dayStates)
        XCTAssertEqual(result.groups[0].range, "12–17 Oct")
    }

    /// The window comes off the link itself, so "outside the log they sent" is
    /// a fact about what the client sent and not a guess.
    func testTheCoveredWindowComesOffTheLink() throws {
        let context = ModelContext(try ModelContainer(
            for: Schema(CoachSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        let link = try String(contentsOf: fixtureURL("plan-log-share-link", "txt"), encoding: .utf8)
        try ShareLinkImporter.importLink(link, into: context)
        let client = try XCTUnwrap(try context.fetch(FetchDescriptor<Client>()).first)
        XCTAssertEqual(client.covered, CoveredRange(from: "2026-09-21", to: "2026-10-16"))
    }

    // MARK: - The join, case by case

    private func ex(_ name: String, _ equipment: String?, _ sets: [[Double?]],
                    eachSide: Bool = false) -> PlanWorkoutExercise {
        PlanWorkoutExercise(n: name, q: equipment, c: nil, s: sets, b: eachSide ? 1 : nil)
    }

    private func plan(_ bookings: [(String, Int)], _ workouts: [(String, [PlanWorkoutExercise])],
                      id: String = "p1", sentAt: Int = 1000) -> PlanAndLog.StoredPlan {
        PlanAndLog.StoredPlan(
            id: id, clientID: "c", sentAtEpochSec: sentAt,
            payload: PlanPayload(v: 1, t: "plan", l: "c", n: "", r: [], m: [],
                                 w: workouts.map { PlanWorkout(n: $0.0, e: $0.1) },
                                 k: bookings.map { PlanSession(d: $0.0, x: $0.1) }))
    }

    private func logged(_ name: String, _ equipment: String,
                        _ sets: [PlanAndLog.SetValues]) -> PlanAndLog.Exercise {
        PlanAndLog.Exercise(key: PlanAndLog.matchKey(name: name, equipment: equipment),
                            name: name, equipment: equipment, eachSide: false, sets: sets)
    }

    private func set(_ weightLb: Double?, _ reps: Double?, side: SetSide? = nil,
                     warmup: Bool = false) -> PlanAndLog.SetValues {
        PlanAndLog.SetValues(weightLb: weightLb, reps: reps, side: side, isWarmup: warmup)
    }

    private func day(_ exercises: [PlanAndLog.Exercise], name: String = "") -> PlanAndLog.LoggedDay {
        PlanAndLog.LoggedDay(name: name, exercises: exercises)
    }

    private func run(_ bookings: [(String, Int)], _ workouts: [(String, [PlanWorkoutExercise])],
                     _ days: [String: PlanAndLog.LoggedDay],
                     coverage: CoveredRange? = CoveredRange(from: "2026-10-01", to: "2026-10-31"),
                     unit: String = "lb", today: String = "2026-10-20",
                     plans: [PlanAndLog.StoredPlan]? = nil) -> PlanAndLog.Result {
        PlanAndLog.compare(clientID: "c", sentPlans: plans ?? [plan(bookings, workouts)],
                           days: days, coverage: coverage, unit: unit, today: today,
                           locale: enUS)
    }

    private func first(_ result: PlanAndLog.Result, _ index: Int = 0) throws -> PlanAndLog.DayRow {
        try XCTUnwrap(result.groups.first?.days[index])
    }

    func testABookedDayTheClientLoggedReadsLogged() throws {
        let result = run([("2026-10-12", 0)],
                         [("Lower A", [ex("Back Squat", "Barbell", [[225, 5]])])],
                         ["2026-10-12": day([logged("Back Squat", "Barbell", [set(225, 5)])], name: "Lower A")])
        XCTAssertEqual(try first(result).text, "Mon 12 Oct · Lower A · logged")
        XCTAssertEqual(result.groups[0].counts,
                       PlanAndLog.Counts(booked: 1, logged: 1, notLogged: 0, outside: 0, other: 0))
    }

    func testABookedDayWithNothingLoggedReadsNotLoggedNeverMissed() throws {
        let result = run([("2026-10-12", 0)],
                         [("Lower A", [ex("Back Squat", "Barbell", [[225, 5]])])], [:])
        XCTAssertEqual(try first(result).text, "Mon 12 Oct · Lower A · not logged")
        XCTAssertEqual(result.groups[0].head, "Booked 1 day, 12 Oct · logged 0")
    }

    func testABookedDayOutsideTheWindowTheClientSentIsNeverCalledNotLogged() throws {
        let result = run([("2026-10-12", 0)],
                         [("Lower A", [ex("Back Squat", "Barbell", [[225, 5]])])], [:],
                         coverage: CoveredRange(from: "2026-09-01", to: "2026-10-05"))
        XCTAssertEqual(try first(result).text, "Mon 12 Oct · Lower A · outside the log they sent")
        XCTAssertEqual(result.groups[0].head, "Booked 1 day, 12 Oct · no log covering them")
        XCTAssertFalse(PlanAndLog.lines(result).joined(separator: " ").contains("not logged"))
    }

    /// A client Coach has no window for at all -- imported before Coach
    /// recorded one -- is "we do not know", never "they logged nothing".
    func testAClientWhoHasSentNothingAtAllGetsNoLogCoveringThem() throws {
        let result = run([("2026-10-12", 0)],
                         [("Lower A", [ex("Back Squat", "Barbell", [[225, 5]])])], [:],
                         coverage: nil)
        XCTAssertEqual(try first(result).state, .outside)
    }

    func testALoggedDayInsideTheSpanWithNoBookingReadsNotBooked() throws {
        let result = run([("2026-10-12", 0), ("2026-10-16", 0)],
                         [("Lower A", [ex("Back Squat", "Barbell", [[225, 5]])])],
                         ["2026-10-13": day([logged("Bench Press", "Barbell", [set(185, 5)])], name: "Upper B")])
        XCTAssertEqual(result.groups[0].days.map(\.text), [
            "Mon 12 Oct · Lower A · not logged",
            "Tue 13 Oct · Upper B · not booked",
            "Fri 16 Oct · Lower A · not logged",
        ])
        XCTAssertEqual(result.groups[0].counts.other, 1)
        XCTAssertTrue(result.groups[0].head.hasSuffix("1 other day logged"))
    }

    func testASubstitutionShowsAsOnePairOnNameAloneLabelled() throws {
        let result = run([("2026-10-12", 0)],
                         [("Lower A", [ex("Lat Pulldown", "Cable", [[140, 10]])])],
                         ["2026-10-12": day([logged("Lat Pulldown", "Machine", [set(140, 10)])])])
        let exercises = try first(result).exercises
        XCTAssertEqual(exercises.count, 1)
        XCTAssertEqual(exercises[0].substitution, "Asked Cable · logged Machine")
        XCTAssertTrue(try first(result).alsoLogged.isEmpty)
    }

    func testAnExactNameAndEquipmentMatchAlwaysWinsOverANameOnlyOne() throws {
        let result = run([("2026-10-12", 0)],
                         [("Lower A", [ex("Lat Pulldown", "Cable", [[140, 10]])])],
                         ["2026-10-12": day([
                            logged("Lat Pulldown", "Machine", [set(150, 10)]),
                            logged("Lat Pulldown", "Cable", [set(140, 10)])])])
        let exercises = try first(result).exercises
        XCTAssertNil(exercises[0].substitution, "the cable one is the match")
        XCTAssertEqual(exercises[0].logged?.text, "140 × 10")
        XCTAssertEqual(try first(result).alsoLogged[0].text, "Lat Pulldown (Machine) · 1 set")
    }

    func testTheSameLiftPrescribedTwiceInADayPoolsIntoOnePrescription() throws {
        let result = run([("2026-10-12", 0)],
                         [("Lower A", [ex("Back Squat", "Barbell", [[225, 5], [225, 5]]),
                                       ex("Back Squat", "Barbell", [[245, 3]])])],
                         ["2026-10-12": day([logged("Back Squat", "Barbell",
                                                    [set(225, 5), set(225, 5), set(245, 3)])])])
        let exercises = try first(result).exercises
        XCTAssertEqual(exercises.count, 1)
        XCTAssertEqual(exercises[0].asked?.text, "225 × 5 · 225 × 5 · 245 × 3")
        XCTAssertNil(exercises[0].countLine)
    }

    func testTheSameLiftLoggedTwiceInADayPoolsToo() throws {
        let result = run([("2026-10-12", 0)],
                         [("Lower A", [ex("Back Squat", "Barbell", [[225, 5], [225, 5], [245, 3]])])],
                         ["2026-10-12": day([logged("Back Squat", "Barbell", [set(225, 5), set(225, 5)]),
                                             logged("Back Squat", "Barbell", [set(245, 3)])])])
        let exercises = try first(result).exercises
        XCTAssertEqual(exercises.count, 1)
        XCTAssertEqual(exercises[0].logged?.text, "225 × 5 · 225 × 5 · 245 × 3")
        XCTAssertTrue(try first(result).alsoLogged.isEmpty)
    }

    func testTwoSentPlansBookingTwoSpansAreTwoGroupsNewestFirst() {
        let workouts = [("Lower A", [ex("Back Squat", "Barbell", [[225, 5]])])]
        let result = run([], [], [:], plans: [
            plan([("2026-10-05", 0)], workouts, id: "old", sentAt: 1),
            plan([("2026-10-12", 0)], workouts, id: "new", sentAt: 2),
        ])
        XCTAssertEqual(result.groups.map(\.id), ["new", "old"])
        XCTAssertEqual(result.groups.map(\.range), ["12 Oct", "5 Oct"])
    }

    func testAPlanBookingNothingInTheLastEightWeeksIsNotAGroupAtAll() {
        let result = run([("2026-05-01", 0)],
                         [("Lower A", [ex("Back Squat", "Barbell", [[225, 5]])])], [:])
        XCTAssertTrue(result.groups.isEmpty)
        XCTAssertTrue(PlanAndLog.lines(result).isEmpty)
    }

    /// Meals are not compared, now or as a follow-up.
    func testAPlanSentWithNoTrainingAtAllBooksNothing() {
        let payload = PlanPayload(v: 1, t: "plan", l: "c", n: "", r: [], m: [
            PlanMeal(d: "2026-10-12", s: 2, x: 0, q: 1)], w: nil, k: nil)
        let result = run([], [], [:], plans: [
            PlanAndLog.StoredPlan(id: "p", clientID: "c", sentAtEpochSec: 1, payload: payload)])
        XCTAssertTrue(result.groups.isEmpty)
    }

    /// No sent plan: no heading, no chips, no card, and no explanation. Plans
    /// sent before this existed cannot be reconstructed, and a line saying so
    /// is a line every coach reads once and never again.
    func testNoPlanWasEverSentSoThereIsNoCardAndNoExplanation() {
        let result = run([], [], [:], plans: [])
        XCTAssertTrue(result.groups.isEmpty)
        XCTAssertTrue(result.byLift.isEmpty)
        XCTAssertTrue(PlanAndLog.lines(result).isEmpty, "not even the footer")
    }

    // MARK: - Sets

    func testSetsAreCountedNeverPairedOneToOne() throws {
        let result = run([("2026-10-12", 0)],
                         [("Lower A", [ex("Romanian Deadlift", "Barbell",
                                          [[185, 8], [185, 8], [185, 8], [185, 8]])])],
                         ["2026-10-12": day([logged("Romanian Deadlift", "Barbell",
                                                    [set(185, 8), set(185, 8), set(185, 6)])])])
        let row = try first(result).exercises[0]
        XCTAssertEqual(row.countLine, "Asked 4 sets · logged 3")
        XCTAssertEqual(row.asked?.text, "185 × 8 · 185 × 8 · 185 × 8 · 185 × 8")
        XCTAssertEqual(row.logged?.text, "185 × 8 · 185 × 8 · 185 × 6")
    }

    func testWarmupsAreExcludedFromBothCounts() throws {
        let result = run([("2026-10-12", 0)],
                         [("Lower A", [ex("Back Squat", "Barbell", [[225, 5], [225, 5]])])],
                         ["2026-10-12": day([logged("Back Squat", "Barbell",
                                                    [set(135, 8, warmup: true), set(225, 5), set(225, 5)])])])
        let row = try first(result).exercises[0]
        XCTAssertEqual(row.logged?.text, "225 × 5 · 225 × 5")
        XCTAssertNil(row.countLine)
    }

    /// 0 both, 1 warmup, 2 left, 3 left warmup, 4 right, 5 right warmup --
    /// masked, never compared, read off a real wire day.
    func testFlagsAreMaskedNeverComparedForAllSixValues() throws {
        let sets: [PlanAndLog.SetValues] = [0, 1, 2, 3, 4, 5].map { flags in
            PlanAndLog.SetValues(weightLb: 100, reps: 5,
                                 side: SetFlags.side(flags), isWarmup: SetFlags.isWarmup(flags))
        }
        let result = run([("2026-10-12", 0)],
                         [("Arms", [ex("Curl", "Dumbbell", [[100, 5]], eachSide: true)])],
                         ["2026-10-12": day([logged("Curl", "Dumbbell", sets)])])
        let row = try first(result).exercises[0]
        // Working sets only: 0 (both), 2 (left) and 4 (right). 1, 3 and 5 are
        // warmups whatever side they name.
        XCTAssertEqual(row.sideLine, "L 1/1 · R 1/1 · 1 both")
        XCTAssertEqual(row.logged?.text, "L 100 × 5   R 100 × 5   Both 100 × 5")
    }

    func testSidesReadLThreeOfThreeAndOverIsNeverCapped() throws {
        let sided = { (count: Int, side: SetSide) in
            (0..<count).map { _ in self.set(40, 8, side: side) }
        }
        let result = run([("2026-10-12", 0)],
                         [("Lower A", [ex("Bulgarian Split Squat", "Dumbbell",
                                          [[40, 8], [40, 8], [40, 8]], eachSide: true)])],
                         ["2026-10-12": day([logged("Bulgarian Split Squat", "Dumbbell",
                                                    sided(4, .left) + sided(2, .right))])])
        XCTAssertEqual(try first(result).exercises[0].sideLine, "L 4/3 · R 2/3")
    }

    func testAnEachSideExercisesAskIsTwiceItsTuples() throws {
        let result = run([("2026-10-12", 0)],
                         [("Lower A", [ex("Lunge", "Dumbbell", [[40, 8], [40, 8], [40, 8]],
                                          eachSide: true)])],
                         ["2026-10-12": day([logged("Lunge", "Dumbbell", [set(40, 8, side: .left)])])])
        let row = try first(result).exercises[0]
        XCTAssertEqual(row.sideLine, "L 1/3 · R 0/3", "three tuples each side is six sets")
        XCTAssertTrue(row.title.hasSuffix(" · each side"))
        XCTAssertTrue(try XCTUnwrap(row.asked?.text).hasSuffix(" each side"))
        XCTAssertEqual(row.asked?.suffix, " each side",
                       "the clause is its own field, so a view cannot draw the sets and drop it")
    }

    func testAPlanWithNoSidesProducesNoSideLineAtAll() throws {
        let result = run([("2026-10-12", 0)],
                         [("Lower A", [ex("Back Squat", "Barbell", [[225, 5]])])],
                         ["2026-10-12": day([logged("Back Squat", "Barbell", [set(225, 5)])])])
        let row = try first(result).exercises[0]
        XCTAssertNil(row.sideLine)
        XCTAssertEqual(row.title, "Back Squat (Barbell)")
    }

    func testBlankStaysBlank() {
        XCTAssertEqual(PlanAndLog.setText(.init(weightLb: nil, reps: 5), unit: "lb", locale: enUS),
                       "5 reps")
        XCTAssertEqual(PlanAndLog.setText(.init(weightLb: 225, reps: nil), unit: "lb", locale: enUS),
                       "225 lb")
        XCTAssertEqual(PlanAndLog.setText(.init(durationSec: 600, distanceM: 1600),
                                          unit: "lb", locale: enUS),
                       "1,600 m · 10:00")
        XCTAssertEqual(PlanAndLog.setText(.init(), unit: "lb", locale: enUS), "as written")
    }

    func testAKgClientReadsKilogramsOnBothRowsFromOneSource() throws {
        let result = run([("2026-10-12", 0)],
                         [("Lower A", [ex("Back Squat", "Barbell", [[220, 5]])])],
                         ["2026-10-12": day([logged("Back Squat", "Barbell", [set(220, 5)])])],
                         unit: "kg")
        let row = try first(result).exercises[0]
        XCTAssertEqual(row.asked?.text, "100 × 5")
        XCTAssertEqual(row.logged?.text, "100 × 5")
        // The stored payload and the wire both stay pounds; only the display
        // moved. A `RoutinePrescribedSet`'s kilograms are never read here.
        XCTAssertEqual(plan([("2026-10-12", 0)],
                            [("Lower A", [ex("Back Squat", "Barbell", [[220, 5]])])])
            .payload.w?[0].e[0].s[0][0], 220)
    }

    // MARK: - Set order

    /// The order the client logged in, recorded by the importer and read back
    /// through `orderIndex` -- `day.sets` is an unordered to-many, so without
    /// it "Logged 225 × 5 · 225 × 5 · 245 × 2" could not be trusted.
    func testTheLoggedRowIsInTheOrderTheClientLoggedIt() throws {
        let context = ModelContext(try ModelContainer(
            for: Schema(CoachSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        let client = Client(id: "c", name: "Sam", displayUnit: "lb", platform: "ios")
        context.insert(client)
        let day = TrainingDay(client: client, dayKey: "2026-10-12")
        context.insert(day)
        client.trainingDays.append(day)
        // Inserted out of order on purpose: the index is what orders them.
        for (index, weight) in [(2, 245.0), (0, 225.0), (1, 235.0)] {
            let set = ExerciseSet(day: day, exerciseName: "Back Squat", equipment: "Barbell",
                                  weightLb: weight, reps: 5, orderIndex: index)
            context.insert(set)
            day.sets.append(set)
        }
        try context.save()

        let logged = PlanAndLog.loggedDay(day)
        XCTAssertEqual(logged.exercises[0].sets.map(\.weightLb), [225, 235, 245])
    }

    /// A day stored before Coach recorded the order still prints both rows.
    /// Nothing is aligned against the asked row either way, so there is
    /// nothing to be wrong about.
    func testADayWithNoOrderIndexStillPrintsBothRowsAndAlignsNothing() throws {
        let result = run([("2026-10-12", 0)],
                         [("Lower A", [ex("Back Squat", "Barbell", [[225, 5], [225, 5]])])],
                         ["2026-10-12": day([logged("Back Squat", "Barbell",
                                                    [set(225, 5), set(225, 5)])])])
        let row = try first(result).exercises[0]
        XCTAssertNotNil(row.asked)
        XCTAssertNotNil(row.logged)
        XCTAssertNil(row.countLine, "the counts agree; nothing claims which set answered which")
    }

    // MARK: - By lift

    func testByLiftStacksTheSameLinesUnderOneHeadingByDate() throws {
        let workouts = [("Lower A", [ex("Back Squat", "Barbell", [[225, 5]])])]
        let result = run([("2026-10-12", 0), ("2026-10-15", 0)], workouts, [
            "2026-10-12": day([logged("Back Squat", "Barbell", [set(225, 5)])]),
            "2026-10-15": day([logged("Back Squat", "Barbell", [set(230, 5)])]),
        ])
        XCTAssertEqual(result.byLift.count, 1)
        XCTAssertEqual(result.byLift[0].title, "Back Squat (Barbell)")
        XCTAssertEqual(result.byLift[0].entries.map(\.when), ["12 Oct", "15 Oct"])
        XCTAssertEqual(result.byLift[0].entries.map { $0.exercise.logged?.text },
                       ["225 × 5", "230 × 5"])
    }

    func testByLiftShowsTheWeeksALiftWasBookedAndNotLoggedToo() throws {
        let workouts = [("Lower A", [ex("Back Squat", "Barbell", [[225, 5]])])]
        let result = run([("2026-10-12", 0), ("2026-10-15", 0), ("2026-10-19", 0)], workouts,
                         ["2026-10-12": day([logged("Back Squat", "Barbell", [set(225, 5)])])],
                         coverage: CoveredRange(from: "2026-10-01", to: "2026-10-16"))
        // Shown only on the weeks it was logged, a lift reads steadier than it was.
        XCTAssertEqual(result.byLift[0].entries.map { [$0.when, $0.exercise.title] }, [
            ["12 Oct", "Back Squat (Barbell)"],
            ["15 Oct", "Back Squat (Barbell) · not logged"],
            ["19 Oct", "Back Squat (Barbell) · outside the log they sent"],
        ])
        // And the heading is the lift, never one day's verdict on it.
        XCTAssertEqual(result.byLift[0].title, "Back Squat (Barbell)")
    }

    func testTheDayViewDoesNotReciteAMissedDaysPrescription() throws {
        let result = run([("2026-10-12", 0)],
                         [("Lower A", [ex("Back Squat", "Barbell", [[225, 5]])])], [:])
        XCTAssertTrue(try first(result).exercises.isEmpty, "the row above already says it")
        XCTAssertEqual(try first(result).booked.count, 1, "but by lift still has it")
    }

    func testALiftNobodyAskedForThatWasAllWarmupsIsNotZeroSetsOnScreen() throws {
        let result = run([("2026-10-12", 0)],
                         [("Lower A", [ex("Back Squat", "Barbell", [[225, 5]])])],
                         ["2026-10-12": day([
                            logged("Back Squat", "Barbell", [set(225, 5)]),
                            logged("Treadmill", "Machine", [set(nil, nil, warmup: true)])])])
        XCTAssertTrue(try first(result).alsoLogged.isEmpty,
                      "working sets are the claim everywhere else")
    }

    // MARK: - The line discipline

    /// The spirit of `PerLimbTests.testNothingInTheseLinesTellsACoachWhatToDo`
    /// and its Coach web twin: the card counts, and never grades.
    private let forbidden = ["should", "fix", "warning", "target", "too ", "concern",
                             "missed", "skipped", "failed", "poor", "behind", "compliance",
                             "adherence", "streak", "%"]

    func testNothingInThisCardTellsACoachWhatToDo() throws {
        // Every state the card has: a logged day, a day with nothing logged, a
        // day outside the window the client sent, a day logged and not booked;
        // and a matched lift, a substituted one, one short on a side, one short
        // on sets, one not logged at all and one nobody asked for.
        let (result, _) = try fixtureResult()
        let every = PlanAndLog.lines(result).joined(separator: " · ").lowercased()
        XCTAssertGreaterThan(every.count, 200, "the fixture should exercise the whole card")
        for word in forbidden {
            XCTAssertFalse(every.contains(word), "\"\(word)\" reached a screen")
        }
        XCTAssertFalse(PlanAndLog.footer.lowercased().contains("adherence"))
    }

    func testNothingHereAggregatesAClientIntoAScore() throws {
        let (result, _) = try fixtureResult()

        // Counts hang off a day or a group of days, and there is nothing at
        // the top of the result to aggregate: no roster figure, no all-time
        // total, no trend across weeks.
        XCTAssertEqual(Mirror(reflecting: result).children.compactMap(\.label).sorted(),
                       ["byLift", "footer", "groups"])
        XCTAssertEqual(Mirror(reflecting: result.groups[0].counts).children
            .compactMap(\.label).sorted(),
                       ["booked", "logged", "notLogged", "other", "outside"],
                       "a group counts days and nothing else")

        // And nothing anywhere in the tree is a score, a rate or a percentage.
        let banned = ["score", "percent", "rate", "ratio", "average", "total",
                      "streak", "grade", "adherence", "compliance"]
        func walk(_ node: Any, _ path: String) {
            let mirror = Mirror(reflecting: node)
            if let text = node as? String {
                XCTAssertFalse(text.contains("%"), "\(path) carries a percentage")
            }
            for child in mirror.children {
                if let label = child.label, !label.hasPrefix(".") {
                    for word in banned {
                        XCTAssertFalse(label.lowercased().contains(word),
                                       "\(path).\(label) reads as a grade")
                    }
                }
                walk(child.value, path + "." + (child.label ?? "[]"))
            }
        }
        walk(result, "result")
    }

}
