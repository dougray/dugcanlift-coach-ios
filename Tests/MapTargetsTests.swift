import XCTest
import LiftCore
import LiftMapCore
@testable import Coach

/// Where the street map is allowed to link.
///
/// `LiftMap` (MapLibre, a binary framework) and `LiftMapCore` (the street
/// store and the one download) belong to the Coach app target only. The share
/// extension has a tight memory limit and, by the in-house rule, no business
/// near a network API: it links `LiftCore` and nothing else. This reads
/// `project.yml` and fails if a map product reaches any other target.
final class MapTargetsTests: XCTestCase {

    private func projectYML() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("project.yml")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The products each target lists as `- package: LiftKit` / `product: X`.
    private func products(in yml: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        var inTargets = false
        var target: String?
        for raw in yml.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\\s+#.*$", with: "", options: .regularExpression)
            if line.hasPrefix("targets:") { inTargets = true; continue }
            if line.hasPrefix("schemes:") { inTargets = false; target = nil }
            guard inTargets else { continue }
            if line.range(of: "^  [A-Za-z]+:\\s*$", options: .regularExpression) != nil {
                target = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ":", with: "")
                result[target!] = []
            } else if let target, line.trimmingCharacters(in: .whitespaces).hasPrefix("product:") {
                let name = line.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "product:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                result[target, default: []].append(name)
            }
        }
        return result
    }

    func testOnlyTheAppLinksTheMap() throws {
        let linked = products(in: try projectYML())
        XCTAssertNotNil(linked["Coach"], "no Coach target found in project.yml")
        XCTAssertNotNil(linked["CoachShare"], "no CoachShare target found in project.yml")
        for product in ["LiftMap", "LiftMapCore"] {
            XCTAssertTrue(linked["Coach"]?.contains(product) == true, "Coach must link \(product)")
            for (name, list) in linked where name != "Coach" {
                XCTAssertFalse(list.contains(product), "\(name) must not link \(product)")
            }
        }
    }

    func testTheShareExtensionLinksOnlyLiftCore() throws {
        XCTAssertEqual(products(in: try projectYML())["CoachShare"], ["LiftCore"])
    }

    func testTheKitIsPinnedToTheMapRelease() throws {
        XCTAssertTrue(try projectYML().contains("exactVersion: 1.18.0"))
    }

    // MARK: the route card's offer

    private func emptyStore() throws -> StreetStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MapTargetsTests-\(UUID().uuidString).mbtiles")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try StreetStore(fileURL: url)
    }

    func testTheOfferNeedsARouteOfAtLeastTwoPoints() throws {
        let store = try emptyStore()
        let a = OutdoorShareCoordinate(latitude: 30.26896, longitude: -97.74262)
        let b = OutdoorShareCoordinate(latitude: 30.26544, longitude: -97.74262)
        XCTAssertFalse(RouteStreetsOffer.shouldOffer(points: [], store: store))
        // MapBounds.around answers for one point, with an area of nothing.
        XCTAssertFalse(RouteStreetsOffer.shouldOffer(points: [a], store: store))
        XCTAssertTrue(RouteStreetsOffer.shouldOffer(points: [a, b], store: store))
    }

    func testTheOfferGoesWhileADownloadHoldsTheStore() throws {
        let store = try emptyStore()
        let a = OutdoorShareCoordinate(latitude: 30.26896, longitude: -97.74262)
        let b = OutdoorShareCoordinate(latitude: 30.26544, longitude: -97.74262)
        XCTAssertTrue(RouteStreetsOffer.shouldOffer(points: [a, b], store: store))
        store.beginWriting()
        XCTAssertFalse(RouteStreetsOffer.shouldOffer(points: [a, b], store: store))
        store.endWriting()
        XCTAssertTrue(RouteStreetsOffer.shouldOffer(points: [a, b], store: store))
    }

    func testTheOfferGoesOnceStreetsCoverTheRoute() throws {
        let store = try emptyStore()
        let a = OutdoorShareCoordinate(latitude: 30.26896, longitude: -97.74262)
        let b = OutdoorShareCoordinate(latitude: 30.26544, longitude: -97.74262)
        let area = try store.beginArea(.forRoute(try XCTUnwrap(MapBounds.around([a, b]))), name: "route")
        // Begun but not finished is not cover.
        XCTAssertTrue(RouteStreetsOffer.shouldOffer(points: [a, b], store: store))
        try store.finishArea(area)
        XCTAssertFalse(RouteStreetsOffer.shouldOffer(points: [a, b], store: store))
    }
}
