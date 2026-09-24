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
    /// The client's road picks ride in this same link (PLAN-FORMAT.md "Road
    /// picks"), which is why they are read here and are part of the rebuild
    /// key: a pick ticked in Cook → Road must change the link this screen
    /// hands to Share, or the coach sends last week's answer.
    @AppStorage(RoadPicks.key) private var roadPicksData = Data()

    /// The share sheet the send button presents, once the send is filed.
    @State private var sharing = false

    private var days: [String] { PlanWeek(startDayKey: weekStart).days }

    var body: some View {
        // `owners` decodes the AppStorage blob from JSON. Decoded once here
        // and threaded through as a plain value rather than re-decoded by
        // every call to `mine`/`planned`/`usedRecipes` -- `mealRow` alone is
        // invoked 7 days x 4 meal types = 28 times per body evaluation.
        let mapping = owners
        let mineMeals = mine(mapping: mapping)
        let used = usedRecipes(mine: mineMeals)

        return AdaptiveScrollPage { width in
            let weekGrid = AdaptiveLayout.showsWeekGrid(width: width)
            let columns = AdaptiveLayout.columns(for: width, maxColumns: 3)

            PlanClientCard(clientID: $clientID, weekStart: $weekStart,
                           clients: clients, wide: columns > 1)

            if recipes.isEmpty {
                LiftCard(title: "Plan") {
                    Text("Write a recipe first — the plan is built from them.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            if weekGrid {
                // The whole week at a glance, a column a day.
                AdaptiveGrid(days, id: \.self, columns: 7) { day in
                    LiftCard {
                        VStack(alignment: .leading, spacing: 10) {
                            DayColumnHeading(dayKey: day)
                            ForEach(MealType.allCases) { slot in
                                mealCell(day: day, slot: slot, mapping: mapping)
                            }
                        }
                        .fillsGridCell()
                    }
                }
            } else {
                AdaptiveGrid(days, id: \.self, columns: columns) { day in
                    LiftCard(title: "\(CookFormat.dayLabel(dayKey: day)) · \(day)") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(MealType.allCases) { slot in
                                mealRow(day: day, slot: slot, mapping: mapping)
                            }
                        }
                        .fillsGridCell()
                    }
                }
            }

            // Road picks travel in the same link, so a coach whose only answer
            // this week is "these are fine on the road" still has a send.
            if !mineMeals.isEmpty || !roadPicks.isEmpty {
                // A `Button` that records the send and then presents the same
                // sheet `ShareLink` would, for the reason `TrainPlanView`
                // spells out: a `.simultaneousGesture` beside a `ShareLink`
                // is a silent dependency on how two gestures compose, and if
                // it stopped firing the plan would still go while Coach
                // recorded nothing.
                //
                // A picks-only send books no day and is not filed -- the rule
                // is `PlanLinkEncoder.recordSend`'s, so this screen cannot
                // get it wrong.
                Button("Send this week") {
                    recordSend(mine: mineMeals, used: used)
                    sharing = true
                }
                .tint(Theme.accent)
                .sheet(isPresented: $sharing) {
                    PlanShareSheet(text: shareLink)
                        .liftAppearance()
                }
                Text(contentsLabel(mineCount: mineMeals.count, pickCount: roadPicks.count))
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: AdaptiveLayout.readableWidth, alignment: .leading)
            }
        }
        .coachScreen()
        .task(id: rebuildKey(mine: mineMeals, used: used)) {
            shareLink = link(mine: mineMeals, used: used)
        }
        .background(Theme.background)
    }

    /// One meal slot stacked for a narrow day column: the slot's name, then
    /// each booking with its servings and a remove button beneath it, where
    /// `mealRow` lays all of that out on one line.
    private func mealCell(day: String, slot: MealType, mapping: [String: String]) -> some View {
        let booked = planned(on: day, slot: slot, mapping: mapping)
        return VStack(alignment: .leading, spacing: 3) {
            Text(slot.displayName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            if booked.isEmpty {
                Menu("Add") {
                    ForEach(recipes) { recipe in
                        Button(recipe.name) { book(recipe, on: day, slot: slot) }
                    }
                }
                .font(.caption)
                .tint(Theme.accent)
                .disabled(clientID.isEmpty || recipes.isEmpty)
            } else {
                ForEach(booked) { meal in
                    Text(meal.recipeName)
                        .font(.caption)
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Menu(CookFormat.servingsLabel(meal.servings)) {
                            ForEach(Self.servingOptions, id: \.self) { count in
                                Button(CookFormat.servingsLabel(count)) { setServings(count, on: meal) }
                            }
                        }
                        .tint(Theme.accent)
                        Spacer(minLength: 0)
                        Button {
                            remove(meal)
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .accessibilityLabel("Remove \(meal.recipeName)")
                        .tint(Theme.accent)
                    }
                    .font(.caption)
                    .lineLimit(1)
                }
            }
        }
    }

    private func mealRow(day: String, slot: MealType, mapping: [String: String]) -> some View {
        HStack {
            Text(slot.displayName)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            let booked = planned(on: day, slot: slot, mapping: mapping)
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
                            Text(meal.recipeName)
                                .font(.caption)
                                .foregroundStyle(Theme.textPrimary)
                            Menu(CookFormat.servingsLabel(meal.servings)) {
                                ForEach(Self.servingOptions, id: \.self) { count in
                                    Button(CookFormat.servingsLabel(count)) { setServings(count, on: meal) }
                                }
                            }
                            .font(.caption)
                            .tint(Theme.accent)
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

    private func planned(on day: String, slot: MealType, mapping: [String: String]) -> [PlannedMeal] {
        meals.filter {
            $0.dayKey == day && $0.mealType == slot
                && mapping[$0.id.uuidString] == clientID
        }
    }

    private func mine(mapping: [String: String]) -> [PlannedMeal] {
        meals.filter {
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

    /// PLAN-FORMAT's `q` and the shopping list's per-recipe scaling factor
    /// both key off `meal.servings` -- a booking hard-coded to 1 always
    /// shopped for one serving regardless of how many the recipe actually
    /// yields per booking, and always sent `q:1` on the wire.
    private static let servingOptions: [Double] = [0.5, 1, 1.5, 2, 3, 4]

    private func setServings(_ count: Double, on meal: PlannedMeal) {
        meal.servings = count
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
    private func usedRecipes(mine: [PlannedMeal]) -> [Recipe] {
        recipes.filter { recipe in mine.contains { $0.recipeID == recipe.id } }
    }

    /// Keyed on the content that ends up on the wire, not on counts -- a
    /// rename or a macro edit must rebuild the link. `Inlined` mirrors every
    /// field `PlanLinkEncoder.planRecipe` actually writes to `u`
    /// (calories/protein/carbs/fat/fibre), not just calories -- a coach who
    /// corrects protein with calories unchanged must still rebuild the link.
    /// `ux` too: the three detail values ride in `details`.
    /// Same discipline as TrainPlanView's RebuildKey, and for the same bug.
    ///
    /// Internal, and `rebuildKey(clientID:weekStart:coachName:mine:used:)` is
    /// a static function rather than an instance computed property, so
    /// `CookPlanViewRebuildKeyTests` can pin the "protein change moves the
    /// key" behaviour without standing up a live `@Query`/`@Environment`
    /// view instance.
    struct RebuildKey: Equatable {
        let clientID: String
        let weekStart: String
        let coachName: String
        let bookings: [Booking]
        let recipes: [Inlined]
        /// The ids as sent, in order: a pick ticked, unticked or re-ordered
        /// is a different link.
        let roadPicks: [String]

        struct Booking: Equatable { let day: String; let slot: String; let recipeID: UUID; let servings: Double }
        struct Inlined: Equatable {
            let id: UUID, name: String, servings: Double
            let calories: Double?, proteinG: Double?, carbsG: Double?, fatG: Double?, fiberG: Double?
            let details: WireNutrientDetails?
            let ingredients: [String], steps: [String]
        }
    }

    static func rebuildKey(clientID: String, weekStart: String, coachName: String,
                           mine: [PlannedMeal], used: [Recipe],
                           roadPicks: [String] = []) -> RebuildKey {
        RebuildKey(
            clientID: clientID, weekStart: weekStart, coachName: coachName,
            bookings: mine.map { .init(day: $0.dayKey, slot: $0.mealType.rawValue,
                                       recipeID: $0.recipeID, servings: $0.servings) },
            recipes: used.map { recipe in
                .init(id: recipe.id, name: recipe.name, servings: recipe.servings,
                      calories: recipe.nutritionPerServing?.calories,
                      proteinG: recipe.nutritionPerServing?.proteinG,
                      carbsG: recipe.nutritionPerServing?.carbsG,
                      fatG: recipe.nutritionPerServing?.fatG,
                      fiberG: recipe.nutritionPerServing?.fiberG,
                      details: recipe.nutritionPerServing.map(WireNutrientDetails.init),
                      ingredients: (recipe.ingredients ?? [])
                          .sorted { $0.sortOrder < $1.sortOrder }.map(\.rawText),
                      steps: recipe.steps)
            },
            roadPicks: roadPicks)
    }

    private func rebuildKey(mine: [PlannedMeal], used: [Recipe]) -> RebuildKey {
        Self.rebuildKey(clientID: clientID, weekStart: weekStart, coachName: coachName,
                        mine: mine, used: used, roadPicks: roadPicks)
    }

    private var coachName: String {
        PlanLinkEncoder.coachName(UserDefaults.standard.string(forKey: "coachName"))
    }

    private func contentsLabel(mineCount: Int, pickCount: Int) -> String {
        var parts: [String] = []
        if mineCount > 0 || pickCount == 0 {
            parts.append("\(mineCount) meal\(mineCount == 1 ? "" : "s") this week")
        }
        if pickCount > 0 {
            parts.append("\(pickCount) road pick\(pickCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: " and ") + ". "
             + "Nothing in that link goes to a server — it travels in the part of the "
             + "address browsers never send."
    }

    private func link(mine: [PlannedMeal], used: [Recipe]) -> String {
        let fragment = PlanLinkEncoder.fragment(
            recipes: used, meals: mine, roadPicks: roadPicks,
            lifterID: clientID, coachName: coachName)
        return "https://www.dugcanlift.com/lift/#" + fragment
    }

    /// The same payload the link carries, filed against this client, so the
    /// Booked card can say later what this week asked for.
    private func recordSend(mine: [PlannedMeal], used: [Recipe]) {
        PlanLinkEncoder.recordSend(recipes: used, meals: mine, roadPicks: roadPicks,
                                   lifterID: clientID, coachName: coachName, in: context)
    }

    /// This client's picks, read from the same bytes `RoadPicksView` writes.
    private var roadPicks: [String] {
        guard !clientID.isEmpty,
              let map = try? JSONDecoder().decode([String: [String]].self, from: roadPicksData)
        else { return [] }
        return RoadPicks.normalise(map[clientID] ?? [])
    }
}
