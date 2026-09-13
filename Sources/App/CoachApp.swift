import SwiftUI
import SwiftData
import LiftCore

@main
struct CoachApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(for: [
            Client.self, Goal.self, TrainingDay.self, ExerciseSet.self,
            ClientFoodEntry.self,
            Routine.self, RoutineExercise.self, RoutinePrescribedSet.self,
            ScheduledSession.self,
            // Cook. LiftCore.FoodEntry is deliberately absent: PlannedMeal
            // can build one, but a coach plans meals rather than logging
            // them, so Coach never persists one.
            Recipe.self, RecipeIngredient.self, PlannedMeal.self, ShoppingListCheck.self,
        ])
    }
}
