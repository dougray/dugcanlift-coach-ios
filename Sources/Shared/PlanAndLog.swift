import Foundation
import LiftCore

/// What the coach booked, beside what the client logged.
///
/// Coach holds both halves -- it wrote the plan and it decoded the log -- and
/// joined them nowhere, so a coach could not see that Friday never happened,
/// or that the split squats came in at five reps on the left when eight were
/// asked for. This is the join.
///
/// A value type with no view in it, for the reason `ClientRemoval`,
/// `LinkImportMacros` and `LiftProgression` are: this decides whether a coach
/// is told something true. **Coach web's `plan-log.js` is the reference
/// implementation**, as `sides.js` and `prescriptions.js` are; this is a port
/// of it, and `Tests/Fixtures/plan-log-expected.json` is web's own fixture,
/// shared by all three Coach builds and never regenerated from Swift.
///
/// **Counting is allowed; grading is not.** This says how many days were
/// booked and how many were logged, side by side, and stops. There is no
/// score, no percentage, no colour on an absence, no roster column, nothing
/// carried across weeks and nothing comparing one client to another. The words
/// are `not logged`, never "missed" or "skipped": a client may have trained
/// and not sent, been ill, or been told to rest, and Coach cannot tell those
/// apart. `outside the log they sent` is a fourth state and exists so the
/// third is never claimed wrongly. The word "adherence" never reaches a
/// screen. `lines(_:)` exists so both of those are testable as strings.
///
/// **Nothing new travels.** SHARE-FORMAT and PLAN-FORMAT are unchanged; this
/// works from what Coach sent and the log the client already chose to send, so
/// it reads every LIFT build in the field, including ones that will never
/// update, and one a client never opened. The cost, stated: a session lifted
/// the day after it was booked is a booked day with nothing logged plus a
/// session of its own. They sit next to each other on screen where a coach can
/// read what happened, and Coach claims no connection between them -- that
/// join is the trainer's to make.
enum PlanAndLog {

    /// Permanently under the card, whatever is above it: Coach knows what it
    /// put on a share sheet and nothing after that.
    static let footer = "This is what you shared. Whether it arrived, and whether they "
        + "opened it, only they know."

    // MARK: - What goes in

    /// One prescribed or logged set, in the same shape -- PLAN-FORMAT's set
    /// tuple and SHARE-FORMAT's are deliberately the same six fields "so
    /// nothing has to be transposed to compare what was asked for against what
    /// was done", and this is what that sentence was written for.
    struct SetValues: Equatable {
        var weightLb: Double?
        var reps: Double?
        var rpe: Double?
        var durationSec: Double?
        var distanceM: Double?
        var side: SetSide?
        var isWarmup: Bool

        init(weightLb: Double? = nil, reps: Double? = nil, rpe: Double? = nil,
             durationSec: Double? = nil, distanceM: Double? = nil,
             side: SetSide? = nil, isWarmup: Bool = false) {
            self.weightLb = weightLb
            self.reps = reps
            self.rpe = rpe
            self.durationSec = durationSec
            self.distanceM = distanceM
            self.side = side
            self.isWarmup = isWarmup
        }
    }

    /// A lift on either side of the join, its sets pooled.
    struct Exercise: Equatable {
        var key: String
        var name: String
        var equipment: String
        var eachSide: Bool
        var sets: [SetValues]
    }

    /// A day the client logged, as the store holds it.
    struct LoggedDay: Equatable {
        var name: String
        var exercises: [Exercise]

        init(name: String = "", exercises: [Exercise]) {
            self.name = name
            self.exercises = exercises
        }
    }

    /// A day one sent plan books, pooled where a payload books two sessions on
    /// one date -- SHARE-FORMAT gives a day one `w` array, so the log has
    /// already merged two sessions into one before Coach sees it, and the
    /// asked side has to be read the same way.
    struct Booking: Equatable {
        var date: String
        var name: String
        var exercises: [Exercise]
    }

