import Foundation

/// Road picks -- the Road Food items a coach is happy with for one client.
///
/// LIFT has Road Food: a curated file of chains, items and gas-station snacks,
/// ranked against what is left of the client's day. A coach marking picks is
/// saying "these fit how I want you eating on the road" and nothing else -- no
/// calorie or macro claim, because LIFT already ranks on those and re-ranking
/// them from here would put a coach's tick in front of the client's own
/// numbers. At the client's end they sort to the top of that place's list,
/// named as the coach's, and nothing underneath them moves.
///
/// **On the wire: `rf`**, a flat list of item ids, omitted entirely when there
/// are none (PLAN-FORMAT.md "Road picks"). Item ids are the contract -- the
/// Road Food spec keeps them stable for exactly this -- and they are all that
/// travels. A whole chain is not a thing on the wire: "Pick all" ticks the
/// items the coach can see at the time they tick them, so a chain that gains
/// an item next quarter does not silently gain a pick nobody looked at.
///
/// **Nothing is filtered against this app's own copy of the data on the way
/// out.** The coach's bundle and the client's are two builds of two apps,
/// updated at different times, so only the receiver can say what it has. It
/// skips an id it does not know, silently, and draws no broken row. That is
/// why a withdrawn item is safe to leave in a coach's stored picks, and why
/// `missing` exists only so a coach is never puzzled by a count that does not
/// match what is on screen.
///
/// **Where it is kept: `UserDefaults`, keyed by client id**, the way
/// `cookPlanOwners` and `EachSideChoices` are, and the shape Coach web's
/// `coach.roadPicks` and the backup's `roadPicks` object both have. Not a
/// `@Model`: it is one short list of strings per client, replaced whole, with
/// nothing to query and nothing to relate -- and the order the coach ticked
/// them in, which is the only order they authored, comes free. `ClientRemoval`
/// sweeps a removed client's key the way it sweeps their meal ownership, after
/// the store has committed.
///
/// A value type with no view in it, for the reason `MacroFields` and
/// `ClientRemoval` are: a rule in a view's `@State` cannot be tested, and
/// these decide what a client's app is told.
enum RoadPicks {
    static let key = "roadPicks"

    // MARK: - Storage

    /// Every client's picks. A junk or absent value is no picks at all -- a
    /// picks list is not worth losing a launch over.
    static func load(from defaults: UserDefaults = .standard) -> [String: [String]] {
        guard let data = defaults.data(forKey: key),
              let map = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return [:] }
        return map.compactMapValues { list in
            let cleaned = normalise(list)
            return cleaned.isEmpty ? nil : cleaned
        }
    }

    static func save(_ map: [String: [String]], to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        defaults.set(data, forKey: key)
    }

    static func picks(for clientID: String, in defaults: UserDefaults = .standard) -> [String] {
        normalise(load(from: defaults)[clientID] ?? [])
    }

    /// Stores one client's picks, **dropping the key entirely when there are
    /// none**: an empty list is how "no picks" is written here and on the
    /// wire, so a client with none looks the same as a client who never had
    /// any, in storage and in a backup.
    static func set(_ ids: [String], for clientID: String,
                    in defaults: UserDefaults = .standard) {
        var map = load(from: defaults)
        let list = normalise(ids)
        if list.isEmpty { map.removeValue(forKey: clientID) } else { map[clientID] = list }
        save(map, to: defaults)
    }

    /// Drops one client's picks, writing nothing when they had none -- a
    /// client who was never picked for must not cost a write, the same rule
    /// `ClientRemoval.sweepOwners` follows.
    static func remove(clientID: String, in defaults: UserDefaults = .standard) {
        var map = load(from: defaults)
        guard map.removeValue(forKey: clientID) != nil else { return }
        save(map, to: defaults)
    }

    // MARK: - The stored shape

    /// Trimmed strings, no blanks, no duplicates, in the order the coach
    /// ticked them. Anything else is dropped rather than failing.
    static func normalise(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.compactMap { raw in
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { return nil }
            return id
        }
    }

    /// The `rf` value for a payload, or nil when there is nothing to send.
    /// Nil means the key is left out; an empty array is never written.
    static func wire(_ ids: [String]) -> [String]? {
        let list = normalise(ids)
        return list.isEmpty ? nil : list
    }

    // MARK: - Ticking

    /// `ids` with `id` added at the end or taken out. The order picks were
    /// ticked in is kept: it is the only order a coach has authored.
    static func toggle(_ ids: [String], id: String, on: Bool) -> [String] {
        let without = normalise(ids).filter { $0 != id }
        return on ? without + [id] : without
    }

    /// `ids` with every id in `items` added, or every one of them removed.
    static func toggleAll(_ ids: [String], items: [RoadFoodItem], on: Bool) -> [String] {
        let these = items.map(\.id)
        let list = normalise(ids)
        guard on else {
            let drop = Set(these)
            return list.filter { !drop.contains($0) }
        }
        return normalise(list + these)
    }

    /// How many of `items` are picked.
    static func countIn(_ ids: [String], items: [RoadFoodItem]) -> Int {
        let picked = Set(normalise(ids))
        return items.filter { picked.contains($0.id) }.count
    }

    // MARK: - What the coach reads

    /// Picked ids this copy of the data has no item for. They still travel:
    /// the client's app decides what it knows.
    static func missing(_ ids: [String], in catalog: RoadFoodCatalog) -> [String] {
        let have = catalog.itemsByID
        return normalise(ids).filter { have[$0] == nil }
    }

    /// What is picked, in words: "6 items at 3 places", "1 item at 1 place",
    /// "" when there are none. Counts only what this copy of the data has, so
    /// the sentence matches the ticks on screen; the wire still carries the
    /// rest. Coach web's `summary`, word for word.
    static func summary(_ ids: [String], in catalog: RoadFoodCatalog) -> String {
        let places = catalog.placeByItemID
        var seen = Set<String>()
        var n = 0
        for id in normalise(ids) {
            guard let place = places[id] else { continue }
            n += 1
            seen.insert(place)
        }
        guard n > 0 else { return "" }
        return "\(n) \(n == 1 ? "item" : "items") at "
            + "\(seen.count) \(seen.count == 1 ? "place" : "places")"
    }
}
