import SwiftUI
import SwiftData
import LiftCore

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
                if !silentClients.isEmpty {
                    Section {
                        Text("\(silentClients.count) client\(silentClients.count == 1 ? "" : "s") logged nothing in a week: \(silentClients.map(\.name).joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(Theme.accent)
                    }
                    .listRowBackground(Theme.background)
                }
                ForEach(clients) { client in
                    NavigationLink {
                        ClientDetailView(client: client)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(client.name)
                            Text(silenceText(for: client))
                                .font(.caption)
                                .foregroundStyle(
                                    (client.daysSinceLastLoggedDay ?? Int.max) >= 7
                                        ? Theme.accent : Theme.textSecondary
                                )
                        }
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

    private func silenceText(for client: Client) -> String {
        guard let days = client.daysSinceLastLoggedDay else { return "Nothing logged yet" }
        if days <= 0 { return "Logged today" }
        if days == 1 { return "Logged yesterday" }
        return "Logged \(days) days ago"
    }

    private var silentClients: [Client] {
        clients.filter { ($0.daysSinceLastLoggedDay ?? Int.max) >= 7 }
    }
}
