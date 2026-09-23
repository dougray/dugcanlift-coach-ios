import SwiftUI
import SwiftData
import LiftCore

/// Cook → Road: the Road Food items a coach is happy with for one client.
///
/// **Why it is in Cook**, beside the week and the shopping list, rather than
/// on the client's page: that page is a record of what a client did, and this
/// is something the coach makes for them -- addressed to one person and sent
/// in the same plan link as the rest of Cook. Train would have been the other
/// candidate and is the wrong half of the app; this is food. Coach web puts it
/// in exactly the same place, as a fourth section on the same client selector.
///
/// A pick says "this fits how I want you eating on the road" and nothing about
/// calories or macros: LIFT already ranks Road Food against what is left of
/// the client's day, and a pick floats to the top of that list, labelled,
/// without re-ranking the numbers underneath or hiding anything that fits.
/// Nothing here or there judges what a client ate against what was picked --
/// shown, never targeted, the discipline saturated fat and the imbalance
/// figure are held to.
///
/// The rules are `RoadPicks`, which is where they are tested. This is the
/// screen.
struct RoadPicksView: View {
    @Query(sort: \Client.name) private var clients: [Client]
    @Binding var clientID: String

    @AppStorage(RoadPicks.key) private var picksData = Data()
    /// Which place cards are open, so ticking an item does not fold them all
    /// up. Deliberately not persisted: it is where a thumb is, not a record.
    @State private var open: Set<String> = []
    @State private var confirmingClear = false

    private let catalog = RoadFoodCatalog.shared

