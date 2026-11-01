import Foundation
import SwiftData
import LiftCore

// Set types (PLAN-FORMAT.md "Set types"): supersets and circuits, drop sets and
// rest-pause. Coach web's `prescriptions.js` is the reference implementation,
// as it was for sides, and this file is its port: the same rules, the same
// words. `PrescriptionSides.swift` is the precedent this follows file for file.
//
//   a group   exercises done round by round -- one set of each, then the rest.
//             Two make a superset, three or more a circuit. On the wire `g`,
//             renumbered 1, 2, 3... in order of appearance; adjacency makes
//             the group, not the number, so a group of one is no group and is
//             never written.
//   a kind    how a set follows the one before it: drop (no rest, normally
//             lighter) or rest-pause (a short pause, normally the same
//             weight). On the wire, flags bits 3-4, OR'd with the side. An
//             exercise's first set has no set before it, so it is always
//             straight.

// MARK: - Storage

/// The group an exercise is done in, as a positive integer its neighbours
/// share. Keyed by `RoutineExercise.id` as a plain value, for the reason
/// `EachSideExercise` is: `RoutineExercise` is LiftKit's `@Model`, shared with
/// LIFT iOS, and a property on it is a schema change for both apps. A new
/// Coach entity is a lightweight migration here and nothing at all there.
///
/// Named so it cannot collide with a `LiftCore` entity: SwiftData identifies
/// an entity by its class's simple name (see CLAUDE.md, "`ClientFoodEntry`").
///
/// Storage holds groups as the wire would number them -- runs renumbered 1,
/// 2, 3..., a group of one removed -- because every write goes through
/// `PrescriptionTypes`, which regroups after each join, split and removal.
/// No row is not grouped.
@Model
final class ExerciseGroup {
    var exerciseID: UUID = UUID()
    var group: Int = 0

    init(exerciseID: UUID, group: Int) {
        self.exerciseID = exerciseID
        self.group = group
    }
}

/// A prescribed set that is a drop set or rest-pause. Keyed by
/// `RoutinePrescribedSet.id` for the reason `ExerciseGroup` is. No row is
/// straight, which is what every set written before this means.
@Model
final class PrescribedSetKind {
    var setID: UUID = UUID()
    /// `SetKind.rawValue`. Anything else reads as straight.
    var kindRaw: String = ""

    init(setID: UUID, kind: SetKind) {
        self.setID = setID
        self.kindRaw = kind.rawValue
    }

    var kind: SetKind? { SetKind(rawValue: kindRaw) }
}

// MARK: - A set's kind

/// Drop or rest-pause. `nil` is straight, everywhere: absent is how straight
/// is spelt, in storage, in a backup and on the wire.
enum SetKind: String, CaseIterable, Identifiable {
    /// Done straight after the set before it, with no rest; normally lighter.
    case drop
    /// Done after a short pause, about 15 seconds; normally the same weight.
    case restPause

    var id: String { rawValue }

    /// Bits 3-4 of a plan tuple's `flags`: 1 drop, 2 rest-pause. 0 is
    /// straight, and 3 is never written and reads as straight.
    var planKindBits: Int { self == .drop ? 1 : 2 }

    /// The `flags` value this kind contributes, to be OR'd with the side's:
    /// 8 drop, 16 rest-pause, so a left-side drop set is 10.
    var planFlags: Int { planKindBits << SetKind.planShift }

    static let planShift = 3

    /// The word a set's text ends with: "50 × 10 drop". Coach web's
    /// `kindLabel`.
    var label: String { self == .drop ? "drop" : "rest-pause" }

    /// The editor's control: "Drop", "Rest-pause".
    var displayName: String { self == .drop ? "Drop" : "Rest-pause" }

    /// `"drop"` / `"restPause"` in a backup file, omitted entirely when
    /// straight -- not `"straight"`, not `null`.
    var backupValue: String { rawValue }

