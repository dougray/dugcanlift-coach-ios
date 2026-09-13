import SwiftUI
import SwiftData
import LiftCore

/// A client's week of meals, and the link that sends it.
///
/// `clientID`/`weekStart`/`shareLink` are owned by `CookView` and passed down
/// as bindings, for the reason spelled out in `TrainPlanView`: @State here
/// would be torn down on every section switch.
struct CookPlanView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Client.name) private var clients: [Client]
    @Query(sort: \Recipe.name) private var recipes: [Recipe]
    @Query private var meals: [PlannedMeal]

    @Binding var clientID: String
    @Binding var weekStart: String
    @Binding var shareLink: String

    /// PlannedMeal has no client field -- it is LiftCore's, shared with LIFT,
    /// where a planned meal belongs to the only person on the device. Coach
    /// plans for several clients, so the booking is keyed by the client whose
    /// week it was placed in. Held here rather than added to the package
    /// model, which would be a schema change for a shipped app.
    @AppStorage("cookPlanOwners") private var ownersData = Data()

    private var days: [String] { PlanWeek(startDayKey: weekStart).days }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                LiftCard(title: "Client") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Client", selection: $clientID) {
                            Text("Pick a client").tag("")
                            ForEach(clients) { Text($0.name).tag($0.id) }
                        }
                        .tint(Theme.accent)
                        WeekHeader(startDayKey: $weekStart)
                    }
                }

                if recipes.isEmpty {
                    LiftCard(title: "Plan") {
                        Text("Write a recipe first — the plan is built from them.")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                ForEach(days, id: \.self) { day in
                    LiftCard(title: "\(CookFormat.dayLabel(dayKey: day)) · \(day)") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(MealType.allCases) { slot in
                                mealRow(day: day, slot: slot)
                            }
                        }
                    }
                }

                if !mine.isEmpty {
                    ShareLink(item: shareLink) { Text("Send this week") }
                        .tint(Theme.accent)
                    Text(contentsLabel)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding()
        }
        .liftScreen()
        .task(id: rebuildKey) { shareLink = link() }
        .background(Theme.background)
    }

    private func mealRow(day: String, slot: MealType) -> some View {
        HStack {
            Text(slot.displayName)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            let booked = planned(on: day, slot: slot)
            if booked.isEmpty {
                Menu("Add") {
                    ForEach(recipes) { recipe in
                        Button(recipe.name) { book(recipe, on: day, slot: slot) }
                    }
                }
                .tint(Theme.accent)
                .disabled(clientID.isEmpty || recipes.isEmpty)
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    ForEach(booked) { meal in
                        HStack {
                            Text("\(meal.recipeName) · \(CookFormat.servingsLabel(meal.servings))")
                                .font(.caption)
                                .foregroundStyle(Theme.textPrimary)
                            Button("Remove") { remove(meal) }
                                .font(.caption)
                                .tint(Theme.accent)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Ownership

    private var owners: [String: String] {
        get { (try? JSONDecoder().decode([String: String].self, from: ownersData)) ?? [:] }
        nonmutating set { ownersData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    private func planned(on day: String, slot: MealType) -> [PlannedMeal] {
        let mapping = owners
        return meals.filter {
            $0.dayKey == day && $0.mealType == slot
                && mapping[$0.id.uuidString] == clientID
        }
    }

    private var mine: [PlannedMeal] {
        let mapping = owners
        return meals.filter {
            days.contains($0.dayKey) && mapping[$0.id.uuidString] == clientID
        }
    }

    private func book(_ recipe: Recipe, on day: String, slot: MealType) {
        guard let date = DayKey.date(from: day) else { return }
        let meal = PlannedMeal(recipe: recipe, mealType: slot, plannedFor: date, servings: 1)
        context.insert(meal)
        var mapping = owners
        mapping[meal.id.uuidString] = clientID
        owners = mapping
        try? context.save()
    }

    private func remove(_ meal: PlannedMeal) {
        var mapping = owners
        mapping.removeValue(forKey: meal.id.uuidString)
        owners = mapping
        context.delete(meal)
        try? context.save()
    }

    // MARK: - Sending

    /// Only the recipes this week actually plans are inlined, which is what
    /// keeps a week inside a link an email client will not mangle.
    private var usedRecipes: [Recipe] {
        recipes.filter { recipe in mine.contains { $0.recipeID == recipe.id } }
    }

    /// Keyed on the content that ends up on the wire, not on counts -- a
    /// rename or a servings edit must rebuild the link. Same discipline as
    /// TrainPlanView's RebuildKey, and for the same bug.
    private struct RebuildKey: Equatable {
        let clientID: String
        let weekStart: String
        let coachName: String
        let bookings: [Booking]
        let recipes: [Inlined]

        struct Booking: Equatable { let day: String; let slot: String; let recipeID: UUID; let servings: Double }
        struct Inlined: Equatable {
            let id: UUID, name: String, servings: Double
            let calories: Double?, ingredients: [String], steps: [String]
        }
    }

    private var rebuildKey: RebuildKey {
        RebuildKey(
            clientID: clientID, weekStart: weekStart, coachName: coachName,
            bookings: mine.map { .init(day: $0.dayKey, slot: $0.mealType.rawValue,
                                       recipeID: $0.recipeID, servings: $0.servings) },
            recipes: usedRecipes.map { recipe in
                .init(id: recipe.id, name: recipe.name, servings: recipe.servings,
                      calories: recipe.nutritionPerServing?.calories,
                      ingredients: (recipe.ingredients ?? [])
                          .sorted { $0.sortOrder < $1.sortOrder }.map(\.rawText),
                      steps: recipe.steps)
            })
    }

    private var coachName: String {
        PlanLinkEncoder.coachName(UserDefaults.standard.string(forKey: "coachName"))
    }

    private var contentsLabel: String {
        let n = mine.count
        return "\(n) meal\(n == 1 ? "" : "s") this week. "
             + "Nothing in that link goes to a server — it travels in the part of the "
             + "address browsers never send."
    }

    private func link() -> String {
        let fragment = PlanLinkEncoder.fragment(
            recipes: usedRecipes, meals: mine, lifterID: clientID, coachName: coachName)
        return "https://www.dugcanlift.com/lift/#" + fragment
    }
}
