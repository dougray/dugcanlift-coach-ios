import Foundation

/// Road Food's bundled file, as Coach reads it: the chains and gas-station
/// snacks a client's own app ranks against what is left of their day, and
/// whose **item ids** are what a coach's picks travel as
/// (`PLAN-FORMAT.md` "Road picks").
///
/// **Where it lives.** `Resources/road-food.json` in the Coach app target, a
/// verbatim copy of `dugcanlift-kit/data/road-food.json` -- the same bytes
/// LIFT iOS bundles, and the same file Coach web and LIFT web serve. Not in
/// `LiftReference`: the kit is pinned to an exact tag that two shipped apps
/// consume, so a data refresh there is a kit release plus a version bump in
/// both, while this file is one copy into one folder. Edit it in the kit and
/// copy it here; never here alone. Item ids are the whole contract, so the two
/// copies must not drift.
///
/// **Coach reads it only to draw the ticks.** Nothing is filtered against it
/// on the way out: a picked id this copy does not have still travels, because
/// the client's build is the only one that can say what it holds, and it skips
/// an id it does not know. See `RoadPicks`.
///
/// **Lenient on purpose.** The file is hand-curated: a malformed chain or item
/// is dropped rather than failing the whole list, and a number that is not a
/// finite, non-negative number is read as not listed. Blank stays blank -- an
/// absent figure is nil and is said in words, never drawn as a zero.
struct RoadFoodCatalog: Decodable, Equatable {
    let chains: [RoadFoodChain]
    let snacks: [RoadFoodItem]

    enum CodingKeys: String, CodingKey { case chains, snacks }

    init(chains: [RoadFoodChain], snacks: [RoadFoodItem]) {
        self.chains = chains
        self.snacks = snacks
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A file with no chains array is not a Road Food file.
        chains = try c.decode([RoadFoodLenient<RoadFoodChain>].self, forKey: .chains)
            .compactMap(\.value)
        snacks = (try? c.decodeIfPresent([RoadFoodLenient<RoadFoodItem>].self, forKey: .snacks))?
            .compactMap(\.value) ?? []
    }

    /// The gas station, as a place beside the chains: a snack belongs to no
    /// chain, and "Gas station" is the name web and Android both give it.
    static let gasStationID = "snacks"
    static let gasStationName = "Gas station"

    /// Every item in the file, chain items and snacks alike, keyed by id --
    /// the lookup a picks summary runs.
    var itemsByID: [String: RoadFoodItem] {
        var map: [String: RoadFoodItem] = [:]
        for item in chains.flatMap(\.items) + snacks where map[item.id] == nil {
            map[item.id] = item
        }
        return map
    }

    /// The place an item belongs to, by item id: a chain's id, or the gas
    /// station's. What `RoadPicks.summary` counts places with.
    var placeByItemID: [String: String] {
        var map: [String: String] = [:]
        for chain in chains {
            for item in chain.items where map[item.id] == nil { map[item.id] = chain.id }
        }
        for snack in snacks where map[snack.id] == nil { map[snack.id] = Self.gasStationID }
        return map
    }

    /// The snacks sorted the way the gas-station card lists them: by category,
    /// then by name, as Coach web sorts them.
    var sortedSnacks: [RoadFoodItem] {
        snacks.sorted {
            let a = ($0.category ?? "", $0.name)
            let b = ($1.category ?? "", $1.name)
            return a < b
        }
    }

    static func decode(_ data: Data) throws -> RoadFoodCatalog {
        try JSONDecoder().decode(RoadFoodCatalog.self, from: data)
    }

