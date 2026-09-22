import XCTest
import SwiftData
import LiftCore
@testable import Coach

/// Per-side prescriptions (PLAN-FORMAT.md "Sides"): `b: 1` on an exercise done
/// each side, and a sixth set-tuple position naming a side. The rules are
/// Coach web's `prescriptions.js`; these are its tests, ported case for case
/// where the two apps share a behaviour.
final class PerSidePrescriptionTests: XCTestCase {

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema(CoachSchema.models),
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    private func decode(_ fragment: String) throws -> PlanPayload {
        try PlanLinkCodec.decode(fragment: fragment, expectedLifterID: "a1b2c3d4")
    }

    /// A routine built in a store, with the sides it names written the way the
    /// editor writes them.
    private struct Built {
        let routine: Routine
        let context: ModelContext
        var sides: PrescriptionSides { PrescriptionSides.load(from: context) }
    }

    /// `(weightLb, reps, side)` per set; `nil` weight or reps is unprescribed.
    private typealias SetSpec = (lb: Double?, reps: Int?, side: SetSide?)

    private func build(_ exercises: [(name: String, equipment: String, eachSide: Bool, sets: [SetSpec])],
                       in context: ModelContext, name: String = "Per side") throws -> Built {
        let routine = Routine(name: name)
        context.insert(routine)
        for (index, spec) in exercises.enumerated() {
            let exercise = RoutineExercise(name: spec.name, equipment: spec.equipment, orderIndex: index)
            exercise.routine = routine
            context.insert(exercise)
            if spec.eachSide { PrescriptionSides.setEachSide(true, for: exercise.id, in: context) }
            for (order, s) in spec.sets.enumerated() {
                let set = RoutinePrescribedSet(orderIndex: order, targetWeightKg: s.lb.map(PlanLinkEncoder.lbToKg),
                                               targetReps: s.reps)
                set.exercise = exercise
                context.insert(set)
                PrescriptionSides.setSide(s.side, for: set.id, in: context)
            }
        }
        try context.save()
        return Built(routine: routine, context: context)
    }

    private func side(of tuple: [Double?]) -> SetSide? {
        switch PlanSetFlags.sideBits(of: tuple) {
        case 1?: return .left
        case 2?: return .right
        default: return nil
        }
    }

    // MARK: - The wire

    func testABothSidesSetWritesNoSixthPositionAndANamedSideAlwaysDoes() {
        let set = RoutinePrescribedSet(orderIndex: 0, targetWeightKg: PlanLinkEncoder.lbToKg(30), targetReps: 8)
        XCTAssertEqual(PlanLinkEncoder.setTuple(set, side: nil).count, 2)
        let left = PlanLinkEncoder.setTuple(set, side: .left)
        XCTAssertEqual(left.count, 6)
        XCTAssertEqual(Array(left[2...]), [nil, nil, nil, 2])
        XCTAssertEqual(PlanLinkEncoder.setTuple(set, side: .right).last, 4)
    }

    func testOnlyTrailingNullsAreTrimmedSoALeftConditioningPieceKeepsItsSlots() {
        let carry = RoutinePrescribedSet(orderIndex: 0, targetDurationSec: 600, targetDistanceMeters: 1600)
        XCTAssertEqual(PlanLinkEncoder.setTuple(carry, side: .left), [nil, nil, nil, 600, 1600, 2])
        XCTAssertEqual(PlanLinkEncoder.setTuple(carry, side: nil), [nil, nil, nil, 600, 1600])
        let fiveReps = RoutinePrescribedSet(orderIndex: 0, targetReps: 5)
        XCTAssertEqual(PlanLinkEncoder.setTuple(fiveReps, side: .right), [nil, 5, nil, nil, nil, 4])
    }

