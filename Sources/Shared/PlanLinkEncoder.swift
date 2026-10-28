import Foundation
import LiftCore

/// Turns a coach's templates and bookings into a `PLAN-FORMAT` link.
///
/// The mirror of `lift-ios`'s `PlanImporter`, and it goes through
/// `LiftCore`'s `PlanPayload` types — the same definitions LIFT decodes
/// with, so a field cannot be added on one side and forgotten on the other.
enum PlanLinkEncoder {

    /// `RoutinePrescribedSet` stores kilograms; `PLAN-FORMAT`'s set tuple is
    /// `[weightLb, ...]`. Both ends of this conversion are load-bearing:
    /// `PlanImporter` converts back on the way in, and a missing conversion
    /// here ships a number 2.2x wrong to a real client with nothing failing.
    ///
    /// Both delegate to `LiftCore.WeightUnit` rather than carrying their own
    /// factor. An earlier version wrote the literal twice here, which is the
    /// same shape as the duplication these wrappers exist to prevent — one
    /// copy in the package and one here would drift exactly as readily as
    /// one here and one in a view.
    static func kgToLb(_ kg: Double) -> Double { WeightUnit.pounds.fromKilograms(kg) }

    /// The inverse of `kgToLb`, for a call site that takes a coach's
    /// pounds-entered weight and must store kilograms.
    static func lbToKg(_ lb: Double) -> Double { WeightUnit.pounds.toKilograms(lb) }

    /// `UserDefaults.string(forKey:)` returns `nil` only when the key was
    /// never set. `ConnectView`'s `@AppStorage` writes `""` the moment a
    /// coach clears the Name field, and `?? "Your coach"` alone lets that
    /// empty string straight onto the wire as `n:""`. `ConnectView` itself
    /// already guards its own use of the same value with `.isEmpty`
    /// (`inviteText`); this mirrors that.
    static func coachName(_ raw: String?) -> String {
        let name = raw ?? ""
        return name.isEmpty ? "Your coach" : name
    }

    /// - Parameter sides: the coach's prescribed sides. `nil` reads them from
    ///   the routines' own store, so no call site can send a plan and forget
    ///   them; a test passes them in.
    /// - Parameter types: the coach's groups and set kinds (PLAN-FORMAT.md
    ///   "Set types"). `nil` reads them from the routines' own store, as
    ///   `sides` does, for the same reason.
    /// - Parameter roadPicks: the Road Food item ids marked for this client.
    ///   Sent as `rf`, omitted entirely when empty. Nothing is dropped from it
    ///   here for being absent from this app's copy of the file.
    static func fragment(routines: [Routine] = [], sessions: [ScheduledSession] = [],
                         recipes: [Recipe] = [], meals: [PlannedMeal] = [],
                         sides: PrescriptionSides? = nil, types: PrescriptionTypes? = nil,
                         roadPicks: [String] = [],
                         lifterID: String, coachName: String) -> String {
        guard let json = json(routines: routines, sessions: sessions, recipes: recipes,
                              meals: meals, sides: sides, types: types, roadPicks: roadPicks,
                              lifterID: lifterID,
                              coachName: coachName) else { return "" }
        if let deflated = CompactEncoding.deflateRaw(json) {
            return "1z" + CompactEncoding.base64URL(deflated)
        }
        return "1u" + CompactEncoding.base64URL(json)
    }

