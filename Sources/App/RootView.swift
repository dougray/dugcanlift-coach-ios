import SwiftUI
import LiftCore

struct RootView: View {
    var body: some View {
        TabView {
            NavigationStack {
                RosterView()
            }
            .tabItem { Label("Roster", systemImage: "person.2") }

            TrainView()
                .tabItem { Label("Train", systemImage: "dumbbell") }

            NavigationStack {
                ConnectView()
            }
            .tabItem { Label("Connect", systemImage: "link") }
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
    }
}
