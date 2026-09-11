import Foundation
import SwiftData

@Model
final class Client {
    @Attribute(.unique) var id: String
    var name: String
    var displayUnit: String       // "lb" | "kg" — display preference only
    var platform: String?         // "and" | "ios" | "web"
    var lastImportedAt: Date

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

    @Relationship(deleteRule: .cascade, inverse: \ExerciseSet.day)
    var sets: [ExerciseSet] = []

    @Relationship(deleteRule: .cascade, inverse: \FoodEntry.day)
    var foodEntries: [FoodEntry] = []

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

@Model
final class FoodEntry {
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
