import XCTest
@testable import Coach

/// Two rules about the Booked card that only its own source can answer.
///
/// Coach web pins the same two by reading `app.js`: a card that counts must
/// not reach a roster row, and a row is its set groups **plus** its clause.
final class BookedCardTests: XCTestCase {

    /// The roster stays a roster: the card counts per client and never across
    /// the roster, so nothing in this feature reaches a roster row.
    func testTheRosterStaysARoster() throws {
        let source = try String(contentsOf: sourceFile("RosterView.swift"), encoding: .utf8)
        for token in ["PlanAndLog", "SentPlan", "Booked", "booked"] {
            XCTAssertFalse(source.contains(token),
                           "RosterView mentions \(token) -- this counts per client, never across the roster")
        }
    }

    /// The card draws every part of a row, clause included. Found on screen in
    /// Coach web, not in a test: the card drew an each-side ask's set groups
    /// and dropped its "each side" clause, so a plan asking for six sets
    /// printed three while `lines` -- and so every discipline test -- read the
    /// full sentence.
    func testTheCardDrawsEveryPartOfARowClauseIncluded() throws {
        let source = try String(contentsOf: sourceFile("BookedCardView.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func setRow("))
        let body = String(source[start.lowerBound...].prefix(600))
        XCTAssertTrue(body.contains("row.groups"), "setRow must draw the groups")
        XCTAssertTrue(body.contains("row.suffix"), "setRow must draw the suffix")
    }

    private func sourceFile(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("Sources/App/\(name)")
    }
}
