import XCTest
import SwiftData
import LiftCore
@testable import Coach

/// The record of what was sent: `SentPlan`, its cap and its hash, how it
/// travels in a backup, and what a removal takes with it.
///
/// A port of Coach web's own `plan-log.test.mjs` cases for `record`,
/// `mergeBackup` and `hash`, plus the two this app needs that the browser did
/// not: a set's order and a client's covered window, both new columns on
/// models Coach owns.
final class SentPlanTests: XCTestCase {

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema(CoachSchema.models),
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    private func isolatedDefaults(_ name: String) -> UserDefaults {
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return suite
    }

    /// A payload that differs by one number, so two of them are two plans.
    private func payload(_ seed: Int, client: String = "c") -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try! encoder.encode(PlanPayload(
            v: 1, t: "plan", l: client, n: "Coach", r: nil, m: nil,
            w: [PlanWorkout(n: "Lower A", e: [PlanWorkoutExercise(
                n: "Back Squat", q: "Barbell", c: nil, s: [[Double(200 + seed), 5]])])],
            k: [PlanSession(d: "2026-10-12", x: 0)]))
    }

    // MARK: - Recording a send

    func testAnIdenticalReShareReplacesTheNewestRowRatherThanAddingOne() throws {
        let context = try context()
        let first = try XCTUnwrap(SentPlans.record(payload: payload(1), clientID: "c", in: context,
                                                   now: Date(timeIntervalSince1970: 100)))
        let id = first.id
        let again = try XCTUnwrap(SentPlans.record(payload: payload(1), clientID: "c", in: context,
                                                   now: Date(timeIntervalSince1970: 200)))
        XCTAssertEqual(SentPlans.forClient("c", in: context).count, 1)
        XCTAssertEqual(again.id, id, "the id stays, so a backup merges it as one row")
        XCTAssertEqual(again.sentAtEpochSec, 200)
    }

    func testADifferentPlanIsANewRowAndAnOlderMatchingOneIsLeftAlone() throws {
        let context = try context()
        SentPlans.record(payload: payload(1), clientID: "c", in: context,
                         now: Date(timeIntervalSince1970: 100))
        SentPlans.record(payload: payload(2), clientID: "c", in: context,
                         now: Date(timeIntervalSince1970: 200))
        SentPlans.record(payload: payload(1), clientID: "c", in: context,
                         now: Date(timeIntervalSince1970: 300))
        // A coach who went back to last week's plan after a week of something
        // else did send it again, and both dates are true.
        XCTAssertEqual(SentPlans.forClient("c", in: context).map(\.sentAtEpochSec), [300, 200, 100])
    }

    func testTheCapPrunesOldestFirstPerClientLeavingOtherClientsAlone() throws {
        let context = try context()
        SentPlans.record(payload: payload(0, client: "z"), clientID: "z", in: context,
                         now: Date(timeIntervalSince1970: 1))
        for index in 0..<(SentPlans.cap + 4) {
            SentPlans.record(payload: payload(index), clientID: "c", in: context,
                             now: Date(timeIntervalSince1970: TimeInterval(index + 1)))
        }
        let mine = SentPlans.forClient("c", in: context)
        XCTAssertEqual(mine.count, SentPlans.cap)
        XCTAssertEqual(mine.first?.sentAtEpochSec, SentPlans.cap + 4, "newest kept")
        XCTAssertEqual(mine.last?.sentAtEpochSec, 5, "oldest four pruned")
        XCTAssertEqual(SentPlans.forClient("z", in: context).count, 1)
    }

    /// Every way of sending a plan goes through `recordSend`, and what it
    /// files is byte for byte what the link carries.
    func testRecordSendFilesExactlyWhatTheLinkCarries() throws {
        let context = try context()
        let routine = Routine(name: "Lower A")
        context.insert(routine)
        let exercise = RoutineExercise(name: "Back Squat", equipment: "Barbell", orderIndex: 0)
        exercise.routine = routine
        context.insert(exercise)
        let set = RoutinePrescribedSet(orderIndex: 0, targetWeightKg: 100, targetReps: 5)
        set.exercise = exercise
        context.insert(set)
        let session = ScheduledSession(clientID: "c", dayKey: "2026-10-12", routineID: routine.id)
        context.insert(session)

        let row = try XCTUnwrap(PlanLinkEncoder.recordSend(
            routines: [routine], sessions: [session], lifterID: "c", coachName: "Sam", in: context))
        let expected = try XCTUnwrap(PlanLinkEncoder.json(routines: [routine], sessions: [session],
                                                          lifterID: "c", coachName: "Sam"))
        XCTAssertEqual(row.payloadData, expected)
        XCTAssertEqual(row.payloadHash, SentPlans.hash(payload: expected))
        // And it reads back as the plan it was: kilograms went out as pounds.
        let decoded = try JSONDecoder().decode(PlanPayload.self, from: row.payloadData)
        XCTAssertEqual(decoded.k?.first?.d, "2026-10-12")
        XCTAssertEqual(decoded.w?.first?.e.first?.s.first?.first??.rounded(), 220)
    }

    /// A library send -- recipes or workouts with nothing scheduled -- books
    /// no day. It would show as no group on the card while taking one of the
    /// 26 rows kept per client.
    func testASendThatBooksNoDayIsNotRecorded() throws {
        let context = try context()
        let routine = Routine(name: "Lower A")
        context.insert(routine)
        let exercise = RoutineExercise(name: "Back Squat", equipment: "Barbell", orderIndex: 0)
        exercise.routine = routine
        context.insert(exercise)

        // A programme with no bookings at all.
        XCTAssertNil(PlanLinkEncoder.recordSend(routines: [routine], sessions: [],
                                                lifterID: "c", coachName: "Sam", in: context))
        // And a recipe library with nothing booked into a day.
        let recipe = Recipe(name: "Beef Chilli", servings: 4)
        context.insert(recipe)
        XCTAssertNil(PlanLinkEncoder.recordSend(recipes: [recipe], lifterID: "c",
                                                coachName: "Sam", in: context))
        // And a picks-only send, which is every key but a booked day.
        XCTAssertNil(PlanLinkEncoder.recordSend(roadPicks: ["wendys-large-chili"], lifterID: "c",
                                                coachName: "Sam", in: context))
        XCTAssertTrue(SentPlans.forClient("c", in: context).isEmpty)
    }

    /// **A booked meal is a booked day.** This read `k` alone until meals
    /// reached the Booked card, which meant Cook's send -- the only send that
    /// carries `m` on this platform -- was never filed at all, so a coach who
    /// plans food had no record of what they sent.
    func testAWeekThatBooksOnlyMealsIsRecorded() throws {
        let context = try context()
        let recipe = Recipe(name: "Beef Chilli", servings: 4)
        context.insert(recipe)
        let plannedFor = try XCTUnwrap(DayKey.date(from: "2026-10-12"))
        let meal = PlannedMeal(recipe: recipe, mealType: .dinner, plannedFor: plannedFor,
                               servings: 2)
        context.insert(meal)

        let row = try XCTUnwrap(PlanLinkEncoder.recordSend(
            recipes: [recipe], meals: [meal], lifterID: "c", coachName: "Sam", in: context))
        XCTAssertEqual(row.clientID, "c")
        let decoded = try JSONDecoder().decode(PlanPayload.self, from: row.payloadData)
        XCTAssertEqual(decoded.m?.first?.d, "2026-10-12")
        XCTAssertNil(decoded.k, "and it booked no session")
    }

    // MARK: - The hash

    func testTheHashIsTheCanonicalReEncode() throws {
        let sorted = Data(#"{"k":[{"d":"2026-10-12","x":0}],"t":"plan","v":1}"#.utf8)
        let shuffled = Data(#"{"v":1,"t":"plan","k":[{"x":0,"d":"2026-10-12"}]}"#.utf8)
        XCTAssertEqual(SentPlans.hash(payload: sorted), SentPlans.hash(payload: shuffled))
        XCTAssertEqual(SentPlans.hash(payload: sorted).count, 64)
        // Array order is part of the plan, not incidental.
        let one = Data(#"{"k":[{"d":"2026-10-13"},{"d":"2026-10-12"}]}"#.utf8)
        let other = Data(#"{"k":[{"d":"2026-10-12"},{"d":"2026-10-13"}]}"#.utf8)
        XCTAssertNotEqual(SentPlans.hash(payload: one), SentPlans.hash(payload: other))
    }

    /// The canonical form is web's, character for character, so the two apps
    /// compute the same digest for the same plan.
    func testTheCanonicalFormSortsKeysAtEveryDepth() {
        let raw = Data(#"{"b":{"z":1,"a":[1,2]},"a":"x"}"#.utf8)
        XCTAssertEqual(SentPlans.canonical(payload: raw), #"{"a":"x","b":{"a":[1,2],"z":1}}"#)
    }

    // MARK: - The backup

    private func backupData(_ context: ModelContext, _ defaults: UserDefaults) throws -> [String: Any] {
        let data = try BackupCodec.export(from: context, defaults: defaults)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testABackupWrittenBeforeSentPlansExistedRestoresUnchanged() throws {
        let source = try context()
        let defaults = isolatedDefaults("sentplans.none")
        let client = Client(id: "c", name: "Sam", displayUnit: "lb", platform: "ios")
        source.insert(client)
        try source.save()
        let file = try backupData(source, defaults)
        XCTAssertNil(file["sentPlans"], "omitted entirely when there are none")

        // A device that has one keeps it when that file is restored.
        let target = try context()
        SentPlans.record(payload: payload(1), clientID: "c", in: target,
                         now: Date(timeIntervalSince1970: 300))
        try BackupCodec.restore(from: try BackupCodec.export(from: source, defaults: defaults),
                                into: target, defaults: defaults)
        XCTAssertEqual(SentPlans.forClient("c", in: target).count, 1)
    }

    func testARoundTripThroughTheBackupKeepsEveryField() throws {
        let source = try context()
        let defaults = isolatedDefaults("sentplans.roundtrip")
        let client = Client(id: "c", name: "Sam", displayUnit: "lb", platform: "ios")
        source.insert(client)
        let row = try XCTUnwrap(SentPlans.record(payload: payload(3), clientID: "c", in: source,
                                                  now: Date(timeIntervalSince1970: 1760745600)))
        let id = row.id, hash = row.payloadHash, bytes = row.payloadData
        try source.save()

        let file = try backupData(source, defaults)
        let rows = try XCTUnwrap(file["sentPlans"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["clientId"] as? String, "c", "Coach web's and Android's spelling")
        XCTAssertEqual(rows[0]["sentAt"] as? Int, 1760745600)
        XCTAssertNotNil(rows[0]["payload"] as? [String: Any], "an object, never escaped text")

        let target = try context()
        try BackupCodec.restore(from: try BackupCodec.export(from: source, defaults: defaults),
                                into: target, defaults: defaults)
        let restored = try XCTUnwrap(SentPlans.forClient("c", in: target).first)
        XCTAssertEqual(restored.id, id)
        XCTAssertEqual(restored.sentAtEpochSec, 1760745600)
        XCTAssertEqual(restored.payloadHash, hash)
        XCTAssertEqual(SentPlans.hash(payload: restored.payloadData), SentPlans.hash(payload: bytes))
    }

    func testAnOlderBackupNeverDeletesANewerSendAndMergesById() throws {
        let defaults = isolatedDefaults("sentplans.merge")
        let old = try context()
        let client = Client(id: "c", name: "Sam", displayUnit: "lb", platform: "ios")
        old.insert(client)
        SentPlans.record(payload: payload(1), clientID: "c", in: old,
                         now: Date(timeIntervalSince1970: 100))
        try old.save()
        let file = try BackupCodec.export(from: old, defaults: defaults)

        let device = try context()
        let newer = try XCTUnwrap(SentPlans.record(payload: payload(9), clientID: "c", in: device,
                                                    now: Date(timeIntervalSince1970: 900)))
        let newerID = newer.id
        try device.save()
        try BackupCodec.restore(from: file, into: device, defaults: defaults)

        let rows = SentPlans.forClient("c", in: device)
        XCTAssertEqual(rows.count, 2, "the older file adds its row and removes nothing")
        XCTAssertEqual(rows.first?.id, newerID)
        XCTAssertEqual(rows.first?.sentAtEpochSec, 900, "the newer send is untouched")

        // Restoring the same file twice is the same one row: merged by id.
        try BackupCodec.restore(from: file, into: device, defaults: defaults)
        XCTAssertEqual(SentPlans.forClient("c", in: device).count, 2)
    }

    func testARestoreCannotLeaveAClientWithMoreRowsThanSendingWould() throws {
        let defaults = isolatedDefaults("sentplans.cap")
        let source = try context()
        source.insert(Client(id: "c", name: "Sam", displayUnit: "lb", platform: "ios"))
        for index in 0..<(SentPlans.cap + 5) {
            SentPlans.record(payload: payload(index), clientID: "c", in: source,
                             now: Date(timeIntervalSince1970: TimeInterval(index + 1)))
        }
        try source.save()
        let target = try context()
        try BackupCodec.restore(from: try BackupCodec.export(from: source, defaults: defaults),
                                into: target, defaults: defaults)
        XCTAssertEqual(SentPlans.forClient("c", in: target).count, SentPlans.cap)
    }

    /// The covered window travels too, or a restore would leave Coach unable
    /// to tell "not logged" from "outside the log they sent".
    func testTheCoveredWindowSurvivesABackup() throws {
        let defaults = isolatedDefaults("sentplans.coverage")
        let source = try context()
        let client = Client(id: "c", name: "Sam", displayUnit: "lb", platform: "ios")
        client.covered = CoveredRange(from: "2026-09-21", to: "2026-10-16")
        source.insert(client)
        try source.save()

        let target = try context()
        try BackupCodec.restore(from: try BackupCodec.export(from: source, defaults: defaults),
                                into: target, defaults: defaults)
        let restored = try XCTUnwrap(try target.fetch(FetchDescriptor<Client>()).first)
        XCTAssertEqual(restored.covered, CoveredRange(from: "2026-09-21", to: "2026-10-16"))
    }

    /// The union, with its cost stated: a later link widens the window rather
    /// than replacing it.
    func testACoveredWindowIsTheUnionOfEveryLink() {
        let first = ClientCoverage.absorbed(existing: nil,
                                            link: CoveredRange(from: "2026-09-01", to: "2026-09-30"))
        XCTAssertEqual(first, CoveredRange(from: "2026-09-01", to: "2026-09-30"))
        let widened = ClientCoverage.absorbed(existing: first,
                                              link: CoveredRange(from: "2026-10-01", to: "2026-10-16"))
        XCTAssertEqual(widened, CoveredRange(from: "2026-09-01", to: "2026-10-16"))
        // An older link pasted late widens backwards and never narrows.
        let older = ClientCoverage.absorbed(existing: widened,
                                            link: CoveredRange(from: "2026-08-01", to: "2026-08-07"))
        XCTAssertEqual(older, CoveredRange(from: "2026-08-01", to: "2026-10-16"))
    }

    /// The order the sets were logged in survives a backup; a file written
    /// before Coach recorded it restores with none, rather than inventing one
    /// out of the array's order.
    func testSetOrderSurvivesABackupAndAbsentStaysAbsent() throws {
        let defaults = isolatedDefaults("sentplans.order")
        let source = try context()
        let client = Client(id: "c", name: "Sam", displayUnit: "lb", platform: "ios")
        source.insert(client)
        let day = TrainingDay(client: client, dayKey: "2026-10-12")
        source.insert(day)
        client.trainingDays.append(day)
        for (index, weight) in [(1, 235.0), (0, 225.0)] {
            let set = ExerciseSet(day: day, exerciseName: "Back Squat", equipment: "Barbell",
                                  weightLb: weight, reps: 5, orderIndex: index)
            source.insert(set)
            day.sets.append(set)
        }
        try source.save()

        let data = try BackupCodec.export(from: source, defaults: defaults)
        let file = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let clients = try XCTUnwrap(file["clients"] as? [[String: Any]])
        let days = try XCTUnwrap(clients[0]["days"] as? [[String: Any]])
        let sets = try XCTUnwrap(days[0]["sets"] as? [[String: Any]])
        XCTAssertEqual(sets.map { $0["weightLb"] as? Double }, [225, 235],
                       "written in the order the client logged them")
        XCTAssertEqual(sets.map { $0["orderIndex"] as? Int }, [0, 1])

        let target = try context()
        try BackupCodec.restore(from: data, into: target, defaults: defaults)
        let restoredDay = try XCTUnwrap(try target.fetch(FetchDescriptor<TrainingDay>()).first)
        XCTAssertEqual(BackupCodec.orderedSets(restoredDay).map(\.weightLb), [225, 235])

        // A file with no `orderIndex` at all restores with none: this array's
        // order is not a record of an order nobody kept.
        var older = file
        var olderClients = clients
        var olderDays = days
        olderDays[0]["sets"] = sets.map { set -> [String: Any] in
            var copy = set
            copy.removeValue(forKey: "orderIndex")
            return copy
        }
        olderClients[0]["days"] = olderDays
        older["clients"] = olderClients
        let blank = try context()
        try BackupCodec.restore(from: JSONSerialization.data(withJSONObject: older),
                                into: blank, defaults: defaults)
        let blankDay = try XCTUnwrap(try blank.fetch(FetchDescriptor<TrainingDay>()).first)
        XCTAssertTrue(blankDay.sets.allSatisfy { $0.orderIndex == nil })
    }

    /// Coach web's restore skips a row missing an id, a client or a payload
    /// and keeps going. A record of one send is not worth failing a file that
    /// also carries the roster.
    func testAMalformedSentPlanRowIsSkippedRatherThanFailingTheFile() throws {
        let context = try context()
        let defaults = isolatedDefaults("sentplans.lenient")
        let file = """
        {"v":2,"clients":[{"id":"c","name":"Sam","displayUnit":"lb","days":[]}],
         "sentPlans":[
           {"clientId":"c","sentAt":1,"payload":{"v":1}},
           {"id":"not-a-uuid","clientId":"c","sentAt":2,"payloadHash":"",
            "payload":{"v":1,"t":"plan","l":"c","k":[]}},
           {"id":"3f2a0c1e-5b7d-4a2f-9c11-0e5d7b3a1f24","clientId":"c","sentAt":3,
            "payloadHash":"h","payload":{"v":1,"t":"plan","l":"c"}}]}
        """
        try BackupCodec.restore(from: Data(file.utf8), into: context, defaults: defaults)

        // The roster restored, and the two readable rows with it.
        XCTAssertEqual(try context.fetch(FetchDescriptor<Client>()).count, 1)
        XCTAssertEqual(SentPlans.forClient("c", in: context).map(\.sentAtEpochSec), [3, 2],
                       "the row with no id at all is the only one dropped")
    }

    // MARK: - Removing a client

    func testARemovalTakesTheClientsSentPlansAndLeavesEveryoneElses() throws {
        let context = try context()
        let defaults = isolatedDefaults("sentplans.removal")
        let jordan = Client(id: "jordan", name: "Jordan Reyes", displayUnit: "lb", platform: "ios")
        let sam = Client(id: "sam", name: "Sam Ortiz", displayUnit: "kg", platform: "and")
        context.insert(jordan)
        context.insert(sam)
        SentPlans.record(payload: payload(1, client: "jordan"), clientID: "jordan", in: context)
        SentPlans.record(payload: payload(2, client: "sam"), clientID: "sam", in: context)
        try context.save()

        let outcome = ClientRemoval.remove(clientID: "jordan", in: context, defaults: defaults)
        XCTAssertTrue(outcome.removed)
        XCTAssertTrue(SentPlans.forClient("jordan", in: context).isEmpty)
        XCTAssertEqual(SentPlans.forClient("sam", in: context).count, 1)

        // And a backup written afterwards does not mention them.
        let file = String(decoding: try BackupCodec.export(from: context, defaults: defaults),
                          as: UTF8.self)
        XCTAssertFalse(file.contains("jordan"))
    }

    /// Three Coach builds pin this sentence word for word, and it was written
    /// before sent plans existed. It gains a clause in all three at once or in
    /// none -- the call road picks already made.
    func testTheConfirmationSentenceIsUnchangedByAnyOfThis() {
        let impact = RemovalImpact(clientID: "jordan", clientName: "Jordan Reyes",
                                   loggedDays: 2, plannedMeals: 2, bookedSessions: 1)
        let text = ClientRemoval.confirmationText(impact)
        XCTAssertEqual(text,
            "Their 2 logged days will be removed from this device, and the 2 planned meals "
            + "and 1 booked session you made for them. Your recipes and routines stay. "
            + "A backup file you saved earlier still has them. This can't be undone.")
        for clause in ["sent plan", "plan you sent", "road pick"] {
            XCTAssertFalse(text.lowercased().contains(clause), "the sentence gained \"\(clause)\"")
        }
    }

    // MARK: - A web backup

    func testAWebBackupsSentPlansReachThePhone() throws {
        let context = try context()
        let defaults = isolatedDefaults("sentplans.web")
        let file = """
        {"v":2,"clients":[{"id":"c"}],"recipes":[],"plans":[],"workouts":[],"sessions":[],
         "sentPlans":[{"id":"3f2a0c1e-5b7d-4a2f-9c11-0e5d7b3a1f24","clientId":"c",
           "sentAt":1760745600,"payloadHash":"",
           "payload":{"v":1,"t":"plan","l":"c","n":"Coach","r":[],"m":[],
             "w":[{"n":"Lower A","e":[{"n":"Back Squat","q":"Barbell","s":[[225,5]]}]}],
             "k":[{"d":"2026-10-12","x":0}]}}]}
        """
        let summary = try WebLibraryImporter.importLibrary(from: Data(file.utf8), into: context,
                                                            defaults: defaults)
        XCTAssertEqual(summary.sentPlans, 1)
        let row = try XCTUnwrap(SentPlans.forClient("c", in: context).first)
        XCTAssertEqual(row.sentAtEpochSec, 1760745600)
        XCTAssertFalse(row.payloadHash.isEmpty, "a file with no hash gets one computed here")
        let plan = try JSONDecoder().decode(PlanPayload.self, from: row.payloadData)
        XCTAssertEqual(plan.w?.first?.n, "Lower A")

        // Importing the same file again is the same one row.
        _ = try WebLibraryImporter.importLibrary(from: Data(file.utf8), into: context,
                                                 defaults: defaults)
        XCTAssertEqual(SentPlans.forClient("c", in: context).count, 1)
    }
}
