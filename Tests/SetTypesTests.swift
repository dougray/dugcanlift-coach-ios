import XCTest
import SwiftData
import LiftCore
@testable import Coach

/// Set types (PLAN-FORMAT.md "Set types"): `g` on an exercise in a superset or
/// circuit, and a set's kind -- drop, rest-pause -- in flags bits 3-4. The
/// rules are Coach web's `prescriptions.js`; these are its
/// `set-types.test.mjs`, ported case for case where the two apps share a
/// behaviour, in the shape `PerSidePrescriptionTests` already has.
final class SetTypesTests: XCTestCase {

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema(CoachSchema.models),
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    /// Kept per label so two calls inside one test hand back the *same* suite.
    private var suites: [String: UserDefaults] = [:]

    /// A fresh, isolated `UserDefaults` suite -- never `.standard`, which in a
    /// test hosted by the Coach app is the *installed app's* own preference
    /// domain. No `BackupCodec` or `importLibrary` call in a test may take the
    /// defaulted `defaults:`.
    private func isolatedDefaults(_ label: String = #function) -> UserDefaults {
        let name = "SetTypesTests." + label.replacingOccurrences(of: "()", with: "")
        if let existing = suites[name] { return existing }
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        addTeardownBlock { suite.removePersistentDomain(forName: name) }
        suites[name] = suite
        return suite
    }

    private static let lifterID = "a1b2c3d4"

    private func decode(_ fragment: String) throws -> PlanPayload {
        try PlanLinkCodec.decode(fragment: fragment, expectedLifterID: Self.lifterID)
    }

    // MARK: - Building templates

    /// One prescribed set: pounds, as a coach types them.
    private struct S {
        var lb: Double?
        var reps: Int?
        var rpe: Double? = nil
        var sec: Int? = nil
        var metres: Double? = nil
        var side: SetSide? = nil
        var kind: SetKind? = nil
    }

    private struct Ex {
        var name: String
        var equipment = ""
        var note: String? = nil
        var eachSide = false
        /// Written as a raw `ExerciseGroup` row, so a test can store what the
        /// editor never would -- a lone group, a non-adjacent one.
        var group: Int? = nil
        var sets: [S] = [S(lb: 100, reps: 5), S(lb: 100, reps: 5)]
    }

    @discardableResult
    private func build(_ exercises: [Ex], in context: ModelContext, name: String = "Set types") throws -> Routine {
        let routine = Routine(name: name)
        context.insert(routine)
        for (index, spec) in exercises.enumerated() {
            let exercise = RoutineExercise(name: spec.name, equipment: spec.equipment, orderIndex: index,
                                           note: spec.note)
            exercise.routine = routine
            context.insert(exercise)
            if spec.eachSide { PrescriptionSides.setEachSide(true, for: exercise.id, in: context) }
            if let group = spec.group { context.insert(ExerciseGroup(exerciseID: exercise.id, group: group)) }
            for (order, s) in spec.sets.enumerated() {
                let set = RoutinePrescribedSet(orderIndex: order, targetWeightKg: s.lb.map(PlanLinkEncoder.lbToKg),
                                               targetReps: s.reps, targetRPE: s.rpe, targetDurationSec: s.sec,
                                               targetDistanceMeters: s.metres)
                set.exercise = exercise
                context.insert(set)
                PrescriptionSides.setSide(s.side, for: set.id, in: context)
                PrescriptionTypes.setKind(s.kind, for: set.id, in: context)
            }
        }
        try context.save()
        return routine
    }

    private func wire(_ routine: Routine) throws -> [PlanWorkoutExercise] {
        try XCTUnwrap(try decode(PlanLinkEncoder.fragment(
            routines: [routine], lifterID: Self.lifterID, coachName: "Doug")).w?.first?.e)
    }

    /// The payload's raw JSON, as an object -- for `g`, which the kit's
    /// `PlanWorkoutExercise` does not read.
    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Each exercise's `g` in the first workout, read as a decoder must: a
    /// positive integer, by adjacency, renumbered; anything else not grouped.
    private func groups(_ payload: [String: Any]) -> [Int?] {
        let workouts = payload["w"] as? [[String: Any]] ?? []
        let exercises = workouts.first?["e"] as? [[String: Any]] ?? []
        return ExerciseGrouping.runs(exercises.map { ExerciseGrouping.groupOf(json: $0["g"]) })
    }

    private func rawGroups(_ payload: [String: Any]) -> [Int?] {
        let workouts = payload["w"] as? [[String: Any]] ?? []
        let exercises = workouts.first?["e"] as? [[String: Any]] ?? []
        return exercises.map { ExerciseGrouping.groupOf(json: $0["g"]) }
    }

    private func encodedJSON(_ routines: [Routine], sessions: [ScheduledSession] = []) throws -> Data {
        try XCTUnwrap(PlanLinkEncoder.json(routines: routines, sessions: sessions,
                                           lifterID: Self.lifterID, coachName: "Doug"))
    }

    private func side(of tuple: [Double?]) -> SetSide? {
        switch PlanSetFlags.sideBits(of: tuple) {
        case 1?: return .left
        case 2?: return .right
        default: return nil
        }
    }

    /// A set's kind as a reader shows it: masked out of `flags`, and never on
    /// an exercise's first set.
    private func kinds(_ exercise: PlanWorkoutExercise) -> [SetKind?] {
        exercise.s.enumerated().map { $0.offset == 0 ? nil : SetKind.fromPlanFlags($0.element) }
    }

    // MARK: - A plan written today is unchanged