    /// Lenient on the way in, as a side is: case and surrounding space are
    /// forgiven, and anything that is not drop or rest-pause -- absent,
    /// `"straight"`, junk from a file another app wrote -- is straight, the
    /// only safe reading of a set nobody described. Coach web's `kindOf`.
    static func fromBackup(_ raw: String?) -> SetKind? {
        guard let raw else { return nil }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "drop": return .drop
        case "restpause": return .restPause
        default: return nil
        }
    }

    /// The kind bits 3-4 of a plan tuple's `flags` say, or nil for straight.
    /// **Masked, never compared**: a left-side drop set arrives as 10, and a
    /// reader testing `flags == 8` would call it straight. A missing,
    /// non-integral or negative `flags` is straight; bit 0 and the side bits
    /// are not this reader's. Coach web's `kindFromFlags`.
    ///
    /// Coach never decodes a plan of its own -- it sends them -- so this is
    /// what the tests read the fixture and the encoder's output with, the
    /// way `PlanSetFlags.sideBits` reads sides.
    static func fromPlanFlags(_ tuple: [Double?]) -> SetKind? {
        guard tuple.count > PlanSetFlags.index, let raw = tuple[PlanSetFlags.index],
              raw.isFinite, raw.rounded() == raw, raw >= 0, raw < 256 else { return nil }
        switch (Int(raw) >> planShift) & 0b11 {
        case 1: return .drop
        case 2: return .restPause
        default: return nil
        }
    }
}

// MARK: - Groups, as rules on a list of numbers

/// What each exercise of a grouped workout is labelled: "Superset A" and
/// "A1". Two exercises are a superset and three or more a circuit; the
/// letters run A, B, C... within the workout and the members are numbered
/// from 1. LIFT's labels, so a coach and their client read the same words.
struct GroupLabel: Equatable {
    /// "Superset A", "Circuit B".
    var group: String
    /// "A1", "B3".
    var member: String
    /// Whether this is the group's first exercise -- where the workout list
    /// names the group once.
    var first: Bool
    var size: Int

    /// "Superset A · A1", the editor's line over a grouped exercise.
    var text: String { "\(group) · \(member)" }
}

/// The group rules, over a workout's stored group numbers in order. Values,
/// with no store and no view in them, for the reason `MacroFields` is one: a
/// rule living in a view cannot be tested, and these decide what a client's
/// phone does round by round. Coach web's `runs`, `regroup`,
/// `groupedWithNext`, `setGroupedWithNext`, `letters` and `groupLabels`, rule
/// for rule.
enum ExerciseGrouping {

