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

    static func fragment(routines: [Routine], sessions: [ScheduledSession],
                         lifterID: String, coachName: String) -> String {
        let workouts = routines.map { routine in
            PlanWorkout(n: routine.name, e: routine.orderedExercises.map { exercise in
                PlanWorkoutExercise(
                    n: exercise.name,
                    q: exercise.equipment.isEmpty ? nil : exercise.equipment,
                    c: exercise.note,
                    s: exercise.orderedSets.map(setTuple))
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

        let payload = PlanPayload(v: 1, t: "plan", l: lifterID, n: coachName,
                                  r: [], m: [], w: workouts, k: booked)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let json = try? encoder.encode(payload) else { return "" }
        if let deflated = CompactEncoding.deflateRaw(json) {
            return "1z" + CompactEncoding.base64URL(deflated)
        }
        return "1u" + CompactEncoding.base64URL(json)
    }

    /// `[weightLb, reps, rpe, durationSec, distanceMeters]`, trailing nulls
    /// trimmed. Leading and interior nulls stay: a conditioning piece is
    /// `[null, null, null, 600, 1600]`, and trimming those would move
    /// distance into the weight slot.
    private static func setTuple(_ set: RoutinePrescribedSet) -> [Double?] {
        var values: [Double?] = [
            set.targetWeightKg.map(kgToLb),
            set.targetReps.map(Double.init),
            set.targetRPE,
            set.targetDurationSec.map(Double.init),
            set.targetDistanceMeters,
        ]
        while let last = values.last, last == nil { values.removeLast() }
        return values
    }
}