    /// `setTuple` and the workout mapping as they stood on main before set
    /// types (coach-ios 9d7978e, PlanLinkEncoder.swift), verbatim but for the
    /// envelope: with no road picks main's `PayloadWithRoadPicks` wrote
    /// exactly `PlanPayload`'s own keys. Frozen here on purpose: the promise
    /// is that a plan with no groups and no kinds is the same bytes it always
    /// was, sides included, and the only honest check is against the code
    /// that wrote those bytes.
    private func mainJSON(_ routines: [Routine], sessions: [ScheduledSession]) throws -> Data {
        let sides = PrescriptionSides.load(from: routines.first?.modelContext)
        func mainSetTuple(_ set: RoutinePrescribedSet, side: SetSide?) -> [Double?] {
            var values: [Double?] = [
                set.targetWeightKg.map(PlanLinkEncoder.kgToLb),
                set.targetReps.map(Double.init),
                set.targetRPE,
                set.targetDurationSec.map(Double.init),
                set.targetDistanceMeters,
            ]
            if let side, let flags = PlanSetFlags.flags(sideBits: side.shareFlagBits) {
                return values + [flags]
            }
            while let last = values.last, last == nil { values.removeLast() }
            return values
        }
        let workouts = routines.map { routine in
            PlanWorkout(n: routine.name, e: routine.orderedExercises.map { exercise in
                PlanWorkoutExercise(
                    n: exercise.name,
                    q: exercise.equipment.isEmpty ? nil : exercise.equipment,
                    c: exercise.note,
                    s: exercise.orderedSets.map { mainSetTuple($0, side: sides.side(of: $0)) },
                    b: sides.isEachSide(exercise) ? 1 : nil)
            })
        }
        let index = Dictionary(uniqueKeysWithValues: routines.enumerated().map { ($0.element.id, $0.offset) })
        let booked = sessions.compactMap { s in index[s.routineID].map { PlanSession(d: s.dayKey, x: $0) } }
        let payload = PlanPayload(v: 1, t: "plan", l: Self.lifterID, n: "Doug", r: nil, m: nil,
                                  w: workouts.isEmpty ? nil : workouts, k: booked.isEmpty ? nil : booked)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }

    func testAPlanWithNoGroupsOrKindsEncodesByteForByteAsMainDid() throws {
        let ctx = try context()
        let routine = try build([
            Ex(name: "Back Squat", equipment: "Barbell", note: "Belt on the last set.",
               sets: [S(lb: 225, reps: 5, rpe: 8), S(lb: 225, reps: 5, rpe: 8), S(lb: 245, reps: 3, rpe: 9)]),
            Ex(name: "Walking Lunge", eachSide: true, sets: [S(lb: nil, reps: 12), S(lb: 0, reps: 12)]),
            Ex(name: "Row", equipment: "Machine",
               sets: [S(lb: nil, reps: nil, sec: 600, metres: 1600, side: .left), S(lb: nil, reps: nil)]),
            Ex(name: "Split Squat", eachSide: true, sets: [S(lb: 40, reps: 8), S(lb: 40, reps: 8, side: .right)]),
            Ex(name: "Empty", equipment: "Cable", sets: []),
        ], in: ctx, name: "Lower A")
        let session = ScheduledSession(clientID: Self.lifterID, dayKey: "2026-09-28", routineID: routine.id)
        ctx.insert(session)
        try ctx.save()
        XCTAssertEqual(String(data: try encodedJSON([routine], sessions: [session]), encoding: .utf8),
                       String(data: try mainJSON([routine], sessions: [session]), encoding: .utf8))
    }

    /// A lone group, a non-adjacent one, and a kind on a first set are all
    /// things a reader would ignore -- so the encoder writes none of them.
    func testALoneOrNonAdjacentGroupAndAFirstSetKindChangeNoByte() throws {
        let ctx = try context()
        let routine = try build([
            Ex(name: "A", group: 1),
            Ex(name: "B"),
            Ex(name: "C", group: 1, sets: [S(lb: 100, reps: 5, kind: .drop), S(lb: 90, reps: 5)]),
            Ex(name: "D", group: 0),
            Ex(name: "E", group: -3),
        ], in: ctx, name: "Junk")
        XCTAssertEqual(String(data: try encodedJSON([routine]), encoding: .utf8),
                       String(data: try mainJSON([routine], sessions: []), encoding: .utf8))
    }

