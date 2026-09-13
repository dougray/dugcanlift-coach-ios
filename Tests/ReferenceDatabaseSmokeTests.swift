import XCTest
import LiftReference
@testable import Coach

/// The only test in Coach that touches the REAL bundled `food.db` via
/// `ReferenceDatabase.shared`, rather than a fixture or an in-memory stand-in.
/// Every other reference-database test in this codebase (`RecipeEditingTests`,
/// for instance) builds a `FoodRecord` by decoding JSON, because
/// `LiftReference.FoodRecord` has no public initializer -- this one instead
/// asks the actual on-device search and barcode lookup for real answers,
/// which is the only way to catch a bundling regression (the `.db` resource
/// missing from the app bundle, the FTS5 index empty or malformed) that a
/// synthetic test can never see.
///
/// There is no "watch it fail first" for this file: it adds coverage of a
/// layer nothing else in this repo exercises, rather than pinning a defect
/// being fixed. Said plainly rather than fabricating a red run.
final class ReferenceDatabaseSmokeTests: XCTestCase {

    func testSearchingChickenBreastFindsAMatchInTheRealBundledDatabase() async throws {
        let results = try await ReferenceDatabase.shared.searchFoods("chicken breast", limit: 5)
        XCTAssertTrue(
            results.contains { $0.name.localizedCaseInsensitiveContains("chicken") },
            "expected at least one bundled food record whose name contains \"chicken\"")
    }

    func testAnUnknownBarcodeReturnsNilRatherThanThrowing() async throws {
        let record = try await ReferenceDatabase.shared.food(barcode: "0000000000000")
        XCTAssertNil(record)
    }
}
