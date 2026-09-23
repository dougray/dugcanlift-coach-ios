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
        // Not a checksum of the bytes -- the copy is verbatim but the test
        // bundle is not the place to assert that -- but the shape the ids
        // depend on: chains with items, snacks, and no empty ids.
        let catalog = try catalog()
        XCTAssertFalse(catalog.chains.isEmpty)
        XCTAssertFalse(catalog.snacks.isEmpty)
        XCTAssertTrue(catalog.chains.allSatisfy { !$0.id.isEmpty && !$0.items.isEmpty })
        XCTAssertTrue(catalog.snacks.allSatisfy { !$0.id.isEmpty })
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
}