    /// The sibling fixtures, all written by Coach web before set types: no
    /// `g`, and nothing in bits 3-4 of any set.
    func testTheSiblingFixturesCarryNoGroupsAndNoKinds() throws {
        for name in ["web-plan-link", "web-plan-per-side", "web-plan-road-picks"] {
            let json = try fixtureJSON(name)
            XCTAssertFalse(String(data: json, encoding: .utf8)!.contains(#""g""#), name)
            let payload = try JSONDecoder().decode(PlanPayload.self, from: json)
            for exercise in payload.w?.flatMap(\.e) ?? [] {
                XCTAssertEqual(exercise.s.map(SetKind.fromPlanFlags), exercise.s.map { _ in nil }, name)
            }
        }
    }

    // MARK: - Kinds on the wire

    func testAKindIsFlagsBits3And4OrdWithTheSide() {
        let set = RoutinePrescribedSet(orderIndex: 1, targetWeightKg: PlanLinkEncoder.lbToKg(30), targetReps: 12)
        XCTAssertEqual(PlanLinkEncoder.setTuple(set, side: nil, kind: .drop), [30, 12, nil, nil, nil, 8])
        XCTAssertEqual(PlanLinkEncoder.setTuple(set, side: nil, kind: .restPause), [30, 12, nil, nil, nil, 16])
        XCTAssertEqual(PlanLinkEncoder.setTuple(set, side: .left, kind: .drop), [30, 12, nil, nil, nil, 10])
        XCTAssertEqual(PlanLinkEncoder.setTuple(set, side: .right, kind: .drop), [30, 12, nil, nil, nil, 12])
        XCTAssertEqual(PlanLinkEncoder.setTuple(set, side: .left, kind: .restPause), [30, 12, nil, nil, nil, 18])
        XCTAssertEqual(PlanLinkEncoder.setTuple(set, side: .right, kind: .restPause), [30, 12, nil, nil, nil, 20])
    }

    func testAStraightBothSidesSetStillWritesNoSixthPosition() {
        let set = RoutinePrescribedSet(orderIndex: 1, targetWeightKg: PlanLinkEncoder.lbToKg(225), targetReps: 5)
        XCTAssertEqual(PlanLinkEncoder.setTuple(set, side: nil, kind: nil), [225, 5])
        XCTAssertEqual(PlanLinkEncoder.setTuple(set, side: nil), [225, 5])
    }

    func testOnlyTrailingNullsAreTrimmedSoARestPauseHoldKeepsItsSlots() {
        let hold = RoutinePrescribedSet(orderIndex: 1, targetDurationSec: 20)
        XCTAssertEqual(PlanLinkEncoder.setTuple(hold, side: nil, kind: .restPause), [nil, nil, nil, 20, nil, 16])
        let six = RoutinePrescribedSet(orderIndex: 1, targetReps: 6)
        XCTAssertEqual(PlanLinkEncoder.setTuple(six, side: nil, kind: .drop), [nil, 6, nil, nil, nil, 8])
    }

    func testAnExercisesFirstSetIsNeverWrittenAsADropOrRestPause() throws {
        let ctx = try context()
        let routine = try build([
            Ex(name: "Pushdown", sets: [S(lb: 70, reps: 12, kind: .drop), S(lb: 50, reps: 10, kind: .drop)]),
            // The side on a first set survives; only the kind goes.
            Ex(name: "Row", sets: [S(lb: 30, reps: 8, side: .left, kind: .restPause)]),
        ], in: ctx)
        let e = try wire(routine)
        XCTAssertEqual(e[0].s, [[70, 12], [50, 10, nil, nil, nil, 8]])
        XCTAssertEqual(e[1].s, [[30, 8, nil, nil, nil, 2]])
    }

    // MARK: - Kinds read back

    func testKindsAreMaskedNeverComparedSoLeftAndDropIsTen() {
        let expected: [(Double, SetSide?, SetKind?)] = [
            (8, nil, .drop), (16, nil, .restPause), (10, .left, .drop), (12, .right, .drop),
            (18, .left, .restPause), (20, .right, .restPause),
            (9, nil, .drop),        // bit 0 is ignored
            (11, .left, .drop),     // with a side too
            (24, nil, nil),         // 3 in bits 3-4 is never written and reads straight
            (26, .left, nil), (2, .left, nil), (0, nil, nil),
            (40, nil, .drop),       // bits above 4 are not ours
        ]
        for (flags, wantSide, wantKind) in expected {
            let tuple: [Double?] = [30, 8, nil, nil, nil, flags]
            XCTAssertEqual(side(of: tuple), wantSide, "flags \(flags)")
            XCTAssertEqual(SetKind.fromPlanFlags(tuple), wantKind, "flags \(flags)")
        }
    }

    func testAJunkSixthPositionIsAStraightSet() {
        for flags in [nil, -1, 2.5, .nan, .infinity] as [Double?] {
            XCTAssertNil(SetKind.fromPlanFlags([30, 8, nil, nil, nil, flags]), "\(String(describing: flags))")
        }
        XCTAssertNil(SetKind.fromPlanFlags([30, 8]), "no sixth position is straight")
    }

    // MARK: - Groups on the wire

    func testGIsWrittenOnARunOfTwoOrMoreAdjacentExercisesSharingAGroup() throws {
        let ctx = try context()
        let routine = try build([Ex(name: "Bench", group: 1), Ex(name: "Row", group: 1), Ex(name: "Curl")], in: ctx)
        XCTAssertEqual(rawGroups(try object(try encodedJSON([routine]))), [1, 1, nil])
    }

    /// Coach iPhone has always written sorted keys (`.sortedKeys`) -- decoders
    /// read by name -- so `g` lands between `c` and `n`, not in Coach web's
    /// `n q b g s c` insertion order. Never `0`.
    func testGIsAPlainIntegerKeyAmongTheSortedOnes() throws {
        let ctx = try context()
        let routine = try build([
            Ex(name: "Split Squat", equipment: "Dumbbell", note: "Slow.", eachSide: true, group: 3,
               sets: [S(lb: 40, reps: 8)]),
            Ex(name: "Row", equipment: "Cable", group: 3, sets: [S(lb: 100, reps: 10)]),
            Ex(name: "Curl", sets: [S(lb: 30, reps: 10)]),
        ], in: ctx)
        let json = try XCTUnwrap(String(data: try encodedJSON([routine]), encoding: .utf8))
        XCTAssertTrue(json.contains(#"{"b":1,"c":"Slow.","g":1,"n":"Split Squat","q":"Dumbbell","s":[[40,8]]}"#), json)
        XCTAssertTrue(json.contains(#"{"g":1,"n":"Row","q":"Cable","s":[[100,10]]}"#), json)
        XCTAssertTrue(json.contains(#"{"n":"Curl","s":[[30,10]]}"#), json)
        XCTAssertFalse(json.contains(#""g":0"#))
    }

    func testGroupsAreRenumberedOneTwoThreeInOrderOfAppearance() throws {
        let ctx = try context()
        let routine = try build([
            Ex(name: "A", group: 7), Ex(name: "B", group: 7),
            Ex(name: "C"),
            Ex(name: "D", group: 3), Ex(name: "E", group: 3), Ex(name: "F", group: 3),
            Ex(name: "G", group: 7), Ex(name: "H", group: 7),
        ], in: ctx)
        XCTAssertEqual(rawGroups(try object(try encodedJSON([routine]))), [1, 1, nil, 2, 2, 2, 3, 3])
    }

    func testAdjacencyMakesTheGroupNotTheNumber() {
        let g = ExerciseGrouping.runs
        XCTAssertEqual(g([1, nil, 1]), [nil, nil, nil], "two groups of one are no group")
        XCTAssertEqual(g([1]), [nil], "a group of one is an ordinary exercise")
        XCTAssertEqual(g([1, 1, 2, 2]), [1, 1, 2, 2], "neighbours with different numbers are two groups")
        XCTAssertEqual(g([1, 2, 1]), [nil, nil, nil])
        XCTAssertEqual(g([5, 5, 5, 5]), [1, 1, 1, 1])
        XCTAssertEqual(g([0, 0]), [nil, nil], "never 0")
        XCTAssertEqual(g([-1, -1]), [nil, nil])
        XCTAssertEqual(g([1, 1, 0, 1, 1]), [1, 1, nil, 2, 2])
    }

    /// `g` as a decoder reads it out of JSON: only a positive integer number.
    func testAGThatIsNotAPositiveIntegerIsNotGrouped() throws {
        let json = #"[4, 4, null, 9, 9, 9, 0, "3", 1.5, -2, true, 2.0, 2.0]"#
        let values = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any])
        let read = values.map { ExerciseGrouping.groupOf(json: $0) }
        XCTAssertEqual(read, [4, 4, nil, 9, 9, 9, nil, nil, nil, nil, nil, 2, 2])
        XCTAssertEqual(ExerciseGrouping.runs(read), [1, 1, nil, 2, 2, 2, nil, nil, nil, nil, nil, 3, 3])
        XCTAssertNil(ExerciseGrouping.groupOf(json: nil))
    }

    // MARK: - Round trip

    func testRoundTripSupersetCircuitDropRestPauseAndALeftSideDrop() throws {
        let ctx = try context()
        let routine = try build([
            Ex(name: "Back Squat", sets: [S(lb: 225, reps: 5), S(lb: 225, reps: 5)]),
            Ex(name: "Bench", group: 1, sets: [S(lb: 60, reps: 10), S(lb: 60, reps: 10)]),
            Ex(name: "Row", group: 1, sets: [S(lb: 120, reps: 12), S(lb: 120, reps: 12)]),
            Ex(name: "Swing", group: 2, sets: [S(lb: 53, reps: 15)]),
            Ex(name: "Push-Up", group: 2, sets: [S(lb: nil, reps: 12)]),
            Ex(name: "Plank", group: 2, sets: [S(lb: nil, reps: nil, sec: 45)]),
            Ex(name: "Pushdown", sets: [S(lb: 70, reps: 12), S(lb: 50, reps: 10, kind: .drop),
                                        S(lb: 35, reps: 10, kind: .drop)]),
            Ex(name: "Curl", sets: [S(lb: 65, reps: 8), S(lb: 65, reps: 4, kind: .restPause)]),
            Ex(name: "One-Arm Row", eachSide: true,
               sets: [S(lb: 50, reps: 10), S(lb: 30, reps: 12, side: .left, kind: .drop)]),
        ], in: ctx)
        let data = try encodedJSON([routine])
        XCTAssertEqual(groups(try object(data)), [nil, 1, 1, 2, 2, 2, nil, nil, nil])
        let e = try XCTUnwrap(try JSONDecoder().decode(PlanPayload.self, from: data).w?.first?.e)
        XCTAssertEqual(e.map(kinds), [[nil, nil], [nil, nil], [nil, nil], [nil], [nil], [nil],
                                      [nil, .drop, .drop], [nil, .restPause], [nil, .drop]])
        XCTAssertEqual(e[8].s.map(side(of:)), [nil, .left])
        XCTAssertEqual(e[8].b, 1)
        XCTAssertEqual(e[5].s, [[nil, nil, nil, 45]])
    }

    // MARK: - The editor's join and split

    func testSupersetWithNextJoinsTwoAndAgainMakesACircuitOfThree() {
        var list: [Int?] = [nil, nil, nil, nil]
        XCTAssertFalse(ExerciseGrouping.groupedWithNext(list, at: 0))
        list = ExerciseGrouping.settingGroupedWithNext(list, at: 0, true)
        XCTAssertEqual(list, [1, 1, nil, nil])
        XCTAssertTrue(ExerciseGrouping.groupedWithNext(list, at: 0))
        list = ExerciseGrouping.settingGroupedWithNext(list, at: 1, true)
        XCTAssertEqual(list, [1, 1, 1, nil])
        // Joining the exercise before a group takes the whole group.
        XCTAssertEqual(ExerciseGrouping.settingGroupedWithNext([nil, 1, 1], at: 0, true), [1, 1, 1])
    }

    func testJoiningTwoGroupsMakesOne() {
        XCTAssertEqual(ExerciseGrouping.settingGroupedWithNext([1, 1, 2, 2], at: 1, true), [1, 1, 1, 1])
    }

    func testSplittingKeepsWhatIsBeforeTheSplitAndGivesTheRestAGroupOfTheirOwn() {
        XCTAssertEqual(ExerciseGrouping.settingGroupedWithNext([1, 1, 1, nil], at: 0, false), [nil, 1, 1, nil],
                       "a superset is left behind")
        XCTAssertEqual(ExerciseGrouping.settingGroupedWithNext([1, 1, 1, 1], at: 1, false), [1, 1, 2, 2])
        XCTAssertEqual(ExerciseGrouping.settingGroupedWithNext([1, 1], at: 0, false), [nil, nil])
    }

    func testTheLastExerciseHasNoNextAndAskingChangesNothing() {
        XCTAssertEqual(ExerciseGrouping.settingGroupedWithNext([nil, nil], at: 1, true), [nil, nil])
        XCTAssertFalse(ExerciseGrouping.groupedWithNext([1, 1], at: 1))
    }

    /// The same rules, through the store, as the editor's toggle writes them:
    /// storage holds groups as the wire numbers them.
    func testTheEditorsToggleWritesGroupsAsTheWireNumbersThem() throws {
        let ctx = try context()
        let routine = try build([Ex(name: "A"), Ex(name: "B"), Ex(name: "C"), Ex(name: "D"), Ex(name: "E")], in: ctx)
        PrescriptionTypes.setGroupedWithNext(true, at: 3, in: routine, context: ctx)
        PrescriptionTypes.setGroupedWithNext(true, at: 0, in: routine, context: ctx)
        PrescriptionTypes.setGroupedWithNext(true, at: 1, in: routine, context: ctx)
        try ctx.save()
        let stored = { PrescriptionTypes.load(from: ctx).storedGroups(routine.orderedExercises) }
        XCTAssertEqual(stored(), [1, 1, 1, 2, 2], "renumbered in order of appearance on every write")
        XCTAssertEqual(PrescriptionTypes.load(from: ctx).labels(routine.orderedExercises).map { $0?.text }, [
            "Circuit A · A1", "Circuit A · A2", "Circuit A · A3", "Superset B · B1", "Superset B · B2"])

        PrescriptionTypes.setGroupedWithNext(false, at: 0, in: routine, context: ctx)
        try ctx.save()
        XCTAssertEqual(stored(), [nil, 1, 1, 2, 2])
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<ExerciseGroup>()), 4, "no row is not grouped")
    }

    func testRemovingTheMiddleOfASupersetLeavesNoGroupOfOneAndOfACircuitASuperset() throws {
        let ctx = try context()
        let pair = try build([Ex(name: "A", group: 1), Ex(name: "B", group: 1), Ex(name: "C")], in: ctx, name: "Pair")
        PrescriptionSides.removeExercise(pair.orderedExercises[1], in: ctx)
        try ctx.save()
        XCTAssertEqual(PrescriptionTypes.load(from: ctx).storedGroups(pair.orderedExercises), [nil, nil])

        let circuit = try build([Ex(name: "A", group: 1), Ex(name: "B", group: 1), Ex(name: "C", group: 1)],
                                in: ctx, name: "Circuit")
        PrescriptionSides.removeExercise(circuit.orderedExercises[1], in: ctx)
        try ctx.save()
        XCTAssertEqual(PrescriptionTypes.load(from: ctx).storedGroups(circuit.orderedExercises), [1, 1])
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<ExerciseGroup>()), 2)
    }

    func testRemovingASetTakesItsKindAndANewFirstSetLosesItsOwn() throws {
        let ctx = try context()
        let routine = try build([Ex(name: "Pushdown", sets: [
            S(lb: 70, reps: 12), S(lb: 50, reps: 10, kind: .drop), S(lb: 35, reps: 10, kind: .drop)])], in: ctx)
        let exercise = try XCTUnwrap(routine.orderedExercises.first)
        PrescriptionSides.removeSet(exercise.orderedSets[0], in: ctx)
        try ctx.save()
        XCTAssertEqual(PrescriptionTypes.load(from: ctx).kinds(of: exercise), [nil, .drop])
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<PrescribedSetKind>()), 1,
                       "the set that became first keeps no kind row at all")
        PrescriptionSides.removeSet(exercise.orderedSets[1], in: ctx)
        try ctx.save()
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<PrescribedSetKind>()), 0)
    }

