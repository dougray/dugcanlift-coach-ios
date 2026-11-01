import XCTest
@testable import Coach

/// The bookmarklet's on-screen preview wraps by character, so `Text` has a
/// break opportunity everywhere and never hyphenates the code. Only the
/// preview changes: what Copy copies is the bundled bytes.
final class BookmarkletPreviewTests: XCTestCase {
    func testThePreviewIsTheCodeWithABreakBetweenEveryCharacter() {
        let code = "javascript:(()=>{location.href='x'})()"
        let preview = BrowserBookmarkletView.characterWrapped(code)
        XCTAssertEqual(preview.replacingOccurrences(of: "\u{200B}", with: ""), code)
        XCTAssertEqual(preview.filter { $0 == "\u{200B}" }.count, code.count - 1)
        XCTAssertFalse(preview.contains("-") && !code.contains("-"))
    }
}