    /// A `SentPlan` as this rule reads one: its id, when it went, and the
    /// payload. Taking the decoded payload rather than the model keeps
    /// SwiftData out of the rule.
    struct StoredPlan {
        var id: String
        var clientID: String
        var sentAtEpochSec: Int
        var payload: PlanPayload

        init(id: String, clientID: String, sentAtEpochSec: Int, payload: PlanPayload) {
            self.id = id
            self.clientID = clientID
            self.sentAtEpochSec = sentAtEpochSec
            self.payload = payload
        }
    }

    // MARK: - What comes out

    enum DayState: String, Equatable { case logged, notLogged, outside, notBooked }
    enum ExerciseState: String, Equatable { case logged, notLogged }

    /// One side's sets -- "L 40 × 8 · 40 × 8 · 40 × 5" -- or one unlabelled
    /// group when nothing is sided.
    struct SetGroup: Equatable {
        var label: String
        var text: String
    }

    /// An Asked or a Logged row. `suffix` carries "each side", which is a
    /// clause on the ask and not a set of its own: a view that draws the
    /// groups and forgets the clause prints a plan asking for half of what it
    /// asks for.
    struct SetRow: Equatable {
        var label: String
        var groups: [SetGroup]
        var suffix: String
        var text: String
    }

    struct ExerciseRow: Equatable {
        var key: String
        /// The lift on its own, for a heading that is about the lift and not
        /// about one day of it.
        var lift: String
        var title: String
        var state: ExerciseState
        var substitution: String?
        var sideLine: String?
        var countLine: String?
        var asked: SetRow?
        var logged: SetRow?
    }

    /// A lift the log has and the plan does not: its name and how many working
    /// sets it carried, counted against nothing.
    struct AlsoLoggedRow: Equatable {
        var key: String
        var title: String
        var text: String
    }

    struct Counts: Equatable {
        var booked = 0
        var logged = 0
        var notLogged = 0
        var outside = 0
        var other = 0
    }

    struct DayRow: Equatable {
        var key: String
        var state: DayState
        var name: String
        var text: String
        var exercises: [ExerciseRow]
        var alsoLogged: [AlsoLoggedRow]
        /// What this day booked, whatever became of it. The day view does not
        /// draw these on a day nobody logged -- the row above already says so,
        /// and reciting the prescription under it turns a fact into a list of
        /// what someone did not do. The by-lift view does need them: a lift
        /// shown only on the weeks it was logged reads steadier than it was.
        var booked: [ExerciseRow]
    }

    struct Group: Equatable {
        var id: String
        var sentAt: Int
        var from: String
        var to: String
        var range: String
        var counts: Counts
        var head: String
        var days: [DayRow]
    }

    struct LiftEntry: Equatable {
        var key: String
        var when: String
        var exercise: ExerciseRow
    }

    struct Lift: Equatable {
        var key: String
        var title: String
        var entries: [LiftEntry]
    }

    struct Result: Equatable {
        var groups: [Group]
        var byLift: [Lift]
        var footer: String
    }

    // MARK: - The join

