import SwiftUI
import SwiftData
import LiftCore

/// What this client needs for the week that was planned.
///
/// Derived from the planned meals, never stored -- only the tick-off state
/// persists, keyed by the normalised item name, so re-deriving the list does
/// not lose what is already in the basket.
struct ShoppingView: View {
    @Environment(\.modelContext) private var context
    @Query private var meals: [PlannedMeal]
    @Query private var recipes: [Recipe]
    @Query private var checks: [ShoppingListCheck]
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
        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.cardSpacing) {
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

                ForEach(rows) { line in
                    let isChecked = checks.contains { $0.itemKey == line.key }
                    Button {
                        toggle(line.key, isChecked: isChecked)
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
                        .padding(Theme.cardPadding)
                        .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))
                    }
                    .buttonStyle(.plain)
                }

                if !checks.isEmpty {
                    Button("Clear ticks") { clearChecks() }
                        .tint(Theme.accent)
                }
            }
            .padding()
        }
        .liftScreen()
        .background(Theme.background)
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

    private func toggle(_ key: String, isChecked: Bool) {
        if isChecked {
            for check in checks where check.itemKey == key { context.delete(check) }
        } else {
            context.insert(ShoppingListCheck(itemKey: key))
        }
        try? context.save()
    }

    private func clearChecks() {
        for check in checks { context.delete(check) }
        try? context.save()
    }
}
