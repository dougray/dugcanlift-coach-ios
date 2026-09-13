import Foundation

/// Reads and writes the `cookPlanOwners` map -- `PlannedMeal.id.uuidString`
/// to client id -- the same JSON-in-`UserDefaults` blob `CookPlanView.owners`
/// and `ShoppingView.owners` decode inline, and `CookView.sweepOwners` prunes.
/// See this project's `CLAUDE.md`, "A planned meal's client lives in
/// `@AppStorage`, not on the model," for why the map exists at all instead of
/// a field on `PlannedMeal`.
///
/// `BackupCodec` and `WebLibraryImporter` write into it through this type.
/// Neither did before: a restored or imported `PlannedMeal` landed in
/// SwiftData with no entry here, which every screen that reads the map
/// (`CookPlanView.mine`, `ShoppingView.lines`) treats identically to a meal
/// belonging to nobody -- stored, but permanently invisible.
enum MealOwners {
    static let key = "cookPlanOwners"

    static func load(from defaults: UserDefaults = .standard) -> [String: String] {
        guard let data = defaults.data(forKey: key),
              let mapping = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return mapping
    }

    static func save(_ map: [String: String], to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        defaults.set(data, forKey: key)
    }
}