    /// Every sent plan against the log.
    ///
    /// Days join on client and date. **Nothing else, and no window.** A client
    /// who does Friday's work on Saturday is the case everyone asks about, and
    /// the honest answer is that Coach cannot know they did: the card puts the
    /// two facts on the same seven days and says nothing about cause.
    ///
    /// The eight weeks are the Weeks table's own window, so the card and the
    /// table look at the same stretch. A group is one send, and its range is
    /// the first and last day that send booked -- not a calendar week, because
    /// a coach sends the days they book.
    static func compare(clientID: String,
                        sentPlans: [StoredPlan],
                        days: [String: LoggedDay],
                        coverage: CoveredRange?,
                        unit: String,
                        today: String,
                        weeks: Int = 8,
                        locale: Locale = .current) -> Result {
        let from = DayKey.adding(days: -(7 * weeks - 1), to: today) ?? today
        var groups: [Group] = []

        // This client's rows, newest first -- the order the card reads in.
        for plan in sentPlans.filter({ $0.clientID == clientID })
            .sorted(by: { $0.sentAtEpochSec > $1.sentAtEpochSec }) {
            let booked = bookings(in: plan.payload).filter { $0.date >= from && $0.date <= today }
            guard let first = booked.first?.date, let last = booked.last?.date else { continue }

            let bookedDates = Set(booked.map(\.date))
            var counts = Counts()
            counts.booked = booked.count

            var rows: [DayRow] = booked.map { booking in
                let day = days[booking.date]
                let state: DayState
                if !(coverage?.covers(booking.date) ?? false) {
                    state = .outside
                    counts.outside += 1
                } else if hasTraining(day) {
                    state = .logged
                    counts.logged += 1
                } else {
                    state = .notLogged
                    counts.notLogged += 1
                }

                let word = self.word(for: state)
                let joined = state == .logged
                    ? join(asked: booking.exercises, logged: working(in: day), unit: unit, locale: locale)
                    : (exercises: [ExerciseRow](), alsoLogged: [AlsoLoggedRow]())
                return DayRow(
                    key: booking.date,
                    state: state,
                    name: booking.name,
                    text: [dayLabel(booking.date, locale: locale), booking.name, word]
                        .filter { !$0.isEmpty }.joined(separator: " · "),
                    exercises: joined.exercises,
                    alsoLogged: joined.alsoLogged,
                    booked: state == .logged ? [] : booking.exercises.map {
                        pairRow(asked: $0, logged: nil, unit: unit, substituted: false,
                                absentWord: word, locale: locale)
                    })
            }

            // A day inside this send's span that was trained and not booked.
            // Shown beside the bookings, saying nothing about cause: a session
            // lifted the day after the one it was booked for looks exactly
            // like this, and so does a session the client added themselves.
            for key in days.keys.sorted() {
                guard key >= first, key <= last, !bookedDates.contains(key),
                      let day = days[key], hasTraining(day) else { continue }
                counts.other += 1
                rows.append(DayRow(
                    key: key,
                    state: .notBooked,
                    name: day.name,
                    text: [dayLabel(key, locale: locale), day.name, "not booked"]
                        .filter { !$0.isEmpty }.joined(separator: " · "),
                    exercises: [],
                    alsoLogged: working(in: day).filter { !$0.sets.isEmpty }.map(alsoLoggedRow),
                    booked: []))
            }
            rows.sort { $0.key < $1.key }

            let range = rangeText(from: first, to: last, locale: locale)
            groups.append(Group(id: plan.id, sentAt: plan.sentAtEpochSec, from: first, to: last,
                                range: range, counts: counts,
                                head: headLine(range: range, counts: counts),
                                days: rows))
        }

        return Result(groups: groups, byLift: byLift(groups, locale: locale), footer: footer)
    }

    /// The same lines grouped the other way: each prescribed lift across the
    /// sent weeks, its asked and logged rows stacked by date. Same rules, same
    /// strings -- a regrouping of what `compare` already decided, not a second
    /// opinion about it, and it still carries nothing across weeks beyond
    /// putting the days under one heading.
    private static func byLift(_ groups: [Group], locale: Locale) -> [Lift] {
        var order: [String] = []
        var byKey: [String: Lift] = [:]
        for group in groups {
            for day in group.days {
                for exercise in day.exercises + day.booked {
                    if byKey[exercise.key] == nil {
                        byKey[exercise.key] = Lift(key: exercise.key, title: "", entries: [])
                        order.append(exercise.key)
                    }
                    byKey[exercise.key]?.entries.append(
                        LiftEntry(key: day.key, when: dayMonth(day.key, locale: locale),
                                  exercise: exercise))
                }
            }
        }
        return order.compactMap { key in
            guard var lift = byKey[key] else { return nil }
            lift.entries.sort { $0.key < $1.key }
            // The heading is the lift, without the per-day clause: whether one
            // day of it was logged belongs to that day and not to the lift.
            lift.title = lift.entries.first?.exercise.lift ?? ""
            return lift
        }
    }

