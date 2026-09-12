import Foundation
import SwiftData

/// A flat, versioned, whole-app-state JSON blob — no compression, no
/// dictionary interning. Unlike `ShareLinkCodec`'s links, a local file has
/// no email-body size pressure, so there's nothing to optimize for; this
/// mirrors `lift-ios`'s own `BackupStore.swift` in spirit (restore-by-
/// replace, not merge).
enum BackupCodec {

    private struct Backup: Codable {
        var v: Int
        var clients: [BackupClient]
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

    static func export(from context: ModelContext) throws -> Data {
        let clients = try context.fetch(FetchDescriptor<Client>())
        let backup = Backup(v: 1, clients: clients.map { client in
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
        })
        return try JSONEncoder().encode(backup)
    }

    static func restore(from data: Data, into context: ModelContext) throws {
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

        try context.save()
    }
}
