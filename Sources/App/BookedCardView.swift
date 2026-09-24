import SwiftUI
import SwiftData
import LiftCore

/// **Booked** -- what the coach sent, beside what the client logged.
///
/// On the client page above Sessions, because Train is where a coach *writes*
/// and the client page is where a coach *reads*, and this is reading. Absent
/// entirely for a client never sent a plan: plans sent before this existed
/// cannot be reconstructed, and a line saying so is a line every coach reads
/// once and never again.
///
/// Every rule -- which day joins which, which lift answers which, and every
/// sentence on screen -- is `PlanAndLog`, which the tests read as strings.
/// This draws what it returns and decides nothing of its own.
///
/// **Counting, never grading.** Every day row is the same weight and the same
/// colour, whichever of the four states it is in. The nearest precedent in
/// this app goes the other way -- the Fuel card colours a macro against its
/// goal -- and this deliberately does not follow it. A macro goal is a number
/// on a dial; a booked day nobody logged is a person's week.
struct BookedSection: View {
    let result: PlanAndLog.Result
    /// The width the page gave this section, so the cards follow the space
    /// they actually have rather than the device (`AdaptiveLayout`).
    let width: CGFloat

    private enum Mode: String, CaseIterable, Identifiable {
        case day = "By day"
        case lift = "By lift"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .day

    /// By lift is about lifts. A send that booked only meals has none, so the
    /// chip would open an empty card -- one mode is no choice, so no picker.
    private var reading: Mode { result.byLift.isEmpty ? .day : mode }

    var body: some View {
        if !result.groups.isEmpty {
            Text("Booked")
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 4)

            if !result.byLift.isEmpty {
                Picker("How to read it", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: AdaptiveLayout.readableWidth)
            }

            // Two sends sit side by side where there is room; one takes the
            // width it is given, rather than half a row with a hole beside it.
            // (Coach web's card is `span-all`.)
            let fits = AdaptiveLayout.columns(for: width, maxColumns: 2)
            if reading == .day {
                AdaptiveGrid(result.groups, id: \.id,
                             columns: min(fits, max(1, result.groups.count))) { group in
                    LiftCard(title: group.head) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(group.days, id: \.key) { day in
                                dayRow(day)
                            }
                        }
                        .fillsGridCell()
                    }
                }
            } else {
                AdaptiveGrid(result.byLift, id: \.key,
                             columns: min(fits, max(1, result.byLift.count))) { lift in
                    LiftCard(title: lift.title) {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(lift.entries, id: \.key) { entry in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.when)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(Theme.textPrimary)
                                    // A day with nothing logged against this
                                    // lift says so in the rule's own words.
                                    if entry.exercise.state != .logged {
                                        line(entry.exercise.title)
                                    }
                                    exercise(entry.exercise, sayTitle: false)
                                }
                            }
                        }
                        .fillsGridCell()
                    }
                }
            }

            // What a meal row does not claim, once, under the card that has one.
            if let mealFooter = result.mealFooter {
                Text(mealFooter)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: AdaptiveLayout.readableWidth, alignment: .leading)
            }
            // Permanently, whatever is above it: Coach knows what it put on a
            // share sheet and nothing after that.
            Text(result.footer)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: AdaptiveLayout.readableWidth, alignment: .leading)
        }
    }

    @ViewBuilder
    private func dayRow(_ day: PlanAndLog.DayRow) -> some View {
        if day.exercises.isEmpty && day.alsoLogged.isEmpty && day.meals.isEmpty {
            // A day with nothing under it is the same line in the same weight,
            // just without a disclosure triangle.
            Text(day.text)
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(day.exercises, id: \.key) { exercise($0, sayTitle: true) }
                    if !day.alsoLogged.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Also logged")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            ForEach(day.alsoLogged, id: \.key) { line($0.text) }
                        }
                    }
                    meals(day)
                }
                .padding(.top, 4)
            } label: {
                Text(day.text).foregroundStyle(Theme.textPrimary)
            }
            .tint(Theme.accent)
        }
    }

    /// The meals a day booked, and what the log holds at each slot.
    ///
    /// Two separate statements, never one: the bold row is Coach's own record
    /// of what it booked, the muted row under it is what the client's log
    /// holds at that meal, and nothing anywhere says they are the same dish.
    /// The context line above them all is what stops `Nothing logged at lunch`
    /// being read as `they ate nothing` -- see `PlanAndLog.mealNote`, which
    /// sits under the card saying so in words.
    @ViewBuilder
    private func meals(_ day: PlanAndLog.DayRow) -> some View {
        if !day.meals.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Meals")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let context = day.foodContext { line(context, muted: true) }
                // By position: a coach may book the same dish at the same slot
                // twice, and two rows that read alike are still two bookings.
                ForEach(Array(day.meals.enumerated()), id: \.offset) { _, meal in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(meal.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if let logged = meal.logged { line(logged, muted: true) }
                    }
                    .padding(.top, 6)
                }
            }
        }
    }

    @ViewBuilder
    private func exercise(_ row: PlanAndLog.ExerciseRow, sayTitle: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if sayTitle {
                Text(row.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            if let side = row.sideLine { line(side, muted: true) }
            if let count = row.countLine { line(count, muted: true) }
            if let asked = row.asked { setRow(asked) }
            if let logged = row.logged { setRow(logged) }
            // Under the pair, as the rule flattens it: the substitution line
            // says what the two rows above it are.
            if let substitution = row.substitution { line(substitution, muted: true) }
        }
    }

    /// An Asked or a Logged row: its label, its groups, and the clause that
    /// makes three rows six. **A view that draws the groups and forgets the
    /// suffix prints a plan asking for half of what it asks for** -- which is
    /// exactly the defect Coach web found on screen rather than in a test.
    private func setRow(_ row: PlanAndLog.SetRow) -> some View {
        (Text(row.label + " ").bold()
         + Text(row.groups.map { ($0.label.isEmpty ? "" : $0.label + " ") + $0.text }
            .joined(separator: "   "))
         + Text(row.suffix))
            .font(.caption)
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func line(_ text: String, muted: Bool = false) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(muted ? Theme.textSecondary : Theme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
