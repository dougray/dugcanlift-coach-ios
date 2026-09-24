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
        let counts = try XCTUnwrap(result.groups.first?.sends[0].counts)
        XCTAssertEqual(counts, PlanAndLog.Counts(
            booked: expected.counts["booked"] ?? -1, training: expected.counts["training"] ?? -1,
            logged: expected.counts["logged"] ?? -1,
            notLogged: expected.counts["notLogged"] ?? -1, outside: expected.counts["outside"] ?? -1,
            other: expected.counts["other"] ?? -1, meals: expected.counts["meals"] ?? -1))
        XCTAssertEqual(result.groups[0].days.map(\.state.rawValue), expected.dayStates)
        XCTAssertEqual(result.groups[0].sends[0].range, "12–17 Oct")
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
        XCTAssertEqual(result.groups[0].sends[0].counts,
                       PlanAndLog.Counts(booked: 1, training: 1, logged: 1, notLogged: 0,
                                         outside: 0, other: 0, meals: 0))
    }

    func testABookedDayWithNothingLoggedReadsNotLoggedNeverMissed() throws {
        let result = run([("2026-10-12", 0)],
                         [("Lower A", [ex("Back Squat", "Barbell", [[225, 5]])])], [:])
        XCTAssertEqual(try first(result).text, "Mon 12 Oct · Lower A · not logged")
        XCTAssertEqual(result.groups[0].sends[0].head, "Booked 1 day, 12 Oct · logged 0")
    }

    func testABookedDayOutsideTheWindowTheClientSentIsNeverCalledNotLogged() throws {
        let result = run([("2026-10-12", 0)],
                         [("Lower A", [ex("Back Squat", "Barbell", [[225, 5]])])], [:],
                         coverage: CoveredRange(from: "2026-09-01", to: "2026-10-05"))
        XCTAssertEqual(try first(result).text, "Mon 12 Oct · Lower A · outside the log they sent")
        XCTAssertEqual(result.groups[0].sends[0].head, "Booked 1 day, 12 Oct · no log covering them")
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
        XCTAssertEqual(result.groups[0].sends[0].counts.other, 1)
        XCTAssertTrue(result.groups[0].sends[0].head.hasSuffix("1 other day logged"))
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
        XCTAssertEqual(result.groups.flatMap { $0.sends.map(\.id) }, ["new", "old"])
        XCTAssertEqual(result.groups.flatMap { $0.sends.map(\.range) }, ["12 Oct", "5 Oct"])
    }

    func testAPlanBookingNothingInTheLastEightWeeksIsNotAGroupAtAll() {
        let result = run([("2026-05-01", 0)],
                         [("Lower A", [ex("Back Squat", "Barbell", [[225, 5]])])], [:])
        XCTAssertTrue(result.groups.isEmpty)
        XCTAssertTrue(PlanAndLog.lines(result).isEmpty)
    }

    /// `m.x` indexes `r`, exactly as `k.x` indexes `w`. A booking that indexes
    /// nothing is skipped rather than drawn as a dish with no name.
    func testAMealBookedAgainstARecipeThePayloadDoesNotCarryBooksNothing() {
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

    // MARK: - Meals
    //
    // A booked meal is a recipe in a slot on a day. What comes back is a list
    // of food entries -- free text, barcode scans, a recipe logged as a meal
    // -- named out of the client's own food dictionary, with no id joining
    // them to anything, and itemised only if the client chose to itemise.
    //
    // So Coach says what it booked and what the log holds at that slot, and
    // never that the two are the same dish. The tests that matter most here
    // are the negative ones: nothing this card produces may tell a coach their
    // client ate something they did not.

    private static let breakfast = 0, lunch = 1, dinner = 2, snack = 3

    private func recipe(_ name: String) -> PlanRecipe {
        PlanRecipe(n: name, s: 4, u: [400, 30, 40, 12, 6], i: [], t: [])
    }

    private func meal(_ date: String, _ slot: Int, _ index: Int,
                      _ servings: Double = 1) -> PlanMeal {
        PlanMeal(d: date, s: slot, x: index, q: servings)
    }

    private func foodPlan(_ recipes: [PlanRecipe], _ meals: [PlanMeal],
                          _ workouts: [(String, [PlanWorkoutExercise])] = [],
                          _ bookings: [(String, Int)] = []) -> PlanAndLog.StoredPlan {
        PlanAndLog.StoredPlan(
            id: "p1", clientID: "c", sentAtEpochSec: 1000,
            payload: PlanPayload(v: 1, t: "plan", l: "c", n: "", r: recipes, m: meals,
                                 w: workouts.map { PlanWorkout(n: $0.0, e: $0.1) },
                                 k: bookings.map { PlanSession(d: $0.0, x: $0.1) }))
    }

    /// A day's food as the importer stores it: the name the client wrote, and
    /// the slot index they stamped it with -- nil for an entry tied to none.
    private func food(_ name: String, _ slot: Int? = nil) -> PlanAndLog.LoggedFood {
        PlanAndLog.LoggedFood(name: name, slot: slot)
    }

    private func foodDay(_ food: [PlanAndLog.LoggedFood] = [],
                         exercises: [PlanAndLog.Exercise] = [],
                         name: String = "",
                         totals: PlanAndLog.FoodTotals? = nil) -> PlanAndLog.LoggedDay {
        PlanAndLog.LoggedDay(name: name, exercises: exercises, food: food, foodTotals: totals)
    }

    private let totalsOnly = PlanAndLog.FoodTotals(calories: 2100, proteinG: 160, fatG: 70,
                                                   carbsG: 210, fiberG: 28)

    private func runMeals(_ recipes: [PlanRecipe], _ meals: [PlanMeal],
                          _ days: [String: PlanAndLog.LoggedDay],
                          coverage: CoveredRange? = CoveredRange(from: "2026-10-01",
                                                                 to: "2026-10-31")
    ) -> PlanAndLog.Result {
        PlanAndLog.compare(clientID: "c", sentPlans: [foodPlan(recipes, meals)], days: days,
                           coverage: coverage, unit: "lb", today: "2026-10-20", locale: enUS)
    }

    func testAPlanThatBooksMealsAndNoTrainingIsACardNotASkippedGroup() throws {
        let result = runMeals([recipe("Beef Chilli")],
                              [meal("2026-10-12", Self.dinner, 0, 2)], [:])
        XCTAssertEqual(result.groups.count, 1, "the training-only card skipped this entirely")
        XCTAssertEqual(result.groups[0].sends[0].head, "Booked 1 day, 12 Oct · 1 meal booked")
        XCTAssertEqual(try first(result).text, "Mon 12 Oct · 1 meal booked")
        XCTAssertEqual(try first(result).state, .meals)
    }

    /// There is no training booked to be logged or not. Saying "not logged"
    /// against one would be Coach inventing a booking to hold against a client.
    func testAMealsOnlyDayIsNeverCalledNotLogged() {
        let result = runMeals([recipe("Beef Chilli")], [meal("2026-10-12", Self.dinner, 0)], [:])
        let every = PlanAndLog.lines(result).joined(separator: " · ")
        XCTAssertFalse(every.contains("not logged"), every)
        XCTAssertEqual(result.groups[0].sends[0].counts,
                       PlanAndLog.Counts(booked: 1, training: 0, logged: 0, notLogged: 0,
                                         outside: 0, other: 0, meals: 1))
    }

    func testABookedMealNamesTheSlotTheDishAndTheServingsAndNoMacros() throws {
        let result = runMeals([recipe("Beef Chilli")],
                              [meal("2026-10-12", Self.dinner, 0, 2)], [:])
        XCTAssertEqual(try first(result).meals[0].title, "Dinner · Beef Chilli · 2 servings")
        // The recipe's own figures are in the payload and deliberately not on
        // the card: a planned calorie beside a logged one is a coach's target
        // measured against, which is the line this card does not cross.
        let every = PlanAndLog.lines(result).joined(separator: " · ")
        for token in ["400", "30", "kcal", "protein"] {
            XCTAssertFalse(every.contains(token), "\(token) reached the card")
        }
    }

    func testOneServingIsOneServingAndTwoDishesAtOneSlotAreTwoRows() throws {
        let result = runMeals([recipe("Overnight Oats"), recipe("Protein Shake")],
                              [meal("2026-10-12", Self.breakfast, 0),
                               meal("2026-10-12", Self.breakfast, 1, 1)], [:])
        XCTAssertEqual(try first(result).meals.map(\.title), [
            "Breakfast · Overnight Oats · 1 serving",
            "Breakfast · Protein Shake · 1 serving",
        ])
    }

    func testMealsReadInTheOrderADayIsEatenNotTheOrderTheyWereBooked() throws {
        let result = runMeals([recipe("Chilli"), recipe("Oats"), recipe("Bar")],
                              [meal("2026-10-12", Self.snack, 2),
                               meal("2026-10-12", Self.dinner, 0),
                               meal("2026-10-12", Self.breakfast, 1)], [:])
        XCTAssertEqual(try first(result).meals.map(\.slotLabel),
                       ["Breakfast", "Dinner", "Snack"])
    }

    // MARK: - What the log can be asked

    func testAnItemisedSlotSaysWhatTheLogHoldsThereAndNeverThatItIsTheDish() throws {
        let result = runMeals([recipe("Beef Chilli")],
                              [meal("2026-10-12", Self.dinner, 0, 2)],
                              ["2026-10-12": foodDay([food("Porridge", Self.breakfast),
                                                      food("Beef Chilli", Self.dinner),
                                                      food("Greek yoghurt", Self.dinner)])])
        XCTAssertEqual(try first(result).foodContext, "3 foods logged that day")
        XCTAssertEqual(try first(result).meals[0].logged,
                       "Logged at dinner · Beef Chilli · Greek yoghurt")
        // The two facts are printed one above the other. Nothing anywhere
        // claims the logged Beef Chilli is the booked one -- the coach makes
        // that join, from the same two facts Coach has.
        let every = PlanAndLog.lines(result).joined(separator: " · ").lowercased()
        for claim in ["ate", "as booked", "as planned", "matched", "they had"] {
            XCTAssertFalse(every.contains(claim), "\"\(claim)\" claims a match: \(every)")
        }
    }

    func testABookedMealWithNothingAtThatSlotSaysSoAboutTheSlotNotTheClient() throws {
        let result = runMeals([recipe("Chicken & Rice")],
                              [meal("2026-10-12", Self.lunch, 0)],
                              ["2026-10-12": foodDay([food("Porridge", Self.breakfast),
                                                      food("Steak", Self.dinner)])])
        XCTAssertEqual(try first(result).meals[0].logged, "Nothing logged at lunch")
        // And the day's own count sits above it, so "nothing at lunch" cannot
        // be read as "they ate nothing".
        XCTAssertEqual(try first(result).foodContext, "2 foods logged that day")
    }

    func testADayWithMealsBookedAndNoFoodAtAllLoggedSaysExactlyThat() throws {
        let result = runMeals([recipe("Beef Chilli")], [meal("2026-10-12", Self.dinner, 0)],
                              ["2026-10-12": foodDay()])
        XCTAssertEqual(try first(result).foodContext, "No food logged that day")
        XCTAssertNil(try first(result).meals[0].logged, "nothing to say per slot")
    }

    /// SHARE-FORMAT: `ft: [0,0,0,0,0]` is a day opened and nothing logged.
    func testADayOpenedAndLeftEmptyLoggedNoFoodAndIsNotASlotVerdict() throws {
        let result = runMeals([recipe("Beef Chilli")], [meal("2026-10-12", Self.dinner, 0)],
                              ["2026-10-12": foodDay(totals: PlanAndLog.FoodTotals(
                                  calories: 0, proteinG: 0, fatG: 0, carbsG: 0, fiberG: 0))])
        XCTAssertEqual(try first(result).foodContext, "No food logged that day")
        XCTAssertNil(try first(result).meals[0].logged)
    }

    /// Itemisation is a choice the client makes per send. Calling a booked
    /// dinner "nothing logged at dinner" here would contradict that choice
    /// with a fact Coach does not have.
    func testAClientWhoSentTotalsAndNotItemsGetsNoSlotVerdictAtAll() throws {
        let result = runMeals([recipe("Beef Chilli")], [meal("2026-10-12", Self.dinner, 0)],
                              ["2026-10-12": foodDay(totals: totalsOnly)])
        XCTAssertEqual(try first(result).foodContext, "Food logged that day, not itemised")
        XCTAssertNil(try first(result).meals[0].logged)
        XCTAssertFalse(PlanAndLog.lines(result).joined(separator: " ").contains("Nothing logged"))
    }

    func testFoodsTiedToNoMealAreCountedSoAQuietSlotIsNotAVerdict() throws {
        let result = runMeals([recipe("Chicken & Rice")], [meal("2026-10-12", Self.lunch, 0)],
                              ["2026-10-12": foodDay([food("Flapjack"), food("Coffee"),
                                                      food("Steak", Self.dinner)])])
        XCTAssertEqual(try first(result).foodContext,
                       "3 foods logged that day · 2 not tied to a meal")
        XCTAssertEqual(try first(result).meals[0].logged, "Nothing logged at lunch")
    }

    func testABookedMealOutsideTheLogTheClientSentIsNeverASlotVerdict() throws {
        let result = runMeals([recipe("Beef Chilli")], [meal("2026-10-12", Self.dinner, 0)], [:],
                              coverage: CoveredRange(from: "2026-09-01", to: "2026-10-05"))
        XCTAssertEqual(try first(result).text,
                       "Mon 12 Oct · 1 meal booked · outside the log they sent")
        XCTAssertNil(try first(result).meals[0].logged)
        XCTAssertNil(try first(result).foodContext)
        XCTAssertEqual(result.groups[0].sends[0].head,
                       "Booked 1 day, 12 Oct · 1 meal booked · no log covering them")
    }

    func testAClientWhoseLogPredatesTheSendGetsNoVerdictOnAnyMealOfIt() {
        let result = runMeals([recipe("Beef Chilli"), recipe("Oats")],
                              [meal("2026-10-12", Self.dinner, 0),
                               meal("2026-10-13", Self.breakfast, 1)], [:],
                              coverage: CoveredRange(from: "2026-08-01", to: "2026-09-30"))
        XCTAssertEqual(result.groups[0].days.map(\.text), [
            "Mon 12 Oct · 1 meal booked · outside the log they sent",
            "Tue 13 Oct · 1 meal booked · outside the log they sent",
        ])
        let every = PlanAndLog.lines(result).joined(separator: " · ")
        XCTAssertFalse(every.contains("Nothing logged"))
        XCTAssertFalse(every.contains("not logged"))
    }

    /// The line discipline is about Coach's sentences, not about the client's
    /// data: "2% milk" is what they logged and what Coach prints. Never
    /// rewritten, never trimmed to fit a rule about the app's own words.
    func testAClientsOwnFoodNameIsPrintedAsTheyWroteItPercentSignAndAll() throws {
        let result = runMeals([recipe("Porridge")], [meal("2026-10-12", Self.breakfast, 0)],
                              ["2026-10-12": foodDay([food("2% milk", Self.breakfast)])])
        XCTAssertEqual(try first(result).meals[0].logged, "Logged at breakfast · 2% milk")
    }

    // MARK: - Meals beside training

    func testADayThatBooksBothSaysTheTrainingVerdictAndTheMealCount() {
        let result = PlanAndLog.compare(
            clientID: "c",
            sentPlans: [foodPlan([recipe("Beef Chilli"), recipe("Oats")],
                                 [meal("2026-10-12", Self.dinner, 0, 2),
                                  meal("2026-10-13", Self.breakfast, 1),
                                  meal("2026-10-13", Self.dinner, 0)],
                                 [("Lower A", [ex("Back Squat", "Barbell", [[225, 5]])])],
                                 [("2026-10-12", 0)])],
            days: ["2026-10-12": foodDay([food("Beef Chilli", Self.dinner)],
                                         exercises: [logged("Back Squat", "Barbell", [set(225, 5)])],
                                         name: "Lower A")],
            coverage: CoveredRange(from: "2026-10-01", to: "2026-10-31"),
            unit: "lb", today: "2026-10-20", locale: enUS)
        XCTAssertEqual(result.groups[0].days.map(\.text), [
            "Mon 12 Oct · Lower A · logged · 1 meal booked",
            "Tue 13 Oct · 2 meals booked",
        ])
        // "logged 2" under "Booked 5 days" would read as two of five when
        // three of them booked no training at all, so the figure names what it
        // counts.
        XCTAssertEqual(result.groups[0].sends[0].head,
                       "Booked 2 days, 12–13 Oct · 3 meals booked · 1 training day, 1 logged")
        XCTAssertEqual(result.groups[0].sends[0].counts,
                       PlanAndLog.Counts(booked: 2, training: 1, logged: 1, notLogged: 0,
                                         outside: 0, other: 0, meals: 3))
    }

    func testATrainingOnlySendReadsExactlyAsItDidBeforeMealsExisted() throws {
        let result = run([("2026-10-12", 0)],
                         [("Lower A", [ex("Back Squat", "Barbell", [[225, 5]])])],
                         ["2026-10-12": day([logged("Back Squat", "Barbell", [set(225, 5)])],
                                            name: "Lower A")])
        XCTAssertEqual(result.groups[0].sends[0].head, "Booked 1 day, 12 Oct · logged 1")
        XCTAssertTrue(try first(result).meals.isEmpty)
        XCTAssertNil(try first(result).foodContext)
        XCTAssertNil(result.mealFooter, "and no note about meals under a card with none")
    }

    /// `not booked` exists so a session lifted the day after the one it was
    /// booked for sits beside that booking. A send with no training booked
    /// none for it to sit beside, and listing a client's own sessions under a
    /// meal plan would be Coach holding up work nobody set out to book.
    func testAFoodPlanDoesNotHoldUpTheTrainingTheCoachNeverBooked() {
        let result = runMeals([recipe("Beef Chilli")],
                              [meal("2026-10-12", Self.dinner, 0),
                               meal("2026-10-14", Self.dinner, 0)],
                              ["2026-10-13": foodDay(
                                  exercises: [logged("Kettlebell Swing", "Kettlebell",
                                                     [set(53, 20)])],
                                  name: "Conditioning")])
        XCTAssertEqual(result.groups[0].days.map(\.text), [
            "Mon 12 Oct · 1 meal booked",
            "Wed 14 Oct · 1 meal booked",
        ])
        XCTAssertEqual(result.groups[0].sends[0].counts.other, 0)
        XCTAssertFalse(PlanAndLog.lines(result).joined(separator: " ").contains("not booked"))
    }

    func testASendThatBooksBothStillShowsASessionItDidNotBook() {
        let result = PlanAndLog.compare(
            clientID: "c",
            sentPlans: [foodPlan([recipe("Beef Chilli")], [meal("2026-10-12", Self.dinner, 0)],
                                 [("Lower A", [ex("Back Squat", "Barbell", [[225, 5]])])],
                                 [("2026-10-12", 0), ("2026-10-14", 0)])],
            days: ["2026-10-13": foodDay(
                exercises: [logged("Kettlebell Swing", "Kettlebell", [set(53, 20)])],
                name: "Conditioning")],
            coverage: CoveredRange(from: "2026-10-01", to: "2026-10-31"),
            unit: "lb", today: "2026-10-20", locale: enUS)
        XCTAssertEqual(result.groups[0].days[1].text, "Tue 13 Oct · Conditioning · not booked")
        XCTAssertEqual(result.groups[0].sends[0].counts.other, 1)
    }

    func testByLiftStaysAboutLiftsAMealsOnlyPlanHasNone() {
        let result = runMeals([recipe("Beef Chilli")], [meal("2026-10-12", Self.dinner, 0)], [:])
        XCTAssertTrue(result.byLift.isEmpty)
        XCTAssertFalse(PlanAndLog.lines(result).contains("By lift"))
    }

    // MARK: - A plan with nothing booked into a day

    func testALibrarySendRecipesWithNothingBookedIsNotACard() {
        let result = runMeals([recipe("Beef Chilli"), recipe("Oats")], [], [:])
        XCTAssertTrue(result.groups.isEmpty)
        XCTAssertTrue(PlanAndLog.lines(result).isEmpty)
    }

    /// Road picks ride in Cook's plan link and book no day. A picks-only send
    /// is still nothing to show.
    func testAPicksOnlyPlanIsStillNothingToShow() {
        let payload = PlanPayload(v: 1, t: "plan", l: "c", n: "", r: nil, m: nil, w: nil, k: nil)
        let result = PlanAndLog.compare(
            clientID: "c",
            sentPlans: [PlanAndLog.StoredPlan(id: "p", clientID: "c", sentAtEpochSec: 1,
                                              payload: payload)],
            days: ["2026-10-12": foodDay([food("Wendy’s chilli", Self.lunch)])],
            coverage: CoveredRange(from: "2026-10-01", to: "2026-10-31"),
            unit: "lb", today: "2026-10-20", locale: enUS)
        XCTAssertTrue(result.groups.isEmpty)
        XCTAssertNil(result.mealFooter)
    }

    func testTheNoteAboutWhatAMealRowDoesNotClaimIsShownOnceUnderACardThatHasOne() {
        let result = runMeals([recipe("Beef Chilli")], [meal("2026-10-12", Self.dinner, 0)],
                              ["2026-10-12": foodDay([food("Beef Chilli", Self.dinner)])])
        XCTAssertEqual(result.mealFooter, PlanAndLog.mealNote)
        let out = PlanAndLog.lines(result)
        XCTAssertEqual(out.filter { $0 == PlanAndLog.mealNote }.count, 1)
        XCTAssertEqual(out[out.count - 2], PlanAndLog.mealNote, "above the permanent footer")
        XCTAssertEqual(out[out.count - 1], PlanAndLog.footer)
    }

    // MARK: - How this store answers "which meal was that food?"

    /// `ClientFoodEntry.meal` is the wire's slot index and is not optional, so
    /// "tied to no meal" is an index outside the four slots -- what Coach web
    /// reads as the empty string. A future writer's fifth slot lands there
    /// too, counted rather than printed under a name Coach invented for it.
    func testTheStoreSMealIndexBecomesASlotOrNothing() {
        let entry = { (meal: Int) in
            ClientFoodEntry(foodName: "Porridge", servings: 1, calories: 1, proteinG: 1,
                            fatG: 1, carbsG: 1, fiberG: 1, meal: meal)
        }
        XCTAssertEqual(PlanAndLog.loggedFood(entry(0)).slot, 0)
        XCTAssertEqual(PlanAndLog.loggedFood(entry(3)).slot, 3)
        XCTAssertNil(PlanAndLog.loggedFood(entry(4)).slot, "a slot Coach has no word for")
        XCTAssertNil(PlanAndLog.loggedFood(entry(-1)).slot)
    }

    /// A real store's day, read back the way the card reads one: the three
    /// food states come off `foodEntries` and the day's own totals, and
    /// nothing else.
    func testAStoredDaysFoodReachesTheCardWithItsSlots() throws {
        let context = ModelContext(try ModelContainer(
            for: Schema(CoachSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        let client = Client(id: "c", name: "Sam", displayUnit: "lb", platform: "ios")
        context.insert(client)

        func storedDay(_ key: String, foods: [(String, Int)],
                       calories: Double?) throws -> TrainingDay {
            let day = TrainingDay(client: client, dayKey: key)
            day.foodCalories = calories
            context.insert(day)
            client.trainingDays.append(day)
            for (name, meal) in foods {
                let entry = ClientFoodEntry(day: day, foodName: name, servings: 1, calories: 400,
                                            proteinG: 30, fatG: 12, carbsG: 40, fiberG: 6,
                                            meal: meal)
                context.insert(entry)
                day.foodEntries.append(entry)
            }
            return day
        }

        let itemised = try storedDay("2026-10-12",
                                     foods: [("Beef Chilli", Self.dinner), ("Flapjack", 7)],
                                     calories: 2100)
        let totals = try storedDay("2026-10-13", foods: [], calories: 2100)
        let empty = try storedDay("2026-10-14", foods: [], calories: 0)
        try context.save()

        let read = PlanAndLog.loggedDay(itemised)
        XCTAssertEqual(Set(read.food.map(\.name)), ["Beef Chilli", "Flapjack"])
        XCTAssertEqual(PlanAndLog.foodIn(read).state, .items)
        // A slot Coach has no word for is counted, never printed under one it
        // made up.
        XCTAssertEqual(PlanAndLog.foodContext(PlanAndLog.foodIn(read)),
                       "2 foods logged that day · 1 not tied to a meal")
        XCTAssertEqual(PlanAndLog.foodIn(PlanAndLog.loggedDay(totals)).state, .totals)
        XCTAssertEqual(PlanAndLog.foodIn(PlanAndLog.loggedDay(empty)).state, .none,
                       "a day opened and left empty logged no food")
    }

    // MARK: - The line discipline

    /// The spirit of `PerLimbTests.testNothingInTheseLinesTellsACoachWhatToDo`
    /// and its Coach web twin: the card counts, and never grades.
    private let forbidden = ["should", "fix", "warning", "target", "too ", "concern",
                             "missed", "skipped", "failed", "poor", "behind", "compliance",
                             "adherence", "streak", "%"]

    /// Every meal state the card has, in one send: a slot the log holds
    /// something at, a slot it holds nothing at, a day with no food at all, a
    /// day whose client sent totals and not items, a day outside the window
    /// they sent, an entry tied to no meal, and a meal day beside a training
    /// one.
    ///
    /// The food names here are plain on purpose. A client's own "2% milk" is
    /// printed as they wrote it and would fail the list above -- the
    /// discipline is about the sentences Coach writes, not about the client's
    /// data, and `testAClientsOwnFoodNameIsPrintedAsTheyWroteItPercentSignAndAll`
    /// pins the passthrough.
    private func mealFixture() -> PlanAndLog.Result {
        PlanAndLog.compare(
            clientID: "c",
            sentPlans: [foodPlan(
                [recipe("Beef Chilli"), recipe("Overnight Oats"), recipe("Chicken & Rice")],
                [meal("2026-10-12", Self.dinner, 0, 2), meal("2026-10-12", Self.breakfast, 1),
                 meal("2026-10-13", Self.lunch, 2), meal("2026-10-14", Self.dinner, 0),
                 meal("2026-10-15", Self.lunch, 2), meal("2026-10-19", Self.dinner, 0)],
                [("Lower A", [ex("Back Squat", "Barbell", [[225, 5]])])],
                [("2026-10-12", 0)])],
            days: [
                "2026-10-12": foodDay([food("Beef Chilli", Self.dinner),
                                       food("Greek yoghurt", Self.dinner),
                                       food("Porridge", Self.breakfast)],
                                      exercises: [logged("Back Squat", "Barbell", [set(225, 5)])],
                                      name: "Lower A"),
                "2026-10-13": foodDay([food("Steak", Self.dinner), food("Flapjack")]),
                "2026-10-14": foodDay(),
                "2026-10-15": foodDay(totals: totalsOnly),
            ],
            coverage: CoveredRange(from: "2026-10-01", to: "2026-10-16"),
            unit: "lb", today: "2026-10-20", locale: enUS)
    }

    func testNothingInThisCardTellsACoachWhatToDo() throws {
        // Every state the card has: a logged day, a day with nothing logged, a
        // day outside the window the client sent, a day logged and not booked;
        // and a matched lift, a substituted one, one short on a side, one short
        // on sets, one not logged at all and one nobody asked for.
        let (result, _) = try fixtureResult()
        let training = PlanAndLog.lines(result)
        let meals = PlanAndLog.lines(mealFixture())
        XCTAssertGreaterThan(meals.count, 15, "the meal fixture should exercise every meal state")
        let every = (training + meals).joined(separator: " · ").lowercased()
        XCTAssertGreaterThan(every.count, 200, "the fixture should exercise the whole card")
        for word in forbidden {
            XCTAssertFalse(every.contains(word), "\"\(word)\" reached a screen")
        }
        XCTAssertFalse(PlanAndLog.footer.lowercased().contains("adherence"))
        XCTAssertFalse(PlanAndLog.mealNote.lowercased().contains("adherence"))
    }

    /// The whole reason the booked and the logged sides of a meal are two
    /// separate statements. Coach can see a dish it booked and a list of foods
    /// stamped with a slot; it cannot see that they are the same dinner, and a
    /// wrong claim here tells a coach their client ate something they did not.
    func testNoMealSentenceClaimsAClientAteAnything() {
        let every = PlanAndLog.lines(mealFixture()).joined(separator: " · ").lowercased()
        for claim in ["ate", "eaten", "as booked", "as planned", "matched", "they had",
                      "on plan", "off plan", "followed", "complied"] {
            XCTAssertFalse(every.contains(claim), "\"\(claim)\" claims a meal was eaten: \(every)")
        }
        // And the one sentence that says what the rows do not claim is there.
        XCTAssertTrue(every.contains(PlanAndLog.mealNote.lowercased()))
    }

    func testNothingHereAggregatesAClientIntoAScore() throws {
        let (result, _) = try fixtureResult()

        // Counts hang off a day or a group of days, and there is nothing at
        // the top of the result to aggregate: no roster figure, no all-time
        // total, no trend across weeks.
        XCTAssertEqual(Mirror(reflecting: result).children.compactMap(\.label).sorted(),
                       ["byLift", "footer", "groups", "mealFooter"])
        XCTAssertEqual(Mirror(reflecting: result.groups[0].sends[0].counts).children
            .compactMap(\.label).sorted(),
                       ["booked", "logged", "meals", "notLogged", "other", "outside", "training"],
                       "a group counts the days and the meals it booked, and nothing else")

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

        // Meals are counted the same way and scored no more than training is:
        // a number of meals booked, and no figure beside it claiming how many
        // of them were eaten, because there is no such figure.
        let meals = mealFixture()
        XCTAssertEqual(Mirror(reflecting: meals).children.compactMap(\.label).sorted(),
                       ["byLift", "footer", "groups", "mealFooter"])
        XCTAssertEqual(meals.groups[0].sends[0].counts.meals, 6)
        walk(meals, "meals")
    }

}