    /// A group number as stored or sent: a positive integer, or nil. `0` or a
    /// negative is not grouped.
    static func groupOf(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    /// A `g` as `JSONSerialization` hands it over. Only a JSON number that is
    /// a positive integer is a group: a string, a fraction, a negative, a
    /// boolean, `null` or anything else is not grouped.
    static func groupOf(json value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded() == double, double > 0, double < 1_000_000 else { return nil }
        return Int(double)
    }

    /// The group each position belongs to, as the wire numbers them: runs of
    /// two or more adjacent equal numbers become 1, 2, 3... in order of
    /// appearance, and everything else -- a lone number, a number its
    /// neighbours do not share, no number at all -- is nil.
    ///
    /// So `[7, 7, 3, 3, 3]` is `[1, 1, 2, 2, 2]`, and `[1, nil, 1]` is three
    /// ungrouped exercises: the number only has to differ from its neighbours.
    static func runs(_ numbers: [Int?]) -> [Int?] {
        var out = [Int?](repeating: nil, count: numbers.count)
        var next = 1
        var i = 0
        while i < numbers.count {
            let g = groupOf(numbers[i])
            var j = i + 1
            if let g { while j < numbers.count && groupOf(numbers[j]) == g { j += 1 } }
            if g != nil, j - i >= 2 {
                for k in i..<j { out[k] = next }
                next += 1
            }
            i = j
        }
        return out
    }

    /// Whether position `i` and the one after it are in the same group -- the
    /// "Superset with next" toggle's state.
    static func groupedWithNext(_ numbers: [Int?], at i: Int) -> Bool {
        guard i >= 0, i + 1 < numbers.count, let a = groupOf(numbers[i]) else { return false }
        return groupOf(numbers[i + 1]) == a
    }

    /// Join position `i` to the next, or split them. Joining takes the whole
    /// group the next exercise is in, so "Superset with next" on the exercise
    /// before a superset makes a circuit of three, and joining two groups
    /// makes one. Splitting keeps the exercises before the split in their
    /// group and gives the rest one of their own, so splitting a circuit of
    /// three after its first leaves a superset. Either way the result is as
    /// the wire would number it: a group left with one member is gone.
    /// The last position has no next, and asking changes nothing.
    static func settingGroupedWithNext(_ numbers: [Int?], at i: Int, _ on: Bool) -> [Int?] {
        guard i >= 0, i + 1 < numbers.count else { return numbers }
        var list = runs(numbers)
        let a = list[i]
        let b = list[i + 1]
        let fresh = (list.compactMap { $0 }.max() ?? 0) + 1
        if on {
            if let a, a == b { return list }
            let target = a ?? b ?? fresh
            list[i] = target
            list[i + 1] = target
            var j = i + 2
            while let b, j < list.count, list[j] == b {
                list[j] = target
                j += 1
            }
        } else {
            guard let a, a == b else { return list }
            var j = i + 1
            while j < list.count, list[j] == a {
                list[j] = fresh
                j += 1
            }
        }
        return runs(list)
    }

    /// Spreadsheet letters: 0 is A, 25 Z, 26 AA. A day with 27 groups is not
    /// likely, but a label must never be blank.
    static func letters(_ n: Int) -> String {
        var out = ""
        var x = n + 1
        while x > 0 {
            let scalar = UnicodeScalar(UInt8(65 + (x - 1) % 26))
            out = String(Character(scalar)) + out
            x = (x - 1) / 26
        }
        return out
    }

    /// Each position's label, or nil when it is not grouped.
    static func labels(_ numbers: [Int?]) -> [GroupLabel?] {
        let groups = runs(numbers)
        var sizes: [Int: Int] = [:]
        for g in groups.compactMap({ $0 }) { sizes[g, default: 0] += 1 }
        var seen: [Int: Int] = [:]
        return groups.map { g in
            guard let g else { return nil }
            let letter = letters(g - 1)
            seen[g, default: 0] += 1
            let size = sizes[g] ?? 0
            return GroupLabel(group: (size >= 3 ? "Circuit " : "Superset ") + letter,
                              member: letter + String(seen[g] ?? 0),
                              first: seen[g] == 1, size: size)
        }
    }
}

// MARK: - What the store holds

/// Every group and kind a coach has prescribed, read once and threaded down,
/// as `PrescriptionSides` is.
struct PrescriptionTypes: Equatable {
    var groups: [UUID: Int] = [:]
    var kinds: [UUID: SetKind] = [:]

    init(groups: [UUID: Int] = [:], kinds: [UUID: SetKind] = [:]) {
        self.groups = groups
        self.kinds = kinds
    }

    init(groupRows: [ExerciseGroup], kindRows: [PrescribedSetKind]) {
        for row in groupRows {
            if let g = ExerciseGrouping.groupOf(row.group) { groups[row.exerciseID] = g }
        }
        for row in kindRows {
            if let kind = row.kind { kinds[row.setID] = kind }
        }
    }

    /// Everything in `context`'s store, or nothing when there is no context.
    static func load(from context: ModelContext?) -> PrescriptionTypes {
        guard let context else { return PrescriptionTypes() }
        return PrescriptionTypes(
            groupRows: (try? context.fetch(FetchDescriptor<ExerciseGroup>())) ?? [],
            kindRows: (try? context.fetch(FetchDescriptor<PrescribedSetKind>())) ?? [])
    }

    /// The stored group numbers of a workout's exercises, in order.
    func storedGroups(_ exercises: [RoutineExercise]) -> [Int?] {
        exercises.map { groups[$0.id] }
    }

    /// The group each exercise is sent in, as the wire numbers them.
    func wireGroups(_ exercises: [RoutineExercise]) -> [Int?] {
        ExerciseGrouping.runs(storedGroups(exercises))
    }

    func labels(_ exercises: [RoutineExercise]) -> [GroupLabel?] {
        ExerciseGrouping.labels(storedGroups(exercises))
    }

    func groupedWithNext(_ exercises: [RoutineExercise], at index: Int) -> Bool {
        ExerciseGrouping.groupedWithNext(wireGroups(exercises), at: index)
    }

    /// The kind each of an exercise's sets is, in order. The first set is
    /// always straight -- there is no set before it to drop from or pause
    /// after -- whatever a row might say, so the encoder, the summary and the
    /// backup cannot disagree about it.
    func kinds(of exercise: RoutineExercise) -> [SetKind?] {
        exercise.orderedSets.enumerated().map { $0.offset == 0 ? nil : kinds[$0.element.id] }
    }

