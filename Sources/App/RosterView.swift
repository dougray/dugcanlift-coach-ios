import SwiftUI
import SwiftData
import LiftCore

struct RosterView: View {
    @Environment(\.modelContext) private var context
    /// Unsorted from SwiftData on purpose: the order the roster shows is
    /// quietest-first (see `orderedClients`), which `lastImportedAt` -- when
    /// the coach happened to tap a link -- has nothing to do with. Sorting
    /// here as well would just be a sort the view throws away.
    @Query private var clients: [Client]
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
                ForEach(orderedClients) { client in
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
        // No navigation title: the tab row above already says Roster, and the
        // browser build goes straight from its tabs into the content. Keeping
        // it meant the word appeared twice, one above the other.
        .navigationBarTitleDisplayMode(.inline)
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

    /// Quietest first, so the person who most needs attention is at the top
    /// and the list agrees with the silence banner directly above it. Ordering
    /// by `lastImportedAt` reflected when the coach happened to tap a link and
    /// disagreed with that banner outright.
    private var orderedClients: [Client] {
        ClientDisplay.orderedBySilence(clients,
                                       rank: { $0.daysSinceLastLoggedDay },
                                       name: { $0.name })
    }

    /// Same order as the list, so the banner names them in the order they
    /// appear rather than in a second, unrelated one.
    private var silentClients: [Client] {
        orderedClients.filter { ($0.daysSinceLastLoggedDay ?? Int.max) >= 7 }
    }
}
