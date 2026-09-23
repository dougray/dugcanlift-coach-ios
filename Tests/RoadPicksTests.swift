import CryptoKit
import XCTest
import SwiftData
import LiftCore
@testable import Coach

/// Road picks, at the end where they are made: the stored shape, the ticking,
/// the summary a coach reads, and what the wire does with them.
///
/// A port of Coach web's `coach/road-picks.test.mjs` (dugcanlift-coach), test
/// for test, so a coach ticking items in the browser and on the phone marks
/// the same thing and sends the same bytes.
final class RoadPicksTests: XCTestCase {

    private func defaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "road-picks-\(UUID().uuidString)"
        guard let store = UserDefaults(suiteName: suite) else { return XCTFail("no suite") }
        defer { store.removePersistentDomain(forName: suite) }
        try body(store)
    }

    private func catalog() throws -> RoadFoodCatalog {
        try XCTUnwrap(RoadFoodCatalog.bundled(in: Bundle(for: RoadPicksTests.self)),
                      "road-food.json missing from the test bundle")
    }

    // MARK: - How old the numbers are

    /// Coach shows no staleness warning - none of the three Coach builds does
    /// - but it does say when a chain's numbers are from, and a chart's own
    /// date and the day someone read it are different facts.
    func testAPlaceSaysWhatTheChainPublishedAndWhenItWasChecked() {
        XCTAssertEqual(RoadFoodDates.line(publishedOn: "2021-03-29", checkedOn: "2026-09-23",
                                          locale: enUS),
                       "Published Mar 29, 2021 · checked Sep 23, 2026")
        XCTAssertEqual(RoadFoodDates.line(publishedOn: "2022-11", checkedOn: "2026-09-23",
                                          locale: enUS),
                       "Published Nov 2022 · checked Sep 23, 2026")
        // Blank stays blank: a chain whose document states no date reads
        // exactly as it did before the field existed - no empty parenthetical.
        XCTAssertEqual(RoadFoodDates.line(publishedOn: nil, checkedOn: "2026-09-20", locale: enUS),
                       "Checked Sep 20, 2026")
        XCTAssertEqual(RoadFoodDates.line(publishedOn: "  ", checkedOn: "2026-09-20", locale: enUS),
                       "Checked Sep 20, 2026")
        XCTAssertEqual(RoadFoodDates.line(publishedOn: "2022-11", checkedOn: nil, locale: enUS),
                       "Published Nov 2022")
        XCTAssertNil(RoadFoodDates.line(publishedOn: nil, checkedOn: nil, locale: enUS))
    }

    /// The date a person reads, not the key the file stores. LIFT web, LIFT
    /// Android and LIFT iPhone all print "Sep 20, 2026" for the same chain;
    /// Coach printed "2026-09-20" because it had no formatter at all.
    func testADateIsWrittenTheWayAPersonWritesOne() {
        XCTAssertEqual(RoadFoodDates.dayText("2026-09-20", locale: enUS), "Sep 20, 2026")
        XCTAssertEqual(RoadFoodDates.documentText("2021-03-29", locale: enUS), "Mar 29, 2021")
    }

    /// A document that names only a month is printed only to the month. No day
    /// is invented for the reader: Burger King's chart says "NOVEMBER 2022"
    /// and never says the 1st, which is LIFT web's `roadDocDate` rule and LIFT
    /// Android's `publishedLabel` rule both.
    func testAMonthOnlyDocumentDateStaysAMonth() {
        XCTAssertEqual(RoadFoodDates.documentText("2022-11", locale: enUS), "Nov 2022")
        XCTAssertEqual(RoadFoodDates.documentText("2022-01", locale: enUS), "Jan 2022")
        // The day someone read a chart is a whole day, so a month-only value
        // is not one -- `checkedOn` is `YYYY-MM-DD` or it is not a check date.
        XCTAssertNil(RoadFoodDates.dayText("2022-11", locale: enUS))
    }

    /// A missing date, and anything that is not one. Both read as absent: the
    /// clause is left out rather than showing a blank or echoing the text, the
    /// same answer LIFT iPhone and LIFT Android give. The kit's
    /// `validate-road-food.mjs` is what keeps junk out of the file; this is
    /// what happens if it ever gets in.
    func testAMissingOrUnreadableDateSaysNothingAtAll() {
        XCTAssertNil(RoadFoodDates.dayText(nil, locale: enUS))
        XCTAssertNil(RoadFoodDates.documentText(nil, locale: enUS))
        XCTAssertNil(RoadFoodDates.dayText("", locale: enUS))
        XCTAssertNil(RoadFoodDates.documentText("   ", locale: enUS))
        for junk in ["2026", "2026-13-01", "2026-09-32", "20 Sept", "2026-9-8", "2026-09-20T00:00:00Z"] {
            XCTAssertNil(RoadFoodDates.dayText(junk, locale: enUS), junk)
            XCTAssertNil(RoadFoodDates.documentText(junk, locale: enUS), junk)
        }
        XCTAssertNil(RoadFoodDates.line(publishedOn: "20 Sept", checkedOn: nil, locale: enUS))
    }

    /// A day key is a calendar day, not an instant. It is built at noon UTC
    /// and printed with the style's time zone pinned to UTC, so the edges of
    /// a year stay on the day the file wrote wherever the phone is: at
    /// midnight, every reader west of UTC would read the day before.
    func testADayKeyStaysOnItsOwnDayAtTheEdgesOfAYear() {
        XCTAssertEqual(RoadFoodDates.dayText("2026-01-01", locale: enUS), "Jan 1, 2026")
        XCTAssertEqual(RoadFoodDates.dayText("2026-12-31", locale: enUS), "Dec 31, 2026")
        XCTAssertEqual(RoadFoodDates.documentText("2026-01", locale: enUS), "Jan 2026")
        XCTAssertEqual(RoadFoodDates.documentText("2026-12", locale: enUS), "Dec 2026")
    }

    /// Nothing pins en-US. LIFT web passes `undefined` to
    /// `toLocaleDateString`, LIFT Android uses `Locale.getDefault()` and LIFT
    /// iPhone `Locale.current`, so a coach in Berlin reads a Berlin date in
    /// all four apps. The tests pin a locale only so they can assert a string.
    func testTheDateIsWrittenInTheReadersOwnLocale() {
        XCTAssertNotEqual(RoadFoodDates.dayText("2026-09-20", locale: Locale(identifier: "de_DE")),
                          RoadFoodDates.dayText("2026-09-20", locale: enUS))
    }

    private let enUS = Locale(identifier: "en_US")

    func testTheBundledFileCarriesEachChainsOwnDocumentDateWhereItsDocumentStatesOne() throws {
        let catalog = try catalog()
        let by = { (id: String) in catalog.chains.first { $0.id == id } }
        XCTAssertEqual(by("burgerking")?.publishedOn, "2022-11")
        XCTAssertEqual(by("whataburger")?.publishedOn, "2021-03-29")
        XCTAssertEqual(by("chipotle")?.publishedOn, "2024-10")
        // A chain whose document states no date has no key at all.
        XCTAssertNil(by("sonic")?.publishedOn)
        XCTAssertNil(by("quiktrip")?.publishedOn)
        // The file is the same bytes LIFT reads, and LIFT warns from this
        // field, so a copy that lost it would be a copy that had drifted.
        for chain in catalog.chains {
            XCTAssertNotNil(chain.checkedOn, "\(chain.id) has no checkedOn")
            if let published = chain.publishedOn {
                XCTAssertNotNil(published.range(of: #"^\d{4}-\d{2}(-\d{2})?$"#, options: .regularExpression),
                                "\(chain.id) has an unusable publishedOn")
                XCTAssertLessThanOrEqual(published.count == 7 ? published + "-01" : published, chain.checkedOn!,
                                         "\(chain.id) claims a document published after it was read")
            }
        }
    }

    // MARK: - The stored list

    func testPicksAreTrimmedStringsUniqueInTheOrderTheyWereTicked() {
        XCTAssertEqual(RoadPicks.normalise([" b ", "a", "b", "", "a", "  ", "c"]), ["b", "a", "c"])
        XCTAssertEqual(RoadPicks.normalise([]), [])
    }

    func testToggleAddsAtTheEndAndRemovesByID() {
        XCTAssertEqual(RoadPicks.toggle(["a", "b"], id: "c", on: true), ["a", "b", "c"])
        XCTAssertEqual(RoadPicks.toggle(["a", "b"], id: "a", on: false), ["b"])
        XCTAssertEqual(RoadPicks.toggle(["a", "b"], id: "a", on: true), ["b", "a"],
                       "ticking one already on is a no-op re-add")
        XCTAssertEqual(RoadPicks.toggle([], id: "a", on: false), [])
    }

    func testToggleAllPicksOrClearsOnePlaceWithoutTouchingAnother() {
        let items = [RoadFoodItem(id: "x1", name: "One"), RoadFoodItem(id: "x2", name: "Two")]
        XCTAssertEqual(RoadPicks.toggleAll(["a"], items: items, on: true), ["a", "x1", "x2"])
        XCTAssertEqual(RoadPicks.toggleAll(["a", "x1", "x2"], items: items, on: false), ["a"])
        XCTAssertEqual(RoadPicks.toggleAll(["a", "x1"], items: items, on: true), ["a", "x1", "x2"],
                       "no duplicates")
    }

    func testPicksAreStoredPerClientAndAClientWithNoneHasNoKeyAtAll() {
        defaults { store in
            RoadPicks.set(["a", "b"], for: "jordan", in: store)
            RoadPicks.set(["c"], for: "sam", in: store)
            XCTAssertEqual(RoadPicks.picks(for: "jordan", in: store), ["a", "b"])
            XCTAssertEqual(RoadPicks.picks(for: "sam", in: store), ["c"])

            RoadPicks.set([], for: "jordan", in: store)
            XCTAssertEqual(RoadPicks.load(from: store).keys.sorted(), ["sam"],
                           "no picks is no key, not an empty list")
            XCTAssertEqual(RoadPicks.picks(for: "nobody", in: store), [])
        }
    }

    func testRemovingAClientTakesTheirPicksAndLeavesEveryoneElsesAlone() {
        defaults { store in
            RoadPicks.set(["a"], for: "jordan", in: store)
            RoadPicks.set(["b"], for: "sam", in: store)
            RoadPicks.remove(clientID: "jordan", in: store)
            XCTAssertEqual(RoadPicks.load(from: store), ["sam": ["b"]])
            // A client who was never picked for must not cost a write.
            RoadPicks.remove(clientID: "nobody", in: store)
            XCTAssertEqual(RoadPicks.load(from: store), ["sam": ["b"]])
        }
    }

    // MARK: - The wire

    func testNoPicksIsNoKeyAtAllNeverAnEmptyList() {
        XCTAssertNil(RoadPicks.wire([]))
        XCTAssertNil(RoadPicks.wire(["", "  "]))
        XCTAssertEqual(RoadPicks.wire(["wendys-large-chili", "chickfila-grilled-filet"]),
                       ["wendys-large-chili", "chickfila-grilled-filet"])
    }

    func testNothingIsFilteredAgainstThisAppsOwnCopyOfTheFileOnTheWayOut() throws {
        // The coach's bundle and the client's are two builds updated at
        // different times, so only the receiver can say what it has. An id
        // this copy does not know still travels; LIFT skips it silently.
        let ids = ["wendys-large-chili", "gone-from-the-menu-2019"]
        XCTAssertEqual(RoadPicks.wire(ids), ids)
        XCTAssertEqual(RoadPicks.missing(ids, in: try catalog()), ["gone-from-the-menu-2019"])
    }

    // MARK: - Against the bundled file

    func testEveryIDInTheBundledFileIsUniqueBecauseTheIDsAreTheWholeContract() throws {
        let catalog = try catalog()
        let all = catalog.chains.flatMap(\.items).map(\.id) + catalog.snacks.map(\.id)
        XCTAssertEqual(Set(all).count, all.count)
        XCTAssertGreaterThan(all.count, 50, "chains and snacks both counted")
    }

    func testTheCatalogueCoversChainItemsAndGasStationSnacksAlike() throws {
        let catalog = try catalog()
        XCTAssertEqual(catalog.placeByItemID["wendys-large-chili"], "wendys")
        XCTAssertEqual(catalog.itemsByID["wendys-large-chili"]?.name, "Large Chili")
        XCTAssertEqual(catalog.placeByItemID["snack-jack-links-original-beef-jerky"],
                       RoadFoodCatalog.gasStationID)
        XCTAssertEqual(RoadFoodCatalog.gasStationName, "Gas station")
    }

    func testCountsAndTheSummaryLineCountOnlyWhatThisCopyHas() throws {
        let catalog = try catalog()
        let wendys = try XCTUnwrap(catalog.chains.first { $0.id == "wendys" })
        let ids = ["wendys-large-chili", "wendys-grilled-chicken-ranch-wrap",
                   "gone-from-the-menu-2019"]
        XCTAssertEqual(RoadPicks.countIn(ids, items: wendys.items), 2)
        XCTAssertEqual(RoadPicks.summary(ids, in: catalog), "2 items at 1 place")
        XCTAssertEqual(RoadPicks.summary(["wendys-large-chili",
                                          "snack-jack-links-original-beef-jerky"], in: catalog),
                       "2 items at 2 places")
        XCTAssertEqual(RoadPicks.summary(["wendys-large-chili"], in: catalog), "1 item at 1 place")
        XCTAssertEqual(RoadPicks.summary([], in: catalog), "")
        XCTAssertEqual(RoadPicks.summary(["gone-from-the-menu-2019"], in: catalog), "",
                       "an id nothing here knows is not counted on screen, though it still travels")
    }

    func testTheBundledFileIsTheKitsOwnCopy() throws {
        // The shape the ids depend on: chains with items, snacks, and no empty
        // ids. This used to say a checksum of the bytes was not the test
        // bundle's business, and left the copy on the honour system --
        // testTheBundledFileIsTheKitsBytes below is that checksum. This one
        // stays because the two answer different questions: whether the file
        // is usable, and whether it is the file the kit curated.
        let catalog = try catalog()
        XCTAssertFalse(catalog.chains.isEmpty)
        XCTAssertFalse(catalog.snacks.isEmpty)
        XCTAssertTrue(catalog.chains.allSatisfy { !$0.id.isEmpty && !$0.items.isEmpty })
        XCTAssertTrue(catalog.snacks.allSatisfy { !$0.id.isEmpty })
    }

    /// road-food.json is curated once in `dugcanlift-kit/data/` and copied byte
    /// for byte into five app repos. Nothing used to check that they matched:
    /// CLAUDE.md says so in prose, and every other check here is on what the
    /// data *means* -- ids resolve, the dated charts carry their dates, the
    /// summary counts what this copy has -- all of which a copy several chains
    /// behind passes cleanly.
    ///
    /// It matters most here. Item ids are the contract road picks travel on,
    /// and `testNothingIsFilteredAgainstThisAppsOwnCopyOfTheFileOnTheWayOut`
    /// records the deliberate rule that an id the receiver does not know is
    /// skipped in silence. A coach on a stale copy is a coach whose picks
    /// vanish on the client's phone with nothing said.
    ///
    /// **It hashes what the bundle holds, not what sits in the repo**, so a
    /// build that dropped the resource from the target fails here too.
    func testTheBundledFileIsTheKitsBytes() throws {
        let bundle = Bundle(for: RoadPicksTests.self)
        let json = try XCTUnwrap(bundle.url(forResource: "road-food", withExtension: "json"),
                                 "road-food.json is not in the test bundle")
        let sumURL = try XCTUnwrap(bundle.url(forResource: "road-food", withExtension: "sha256"),
                                   "road-food.sha256 is not in the test bundle -- copy it from the kit beside the JSON")
        let pinned = try String(contentsOf: sumURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertNotNil(pinned.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression),
                        "road-food.sha256 should be one bare sha256 and nothing else")
        let actual = SHA256.hash(data: try Data(contentsOf: json))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(actual, pinned, """
            The bundled road-food.json does not match road-food.sha256.
            Copy dugcanlift-kit/data/road-food.json AND data/road-food.sha256 over together.
            Never edit either file here, and never re-write the checksum by hand to make this
            pass: the kit writes it with `node data/validate-road-food.mjs --write-checksum`,
            and the other four app repos pin the same one, so a hand-written hash only moves
            the failure somewhere further away.
            """)
    }

    func testAMalformedRowCostsThatRowAndNotTheList() throws {
        let json = """
        {"chains":[{"id":"ok","name":"OK","items":[
            {"id":"a","name":"A","kcal":100,"proteinG":10},
            {"name":"no id"},
            {"id":"b","name":"B","kcal":-5,"proteinG":null}]},
          {"name":"chain with no id"}],
         "snacks":[{"id":"s","name":"S","category":"jerky"},"junk"]}
        """
        let catalog = try RoadFoodCatalog.decode(Data(json.utf8))
        XCTAssertEqual(catalog.chains.map(\.id), ["ok"])
        XCTAssertEqual(catalog.chains[0].items.map(\.id), ["a", "b"])
        XCTAssertNil(catalog.chains[0].items[1].kcal, "a negative figure is not listed, not a zero")
        XCTAssertNil(catalog.chains[0].items[1].proteinG)
        XCTAssertEqual(catalog.snacks.map(\.id), ["s"])
    }

    // MARK: - Removing a client

    func testRemovingAClientTakesTheirPicksThroughClientRemoval() throws {
        let schema = Schema(CoachSchema.models)
        let context = ModelContext(try ModelContainer(
            for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        let jordan = Client(id: "jordan", name: "Jordan Reyes", displayUnit: "lb", platform: "ios")
        let sam = Client(id: "sam", name: "Sam Ortiz", displayUnit: "kg", platform: "android")
        context.insert(jordan)
        context.insert(sam)
        try context.save()

        try defaults { store in
            RoadPicks.set(["wendys-large-chili"], for: "jordan", in: store)
            RoadPicks.set(["chickfila-grilled-filet"], for: "sam", in: store)

            let impact = try XCTUnwrap(ClientRemoval.impact(clientID: "jordan", in: context,
                                                            defaults: store))
            // Android's sentence, word for word, and road picks are not in it:
            // it was written before they existed, and it changes in both
            // places at once or in neither.
            XCTAssertFalse(ClientRemoval.confirmationText(impact).contains("pick"))
            XCTAssertFalse(ClientRemoval.confirmationText(impact).contains("road"))

            let outcome = ClientRemoval.remove(clientID: "jordan", in: context, defaults: store)
            XCTAssertTrue(outcome.removed)
            XCTAssertEqual(RoadPicks.load(from: store), ["sam": ["chickfila-grilled-filet"]])
        }
    }

    // MARK: - The backup

    private func storeContext() throws -> ModelContext {
        let schema = Schema(CoachSchema.models)
        return ModelContext(try ModelContainer(
            for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    func testPicksTravelInTheBackupAndComeBackPerClient() throws {
        let source = try storeContext()
        source.insert(Client(id: "jordan", name: "Jordan Reyes", displayUnit: "lb", platform: "ios"))
        try source.save()

        try defaults { out in
            RoadPicks.set(["wendys-large-chili", "snack-jack-links-original-beef-jerky"],
                          for: "jordan", in: out)
            let data = try BackupCodec.export(from: source, defaults: out)

            // Coach Android's and Coach web's own spelling: an object keyed by
            // client id, each value a list of ids in the order they were
            // ticked, so one file moves between all three.
            let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(json["roadPicks"] as? [String: [String]],
                           ["jordan": ["wendys-large-chili",
                                       "snack-jack-links-original-beef-jerky"]])

            try defaults { fresh in
                try BackupCodec.restore(from: data, into: try storeContext(), defaults: fresh)
                XCTAssertEqual(RoadPicks.picks(for: "jordan", in: fresh),
                               ["wendys-large-chili", "snack-jack-links-original-beef-jerky"])
            }
        }
    }

    func testAClientThisDeviceAlreadyHasPicksForKeepsThem() throws {
        let source = try storeContext()
        source.insert(Client(id: "jordan", name: "Jordan Reyes", displayUnit: "lb", platform: "ios"))
        try source.save()
        var file = Data()
        try defaults { out in
            RoadPicks.set(["old-pick"], for: "jordan", in: out)
            RoadPicks.set(["sams-pick"], for: "sam", in: out)
            file = try BackupCodec.export(from: source, defaults: out)
        }

        try defaults { device in
            RoadPicks.set(["newer-pick"], for: "jordan", in: device)
            try BackupCodec.restore(from: file, into: try storeContext(), defaults: device)
            // Restoring is per client, not per id: an older backup must never
            // delete newer work, and a client this device has none for takes
            // the file's list.
            XCTAssertEqual(RoadPicks.picks(for: "jordan", in: device), ["newer-pick"])
            XCTAssertEqual(RoadPicks.picks(for: "sam", in: device), ["sams-pick"])
        }
    }

    func testAFileWrittenBeforeRoadPicksChangesNothing() throws {
        let source = try storeContext()
        source.insert(Client(id: "jordan", name: "Jordan Reyes", displayUnit: "lb", platform: "ios"))
        try source.save()

        try defaults { out in
            let data = try BackupCodec.export(from: source, defaults: out)
            let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertNil(json["roadPicks"],
                         "a coach who has marked none writes no key, as an older Coach does")

            try defaults { device in
                RoadPicks.set(["kept"], for: "jordan", in: device)
                try BackupCodec.restore(from: data, into: try storeContext(), defaults: device)
                XCTAssertEqual(RoadPicks.picks(for: "jordan", in: device), ["kept"])
            }
        }
    }
}
