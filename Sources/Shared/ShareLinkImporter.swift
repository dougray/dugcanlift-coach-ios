import Foundation
import SwiftData

enum ShareLinkImporter {

    static func importPayload(_ payload: ShareLinkPayload, into context: ModelContext) throws {
        let client = try findOrCreateClient(for: payload.c, in: context)
        client.lastImportedAt = .now

        if let wireGoal = payload.g {
            if let existingGoal = client.goal {
                existingGoal.calories = wireGoal.c
                existingGoal.proteinG = wireGoal.p
                existingGoal.fatG = wireGoal.f
                existingGoal.carbsG = wireGoal.cb
                existingGoal.fiberG = wireGoal.fb
            } else {
                let goal = Goal(client: client, calories: wireGoal.c, proteinG: wireGoal.p,
                                 fatG: wireGoal.f, carbsG: wireGoal.cb, fiberG: wireGoal.fb)
                context.insert(goal)
                client.goal = goal
            }
        }

        for wireDay in payload.d {
            guard let dayKey = DayKey.adding(days: wireDay.k, to: payload.r) else { continue }
            try replaceDay(wireDay, dayKey: dayKey, exerciseDict: payload.x, foodDict: payload.fd,
                            client: client, in: context)
        }

        try context.save()
    }

    private static func findOrCreateClient(for wireClient: WireClient, in context: ModelContext) throws -> Client {
        let id = wireClient.i
        let descriptor = FetchDescriptor<Client>(predicate: #Predicate { $0.id == id })
        if let existing = try context.fetch(descriptor).first {
            existing.name = wireClient.n
            existing.displayUnit = wireClient.u
            existing.platform = wireClient.p
            return existing
        }
        let client = Client(id: wireClient.i, name: wireClient.n, displayUnit: wireClient.u, platform: wireClient.p)
        context.insert(client)
        return client
    }

    /// "Replace the whole day" — SHARE-FORMAT.md's own merge rule. Deleting
    /// any existing day with this key before inserting the new one is what
    /// makes a deletion on the sending client's own app propagate correctly.
    private static func replaceDay(_ wireDay: WireDay, dayKey: String, exerciseDict: [String],
                                    foodDict: [String]?, client: Client, in context: ModelContext) throws {
        let existing = client.trainingDays.filter { $0.dayKey == dayKey }
        for day in existing {
            context.delete(day)
            client.trainingDays.removeAll { $0 === day }
        }

        let day = TrainingDay(client: client, dayKey: dayKey, sessionName: wireDay.n, focus: wireDay.fo,
                               bodyweightLb: wireDay.bw, steps: wireDay.st)
        context.insert(day)
        client.trainingDays.append(day)

        for entry in wireDay.w ?? [] {
            guard entry.exerciseIndex < exerciseDict.count else { continue }
            let parts = exerciseDict[entry.exerciseIndex].split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts.first ?? "")
            let equipment = parts.count > 1 && !parts[1].isEmpty ? String(parts[1]) : nil

            for tuple in entry.sets {
                let set = ExerciseSet(
                    day: day,
                    exerciseName: name,
                    equipment: equipment,
                    weightLb: value(at: 0, in: tuple),
                    reps: value(at: 1, in: tuple).map { Int($0) },
                    rpe: value(at: 2, in: tuple),
                    durationSec: value(at: 3, in: tuple),
                    distanceMeters: value(at: 4, in: tuple),
                    isWarmup: (value(at: 5, in: tuple) ?? 0) == 1
                )
                context.insert(set)
                day.sets.append(set)
            }
        }

        if let totals = wireDay.ft, totals.count == 5 {
            day.foodCalories = totals[0]
            day.foodProteinG = totals[1]
            day.foodFatG = totals[2]
            day.foodCarbsG = totals[3]
            day.foodFiberG = totals[4]
        }

        for itemized in wireDay.f ?? [] where itemized.count == 8 {
            let foodIndex = Int(itemized[0])
            guard let foodDict, foodIndex < foodDict.count else { continue }
            // servings (itemized[1]) is always 1 from the iOS encoder and the
            // macro numbers below are already as-eaten totals — stored as-is,
            // never multiplied.
            let food = FoodEntry(
                day: day, foodName: foodDict[foodIndex], servings: itemized[1],
                calories: itemized[2], proteinG: itemized[3], fatG: itemized[4],
                carbsG: itemized[5], fiberG: itemized[6], meal: Int(itemized[7])
            )
            context.insert(food)
            day.foodEntries.append(food)
        }
    }

    private static func value(at index: Int, in tuple: [Double?]) -> Double? {
        index < tuple.count ? tuple[index] : nil
    }
}
