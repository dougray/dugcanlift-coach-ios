import XCTest
import CryptoKit
import SwiftData
import LiftCore
@testable import Coach

/// The "Send to Coach" bookmarklet's link, `dugcanliftcoach://recipe#r1…`, as
/// `dugcanlift-kit`'s `bookmarklet/` defines it. `recipe-link.txt` and
/// `recipe-link-expected.json` are the kit's fixture pair, copied unchanged:
/// the link was written by the bookmarklet itself, so a port that agrees with
/// the pair agrees with the bookmarklet people run. Never regenerate them from
/// Swift.
final class RecipeLinkTests: XCTestCase {

    private func fixture(_ name: String, _ ext: String) throws -> String {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext),
                                "\(name).\(ext) is not in the test bundle")
        return try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct Expected: Decodable {
        let url: String
        let jsonld: [String]
    }

    /// The fixture's own fragment, `r1…`.
    private func fixtureFragment() throws -> String {
        let link = try fixture("recipe-link", "txt")
        return String(try XCTUnwrap(link.split(separator: "#", maxSplits: 1).last))
    }

    /// The kit's fixture was written for the `liftApp` target; the payload is
    /// the same for every target, so this is the link `coachApp` writes for
    /// the same page.
    private func coachLink() throws -> URL {
        try XCTUnwrap(URL(string: "dugcanliftcoach://recipe#" + fixtureFragment()))
    }

    /// The reference's own test encoder: deflate-raw, base64url, no padding.
    private func encode(_ object: Any) throws -> String {
        try encode(json: JSONSerialization.data(withJSONObject: object))
    }

    private func encode(json: Data) throws -> String {
        // `.zlib` here is raw deflate, the same stream `CompressionStream('deflate-raw')` writes.
        let deflated = try (json as NSData).compressed(using: .zlib) as Data
        return "#r1" + deflated.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private let ok: [String: Any] = ["v": 1, "url": "https://a.example/r", "jsonld": [#"{"@type":"Recipe"}"#]]

    private func with(_ key: String, _ value: Any) -> [String: Any] {
        var doc = ok
        doc[key] = value
        return doc
    }

    // MARK: - The fixture pair

    func testTheFixtureLinkDecodesToTheExpectedPage() throws {
        let expected = try JSONDecoder().decode(Expected.self,
                                                from: Data(fixture("recipe-link-expected", "json").utf8))
        let page = try XCTUnwrap(RecipeLink.decode(fixture("recipe-link", "txt")))
        XCTAssertEqual(page.url.absoluteString, expected.url)
        XCTAssertEqual(page.blocks, expected.jsonld)
    }

    /// What comes out is what Safari's extension hands over, so the same
    /// reader finds the same recipe in it -- non-ASCII and emoji intact.
    func testTheFixtureHoldsTheStew() throws {
        let page = try XCTUnwrap(RecipeLink.decode(fixture("recipe-link", "txt")))
        let found = try XCTUnwrap(page.firstRecipe())
        XCTAssertEqual(found.recipe.name, "Beef & barley stew — crème fraîche finish 🍲")
        XCTAssertEqual(found.recipe.servings, 4)
        XCTAssertEqual(found.recipe.ingredientLines.count, 6)
        XCTAssertEqual(found.block, page.blocks[0])
    }

    // MARK: - Refusals, as the reference's own test lists them

    func testRefusals() throws {
        XCTAssertNotNil(RecipeLink.decode(try encode(ok)))
        XCTAssertNil(RecipeLink.decode("dugcanliftcoach://recipe"), "no fragment")
        XCTAssertNil(RecipeLink.decode("#1zabc"), "a log link is not a recipe link")
        XCTAssertNil(RecipeLink.decode("#r1!!!"), "not base64url")
        XCTAssertNil(RecipeLink.decode("#r1AAAA"), "not deflate")
        XCTAssertNil(RecipeLink.decode("#r1"), "nothing after the prefix")
        XCTAssertNil(RecipeLink.decode(try encode(with("v", 2))), "unknown version")
        XCTAssertNil(RecipeLink.decode(try encode(with("v", true))), "true is not 1")
        XCTAssertNil(RecipeLink.decode(try encode(with("v", "1"))), "\"1\" is not 1")
        XCTAssertNil(RecipeLink.decode(try encode(with("url", "javascript:alert(1)"))), "not http(s)")
        XCTAssertNil(RecipeLink.decode(try encode(with("url", 7))), "url not a string")
        XCTAssertNil(RecipeLink.decode(try encode(with("jsonld", "x"))), "jsonld not an array")
        XCTAssertNil(RecipeLink.decode(try encode(with("jsonld", [Any]()))), "no blocks")
        XCTAssertNil(RecipeLink.decode(try encode(with("jsonld", [3, NSNull()]))), "no string blocks")
        XCTAssertNil(RecipeLink.decode(try encode(json: Data("[1]".utf8))), "not an object")
        XCTAssertNil(RecipeLink.decode(try encode(json: Data("{\"v\":1,".utf8))), "not JSON")
    }

    func testAnHTTPAddressIsAcceptedInAnyCase() throws {
        XCTAssertNotNil(RecipeLink.decode(try encode(with("url", "http://a.example/r"))))
        XCTAssertNotNil(RecipeLink.decode(try encode(with("url", "HTTPS://a.example/r"))))
    }

    func testANonStringBlockIsDroppedNotFatal() throws {
        let page = try XCTUnwrap(RecipeLink.decode(try encode(with("jsonld", [5, #"{"@type":"Recipe"}"#]))))
        XCTAssertEqual(page.blocks, [#"{"@type":"Recipe"}"#])
    }

    /// A deflate stream cut short is refused, not read as far as it goes.
    func testATruncatedStreamIsRefused() throws {
        let whole = try encode(ok)
        XCTAssertNotNil(RecipeLink.decode(whole))
        XCTAssertNil(RecipeLink.decode(String(whole.dropLast(8))))
    }

    /// The cap is on the inflated bytes, as `maxOutputLength` is: exactly
    /// 512 KiB is read, one byte more is refused.
    func testTheCapIsFiveHundredAndTwelveKibibytesInflated() throws {
        let head = #"{"v":1,"url":"https://a.example/r","jsonld":[""#
        let tail = #""]}"#
        let filler = RecipeLink.maxBytes - head.utf8.count - tail.utf8.count
        let atCap = head + String(repeating: "x", count: filler) + tail
        XCTAssertEqual(atCap.utf8.count, RecipeLink.maxBytes)
        XCTAssertNotNil(RecipeLink.decode(try encode(json: Data(atCap.utf8))))
        let over = head + String(repeating: "x", count: filler + 1) + tail
        XCTAssertNil(RecipeLink.decode(try encode(json: Data(over.utf8))))
        // The reference's own case.
        XCTAssertNil(RecipeLink.decode(try encode(with("jsonld", [String(repeating: "x", count: RecipeLink.maxBytes + 1)]))))
    }

    // MARK: - A log link and a recipe link are never confused

    private func logLink() throws -> URL {
        let shared = try fixture("plan-log-share-link", "txt")
        let fragment = try XCTUnwrap(ShareLinkExtractor.fragment(in: shared))
        return try XCTUnwrap(ShareLinkExtractor.openURL(for: fragment))
    }

    func testARecipeLinkRoutesToTheReview() throws {
        let page = try XCTUnwrap(RecipeLink.decode(fixture("recipe-link", "txt")))
        XCTAssertEqual(CoachURLRoute(try coachLink()),
                       .recipe(.init(block: page.blocks[0], pageURL: "https://example.com/recipes/stew")))
        // The host is read case-insensitively, as a URL's host is.
        XCTAssertEqual(CoachURLRoute(try XCTUnwrap(URL(string: "DUGCANLIFTCOACH://Recipe#" + fixtureFragment()))),
                       CoachURLRoute(try coachLink()))
    }

    func testALogLinkRoutesToTheImporterAndStillImports() throws {
        let url = try logLink()
        XCTAssertEqual(url.host, "import")
        guard case .log(let text) = CoachURLRoute(url) else { return XCTFail("a log link went to the recipe path") }
        XCTAssertNil(RecipeLink.decode(text))
        let container = try ModelContainer(for: Schema(CoachSchema.models),
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        XCTAssertNoThrow(try ShareLinkImporter.importLink(text, into: ModelContext(container)))
    }

    func testARecipeFragmentOnTheImportHostIsALogLinkAndIsRefused() throws {
        let url = try XCTUnwrap(URL(string: "dugcanliftcoach://import#" + fixtureFragment()))
        guard case .log(let text) = CoachURLRoute(url) else { return XCTFail("routed by fragment, not host") }
        let container = try ModelContainer(for: Schema(CoachSchema.models),
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        XCTAssertThrowsError(try ShareLinkImporter.importLink(text, into: ModelContext(container)))
        // Nor does Paste a Link or the share extension take one for a log.
        XCTAssertNil(ShareLinkExtractor.fragment(in: try coachLink().absoluteString))
    }

    func testALogFragmentOnTheRecipeHostIsAnUnreadableRecipe() throws {
        let log = try logLink().absoluteString
        let fragment = String(try XCTUnwrap(log.split(separator: "#").last))
        XCTAssertEqual(CoachURLRoute(try XCTUnwrap(URL(string: "dugcanliftcoach://recipe#" + fragment))),
                       .unreadableRecipe)
    }

    /// The bookmarklet's shared wording, word for word in every build.
    func testTheReportsAreTheSharedWording() {
        XCTAssertEqual(RecipeLink.unreadableMessage,
                       "That recipe link could not be read, so nothing was added. Open the recipe page and tap Send to Coach again.")
        XCTAssertEqual(RecipeLink.noRecipeMessage,
                       "That page has no recipe Coach can read. Copy the recipe text and use Paste a recipe instead.")
    }

    func testGarbageAndRecipelessLinksGetTheReport() throws {
        XCTAssertEqual(CoachURLRoute(try XCTUnwrap(URL(string: "dugcanliftcoach://recipe#r1abc"))), .unreadableRecipe)
        XCTAssertEqual(CoachURLRoute(try XCTUnwrap(URL(string: "dugcanliftcoach://recipe"))), .unreadableRecipe)
        // Decodes, but holds no schema.org Recipe for the review to show.
        let breadcrumbs = try encode(with("jsonld", [#"{"@type":"BreadcrumbList","name":"recipes"}"#]))
        XCTAssertNotNil(RecipeLink.decode(breadcrumbs))
        XCTAssertEqual(CoachURLRoute(try XCTUnwrap(URL(string: "dugcanliftcoach://recipe" + breadcrumbs))),
                       .noRecipe)
    }

    // MARK: - The bookmarklet Coach offers

    /// `bookmarklets.json` is built in `dugcanlift-kit/bookmarklet/` and copied
    /// here byte for byte with its `.sha256`, as `road-food.json` is
    /// (`RoadPicksTests.testTheBundledFileIsTheKitsBytes`). It hashes what the
    /// test bundle holds, so a build that dropped the resource fails too.
    func testTheBundledBookmarkletsAreTheKitsBytes() throws {
        let bundle = Bundle(for: RecipeLinkTests.self)
        let json = try XCTUnwrap(bundle.url(forResource: "bookmarklets", withExtension: "json"),
                                 "bookmarklets.json is not in the test bundle")
        let sumURL = try XCTUnwrap(bundle.url(forResource: "bookmarklets", withExtension: "sha256"),
                                   "bookmarklets.sha256 is not in the test bundle -- copy it from the kit beside the JSON")
        let pinned = try String(contentsOf: sumURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertNotNil(pinned.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression),
                        "bookmarklets.sha256 should be one bare sha256 and nothing else")
        let actual = SHA256.hash(data: try Data(contentsOf: json))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(actual, pinned, """
            The bundled bookmarklets.json does not match bookmarklets.sha256.
            Copy dugcanlift-kit/bookmarklet/bookmarklets.json AND bookmarklets.sha256 over together.
            Never edit either file here, and never re-write the checksum by hand to make this pass:
            the kit writes both with `node bookmarklet/build-bookmarklets.mjs`.
            """)
    }

    /// The string the sheet shows and copies is the kit's `coachApp`, read
    /// from the app's own bundle, and it opens Coach's recipe host.
    func testTheSheetOffersTheCoachAppBookmarklet() throws {
        let shipped = try XCTUnwrap(Bookmarklets.coachApp(), "the app bundle has no bookmarklets.json")
        XCTAssertEqual(shipped, Bookmarklets.coachApp(in: Bundle(for: RecipeLinkTests.self)))
        XCTAssertTrue(shipped.hasPrefix("javascript:"))
        XCTAssertFalse(shipped.contains("#"), "a raw # would end the bookmark's address")
        let body = try XCTUnwrap(shipped.removingPercentEncoding)
        XCTAssertTrue(body.contains("'dugcanliftcoach://recipe' + '#r1'"), "not the coachApp target")
        XCTAssertFalse(body.contains("dugcanliftlift:"))
    }
}
