import XCTest
import SwiftData
import LiftCore
@testable import Coach

final class ShareLinkExtractorTests: XCTestCase {

    private let link = "https://www.dugcanlift.com/coach/#1zABC-def_123"

    // MARK: Where the link is found

    func testAFullLinkReducesToItsFragment() {
        XCTAssertEqual(ShareLinkExtractor.fragment(in: link), "1zABC-def_123")
    }

    func testTheUncompressedCodecIsAccepted() {
        XCTAssertEqual(ShareLinkExtractor.fragment(in: "https://www.dugcanlift.com/coach/#1uXYZ"), "1uXYZ")
    }

    func testHostVariantsAreAccepted() {
        for text in ["http://dugcanlift.com/coach/#1zABC",
                     "HTTPS://WWW.DUGCANLIFT.COM/coach/#1zABC",
                     "www.dugcanlift.com/coach/#1zABC",
                     "https://www.dugcanlift.com/coach#1zABC",
                     "https://www.dugcanlift.com/coach/index.html#1zABC"] {
            XCTAssertEqual(ShareLinkExtractor.fragment(in: text), "1zABC", text)
        }
    }

    func testTextAroundTheLinkIsIgnored() {
        let mail = """
        Hi coach,

        Here's week #3 of my log: \(link)
        Thanks!
        Sent from my iPhone
        """
        XCTAssertEqual(ShareLinkExtractor.fragment(in: mail), "1zABC-def_123")
    }

    func testTrailingPunctuationAndMailBracketsAreDropped() {
        XCTAssertEqual(ShareLinkExtractor.fragment(in: "<\(link)>"), "1zABC-def_123")
        XCTAssertEqual(ShareLinkExtractor.fragment(in: "My log: \(link)."), "1zABC-def_123")
        XCTAssertEqual(ShareLinkExtractor.fragment(in: "(\(link))"), "1zABC-def_123")
    }

    func testTheFirstLinkWinsWhenAThreadQuotesAnother() {
        let text = "New: https://www.dugcanlift.com/coach/#1zNEW\n> Old: https://www.dugcanlift.com/coach/#1zOLD"
        XCTAssertEqual(ShareLinkExtractor.fragment(in: text), "1zNEW")
    }

    func testCoachsOwnURLSchemeIsAccepted() {
        XCTAssertEqual(ShareLinkExtractor.fragment(in: "dugcanliftcoach://import#1zABC"), "1zABC")
        XCTAssertEqual(ShareLinkExtractor.openURL(for: "1zABC")?.absoluteString, "dugcanliftcoach://import#1zABC")
    }

    func testABareFragmentIsAccepted() {
        XCTAssertEqual(ShareLinkExtractor.fragment(in: "  1zABC\n"), "1zABC")
        XCTAssertEqual(ShareLinkExtractor.fragment(in: "#1zABC sent via LIFT"), "1zABC")
    }

    // MARK: What is refused

    func testAnotherSitesURLIsRefusedEvenWithALiftShapedFragment() {
        XCTAssertNil(ShareLinkExtractor.fragment(in: "https://example.com/coach/#1zABC"))
        XCTAssertNil(ShareLinkExtractor.fragment(in: "https://notdugcanlift.com/coach/#1zABC"))
        XCTAssertNil(ShareLinkExtractor.fragment(in: "https://dugcanlift.com.evil.example/coach/#1zABC"))
        XCTAssertNil(ShareLinkExtractor.fragment(in: "https://evil.example/www.dugcanlift.com/coach/#1zABC"))
        XCTAssertNil(ShareLinkExtractor.fragment(in: "https://evil.example@dugcanlift.com/coach/#1zABC"))
    }

    func testOtherDugCanLiftPagesAreRefused() {
        XCTAssertNil(ShareLinkExtractor.fragment(in: "https://www.dugcanlift.com/lift/#1zABC"))
        XCTAssertNil(ShareLinkExtractor.fragment(in: "https://www.dugcanlift.com/coach/"))
    }

