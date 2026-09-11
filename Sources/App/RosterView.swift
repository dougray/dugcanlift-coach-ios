import SwiftUI
import SwiftData

struct RosterView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Client.lastImportedAt) private var clients: [Client]
    @State private var showingPasteLink = false

    var body: some View {
        List {
            if clients.isEmpty {
                ContentUnavailableView(
                    "No Clients Yet",
                    systemImage: "person.2",
                    description: Text("Paste a log link from a client to get started.")
                )
            } else {
                ForEach(clients) { client in
                    NavigationLink(client.name) {
                        Text(client.name) // Replaced by ClientDetailView in Task 5.
                    }
                }
            }
        }
        .navigationTitle("Roster")
        .toolbar {
            Button("Paste a Link") { showingPasteLink = true }
        }
        .sheet(isPresented: $showingPasteLink) {
            PasteLinkView()
        }
    }
}
