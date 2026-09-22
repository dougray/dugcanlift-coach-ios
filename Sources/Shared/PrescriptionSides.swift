import Foundation
import SwiftData
import LiftCore

// MARK: - Storage

/// An exercise whose prescribed sets are each done on both sides: "3 × 8,
/// each side" is three rows here and on the wire (`b: 1`), and six sets on the
/// client's phone. PLAN-FORMAT.md "Sides".
///
/// Coach's own rows, keyed by `RoutineExercise.id` as a plain value, rather
/// than a property on `RoutineExercise`: that type is LiftKit's `@Model`,
/// shared with LIFT iOS, and a property on it is a schema change for both
/// apps -- on LIFT one that means freezing `Routine`, `RoutineExercise` and
/// `RoutinePrescribedSet` in every schema version since V3. A new Coach entity
/// is a lightweight migration here and nothing at all there. The same choice,
/// for the same reason, as `ClientShoppingCheck` and `ScheduledSession`.
///
/// Presence is the flag: a row means each side, no row means not.
@Model
final class EachSideExercise {
    var exerciseID: UUID = UUID()

    init(exerciseID: UUID) {
        self.exerciseID = exerciseID
    }
}

/// A prescribed set done on one side only, once -- the asymmetric case: an
/// extra set on the left, rehab side only. Keyed by `RoutinePrescribedSet.id`
/// for the reason `EachSideExercise` is. No row is both, which is what every
/// set written before this means.
@Model
final class PrescribedSetSide {
    var setID: UUID = UUID()
    /// `SetSide.rawValue`. Anything else reads as both.
    var sideRaw: String = ""

    init(setID: UUID, side: SetSide) {
        self.setID = setID
        self.sideRaw = side.rawValue
    }

    var side: SetSide? { SetSide(rawValue: sideRaw) }
}

/// Every side a coach has prescribed, read once and threaded down -- the way
/// `CookPlanView` threads the meal-owner map rather than decoding it per row.
struct PrescriptionSides: Equatable {
    var eachSide: Set<UUID> = []
    var sides: [UUID: SetSide] = [:]

    init(eachSide: Set<UUID> = [], sides: [UUID: SetSide] = [:]) {
        self.eachSide = eachSide
        self.sides = sides
    }

    init(eachSideRows: [EachSideExercise], sideRows: [PrescribedSetSide]) {
        eachSide = Set(eachSideRows.map(\.exerciseID))
        for row in sideRows {
            if let side = row.side { sides[row.setID] = side }
        }
    }

    /// Everything in `context`'s store, or nothing when there is no context.
    static func load(from context: ModelContext?) -> PrescriptionSides {
        guard let context else { return PrescriptionSides() }
        return PrescriptionSides(
            eachSideRows: (try? context.fetch(FetchDescriptor<EachSideExercise>())) ?? [],
            sideRows: (try? context.fetch(FetchDescriptor<PrescribedSetSide>())) ?? [])
    }

    func isEachSide(_ exercise: RoutineExercise) -> Bool { eachSide.contains(exercise.id) }

    func side(of set: RoutinePrescribedSet) -> SetSide? { sides[set.id] }

    /// Whether the exercise's editor shows the Both / L / R control without
    /// being asked: it is each side, or a set already names a side.
    func showsSides(_ exercise: RoutineExercise) -> Bool {
        isEachSide(exercise) || exercise.orderedSets.contains { side(of: $0) != nil }
    }

    // MARK: Writes

