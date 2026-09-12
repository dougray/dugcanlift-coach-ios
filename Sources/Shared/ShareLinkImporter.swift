import Foundation
import SwiftData
import LiftCore

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
            guard exerciseDict.indices.contains(entry.exerciseIndex) else { continue }
            let parts = exerciseDict[entry.exerciseIndex].split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts.first ?? "")
            let equipment = parts.count > 1 && !parts[1].isEmpty ? String(parts[1]) : nil

            for tuple in entry.sets {
                let set = ExerciseSet(
                    day: day,
                    exerciseName: name,
                    equipment: equipment,
                    weightLb: value(at: 0, in: tuple),
                    reps: value(at: 1, in: tuple).flatMap { Int(exactly: $0) },
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
            guard let foodIndex = Int(exactly: itemized[0]), foodIndex >= 0,
                  let foodDict, foodDict.indices.contains(foodIndex),
                  let meal = Int(exactly: itemized[7])
            else { continue }
            let servings = itemized[1]
            // The macro numbers on the wire are PER SERVING
            // (SHARE-FORMAT.md's documented convention, and what
            // Android's real encoder sends). lift-ios's own encoder
            // always sends servings=1 with as-eaten totals already in
            // the macro slots, so multiplying is a no-op there -- but
            // it's required to correctly read an Android-sourced
            // payload, where servings can be any real value. (Reversed
            // from an earlier version of this importer, which stored
            // macros unmultiplied based on iOS-only evidence -- see the
            // final whole-branch review that caught this against the
            // real Android encoder.)
            let food = ClientFoodEntry(
                day: day, foodName: foodDict[foodIndex], servings: servings,
                calories: itemized[2] * servings, proteinG: itemized[3] * servings,
                fatG: itemized[4] * servings, carbsG: itemized[5] * servings,
                fiberG: itemized[6] * servings, meal: meal
            )
            context.insert(food)
            day.foodEntries.append(food)
        }
    }

    private static func value(at index: Int, in tuple: [Double?]) -> Double? {
        index < tuple.count ? tuple[index] : nil
    }
}
