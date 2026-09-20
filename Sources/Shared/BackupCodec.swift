import Foundation
import SwiftData
import LiftCore

/// A flat, versioned, whole-app-state JSON blob — no compression, no
/// dictionary interning. Unlike `ShareLinkCodec`'s links, a local file has
/// no email-body size pressure, so there's nothing to optimize for; this
/// mirrors `lift-ios`'s own `BackupStore.swift` in spirit (restore-by-
/// replace, not merge) for clients. The library (v2) is the one exception --
/// see `restore` below.
enum BackupCodec {

    private struct Backup: Codable {
        var v: Int
        var clients: [BackupClient]
        // v2. Optional so a v1 file decodes, and so absent means "this file
        // has no library", never "delete the one on this device".
        var recipes: [BackupRecipe]?
        var meals: [BackupMeal]?
        var routines: [BackupRoutine]?
        var sessions: [BackupSession]?
    }

    /// A weight read from a file, or nil when it is absent, zero, negative or
    /// not finite. A dish that weighs nothing is not a measurement; it is a
    /// field nobody filled in, and treating it as grams would divide a
    /// serving's weight down to zero.
    static func weighed(_ grams: Double?) -> Double? {
        guard let grams, grams.isFinite, grams > 0 else { return nil }
        return grams
    }

    private struct BackupRecipe: Codable {
        var id: UUID
        var name: String
        var servings: Double
        var steps: [String]
        var ingredients: [String]      // raw text; the parser rebuilds the rest
        var nutritionPerServing: NutritionFacts?
        /// The whole finished dish, in grams. Optional so a backup written
        /// before this field existed still decodes; absent there means "not
        /// weighed", which is also what it meant at the time. Same name and
        /// spelling as `Recipe.totalWeightGrams`, Coach web and Coach Android,
        /// so a weight survives moving between any of them.
        var totalWeightGrams: Double?
    }

    private struct BackupMeal: Codable {
        var id: UUID
        var recipeID: UUID
        var recipeName: String
        var dayKey: String
        var meal: String               // MealType.rawValue
        var servings: Double
        var snapshotNutrition: NutritionFacts?
        /// `PlannedMeal` carries no client field of its own (see this
        /// project's CLAUDE.md, "A planned meal's client lives in
        /// `@AppStorage`, not on the model"); this is that ownership
        /// travelling with the meal instead of being left behind in
        /// `cookPlanOwners`, where a restore could never reach it. `nil` for
        /// a meal that was never booked to a client on this device.
        var clientID: String?
    }

    private struct BackupRoutine: Codable {
        var id: UUID
        var name: String
        var exercises: [BackupRoutineExercise]
    }

    private struct BackupRoutineExercise: Codable {
        var name: String
        var equipment: String
        var note: String?
        var sets: [BackupPrescribedSet]
    }

    /// Kilograms, as stored. This file is Coach's own, not the wire, so there
    /// is no pounds conversion here -- adding one would be a silent 2.2x.
    private struct BackupPrescribedSet: Codable {
        var targetWeightKg: Double?
        var targetReps: Int?
        var targetRPE: Double?
        var targetDurationSec: Int?
        var targetDistanceMeters: Double?
    }

    private struct BackupSession: Codable {
        var id: UUID
        var clientID: String
        var dayKey: String
        var routineID: UUID
    }

    private struct BackupClient: Codable {
        var id: String
        var name: String
        var displayUnit: String
        var platform: String?
        var lastImportedAt: Date?
        var goal: BackupGoal?
        var days: [BackupDay]
        // Outdoor. Optional so a backup written before them still decodes,
        // and absent there means the client had none, which it did. Names and
        // object shapes are Coach Android's, so a backup moves between the
        // two apps; the wire's tuples stay on the wire.
        /// The link's `z`, which decides whether a later link is newer.
        var exportedAtEpochSec: Int?
        var outdoorBests: [BackupOutdoorBest]?
        var lastRoute: BackupLastRoute?
    }

    private struct BackupOutdoorActivity: Codable {
        var type, durationSec, distanceMeters, climbMeters: Int
    }

    /// Null bests stay null. A best of 0 would read as a real record.
    private struct BackupOutdoorBest: Codable {
        var type, count: Int
        var farthestMeters, longestSec, fastestSecPerKm: Int?
    }