    static func setEachSide(_ on: Bool, for exerciseID: UUID, in context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<EachSideExercise>(
            predicate: #Predicate { $0.exerciseID == exerciseID }))) ?? []
        if on {
            if existing.isEmpty { context.insert(EachSideExercise(exerciseID: exerciseID)) }
        } else {
            existing.forEach(context.delete)
        }
    }

    /// `nil` is both: the row goes, rather than a "both" being written down.
    static func setSide(_ side: SetSide?, for setID: UUID, in context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<PrescribedSetSide>(
            predicate: #Predicate { $0.setID == setID }))) ?? []
        existing.forEach(context.delete)
        if let side { context.insert(PrescribedSetSide(setID: setID, side: side)) }
    }

    /// The rows naming this routine's exercises and sets. No delete rule
    /// reaches them -- they hold ids, not relationships -- so whatever deletes
    /// a routine calls this (`ScheduledSession.deleteRoutineAndSessions`).
    /// A row left behind would be harmless, since ids are never reused, but it
    /// would ride in every backup for nothing.
    static func deleteAll(for routine: Routine, in context: ModelContext) {
        let exerciseIDs = Set(routine.orderedExercises.map(\.id))
        let setIDs = Set(routine.orderedExercises.flatMap(\.orderedSets).map(\.id))
        for row in (try? context.fetch(FetchDescriptor<EachSideExercise>())) ?? []
        where exerciseIDs.contains(row.exerciseID) {
            context.delete(row)
        }
        for row in (try? context.fetch(FetchDescriptor<PrescribedSetSide>())) ?? []
        where setIDs.contains(row.setID) {
            context.delete(row)
        }
    }
}

// MARK: - What a prescription asks for

/// How many sets a side the exercise asks for, and how many two-sided ones.
/// An each-side exercise's unmarked set counts once on each side; a set that
/// names a side counts once on that side, each side or not. So "3 × 8 each
/// side plus one left" is left 4, right 3 -- seven sets. Coach web's
/// `CoachPrescriptions.targets`, rule for rule.
struct PrescribedTargets: Equatable {
    var left = 0
    var right = 0
    var both = 0

    init(left: Int = 0, right: Int = 0, both: Int = 0) {
        self.left = left
        self.right = right
        self.both = both
    }

    init(sides: [SetSide?], eachSide: Bool) {
        for side in sides {
            switch side {
            case .left?: left += 1
            case .right?: right += 1
            case nil:
                if eachSide { left += 1; right += 1 } else { both += 1 }
            }
        }
    }
}

// MARK: - How it reads

/// The text a prescription reads as on a workout card: "3 × 225 lb × 5",
/// "3 × 30 lb × 8 each side + 1 L", "60 lb × 8, 60 lb × 8, 40 lb × 10 R".
///
/// The numbers are Coach iPhone's own, as they were before sides; the side
/// rules are Coach web's `CoachPrescriptions.summary`. An exercise with no
/// side anywhere reads exactly as it always has.
enum PrescriptionText {

    /// A set's numbers alone: "225 lb × 5 × RPE 8", "—" for nothing.
    static func numbers(_ set: RoutinePrescribedSet) -> String {
        var parts: [String] = []
        if let kg = set.targetWeightKg {
            parts.append("\(Int(PlanLinkEncoder.kgToLb(kg).rounded())) lb")
        }
        if let reps = set.targetReps { parts.append("\(reps)") }
        if let rpe = set.targetRPE { parts.append("RPE \(rpe.formatted())") }
        if let seconds = set.targetDurationSec { parts.append("\(seconds)s") }
        if let metres = set.targetDistanceMeters { parts.append("\(Int(metres))m") }
        return parts.isEmpty ? "—" : parts.joined(separator: " × ")
    }

    /// The same, with the side it names: "30 lb × 8 L". Nothing added for both.
    static func text(_ set: RoutinePrescribedSet, side: SetSide?) -> String {
        numbers(set) + (side.map { " \($0.shortLabel)" } ?? "")
    }

    /// Collapses only when every set reads the same -- "3 × 225 lb × 5". A
    /// ramp lists its sets, because 225/225/245 has no collapsed form.
    private static func list(_ texts: [String]) -> String {
        if texts.count > 1, Set(texts).count == 1 { return "\(texts.count) × \(texts[0])" }
        return texts.joined(separator: ", ")
    }

    static func summary(_ exercise: RoutineExercise, sides: PrescriptionSides) -> String {
        let sets = exercise.orderedSets
        guard !sets.isEmpty else { return "no sets yet" }
        let named = sets.map { sides.side(of: $0) }
        let plain = zip(sets, named).filter { $0.1 == nil }.map(\.0)
        guard sides.isEachSide(exercise), !plain.isEmpty else {
            return list(zip(sets, named).map { text($0.0, side: $0.1) })
        }

        let plainTexts = plain.map(numbers)
        let same = Set(plainTexts).count == 1 ? plainTexts[0] : nil

        // The named extras, grouped by what they say, in the order they appear.
        var groups: [(side: SetSide, text: String, count: Int)] = []
        for (set, side) in zip(sets, named) {
            guard let side else { continue }
            let text = numbers(set)
            if let index = groups.firstIndex(where: { $0.side == side && $0.text == text }) {
                groups[index].count += 1
            } else {
                groups.append((side, text, 1))
            }
        }
        let extras = groups.map { group -> String in
            // "+ 1 L" when the extra is the same set; its numbers when it is not.
            if group.text == same { return " + \(group.count) \(group.side.shortLabel)" }
            return " + " + (group.count > 1 ? "\(group.count) × " : "") + group.text
                + " " + group.side.shortLabel
        }
        return list(plainTexts) + " each side" + extras.joined()
    }
}

// MARK: - Where "Each side" starts

/// Whether a name reads as a lift with a side to it. A guess, used only to
/// decide where the editor's "Each side" toggle starts; the coach's own choice
/// is what sticks (`EachSideChoices`).
///
/// LIFT web's `UNILATERAL_TERMS` (`lift/sides.js`), which is LIFT Android's
/// `PerSideLogging.UNILATERAL_TERMS` and Coach web's copy, term for term.
/// Matched as whole words against a name with everything that is not a letter
/// or a digit turned into a space, so "Single-Arm", "Single Arm" and "1-Arm"
/// are one term, and "lunge" does not tick a cold plunge. (LIFT iOS's
/// `UnilateralGuess` matches substrings and does tick one; this follows the
/// other three builds.)
enum UnilateralGuess {
    static let terms = [
        "single arm", "one arm", "1 arm", "single handed",
        "single leg", "one leg", "1 leg", "single limb",
        "one legged", "single legged", "one armed", "single armed",
        "bulgarian", "split squat", "split squats",
        "pistol", "pistols", "lunge", "lunges",
        "step up", "step ups", "stepup", "stepups",
        "unilateral",
    ]

    static func looksUnilateral(_ name: String) -> Bool {
        let words = name.lowercased().unicodeScalars.map {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
                ? String($0) : " "
        }.joined()
        let padded = " " + words.split(separator: " ").joined(separator: " ") + " "
        return terms.contains { padded.contains(" \($0) ") }
    }
}

/// The coach's own answer to "each side?" for a lift, remembered by name and
/// equipment -- the way LIFT keys its per-side preference -- so the next copy
/// of that lift starts where the coach left the last one. Absent is "never
/// answered", which falls back to `UnilateralGuess`; `false` is a real answer
/// and outranks it.
enum EachSideChoices {
    static let key = "eachSideChoices"

    static func exerciseKey(name: String, equipment: String) -> String {
        "\(name.trimmingCharacters(in: .whitespaces))|\(equipment.trimmingCharacters(in: .whitespaces))"
            .lowercased()
    }

    static func load(from defaults: UserDefaults = .standard) -> [String: Bool] {
        guard let data = defaults.data(forKey: key),
              let map = try? JSONDecoder().decode([String: Bool].self, from: data) else { return [:] }
        return map
    }

    static func startsEachSide(name: String, equipment: String,
                               defaults: UserDefaults = .standard) -> Bool {
        load(from: defaults)[exerciseKey(name: name, equipment: equipment)]
            ?? UnilateralGuess.looksUnilateral(name)
    }

    static func record(_ on: Bool, name: String, equipment: String,
                       defaults: UserDefaults = .standard) {
        var map = load(from: defaults)
        map[exerciseKey(name: name, equipment: equipment)] = on
        guard let data = try? JSONEncoder().encode(map) else { return }
        defaults.set(data, forKey: key)
    }
}