    // MARK: - Reading a sent payload

    /// Every day a payload books, in date order.
    static func bookings(in payload: PlanPayload) -> [Booking] {
        let workouts = payload.w ?? []
        var names: [String: [String]] = [:]
        var exercises: [String: [Exercise]] = [:]
        var order: [String] = []

        for entry in payload.k ?? [] {
            guard workouts.indices.contains(entry.x) else { continue }
            let workout = workouts[entry.x]
            if exercises[entry.d] == nil {
                exercises[entry.d] = []
                names[entry.d] = []
                order.append(entry.d)
            }
            let name = workout.n.isEmpty ? "Session" : workout.n
            names[entry.d]?.append(name)
            exercises[entry.d]?.append(contentsOf: workout.e.map(asked))
        }

        return order.sorted().map { date in
            Booking(date: date, name: (names[date] ?? []).joined(separator: " · "),
                    exercises: pooled(exercises[date] ?? []))
        }
    }

    /// One prescribed exercise off the wire.
    private static func asked(_ wire: PlanWorkoutExercise) -> Exercise {
        let name = wire.n.isEmpty ? "Exercise" : wire.n
        let equipment = wire.q ?? ""
        return Exercise(
            key: matchKey(name: name, equipment: equipment),
            name: name, equipment: equipment,
            eachSide: wire.isEachSide,
            sets: wire.s.map { tuple in
                SetValues(weightLb: value(0, tuple), reps: value(1, tuple), rpe: value(2, tuple),
                          durationSec: value(3, tuple), distanceM: value(4, tuple),
                          // Masked, never compared -- the kit's own reader.
                          side: PlanSetFlags.sideBits(of: tuple).flatMap {
                              $0 == 1 ? .left : $0 == 2 ? .right : nil
                          },
                          isWarmup: false)
            })
    }

    private static func value(_ index: Int, _ tuple: [Double?]) -> Double? {
        index < tuple.count ? tuple[index] : nil
    }

    /// A logged day's exercises with its warmups dropped. Warmups are excluded
    /// on both sides -- masked, never compared, because a left-side warmup
    /// arrives as 3 and `flags == 1` would read it as a working set -- and a
    /// plan never prescribes one.
    private static func working(in day: LoggedDay?) -> [Exercise] {
        pooled((day?.exercises ?? []).map { exercise in
            var stripped = exercise
            stripped.sets = exercise.sets.filter { !$0.isWarmup }
            return stripped
        })
    }

    /// Exercises pooled by name and equipment, keeping first-seen order. The
    /// same key prescribed twice in a day, or logged twice in a day, is one
    /// lift of more sets.
    private static func pooled(_ list: [Exercise]) -> [Exercise] {
        var order: [String] = []
        var byKey: [String: Exercise] = [:]
        for exercise in list {
            if byKey[exercise.key] == nil {
                byKey[exercise.key] = Exercise(key: exercise.key, name: exercise.name,
                                               equipment: exercise.equipment,
                                               eachSide: exercise.eachSide, sets: [])
                order.append(exercise.key)
            }
            // Each side is a property of the lift, not of one booking of it:
            // if either says each side, the sets pooled under it are each side.
            if exercise.eachSide { byKey[exercise.key]?.eachSide = true }
            byKey[exercise.key]?.sets.append(contentsOf: exercise.sets)
        }
        return order.compactMap { byKey[$0] }
    }

    private static func hasTraining(_ day: LoggedDay?) -> Bool {
        !(day?.exercises.isEmpty ?? true)
    }

