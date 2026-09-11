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
                .tint(Theme.accent)
                .foregroundStyle(Theme.textPrimary)
                .listRowBackground(Theme.background)
            } else {
                ForEach(clients) { client in
                    NavigationLink(client.name) {
                        ClientDetailView(client: client)
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .listRowBackground(Theme.surface)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Roster")
        .toolbar {
            Button("Paste a Link") { showingPasteLink = true }
                .foregroundStyle(Theme.accent)
        }
        .sheet(isPresented: $showingPasteLink) {
            PasteLinkView()
        }
    }
}