    var body: some View {
        AdaptiveScrollPage { width in
            let columns = AdaptiveLayout.columns(for: width, maxColumns: 2)

            LiftCard(title: "Picking for") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Client", selection: $clientID) {
                        Text("Pick a client").tag("")
                        ForEach(clients) { Text($0.name).tag($0.id) }
                    }
                    .tint(Theme.accent)
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            if let catalog, !clients.isEmpty, !clientID.isEmpty {
                summaryCard(catalog)
                AdaptiveGrid(places(catalog), id: \.id, columns: columns) { place in
                    placeCard(place)
                }
            } else if catalog == nil {
                LiftCard(title: "Road") {
                    Text("The Road Food list isn't in this build. It ships with the app, "
                         + "so this is a bad install rather than something to wait out.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .coachScreen()
        .background(Theme.background)
        .alert("Clear every road pick for \(clientName)?", isPresented: $confirmingClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) { setPicks([]) }
        } message: {
            Text("They stay picked in LIFT until this client's next plan link, which carries "
                 + "whatever is marked here.")
        }
    }

    private var note: String {
        if clients.isEmpty {
            return "No clients yet. Picks are made for one person, so add a client first."
        }
        if clientID.isEmpty {
            return "Picks are made for one person. Choose the client you are marking for."
        }
        return "Marked here, sent with the plan link. In LIFT they sit at the top of that "
            + "place's list, named as yours. The ranking underneath is unchanged, and nothing "
            + "that fits is hidden."
    }

    // MARK: - What is picked

    private func summaryCard(_ catalog: RoadFoodCatalog) -> some View {
        let ids = picks
        let summary = RoadPicks.summary(ids, in: catalog)
        let missing = RoadPicks.missing(ids, in: catalog)
        return LiftCard(title: "Picked") {
            VStack(alignment: .leading, spacing: 8) {
                Text(summary.isEmpty
                     ? "Nothing picked for \(clientName) yet."
                     : "\(summary) picked for \(clientName).")
                    .font(Theme.body)
                    .foregroundStyle(Theme.textPrimary)
                // A pick for an item this copy of the file no longer lists. It
                // still travels: the client's app is the one that knows what
                // its own menus hold, and it skips what it cannot find rather
                // than drawing a broken row.
                if !missing.isEmpty {
                    Text("\(missing.count) more \(missing.count == 1 ? "pick is" : "picks are") "
                         + "not on the menus this copy has. They still travel; an app skips what "
                         + "it cannot find.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                if !ids.isEmpty {
                    Button("Clear these picks", role: .destructive) { confirmingClear = true }
                        .tint(Theme.accent)
                }
            }
        }
    }

    // MARK: - One place

    /// A chain, or the gas station its snacks all come from.
    private struct Place: Identifiable {
        let id: String
        let name: String
        let detail: String?
        let items: [RoadFoodItem]
        let showsCategory: Bool
    }

    private func places(_ catalog: RoadFoodCatalog) -> [Place] {
        var list = catalog.chains.map {
            Place(id: $0.id, name: $0.name,
                  detail: RoadFoodDates.line(publishedOn: $0.publishedOn, checkedOn: $0.checkedOn),
                  items: $0.items, showsCategory: false)
        }
        if !catalog.snacks.isEmpty {
            list.append(Place(id: RoadFoodCatalog.gasStationID,
                              name: RoadFoodCatalog.gasStationName,
                              detail: nil, items: catalog.sortedSnacks, showsCategory: true))
        }
        return list
    }

    private func placeCard(_ place: Place) -> some View {
        let ids = picks
        let picked = RoadPicks.countIn(ids, items: place.items)
        return LiftCard {
            VStack(alignment: .leading, spacing: 10) {
                DisclosureGroup(isExpanded: expansion(of: place.id)) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 12) {
                            Button("Pick all") {
                                setPicks(RoadPicks.toggleAll(picks, items: place.items, on: true))
                            }
                            Button("Clear") {
                                setPicks(RoadPicks.toggleAll(picks, items: place.items, on: false))
                            }
                            .disabled(picked == 0)
                            Spacer(minLength: 0)
                        }
                        .font(.caption)
                        .tint(Theme.accent)
                        .padding(.top, 8)

                        ForEach(place.items) { item in
                            Divider().overlay(Theme.hairline).padding(.vertical, 8)
                            row(item, isPicked: ids.contains(item.id),
                                showsCategory: place.showsCategory)
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(place.name)
                            .font(Theme.cardTitle)
                            .foregroundStyle(Theme.accent)
                        Text(picked > 0
                             ? "\(picked) of \(place.items.count) picked"
                             : "\(place.items.count) items")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                        if let detail = place.detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                .tint(Theme.accent)
            }
            .fillsGridCell()
        }
    }

    /// One item: the tick, the name, and the figures plainly. No colour, no
    /// threshold, nothing ranked -- the ranking is the client's app's job,
    /// against a day this screen knows nothing about.
    private func row(_ item: RoadFoodItem, isPicked: Bool, showsCategory: Bool) -> some View {
        Button {
            setPicks(RoadPicks.toggle(picks, id: item.id, on: !isPicked))
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detailLine(item, showsCategory: showsCategory))
                        .font(Theme.detail)
                        .foregroundStyle(Theme.textSecondary)
                    if let modification = item.modification {
                        Text(modification)
                            .font(Theme.detail)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.name)
        .accessibilityValue(isPicked ? "Picked" : "Not picked")
    }

    /// "370 kcal · P 34 g · 1 sandwich". Blank stays blank: an item with no
    /// figure says so rather than showing a zero.
    private func detailLine(_ item: RoadFoodItem, showsCategory: Bool) -> String {
        var parts: [String] = []
        if showsCategory, let category = item.category { parts.append(category) }
        parts.append(item.kcal.map { "\(Int($0.rounded())) kcal" } ?? "kcal not listed")
        parts.append(item.proteinG.map { "P \(Int($0.rounded())) g" } ?? "protein not listed")
        if let serving = item.serving { parts.append(serving) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Storage

    private var picks: [String] {
        guard !clientID.isEmpty,
              let map = try? JSONDecoder().decode([String: [String]].self, from: picksData)
        else { return [] }
        return RoadPicks.normalise(map[clientID] ?? [])
    }

    /// Written through `@AppStorage`'s own bytes so the screen redraws, and
    /// through `RoadPicks` so the one rule about the stored shape -- no
    /// blanks, no duplicates, and no key at all for a client with none -- is
    /// not restated here.
    private func setPicks(_ ids: [String]) {
        guard !clientID.isEmpty else { return }
        var map = (try? JSONDecoder().decode([String: [String]].self, from: picksData)) ?? [:]
        let list = RoadPicks.normalise(ids)
        if list.isEmpty { map.removeValue(forKey: clientID) } else { map[clientID] = list }
        picksData = (try? JSONEncoder().encode(map)) ?? Data()
    }

    private func expansion(of id: String) -> Binding<Bool> {
        Binding(get: { open.contains(id) },
                set: { isOpen in
                    if isOpen { open.insert(id) } else { open.remove(id) }
                })
    }

    private var clientName: String {
        clients.first { $0.id == clientID }?.name ?? "this client"
    }
}
