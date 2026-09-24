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
/// **Training is compared; meals are not matched.** A booked meal is a recipe
/// in a slot on a day. What comes back is a day's food entries -- free-typed
/// foods, barcode scans, a recipe logged as a meal -- with no id joining them
/// to anything, names drawn from the client's own food dictionary, and
/// itemisation a choice the client makes per send. Coach therefore says what
/// it booked and what the log holds at that meal, and never that the two are
/// the same dish. Matching a booked recipe to a logged entry by name would be
/// right most of the time, and the times it was wrong it would tell a coach
/// their client ate something they did not -- the one error this card exists
/// to avoid. `mealNote` says so on screen, once, permanently.
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

    /// The one line that keeps the meal rows honest, shown once under a card
    /// that has any, permanently.
    ///
    /// A booked meal is a dish in a slot. A logged day is a list of foods,
    /// named out of the client's own food dictionary, with no id joining the
    /// two. Coach therefore prints what it booked and what the log holds at
    /// that slot, side by side, and stops -- the same move the day rows make
    /// with `not logged` above `not booked`. The join is the trainer's, and
    /// this says so.
    static let mealNote = "A meal row says what the log holds at that meal. Whether it "
        + "was this dish, only they know."

    /// PLAN-FORMAT's `m.s`: 0 breakfast, 1 lunch, 2 dinner, 3 snack. The same
    /// four words, in the same order, that SHARE-FORMAT's `f` meal position
    /// indexes -- which is the only reason a booked slot and a logged entry
    /// can be put on the same line at all.
    static let mealSlots = ["Breakfast", "Lunch", "Dinner", "Snack"]

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

    /// One food the client logged: what they called it, and which meal they
    /// stamped it with.
    ///
    /// `slot` is nil for an entry tied to no meal -- SHARE-FORMAT's `f` meal
    /// position outside `mealSlots`, which Coach web reads as the empty
    /// string. Printed, never compared against a booked dish.
    struct LoggedFood: Equatable {
        var name: String
        var slot: Int?

        init(name: String, slot: Int?) {
            self.name = name
            self.slot = slot
        }
    }

    /// A day's `ft` -- the five totals the client sent without saying what was
    /// in them. Only whether any of them is above zero is ever read here: it
    /// separates "they sent totals and not items" from "nothing at all", and
    /// SHARE-FORMAT writes a day opened and left empty as `[0,0,0,0,0]`.
    struct FoodTotals: Equatable {
        var calories: Double?
        var proteinG: Double?
        var fatG: Double?
        var carbsG: Double?
        var fiberG: Double?

        init(calories: Double? = nil, proteinG: Double? = nil, fatG: Double? = nil,
             carbsG: Double? = nil, fiberG: Double? = nil) {
            self.calories = calories
            self.proteinG = proteinG
            self.fatG = fatG
            self.carbsG = carbsG
            self.fiberG = fiberG
        }

        var recordedSomething: Bool {
            [calories, proteinG, fatG, carbsG, fiberG].contains { ($0 ?? 0) > 0 }
        }
    }

    /// A day the client logged, as the store holds it.
    struct LoggedDay: Equatable {
        var name: String
        var exercises: [Exercise]
        /// The day's itemised foods, empty when the client sent totals alone.
        var food: [LoggedFood]
        /// The day's totals, whatever the itemisation. nil when the day
        /// records none.
        var foodTotals: FoodTotals?

        init(name: String = "", exercises: [Exercise],
             food: [LoggedFood] = [], foodTotals: FoodTotals? = nil) {
            self.name = name
            self.exercises = exercises
            self.food = food
            self.foodTotals = foodTotals
        }
    }

    /// A day one sent plan books.
    ///
    /// Training pools where a payload books two sessions on one date --
    /// SHARE-FORMAT gives a day one `w` array, so the log has already merged
    /// two sessions into one before Coach sees it, and the asked side has to
    /// be read the same way. Meals do not pool: two dishes at one dinner are
    /// two dishes, and a coach who booked both wants to see both.
    ///
    /// `r`/`m` and `w`/`k` are independent (PLAN-FORMAT). A day may book meals
    /// with no training, training with no meals, or both, and a library send
    /// -- `r` or `w` with nothing scheduled -- books no day at all.
    struct Booking: Equatable {
        var date: String
        var name: String
        /// Whether this day booked a session at all. A day that booked none
        /// gets no training verdict: `not logged` against a day nobody was
        /// asked to train would be Coach inventing a booking to hold against
        /// a client.
        var workout: Bool
        var exercises: [Exercise]
        var meals: [MealBooking]

        init(date: String, name: String, workout: Bool,
             exercises: [Exercise], meals: [MealBooking] = []) {
            self.date = date
            self.name = name
            self.workout = workout
            self.exercises = exercises
            self.meals = meals
        }
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

    /// `meals` is a day that booked food and no session: it carries no
    /// training verdict at all, because there was no session to log.
    enum DayState: String, Equatable { case logged, notLogged, outside, notBooked, meals }
    enum ExerciseState: String, Equatable { case logged, notLogged }

    /// What Coach can see of a day's food at all, which is three different
    /// things and not two:
    ///
    ///   - `items`  the client itemised: Coach can see each entry and the meal
    ///     it was stamped with, so it can say what the log holds at a slot.
    ///   - `totals` the client sent the day's totals and not what was in them.
    ///     Itemisation is a choice made per send (SHARE-FORMAT's `f` is
    ///     optional), so this is a client's privacy choice and not an absence
    ///     -- calling a booked dinner `not logged` here would contradict it.
    ///   - `none`   nothing at all, including a day opened and left empty,
    ///     which SHARE-FORMAT writes as `ft: [0,0,0,0,0]`.
    enum FoodState: String, Equatable { case items, totals, none }

    struct DayFood: Equatable {
        var state: FoodState
        var items: [LoggedFood]
    }

    /// One booked meal, as Coach's own record of it: the slot it was booked
    /// into, the dish, and how much of it. All three are what the coach wrote,
    /// so all three can be said without reservation. Macros are deliberately
    /// not here -- see `mealNote`.
    ///
    /// `logged` is what the log holds at that slot, or nil when nothing can be
    /// said per slot: a day Coach cannot see inside, or a booking whose slot
    /// the payload did not give. It is never a claim that the two are the same
    /// dish.
    struct MealBooking: Equatable {
        /// The wire's slot index, or -1 for one Coach cannot read, which sorts
        /// last rather than being dropped.
        var slot: Int
        var slotLabel: String?
        var name: String
        var servings: Double
        var title: String
        var logged: String?
    }

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

    /// The days and the meals a send booked, and nothing else. `training` is
    /// how many of `booked` booked a session: `logged 2` under `Booked 5 days`
    /// would read as two of five when three of them booked no training at all.
    /// The meal count carries no logged figure beside it, because there is not
    /// one -- see `mealNote`.
    struct Counts: Equatable {
        var booked = 0
        var training = 0
        var logged = 0
        var notLogged = 0
        var outside = 0
        var other = 0
        var meals = 0
    }

    struct DayRow: Equatable {
        var key: String
        var state: DayState
        var name: String
        var text: String
        var exercises: [ExerciseRow]
        var alsoLogged: [AlsoLoggedRow]
        /// What this day booked to eat, and what the log holds at each of
        /// those meals. Two separate statements, never one.
        var meals: [MealBooking]
        /// What Coach can see of this day's food, said once above the meal
        /// rows. It is here so `Nothing logged at lunch` cannot be read as
        /// `they ate nothing`: a day with seven foods on it, none of them
        /// stamped lunch, says both facts one above the other.
        var foodContext: String?
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
        /// What a meal row does not claim, said once under a card that has
        /// one. nil when there is no meal row for it to be about, so a
        /// training-only card is byte for byte what it was.
        var mealFooter: String?
        var footer: String

        init(groups: [Group], byLift: [Lift], mealFooter: String? = nil, footer: String) {
            self.groups = groups
            self.byLift = byLift
            self.mealFooter = mealFooter
            self.footer = footer
        }
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
                let isCovered = coverage?.covers(booking.date) ?? false
                let state: DayState
                if booking.workout { counts.training += 1 }
                counts.meals += booking.meals.count
                if !isCovered {
                    state = .outside
                    counts.outside += 1
                } else if !booking.workout {
                    // A day that booked no training gets no training verdict.
                    state = .meals
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
                let food = isCovered ? foodIn(day) : nil
                let meals: [MealBooking] = booking.meals.map { meal in
                    var out = meal
                    out.logged = food.flatMap { slotLine(meal, in: $0) }
                    return out
                }
                let mealsClause = meals.isEmpty
                    ? "" : plural(meals.count, "meal booked", "meals booked")
                // The training word hugs the session it judges; the meal clause
                // follows it. A day that booked only meals has no session for
                // it to hug, so what is left -- `outside the log they sent`, or
                // nothing -- goes last instead.
                let head = booking.name.isEmpty
                    ? [dayLabel(booking.date, locale: locale), mealsClause, word]
                    : [dayLabel(booking.date, locale: locale), booking.name, word, mealsClause]
                return DayRow(
                    key: booking.date,
                    state: state,
                    name: booking.name,
                    text: head.filter { !$0.isEmpty }.joined(separator: " · "),
                    exercises: joined.exercises,
                    alsoLogged: joined.alsoLogged,
                    meals: meals,
                    foodContext: meals.isEmpty ? nil : food.map(foodContext),
                    booked: state == .logged ? [] : booking.exercises.map {
                        pairRow(asked: $0, logged: nil, unit: unit, substituted: false,
                                absentWord: word, locale: locale)
                    })
            }

            // A day inside this send's span that was trained and not booked.
            // Shown beside the bookings, saying nothing about cause: a session
            // lifted the day after the one it was booked for looks exactly
            // like this, and so does a session the client added themselves.
            //
            // Only when this send booked training at all. A food plan booked
            // no session for a logged one to be a displaced version of, and
            // listing a client's own training under it as `not booked` would
            // be Coach holding up work nobody set out to book.
            if counts.training > 0 {
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
                        meals: [],
                        foodContext: nil,
                        booked: []))
                }
            }
            rows.sort { $0.key < $1.key }

            let range = rangeText(from: first, to: last, locale: locale)
            groups.append(Group(id: plan.id, sentAt: plan.sentAtEpochSec, from: first, to: last,
                                range: range, counts: counts,
                                head: headLine(range: range, counts: counts),
                                days: rows))
        }

        // Only when there is a meal row for it to be about. A training-only
        // card is byte for byte what it was.
        let anyMeal = groups.contains { $0.counts.meals > 0 }
        return Result(groups: groups, byLift: byLift(groups, locale: locale),
                      mealFooter: anyMeal ? mealNote : nil, footer: footer)
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
        let recipes = payload.r ?? []
        var names: [String: [String]] = [:]
        var exercises: [String: [Exercise]] = [:]
        var meals: [String: [MealBooking]] = [:]
        var trained: Set<String> = []
        var dates: Set<String> = []

        for entry in payload.k ?? [] {
            guard workouts.indices.contains(entry.x) else { continue }
            let workout = workouts[entry.x]
            dates.insert(entry.d)
            trained.insert(entry.d)
            let name = workout.n.isEmpty ? "Session" : workout.n
            names[entry.d, default: []].append(name)
            exercises[entry.d, default: []].append(contentsOf: workout.e.map(asked))
        }

        for entry in payload.m ?? [] {
            // A booking whose recipe is not inlined indexes nothing, exactly
            // as a session whose `x` misses `w` does. Skipped, not guessed at.
            guard recipes.indices.contains(entry.x) else { continue }
            dates.insert(entry.d)
            let label = mealSlots.indices.contains(entry.s) ? mealSlots[entry.s] : nil
            meals[entry.d, default: []].append(mealBooking(
                slot: label == nil ? -1 : entry.s, label: label,
                name: recipes[entry.x].n.isEmpty ? "Recipe" : recipes[entry.x].n,
                servings: entry.q > 0 ? entry.q : 1))
        }

        return dates.sorted().map { date in
            // Breakfast, lunch, dinner, snack -- the order a day is eaten in,
            // not the order the coach happened to book them. A slot Coach
            // cannot read sorts last rather than being dropped.
            let ordered = (meals[date] ?? []).enumerated()
                .sorted { left, right in
                    let a = left.element.slot < 0 ? 9 : left.element.slot
                    let b = right.element.slot < 0 ? 9 : right.element.slot
                    return a == b ? left.offset < right.offset : a < b
                }
                .map(\.element)
            return Booking(date: date, name: (names[date] ?? []).joined(separator: " · "),
                           workout: trained.contains(date),
                           exercises: pooled(exercises[date] ?? []), meals: ordered)
        }
    }

    private static func mealBooking(slot: Int, label: String?, name: String,
                                    servings: Double) -> MealBooking {
        MealBooking(
            slot: slot, slotLabel: label, name: name, servings: servings,
            title: [label, name, plural(servings, "serving", "servings")]
                .compactMap { $0 }.joined(separator: " · "),
            logged: nil)
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

    // MARK: - Reading a day's food

    /// What a day's log can say about food at all. Three states, not two --
    /// see `FoodState`.
    static func foodIn(_ day: LoggedDay?) -> DayFood {
        let items = day?.food ?? []
        if !items.isEmpty { return DayFood(state: .items, items: items) }
        return DayFood(state: day?.foodTotals?.recordedSomething == true ? .totals : .none,
                       items: [])
    }

    /// What Coach can see of a day's food, said once above that day's meal
    /// rows. `not tied to a meal` is the same guard for an entry the client's
    /// app recorded with no slot.
    static func foodContext(_ food: DayFood) -> String {
        switch food.state {
        case .totals: return "Food logged that day, not itemised"
        case .none: return "No food logged that day"
        case .items:
            let loose = food.items.filter { $0.slot == nil }.count
            return plural(food.items.count, "food", "foods") + " logged that day"
                + (loose > 0 ? " · \(loose) not tied to a meal" : "")
        }
    }

    /// What the log holds at one slot -- the entries the client stamped with
    /// it, named as they wrote them.
    ///
    /// Names are printed, never compared. A coach reading `Beef Chilli` under
    /// a booked `Beef Chilli` has made the join themselves, from the same two
    /// facts Coach has, and can see when it is not there; Coach asserting the
    /// match would be right most nights and, the nights it was wrong, would
    /// tell a coach their client ate something they did not.
    ///
    /// nil when nothing can be said per slot: a day Coach cannot see inside,
    /// or a booking whose slot the payload did not give.
    static func slotLine(_ meal: MealBooking, in food: DayFood) -> String? {
        guard food.state == .items, let label = meal.slotLabel else { return nil }
        let place = label.lowercased()
        let mine = food.items.filter { $0.slot == meal.slot }
        guard !mine.isEmpty else { return "Nothing logged at \(place)" }
        return "Logged at \(place) · " + mine.map(\.name).joined(separator: " · ")
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

    /// A serving count is a number the coach wrote and may be a half, so it
    /// prints as JavaScript prints one: "1 serving", "2 servings",
    /// "1.5 servings".
    private static func plural(_ value: Double, _ one: String, _ many: String) -> String {
        "\(number(value)) \(value == 1 ? one : many)"
    }

    /// A day that booked only meals has no training verdict at all -- the
    /// empty string, so the clause it would have occupied is simply absent.
    private static func word(for state: DayState) -> String {
        switch state {
        case .logged: return "logged"
        case .notLogged: return "not logged"
        case .outside: return "outside the log they sent"
        case .notBooked: return "not booked"
        case .meals: return ""
        }
    }

    /// The head of one send.
    ///
    /// A send with no meals reads exactly as it always has -- `Booked 4 days,
    /// 12–17 Oct · logged 2` -- so a training week's line, and the fixture
    /// that pins it, are unchanged.
    ///
    /// A send with meals says how many it booked, and then names what the
    /// `logged` figure counts: `logged 2` under `Booked 5 days` would read as
    /// two days of five when three of them booked no training at all.
    static func headLine(range: String, counts: Counts) -> String {
        var head = "Booked \(plural(counts.booked, "day", "days")), \(range)"
        if counts.meals > 0 {
            head += " · " + plural(counts.meals, "meal booked", "meals booked")
        }
        if counts.outside == counts.booked { return head + " · no log covering them" }
        if counts.meals == 0 {
            head += " · logged \(counts.logged)"
        } else if counts.training > 0 {
            head += " · " + plural(counts.training, "training day", "training days")
                + ", \(counts.logged) logged"
        }
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
                // Meals last, under the training they sit beside, in the order
                // a day is eaten. Every sentence they can produce runs through
                // here, so the line-discipline tests cover them exactly as
                // they cover a lift.
                if !day.meals.isEmpty {
                    out.append("Meals")
                    if let context = day.foodContext { out.append(context) }
                    for meal in day.meals {
                        out.append(meal.title)
                        if let logged = meal.logged { out.append(logged) }
                    }
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
        if !out.isEmpty, let mealFooter = result.mealFooter { out.append(mealFooter) }
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
