import XCTest
import SwiftData
import LiftCore
@testable import Coach

final class ShareLinkImporterTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Client.self, Goal.self, TrainingDay.self, ExerciseSet.self, ClientFoodEntry.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    private func payload(clientID: String = "b7f3a1c8", r: String = "2026-09-01",
                          days: [WireDay]) -> ShareLinkPayload {
        ShareLinkPayload(
            v: 1,
            c: WireClient(i: clientID, n: "Jordan Reyes", s: nil, a: nil, h: nil, u: "lb", p: "ios"),
            g: nil, r: r, t: "2026-09-10", z: 1, x: ["Back Squat|Barbell"], fd: nil, d: days
        )
    }

    func testCreatesNewClientOnFirstImport() throws {
        let context = try makeContext()
        try ShareLinkImporter.importPayload(payload(days: []), into: context)

        let clients = try context.fetch(FetchDescriptor<Client>())
        XCTAssertEqual(clients.count, 1)
        XCTAssertEqual(clients.first?.id, "b7f3a1c8")
        XCTAssertEqual(clients.first?.name, "Jordan Reyes")
    }

    func testSecondImportReusesExistingClientRatherThanDuplicating() throws {
        let context = try makeContext()
        try ShareLinkImporter.importPayload(payload(days: []), into: context)
        try ShareLinkImporter.importPayload(payload(days: []), into: context)

        let clients = try context.fetch(FetchDescriptor<Client>())
        XCTAssertEqual(clients.count, 1)
    }

    func testDayOffsetResolvesToRealDateFromR() throws {
        let context = try makeContext()
        let day = WireDay(k: 3, n: "Push Day", fo: "POWERLIFTING", bw: nil, st: nil, w: nil, ft: nil, f: nil)
        try ShareLinkImporter.importPayload(payload(r: "2026-09-01", days: [day]), into: context)

        let days = try context.fetch(FetchDescriptor<TrainingDay>())
        XCTAssertEqual(days.first?.dayKey, "2026-09-04")   // 2026-09-01 + 3 days
        XCTAssertEqual(days.first?.sessionName, "Push Day")
    }

    func testWorkoutSetsResolveExerciseNameFromDictionary() throws {
        let context = try makeContext()
        let entry = WireWorkoutEntry(exerciseIndex: 0, sets: [[185, 5, 8]])
        let day = WireDay(k: 0, n: nil, fo: nil, bw: nil, st: nil, w: [entry], ft: nil, f: nil)
        try ShareLinkImporter.importPayload(payload(days: [day]), into: context)

        let sets = try context.fetch(FetchDescriptor<ExerciseSet>())
        XCTAssertEqual(sets.count, 1)
        XCTAssertEqual(sets.first?.exerciseName, "Back Squat")
        XCTAssertEqual(sets.first?.equipment, "Barbell")
        XCTAssertEqual(sets.first?.weightLb, 185)
        XCTAssertEqual(sets.first?.reps, 5)
        XCTAssertEqual(sets.first?.rpe, 8)
        XCTAssertFalse(sets.first!.isWarmup)
    }

    func testShortSetTupleLeavesTrailingFieldsNil() throws {
        let context = try makeContext()
        // A 1-element tuple: only weight recorded, everything else implicitly absent.
        let entry = WireWorkoutEntry(exerciseIndex: 0, sets: [[135]])
        let day = WireDay(k: 0, n: nil, fo: nil, bw: nil, st: nil, w: [entry], ft: nil, f: nil)
        try ShareLinkImporter.importPayload(payload(days: [day]), into: context)

        let set = try XCTUnwrap(try context.fetch(FetchDescriptor<ExerciseSet>()).first)
        XCTAssertEqual(set.weightLb, 135)
        XCTAssertNil(set.reps)
        XCTAssertNil(set.rpe)
        XCTAssertFalse(set.isWarmup)
    }

    /// servings: 1 here means the multiplication is a numeric no-op
    /// (201 * 1 == 201) -- this test only locks in that a servings value
    /// of 1 doesn't change behavior, not that multiplication never
    /// happens (see testItemizedFoodMacrosAreMultipliedByServings for
    /// the servings > 1 case, which is where the earlier "never
    /// multiply" ruling was actually wrong).
    func testItemizedFoodWithServingsOfOneIsUnaffectedByMultiplication() throws {
        let context = try makeContext()
        // [foodIndex, servings(=1), kcal, protein, fat, carbs, fiber, meal]
        let day = WireDay(k: 0, n: nil, fo: nil, bw: nil, st: nil, w: nil, ft: nil,
                           f: [[0, 1, 201, 22, 4, 0, 0, 1]])
        var withFoodDict = payload(days: [day])
        withFoodDict = ShareLinkPayload(v: withFoodDict.v, c: withFoodDict.c, g: withFoodDict.g,
                                        r: withFoodDict.r, t: withFoodDict.t, z: withFoodDict.z,
                                        x: withFoodDict.x, fd: ["Chicken breast"], d: withFoodDict.d)
        try ShareLinkImporter.importPayload(withFoodDict, into: context)

        let food = try XCTUnwrap(try context.fetch(FetchDescriptor<ClientFoodEntry>()).first)
        XCTAssertEqual(food.foodName, "Chicken breast")
        XCTAssertEqual(food.calories, 201)   // 201 * 1 == 201
        XCTAssertEqual(food.meal, 1)
    }

    func testReimportingSameDayReplacesItEntirely() throws {
        let context = try makeContext()
        let firstDay = WireDay(k: 0, n: "Original", fo: nil, bw: 200, st: nil, w: nil, ft: nil, f: nil)
        try ShareLinkImporter.importPayload(payload(days: [firstDay]), into: context)

        let secondDay = WireDay(k: 0, n: "Replaced", fo: nil, bw: 198, st: nil, w: nil, ft: nil, f: nil)
        try ShareLinkImporter.importPayload(payload(days: [secondDay]), into: context)

        let days = try context.fetch(FetchDescriptor<TrainingDay>())
        XCTAssertEqual(days.count, 1)   // not 2 — replaced, not appended
        XCTAssertEqual(days.first?.sessionName, "Replaced")
        XCTAssertEqual(days.first?.bodyweightLb, 198)
    }

    func testDayOutsideNewPayloadWindowIsUntouched() throws {
        let context = try makeContext()
        let day1 = WireDay(k: 0, n: "Day 1", fo: nil, bw: nil, st: nil, w: nil, ft: nil, f: nil)
        try ShareLinkImporter.importPayload(payload(r: "2026-09-01", days: [day1]), into: context)

        // A later import whose window doesn't include 2026-09-01 at all.
        let day2 = WireDay(k: 0, n: "Day 2", fo: nil, bw: nil, st: nil, w: nil, ft: nil, f: nil)
        try ShareLinkImporter.importPayload(payload(r: "2026-09-05", days: [day2]), into: context)

        let days = try context.fetch(FetchDescriptor<TrainingDay>())
        XCTAssertEqual(days.count, 2)
        XCTAssertTrue(days.contains { $0.sessionName == "Day 1" })
        XCTAssertTrue(days.contains { $0.sessionName == "Day 2" })
    }

    func testGoalIsImportedWhenPresent() throws {
        let context = try makeContext()
        var withGoal = payload(days: [])
        withGoal = ShareLinkPayload(v: withGoal.v, c: withGoal.c,
                                    g: WireGoal(c: 2400, p: 190, f: 70, cb: 220, fb: 34),
                                    r: withGoal.r, t: withGoal.t, z: withGoal.z, x: withGoal.x,
                                    fd: withGoal.fd, d: withGoal.d)
        try ShareLinkImporter.importPayload(withGoal, into: context)

        let clients = try context.fetch(FetchDescriptor<Client>())
        XCTAssertEqual(clients.first?.goal?.calories, 2400)
        XCTAssertEqual(clients.first?.goal?.proteinG, 190)
    }

    /// `CoachShare.swift` (the real encoder) always emits `servings: 1` and
    /// puts as-eaten totals directly in the macro slots — every other test
    /// fixture in this file also uses `servings: 1`, which would silently
    /// pass even if the importer wrongly multiplied macros by `servings`.
    /// This uses `servings: 2` specifically to catch that mutant.
    /// Android's real encoder sends true per-serving macros plus a real
    /// servings count (unlike iOS, which always sends servings=1 with
    /// already-multiplied totals) -- the importer must multiply to read
    /// an Android-sourced payload correctly. servings: 2 here specifically
    /// distinguishes "multiplies correctly" from "coincidentally correct
    /// because servings was 1."
    func testItemizedFoodMacrosAreMultipliedByServings() throws {
        let context = try makeContext()
        let day = WireDay(k: 0, n: nil, fo: nil, bw: nil, st: nil, w: nil, ft: nil,
                           f: [[0, 2, 201, 22, 4, 0, 0, 1]])
        var withFoodDict = payload(days: [day])
        withFoodDict = ShareLinkPayload(v: withFoodDict.v, c: withFoodDict.c, g: withFoodDict.g,
                                        r: withFoodDict.r, t: withFoodDict.t, z: withFoodDict.z,
                                        x: withFoodDict.x, fd: ["Chicken breast"], d: withFoodDict.d)
        try ShareLinkImporter.importPayload(withFoodDict, into: context)

        let food = try XCTUnwrap(try context.fetch(FetchDescriptor<ClientFoodEntry>()).first)
        XCTAssertEqual(food.servings, 2)
        XCTAssertEqual(food.calories, 402)   // 201 * 2, NOT 201
    }

    /// A malformed or adversarial pasted link could carry a negative index —
    /// this must be dropped like any other out-of-range index, not crash.
    func testNegativeExerciseIndexIsDroppedRatherThanCrashing() throws {
        let context = try makeContext()
        let entry = WireWorkoutEntry(exerciseIndex: -1, sets: [[185, 5, 8]])
        let day = WireDay(k: 0, n: nil, fo: nil, bw: nil, st: nil, w: [entry], ft: nil, f: nil)
        try ShareLinkImporter.importPayload(payload(days: [day]), into: context)

        let sets = try context.fetch(FetchDescriptor<ExerciseSet>())
        XCTAssertTrue(sets.isEmpty)
    }

    func testNegativeFoodIndexIsDroppedRatherThanCrashing() throws {
        let context = try makeContext()
        let day = WireDay(k: 0, n: nil, fo: nil, bw: nil, st: nil, w: nil, ft: nil,
                           f: [[-1, 1, 201, 22, 4, 0, 0, 1]])
        var withFoodDict = payload(days: [day])
        withFoodDict = ShareLinkPayload(v: withFoodDict.v, c: withFoodDict.c, g: withFoodDict.g,
                                        r: withFoodDict.r, t: withFoodDict.t, z: withFoodDict.z,
                                        x: withFoodDict.x, fd: ["Chicken breast"], d: withFoodDict.d)
        try ShareLinkImporter.importPayload(withFoodDict, into: context)

        let foods = try context.fetch(FetchDescriptor<ClientFoodEntry>())
        XCTAssertTrue(foods.isEmpty)
    }

    // MARK: - An older link cannot undo a newer one

    private func sent(z: Int, name: String, unit: String = "lb", calories: Int,
                      days: [WireDay] = []) -> ShareLinkPayload {
        ShareLinkPayload(
            v: 1,
            c: WireClient(i: "b7f3a1c8", n: name, s: nil, a: nil, h: nil, u: unit, p: "ios"),
            g: WireGoal(c: calories, p: 180, f: 70, cb: 250, fb: 30),
            r: "2026-09-01", t: "2026-09-10", z: z, x: ["Back Squat|Barbell"], fd: nil, d: days
        )
    }

    func testAnOlderLinkPastedLateKeepsTheNewerGoalAndProfile() throws {
        let context = try makeContext()
        try ShareLinkImporter.importPayload(sent(z: 2_000, name: "Jordan R.", unit: "kg", calories: 2_600), into: context)
        try ShareLinkImporter.importPayload(sent(z: 1_000, name: "Jordan Reyes", unit: "lb", calories: 2_200), into: context)

        let client = try XCTUnwrap(context.fetch(FetchDescriptor<Client>()).first)
        XCTAssertEqual(client.goal?.calories, 2_600, "a goal changed last week is not undone by an older link")
        XCTAssertEqual(client.name, "Jordan R.")
        XCTAssertEqual(client.displayUnit, "kg")
    }

    func testAnOlderLinkStillDeliversItsDays() throws {
        // Days are the truth for the window a link covers, whenever it arrives.
        let context = try makeContext()
        try ShareLinkImporter.importPayload(sent(z: 2_000, name: "Jordan", calories: 2_600), into: context)
        let day = WireDay(k: 0, n: "Pull Day", fo: nil, bw: nil, st: nil, w: nil, ft: nil, f: nil)
        try ShareLinkImporter.importPayload(sent(z: 1_000, name: "Jordan", calories: 2_200, days: [day]), into: context)

        let days = try context.fetch(FetchDescriptor<TrainingDay>())
        XCTAssertEqual(days.map(\.sessionName), ["Pull Day"])
    }

    func testANewerOrEqualLinkUpdatesGoalAndProfile() throws {
        let context = try makeContext()
        try ShareLinkImporter.importPayload(sent(z: 1_000, name: "Jordan Reyes", calories: 2_200), into: context)
        try ShareLinkImporter.importPayload(sent(z: 1_000, name: "Jordan R.", unit: "kg", calories: 2_400), into: context)
        try ShareLinkImporter.importPayload(sent(z: 3_000, name: "Jordan", calories: 2_500), into: context)

        let client = try XCTUnwrap(context.fetch(FetchDescriptor<Client>()).first)
        XCTAssertEqual(client.goal?.calories, 2_500)
        XCTAssertEqual(client.name, "Jordan")
        XCTAssertEqual(client.displayUnit, "lb")
    }

    func testAClientImportedBeforeLinksWereStampedTakesTheNextLink() throws {
        let context = try makeContext()
        try ShareLinkImporter.importPayload(sent(z: 5_000, name: "Old Name", calories: 2_000), into: context)
        let client = try XCTUnwrap(context.fetch(FetchDescriptor<Client>()).first)
        client.exportedAtEpochSec = nil   // as a store written before the stamp existed
        try ShareLinkImporter.importPayload(sent(z: 1, name: "New Name", calories: 2_300), into: context)
        XCTAssertEqual(client.name, "New Name")
        XCTAssertEqual(client.goal?.calories, 2_300)
    }

    // MARK: - The order a day was logged in, and the window a client sent

    /// The wire's sets arrive in log order and used to be dropped into an
    /// unordered to-many, so Coach could not say which logged set was the
    /// third. One running index across the day keeps the exercises in order
    /// too.
    func testTheImporterKeepsTheOrderTheWireSentSetsIn() throws {
        let context = try makeContext()
        let squats = WireWorkoutEntry(exerciseIndex: 0, sets: [[225, 5], [225, 5], [245, 3]])
        let press = WireWorkoutEntry(exerciseIndex: 1, sets: [[95, 8]])
        let day = WireDay(k: 0, n: nil, fo: nil, bw: nil, st: nil, w: [squats, press],
                          ft: nil, f: nil)
        var wire = payload(days: [day])
        wire = ShareLinkPayload(v: wire.v, c: wire.c, g: wire.g, r: wire.r, t: wire.t, z: wire.z,
                                x: ["Back Squat|Barbell", "Overhead Press|Barbell"], fd: wire.fd,
                                d: wire.d)
        try ShareLinkImporter.importPayload(wire, into: context)

        let sets = try context.fetch(FetchDescriptor<ExerciseSet>())
            .sorted { ($0.orderIndex ?? .max) < ($1.orderIndex ?? .max) }
        XCTAssertEqual(sets.map(\.orderIndex), [0, 1, 2, 3])
        XCTAssertEqual(sets.map(\.weightLb), [225, 225, 245, 95])
    }

    /// A day replaced by a later link is renumbered from scratch, as the
    /// whole day is replaced.
    func testReplacingADayRenumbersItsSets() throws {
        let context = try makeContext()
        let first = WireWorkoutEntry(exerciseIndex: 0, sets: [[225, 5], [225, 5]])
        try ShareLinkImporter.importPayload(payload(days: [
            WireDay(k: 0, n: nil, fo: nil, bw: nil, st: nil, w: [first], ft: nil, f: nil)]),
                                            into: context)
        let again = WireWorkoutEntry(exerciseIndex: 0, sets: [[245, 3]])
        try ShareLinkImporter.importPayload(payload(days: [
            WireDay(k: 0, n: nil, fo: nil, bw: nil, st: nil, w: [again], ft: nil, f: nil)]),
                                            into: context)
        let sets = try context.fetch(FetchDescriptor<ExerciseSet>())
        XCTAssertEqual(sets.map(\.orderIndex), [0])
        XCTAssertEqual(sets.map(\.weightLb), [245])
    }

    /// `r`..`t` is what the client chose to send, and it is the union across
    /// links -- so a booked day with no `TrainingDay` can be told from a day
    /// outside the window at all.
    func testTheCoveredWindowIsTheUnionOfEveryLink() throws {
        let context = try makeContext()
        try ShareLinkImporter.importPayload(payload(r: "2026-09-01", days: []), into: context)
        let client = try XCTUnwrap(context.fetch(FetchDescriptor<Client>()).first)
        XCTAssertEqual(client.covered, CoveredRange(from: "2026-09-01", to: "2026-09-10"))

        // An older link pasted late widens the window backwards; it never
        // narrows it, and it is not gated on the newest-send rule.
        try ShareLinkImporter.importPayload(payload(r: "2026-08-01", days: []), into: context)
        XCTAssertEqual(client.covered, CoveredRange(from: "2026-08-01", to: "2026-09-10"))
    }

    /// A client imported before Coach recorded a window has none, which is
    /// "we do not know" -- never "they logged nothing".
    func testAClientWithNoWindowRecordedHasNone() throws {
        let context = try makeContext()
        try ShareLinkImporter.importPayload(payload(days: []), into: context)
        let client = try XCTUnwrap(context.fetch(FetchDescriptor<Client>()).first)
        client.coveredFrom = nil
        client.coveredTo = nil
        XCTAssertNil(client.covered)
    }
}