    func testDeletingARoutineTakesItsGroupsAndKindsWithIt() throws {
        let ctx = try context()
        let keep = try build([Ex(name: "A", group: 1), Ex(name: "B", group: 1,
                                                          sets: [S(lb: 1, reps: 1), S(lb: 1, reps: 1, kind: .drop)])],
                             in: ctx, name: "Keep")
        let gone = try build([Ex(name: "C", group: 1), Ex(name: "D", group: 1,
                                                          sets: [S(lb: 1, reps: 1), S(lb: 1, reps: 1, kind: .restPause)])],
                             in: ctx, name: "Gone")
        ScheduledSession.deleteRoutineAndSessions(gone, from: [], in: ctx)
        try ctx.save()
        let types = PrescriptionTypes.load(from: ctx)
        XCTAssertEqual(Set(types.groups.keys), Set(keep.orderedExercises.map(\.id)))
        XCTAssertEqual(Array(types.kinds.values), [.drop])
    }

    // MARK: - How it reads

    func testAGroupIsLabelledSupersetForTwoAndCircuitForThreeMembersA1A2() {
        let labels = ExerciseGrouping.labels([nil, 1, 1, 2, 2, 2, 9])
        XCTAssertNil(labels[0])
        XCTAssertEqual(labels[1...5].map { $0?.text }, [
            "Superset A · A1", "Superset A · A2", "Circuit B · B1", "Circuit B · B2", "Circuit B · B3"])
        XCTAssertNil(labels[6], "a group of one is not labelled")
        XCTAssertEqual(labels.map { $0?.first }, [nil, true, false, true, false, false, nil])
    }

