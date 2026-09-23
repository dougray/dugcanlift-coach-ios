import Foundation
import SwiftData
import LiftCore

/// What removing one client takes with it, counted before anything is deleted.
///
/// `clientID` travels with the counts so the confirmation is self-contained:
/// the view that shows it holds this value and nothing else, and never reads a
/// `Client` the removal is about to delete.
struct RemovalImpact: Equatable {
    let clientID: String
    let clientName: String
    let loggedDays: Int
    let plannedMeals: Int
    let bookedSessions: Int
}

/// The result of a removal, in the words the coach reads.
///
/// Coach Android carries a third flag here, `problem`, for a removal that took
/// the client but could not clean up after them: its Cook and Train libraries
/// are two separate JSON files, and an unreadable one is left alone rather than
/// saved over. There is no analogue in this app -- one SwiftData store holds
/// all of it, and a `save()` that throws is rolled back whole, so a removal
/// either happened or changed nothing.
struct RemovalOutcome: Equatable {
    let removed: Bool
    let message: String
}

/// Removing a client, and everything that was only ever about them.
///
/// The decision is here rather than in the view for the reason `MacroFields`
/// and `LinkImportMacros` are: a rule living in a view's `@State` cannot be
/// tested, and this one decides what a coach loses. A port of Coach Android's
/// `ClientRemoval.kt`, down to the wording of the confirmation -- a coach who
/// reads the sentence on one platform must read the same sentence on the
/// other. Coach web asks a shorter question and deletes less (it leaves its
/// planned meals and booked sessions orphaned in local storage); Android is
/// the deliberate upgrade, and this follows Android.
///
/// **What goes:** the `Client` -- and by SwiftData's own cascade rules its
/// `Goal`, its `TrainingDay`s and, through those, every `ExerciseSet` and
/// `ClientFoodEntry` -- plus the rows that name the client as a plain value,
/// which no cascade reaches: `ScheduledSession`s booked for them,
/// `PlannedMeal`s owned by them through the `cookPlanOwners` map, their
/// `ClientShoppingCheck` ticks, and their `roadPicks`. Those carry the
/// client's id and nothing else: with the client gone they show in no week,
/// can never be sent or edited, and would still ride along in every backup.
///
/// **Road picks are not in the confirmation sentence.** That sentence is Coach
/// Android's, word for word, and it was written before road picks existed;
/// when Coach for Android gains them the sentence gains a clause in both
/// places at once, not here alone. Coach web made the same call for the same
/// reason.
///
/// **What stays:** recipes and routines. They are the coach's own library,
/// written once and reused across clients; a template a client was booked onto
/// is not the client's to take with them.
enum ClientRemoval {

    /// What removing this client would take, or `nil` when they are no longer
    /// on this device -- removed in the other pane of an iPad, or restored
    /// over. The caller shows nothing until this returns: a confirmation whose
    /// counts arrive after it is on screen is a sentence that changes under a
    /// thumb.
    static func impact(clientID: String, in context: ModelContext,
                       defaults: UserDefaults = .standard) -> RemovalImpact? {
        guard let client = client(clientID, in: context) else { return nil }
        return RemovalImpact(
            clientID: clientID,
            clientName: client.name,
            loggedDays: client.trainingDays.count,
            plannedMeals: meals(ownedBy: clientID, in: context, defaults: defaults).count,
            bookedSessions: sessions(for: clientID, in: context).count)
    }

    /// Removes the client and everything that was only about them, in one
    /// save. Nothing here touches a recipe or a routine.
    static func remove(clientID: String, in context: ModelContext,
                       defaults: UserDefaults = .standard) -> RemovalOutcome {
        guard let client = client(clientID, in: context) else {
            // Already gone. Nothing to delete and nothing to warn about: the
            // caller should leave the page either way, so this is not a
            // failure.
            return RemovalOutcome(removed: true, message: alreadyGoneMessage)
        }
        // Read before the delete: a deleted model is not a safe thing to ask
        // for a name.
        let name = client.name

        let ownedMeals = meals(ownedBy: clientID, in: context, defaults: defaults)
        for meal in ownedMeals { context.delete(meal) }
        for session in sessions(for: clientID, in: context) { context.delete(session) }
        for check in checks(for: clientID, in: context) { context.delete(check) }
        context.delete(client)

        do {
            try context.save()
        } catch {
            // All of it or none of it. A half-removed client -- their days
            // gone but their week still full of meals nobody can open -- is
            // worse than a removal that did not happen and says so.
            context.rollback()
            return RemovalOutcome(removed: false,
                                  message: "Couldn't remove \(name). Nothing was changed.")
        }

        // Swept only after the store has committed, so a rollback leaves each
        // meal's ownership with the meal. Every entry pointing at this client
        // goes, not only the ones whose meals were found: a stale entry is a
        // violation of the contract this key is (see CLAUDE.md, "A planned
        // meal's client lives in `@AppStorage`, not on the model").
        sweepOwners(of: clientID, defaults: defaults)
        // Road picks go the same way and for the same reason: a list made for
        // one client, keyed by their id, which with the client gone can be
        // neither seen nor sent while still riding in every backup. Also
        // after the commit, so a rolled-back removal keeps them.
        RoadPicks.remove(clientID: clientID, in: defaults)

        return RemovalOutcome(removed: true, message: "Removed \(name).")
    }