    /// The shipped file, or nil when it is not in the bundle -- in which case
    /// the Road section says so rather than showing an empty list.
    static func bundled(in bundle: Bundle = .main) -> RoadFoodCatalog? {
        guard let url = bundle.url(forResource: "road-food", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? decode(data),
              !catalog.chains.isEmpty || !catalog.snacks.isEmpty else { return nil }
        return catalog
    }

    /// Read once: the file is part of the app and cannot change while it runs.
    static let shared: RoadFoodCatalog? = bundled()
}

struct RoadFoodChain: Decodable, Equatable, Identifiable, Hashable {
    let id: String
    let name: String
    /// The date the chain's own document states about itself, as precise as
    /// the document is: "YYYY-MM-DD", or "YYYY-MM" where a chart names only a
    /// month. Nil where the document states no date at all. Shown beside
    /// `checkedOn` because they are different facts: this is when the chain
    /// wrote the chart, and a 2021 chart read this morning is still a 2021
    /// chart. LIFT warns from it; Coach only says it.
    let publishedOn: String?
    /// "YYYY-MM-DD", when the numbers were checked against the chain's page.
    /// Shown so a coach ticking items can see how old they are.
    let checkedOn: String?
    let items: [RoadFoodItem]

    enum CodingKeys: String, CodingKey { case id, name, publishedOn, checkedOn, items }

    init(id: String, name: String, publishedOn: String? = nil, checkedOn: String? = nil,
         items: [RoadFoodItem]) {
        self.id = id
        self.name = name
        self.publishedOn = publishedOn
        self.checkedOn = checkedOn
        self.items = items
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        guard !id.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "empty id")
        }
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? id
        publishedOn = try? c.decodeIfPresent(String.self, forKey: .publishedOn)
        checkedOn = try? c.decodeIfPresent(String.self, forKey: .checkedOn)
        items = try c.decode([RoadFoodLenient<RoadFoodItem>].self, forKey: .items).compactMap(\.value)
    }
}

/// One menu item or gas-station product. Only the fields a coach reads while
/// ticking: the numbers are the client's app's business, and the ranking
/// certainly is -- a pick says nothing about calories.
struct RoadFoodItem: Decodable, Equatable, Identifiable, Hashable {
    let id: String
    let name: String
    let serving: String?
    let kcal: Double?
    let proteinG: Double?
    let modification: String?
    /// Snacks only: "jerky", "protein-bar"...
    let category: String?

    enum CodingKeys: String, CodingKey {
        case id, name, serving, kcal, proteinG, modification, category
    }

    init(id: String, name: String, serving: String? = nil, kcal: Double? = nil,
         proteinG: Double? = nil, modification: String? = nil, category: String? = nil) {
        self.id = id
        self.name = name
        self.serving = serving
        self.kcal = kcal
        self.proteinG = proteinG
        self.modification = modification
        self.category = category
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        guard !id.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "empty id")
        }
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? id
        serving = try? c.decodeIfPresent(String.self, forKey: .serving)
        kcal = RoadFoodItem.number(try? c.decodeIfPresent(Double.self, forKey: .kcal))
        proteinG = RoadFoodItem.number(try? c.decodeIfPresent(Double.self, forKey: .proteinG))
        modification = try? c.decodeIfPresent(String.self, forKey: .modification)
        category = try? c.decodeIfPresent(String.self, forKey: .category)
    }

    /// A finite, non-negative figure, or nil. A negative or a NaN is a file
    /// that is wrong about this number, which is "not listed", not a zero.
    private static func number(_ value: Double??) -> Double? {
        guard let value = value ?? nil, value.isFinite, value >= 0 else { return nil }
        return value
    }
}

/// Decodes `T` or keeps nil, so one bad row in a hand-curated file costs that
/// row and not the list.
private struct RoadFoodLenient<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