    func testTheLettersRunOnPastZ() {
        var many: [Int?] = []
        for g in 1...28 { many += [g, g] }
        let labels = ExerciseGrouping.labels(many)
        XCTAssertEqual(labels[50]?.group, "Superset Z")
        XCTAssertEqual(labels[52]?.group, "Superset AA")
        XCTAssertEqual(labels[55]?.member, "AB2")
        XCTAssertEqual(ExerciseGrouping.letters(701), "ZZ")
        XCTAssertEqual(ExerciseGrouping.letters(702), "AAA")
    }

    func testASetReadsWithItsKindAsItReadsWithItsSide() throws {
        let ctx = try context()
        let routine = try build([
            Ex(name: "Pushdown", sets: [S(lb: 70, reps: 12), S(lb: 70, reps: 12),
                                        S(lb: 50, reps: 10, kind: .drop), S(lb: 35, reps: 10, kind: .drop)]),
            Ex(name: "Curl", sets: [S(lb: 65, reps: 8), S(lb: 65, reps: 4, kind: .restPause)]),
            Ex(name: "Row", sets: [S(lb: 40, reps: 12), S(lb: 30, reps: 12, side: .left, kind: .drop)]),
            Ex(name: "Bench", sets: [S(lb: 30, reps: 12), S(lb: 30, reps: 12)]),
        ], in: ctx)
        let sides = PrescriptionSides.load(from: ctx)
        let types = PrescriptionTypes.load(from: ctx)
        XCTAssertEqual(routine.orderedExercises.map { PrescriptionText.summary($0, sides: sides, types: types) }, [
            "70 × 12, 70 × 12, 50 × 10 drop, 35 × 10 drop",
            "65 × 8, 65 × 4 rest-pause",
            "40 × 12, 30 × 12 L drop",
            "2 × 30 × 12",
        ])
    }

    func testEachSideKeepsAKindInTheSummaryOnThePlainSetsAndTheExtras() throws {
        let ctx = try context()
        let routine = try build([
            Ex(name: "A", eachSide: true, sets: [S(lb: 50, reps: 10), S(lb: 30, reps: 12, kind: .drop)]),
            Ex(name: "B", eachSide: true, sets: [S(lb: 50, reps: 10), S(lb: 50, reps: 10),
                                                 S(lb: 30, reps: 12, side: .left, kind: .drop)]),
            // An extra that is the same set, kind and all, is still "+ 1 L".
            Ex(name: "C", eachSide: true, sets: [S(lb: 50, reps: 10), S(lb: 30, reps: 12, kind: .drop),
                                                 S(lb: 30, reps: 12, side: .left, kind: .drop)]),
            Ex(name: "D", eachSide: true, sets: [S(lb: 30, reps: 12), S(lb: 30, reps: 12, kind: .drop),
                                                 S(lb: 30, reps: 12, side: .left, kind: .drop)]),
            Ex(name: "E", eachSide: true, sets: [S(lb: 30, reps: 12), S(lb: 30, reps: 12, kind: .drop),
                                                 S(lb: 30, reps: 12, kind: .drop),
                                                 S(lb: 30, reps: 12, side: .left, kind: .drop)]),
        ], in: ctx)
        let sides = PrescriptionSides.load(from: ctx)
        let types = PrescriptionTypes.load(from: ctx)
        XCTAssertEqual(routine.orderedExercises.map { PrescriptionText.summary($0, sides: sides, types: types) }, [
            "50 × 10, 30 × 12 drop each side",
            "2 × 50 × 10 each side + 30 × 12 L drop",
            "50 × 10, 30 × 12 drop each side + 30 × 12 L drop",
            "30 × 12, 30 × 12 drop each side + 30 × 12 L drop",
            "30 × 12, 30 × 12 drop, 30 × 12 drop each side + 30 × 12 L drop",
        ])
    }