    /// The encoded polyline as received, never decoded points.
    private struct BackupLastRoute: Codable {
        var type, startedAtEpochSec, durationSec, distanceMeters, climbMeters: Int
        var polyline: String
    }

    private struct BackupGoal: Codable {
        var calories, proteinG, fatG, carbsG, fiberG: Int
    }

    private struct BackupDay: Codable {
        var dayKey: String
        var sessionName: String?
        var focus: String?
        var bodyweightLb: Double?
        var steps: Int?
        var foodCalories, foodProteinG, foodFatG, foodCarbsG, foodFiberG: Double?
        var sets: [BackupSet]
        var foodEntries: [BackupFood]
        /// The day's activities; `[]` when none. Optional on read, as above.
        var outdoor: [BackupOutdoorActivity]?
        /// The day's `fx`, as an object with named fields -- Coach Android's
        /// `nutrientTotals`, name and shape. Absent when the day has none, and in
        /// every file written before it, which means the same thing.
        var nutrientTotals: BackupNutrientTotals?
    }

    /// Coach Android's `DayNutrientTotals` JSON exactly: all seven keys, an
    /// unknown total written as an explicit `null`, never `0`. Read as Android
    /// reads it -- a missing count is 0, and all three totals unknown is no
    /// totals at all.
    private struct BackupNutrientTotals: Codable {
        var saturatedFatG, sugarG, sodiumMg: Double?
        var foods, withSaturatedFat, withSugar, withSodium: Int

        init(_ totals: WireNutrientTotals) {
            saturatedFatG = totals.saturatedFatG
            sugarG = totals.sugarG
            sodiumMg = totals.sodiumMg
            foods = totals.foods
            withSaturatedFat = totals.withSaturatedFat
            withSugar = totals.withSugar
            withSodium = totals.withSodium
        }

        var wire: WireNutrientTotals {
            WireNutrientTotals(saturatedFatG: saturatedFatG, sugarG: sugarG, sodiumMg: sodiumMg,
                               foods: foods, withSaturatedFat: withSaturatedFat,
                               withSugar: withSugar, withSodium: withSodium)
        }

        private enum CodingKeys: String, CodingKey {
            case saturatedFatG, sugarG, sodiumMg, foods, withSaturatedFat, withSugar, withSodium
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            saturatedFatG = Self.finite(try? c.decodeIfPresent(Double.self, forKey: .saturatedFatG))
            sugarG = Self.finite(try? c.decodeIfPresent(Double.self, forKey: .sugarG))
            sodiumMg = Self.finite(try? c.decodeIfPresent(Double.self, forKey: .sodiumMg))
            foods = max(0, (try? c.decodeIfPresent(Int.self, forKey: .foods)) ?? 0)
            withSaturatedFat = max(0, (try? c.decodeIfPresent(Int.self, forKey: .withSaturatedFat)) ?? 0)
            withSugar = max(0, (try? c.decodeIfPresent(Int.self, forKey: .withSugar)) ?? 0)
            withSodium = max(0, (try? c.decodeIfPresent(Int.self, forKey: .withSodium)) ?? 0)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(saturatedFatG, forKey: .saturatedFatG)
            try c.encode(sugarG, forKey: .sugarG)
            try c.encode(sodiumMg, forKey: .sodiumMg)
            try c.encode(foods, forKey: .foods)
            try c.encode(withSaturatedFat, forKey: .withSaturatedFat)
            try c.encode(withSugar, forKey: .withSugar)
            try c.encode(withSodium, forKey: .withSodium)
        }

        private static func finite(_ value: Double?) -> Double? {
            guard let value, value.isFinite else { return nil }
            return value
        }
    }

    private struct BackupSet: Codable {
        var exerciseName: String
        var equipment: String?
        var weightLb: Double?
        var reps: Int?
        var rpe: Double?
        var durationSec: Double?
        var distanceMeters: Double?
        var isWarmup: Bool
        /// `"left"` or `"right"`, **omitted entirely when both** -- not
        /// `"both"`, not `null`, not a bit (BACKUP-FORMAT.md). Named rather
        /// than packed for the reason outdoor bests are objects here: this
        /// file is read by people and by three platforms, and a field a
        /// reader does not know has to survive being carried through. A file
        /// written before per-limb logging has no key here and restores as
        /// both, which is what every one of those sets always meant.
        var side: String?
    }

