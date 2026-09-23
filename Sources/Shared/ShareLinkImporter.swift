import Foundation
import SwiftData
import LiftCore

enum ShareLinkImporter {

    /// Shown wherever a link fails to import: Paste a Link, a
    /// `dugcanliftcoach://` URL, or a link queued by the share extension.
    static let invalidLinkMessage =
        "That doesn't look like a valid LIFT log link. Double-check you copied the whole thing."

    /// The one path from text to store. Paste a Link, `onOpenURL` and the
    /// share extension's queue all come through here, so they accept and
    /// reject exactly the same links (see `ShareLinkExtractor`).
    @discardableResult
    static func importLink(_ text: String, into context: ModelContext) throws -> ShareLinkPayload {
        let payload = try ShareLinkExtractor.payload(in: text)
        try importPayload(payload, into: context)
        return payload
    }

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

        // The window this link covers, folded into what the client has sent
        // before. Not gated on `isNewest`: an older link still proves the
        // client sent those days, and a union of the two is what Coach web
        // keeps (`absorb`). Without it a booked Tuesday with no `TrainingDay`
        // could not be told from a Tuesday outside what the client chose to
        // send, and one of those is "not logged" while the other is "we do
        // not know" -- see `PlanAndLog`.
        client.covered = ClientCoverage.absorbed(
            existing: client.covered, link: CoveredRange(from: payload.r, to: payload.t))

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

        // The order the client logged the day in, which arrives in `w` and
        // used to be dropped on the floor: `day.sets` is an unordered
        // to-many, so without it Coach cannot say which logged set was the
        // third. One running index across the whole day, so the exercises keep
        // their order too.
        var orderIndex = 0
        for entry in wireDay.w ?? [] {
            guard exerciseDict.indices.contains(entry.exerciseIndex) else { continue }
            let parts = exerciseDict[entry.exerciseIndex].split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts.first ?? "")
            let equipment = parts.count > 1 && !parts[1].isEmpty ? String(parts[1]) : nil

            for tuple in entry.sets {
                // `flags` is a bitfield: bit 0 warmup, bits 1-2 side.
                // **Mask, never compare.** `flags == 1` was right while warmup
                // was the only bit and is wrong now -- a left-side working set
                // sends 2 and a left-side warmup sends 3, and the comparison
                // calls the first a working set by luck and the second a
                // working set wrongly.
                let flags = (value(at: 5, in: tuple).flatMap { Int(exactly: $0.rounded()) }) ?? 0
                let set = ExerciseSet(
                    day: day,
                    exerciseName: name,
                    equipment: equipment,
                    weightLb: value(at: 0, in: tuple),
                    reps: value(at: 1, in: tuple).flatMap { Int(exactly: $0) },
                    rpe: value(at: 2, in: tuple),
                    durationSec: value(at: 3, in: tuple),
                    distanceMeters: value(at: 4, in: tuple),
                    isWarmup: SetFlags.isWarmup(flags),
                    // Absent is both: a link written before per-limb logging
                    // has no flags byte at all, and every set in it is a set
                    // whose side nobody recorded.
                    side: SetFlags.side(flags),
                    orderIndex: orderIndex
                )
                orderIndex += 1
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
