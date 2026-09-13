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

    private struct BackupRecipe: Codable {
        var id: UUID
        var name: String
        var servings: Double
        var steps: [String]
        var ingredients: [String]      // raw text; the parser rebuilds the rest
        var nutritionPerServing: NutritionFacts?
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
    }

    private struct BackupFood: Codable {
        var foodName: String
        var servings: Double
        var calories, proteinG, fatG, carbsG, fiberG: Double
        var meal: Int
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
                                      isWarmup: set.isWarmup)
                        },
                        foodEntries: day.foodEntries.map { food in
                            BackupFood(foodName: food.foodName, servings: food.servings,
                                       calories: food.calories, proteinG: food.proteinG, fatG: food.fatG,
                                       carbsG: food.carbsG, fiberG: food.fiberG, meal: food.meal)
                        }
                    )
                }
            )
        }, recipes: recipes.map { recipe in
            BackupRecipe(id: recipe.id, name: recipe.name, servings: recipe.servings,
                         steps: recipe.steps,
                         ingredients: (recipe.ingredients ?? [])
                            .sorted { $0.sortOrder < $1.sortOrder }
                            .map(\.rawText),
                         nutritionPerServing: recipe.nutritionPerServing)
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
                context.insert(day)
                client.trainingDays.append(day)

                for backupSet in backupDay.sets {
                    let set = ExerciseSet(day: day, exerciseName: backupSet.exerciseName,
                                           equipment: backupSet.equipment, weightLb: backupSet.weightLb,
                                           reps: backupSet.reps, rpe: backupSet.rpe,
                                           durationSec: backupSet.durationSec,
                                           distanceMeters: backupSet.distanceMeters, isWarmup: backupSet.isWarmup)
                    context.insert(set)
                    day.sets.append(set)
                }

                for backupFood in backupDay.foodEntries {
                    let food = ClientFoodEntry(day: day, foodName: backupFood.foodName, servings: backupFood.servings,
                                          calories: backupFood.calories, proteinG: backupFood.proteinG,
                                          fatG: backupFood.fatG, carbsG: backupFood.carbsG,
                                          fiberG: backupFood.fiberG, meal: backupFood.meal)
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
