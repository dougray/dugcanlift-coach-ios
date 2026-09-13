import XCTest
@testable import Coach

/// Pins fix-round-1 Finding 3: deleting a recipe already sweeps its orphaned
/// `PlannedMeal`s (see `CookView.delete(_:)`), but left their entries in the
/// `cookPlanOwners` `@AppStorage` blob forever -- a harmless leak, but a
/// violation of the UUID-string -> clientID contract `CookPlanView` and
/// `ShoppingView` both read.
final class CookViewOwnershipTests: XCTestCase {

    func testSweepingOwnersRemovesOnlyTheDeletedMealsEntries() throws {
        let keep = UUID()
        let drop = UUID()
        let before = try JSONEncoder().encode([
            keep.uuidString: "client-keep",
            drop.uuidString: "client-drop",
        ])

        let after = CookView.sweepOwners(before, removing: [drop])
        let mapping = try JSONDecoder().decode([String: String].self, from: after)

        XCTAssertEqual(mapping[keep.uuidString], "client-keep",
            "an unrelated meal's ownership entry must survive the sweep")
        XCTAssertNil(mapping[drop.uuidString],
            "the deleted meal's ownership entry must not linger forever")
    }

    func testSweepingAnEmptyBlobStaysEmpty() throws {
        let after = CookView.sweepOwners(Data(), removing: [UUID()])
        let mapping = try JSONDecoder().decode([String: String].self, from: after)
        XCTAssertTrue(mapping.isEmpty)
    }
}