    /// Whether the exercise's editor shows the Straight / Drop / Rest-pause
    /// control without being asked: a set after the first already has a kind.
    func showsKinds(_ exercise: RoutineExercise) -> Bool {
        kinds(of: exercise).contains { $0 != nil }
    }

    // MARK: Writes

    /// Join exercise `index` of `routine` to the next, or split them --
    /// `ExerciseGrouping.settingGroupedWithNext`, written to the store.
    static func setGroupedWithNext(_ on: Bool, at index: Int, in routine: Routine,
                                   context: ModelContext) {
        let exercises = routine.orderedExercises
        let current = load(from: context).storedGroups(exercises)
        write(ExerciseGrouping.settingGroupedWithNext(current, at: index, on),
              to: exercises, in: context)
    }

    /// Rewrite a workout's stored groups the way the wire would number them:
    /// runs renumbered 1, 2, 3..., a group of one removed. Run after anything
    /// that changes which exercises are neighbours, so storage never holds a
    /// group that would not be sent.
    static func regroup(_ routine: Routine, in context: ModelContext) {
        let exercises = routine.orderedExercises
        write(ExerciseGrouping.runs(load(from: context).storedGroups(exercises)),
              to: exercises, in: context)
    }

    private static func write(_ groups: [Int?], to exercises: [RoutineExercise], in context: ModelContext) {
        let ids = Set(exercises.map(\.id))
        var rows: [UUID: [ExerciseGroup]] = [:]
        for row in (try? context.fetch(FetchDescriptor<ExerciseGroup>())) ?? [] where ids.contains(row.exerciseID) {
            rows[row.exerciseID, default: []].append(row)
        }
        for (exercise, group) in zip(exercises, groups) {
            var existing = rows[exercise.id] ?? []
            guard let group = ExerciseGrouping.groupOf(group) else {
                existing.forEach(context.delete)
                continue
            }
            if let first = existing.first {
                if first.group != group { first.group = group }
                existing.removeFirst()
                existing.forEach(context.delete)
            } else {
                context.insert(ExerciseGroup(exerciseID: exercise.id, group: group))
            }
        }
    }

    /// `nil` is straight: the row goes, rather than a "straight" being
    /// written down.
    static func setKind(_ kind: SetKind?, for setID: UUID, in context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<PrescribedSetKind>(
            predicate: #Predicate { $0.setID == setID }))) ?? []
        existing.forEach(context.delete)
        if let kind { context.insert(PrescribedSetKind(setID: setID, kind: kind)) }
    }

    /// The rows naming one exercise and its sets, for
    /// `PrescriptionSides.removeExercise`. The caller regroups what is left.
    static func sweep(exerciseID: UUID, setIDs: Set<UUID>, in context: ModelContext) {
        for row in (try? context.fetch(FetchDescriptor<ExerciseGroup>())) ?? []
        where row.exerciseID == exerciseID {
            context.delete(row)
        }
        sweep(setIDs: setIDs, in: context)
    }

    static func sweep(setIDs: Set<UUID>, in context: ModelContext) {
        guard !setIDs.isEmpty else { return }
        for row in (try? context.fetch(FetchDescriptor<PrescribedSetKind>())) ?? []
        where setIDs.contains(row.setID) {
            context.delete(row)
        }
    }

    /// A set that has just become an exercise's first loses its kind: there
    /// is no set before it any more.
    static func clearFirstKind(of exercise: RoutineExercise?, in context: ModelContext) {
        guard let first = exercise?.orderedSets.first else { return }
        sweep(setIDs: [first.id], in: context)
    }

    /// The rows naming this routine's exercises and sets. No delete rule
    /// reaches them -- they hold ids, not relationships -- so
    /// `ScheduledSession.deleteRoutineAndSessions` calls this beside
    /// `PrescriptionSides.deleteAll`.
    static func deleteAll(for routine: Routine, in context: ModelContext) {
        let exerciseIDs = Set(routine.orderedExercises.map(\.id))
        let setIDs = Set(routine.orderedExercises.flatMap(\.orderedSets).map(\.id))
        for row in (try? context.fetch(FetchDescriptor<ExerciseGroup>())) ?? []
        where exerciseIDs.contains(row.exerciseID) {
            context.delete(row)
        }
        sweep(setIDs: setIDs, in: context)
    }
}
