import SwiftUI
import SwiftData
import LiftCore
import LiftMap

@main
struct CoachApp: App {
    init() {
        // The second lock on MapLibre: nothing it asks for ever leaves the
        // device. The street download is the kit's own, not MapLibre's.
        MapNetworkGuard.install()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(for: CoachSchema.models)
        .commands { CoachCommands() }
    }
}
