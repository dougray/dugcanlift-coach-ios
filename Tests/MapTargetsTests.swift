import XCTest

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
}
