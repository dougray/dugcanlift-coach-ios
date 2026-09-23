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
        /// The Road Food items a coach has marked for each client, keyed by
        /// client id (BACKUP-FORMAT.md "The Coach backup's road picks";
        /// Coach web's own spelling, so one file moves between them).
        /// Omitted by a Coach old enough not to have picks, and a file
        /// without it changes nothing on restore.
        var roadPicks: [String: [String]]?
        /// What each client was actually sent (BACKUP-FORMAT.md, "The Coach
        /// backup's sent plans"). Rows with ids of their own, so they merge by
        /// id the way recipes and workouts do. Omitted when there are none, so
        /// a coach who has never sent a plan writes the file they always did.
        ///
        /// **A row that will not decode is dropped, not fatal.** Coach web's
        /// `mergeBackup` skips a row missing an id, a client or a payload and
        /// keeps going, and a record of one send is not worth failing a file
        /// that also carries the roster.
        var sentPlans: LenientRows<BackupSentPlan>?
    }

    /// An array whose unreadable elements are skipped rather than failing the
    /// whole file -- the rule `WireDay` follows for `o`, `fx` and `fe`, and
    /// the one Coach web's own restore follows for these rows.
    struct LenientRows<Row: Codable>: Codable {
        var values: [Row]

        init(_ values: [Row]) { self.values = values }

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            var kept: [Row] = []
            while !container.isAtEnd {
                if let row = try? container.decode(Row.self) {
                    kept.append(row)
                } else {
                    // The index only advances on a successful decode, so a bad
                    // element has to be read as something before the next one
                    // can be.
                    _ = try? container.decode(AnyJSON.self)
                }
            }
            values = kept
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.unkeyedContainer()
            for row in values { try container.encode(row) }
        }
    }

    /// One send, in the five fields BACKUP-FORMAT.md names, under Coach web's
    /// and Coach Android's spelling -- `clientId`, not this file's older
    /// `clientID`, because the document names it and a new key should not be
    /// the one that has to be translated. Read either way round all the same:
    /// a file is worth more than a spelling.
    private struct BackupSentPlan: Codable {
        var id: UUID
        var clientId: String
        var sentAt: Int
        var payloadHash: String
        /// The plan payload as PLAN-FORMAT describes it, stored as the object
        /// it is rather than as escaped text.
        var payload: AnyJSON

        private enum CodingKeys: String, CodingKey { case id, clientId, clientID, sentAt, payloadHash, payload }

        init(id: UUID, clientId: String, sentAt: Int, payloadHash: String, payload: AnyJSON) {
            self.id = id
            self.clientId = clientId
            self.sentAt = sentAt
            self.payloadHash = payloadHash
            self.payload = payload
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // A UUID is kept as itself, so a re-restore is idempotent; any
            // other spelling another Coach might write is hashed into one
            // deterministically, the way `WebLibraryImporter` reads the
            // browser's ids.
            id = try BackupCodec.rowID(c.decode(String.self, forKey: .id))
            clientId = try c.decodeIfPresent(String.self, forKey: .clientId)
                ?? c.decode(String.self, forKey: .clientID)
            sentAt = ((try? c.decodeIfPresent(Int.self, forKey: .sentAt)) ?? nil) ?? 0
            payloadHash = ((try? c.decodeIfPresent(String.self, forKey: .payloadHash)) ?? nil) ?? ""
            payload = try c.decode(AnyJSON.self, forKey: .payload)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(clientId, forKey: .clientId)
            try c.encode(sentAt, forKey: .sentAt)
            try c.encode(payloadHash, forKey: .payloadHash)
            try c.encode(payload, forKey: .payload)
        }
    }

    /// A row id as a UUID: kept as itself when it is one, and hashed into one
    /// when it is not, so a file another Coach wrote still restores.
    static func rowID(_ raw: String) throws -> UUID {
        if let real = UUID(uuidString: raw) { return real }
        guard !raw.isEmpty else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "a row with no id"))
        }
        var hash = UInt64(5381)
        for byte in raw.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        var bytes = withUnsafeBytes(of: hash.bigEndian, Array.init)
        bytes += withUnsafeBytes(of: hash.littleEndian, Array.init)
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
                           bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// A day's sets in the order the client logged them: `ExerciseSet
    /// .orderIndex` where it is recorded, and the store's own order behind it
    /// for the sets written before Coach kept one. Nothing here invents an
    /// order for those; they simply keep the place they already had.
    static func orderedSets(_ day: TrainingDay) -> [ExerciseSet] {
        day.sets.enumerated()
            .sorted { left, right in
                let a = left.element.orderIndex ?? Int.max
                let b = right.element.orderIndex ?? Int.max
                return a == b ? left.offset < right.offset : a < b
            }
            .map(\.element)
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
        /// `true` on an exercise done each side, **omitted when not** -- never
        /// `false` (BACKUP-FORMAT.md, "The Coach backup's workouts"; Coach
        /// web's and Android's spelling). Anything but `true` reads as not,
        /// rather than failing the restore, and a file written before sides
        /// has no key and restores as it always did.
        var eachSide: Bool?

        private enum CodingKeys: String, CodingKey { case name, equipment, note, sets, eachSide }

        init(name: String, equipment: String, note: String?, sets: [BackupPrescribedSet], eachSide: Bool) {
            self.name = name
            self.equipment = equipment
            self.note = note
            self.sets = sets
            self.eachSide = eachSide ? true : nil
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            equipment = try c.decode(String.self, forKey: .equipment)
            note = try c.decodeIfPresent(String.self, forKey: .note)
            sets = try c.decode([BackupPrescribedSet].self, forKey: .sets)
            eachSide = (try? c.decodeIfPresent(Bool.self, forKey: .eachSide)) == true ? true : nil
        }
    }

    /// Kilograms, as stored. This file is Coach's own, not the wire, so there
    /// is no pounds conversion here -- adding one would be a silent 2.2x.
    private struct BackupPrescribedSet: Codable {
        var targetWeightKg: Double?
        var targetReps: Int?
        var targetRPE: Double?
        var targetDurationSec: Int?
        var targetDistanceMeters: Double?
        /// `"left"` or `"right"` on a set prescribed for one side, **omitted
        /// entirely when both** -- the spelling a logged set uses here. An
        /// unrecognised value, or one that is not a string, reads as both.
        var side: String?

        private enum CodingKeys: String, CodingKey {
            case targetWeightKg, targetReps, targetRPE, targetDurationSec, targetDistanceMeters, side
        }

        init(targetWeightKg: Double?, targetReps: Int?, targetRPE: Double?,
             targetDurationSec: Int?, targetDistanceMeters: Double?, side: SetSide?) {
            self.targetWeightKg = targetWeightKg
            self.targetReps = targetReps
            self.targetRPE = targetRPE
            self.targetDurationSec = targetDurationSec
            self.targetDistanceMeters = targetDistanceMeters
            self.side = side?.backupValue
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            targetWeightKg = try c.decodeIfPresent(Double.self, forKey: .targetWeightKg)
            targetReps = try c.decodeIfPresent(Int.self, forKey: .targetReps)
            targetRPE = try c.decodeIfPresent(Double.self, forKey: .targetRPE)
            targetDurationSec = try c.decodeIfPresent(Int.self, forKey: .targetDurationSec)
            targetDistanceMeters = try c.decodeIfPresent(Double.self, forKey: .targetDistanceMeters)
            side = SetSide.fromBackup((try? c.decodeIfPresent(String.self, forKey: .side)) ?? nil)?
                .backupValue
        }
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
        /// The window this client has sent, as day keys -- the union of every
        /// link's `r`..`t`. Optional, so a file written before it restores
        /// with both nil, which is "we do not know" and never "they logged
        /// nothing". See `PlanAndLog`.
        var coveredFrom: String?
        var coveredTo: String?
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
        /// Where the set sat in the day the client sent. Written only when it
        /// is known -- a set stored before Coach recorded the order has none,
        /// and inventing one from this array's order would claim an order
        /// nobody recorded. Sets are written in that order anyway, so a reader
        /// that ignores this key still sees the day as it happened.
        var orderIndex: Int?
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
        let sides = PrescriptionSides.load(from: context)
        // Road picks live in `UserDefaults`, keyed by client id, not in the
        // store -- see `RoadPicks`. Written as they are stored: an object of
        // lists, omitted entirely when a coach has marked none.
        let picks = RoadPicks.load(from: defaults)
        // A row whose payload will not parse is left out rather than written
        // as a string: this key is an object in every other Coach's file, and
        // a shape only this app can read is worse than one send going missing.
        let sentPlans: [BackupSentPlan] = try context.fetch(FetchDescriptor<SentPlan>())
            .compactMap { row in
                AnyJSON(data: row.payloadData).map {
                    BackupSentPlan(id: row.id, clientId: row.clientID, sentAt: row.sentAtEpochSec,
                                   payloadHash: row.payloadHash, payload: $0)
                }
            }

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
                        // Written in the order the client logged them, so a
                        // reader that knows nothing of `orderIndex` still gets
                        // the day as it happened; the index rides along for
                        // one that does.
                        sets: orderedSets(day).map { set in
                            BackupSet(exerciseName: set.exerciseName, equipment: set.equipment,
                                      weightLb: set.weightLb, reps: set.reps, rpe: set.rpe,
                                      durationSec: set.durationSec, distanceMeters: set.distanceMeters,
                                      isWarmup: set.isWarmup, orderIndex: set.orderIndex,
                                      side: set.side?.backupValue)
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
                },
                coveredFrom: client.coveredFrom, coveredTo: client.coveredTo
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
                                        targetDistanceMeters: set.targetDistanceMeters,
                                        side: sides.side(of: set))
                }, eachSide: sides.isEachSide(exercise))
            })
        }, sessions: sessions.map { session in
            BackupSession(id: session.id, clientID: session.clientID, dayKey: session.dayKey,
                          routineID: session.routineID)
        }, roadPicks: picks.isEmpty ? nil : picks,
           sentPlans: sentPlans.isEmpty ? nil : LenientRows(sentPlans))
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
            client.coveredFrom = backupClient.coveredFrom
            client.coveredTo = backupClient.coveredTo
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
                                           side: SetSide.fromBackup(backupSet.side),
                                           // Absent stays absent. A file written
                                           // before Coach recorded the order does
                                           // not know it, and this array's order
                                           // is not a record of it.
                                           orderIndex: backupSet.orderIndex)
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

        // Road picks: one list per client, so "merge by id" has nothing to key
        // on. A client this device already has picks for keeps them -- an
        // older backup must never delete newer work, the rule the rest of the
        // library follows -- and a client it has none for takes the file's.
        // A file written before road picks has no key at all and changes
        // nothing. Coach web restores it exactly this way.
        if let filePicks = backup.roadPicks, !filePicks.isEmpty {
            var stored = RoadPicks.load(from: defaults)
            var changed = false
            for (clientID, list) in filePicks where stored[clientID] == nil {
                let cleaned = RoadPicks.normalise(list)
                guard !cleaned.isEmpty else { continue }
                stored[clientID] = cleaned
                changed = true
            }
            if changed { RoadPicks.save(stored, to: defaults) }
        }

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
                if exerciseRow.eachSide == true {
                    context.insert(EachSideExercise(exerciseID: exercise.id))
                }
                for (order, setRow) in exerciseRow.sets.enumerated() {
                    let set = RoutinePrescribedSet(orderIndex: order, targetWeightKg: setRow.targetWeightKg,
                                                   targetReps: setRow.targetReps, targetRPE: setRow.targetRPE,
                                                   targetDurationSec: setRow.targetDurationSec,
                                                   targetDistanceMeters: setRow.targetDistanceMeters)
                    set.exercise = exercise
                    context.insert(set)
                    if let side = SetSide.fromBackup(setRow.side) {
                        context.insert(PrescribedSetSide(setID: set.id, side: side))
                    }
                }
            }
        }

        // Sent plans: rows with ids, merged by id and never deleted by an
        // older file -- the library half's rule, not the roster's, because an
        // older backup must not remove a send this device made since. Ids
        // compare case-insensitively like every other id in this file. A file
        // written before sent plans existed has no key at all and changes
        // nothing.
        if let rows = backup.sentPlans?.values, !rows.isEmpty {
            let existing = Set(try context.fetch(FetchDescriptor<SentPlan>())
                .map { $0.id.uuidString.lowercased() })
            var seen = existing
            var touched: Set<String> = []
            for row in rows {
                let id = row.id.uuidString.lowercased()
                guard !seen.contains(id), !row.clientId.isEmpty,
                      let payload = row.payload.data else { continue }
                seen.insert(id)
                touched.insert(row.clientId)
                context.insert(SentPlan(
                    id: row.id, clientID: row.clientId, sentAtEpochSec: row.sentAt,
                    // A file that carries no hash gets one computed here, so a
                    // re-send of a restored plan still replaces rather than
                    // duplicates.
                    payloadHash: row.payloadHash.isEmpty ? SentPlans.hash(payload: payload)
                                                         : row.payloadHash,
                    payloadData: payload))
            }
            // The cap is applied after the merge, so restoring two files
            // cannot leave a client with more rows than sending would.
            for clientID in touched { SentPlans.prune(clientID: clientID, in: context) }
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
