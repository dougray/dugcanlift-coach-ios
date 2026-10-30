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
    /// Takes one exercise out of its workout. Its sets go with it by cascade;
    /// its side rows hold ids, not relationships, so they are swept here, as
    /// `deleteAll` sweeps a whole routine's. What is left is renumbered so the
    /// order stays 0, 1, 2 with no gap. The editor had no way to undo a wrong
    /// pick from "Add an exercise" short of rebuilding the workout.
    ///
    /// Its group and its sets' kinds are swept too (`PrescriptionTypes`), and
    /// the workout is regrouped afterwards: removing the middle of a superset
    /// leaves a group of one, which is no group, and the middle of a circuit
    /// leaves a superset.
    static func removeExercise(_ exercise: RoutineExercise, in context: ModelContext) {
        let setIDs = Set(exercise.orderedSets.map(\.id))
        let exerciseID = exercise.id
        PrescriptionTypes.sweep(exerciseID: exerciseID, setIDs: setIDs, in: context)
        for row in (try? context.fetch(FetchDescriptor<EachSideExercise>())) ?? []
        where row.exerciseID == exerciseID {
            context.delete(row)
        }
        for row in (try? context.fetch(FetchDescriptor<PrescribedSetSide>())) ?? []
        where setIDs.contains(row.setID) {
            context.delete(row)
        }
        let routine = exercise.routine
        routine?.exercises?.removeAll { $0.id == exerciseID }
        context.delete(exercise)
        for (index, remaining) in (routine?.orderedExercises ?? []).enumerated() {
            remaining.orderIndex = index
        }
        if let routine { PrescriptionTypes.regroup(routine, in: context) }
    }

    /// Takes one set out of its exercise, with its side row and its kind, and
    /// renumbers the rest. A set that has just become the first loses its
    /// kind, because there is no set before it to drop from or pause after.
    static func removeSet(_ set: RoutinePrescribedSet, in context: ModelContext) {
        let setID = set.id
        PrescriptionTypes.sweep(setIDs: [setID], in: context)
        for row in (try? context.fetch(FetchDescriptor<PrescribedSetSide>(
            predicate: #Predicate { $0.setID == setID }))) ?? [] {
            context.delete(row)
        }
        let exercise = set.exercise
        exercise?.prescribedSets?.removeAll { $0.id == setID }
        context.delete(set)
        for (index, remaining) in (exercise?.orderedSets ?? []).enumerated() {
            remaining.orderIndex = index
        }
        PrescriptionTypes.clearFirstKind(of: exercise, in: context)
    }

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

/// The text a prescription reads as on a workout card and a printout:
/// "3 × 225 × 5", "225 × 5 · @8", "1,600 m · 10:00", "5 reps",
/// "3 × 30 × 8 each side + 1 L", "185 × 5, 95 × 10 R",
/// "70 × 12, 50 × 10 drop", "30 × 12 L drop".
///
/// A port of Coach web's `CoachPrescriptions.prescriptionText` / `setText` /
/// `summary` (`coach/prescriptions.js`), the reference implementation, so a
/// coach reads the same words in the browser, here, and on Coach Android.
/// Change them in every build or in none.
///
/// Weights are pounds, the unit the editor's weight field is in
/// (`PrescribedWeightField`), as web's are: converted from the stored
/// kilograms here, at the point of display, and nowhere else. A weight with
/// reps carries no unit ("225 × 5"); a weight alone does ("225 lb"). Blank is
/// left out, never written as a zero, and a set with nothing in it reads "as
/// written".
enum PrescriptionText {

    /// A set's numbers alone: "225 × 5 · @8", "5 reps", "225 lb",
    /// "1,600 m · 10:00", "45s", "as written" for nothing. The order is web's:
    /// load, distance, duration, effort.
    ///
    /// Whole numbers are grouped in the reader's locale, as web's
    /// `toLocaleString()` and Android's `NumberFormat` group them; the tests
    /// pin one only so they can assert a string. RPE is printed as JavaScript
    /// prints a number -- "8", "8.5" -- because web writes it that way.
    static func numbers(_ set: RoutinePrescribedSet, locale: Locale = .current) -> String {
        var bits: [String] = []
        // Through the editor field's own pounds first, so conversion noise
        // cannot turn the 22.5 the coach typed into 22.4999... and round down.
        let lb = set.targetWeightKg.map(PrescribedWeightField.displayedPounds(kilograms:))
        switch (lb, set.targetReps) {
        case let (lb?, reps?): bits.append("\(whole(lb, locale)) × \(reps)")
        case let (nil, reps?): bits.append("\(reps) reps")
        case let (lb?, nil): bits.append("\(whole(lb, locale)) lb")
        case (nil, nil): break
        }
        if let metres = set.targetDistanceMeters { bits.append("\(whole(metres, locale)) m") }
        if let seconds = set.targetDurationSec { bits.append(duration(seconds)) }
        if let rpe = set.targetRPE { bits.append("@\(script(rpe))") }
        return bits.isEmpty ? "as written" : bits.joined(separator: " · ")
    }

    /// "10:00" from a minute up, "45s" under one -- web's rule, so 60 is
    /// "1:00" and an hour is "60:00".
    static func duration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        guard minutes != 0 else { return "\(seconds)s" }
        let rest = seconds % 60
        return "\(minutes):" + (rest < 10 ? "0\(rest)" : "\(rest)")
    }

    /// Rounded to a whole number and grouped: web's `num`,
    /// `Math.round(n).toLocaleString()`.
    private static func whole(_ value: Double, _ locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = 0
        let rounded = (value + 0.5).rounded(.down)  // Math.round: halves go up
        return formatter.string(from: NSNumber(value: rounded)) ?? "\(Int(rounded))"
    }

    /// A number as JavaScript's `String(n)` writes it: no ".0" on a whole
    /// number, and a "." decimal whatever the locale.
    private static func script(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
        return String(value)
    }

    /// " drop", " rest-pause", or nothing for a straight set.
    private static func kindSuffix(_ kind: SetKind?) -> String {
        kind.map { " \($0.label)" } ?? ""
    }

    /// The same, with the side it names and its kind: "30 × 8 L",
    /// "50 × 10 drop", "30 × 12 L drop". Nothing added for both, or straight.
    static func text(_ set: RoutinePrescribedSet, side: SetSide?, kind: SetKind? = nil,
                     locale: Locale = .current) -> String {
        numbers(set, locale: locale) + (side.map { " \($0.shortLabel)" } ?? "") + kindSuffix(kind)
    }

    /// What a set prescribes, for deciding whether every set matches. Web
    /// compares the stored set, not its text: 225 and 225.4 print alike and
    /// are not the same prescription.
    private struct Prescribed: Equatable {
        let weightKg: Double?, reps: Int?, rpe: Double?, seconds: Int?, metres: Double?
        let side: SetSide?, kind: SetKind?
    }

    private typealias Row = (set: RoutinePrescribedSet, side: SetSide?, kind: SetKind?)

    private static func prescribed(_ row: Row) -> Prescribed {
        Prescribed(weightKg: row.set.targetWeightKg, reps: row.set.targetReps, rpe: row.set.targetRPE,
                   seconds: row.set.targetDurationSec, metres: row.set.targetDistanceMeters,
                   side: row.side, kind: row.kind)
    }

    private static func allSame(_ rows: [Row]) -> Bool {
        guard let first = rows.first.map(prescribed) else { return false }
        return rows.allSatisfy { prescribed($0) == first }
    }

    /// "3 × 225 × 5" when every set matches, otherwise each set spelled out.
    private static func list(_ rows: [Row], _ text: (Row) -> String) -> String {
        if rows.count > 1, allSame(rows) { return "\(rows.count) × \(text(rows[0]))" }
        return rows.map(text).joined(separator: ", ")
    }

    /// One line for an exercise: "3 × 225 × 5", "3 × 30 × 8 each side",
    /// "3 × 30 × 8 each side + 1 L", "185 × 5, 185 × 5, 95 × 10 R".
    static func summary(_ exercise: RoutineExercise, sides: PrescriptionSides,
                        types: PrescriptionTypes, locale: Locale = .current) -> String {
        let sets = exercise.orderedSets
        guard !sets.isEmpty else { return "no sets yet" }
        let named = sets.map { sides.side(of: $0) }
        let kinds = types.kinds(of: exercise)
        let rows: [Row] = sets.indices.map { (set: sets[$0], side: named[$0], kind: kinds[$0]) }
        let plain = rows.filter { $0.side == nil }
        guard sides.isEachSide(exercise), !plain.isEmpty else {
            return list(rows) { text($0.set, side: $0.side, kind: $0.kind, locale: locale) }
        }

        // The each-side line's unit: a set's numbers and its kind, without
        // its side, which is said once for the whole exercise.
        let plainText: (Row) -> String = { numbers($0.set, locale: locale) + kindSuffix($0.kind) }
        let same = allSame(plain) ? plainText(plain[0]) : nil

        // The named extras, grouped by what they say, in the order they appear.
        var groups: [(side: SetSide, text: String, kind: String, count: Int)] = []
        for row in rows {
            guard let side = row.side else { continue }
            let text = numbers(row.set, locale: locale)
            let kind = kindSuffix(row.kind)
            if let index = groups.firstIndex(where: { $0.side == side && $0.text == text && $0.kind == kind }) {
                groups[index].count += 1
            } else {
                groups.append((side, text, kind, 1))
            }
        }
        let extras = groups.map { group -> String in
            // "+ 1 L" when the extra is the same set, kind and all; its
            // numbers when it is not.
            if group.text + group.kind == same { return " + \(group.count) \(group.side.shortLabel)" }
            return " + " + (group.count > 1 ? "\(group.count) × " : "") + group.text
                + " " + group.side.shortLabel + group.kind
        }
        return list(plain, plainText) + " each side" + extras.joined()
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
