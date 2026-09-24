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

    /// The same guard as the one above, for the half of the card where getting
    /// it wrong is worse: a view that drew the booked dish and dropped the line
    /// saying what the log holds at that meal would read as a claim the dish
    /// was eaten, which is the one thing this feature refuses to say.
    func testTheCardDrawsBothHalvesOfAMealRowAndTheContextAboveThem() throws {
        let source = try String(contentsOf: sourceFile("BookedCardView.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func meals("))
        let rest = source[start.upperBound...]
        // To the end of that function and no further, so this cannot pass on
        // a token that belongs to the one after it.
        let end = try XCTUnwrap(rest.range(of: "\n    }\n"))
        let body = String(rest[..<end.lowerBound])
        XCTAssertTrue(body.contains("day.foodContext"),
                      "the day's own food count sits above the rows")
        XCTAssertTrue(body.contains("meal.title"), "what was booked")
        XCTAssertTrue(body.contains("meal.logged"), "what the log holds at that meal")
    }

    /// Both muted lines under the card, in that order.
    func testTheCardCarriesTheNoteAboutWhatAMealRowDoesNotClaim() throws {
        let source = try String(contentsOf: sourceFile("BookedCardView.swift"), encoding: .utf8)
        let mealFooter = try XCTUnwrap(source.range(of: "result.mealFooter"))
        let footer = try XCTUnwrap(source.range(of: "Text(result.footer)"))
        XCTAssertTrue(mealFooter.lowerBound < footer.lowerBound,
                      "the meal note sits above the permanent footer")
    }

    /// Both send buttons file the send before presenting the sheet.
    ///
    /// A `ShareLink` has no action of its own, so a screen that sends a plan
    /// and records nothing looks exactly like one that works: the link goes,
    /// and the card is simply empty forever. Cook's send was in that state
    /// until meals reached the card.
    func testEverySendButtonRecordsBeforeItShares() throws {
        for name in ["CookPlanView.swift", "TrainPlanView.swift"] {
            let source = try String(contentsOf: sourceFile(name), encoding: .utf8)
            XCTAssertTrue(source.contains("recordSend("),
                          "\(name) sends a plan and files no record of it")
            XCTAssertFalse(source.contains("ShareLink(item:"),
                           "\(name) must present the sheet itself, after recording")
        }
    }

    private func sourceFile(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("Sources/App/\(name)")
    }
}