    func testEachSideIsBOneAndOmittedWhenNotNeverZero() throws {
        let built = try build([
            ("Split Squat", "Dumbbell", true, [(40, 8, nil)]),
            ("Bench Press", "Barbell", false, [(185, 5, nil)]),
        ], in: context())
        let json = try XCTUnwrap(String(data: try XCTUnwrap(PlanLinkEncoder.json(
            routines: [built.routine], lifterID: "a1b2c3d4", coachName: "Doug")), encoding: .utf8))
        XCTAssertTrue(json.contains(#"{"b":1,"n":"Split Squat""#), json)
        XCTAssertTrue(json.contains(#"{"n":"Bench Press""#), json)
        XCTAssertFalse(json.contains(#""b":0"#))
        XCTAssertEqual(json.components(separatedBy: #""b":"#).count - 1, 1, "only the each-side exercise")
    }

    /// No call site passes the sides; the encoder reads them from the
    /// routine's own store, so a plan cannot be sent and its sides forgotten.
    func testTheEncoderFindsTheSidesInTheRoutinesOwnStore() throws {
        let built = try build([("Row", "Dumbbell", true, [(30, 8, nil), (30, 8, .left)])], in: context())
        let exercise = try XCTUnwrap(try decode(PlanLinkEncoder.fragment(
            routines: [built.routine], lifterID: "a1b2c3d4", coachName: "Doug")).w?.first?.e.first)
        XCTAssertEqual(exercise.b, 1)
        XCTAssertEqual(exercise.s.map(side(of:)), [nil, .left])
    }

    /// Flags are masked, never compared: the kit's plan reader and Coach's own
    /// share-link reader agree on every value, 3 and 5 included.
    func testFlagsAreMaskedNeverCompared() {
        let expected: [Int: SetSide?] = [2: .left, 4: .right, 3: .left, 5: .right, 6: nil, 0: nil, 1: nil]
        for (flags, want) in expected {
            let tuple: [Double?] = [30, 8, nil, nil, nil, Double(flags)]
            XCTAssertEqual(side(of: tuple), want, "flags \(flags)")
            XCTAssertEqual(SetFlags.side(flags), want, "flags \(flags)")
            XCTAssertEqual(tuple[0], 30)
            XCTAssertEqual(tuple[1], 8)
        }
    }

    // MARK: - Round trips

    func testRoundTripBothLeftRightEachSideAndTheCombination() throws {
        let built = try build([
            ("Bench Press", "Barbell", false, [(185, 5, nil)]),
            ("Row", "Dumbbell", false, [(30, 8, .left), (35, 8, .right)]),
            ("Split Squat", "Dumbbell", true, [(40, 8, nil), (40, 8, nil)]),
            ("Lunge", "Dumbbell", true, [(40, 8, nil), (40, 8, nil), (40, 8, nil), (40, 8, .left)]),
        ], in: context())
        let e = try XCTUnwrap(try decode(PlanLinkEncoder.fragment(
            routines: [built.routine], lifterID: "a1b2c3d4", coachName: "Doug")).w?.first?.e)

        XCTAssertEqual(e.map(\.b), [nil, nil, 1, 1])
        XCTAssertEqual(e[0].s.map(side(of:)), [nil])
        XCTAssertEqual(e[0].s[0].count, 2, "two-sided: five fields at most, trailing nulls trimmed")
        XCTAssertEqual(e[1].s.map(side(of:)), [.left, .right])
        XCTAssertEqual(try XCTUnwrap(e[1].s[0][0]), 30, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(e[1].s[1][0]), 35, accuracy: 1e-9)
        XCTAssertEqual(e[2].s.map(side(of:)), [nil, nil])
        XCTAssertEqual(e[3].s.map(side(of:)), [nil, nil, nil, .left])
    }

    func testTheSevenSetCaseIsThreeRightAndFourLeft() throws {
        let built = try build([("Bulgarian Split Squat", "Dumbbell", true,
                                [(40, 8, nil), (40, 8, nil), (40, 8, nil), (40, 8, .left)])], in: context())
        let exercise = try XCTUnwrap(built.routine.orderedExercises.first)
        let sides = built.sides
        XCTAssertEqual(PrescribedTargets(sides: exercise.orderedSets.map { sides.side(of: $0) },
                                         eachSide: sides.isEachSide(exercise)),
                       PrescribedTargets(left: 4, right: 3))
        // And after the wire.
        let wire = try XCTUnwrap(try decode(PlanLinkEncoder.fragment(
            routines: [built.routine], lifterID: "a1b2c3d4", coachName: "Doug")).w?.first?.e.first)
        XCTAssertEqual(PrescribedTargets(sides: wire.s.map(side(of:)), eachSide: wire.isEachSide),
                       PrescribedTargets(left: 4, right: 3))
    }

    func testANamedSideOnATwoSidedLiftIsOnceOnThatSide() {
        XCTAssertEqual(PrescribedTargets(sides: [nil, nil, .right], eachSide: false),
                       PrescribedTargets(right: 1, both: 2))
    }

    // MARK: - A plan written today is unchanged

    /// `setTuple` and the exercise mapping as they stood on main before sides
    /// (coach-ios 2272204, PlanLinkEncoder.swift), verbatim. Frozen here on
    /// purpose: the promise is that a plan without sides is the same bytes it
    /// always was, and the only honest check is against the code that wrote
    /// them.
    private func oldJSON(_ routines: [Routine], sessions: [ScheduledSession]) throws -> Data {
        func oldSetTuple(_ set: RoutinePrescribedSet) -> [Double?] {
            var values: [Double?] = [
                set.targetWeightKg.map(PlanLinkEncoder.kgToLb),
                set.targetReps.map(Double.init),
                set.targetRPE,
                set.targetDurationSec.map(Double.init),
                set.targetDistanceMeters,
            ]
            while let last = values.last, last == nil { values.removeLast() }
            return values
        }
        let workouts = routines.map { routine in
            PlanWorkout(n: routine.name, e: routine.orderedExercises.map { exercise in
                PlanWorkoutExercise(
                    n: exercise.name,
                    q: exercise.equipment.isEmpty ? nil : exercise.equipment,
                    c: exercise.note,
                    s: exercise.orderedSets.map(oldSetTuple))
            })
        }
        let index = Dictionary(uniqueKeysWithValues: routines.enumerated().map { ($0.element.id, $0.offset) })
        let booked = sessions.compactMap { s in index[s.routineID].map { PlanSession(d: s.dayKey, x: $0) } }
        let payload = PlanPayload(v: 1, t: "plan", l: "a1b2c3d4", n: "Doug", r: nil, m: nil,
                                  w: workouts.isEmpty ? nil : workouts, k: booked.isEmpty ? nil : booked)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }

    func testAPlanWithNoSidesEncodesByteForByteAsBefore() throws {
        let ctx = try context()
        let built = try build([
            ("Back Squat", "Barbell", false, [(225, 5, nil), (225, 5, nil), (245, 3, nil)]),
            ("Walking Lunge", "", false, [(nil, 12, nil), (0, 12, nil)]),
            ("Empty", "Cable", false, []),
        ], in: ctx, name: "Lower A")
        // A unilateral name that was never ticked stays two-sided on the wire.
        let row = RoutineExercise(name: "Row", equipment: "Machine", orderIndex: 3, note: "Easy.")
        row.routine = built.routine
        ctx.insert(row)
        let conditioning = RoutinePrescribedSet(orderIndex: 0, targetDurationSec: 600, targetDistanceMeters: 1600)
        conditioning.exercise = row
        ctx.insert(conditioning)
        let session = ScheduledSession(clientID: "a1b2c3d4", dayKey: "2026-09-28", routineID: built.routine.id)
        ctx.insert(session)
        try ctx.save()

        let new = try XCTUnwrap(PlanLinkEncoder.json(routines: [built.routine], sessions: [session],
                                                     lifterID: "a1b2c3d4", coachName: "Doug"))
        XCTAssertEqual(String(data: new, encoding: .utf8),
                       String(data: try oldJSON([built.routine], sessions: [session]), encoding: .utf8))
    }

    // MARK: - The interop fixture

    // Fixtures/web-plan-per-side.txt was produced by Coach web's own encoder
    // (encodePlan, in a browser, 2026-09-22; dugcanlift-coach
    // coach/fixtures/, the same bytes). Never regenerate it from Swift: that
    // would prove only that this encoder agrees with itself.
    private func fixtureFragment() throws -> String {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "web-plan-per-side", withExtension: "txt"))
        let link = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(link[link.index(after: try XCTUnwrap(link.firstIndex(of: "#")))...])
    }

    func testTheFixtureIsNotSomethingThisCodeCouldHaveWritten() throws {
        let fragment = try fixtureFragment()
        let json = try XCTUnwrap(String(data: try XCTUnwrap(CompactEncoding.inflateRaw(
            try XCTUnwrap(CompactEncoding.base64URLDecode(String(fragment.dropFirst(2)))))), encoding: .utf8))
        XCTAssertTrue(json.hasPrefix(#"{"v":1,"t":"plan","l":"a1b2c3d4""#),
                      "web JSON keeps insertion order; Coach's .sortedKeys would start with b or l")
    }

    func testTheFixtureDecodesWithItsSides() throws {
        let e = try XCTUnwrap(try decode(fixtureFragment()).w?.first?.e)
        XCTAssertEqual(e.map(\.n), ["Back Squat", "Single-Arm Dumbbell Row", "Bulgarian Split Squat",
                                    "Dumbbell Bench Press", "Suitcase Carry"])
        XCTAssertEqual(e.map(\.b), [nil, 1, 1, nil, nil])
        XCTAssertEqual(e[2].s.map(side(of:)), [nil, nil, nil, .left])
        XCTAssertEqual(e[3].s.map(side(of:)), [nil, nil, .right])
        XCTAssertEqual(e[4].s, [[nil, nil, nil, 600, 1600, 2]], "the distance is not in the weight slot")
        XCTAssertEqual(e.map { PrescribedTargets(sides: $0.s.map(side(of:)), eachSide: $0.isEachSide) }, [
            PrescribedTargets(both: 3),
            PrescribedTargets(left: 3, right: 3),
            PrescribedTargets(left: 4, right: 3),
            PrescribedTargets(right: 1, both: 2),
            PrescribedTargets(left: 1),
        ])
    }

    /// The same workout built in Coach's editor encodes to what Coach web
    /// sent, value for value. Keys are compared sorted -- Coach sorts them and
    /// `Codable` reads by name -- and weights to a millionth of a pound,
    /// because Coach stores kilograms and converts on the way out.
    func testCoachWritesWhatCoachWebWrote() throws {
        let ctx = try context()
        let built = try build([
            ("Back Squat", "Barbell", false, []),
            ("Single-Arm Dumbbell Row", "Dumbbell", true, [(30, 8, nil), (30, 8, nil), (30, 8, nil)]),
            ("Bulgarian Split Squat", "Dumbbell", true, [(40, 8, nil), (40, 8, nil), (40, 8, nil), (40, 8, .left)]),
            ("Dumbbell Bench Press", "Dumbbell", false, [(60, 8, nil), (60, 8, nil), (40, 10, .right)]),
            ("Suitcase Carry", "Kettlebells", false, []),
        ], in: ctx, name: "Per-side A")
        let exercises = built.routine.orderedExercises
        for _ in 0..<3 {
            let squat = RoutinePrescribedSet(orderIndex: exercises[0].orderedSets.count,
                                             targetWeightKg: PlanLinkEncoder.lbToKg(225), targetReps: 5, targetRPE: 8)
            squat.exercise = exercises[0]
            ctx.insert(squat)
        }
        exercises[2].note = "Extra set on the left."
        exercises[4].note = "Left hand only."
        let carry = RoutinePrescribedSet(orderIndex: 0, targetDurationSec: 600, targetDistanceMeters: 1600)
        carry.exercise = exercises[4]
        ctx.insert(carry)
        PrescriptionSides.setSide(.left, for: carry.id, in: ctx)
        try ctx.save()

        func rounded(_ workouts: [PlanWorkout]?) -> [PlanWorkout] {
            (workouts ?? []).map { w in
                PlanWorkout(n: w.n, e: w.e.map { x in
                    PlanWorkoutExercise(n: x.n, q: x.q, c: x.c,
                                        s: x.s.map { $0.map { $0.map { ($0 * 1e6).rounded() / 1e6 } } }, b: x.b)
                })
            }
        }
        let web = try decode(fixtureFragment())
        let mine = try decode(PlanLinkEncoder.fragment(routines: [built.routine], sides: built.sides,
                                                       lifterID: "a1b2c3d4", coachName: "Doug"))
        XCTAssertEqual(rounded(mine.w), rounded(web.w))
    }

    // MARK: - How it reads

    func testAnExerciseWithNoSideReadsExactlyAsBefore() throws {
        let built = try build([
            ("Back Squat", "Barbell", false, [(225, 5, nil), (225, 5, nil), (225, 5, nil)]),
            ("Ramp", "Barbell", false, [(225, 5, nil), (245, 3, nil)]),
            ("Empty", "", false, []),
        ], in: context())
        let e = built.routine.orderedExercises
        XCTAssertEqual(e.map { PrescriptionText.summary($0, sides: built.sides) },
                       ["3 × 225 lb × 5", "225 lb × 5, 245 lb × 3", "no sets yet"])
    }

    func testEachSideReadsEachSideAndAnExtraSetReadsPlusOneL() throws {
        let built = try build([
            ("A", "", true, [(30, 8, nil), (30, 8, nil), (30, 8, nil)]),
            ("B", "", true, [(30, 8, nil), (30, 8, nil), (30, 8, nil), (30, 8, .left)]),
            ("C", "", true, [(30, 8, nil), (30, 8, nil), (30, 8, nil), (20, 12, .left)]),
            ("D", "", true, [(30, 8, nil)]),
            ("E", "", false, [(185, 5, nil), (95, 10, .right)]),
            ("F", "", true, [(30, 8, .left), (30, 8, .left)]),
        ], in: context())
        let e = built.routine.orderedExercises
        XCTAssertEqual(e.map { PrescriptionText.summary($0, sides: built.sides) }, [
            "3 × 30 lb × 8 each side",
            "3 × 30 lb × 8 each side + 1 L",
            "3 × 30 lb × 8 each side + 20 lb × 12 L",
            "30 lb × 8 each side",
            "185 lb × 5, 95 lb × 10 R",
            "2 × 30 lb × 8 L",
        ])
    }

    // MARK: - Backup

    func testABackupCarriesEachSideAndSidesAndRestoresThem() throws {
        let source = try context()
        _ = try build([
            ("Bench Press", "Barbell", false, [(185, 5, nil), (95, 10, .right)]),
            ("Split Squat", "Dumbbell", true, [(40, 8, nil), (40, 8, .left)]),
        ], in: source)
        let data = try BackupCodec.export(from: source)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertEqual(json.components(separatedBy: #""eachSide":true"#).count - 1, 1)
        XCTAssertFalse(json.contains(#""eachSide":false"#), "omitted when false, never false")
        XCTAssertTrue(json.contains(#""side":"right""#))
        XCTAssertTrue(json.contains(#""side":"left""#))
        XCTAssertFalse(json.contains(#""side":null"#) || json.contains(#""side":"both""#))

        let target = try context()
        try BackupCodec.restore(from: data, into: target)
        let routine = try XCTUnwrap(try target.fetch(FetchDescriptor<Routine>()).first)
        let sides = PrescriptionSides.load(from: target)
        let e = routine.orderedExercises
        XCTAssertEqual(e.map { sides.isEachSide($0) }, [false, true])
        XCTAssertEqual(e[0].orderedSets.map { sides.side(of: $0) }, [nil, .right])
        XCTAssertEqual(e[1].orderedSets.map { sides.side(of: $0) }, [nil, .left])
    }

    func testAnUnknownSideOrEachSideRestoresAsBothRatherThanFailing() throws {
        let file = """
        {"v":2,"clients":[],"routines":[{"id":"8C2E6D3A-1F0B-4E57-9A7C-2B5D4E6F7A80","name":"Old",
          "exercises":[
            {"name":"A","equipment":"","sets":[{"targetReps":5,"side":"sideways"},{"targetReps":5,"side":4},
                                                 {"targetReps":5,"side":"Left"}],"eachSide":"yes"},
            {"name":"B","equipment":"","sets":[{"targetReps":5}]}]}]}
        """
        let target = try context()
        try BackupCodec.restore(from: Data(file.utf8), into: target)
        let routine = try XCTUnwrap(try target.fetch(FetchDescriptor<Routine>()).first)
        let sides = PrescriptionSides.load(from: target)
        XCTAssertEqual(routine.orderedExercises.map { sides.isEachSide($0) }, [false, false])
        XCTAssertEqual(routine.orderedExercises[0].orderedSets.map { sides.side(of: $0) }, [nil, nil, .left])
        XCTAssertEqual(routine.orderedExercises[1].orderedSets.map(\.targetReps), [5],
                       "a file written before sides restores unchanged")
    }

    func testAWebCoachBackupsSidesImport() throws {
        let body = """
        { "v": 2, "clients": [], "workouts": [ { "id": "w9", "name": "Per side", "exercises": [
          { "name": "Bulgarian Split Squat", "equipment": "Dumbbell", "note": "", "eachSide": true,
            "sets": [ { "weightLb": 40, "reps": 8 }, { "weightLb": 40, "reps": 8, "side": "left" } ] },
          { "name": "Bench", "equipment": "Barbell", "eachSide": "maybe",
            "sets": [ { "weightLb": 95, "reps": 10, "side": "right" }, { "weightLb": 95, "reps": 10, "side": 7 } ] }
        ] } ] }
        """
        let ctx = try context()
        _ = try WebLibraryImporter.importLibrary(from: Data(body.utf8), into: ctx)
        let routine = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Routine>()).first)
        let sides = PrescriptionSides.load(from: ctx)
        let e = routine.orderedExercises
        XCTAssertEqual(e.map { sides.isEachSide($0) }, [true, false])
        XCTAssertEqual(e[0].orderedSets.map { sides.side(of: $0) }, [nil, .left])
        XCTAssertEqual(e[1].orderedSets.map { sides.side(of: $0) }, [.right, nil])
        XCTAssertEqual(try XCTUnwrap(e[0].orderedSets[1].targetWeightKg), PlanLinkEncoder.lbToKg(40),
                       accuracy: 1e-9, "the web store is pounds")
    }

    // MARK: - Deleting a routine

    func testDeletingARoutineTakesItsSidesWithIt() throws {
        let ctx = try context()
        let keep = try build([("Row", "Dumbbell", true, [(30, 8, .left)])], in: ctx, name: "Keep")
        let gone = try build([("Lunge", "Dumbbell", true, [(40, 8, .right)])], in: ctx, name: "Gone")
        ScheduledSession.deleteRoutineAndSessions(gone.routine, from: [], in: ctx)
        try ctx.save()
        let sides = PrescriptionSides.load(from: ctx)
        XCTAssertEqual(sides.eachSide, [try XCTUnwrap(keep.routine.orderedExercises.first).id])
        XCTAssertEqual(sides.sides.count, 1)
    }

    // MARK: - Where "Each side" starts

    func testEachSideStartsTickedByLiftsOwnUnilateralGuess() {
        for name in ["Bulgarian Split Squat", "Single-Arm Dumbbell Row", "One Arm Overhead Press",
                     "Walking Lunge", "Pistol Squat", "Step-Up", "Kettlebell One-Legged Deadlift", "1-Arm Row"] {
            XCTAssertTrue(UnilateralGuess.looksUnilateral(name), name)
        }
        for name in ["Barbell Bench Press", "Back Squat", "Cold Plunge", "Stepmill", "Arm Curl"] {
            XCTAssertFalse(UnilateralGuess.looksUnilateral(name), name)
        }
    }

    func testTheCoachsChoiceSticksPerLift() throws {
        let name = "per-side-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(EachSideChoices.startsEachSide(name: "Walking Lunge", equipment: "Dumbbell", defaults: defaults))
        EachSideChoices.record(false, name: "Walking Lunge", equipment: "Dumbbell", defaults: defaults)
        XCTAssertFalse(EachSideChoices.startsEachSide(name: " walking lunge", equipment: "DUMBBELL", defaults: defaults),
                       "a no on a name the guess says yes to sticks")
        XCTAssertTrue(EachSideChoices.startsEachSide(name: "Walking Lunge", equipment: "Barbell", defaults: defaults),
                      "keyed by name and equipment")
        EachSideChoices.record(true, name: "Bench Press", equipment: "Dumbbell", defaults: defaults)
        XCTAssertTrue(EachSideChoices.startsEachSide(name: "Bench Press", equipment: "Dumbbell", defaults: defaults))
    }
}
