import SwiftUI
import LiftCore

/// The client picker and week control at the top of Cook's and Train's Plan.
///
/// Stacked on a phone, as it always was. Side by side when the page is wide,
/// where a week control stretched across the whole card put its two chevrons
/// a foot apart.
struct PlanClientCard: View {
    @Binding var clientID: String
    @Binding var weekStart: String
    let clients: [Client]
    let wide: Bool

    var body: some View {
        LiftCard(title: "Client") {
            if wide {
                HStack(spacing: 24) {
                    picker
                    Spacer(minLength: 0)
                    WeekHeader(startDayKey: $weekStart)
                        .frame(maxWidth: 340)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    picker
                    WeekHeader(startDayKey: $weekStart)
                }
            }
        }
    }

    private var picker: some View {
        Picker("Client", selection: $clientID) {
            Text("Pick a client").tag("")
            ForEach(clients) { Text($0.name).tag($0.id) }
        }
        .tint(Theme.accent)
    }
}

/// A day's name over its date, for a day column too narrow for the phone
/// layout's "Wednesday · 2026-09-16" on one line.
struct DayColumnHeading: View {
    let dayKey: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(CookFormat.dayLabel(dayKey: dayKey))
                .font(Theme.cardTitle)
                .foregroundStyle(Theme.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(shortDate)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var shortDate: String {
        guard let date = DayKey.date(from: dayKey) else { return dayKey }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}