    private struct BackupFood: Codable {
        var foodName: String
        var servings: Double
        var calories, proteinG, fatG, carbsG, fiberG: Double
        var meal: Int
        /// As eaten, like the macros. Written only when known -- a key absent is
        /// exactly what an older file says -- under Coach Android's names.
        var saturatedFatG, sugarG, sodiumMg: Double?
    }

    static func export(from context: ModelContext, defaults: UserDefaults = .standard) throws -> Data {
        let clients = try context.fetch(FetchDescriptor<Client>())
        let recipes = try context.fetch(FetchDescriptor<Recipe>())
        let meals = try context.fetch(FetchDescriptor<PlannedMeal>())
        let routines = try context.fetch(FetchDescriptor<Routine>())
        let sessions = try context.fetch(FetchDescriptor<ScheduledSession>())
        let owners = MealOwners.load(from: defaults)

        let backup = Backup(v: 2, clients: clients.map { client in
            BackupClient(
                id: client.id, name: client.name, displayUnit: client.displayUnit, platform: client.platform,
                lastImportedAt: client.lastImportedAt,
                goal: client.goal.map { BackupGoal(calories: $0.calories, proteinG: $0.proteinG,
                                                    fatG: $0.fatG, carbsG: $0.carbsG, fiberG: $0.fiberG) },
                days: client.trainingDays.map { day in
                    BackupDay(
                        dayKey: day.dayKey, sessionName: day.sessionName, focus: day.focus,
                        bodyweightLb: day.bodyweightLb, steps: day.steps,
                        foodCalories: day.foodCalories, foodProteinG: day.foodProteinG,
                        foodFatG: day.foodFatG, foodCarbsG: day.foodCarbsG, foodFiberG: day.foodFiberG,
                        sets: day.sets.map { set in
                            BackupSet(exerciseName: set.exerciseName, equipment: set.equipment,
                                      weightLb: set.weightLb, reps: set.reps, rpe: set.rpe,
                                      durationSec: set.durationSec, distanceMeters: set.distanceMeters,
                                      isWarmup: set.isWarmup, side: set.side?.backupValue)
                        },
                        foodEntries: day.foodEntries.map { food in
                            BackupFood(foodName: food.foodName, servings: food.servings,
                                       calories: food.calories, proteinG: food.proteinG, fatG: food.fatG,
                                       carbsG: food.carbsG, fiberG: food.fiberG, meal: food.meal,
                                       saturatedFatG: food.nutrientDetails?.saturatedFatG,
                                       sugarG: food.nutrientDetails?.sugarG,
                                       sodiumMg: food.nutrientDetails?.sodiumMg)
                        },
                        outdoor: day.outdoor.map {
                            BackupOutdoorActivity(type: $0.type, durationSec: $0.durationSec,
                                                  distanceMeters: $0.distanceMeters, climbMeters: $0.climbMeters)
                        },
                        nutrientTotals: day.nutrientTotals.map(BackupNutrientTotals.init)
                    )
                },
                exportedAtEpochSec: client.exportedAtEpochSec,
                outdoorBests: client.outdoorBests?.map {
                    BackupOutdoorBest(type: $0.type, count: $0.count, farthestMeters: $0.farthestMeters,
                                      longestSec: $0.longestSec, fastestSecPerKm: $0.fastestSecPerKm)
                },
                lastRoute: client.lastRoute.map {
                    BackupLastRoute(type: $0.type, startedAtEpochSec: $0.startedAtEpochSec,
                                    durationSec: $0.durationSec, distanceMeters: $0.distanceMeters,
                                    climbMeters: $0.climbMeters, polyline: $0.polyline)
                }
            )
        }, recipes: recipes.map { recipe in
            BackupRecipe(id: recipe.id, name: recipe.name, servings: recipe.servings,
                         steps: recipe.steps,
                         ingredients: (recipe.ingredients ?? [])
                            .sorted { $0.sortOrder < $1.sortOrder }
                            .map(\.rawText),
                         nutritionPerServing: recipe.nutritionPerServing,
                         totalWeightGrams: recipe.totalWeightGrams)
        }, meals: meals.map { meal in
            BackupMeal(id: meal.id, recipeID: meal.recipeID, recipeName: meal.recipeName,
                      dayKey: meal.dayKey, meal: meal.mealType.rawValue, servings: meal.servings,
                      snapshotNutrition: meal.snapshotNutrition,
                      clientID: owners[meal.id.uuidString])
        }, routines: routines.map { routine in
            BackupRoutine(id: routine.id, name: routine.name,
                         exercises: routine.orderedExercises.map { exercise in
                BackupRoutineExercise(name: exercise.name, equipment: exercise.equipment,
                                      note: exercise.note,
                                      sets: exercise.orderedSets.map { set in
                    BackupPrescribedSet(targetWeightKg: set.targetWeightKg, targetReps: set.targetReps,
                                        targetRPE: set.targetRPE, targetDurationSec: set.targetDurationSec,
                                        targetDistanceMeters: set.targetDistanceMeters)
                })
            })
        }, sessions: sessions.map { session in
            BackupSession(id: session.id, clientID: session.clientID, dayKey: session.dayKey,
                          routineID: session.routineID)
        })
        return try JSONEncoder().encode(backup)
    }