    /// The payload's JSON, before the envelope: what every decoder reads, and
    /// what the tests compare. Keys sorted, so the same plan is the same text.
    static func json(routines: [Routine] = [], sessions: [ScheduledSession] = [],
                     recipes: [Recipe] = [], meals: [PlannedMeal] = [],
                     sides: PrescriptionSides? = nil, types: PrescriptionTypes? = nil,
                     roadPicks: [String] = [],
                     lifterID: String, coachName: String) -> Data? {
        let sides = sides ?? PrescriptionSides.load(from: routines.first?.modelContext)
        let types = types ?? PrescriptionTypes.load(from: routines.first?.modelContext)
        let workouts = routines.map { routine in
            let exercises = routine.orderedExercises
            // `g` only on a run of two or more adjacent exercises sharing a
            // stored group, renumbered 1, 2, 3... in order of appearance, and
            // on no others -- so a plan without groups is the same bytes it
            // always was. A group is a fact about neighbours, so it is worked
            // out over the whole workout, never one exercise at a time.
            let groups = types.wireGroups(exercises)
            return WireWorkout(n: routine.name, e: zip(exercises, groups).map { exercise, group in
                // The first set has nothing before it to drop from or pause
                // after, so `kinds(of:)` never gives it a kind.
                let kinds = types.kinds(of: exercise)
                let sets = exercise.orderedSets
                return WireExercise(PlanWorkoutExercise(
                    n: exercise.name,
                    q: exercise.equipment.isEmpty ? nil : exercise.equipment,
                    c: exercise.note,
                    s: sets.indices.map { setTuple(sets[$0], side: sides.side(of: sets[$0]), kind: kinds[$0]) },
                    // Each side is `b: 1`, and absent when not -- never `0` --
                    // so a plan without it is the same bytes it always was.
                    b: sides.isEachSide(exercise) ? 1 : nil), g: group)
            })
        }

        // `x` indexes into `w`, so a session whose template is not in this
        // send is dropped rather than pointed at the wrong workout.
        let indexByRoutine = Dictionary(uniqueKeysWithValues:
            routines.enumerated().map { ($0.element.id, $0.offset) })
        let booked = sessions.compactMap { session -> PlanSession? in
            guard let index = indexByRoutine[session.routineID] else { return nil }
            return PlanSession(d: session.dayKey, x: index)
        }

        let inlined = recipes.map(planRecipe)

        // The same rule as sessions, for the same reason: `x` indexes into
        // `r`, and a stale index is the wrong dinner on someone's Tuesday.
        let indexByRecipe = Dictionary(uniqueKeysWithValues:
            recipes.enumerated().map { ($0.element.id, $0.offset) })
        let planned = meals.compactMap { meal -> PlanMeal? in
            guard let index = indexByRecipe[meal.recipeID] else { return nil }
            return PlanMeal(d: meal.dayKey, s: slot(meal.mealType), x: index, q: meal.servings)
        }

        // Empty means absent, not `[]`. PLAN-FORMAT: "a coach who plans only
        // training sends a payload with no `r` or `m` at all." `w` is left
        // out of `PlanPayload` here and written by `PayloadWithAppKeys`,
        // which carries each exercise's `g`.
        let payload = PlanPayload(
            v: 1, t: "plan", l: lifterID, n: coachName,
            r: inlined.isEmpty ? nil : inlined,
            m: planned.isEmpty ? nil : planned,
            w: nil,
            k: booked.isEmpty ? nil : booked)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // `rf` is a flat list of Road Food item ids, left out entirely when
        // there are none -- so a plan with no picks is byte for byte the plan
        // this encoder wrote before road picks existed, which
        // `PlanLinkRoadPicksTests` pins against a frozen copy of it. `g` is
        // the same promise for groups, pinned by `SetTypesTests`.
        return try? encoder.encode(PayloadWithAppKeys(
            payload, w: workouts.isEmpty ? nil : workouts, rf: RoadPicks.wire(roadPicks)))
    }

    /// `PlanPayload` plus the keys Coach writes app-side: `rf`, and `w` with
    /// each exercise's `g`.
    ///
    /// **Why the wrapper.** `PlanPayload` is `LiftCore`'s -- the same
    /// definition LIFT decodes with, which is what stops a field being added
    /// on one side and forgotten on the other -- and the kit is pinned to an
    /// exact tag that two shipped apps consume. A list of item ids, or one
    /// optional integer on an exercise, is not worth a kit release plus a
    /// version bump in both, so `rf` and `g` are written here instead, and
    /// LIFT reads them app-side from the same fragment (`RoadPickLink` for
    /// `rf`). The fixtures both ends read are the contract between them.
    ///
    /// It delegates every other key to the kit's own encoders rather than
    /// restating them -- `PlanPayload` for the envelope, `PlanWorkoutExercise`
    /// for every exercise key but `g` -- so nothing about the existing wire
    /// format is written twice and none of it can drift. With `.sortedKeys`,
    /// `rf` and `g` land in key order like everything else.
    private struct PayloadWithAppKeys: Encodable {
        let payload: PlanPayload
        let w: [WireWorkout]?
        let rf: [String]?

        init(_ payload: PlanPayload, w: [WireWorkout]?, rf: [String]?) {
            self.payload = payload
            self.w = w
            self.rf = rf
        }

        private enum CodingKeys: String, CodingKey { case w, rf }

        func encode(to encoder: Encoder) throws {
            try payload.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(w, forKey: .w)
            try container.encodeIfPresent(rf, forKey: .rf)
        }
    }

    /// `PlanWorkout`'s two keys, `n` and `e`, over exercises that can carry `g`.
    private struct WireWorkout: Encodable {
        let n: String
        let e: [WireExercise]
    }

