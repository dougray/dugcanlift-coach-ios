import Foundation
import SwiftData
import LiftCore

@Model
final class Client {
    @Attribute(.unique) var id: String
    var name: String
    var displayUnit: String       // "lb" | "kg" — display preference only
    var platform: String?         // "and" | "ios" | "web"
    var lastImportedAt: Date

    // Outdoor (SHARE-FORMAT.md "Outdoor"). Each is the wire value as JSON,
    // read through `outdoorBests` / `lastRoute` below. Optional with no
    // default, so a store written before outdoor opens with them nil -- a
    // lightweight migration, verified against a real on-disk store.
    /// `ob`, the client's all-time bests.
    var outdoorBestsData: Data?
    /// `lr`, the newest route, already trimmed by the client's app.
    var lastRouteData: Data?
    /// `z` of the newest payload whose `ob`/`lr` are stored. Nil before the
    /// first outdoor-aware import, which any payload then counts as newer.
    var exportedAtEpochSec: Int?

    @Relationship(deleteRule: .cascade, inverse: \Goal.client)
    var goal: Goal?

    @Relationship(deleteRule: .cascade, inverse: \TrainingDay.client)
    var trainingDays: [TrainingDay] = []

    init(id: String, name: String, displayUnit: String, platform: String?, lastImportedAt: Date = .now) {
        self.id = id
        self.name = name
        self.displayUnit = displayUnit
        self.platform = platform
        self.lastImportedAt = lastImportedAt
    }
}

extension Client {
    /// Days since this client's most-recently-LOGGED day (derived from
    /// their actual training data, not `lastImportedAt` -- re-pasting an
    /// old link from a silent client should not make them look active).
    /// `nil` means they have never logged anything at all. Mirrors the
    /// web Coach app's own silence-indicator logic (`app.js`'s
    /// `lastLogged`).
    var daysSinceLastLoggedDay: Int? {
        guard let mostRecentDayKey = trainingDays.map(\.dayKey).max() else { return nil }
        return DayKey.daysBetween(mostRecentDayKey, DayKey.string(from: .now))
    }
}

extension Client {
    var outdoorBests: [WireOutdoorBest]? {
        get { InlineJSON.decode([WireOutdoorBest].self, from: outdoorBestsData) }
        set { outdoorBestsData = InlineJSON.encode(newValue) }
    }

    var lastRoute: WireLastRoute? {
        get { InlineJSON.decode(WireLastRoute.self, from: lastRouteData) }
        set { lastRouteData = InlineJSON.encode(newValue) }
    }
}

extension TrainingDay {
    /// Empty when the day has none. An empty list is stored as nil.
    var outdoor: [WireOutdoorActivity] {
        get { InlineJSON.decode([WireOutdoorActivity].self, from: outdoorData) ?? [] }
        set { outdoorData = newValue.isEmpty ? nil : InlineJSON.encode(newValue) }
    }
}

/// Small wire values kept inline on a model as JSON `Data`, rather than as
/// new `@Model` types (a schema change with relationships to migrate) or as
/// SwiftData composite attributes (which flatten a struct into columns and
/// cannot hold an array of tuples). Unreadable data reads as absent.
enum InlineJSON {
    static func encode<T: Encodable>(_ value: T?) -> Data? {
        guard let value else { return nil }
        return try? JSONEncoder().encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

@Model
final class Goal {
    var client: Client?
    var calories: Int
    var proteinG: Int
    var fatG: Int
    var carbsG: Int
    var fiberG: Int

    init(client: Client? = nil, calories: Int, proteinG: Int, fatG: Int, carbsG: Int, fiberG: Int) {
        self.client = client
        self.calories = calories
        self.proteinG = proteinG
        self.fatG = fatG
        self.carbsG = carbsG
        self.fiberG = fiberG
    }
}

@Model
final class TrainingDay {
    var client: Client?
    var dayKey: String
    var sessionName: String?
    var focus: String?
    var bodyweightLb: Double?
    var steps: Int?
    var foodCalories: Double?
    var foodProteinG: Double?
    var foodFatG: Double?
    var foodCarbsG: Double?
    var foodFiberG: Double?
    /// The day's `o` as JSON; read it through `outdoor`. Travels with the
    /// day, so replacing a day replaces its outdoor activities too.
    var outdoorData: Data?

    @Relationship(deleteRule: .cascade, inverse: \ExerciseSet.day)
    var sets: [ExerciseSet] = []

    @Relationship(deleteRule: .cascade, inverse: \ClientFoodEntry.day)
    var foodEntries: [ClientFoodEntry] = []

    init(client: Client?, dayKey: String, sessionName: String? = nil, focus: String? = nil,
         bodyweightLb: Double? = nil, steps: Int? = nil) {
        self.client = client
        self.dayKey = dayKey
        self.sessionName = sessionName
        self.focus = focus
        self.bodyweightLb = bodyweightLb
        self.steps = steps
    }
}

@Model
final class ExerciseSet {
    var day: TrainingDay?
    var exerciseName: String
    var equipment: String?
    var weightLb: Double?
    var reps: Int?
    var rpe: Double?
    var durationSec: Double?
    var distanceMeters: Double?
    var isWarmup: Bool

    init(day: TrainingDay? = nil, exerciseName: String, equipment: String? = nil,
         weightLb: Double? = nil, reps: Int? = nil, rpe: Double? = nil,
         durationSec: Double? = nil, distanceMeters: Double? = nil, isWarmup: Bool = false) {
        self.day = day
        self.exerciseName = exerciseName
        self.equipment = equipment
        self.weightLb = weightLb
        self.reps = reps
        self.rpe = rpe
        self.durationSec = durationSec
        self.distanceMeters = distanceMeters
        self.isWarmup = isWarmup
    }
}

/// A food a **client** logged, imported from their share link. Coach never
/// logs food itself; it reads what someone else ate.
///
/// Named `ClientFoodEntry` rather than `FoodEntry` on purpose, and renaming
/// it back would break the app. `LiftCore` carries its own `FoodEntry` — the
/// athlete-side one — and **SwiftData identifies an entity by its class
/// name, not module-qualified**. Two `@Model` classes called `FoodEntry` in
/// one schema do not clash loudly: the schema builds with no error, reports
/// a single entity holding whichever type was listed last, and then fails at
/// `save()` with a Core Data validation error naming the *other* type's
/// properties. Measured 2026-09-12.
///
/// Coach reaches that state the moment Cook puts `LiftCore.PlannedMeal` into
/// this store, because `PlannedMeal.makeFoodEntry()` returns a
/// `LiftCore.FoodEntry`. Qualifying the Swift name as `Coach.FoodEntry` does
/// not help — that is symbol lookup, one level above entity identity.
@Model
final class ClientFoodEntry {
    var day: TrainingDay?
    var foodName: String
    var servings: Double
    var calories: Double
    var proteinG: Double
    var fatG: Double
    var carbsG: Double
    var fiberG: Double
    var meal: Int   // 0 breakfast, 1 lunch, 2 dinner, 3 snack

    init(day: TrainingDay? = nil, foodName: String, servings: Double, calories: Double,
         proteinG: Double, fatG: Double, carbsG: Double, fiberG: Double, meal: Int) {
        self.day = day
        self.foodName = foodName
        self.servings = servings
        self.calories = calories
        self.proteinG = proteinG
        self.fatG = fatG
        self.carbsG = carbsG
        self.fiberG = fiberG
        self.meal = meal
    }
}
