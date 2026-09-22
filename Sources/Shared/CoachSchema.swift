import SwiftData
import LiftCore

/// Every `@Model` type in Coach's store, in one place.
///
/// `CoachApp` builds its container from this list, and so do the tests that
/// claim to exercise "the app's actual schema" -- they used to carry their own
/// copies, which could drift from the app without any test noticing.
enum CoachSchema {
    static let models: [any PersistentModel.Type] = [
        Client.self, Goal.self, TrainingDay.self, ExerciseSet.self,
        ClientFoodEntry.self,
        Routine.self, RoutineExercise.self, RoutinePrescribedSet.self,
        ScheduledSession.self,
        // Per-side prescriptions: Coach's own rows keyed by exercise and set
        // id, not properties on LiftKit's shared routine models -- see
        // PrescriptionSides.swift for why.
        EachSideExercise.self, PrescribedSetSide.self,
        // Cook. LiftCore.FoodEntry is deliberately absent: PlannedMeal can
        // build one, but a coach plans meals rather than logging them, so
        // Coach never persists one.
        //
        // LiftCore.ShoppingListCheck is absent too, as of the per-client
        // ticks: it is keyed by item name alone, so a tick reached every
        // client. Dropping the entity drops whatever shared ticks an older
        // build stored -- one week's shop, re-tickable in seconds -- and the
        // store otherwise opens as before (checked by installing over a real
        // store holding ticks, not assumed).
        Recipe.self, RecipeIngredient.self, PlannedMeal.self,
        ClientShoppingCheck.self,
    ]
}