    func testTextWithNoLinkIsRefused() {
        for text in ["", "   ", "#", "1z", "Great session today!", "1Zabc", "2zABC", "week #1zABC"] {
            XCTAssertNil(ShareLinkExtractor.fragment(in: text), text)
        }
    }

    func testTheWebCoachPageWithItsLogStrippedIsRecognised() {
        XCTAssertTrue(ShareLinkExtractor.isCoachPageWithoutLog("https://www.dugcanlift.com/coach/"))
        XCTAssertTrue(ShareLinkExtractor.isCoachPageWithoutLog("https://www.dugcanlift.com/coach"))
        XCTAssertFalse(ShareLinkExtractor.isCoachPageWithoutLog(link))
        XCTAssertFalse(ShareLinkExtractor.isCoachPageWithoutLog("https://www.dugcanlift.com/lift/"))
        XCTAssertFalse(ShareLinkExtractor.isCoachPageWithoutLog("Great session!"))
    }

    // MARK: Decoding a real link

    private func fixtureLink() throws -> String {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "outdoor-share-link", withExtension: "txt"))
        return try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testARealLinkInsideAMessageDecodesAndSummarises() throws {
        let payload = try ShareLinkExtractor.payload(in: "Here you go coach 💪\n\(try fixtureLink())\nSee you Monday")
        XCTAssertEqual(payload.c.n, "Outdoor Fixture")
        XCTAssertEqual(ShareLinkExtractor.summary(of: payload), "Outdoor Fixture's log · 3 days")
    }

    func testTheURLSchemeCarriesARealLink() throws {
        let fragment = try XCTUnwrap(ShareLinkExtractor.fragment(in: try fixtureLink()))
        let url = try XCTUnwrap(ShareLinkExtractor.openURL(for: fragment))
        XCTAssertEqual(try ShareLinkExtractor.payload(in: url.absoluteString).c.i, "outdoor-fixture")
    }

    func testANonLinkThrows() {
        XCTAssertThrowsError(try ShareLinkExtractor.payload(in: "https://example.com/#1zABC"))
        XCTAssertThrowsError(try ShareLinkExtractor.payload(in: "https://www.dugcanlift.com/coach/#1zNotReallyDeflate"))
    }

    func testImportLinkStoresTheClientThroughPasteALinksPath() throws {
        let container = try ModelContainer(for: Schema(CoachSchema.models),
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        try ShareLinkImporter.importLink("From Messages: \(try fixtureLink())", into: context)
        let clients = try context.fetch(FetchDescriptor<Client>())
        XCTAssertEqual(clients.map(\.name), ["Outdoor Fixture"])
        XCTAssertEqual(clients.first?.trainingDays.count, 3)
    }
}

final class PendingShareLinksTests: XCTestCase {

    private var suiteName: String!
    private var inbox: PendingShareLinks!

    override func setUp() {
        suiteName = "PendingShareLinksTests-\(UUID().uuidString)"
        inbox = PendingShareLinks(defaults: UserDefaults(suiteName: suiteName)!)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    func testTakeAllReturnsOldestFirstAndEmptiesTheQueue() {
        inbox.add("1zA")
        inbox.add("1zB")
        XCTAssertEqual(inbox.takeAll(), ["1zA", "1zB"])
        XCTAssertEqual(inbox.takeAll(), [])
    }

    func testTheSameLinkSharedTwiceIsQueuedOnceAtItsNewestPosition() {
        inbox.add("1zA")
        inbox.add("1zB")
        inbox.add("1zA")
        XCTAssertEqual(inbox.pending, ["1zB", "1zA"])
    }

    func testTheQueueIsBoundedAndDropsTheOldest() {
        for i in 0..<(PendingShareLinks.limit + 5) { inbox.add("1z\(i)") }
        XCTAssertEqual(inbox.pending.count, PendingShareLinks.limit)
        XCTAssertEqual(inbox.pending.first, "1z5")
    }
}