    // MARK: - Joining one day

    /// The prescribed and the logged exercises of one day, joined.
    ///
    /// Two passes, in this order, so an exact match always wins:
    ///   1. name and equipment -- a cable pulldown and a machine pulldown are
    ///      not the same lift and a coach prescribing one of them meant it.
    ///   2. name alone, over what is left on each side: the equipment
    ///      substitution, paired and labelled.
    /// Never by position: a client who skips the second exercise would shift
    /// every pairing after it.
    private static func join(asked: [Exercise], logged: [Exercise], unit: String,
                             locale: Locale) -> (exercises: [ExerciseRow], alsoLogged: [AlsoLoggedRow]) {
        var remaining = logged
        func take(_ matches: (Exercise) -> Bool) -> Exercise? {
            guard let index = remaining.firstIndex(where: matches) else { return nil }
            return remaining.remove(at: index)
        }

        var pairs: [(asked: Exercise, logged: Exercise?, substituted: Bool)] = asked.map { exercise in
            let match = take { candidate in candidate.key == exercise.key }
            return (exercise, match, false)
        }
        for index in pairs.indices where pairs[index].logged == nil {
            let wanted = nameKey(pairs[index].asked.name)
            if let match = take({ nameKey($0.name) == wanted }) {
                pairs[index].logged = match
                pairs[index].substituted = true
            }
        }

        return (
            exercises: pairs.map {
                pairRow(asked: $0.asked, logged: $0.logged, unit: unit,
                        substituted: $0.substituted, absentWord: "not logged", locale: locale)
            },
            // Working sets are the claim everywhere else here, so a lift
            // nobody asked for that came back as warmups alone is not
            // "0 sets" on screen.
            alsoLogged: remaining.filter { !$0.sets.isEmpty }.map(alsoLoggedRow))
    }

    private static func alsoLoggedRow(_ exercise: Exercise) -> AlsoLoggedRow {
        AlsoLoggedRow(key: exercise.key, title: title(exercise),
                      text: title(exercise) + " · " + plural(exercise.sets.count, "set", "sets"))
    }

    /// One lift's asked row above its logged row.
    ///
    /// `absentWord` is what a lift with nothing logged against it says: "not
    /// logged" on a day the client sent, "outside the log they sent" on a day
    /// they did not. The second exists so the first is never claimed wrongly.
    private static func pairRow(asked: Exercise, logged: Exercise?, unit: String,
                                substituted: Bool, absentWord: String, locale: Locale) -> ExerciseRow {
        let side = sideLine(asked: asked, logged: logged)
        let askedSets = asked.sets
        let loggedSets = logged?.sets ?? []
        let lift = title(asked) + (asked.eachSide ? " · each side" : "")

        var row = ExerciseRow(
            key: asked.key, lift: lift, title: lift,
            state: logged == nil ? .notLogged : .logged,
            substitution: substituted && logged != nil
                ? "Asked \(equipmentWord(asked.equipment)) · logged \(equipmentWord(logged?.equipment ?? ""))"
                : nil,
            sideLine: side,
            countLine: nil,
            // A lift with nothing logged against it is one line and no rows:
            // the day row above already says the session was not logged, and
            // repeating the prescription under every lift of a missed day
            // turns a fact into a recital of what someone did not do.
            asked: logged != nil && !askedSets.isEmpty
                ? setRow(label: "Asked", sets: askedSets, unit: unit,
                         suffix: asked.eachSide ? " each side" : "", locale: locale)
                : nil,
            logged: logged != nil
                ? setRow(label: "Logged", sets: loggedSets, unit: unit, suffix: "", locale: locale)
                : nil)

        // How many were asked for and how many came back, when they differ and
        // there is no side line already saying it per side.
        if logged != nil, side == nil, askedSets.count != loggedSets.count {
            row.countLine = "Asked \(plural(askedSets.count, "set", "sets")) · logged \(loggedSets.count)"
        }
        if logged == nil { row.title += " · " + absentWord }
        return row
    }

