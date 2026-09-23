import Foundation
import SwiftData
import LiftCore

/// Reads the library out of a **web Coach** backup (v2) into this device.
///
/// A different file from `BackupCodec`'s: the web app stores a client's days
/// as a keyed object and this app stores them as rows, so the roster halves do
/// not line up. The library halves do, and that is what a trainer moving from
/// the browser to the phone actually needs to carry.
///
/// Merge is additive by id, the web app's own rule. A v1 file carries no
/// library; absent stays absent rather than emptying the phone.
enum WebLibraryImporter {

    struct ImportSummary: Equatable {
        var recipes = 0
        var meals = 0
        var routines = 0
        var sessions = 0
        /// Rows of `sentPlans` -- the record of what the browser sent this
        /// client, so a coach who plans in the browser and reads on the phone
        /// carries it across. Nothing else here is about a client.
        var sentPlans = 0

        var isEmpty: Bool { recipes + meals + routines + sessions + sentPlans == 0 }
    }

    enum ImportError: Error { case notACoachBackup }

    static func importLibrary(from data: Data, into context: ModelContext,
                              defaults: UserDefaults = .standard) throws -> ImportSummary {
        guard let file = try? JSONDecoder().decode(WebBackup.self, from: data) else {
            throw ImportError.notACoachBackup
        }
        var summary = ImportSummary()
        // `WebPlan.clientId` was decoded and then discarded -- the imported
        // meal landed in SwiftData with no `cookPlanOwners` entry, which
        // every client-facing screen treats as "belongs to nobody." Recorded
        // below and saved once at the end instead.
        var owners = MealOwners.load(from: defaults)
        var ownersChanged = false

        let haveRecipes = Set(try context.fetch(FetchDescriptor<Recipe>()).map(\.id))
        var recipeIDByWebID: [String: UUID] = [:]

        for row in file.recipes ?? [] {
            let id = stableID(from: row.id)
            recipeIDByWebID[row.id] = id
            guard !haveRecipes.contains(id) else { continue }
            let recipe = Recipe(name: row.name, servings: row.servings,
                                steps: row.steps ?? [],
                                nutritionPerServing: row.nutritionPerServing?.facts)
            recipe.id = id
            // Coach web writes the same field; dropping it here would lose a
            // weight a coach entered in the browser the moment they moved to iOS.
            recipe.totalWeightGrams = BackupCodec.weighed(row.totalWeightGrams)
            context.insert(recipe)
            for (index, ingredient) in (row.ingredients ?? []).enumerated() {
                // Reparsed rather than field-mapped: the parser is shared, so
                // reparsing is how both sides stay in agreement about what a
                // line means. The raw text is the contract.
                let parsed = IngredientParser.parse(ingredient.rawText, sortOrder: index)
                parsed.recipe = recipe
                context.insert(parsed)
            }
            summary.recipes += 1
        }

        let haveMeals = Set(try context.fetch(FetchDescriptor<PlannedMeal>()).map(\.id))
        let recipesByID = Dictionary(uniqueKeysWithValues:
            try context.fetch(FetchDescriptor<Recipe>()).map { ($0.id, $0) })

        for row in file.plans ?? [] {
            let id = stableID(from: row.id)
            guard !haveMeals.contains(id),
                  let recipeID = recipeIDByWebID[row.recipeId] ?? UUID(uuidString: row.recipeId),
                  let recipe = recipesByID[recipeID],
                  let date = DayKey.date(from: row.date) else { continue }
            let meal = PlannedMeal(recipe: recipe, mealType: mealType(row.meal),
                                   plannedFor: date, servings: row.servings)
            meal.id = id
            context.insert(meal)
            owners[meal.id.uuidString] = row.clientId
            ownersChanged = true
            summary.meals += 1
        }

        let haveRoutines = Set(try context.fetch(FetchDescriptor<Routine>()).map(\.id))
        var routineIDByWebID: [String: UUID] = [:]

        for row in file.workouts ?? [] {
            let id = stableID(from: row.id)
            routineIDByWebID[row.id] = id
            guard !haveRoutines.contains(id) else { continue }
            let routine = Routine(name: row.name)
            routine.id = id
            context.insert(routine)
            for (index, exercise) in (row.exercises ?? []).enumerated() {
                let target = RoutineExercise(name: exercise.name,
                                             equipment: exercise.equipment ?? "",
                                             orderIndex: index)
                target.note = (exercise.note?.isEmpty == false) ? exercise.note : nil
                target.routine = routine
                context.insert(target)
                // `eachSide: true` and a set's `side`, Coach web's spellings
                // (BACKUP-FORMAT.md, "The Coach backup's workouts").
                if exercise.eachSide == true {
                    context.insert(EachSideExercise(exerciseID: target.id))
                }
                for (order, set) in (exercise.sets ?? []).enumerated() {
                    let prescribed = RoutinePrescribedSet(orderIndex: order)
                    // The web store is POUNDS. RoutinePrescribedSet is
                    // kilograms. A missing conversion here is silent and
                    // 2.2x wrong on a client's phone.
                    prescribed.targetWeightKg = set.weightLb.map(PlanLinkEncoder.lbToKg)
                    prescribed.targetReps = set.reps
                    prescribed.targetRPE = set.rpe
                    prescribed.targetDurationSec = set.durationSec
                    prescribed.targetDistanceMeters = set.distanceM
                    prescribed.exercise = target
                    context.insert(prescribed)
                    if let side = SetSide.fromBackup(set.side) {
                        context.insert(PrescribedSetSide(setID: prescribed.id, side: side))
                    }
                }
            }
            summary.routines += 1
        }

        let haveSessions = Set(try context.fetch(FetchDescriptor<ScheduledSession>()).map(\.id))
        for row in file.sessions ?? [] {
            let id = stableID(from: row.id)
            guard !haveSessions.contains(id),
                  let routineID = routineIDByWebID[row.workoutId] ?? UUID(uuidString: row.workoutId)
            else { continue }
            let session = ScheduledSession(clientID: row.clientId, dayKey: row.date,
                                           routineID: routineID)
            session.id = id
            context.insert(session)
            summary.sessions += 1
        }

        // Sent plans, merged by id and never deleted -- the same rule
        // `BackupCodec` follows for this key, because an older file must not
        // remove a send this device made since. The cap is applied after the
        // merge, so importing two files cannot leave a client with more rows
        // than sending would.
        let havePlans = Set(try context.fetch(FetchDescriptor<SentPlan>())
            .map { $0.id.uuidString.lowercased() })
        var seenPlans = havePlans
        var touchedClients: Set<String> = []
        for row in file.sentPlans ?? [] {
            let id = stableID(from: row.id)
            guard !seenPlans.contains(id.uuidString.lowercased()), !row.clientId.isEmpty,
                  let payload = row.payload.data else { continue }
            seenPlans.insert(id.uuidString.lowercased())
            touchedClients.insert(row.clientId)
            context.insert(SentPlan(
                id: id, clientID: row.clientId,
                sentAtEpochSec: row.sentAt.map { Int($0) } ?? 0,
                payloadHash: (row.payloadHash?.isEmpty == false) ? row.payloadHash!
                                                                 : SentPlans.hash(payload: payload),
                payloadData: payload))
            summary.sentPlans += 1
        }
        for clientID in touchedClients { SentPlans.prune(clientID: clientID, in: context) }

        if ownersChanged { MealOwners.save(owners, to: defaults) }

        try context.save()
        return summary
    }