    static func restore(from data: Data, into context: ModelContext, defaults: UserDefaults = .standard) throws {
        let backup = try JSONDecoder().decode(Backup.self, from: data)

        for existing in try context.fetch(FetchDescriptor<Client>()) {
            context.delete(existing)
        }

        for backupClient in backup.clients {
            let client = Client(id: backupClient.id, name: backupClient.name,
                                 displayUnit: backupClient.displayUnit, platform: backupClient.platform,
                                 lastImportedAt: backupClient.lastImportedAt ?? .now)
            client.exportedAtEpochSec = backupClient.exportedAtEpochSec
            client.outdoorBests = backupClient.outdoorBests?.map {
                WireOutdoorBest(type: $0.type, count: $0.count, farthestMeters: $0.farthestMeters,
                                longestSec: $0.longestSec, fastestSecPerKm: $0.fastestSecPerKm)
            }
            client.lastRoute = backupClient.lastRoute.map {
                WireLastRoute(type: $0.type, startedAtEpochSec: $0.startedAtEpochSec, durationSec: $0.durationSec,
                              distanceMeters: $0.distanceMeters, climbMeters: $0.climbMeters, polyline: $0.polyline)
            }
            context.insert(client)

            if let backupGoal = backupClient.goal {
                let goal = Goal(client: client, calories: backupGoal.calories, proteinG: backupGoal.proteinG,
                                 fatG: backupGoal.fatG, carbsG: backupGoal.carbsG, fiberG: backupGoal.fiberG)
                context.insert(goal)
                client.goal = goal
            }

            for backupDay in backupClient.days {
                let day = TrainingDay(client: client, dayKey: backupDay.dayKey, sessionName: backupDay.sessionName,
                                       focus: backupDay.focus, bodyweightLb: backupDay.bodyweightLb,
                                       steps: backupDay.steps)
                day.foodCalories = backupDay.foodCalories
                day.foodProteinG = backupDay.foodProteinG
                day.foodFatG = backupDay.foodFatG
                day.foodCarbsG = backupDay.foodCarbsG
                day.foodFiberG = backupDay.foodFiberG
                day.outdoor = (backupDay.outdoor ?? []).map {
                    WireOutdoorActivity(type: $0.type, durationSec: $0.durationSec,
                                        distanceMeters: $0.distanceMeters, climbMeters: $0.climbMeters)
                }
                day.nutrientTotals = backupDay.nutrientTotals?.wire
                context.insert(day)
                client.trainingDays.append(day)

                for backupSet in backupDay.sets {
                    let set = ExerciseSet(day: day, exerciseName: backupSet.exerciseName,
                                           equipment: backupSet.equipment, weightLb: backupSet.weightLb,
                                           reps: backupSet.reps, rpe: backupSet.rpe,
                                           durationSec: backupSet.durationSec,
                                           distanceMeters: backupSet.distanceMeters, isWarmup: backupSet.isWarmup,
                                           // Lenient: an unrecognised string is
                                           // both, not a failed import.
                                           side: SetSide.fromBackup(backupSet.side))
                    context.insert(set)
                    day.sets.append(set)
                }

                for backupFood in backupDay.foodEntries {
                    let food = ClientFoodEntry(day: day, foodName: backupFood.foodName, servings: backupFood.servings,
                                          calories: backupFood.calories, proteinG: backupFood.proteinG,
                                          fatG: backupFood.fatG, carbsG: backupFood.carbsG,
                                          fiberG: backupFood.fiberG, meal: backupFood.meal)
                    food.nutrientDetails = WireNutrientDetails(
                        saturatedFatG: backupFood.saturatedFatG.flatMap { $0.isFinite ? $0 : nil },
                        sugarG: backupFood.sugarG.flatMap { $0.isFinite ? $0 : nil },
                        sodiumMg: backupFood.sodiumMg.flatMap { $0.isFinite ? $0 : nil })
                    context.insert(food)
                    day.foodEntries.append(food)
                }
            }
        }

        // Clients are replace-by-restore, as they have always been. The
        // library merges by id instead -- the same rule the web app uses --
        // because an older backup must not delete newer work on this device.
        // The inconsistency is deliberate and documented in CLAUDE.md.
        let existingRecipes = Set(try context.fetch(FetchDescriptor<Recipe>()).map(\.id))
        for row in backup.recipes ?? [] where !existingRecipes.contains(row.id) {
            let recipe = Recipe(name: row.name, servings: row.servings, steps: row.steps,
                                nutritionPerServing: row.nutritionPerServing)
            recipe.id = row.id
            recipe.totalWeightGrams = BackupCodec.weighed(row.totalWeightGrams)
            context.insert(recipe)
            for (index, line) in row.ingredients.enumerated() {
                let ingredient = IngredientParser.parse(line, sortOrder: index)
                ingredient.recipe = recipe
                context.insert(ingredient)
            }
        }

        let existingMeals = Set(try context.fetch(FetchDescriptor<PlannedMeal>()).map(\.id))
        let recipesByID = Dictionary(uniqueKeysWithValues:
            try context.fetch(FetchDescriptor<Recipe>()).map { ($0.id, $0) })
        // Ownership travels with the meal in `row.clientID` and is written
        // back into `cookPlanOwners` below -- otherwise a restored meal is
        // stored but invisible to every client-facing screen (see
        // `MealOwners`).
        var owners = MealOwners.load(from: defaults)
        var ownersChanged = false
        for row in backup.meals ?? [] where !existingMeals.contains(row.id) {
            guard let recipe = recipesByID[row.recipeID],
                  let plannedFor = DayKey.date(from: row.dayKey) else { continue }
            let meal = PlannedMeal(recipe: recipe, mealType: MealType(rawValue: row.meal) ?? .dinner,
                                   plannedFor: plannedFor, servings: row.servings)
            meal.id = row.id
            meal.recipeName = row.recipeName
            meal.snapshotNutrition = row.snapshotNutrition
            context.insert(meal)
            if let clientID = row.clientID {
                owners[meal.id.uuidString] = clientID
                ownersChanged = true
            }
        }
        if ownersChanged { MealOwners.save(owners, to: defaults) }

        let existingRoutines = Set(try context.fetch(FetchDescriptor<Routine>()).map(\.id))
        for row in backup.routines ?? [] where !existingRoutines.contains(row.id) {
            let routine = Routine(name: row.name)
            routine.id = row.id
            context.insert(routine)
            for (index, exerciseRow) in row.exercises.enumerated() {
                let exercise = RoutineExercise(name: exerciseRow.name, equipment: exerciseRow.equipment,
                                               orderIndex: index, note: exerciseRow.note)
                exercise.routine = routine
                context.insert(exercise)
                for (order, setRow) in exerciseRow.sets.enumerated() {
                    let set = RoutinePrescribedSet(orderIndex: order, targetWeightKg: setRow.targetWeightKg,
                                                   targetReps: setRow.targetReps, targetRPE: setRow.targetRPE,
                                                   targetDurationSec: setRow.targetDurationSec,
                                                   targetDistanceMeters: setRow.targetDistanceMeters)
                    set.exercise = exercise
                    context.insert(set)
                }
            }
        }

        let existingSessions = Set(try context.fetch(FetchDescriptor<ScheduledSession>()).map(\.id))
        for row in backup.sessions ?? [] where !existingSessions.contains(row.id) {
            let session = ScheduledSession(clientID: row.clientID, dayKey: row.dayKey, routineID: row.routineID)
            session.id = row.id
            context.insert(session)
        }

        try context.save()
    }
}