    /// A `PlanWorkoutExercise`, encoded by the kit, plus `g` when the exercise
    /// is grouped. Absent otherwise -- never `0`.
    private struct WireExercise: Encodable {
        let exercise: PlanWorkoutExercise
        let g: Int?

        init(_ exercise: PlanWorkoutExercise, g: Int?) {
            self.exercise = exercise
            self.g = g
        }

        private enum CodingKeys: String, CodingKey { case g }

        func encode(to encoder: Encoder) throws {
            try exercise.encode(to: encoder)
            guard let g else { return }
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(g, forKey: .g)
        }
    }

    /// `[weightLb, reps, rpe, durationSec, distanceMeters, flags]`, trailing
    /// nulls trimmed. Leading and interior nulls stay: a conditioning piece is
    /// `[null, null, null, 600, 1600]`, and trimming those would move
    /// distance into the weight slot.
    ///
    /// `flags` is written only for a set that names a side or a kind -- the
    /// side in bits 1-2 (`2` left, `4` right), the kind in bits 3-4 (`8` drop,
    /// `16` rest-pause), OR'd together so a left-side drop set is `10`, and
    /// bit 0 always 0 -- and then every position before it is kept: a
    /// left-side conditioning piece is `[null, null, null, 600, 1600, 2]`. A
    /// straight both-sides set writes no sixth position at all, so every plan
    /// written before sides or set types is unchanged to the byte.
    ///
    /// This writes what it is handed. That an exercise's first set is never a
    /// drop or rest-pause is the exercise's rule, applied by
    /// `PrescriptionTypes.kinds(of:)`.
    static func setTuple(_ set: RoutinePrescribedSet, side: SetSide?, kind: SetKind? = nil) -> [Double?] {
        var values: [Double?] = [
            set.targetWeightKg.map(kgToLb),
            set.targetReps.map(Double.init),
            set.targetRPE,
            set.targetDurationSec.map(Double.init),
            set.targetDistanceMeters,
        ]
        let sideFlags = side.flatMap { PlanSetFlags.flags(sideBits: $0.shareFlagBits) } ?? 0
        let flags = sideFlags + Double(kind?.planFlags ?? 0)
        if flags != 0 { return values + [flags] }
        while let last = values.last, last == nil { values.removeLast() }
        return values
    }

    /// `u` is `[kcal, protein, carbs, fat, fibre]` PER SERVING, and is omitted
    /// entirely when the coach never entered macros. Never zeros: a zero here
    /// becomes a zero-calorie dinner in the client's day total.
    ///
    /// A non-nil `nutritionPerServing` with calories/protein/carbs/fat all
    /// zero is "did not enter macros" in substance, not a real all-zero
    /// recipe -- `MacroFields.entered()` returns exactly that struct the
    /// moment any one field has content, including a `0` typed into
    /// calories or edited back down to it. Fibre is excluded from this
    /// check: a recipe can legitimately have zero fibre while carrying real
    /// calories.
    private static func planRecipe(_ recipe: Recipe) -> PlanRecipe {
        let macros = recipe.nutritionPerServing.flatMap { facts -> [Double]? in
            guard facts.calories != 0 || facts.proteinG != 0
                || facts.carbsG != 0 || facts.fatG != 0 else { return nil }
            return [facts.calories, facts.proteinG, facts.carbsG, facts.fatG, facts.fiberG ?? 0]
        }
        return PlanRecipe(
            n: recipe.name,
            s: recipe.servings,
            u: macros,
            // Raw text, never parsed. Every client runs the same parser, so
            // parsing on the receiving side keeps one implementation of the
            // rules rather than freezing this sender's reading into the wire.
            i: (recipe.ingredients ?? []).sorted { $0.sortOrder < $1.sortOrder }.map(\.rawText),
            t: recipe.steps,
            // `ux`: saturated fat, sugar and sodium per serving, rounded and
            // trailing-null-trimmed by the kit. nil -- so no key at all -- when
            // none is known, `u`'s blank-stays-blank rule. It can travel
            // without `u`: a coach may know a dish's sodium and not its calories.
            ux: ShareNutrients.itemRow(perServing: recipe.nutritionPerServing))
    }

    /// PLAN-FORMAT's meal slots: 0 breakfast, 1 lunch, 2 dinner, 3 snack.
    /// Written out rather than taken from `MealType.allCases.firstIndex`,
    /// which would silently renumber every planned meal if a case were ever
    /// reordered in the package.
    private static func slot(_ meal: MealType) -> Int {
        switch meal {
        case .breakfast: return 0
        case .lunch: return 1
        case .dinner: return 2
        case .snack: return 3
        }
    }
}