    /// The web app's ids are `crypto.randomUUID()` where the browser has it and
    /// a timestamp-plus-random string where it does not. A real UUID is kept as
    /// itself so re-importing is idempotent; anything else is hashed into one
    /// deterministically, for the same reason.
    private static func stableID(from webID: String) -> UUID {
        if let real = UUID(uuidString: webID) { return real }
        var hash = UInt64(5381)
        for byte in webID.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        var bytes = withUnsafeBytes(of: hash.bigEndian, Array.init)
        bytes += withUnsafeBytes(of: hash.littleEndian, Array.init)
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
                           bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func mealType(_ raw: String?) -> MealType {
        switch (raw ?? "").uppercased() {
        case "BREAKFAST": return .breakfast
        case "LUNCH": return .lunch
        case "SNACK": return .snack
        default: return .dinner
        }
    }

    // MARK: - The web app's shapes

    private struct WebBackup: Decodable {
        let v: Int
        let clients: [WebClientStub]
        let recipes: [WebRecipe]?
        let plans: [WebPlan]?
        let workouts: [WebWorkout]?
        let sessions: [WebSession]?
        /// BACKUP-FORMAT.md, "The Coach backup's sent plans". Absent in a file
        /// written before them, which changes nothing.
        let sentPlans: [WebSentPlan]?
    }

    /// One send as the browser wrote it. The payload is kept as the object it
    /// is: Coach reads it with `PlanPayload`, never field by field here.
    private struct WebSentPlan: Decodable {
        let id: String
        let clientId: String
        let sentAt: Double?
        let payloadHash: String?
        let payload: AnyJSON
    }

    /// Only enough to prove this is a Coach backup. The roster itself is not
    /// imported here -- the two apps store a client's days differently.
    private struct WebClientStub: Decodable { let id: String? }

    private struct WebRecipe: Decodable {
        let id: String
        let name: String
        let servings: Double
        let ingredients: [WebIngredient]?
        let steps: [String]?
        let nutritionPerServing: WebNutrition?
        let totalWeightGrams: Double?
    }

    private struct WebIngredient: Decodable { let rawText: String }

    private struct WebNutrition: Decodable {
        let calories: Double?
        let proteinG: Double?
        let carbsG: Double?
        let fatG: Double?
        let fiberG: Double?
        // BACKUP-FORMAT.md `nutritionPerServing`, per serving; absent is nil.
        // Read leniently: a hand-edited "540 mg" is unknown, not a reason to
        // refuse a whole library that imported fine before these existed.
        let saturatedFatG: Double?
        let sugarG: Double?
        let sodiumMg: Double?

        private enum CodingKeys: String, CodingKey {
            case calories, proteinG, carbsG, fatG, fiberG, saturatedFatG, sugarG, sodiumMg
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            calories = try c.decodeIfPresent(Double.self, forKey: .calories)
            proteinG = try c.decodeIfPresent(Double.self, forKey: .proteinG)
            carbsG = try c.decodeIfPresent(Double.self, forKey: .carbsG)
            fatG = try c.decodeIfPresent(Double.self, forKey: .fatG)
            fiberG = try c.decodeIfPresent(Double.self, forKey: .fiberG)
            saturatedFatG = (try? c.decodeIfPresent(Double.self, forKey: .saturatedFatG)) ?? nil
            sugarG = (try? c.decodeIfPresent(Double.self, forKey: .sugarG)) ?? nil
            sodiumMg = (try? c.decodeIfPresent(Double.self, forKey: .sodiumMg)) ?? nil
        }

        var facts: NutritionFacts {
            NutritionFacts(calories: calories ?? 0, proteinG: proteinG ?? 0,
                           carbsG: carbsG ?? 0, fatG: fatG ?? 0, fiberG: fiberG,
                           sugarG: sugarG, sodiumMg: sodiumMg, saturatedFatG: saturatedFatG)
        }
    }

    private struct WebPlan: Decodable {
        let id: String
        let clientId: String
        let recipeId: String
        let date: String
        let meal: String?
        let servings: Double
    }

    private struct WebWorkout: Decodable {
        let id: String
        let name: String
        let exercises: [WebExercise]?
    }

    private struct WebExercise: Decodable {
        let name: String
        let equipment: String?
        let note: String?
        let sets: [WebSet]?
        /// Only `true` is each side; anything else, or junk, is not.
        let eachSide: Bool?

        private enum CodingKeys: String, CodingKey { case name, equipment, note, sets, eachSide }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            equipment = try c.decodeIfPresent(String.self, forKey: .equipment)
            note = try c.decodeIfPresent(String.self, forKey: .note)
            sets = try c.decodeIfPresent([WebSet].self, forKey: .sets)
            eachSide = (try? c.decodeIfPresent(Bool.self, forKey: .eachSide)) ?? nil
        }
    }

    /// `distanceM`, not `distanceMeters` -- the web store's own spelling.
    private struct WebSet: Decodable {
        let weightLb: Double?
        let reps: Int?
        let rpe: Double?
        let durationSec: Int?
        let distanceM: Double?
        /// `"left"` / `"right"`, absent when both. Junk reads as both.
        let side: String?

        private enum CodingKeys: String, CodingKey { case weightLb, reps, rpe, durationSec, distanceM, side }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            weightLb = try c.decodeIfPresent(Double.self, forKey: .weightLb)
            reps = try c.decodeIfPresent(Int.self, forKey: .reps)
            rpe = try c.decodeIfPresent(Double.self, forKey: .rpe)
            durationSec = try c.decodeIfPresent(Int.self, forKey: .durationSec)
            distanceM = try c.decodeIfPresent(Double.self, forKey: .distanceM)
            side = (try? c.decodeIfPresent(String.self, forKey: .side)) ?? nil
        }
    }

    private struct WebSession: Decodable {
        let id: String
        let clientId: String
        let date: String
        let workoutId: String
    }
}
