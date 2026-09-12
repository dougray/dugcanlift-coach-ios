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
        ])
    }
}