    private static func setRow(label: String, sets: [SetValues], unit: String,
                               suffix: String, locale: Locale) -> SetRow {
        let groups = setGroups(sets, unit: unit, locale: locale)
        return SetRow(label: label, groups: groups, suffix: suffix,
                      text: groupsText(groups) + suffix)
    }

    /// The side counts LIFT already shows in its own header: "L 3/3 · R 2/3",
    /// the logged count over what the prescription asks for. Over is shown as
    /// over -- "L 4/3", never capped. An each-side exercise's ask is twice its
    /// tuples, which `PrescribedTargets` already works out. An exercise with no
    /// side on either half gets no line at all.
    ///
    /// Printed, not judged. Coach does no arithmetic on the difference between
    /// the two numbers; "three reps short on the left every time" is what a
    /// coach reads off the two rows, not a number this computes.
    private static func sideLine(asked: Exercise, logged: Exercise?) -> String? {
        let targets = PrescribedTargets(sides: asked.sets.map(\.side), eachSide: asked.eachSide)
        let counts = PrescribedTargets(sides: (logged?.sets ?? []).map(\.side), eachSide: false)
        guard targets.left != 0 || targets.right != 0 || counts.left != 0 || counts.right != 0
        else { return nil }
        var text = "L \(counts.left)/\(targets.left) · R \(counts.right)/\(targets.right)"
        // Sets logged with no side are still real work. Saying so beats
        // leaving them out.
        if counts.both > 0 { text += " · \(counts.both) both" }
        return text
    }

    // MARK: - How a set reads

    /// Sets as one group per side, or a single unlabelled group when nothing
    /// is sided. Sets are listed, never paired one to one with the asked row:
    /// if they did three of four sets, Coach cannot say which one they
    /// dropped, so it does not.
    static func setGroups(_ sets: [SetValues], unit: String, locale: Locale = .current) -> [SetGroup] {
        guard sets.contains(where: { $0.side != nil }) else {
            return sets.isEmpty ? []
                : [SetGroup(label: "",
                            text: sets.map { setText($0, unit: unit, locale: locale) }
                                .joined(separator: " · "))]
        }
        var groups: [SetGroup] = []
        for side in [SetSide.left, SetSide.right, nil] {
            let mine = sets.filter { $0.side == side }
            guard !mine.isEmpty else { continue }
            groups.append(SetGroup(
                label: side?.shortLabel ?? "Both",
                text: mine.map { setText($0, unit: unit, locale: locale) }.joined(separator: " · ")))
        }
        return groups
    }

    static func groupsText(_ groups: [SetGroup]) -> String {
        groups.map { ($0.label.isEmpty ? "" : $0.label + " ") + $0.text }.joined(separator: "   ")
    }

    /// One set, asked or logged, in the same shape.
    ///
    /// **Both rows come from pounds** -- the stored payload's and the wire's
    /// -- converted once here through `ClientDisplay`. Never from a
    /// `RoutinePrescribedSet`, which stores kilograms: an asked row in kg above
    /// a logged row in lb would be two units in one card, silently and 2.2x
    /// wrong.
    ///
    /// **Blank stays blank.** `[null, 5]` is "5 reps", never "0 × 5".
    static func setText(_ set: SetValues, unit: String, locale: Locale = .current) -> String {
        var bits: [String] = []
        if let weight = set.weightLb, let reps = set.reps {
            bits.append("\(weightText(weight, unit: unit, locale: locale)) × \(number(reps))")
        } else if let reps = set.reps {
            bits.append("\(number(reps)) reps")
        } else if let weight = set.weightLb {
            bits.append("\(weightText(weight, unit: unit, locale: locale)) \(unit)")
        }
        if let distance = set.distanceM {
            bits.append("\(rounded(distance, locale: locale)) m")
        }
        if let seconds = set.durationSec {
            let minutes = Int((seconds / 60).rounded(.down))
            bits.append(minutes > 0
                ? String(format: "%d:%02d", minutes, Int(seconds) % 60)
                : "\(number(seconds))s")
        }
        if let rpe = set.rpe { bits.append("@\(number(rpe))") }
        return bits.isEmpty ? "as written" : bits.joined(separator: " · ")
    }

