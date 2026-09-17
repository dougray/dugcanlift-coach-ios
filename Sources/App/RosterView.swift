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

    /// nil on iPhone, where a row pushes the client's page. Set by
    /// `RosterSplitView` at regular width, where a row selects the client shown
    /// beside the list instead.
    var selection: Binding<String?>? = nil

    var body: some View {
        list
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

    @ViewBuilder
    private var list: some View {
        if let selection {
            List(selection: selection) { rows }
        } else {
            List { rows }
        }
    }

    @ViewBuilder
    private var rows: some View {
        // Beside a client's page the page says it, once, in the larger space.
        if clients.isEmpty, selection == nil {
            ContentUnavailableView(
                "No Clients Yet",
                systemImage: "person.2",
                description: Text("Paste a log link from a client to get started.")
            )
            .tint(Theme.accent)
            .foregroundStyle(Theme.textPrimary)
            .listRowBackground(Theme.background)
        } else if !clients.isEmpty {
            if !silentClients.isEmpty {
                Section {
                    Text("\(silentClients.count) client\(silentClients.count == 1 ? "" : "s") logged nothing in a week: \(silentClients.map(\.name).joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                }
                .listRowBackground(Theme.background)
            }
            ForEach(orderedClients) { client in
                if let selection {
                    rowLabel(client)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .tag(client.id)
                        .foregroundStyle(Theme.textPrimary)
                        .listRowBackground(selection.wrappedValue == client.id
                                           ? Theme.accentMuted.opacity(0.55) : Theme.surface)
                } else {
                    NavigationLink {
                        ClientDetailView(client: client)
                    } label: {
                        rowLabel(client)
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .listRowBackground(Theme.surface)
                }
            }
        }
    }

    private func rowLabel(_ client: Client) -> some View {
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

/// The Roster at regular width: the client list on the left, the selected
/// client's page beside it.
///
/// One navigation stack around both, rather than a third split-view column:
/// Cook, Train and Connect have no list to put in that column, and swapping
/// between a two- and a three-column split view rebuilt the sidebar on every
/// section change.
struct RosterSplitView: View {
    @Query private var clients: [Client]
    /// The last client looked at, restored when the Roster comes back -- after
    /// visiting Cook, or on relaunch.
    @SceneStorage("rosterSelectedClientID") private var storedSelection = ""
    @State private var selection: String?

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width >= AdaptiveLayout.rosterSplitMinWidth {
                split
            } else {
                // Too narrow for a list beside a readable page -- an iPad mini
                // with its sidebar open -- so the phone's list-then-push.
                NavigationStack { RosterView() }
            }
        }
    }

    private var split: some View {
        NavigationStack {
            HStack(spacing: 0) {
                RosterView(selection: $selection)
                    .frame(width: AdaptiveLayout.rosterListWidth)
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(width: 1)
                    .ignoresSafeArea(edges: .bottom)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Theme.background)
            .navigationTitle(selected?.name ?? "Roster")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear(perform: restoreSelection)
        .onChange(of: clients.map(\.id)) { restoreSelection() }
        .onChange(of: selection) { _, new in storedSelection = new ?? "" }
    }

    @ViewBuilder
    private var detail: some View {
        if let selected {
            // Keyed on the client so switching clients starts at the top of the
            // new page rather than at the old page's scroll position.
            ClientDetailView(client: selected)
                .id(selected.id)
        } else {
            ContentUnavailableView(
                clients.isEmpty ? "No Clients Yet" : "No Client Selected",
                systemImage: "person.2",
                description: Text(clients.isEmpty
                                  ? "Paste a log link from a client to get started."
                                  : "Pick a client from the list.")
            )
            .foregroundStyle(Theme.textPrimary)
        }
    }

    private var selected: Client? {
        guard let selection else { return nil }
        return clients.first { $0.id == selection }
    }

    /// The stored client if it still exists; otherwise the one the list puts
    /// first, the quietest, since that is who most needs looking at.
    private func restoreSelection() {
        if let selection, clients.contains(where: { $0.id == selection }) { return }
        if clients.contains(where: { $0.id == storedSelection }) {
            selection = storedSelection
        } else {
            selection = ClientDisplay.orderedBySilence(clients,
                                                       rank: { $0.daysSinceLastLoggedDay },
                                                       name: { $0.name }).first?.id
        }
    }
}