/// What a place card says about how old its numbers are. A value type with no
/// view in it, for the reason `MacroFields` and `LinkImportMacros` are: a rule
/// in a view's `@State` cannot be tested, and this one decides what a coach is
/// told about the chart they are ticking from.
///
/// Two different facts, so both are said. `publishedOn` is the date the chain's
/// own document states about itself -- Burger King's chart says "NOVEMBER 2022"
/// -- and `checkedOn` is the day a person read it. A chain whose document states
/// no date has no `publishedOn`, and then the line is exactly what it has always
/// been.
///
/// Coach does not warn. LIFT does, from the same field, and the three Coach
/// builds say nothing about staleness at all: this line gains a clause in all
/// of them or in none.
///
/// **Both dates are written the way a person writes one** -- "Sep 20, 2026",
/// and "Nov 2022" for a document that names only a month. A coach reading the
/// same chain in LIFT reads the same date there, and an ISO key is a wire
/// shape rather than a sentence.
enum RoadFoodDates {
    static func line(publishedOn: String?, checkedOn: String?,
                     locale: Locale = .current) -> String? {
        let published = documentText(publishedOn, locale: locale)
        let checked = dayText(checkedOn, locale: locale)
        switch (published, checked) {
        case let (published?, checked?): return "Published \(published) · checked \(checked)"
        case let (published?, nil): return "Published \(published)"
        case let (nil, checked?): return "Checked \(checked)"
        case (nil, nil): return nil
        }
    }

    /// "Sep 20, 2026" for a `YYYY-MM-DD`, or nil when the text is not one.
    /// The day someone read a chart is always a whole day, so this is the
    /// strict shape -- a port of `lift-ios`'s `RoadFoodRanking.dateText`.
    static func dayText(_ key: String?, locale: Locale = .current) -> String? {
        guard let parts = parse(key), parts.day != nil else { return nil }
        return text(parts, locale: locale)
    }

    /// A document's own date, printed no more precisely than the document
    /// wrote it: "Mar 29, 2021" for a chart that gives a day, "Nov 2022" for
    /// one that names only a month. Never more precise, so no day is invented
    /// for the reader -- LIFT web's `roadDocDate` and LIFT Android's
    /// `publishedLabel`, which both make exactly that distinction.
    static func documentText(_ key: String?, locale: Locale = .current) -> String? {
        guard let parts = parse(key) else { return nil }
        return text(parts, locale: locale)
    }

    // MARK: - Reading the wire's shape

    /// `YYYY-MM-DD` or `YYYY-MM`, and nothing else. Anything the kit's
    /// `validate-road-food.mjs` would reject reads as no date at all rather
    /// than reaching a card verbatim, which is what LIFT iOS and LIFT Android
    /// both do; only LIFT web prints "Invalid Date", and that is the web's
    /// own bug, not a shape to copy.
    private static func parse(_ key: String?) -> (year: Int, month: Int, day: Int?)? {
        guard let text = key?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              let year = digits(parts[0], count: 4),
              let month = digits(parts[1], count: 2), (1...12).contains(month)
        else { return nil }
        guard parts.count == 3 else { return (year, month, nil) }
        guard let day = digits(parts[2], count: 2), (1...31).contains(day) else { return nil }
        return (year, month, day)
    }

    private static func digits(_ text: Substring, count: Int) -> Int? {
        guard text.count == count, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(text)
    }

    /// Formatted in the reader's own locale, because that is what all three
    /// LIFT builds do -- the browser's `toLocaleDateString(undefined, ...)`,
    /// Android's `Locale.getDefault()`, iOS's `Locale.current`. None of them
    /// pins en-US, so neither does this.
    ///
    /// Noon UTC, and the style's time zone pinned to match: a day key is a
    /// calendar day and not an instant, and midnight in one zone is the day
    /// before in another.
    private static func text(_ parts: (year: Int, month: Int, day: Int?),
                             locale: Locale) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: DateComponents(
            year: parts.year, month: parts.month, day: parts.day ?? 1, hour: 12))
        else { return nil }
        var style = parts.day == nil
            ? Date.FormatStyle(date: .omitted, time: .omitted).year().month(.abbreviated)
            : Date.FormatStyle(date: .abbreviated, time: .omitted)
        style = style.locale(locale)
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }
}
