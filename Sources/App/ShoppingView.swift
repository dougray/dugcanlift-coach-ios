import SwiftUI
import SwiftData
import LiftCore

/// What this client needs for the week that was planned.
///
/// Derived from the planned meals, never stored -- only the tick-off state
/// persists, keyed by client and the normalised item name, so re-deriving the
/// list does not lose what is already in the basket, and one client's basket
/// never shows in another's (see `ClientShoppingCheck`).
struct ShoppingView: View {
    @Environment(\.modelContext) private var context
    @Query private var meals: [PlannedMeal]
    @Query private var recipes: [Recipe]
    @Query private var checks: [ClientShoppingCheck]
    @Query(sort: \Client.name) private var clients: [Client]

    @Binding var clientID: String
    @Binding var weekStart: String

    @AppStorage("cookPlanOwners") private var ownersData = Data()

    var body: some View {
        // Computed once per body pass -- `lines` re-derives the whole list
        // from `meals`/`recipes`/`weekStart` on every access, and the body
        // below was reading it twice (the emptiness check, then the
        // ForEach).
        let rows = lines
        return AdaptiveScrollPage { width in
            // Two columns at most: a shopping list is read down, and three
            // narrow ones read as a table rather than a list.
            let columns = AdaptiveLayout.columns(for: width, maxColumns: 2)

            if rows.isEmpty {
                LiftCard(title: "Shopping") {
                    Text("Nothing planned for this client's week, so there is nothing "
                         + "to buy yet.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                LiftCard(title: "Shopping") {
                    Text("What \(clientName) needs for the week you planned. It goes with "
                         + "the plan link — you don't have to send this separately.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            if !rows.isEmpty {
                AdaptiveGrid(rows, columns: columns) { line in
                    itemRow(line)
                }
            }

            // This client's ticks only -- another client's basket is
            // not this one's to clear.
            if !ClientShoppingCheck.checks(for: clientID, in: checks).isEmpty {
                Button("Clear ticks") {
                    ClientShoppingCheck.clear(clientID: clientID, in: checks, context: context)
                    try? context.save()
                }
                .tint(Theme.accent)
            }
        }
        .coachScreen()
        .background(Theme.background)
    }

    private func itemRow(_ line: ShoppingListLine) -> some View {
        let isChecked = ClientShoppingCheck.isChecked(line, clientID: clientID, in: checks)
        return Button {
            ClientShoppingCheck.toggle(line, clientID: clientID, in: checks, context: context)
            try? context.save()
        } label: {
            HStack(alignment: .top) {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.displayName)
                        .foregroundStyle(Theme.textPrimary)
                        .strikethrough(isChecked)
                    if !line.amounts.isEmpty {
                        Text(CookFormat.amountsLabel(line.amounts))
                            .font(Theme.detail)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    // Ingredients that never parsed. Shown verbatim
                    // so nothing silently drops off the list.
                    ForEach(line.unparsed, id: \.self) { raw in
                        Text(raw)
                            .font(Theme.detail)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer()
            }
            .fillsGridCell()
            .padding(Theme.cardPadding)
            .liftCardBackground()
        }
        .buttonStyle(.plain)
    }

    private var owners: [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: ownersData)) ?? [:]
    }

    private var lines: [ShoppingListLine] {
        let days = PlanWeek(startDayKey: weekStart).days
        let mapping = owners
        let mine = meals.filter {
            days.contains($0.dayKey) && mapping[$0.id.uuidString] == clientID
        }
        let byID = Dictionary(uniqueKeysWithValues: recipes.map { ($0.id, $0) })
        return ShoppingList.build(from: mine, recipes: byID)
    }

    private var clientName: String {
        clients.first { $0.id == clientID }?.name ?? "this client"
    }
}