    /// A kind does not change what an exercise asks for.
    func testAKindDoesNotChangeTheTargets() throws {
        let ctx = try context()
        let routine = try build([Ex(name: "Row", eachSide: true,
                                    sets: [S(lb: 50, reps: 10), S(lb: 30, reps: 12, side: .left, kind: .drop)])], in: ctx)
        let exercise = try XCTUnwrap(routine.orderedExercises.first)
        let sides = PrescriptionSides.load(from: ctx)
        XCTAssertEqual(PrescribedTargets(sides: exercise.orderedSets.map { sides.side(of: $0) },
                                         eachSide: sides.isEachSide(exercise)),
                       PrescribedTargets(left: 2, right: 1))
    }

    // MARK: - Backup

    func testABackupCarriesGroupsAndKindsAndRestoresThem() throws {
        let source = try context()
        try build([
            Ex(name: "Bench", group: 1, sets: [S(lb: 60, reps: 10)]),
            Ex(name: "Row", group: 1, sets: [S(lb: 120, reps: 12)]),
            Ex(name: "Pushdown", sets: [S(lb: 70, reps: 12), S(lb: 50, reps: 10, kind: .drop)]),
            Ex(name: "Curl", eachSide: true,
               sets: [S(lb: 65, reps: 8), S(lb: 65, reps: 4, side: .left, kind: .restPause)]),
        ], in: source)
        let data = try BackupCodec.export(from: source, defaults: isolatedDefaults())
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertEqual(json.components(separatedBy: #""group":1"#).count - 1, 2)
        XCTAssertEqual(json.components(separatedBy: #""group""#).count - 1, 2, "omitted when not grouped")
        XCTAssertTrue(json.contains(#""kind":"drop""#))
        XCTAssertTrue(json.contains(#""kind":"restPause""#))
        XCTAssertEqual(json.components(separatedBy: #""kind""#).count - 1, 2, "omitted when straight")

        let target = try context()
        try BackupCodec.restore(from: data, into: target, defaults: isolatedDefaults())
        let routine = try XCTUnwrap(try target.fetch(FetchDescriptor<Routine>()).first)
        let types = PrescriptionTypes.load(from: target)
        let sides = PrescriptionSides.load(from: target)
        let e = routine.orderedExercises
        XCTAssertEqual(types.storedGroups(e), [1, 1, nil, nil])
        XCTAssertEqual(e.map { types.kinds(of: $0) }, [[nil], [nil], [nil, .drop], [nil, .restPause]])
        XCTAssertEqual(e[3].orderedSets.map { sides.side(of: $0) }, [nil, .left])
    }

    func testABackupReadsGroupAndKindLenientlyAndAnOldFileRestoresUnchanged() throws {
        let file = """
        {"v":2,"clients":[],"routines":[{"id":"8C2E6D3A-1F0B-4E57-9A7C-2B5D4E6F7A81","name":"Junk",
          "exercises":[
            {"name":"A","equipment":"","group":2,"sets":[{"targetReps":1},{"targetReps":1,"kind":"Drop"},
                                                         {"targetReps":1,"kind":" restpause "}]},
            {"name":"B","equipment":"","group":2,"sets":[{"targetReps":1,"kind":"drop"},
                                                         {"targetReps":1,"kind":"sideways"},
                                                         {"targetReps":1,"kind":null},{"targetReps":1,"kind":8}]},
            {"name":"C","equipment":"","group":"3","sets":[{"targetReps":1},{"targetReps":1,"kind":"straight"}]},
            {"name":"D","equipment":"","group":0,"sets":[]},
            {"name":"E","equipment":"","group":2.5,"sets":[]},
            {"name":"F","equipment":"","group":-3,"sets":[]},
            {"name":"G","equipment":"","group":true,"sets":[]},
            {"name":"H","equipment":"","group":5,"sets":[]}]},
          {"id":"8C2E6D3A-1F0B-4E57-9A7C-2B5D4E6F7A82","name":"Old","exercises":[
            {"name":"Back Squat","equipment":"Barbell","sets":[{"targetReps":5},{"targetReps":3}]}]}]}
        """
        let target = try context()
        try BackupCodec.restore(from: Data(file.utf8), into: target, defaults: isolatedDefaults())
        let routines = try target.fetch(FetchDescriptor<Routine>())
        let junk = try XCTUnwrap(routines.first { $0.name == "Junk" })
        let old = try XCTUnwrap(routines.first { $0.name == "Old" })
        let types = PrescriptionTypes.load(from: target)
        let e = junk.orderedExercises
        XCTAssertEqual(types.storedGroups(e), [1, 1, nil, nil, nil, nil, nil, nil],
                       "renumbered as the wire would; a string, 0, a fraction, a negative, a bool and a lone group are not")
        XCTAssertEqual(types.kinds(of: e[0]), [nil, .drop, .restPause], "case and space forgiven")
        XCTAssertEqual(types.kinds(of: e[1]), [nil, nil, nil, nil], "a first set has no kind; junk reads straight")
        XCTAssertEqual(types.kinds(of: e[2]), [nil, nil], #""straight" is how nothing is spelt"#)
        XCTAssertEqual(try target.fetchCount(FetchDescriptor<PrescribedSetKind>()), 2)
        XCTAssertEqual(old.orderedExercises.first?.orderedSets.map(\.targetReps), [5, 3],
                       "a file written before set types restores unchanged")
        XCTAssertEqual(types.storedGroups(old.orderedExercises), [nil])
    }

    func testAWebCoachBackupsGroupsAndKindsImport() throws {
        let body = """
        { "v": 2, "clients": [], "workouts": [ { "id": "w-set-types", "name": "Upper B", "exercises": [
          { "name": "Dumbbell Bench Press", "equipment": "Dumbbell", "group": 4,
            "sets": [ { "weightLb": 60, "reps": 10 } ] },
          { "name": "Seated Cable Rows", "equipment": "Cable", "group": 4,
            "sets": [ { "weightLb": 120, "reps": 12 } ] },
          { "name": "Triceps Pushdown", "equipment": "Cable", "group": "4",
            "sets": [ { "weightLb": 70, "reps": 12, "kind": "drop" }, { "weightLb": 50, "reps": 10, "kind": "DROP" },
                      { "weightLb": 35, "reps": 10, "kind": "restPause" }, { "weightLb": 35, "reps": 10, "kind": 16 } ] }
        ] } ] }
        """
        let ctx = try context()
        _ = try WebLibraryImporter.importLibrary(from: Data(body.utf8), into: ctx, defaults: isolatedDefaults())
        let routine = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Routine>()).first)
        let types = PrescriptionTypes.load(from: ctx)
        let e = routine.orderedExercises
        XCTAssertEqual(types.storedGroups(e), [1, 1, nil])
        XCTAssertEqual(types.kinds(of: e[2]), [nil, .drop, .restPause, nil])
        XCTAssertEqual(try XCTUnwrap(e[2].orderedSets[1].targetWeightKg), PlanLinkEncoder.lbToKg(50),
                       accuracy: 1e-9, "the web store is pounds")
    }

    // MARK: - The store migration

    /// Two new entities and no change to an old one: a lightweight migration.
    /// A store written by a schema without them opens with every row intact.
    func testAStoreWrittenBeforeSetTypesOpensWithEveryRow() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SetTypesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Coach.store")
        let added: Set<ObjectIdentifier> = [ObjectIdentifier(ExerciseGroup.self),
                                            ObjectIdentifier(PrescribedSetKind.self)]
        let before = CoachSchema.models.filter { !added.contains(ObjectIdentifier($0)) }
        XCTAssertEqual(before.count, CoachSchema.models.count - 2)

        do {
            let container = try ModelContainer(for: Schema(before), configurations: ModelConfiguration(url: url))
            let ctx = ModelContext(container)
            try build([Ex(name: "Bench", eachSide: true, sets: [S(lb: 60, reps: 10, side: .left)]),
                       Ex(name: "Row")], in: ctx, name: "Before")
        }

        let container = try ModelContainer(for: Schema(CoachSchema.models), configurations: ModelConfiguration(url: url))
        let ctx = ModelContext(container)
        let routine = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Routine>()).first)
        XCTAssertEqual(routine.name, "Before")
        XCTAssertEqual(routine.orderedExercises.map(\.name), ["Bench", "Row"])
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<RoutinePrescribedSet>()), 3)
        XCTAssertEqual(PrescriptionSides.load(from: ctx).sides.count, 1)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<ExerciseGroup>()), 0)
        PrescriptionTypes.setGroupedWithNext(true, at: 0, in: routine, context: ctx)
        try ctx.save()
        XCTAssertEqual(PrescriptionTypes.load(from: ctx).storedGroups(routine.orderedExercises), [1, 1])
    }

    // MARK: - The interop fixture

    // Fixtures/web-plan-set-types.txt was produced by Coach web's own encoder
    // (planPayload's shape for one client and one booked session, packed by
    // CoachPrescriptions.pack, in node, 2026-10-28; dugcanlift-coach
    // coach/fixtures/, the same bytes). Never regenerate it from Swift: that
    // would prove only that this encoder agrees with itself.
    private func fixtureJSON(_ name: String = "web-plan-set-types") throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "txt"))
        let link = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let fragment = link.firstIndex(of: "#").map { String(link[link.index(after: $0)...]) } ?? link
        return try XCTUnwrap(CompactEncoding.inflateRaw(
            try XCTUnwrap(CompactEncoding.base64URLDecode(String(fragment.dropFirst(2))))))
    }

    private func fixtureFragment() throws -> String {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "web-plan-set-types", withExtension: "txt"))
        let link = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(link[link.index(after: try XCTUnwrap(link.firstIndex(of: "#")))...])
    }

    func testTheFixtureIsNotSomethingThisCodeCouldHaveWritten() throws {
        XCTAssertTrue(try fixtureFragment().hasPrefix("1z"))
        let json = try XCTUnwrap(String(data: try fixtureJSON(), encoding: .utf8))
        XCTAssertTrue(json.hasPrefix(#"{"v":1,"t":"plan","l":"a1b2c3d4""#),
                      "web JSON keeps insertion order; Coach's .sortedKeys would start with k or l")
        XCTAssertTrue(json.contains(#"{"n":"Dumbbell Bench Press","q":"Dumbbell","g":1,"s":"#),
                      "Coach web's n q b g s c order, which Coach's sorted keys never write")
    }

    func testTheFixtureCarriesGAndTheKindBitsAsSpecified() throws {
        let raw = try object(try fixtureJSON())
        XCTAssertEqual(rawGroups(raw), [nil, 1, 1, 2, 2, 2, nil, nil, nil])
        let payload = try decode(fixtureFragment())
        XCTAssertEqual(payload.k, [PlanSession(d: "2026-11-02", x: 0)])
        let e = try XCTUnwrap(payload.w?.first?.e)
        XCTAssertEqual(e.map(\.n), ["Back Squat", "Dumbbell Bench Press", "Seated Cable Rows",
                                    "Kettlebell Swing", "Push-Up", "Plank",
                                    "Triceps Pushdown", "Barbell Curl", "Single-Arm Dumbbell Row"])
        XCTAssertEqual(e.map(\.b), [nil, nil, nil, nil, nil, nil, nil, nil, 1])
        XCTAssertEqual(e[0].s, [[225, 5, 8], [225, 5, 8], [225, 5, 8]], "an ordinary exercise")
        XCTAssertEqual(e[5].s, [[nil, nil, nil, 45], [nil, nil, nil, 45]], "a circuit member with fewer sets")
        XCTAssertEqual(e[6].s, [[70, 12], [70, 12], [50, 10, nil, nil, nil, 8], [35, 10, nil, nil, nil, 8]])
        XCTAssertEqual(e[7].s, [[65, 8], [65, 4, nil, nil, nil, 16]])
        XCTAssertEqual(e[8].s, [[50, 10], [50, 10], [30, 12, nil, nil, nil, 10]], "left and drop is 10")
        for exercise in e {
            XCTAssertNil(SetKind.fromPlanFlags(exercise.s[0]), "no first set carries a kind: \(exercise.n)")
        }
    }

    func testTheFixtureDecodesToTheGroupsAndKindsTheWebEditorWrote() throws {
        let e = try XCTUnwrap(try decode(fixtureFragment()).w?.first?.e)
        let groups = groups(try object(try fixtureJSON()))
        XCTAssertEqual(groups, [nil, 1, 1, 2, 2, 2, nil, nil, nil])
        XCTAssertEqual(ExerciseGrouping.labels(groups).map { $0?.text }, [
            nil, "Superset A · A1", "Superset A · A2",
            "Circuit B · B1", "Circuit B · B2", "Circuit B · B3",
            nil, nil, nil])
        XCTAssertEqual(kinds(e[6]), [nil, nil, .drop, .drop])
        XCTAssertEqual(kinds(e[7]), [nil, .restPause])
        XCTAssertEqual(kinds(e[8]), [nil, nil, .drop])
        XCTAssertEqual(e[8].s.map(side(of:)), [nil, nil, .left])
        XCTAssertTrue(e[8].isEachSide)
    }

    /// What a decoder that has never heard of `g` or bits 3-4 reads -- the
    /// kit's `PlanLinkCodec` is exactly that decoder: the right exercises, in
    /// the right order, with the right sets, numbers and sides.
    func testAnOldDecoderReadsTheRightExercisesSetsNumbersAndSides() throws {
        let e = try XCTUnwrap(try decode(fixtureFragment()).w?.first?.e)
        XCTAssertEqual(e.count, 9)
        XCTAssertEqual(e.map(\.s.count), [3, 3, 3, 3, 3, 2, 4, 2, 3])
        XCTAssertEqual(e[6].s.map { [$0[0], $0[1]] }, [[70, 12], [70, 12], [50, 10], [35, 10]])
        XCTAssertEqual(Array(e[8].s[2].prefix(2)), [30, 12])
        XCTAssertEqual(side(of: e[8].s[2]), .left, "the side bits read through the kind bits")
        XCTAssertTrue(e.prefix(8).allSatisfy { $0.s.allSatisfy { side(of: $0) == nil } },
                      "a drop or rest-pause set is not mistaken for a side")
    }

    /// The same templates, built in a store through the editor's own writes,
    /// encode to the payload Coach web sent -- compared as JSON text. Coach
    /// writes sorted keys, so the fixture is re-serialised with sorted keys
    /// first; and Coach web always sends `r` and `m`, even empty, where Coach
    /// leaves an empty one out (PLAN-FORMAT allows both), so the fixture's
    /// two empty arrays are set aside. Everything else -- every number, every
    /// null, every `g`, every flags value -- must be the same characters.
    func testCoachWritesWhatCoachWebWroteByteForByte() throws {
        let ctx = try context()
        let routine = try build([
            Ex(name: "Back Squat", equipment: "Barbell", note: "Belt on the last set.",
               sets: Array(repeating: S(lb: 225, reps: 5, rpe: 8), count: 3)),
            Ex(name: "Dumbbell Bench Press", equipment: "Dumbbell", sets: Array(repeating: S(lb: 60, reps: 10), count: 3)),
            Ex(name: "Seated Cable Rows", equipment: "Cable", sets: Array(repeating: S(lb: 120, reps: 12), count: 3)),
            Ex(name: "Kettlebell Swing", equipment: "Kettlebells", sets: Array(repeating: S(lb: 53, reps: 15), count: 3)),
            Ex(name: "Push-Up", equipment: "Body Only", sets: Array(repeating: S(lb: nil, reps: 12), count: 3)),
            Ex(name: "Plank", equipment: "Body Only", note: "Two rounds only.",
               sets: Array(repeating: S(lb: nil, reps: nil, sec: 45), count: 2)),
            Ex(name: "Triceps Pushdown", equipment: "Cable",
               sets: [S(lb: 70, reps: 12), S(lb: 70, reps: 12), S(lb: 50, reps: 10, kind: .drop),
                      S(lb: 35, reps: 10, kind: .drop)]),
            Ex(name: "Barbell Curl", equipment: "Barbell",
               sets: [S(lb: 65, reps: 8), S(lb: 65, reps: 4, kind: .restPause)]),
            Ex(name: "Single-Arm Dumbbell Row", equipment: "Dumbbell", note: "Drop on the left only.", eachSide: true,
               sets: [S(lb: 50, reps: 10), S(lb: 50, reps: 10), S(lb: 30, reps: 12, side: .left, kind: .drop)]),
        ], in: ctx, name: "Set types A")
        // The superset and the circuit, as the coach builds them.
        PrescriptionTypes.setGroupedWithNext(true, at: 1, in: routine, context: ctx)
        PrescriptionTypes.setGroupedWithNext(true, at: 3, in: routine, context: ctx)
        PrescriptionTypes.setGroupedWithNext(true, at: 4, in: routine, context: ctx)
        let session = ScheduledSession(clientID: Self.lifterID, dayKey: "2026-11-02", routineID: routine.id)
        ctx.insert(session)
        try ctx.save()

        var web = try object(try fixtureJSON())
        XCTAssertEqual((web.removeValue(forKey: "r") as? [Any])?.isEmpty, true)
        XCTAssertEqual((web.removeValue(forKey: "m") as? [Any])?.isEmpty, true)
        let webText = try XCTUnwrap(String(data: try JSONSerialization.data(
            withJSONObject: web, options: [.sortedKeys]), encoding: .utf8))
        let mine = try XCTUnwrap(String(data: try encodedJSON([routine], sessions: [session]), encoding: .utf8))
        XCTAssertEqual(mine, webText)
    }
}
