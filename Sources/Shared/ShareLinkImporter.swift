import Foundation
import SwiftData
import LiftCore

enum ShareLinkImporter {

    static func importPayload(_ payload: ShareLinkPayload, into context: ModelContext) throws {
        let client = try findOrCreateClient(for: payload.c, in: context)
        client.lastImportedAt = .now

        // Everything that describes the client rather than a day -- name, unit,
        // platform, goal, outdoor bests, last route -- follows the newest send,
        // as the web Coach's `absorb` does. A client who changed their goal last
        // week must not have it undone by an older link pasted late. Days are
        // different: each link is the truth for the days it covers, whenever it
        // arrives. A client imported before `z` was recorded has no stamp, so
        // the first link after the update counts as newest.
        let isNewest = client.exportedAtEpochSec.map { payload.z >= $0 } ?? true

        if isNewest {
            client.name = payload.c.n
            client.displayUnit = payload.c.u
            client.platform = payload.c.p
        }

        if isNewest, let wireGoal = payload.g {
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

        // Within the newest-send rule, absent clears for outdoor -- a client who
        // turned route sharing off expects the route gone, not frozen.
        if isNewest {
            client.outdoorBests = payload.ob
            client.lastRoute = payload.lr
            client.exportedAtEpochSec = payload.z
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
        day.outdoor = wireDay.o ?? []
        // `fx` as sent: the sender already multiplied by servings and counted
        // coverage, so nothing here re-adds it. Null totals stay null.
        day.nutrientTotals = wireDay.fx
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

        // `fe` is aligned with `f` by position, so it is indexed by the
        // position in `f` -- not by the count of entries kept, or one
        // malformed food would pin every later food's sodium on its neighbour.
        // The kit already drops an `fe` whose length differs from `f`'s.
        let details = wireDay.fe
        for (position, itemized) in (wireDay.f ?? []).enumerated() where itemized.count == 8 {
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
            // `fe` is per serving too, so it is multiplied the same way. A
            // value the food did not record stays nil, never zero.
            if let details, details.indices.contains(position), let perServing = details[position] {
                food.nutrientDetails = WireNutrientDetails(
                    saturatedFatG: perServing.saturatedFatG.map { $0 * servings },
                    sugarG: perServing.sugarG.map { $0 * servings },
                    sodiumMg: perServing.sodiumMg.map { $0 * servings })
            }
            context.insert(food)
            day.foodEntries.append(food)
        }
    }

    private static func value(at index: Int, in tuple: [Double?]) -> Double? {
        index < tuple.count ? tuple[index] : nil
    }
}
