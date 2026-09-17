import SwiftUI
import SwiftData
import LiftCore

@main
struct CoachApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(for: CoachSchema.models)
        .commands { CoachCommands() }
    }
}
