import SwiftUI
import LiftCore

/// The seven days a plan screen shows, and how to move between weeks.
///
/// Day arithmetic goes through `DayKey`, which goes through `Calendar`.
/// Adding 7 * 86400 seconds repeats a day across a DST fall-back, which would
/// book two dinners onto one date and skip another entirely.
struct PlanWeek: Equatable {
    var startDayKey: String

    var days: [String] {
        (0..<7).compactMap { DayKey.adding(days: $0, to: startDayKey) }
    }

    func advanced(by weeks: Int) -> PlanWeek {
        guard let moved = DayKey.adding(days: weeks * 7, to: startDayKey) else { return self }
        return PlanWeek(startDayKey: moved)
    }

    /// "This week" when it contains today, otherwise the span.
    var label: String {
        let all = days
        guard let first = all.first, let last = all.last else { return startDayKey }
        if all.contains(DayKey.today) { return "This week" }
        return "\(first) – \(last)"
    }
}

/// Shared by Cook's and Train's plan screens so a coach learns one control.
struct WeekHeader: View {
    @Binding var startDayKey: String

    var body: some View {
        HStack {
            Button {
                startDayKey = PlanWeek(startDayKey: startDayKey).advanced(by: -1).startDayKey
            } label: {
                Image(systemName: "chevron.left")
            }
            .tint(Theme.accent)

            Spacer()
            Text(PlanWeek(startDayKey: startDayKey).label)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            Spacer()

            Button {
                startDayKey = PlanWeek(startDayKey: startDayKey).advanced(by: 1).startDayKey
            } label: {
                Image(systemName: "chevron.right")
            }
            .tint(Theme.accent)
        }
    }
}
