import SwiftUI
import SwiftData

@main
struct CoachApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(for: [Client.self, Goal.self, TrainingDay.self, ExerciseSet.self, ClientFoodEntry.self])
    }
}