    /// A stored pound weight in the client's own unit, rounded to a whole
    /// number as Coach web rounds it. `ClientDisplay` owns the conversion;
    /// nothing converted ever reaches storage or a comparison.
    private static func weightText(_ lb: Double, unit: String, locale: Locale) -> String {
        rounded(ClientDisplay.weightValue(lb: lb, unit: unit), locale: locale)
    }

    /// `Math.round(n).toLocaleString()` -- grouped in the reader's own locale,
    /// because that is what the browser does with `undefined`.
    private static func rounded(_ value: Double, locale: Locale) -> String {
        guard value.isFinite else { return "0" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value.rounded())) ?? "\(Int(value.rounded()))"
    }

    /// A number as JavaScript prints one: no decimal point when it has none.
    /// Reps, RPE and seconds come off the wire as numbers and are printed, not
    /// rounded -- 4.5 reps is what the client logged.
    private static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(value)
    }

    // MARK: - Words

    private static func title(_ exercise: Exercise) -> String {
        exercise.equipment.isEmpty ? exercise.name : "\(exercise.name) (\(exercise.equipment))"
    }

    private static func equipmentWord(_ equipment: String) -> String {
        equipment.isEmpty ? "no equipment" : equipment
    }

    private static func plural(_ count: Int, _ one: String, _ many: String) -> String {
        "\(count) \(count == 1 ? one : many)"
    }

    private static func word(for state: DayState) -> String {
        switch state {
        case .logged: return "logged"
        case .notLogged: return "not logged"
        case .outside: return "outside the log they sent"
        case .notBooked: return "not booked"
        }
    }

    static func headLine(range: String, counts: Counts) -> String {
        var head = "Booked \(plural(counts.booked, "day", "days")), \(range)"
        if counts.outside == counts.booked { return head + " · no log covering them" }
        head += " · logged \(counts.logged)"
        if counts.outside > 0 { head += " · \(counts.outside) outside the log they sent" }
        if counts.other > 0 {
            head += " · " + plural(counts.other, "other day logged", "other days logged")
        }
        return head
    }

    // MARK: - Keys

    /// The join key: `ClientDisplay.exerciseKey`'s own spelling -- name and
    /// equipment, because a cable pulldown and a machine pulldown are not the
    /// same lift and a coach prescribing one of them meant it -- folded for
    /// matching, as Coach web folds it.
    static func matchKey(name: String, equipment: String) -> String {
        ClientDisplay.exerciseKey(name: name.trimmingCharacters(in: .whitespaces),
                                  equipment: equipment.trimmingCharacters(in: .whitespaces))
            .lowercased()
    }

    private static func nameKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).lowercased()
    }

    // MARK: - Dates

    /// "Mon 13 Oct" -- a day row carries its month, so a row read on its own,
    /// or beside a row from the week before, says which day it is without the
    /// head line above it having to be read again. Day-then-month for the
    /// reason `dayMonth` is.
    static func dayLabel(_ key: String, locale: Locale = .current) -> String {
        guard let weekday = text(key, locale: locale, style: .weekday) else { return key }
        return "\(weekday) \(dayMonth(key, locale: locale))"
    }

    /// "13 Oct" -- for the by-lift view, where rows cross weeks. Written
    /// day-then-month by hand rather than through a locale's own ordering,
    /// because "12–18 Oct" has to read as a range and a US ordering would put
    /// the month in the middle of it. Coach web does the same.
    static func dayMonth(_ key: String, locale: Locale = .current) -> String {
        guard let month = text(key, locale: locale, style: .month), let day = dayNumber(key)
        else { return key }
        return "\(day) \(month)"
    }

    /// "12–18 Oct", "28 Sep–4 Oct", "12 Oct" for a single day.
    static func rangeText(from: String, to: String, locale: Locale = .current) -> String {
        if from == to { return dayMonth(from, locale: locale) }
        let left = parts(from), right = parts(to)
        if let left, let right, left.year == right.year, left.month == right.month,
           let day = dayNumber(from) {
            return "\(day)–\(dayMonth(to, locale: locale))"
        }
        return "\(dayMonth(from, locale: locale))–\(dayMonth(to, locale: locale))"
    }

    private enum DateStyle { case weekday, month }

    /// Formatted in the reader's own locale, because that is what Coach web's
    /// `toLocaleDateString(undefined, ...)` does. Noon UTC with the style's
    /// time zone pinned to match, as `RoadFoodDates` already does: a day key
    /// is a calendar day and not an instant.
    private static func text(_ key: String, locale: Locale, style: DateStyle) -> String? {
        guard let parts = parts(key) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: DateComponents(
            year: parts.year, month: parts.month, day: parts.day, hour: 12)) else { return nil }
        var format = Date.FormatStyle(date: .omitted, time: .omitted)
        format = style == .weekday ? format.weekday(.abbreviated) : format.month(.abbreviated)
        format = format.locale(locale)
        format.timeZone = calendar.timeZone
        return date.formatted(format)
    }

    private static func dayNumber(_ key: String) -> Int? { parts(key)?.day }

    private static func parts(_ key: String) -> (year: Int, month: Int, day: Int)? {
        let pieces = key.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3, let year = Int(pieces[0]), let month = Int(pieces[1]),
              let day = Int(pieces[2]), (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        return (year, month, day)
    }

    // MARK: - Every sentence, flattened

    /// Every sentence this card can produce, in the order a coach reads them.
    /// The line-discipline tests run over this rather than over a view, so a
    /// string that judges a client fails a test the day it is written rather
    /// than the day someone notices it on screen.
    static func lines(_ result: Result) -> [String] {
        var out: [String] = []
        for group in result.groups {
            out.append(group.head)
            for day in group.days {
                out.append(day.text)
                for exercise in day.exercises {
                    out.append(contentsOf: exerciseLines(exercise, sayTitle: true))
                }
                if !day.alsoLogged.isEmpty {
                    out.append("Also logged")
                    out.append(contentsOf: day.alsoLogged.map(\.text))
                }
            }
        }
        // The other way round. The same lines under a lift's heading rather
        // than a day's, so the second view is pinned by the same tests as the
        // first rather than being the one place a sentence could slip through.
        if !result.byLift.isEmpty {
            out.append("By lift")
            for lift in result.byLift {
                out.append(lift.title)
                for entry in lift.entries {
                    out.append(entry.when)
                    out.append(contentsOf: exerciseLines(entry.exercise,
                                                         sayTitle: entry.exercise.state != .logged))
                }
            }
        }
        if !out.isEmpty { out.append(result.footer) }
        return out
    }

    private static func exerciseLines(_ exercise: ExerciseRow, sayTitle: Bool) -> [String] {
        var out: [String] = []
        if sayTitle { out.append(exercise.title) }
        if let side = exercise.sideLine { out.append(side) }
        if let count = exercise.countLine { out.append(count) }
        if let asked = exercise.asked { out.append(asked.label + " " + asked.text) }
        if let logged = exercise.logged { out.append(logged.label + " " + logged.text) }
        // Under the pair, as it sits on screen: the substitution line says
        // what the two rows above it are, and reads as nonsense above them.
        if let substitution = exercise.substitution { out.append(substitution) }
        return out
    }
}