    // MARK: - What the coach reads

    /// "Remove Jordan Reyes?" -- empty when there is nothing to confirm, so a
    /// view can hand it whatever it currently holds.
    static func confirmationTitle(_ impact: RemovalImpact?) -> String {
        guard let impact else { return "" }
        return "Remove \(impact.clientName)?"
    }

    /// Names what goes and what stays, with counts. Coach Android's sentence,
    /// word for word, including its two rules about zero: a logged-day count is
    /// always said, even when it is none, because that is what a coach is
    /// deleting; a planned-meal or booked-session count is left out entirely
    /// when it is zero, rather than reading "and the 0 planned meals you made
    /// for them".
    static func confirmationText(_ impact: RemovalImpact) -> String {
        let days = impact.loggedDays == 1 ? "1 logged day" : "\(impact.loggedDays) logged days"
        var planned: [String] = []
        if impact.plannedMeals > 0 {
            planned.append(impact.plannedMeals == 1 ? "1 planned meal"
                                                    : "\(impact.plannedMeals) planned meals")
        }
        if impact.bookedSessions > 0 {
            planned.append(impact.bookedSessions == 1 ? "1 booked session"
                                                      : "\(impact.bookedSessions) booked sessions")
        }
        let also = planned.isEmpty ? ""
            : ", and the " + planned.joined(separator: " and ") + " you made for them"
        return "Their \(days) will be removed from this device\(also). "
             + "Your recipes and routines stay. A backup file you saved earlier still has them. "
             + "This can't be undone."
    }

    /// Said when the client is not there to remove -- the iPad's two panes, or
    /// a restore that landed in between.
    static let alreadyGoneMessage = "This client is no longer on this device."

    // MARK: - Finding what belongs to one client

    private static func client(_ clientID: String, in context: ModelContext) -> Client? {
        var descriptor = FetchDescriptor<Client>(predicate: #Predicate { $0.id == clientID })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// `PlannedMeal` has no client field of its own -- it is `LiftCore`'s,
    /// shared with LIFT, where a planned meal belongs to the only person on the
    /// device -- so ownership is read from the `cookPlanOwners` map through the
    /// one helper that owns it.
    private static func meals(ownedBy clientID: String, in context: ModelContext,
                              defaults: UserDefaults) -> [PlannedMeal] {
        let owners = MealOwners.load(from: defaults)
        guard !owners.isEmpty else { return [] }
        let all = (try? context.fetch(FetchDescriptor<PlannedMeal>())) ?? []
        return all.filter { owners[$0.id.uuidString] == clientID }
    }

    private static func sessions(for clientID: String, in context: ModelContext) -> [ScheduledSession] {
        let descriptor = FetchDescriptor<ScheduledSession>(
            predicate: #Predicate { $0.clientID == clientID })
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func checks(for clientID: String, in context: ModelContext) -> [ClientShoppingCheck] {
        let descriptor = FetchDescriptor<ClientShoppingCheck>(
            predicate: #Predicate { $0.clientID == clientID })
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Drops every `cookPlanOwners` entry pointing at this client, and writes
    /// nothing when there are none -- a client who was never planned for must
    /// not cost a write, the way Android leaves an untouched library file's
    /// timestamp alone.
    private static func sweepOwners(of clientID: String, defaults: UserDefaults) {
        var owners = MealOwners.load(from: defaults)
        let theirs = owners.filter { $0.value == clientID }.map(\.key)
        guard !theirs.isEmpty else { return }
        for key in theirs { owners.removeValue(forKey: key) }
        MealOwners.save(owners, to: defaults)
    }
}
