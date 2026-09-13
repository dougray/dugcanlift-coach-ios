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

            CookView()
                .tabItem { Label("Cook", systemImage: "fork.knife") }

            NavigationStack {
                ConnectView()
            }
            .tabItem { Label("Connect", systemImage: "link") }
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
    }
}
